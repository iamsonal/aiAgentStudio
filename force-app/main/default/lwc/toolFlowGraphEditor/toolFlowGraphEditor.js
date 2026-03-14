import { LightningElement, api, track, wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import cytoscapeResource from '@salesforce/resourceUrl/cytoscape';
import getFlowGraphEditorData from '@salesforce/apex/ToolFlowGenerationService.getFlowGraphEditorData';
import generateGraph from '@salesforce/apex/ToolFlowGenerationService.generateGraph';
import saveGraph from '@salesforce/apex/ToolFlowGenerationService.saveGraph';

// ── Services ──────────────────────────────────────────────────────────────
import {
    START_ID,
    END_PREFIX,
    EMPTY_END_ID,
    SENTINEL_EMPTY,
    PH_PREFIX,
    STEP_PREFIX,
    isEndNode,
    isSentinel,
    isPlaceholder,
    isStep,
    isOverlay,
    stepHeight
} from './services/constants.js';
import { CY_STYLE, LAYOUT_OPTIONS, RANKSEP_EDIT, RANKSEP_READONLY } from './services/graphStyles.js';
import { computeEdgeMidpoints, computeBranchOriginButtons, computeConditionLabels, computeParallelOverlays } from './services/overlayUtils.js';
import { parseFlowJson, applyFallbackConditions, buildFlowJson } from './services/graphSerializer.js';
import { computeGraphDiagnostics } from './services/graphDiagnostics.js';
import {
    getAdjacentTools,
    findDropTarget,
    makePlaceholderElements,
    makeBranchElements,
    makeBranchElementsPreserving,
    makeAdditionalBranchElement,
    buildStepFromPlaceholder,
    computeDropToolOnStep
} from './services/graphOperations.js';

export default class ToolFlowGraphEditor extends LightningElement {
    @api recordId;

    // ── UI state ──────────────────────────────────────────────────────
    @track isLoading = false;
    @track isLibLoading = true;
    @track isDirty = false;
    @track isStale = false;
    @track graphWarning = null;
    @track isEditMode = false; // false = read-only; true = editing
    @track selectedNodeId = null;
    @track selectedEdgeId = null;
    @track conditionDraft = '';
    @track jsonExpanded = false;
    @track capabilities = [];

    // ── Overlay state (HTML elements rendered over the Cytoscape canvas) ──
    @track edgeMidpoints = []; // "+" buttons on edges
    @track branchOriginButtons = []; // "+" button at each branch origin
    @track parallelNodes = []; // parallel-tool chip overlays
    @track conditionLabels = []; // exclusive-edge condition pills
    @track inlineConditionEditor = null; // { edgeId, style }  — input managed via DOM
    @track insertionModal = null; // { x, y, edgeId, sourceId, targetId }

    // ── Canvas sizing ─────────────────────────────────────────────────
    @track cyWrapHeight = 600; // px — recalculated after each layout

    // ── Status-strip counts (updated after each layout stop) ──────────
    @track _nodeCount = 0;
    @track _edgeCount = 0;
    @track graphDiagnostics = {
        warnings: [],
        warningCount: 0,
        missingConditionCount: 0,
        unknownToolCount: 0,
        parallelConflictCount: 0,
        sourceConflictCount: 0
    };

    // ── Drag-and-drop feedback ────────────────────────────────────────
    @track _blockedTools = []; // tools currently invalid for hovered target

    // ── Private fields ────────────────────────────────────────────────
    graphJson = '';
    _history = [];
    _future = [];
    _savedJson = '';
    _capabilitiesHash = null;
    _parallelCallingEnabled = true;
    _cy = null;
    _draggedTool = null;
    // Graph JSON waiting to be rendered once Cytoscape is initialized.
    _pendingJson = undefined;
    // Set to true on mousedown of any HTML overlay so the next Cytoscape
    // tap (node / edge / background) that fires for the same interaction is discarded.
    _suppressNextCyTap = false;
    // Holds the edge ID whose inline condition editor should auto-open after layout.
    _pendingConditionEdgeId = null;
    // Timer/RAF IDs – stored so they can be cancelled in disconnectedCallback.
    _layoutTimer = null;
    _rafId = null;
    // Keyboard shortcut listener reference – stored for removal on disconnect.
    _keydownHandler = null;

    // ── Wire ──────────────────────────────────────────────────────────
    @wire(getFlowGraphEditorData, { agentDefId: '$recordId' })
    wiredData({ data, error }) {
        if (data) {
            this.capabilities = data.capabilities || [];
            this.isStale = data.isStale === true;
            this.graphWarning = data.graphWarning || null;
            this._capabilitiesHash = data.capabilitiesHash || null;
            this._parallelCallingEnabled = data.parallelCallingEnabled === true;
            this._pendingJson = data.graphJson || '';
            this._savedJson = this._pendingJson;
            if (this._cy) this.loadGraph(this._pendingJson, { markClean: true });
        } else if (error) {
            this.toast('Error loading data', error.body?.message || 'Unknown error', 'error');
        }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────
    async connectedCallback() {
        try {
            // cytoscape core must be available before the dagre adapter loads.
            await loadScript(this, cytoscapeResource + '/cytoscape.min.js');
            await loadScript(this, cytoscapeResource + '/dagre.min.js');
            await loadScript(this, cytoscapeResource + '/cytoscape-dagre.js');
            this.isLibLoading = false;
        } catch (e) {
            this.toast('Failed to load graph library', e.message, 'error');
            this.isLibLoading = false;
        }

        this._keydownHandler = (e) => {
            if (!this.isEditMode) return;
            const tag = (e.target && e.target.tagName) || '';
            if (tag === 'INPUT' || tag === 'TEXTAREA') return;
            if ((e.ctrlKey || e.metaKey) && e.key === 'z' && !e.shiftKey) {
                e.preventDefault();
                this.handleUndo();
            } else if ((e.ctrlKey || e.metaKey) && (e.key === 'y' || (e.key === 'z' && e.shiftKey))) {
                e.preventDefault();
                this.handleRedo();
            }
        };
        document.addEventListener('keydown', this._keydownHandler);
    }

    disconnectedCallback() {
        if (this._layoutTimer) {
            clearTimeout(this._layoutTimer);
            this._layoutTimer = null;
        }
        if (this._rafId) {
            cancelAnimationFrame(this._rafId);
            this._rafId = null;
        }
        if (this._keydownHandler) {
            document.removeEventListener('keydown', this._keydownHandler);
            this._keydownHandler = null;
        }
        if (this._cy) {
            this._cy.destroy();
            this._cy = null;
        }
    }

    renderedCallback() {
        if (!this.isLibLoading && !this._cy) this.initCytoscape();
    }

    // ── Cytoscape initialisation ──────────────────────────────────────
    initCytoscape() {
        const container = this.refs.cyContainer;
        if (!container) return;

        /* global cytoscape, cytoscapeDagre */
        cytoscape.use(cytoscapeDagre);

        this._cy = cytoscape({
            container,
            elements: [],
            style: CY_STYLE,
            layout: { name: 'preset' },
            // Wheel scroll disabled so the page scrolls normally;
            // zoom is controlled via the on-canvas +/− buttons.
            userZoomingEnabled: false,
            userPanningEnabled: true,
            boxSelectionEnabled: false,
            minZoom: 0.2,
            maxZoom: 3.0
        });

        this.setupEvents();
        this.addSentinels();
        this._cy.nodes().ungrabify();

        if (this._pendingJson !== undefined) {
            this.loadGraph(this._pendingJson, { markClean: true });
        } else {
            this.runLayout({ animate: false, fitAfter: true });
        }
    }

    // ── Sentinel helpers ──────────────────────────────────────────────
    addSentinels() {
        if (this._cy.getElementById(START_ID).length > 0) return;
        this._cy.add([
            { group: 'nodes', data: { id: START_ID, nodeType: 'start' } },
            { group: 'nodes', data: { id: EMPTY_END_ID, nodeType: 'end' } },
            { group: 'edges', data: { id: SENTINEL_EMPTY, source: START_ID, target: EMPTY_END_ID, edgeType: 'sentinel' } }
        ]);
        this._cy.nodes().ungrabify();
    }

    // Rebuilds End nodes: one per terminal non-sentinel node, or blank-canvas End.
    updateEndConnections() {
        const cy = this._cy;
        cy.nodes()
            .filter((n) => isEndNode(n.id()))
            .remove();

        const nonSentinels = cy.nodes().filter((n) => !isSentinel(n.id()));
        if (nonSentinels.length === 0) {
            cy.add([
                { group: 'nodes', data: { id: EMPTY_END_ID, nodeType: 'end' } },
                { group: 'edges', data: { id: SENTINEL_EMPTY, source: START_ID, target: EMPTY_END_ID, edgeType: 'sentinel' } }
            ]);
        } else {
            nonSentinels.forEach((node) => {
                if (node.outgoers('edge').length === 0) {
                    const endId = `${END_PREFIX}${node.id()}__`;
                    cy.add([
                        { group: 'nodes', data: { id: endId, nodeType: 'end' } },
                        { group: 'edges', data: { id: `${node.id()}-->${endId}`, source: node.id(), target: endId, edgeType: 'end-connection' } }
                    ]);
                }
            });
        }
        cy.nodes().ungrabify();
    }

    // ── Cytoscape event setup ─────────────────────────────────────────
    setupEvents() {
        const cy = this._cy;

        // Tap node → select (inspector panel)
        cy.on('tap', 'node', (evt) => {
            if (this._suppressNextCyTap) {
                this._suppressNextCyTap = false;
                return;
            }
            const id = evt.target.id();
            if (isOverlay(id)) return;
            this.selectedEdgeId = null;
            this.conditionDraft = '';
            this.insertionModal = null;
            this.inlineConditionEditor = null;
            this.selectedNodeId = id;
        });

        // Tap exclusive edge → open inline condition editor
        cy.on('tap', 'edge', (evt) => {
            if (this._suppressNextCyTap) {
                this._suppressNextCyTap = false;
                return;
            }
            const edge = evt.target;
            if (edge.data('type') !== 'exclusive') return;
            this.selectedNodeId = null;
            this.insertionModal = null;
            this._openInlineConditionEditor(edge.id());
        });

        // Tap background → deselect everything and close inline editor
        cy.on('tap', (evt) => {
            if (evt.target !== cy) return;
            if (this._suppressNextCyTap) {
                this._suppressNextCyTap = false;
                return;
            }
            this.selectedNodeId = null;
            this.selectedEdgeId = null;
            this.conditionDraft = '';
            this.insertionModal = null;
            this.inlineConditionEditor = null;
        });

        cy.on('layoutstop', () => this.updateEdgeMidpoints());

        // Close inline editor on pan/zoom to avoid stale positioning.
        // Overlay updates are debounced via requestAnimationFrame so they don't
        // trigger a full LWC re-render on every pointer-move event during a pan.
        cy.on('pan zoom', () => {
            if (this.inlineConditionEditor) this.inlineConditionEditor = null;
            this._scheduleOverlayUpdate();
        });
    }

    // ── HTML overlay position computation ─────────────────────────────
    updateEdgeMidpoints() {
        if (!this._cy) return;
        const cy = this._cy;
        const pan = cy.pan();
        const zoom = cy.zoom();
        const scaledZoom = Math.max(0.6, Math.min(2.0, zoom));

        this.edgeMidpoints = computeEdgeMidpoints(cy, zoom, pan, scaledZoom, this.isEditMode);
        this.branchOriginButtons = computeBranchOriginButtons(cy, zoom, pan, scaledZoom, this.isEditMode);

        const { condLabels, pendingLabel } = computeConditionLabels(cy, zoom, pan, this._pendingConditionEdgeId);
        this.conditionLabels = condLabels;

        // Auto-open inline editor for a newly-created branch edge after first drop
        if (pendingLabel) {
            this._pendingConditionEdgeId = null;
            this.inlineConditionEditor = {
                edgeId: pendingLabel.edgeId,
                style: `left:${pendingLabel.rawX}px;top:${pendingLabel.rawY}px;`
            };
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            Promise.resolve().then(() => {
                const input = this.template.querySelector('.inline-cond-editor__input');
                if (input) {
                    input.value = '';
                    input.focus();
                }
            });
        }

        this.parallelNodes = computeParallelOverlays(cy, zoom, pan);
    }

    // ── Layout ────────────────────────────────────────────────────────
    runLayout(options = {}) {
        if (!this._cy) return;
        const { fitAfter, ...layoutOpts } = options;
        const layout = this._cy.layout({
            ...LAYOUT_OPTIONS,
            rankSep: this.isEditMode ? RANKSEP_EDIT : RANKSEP_READONLY,
            ...layoutOpts,
            stop: () => {
                this._cy.nodes().ungrabify();
                this._expandBranchGaps();

                const bb = this._cy.elements().boundingBox();
                if (bb && isFinite(bb.h) && bb.h > 10) {
                    const needed = Math.round(bb.h * 0.8 + 240);
                    this.cyWrapHeight = Math.min(Math.max(needed, 500), 6000);
                }

                if (this._layoutTimer) clearTimeout(this._layoutTimer);
                this._layoutTimer = setTimeout(() => {
                    this._layoutTimer = null;
                    if (!this._cy) return;
                    this._cy.resize();
                    if (fitAfter) {
                        this._cy.fit(undefined, 60);
                        // Prevent the graph from being zoomed out so far that
                        // nodes become illegibly small on load or after generate.
                        const MIN_ZOOM = 0.6;
                        if (this._cy.zoom() < MIN_ZOOM) {
                            this._cy.zoom({ level: MIN_ZOOM });
                            this._cy.center();
                        }
                    }
                    this.updateEdgeMidpoints();
                    this._refreshCounts();
                    this._refreshDiagnostics();
                }, 16);
            }
        });
        layout.run();
    }

    // Called on mousedown of any HTML overlay to suppress the Cytoscape tap
    // that would otherwise fire because cy tracks mousedown+mouseup on its container.
    suppressBackgroundTap() {
        this._suppressNextCyTap = true;
    }

    _clearOverlays() {
        this.edgeMidpoints = [];
        this.branchOriginButtons = [];
        this.conditionLabels = [];
        this.parallelNodes = [];
    }

    /**
     * Post-layout pass: pushes nodes below branching sources further down so
     * branch gaps are wide enough for condition labels + per-branch buttons,
     * while keeping sequential (non-branch) gaps compact.
     */
    _expandBranchGaps() {
        const cy = this._cy;
        if (!cy || !this.isEditMode) return;

        const BRANCH_EXTRA = 50;
        const RANK_TOLERANCE = 10;

        const allNodes = cy.nodes().toArray();
        if (allNodes.length < 2) return;
        allNodes.sort((a, b) => a.position('y') - b.position('y'));

        const ranks = [];
        let cur = { y: allNodes[0].position('y'), ids: new Set([allNodes[0].id()]) };
        for (let i = 1; i < allNodes.length; i++) {
            const y = allNodes[i].position('y');
            if (y - cur.y <= RANK_TOLERANCE) {
                cur.ids.add(allNodes[i].id());
            } else {
                ranks.push(cur);
                cur = { y, ids: new Set([allNodes[i].id()]) };
            }
        }
        ranks.push(cur);

        if (ranks.length < 2) return;

        let cumulativeShift = 0;
        for (let r = 0; r < ranks.length; r++) {
            if (cumulativeShift > 0) {
                for (const nid of ranks[r].ids) {
                    cy.getElementById(nid).position('y', cy.getElementById(nid).position('y') + cumulativeShift);
                }
            }

            let hasBranch = false;
            for (const nid of ranks[r].ids) {
                const excOut = cy
                    .getElementById(nid)
                    .outgoers('edge')
                    .filter((e) => e.data('type') === 'exclusive').length;
                if (excOut >= 2) {
                    hasBranch = true;
                    break;
                }
            }
            if (hasBranch) cumulativeShift += BRANCH_EXTRA;
        }
    }

    // Throttles overlay position recomputation to one update per animation frame.
    _scheduleOverlayUpdate() {
        if (this._rafId) return;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._rafId = requestAnimationFrame(() => {
            this._rafId = null;
            if (this._cy) this.updateEdgeMidpoints();
        });
    }

    // ── "+" button → insertion modal ──────────────────────────────────
    onPlusBtnClick(evt) {
        const { edgeid, sourceid, targetid } = evt.currentTarget.dataset;
        const containerRect = this.refs.cyContainer.getBoundingClientRect();
        const btnRect = evt.currentTarget.getBoundingClientRect();
        this.selectedNodeId = null;
        this.selectedEdgeId = null;
        this.conditionDraft = '';
        this.insertionModal = {
            x: btnRect.left - containerRect.left + btnRect.width / 2,
            y: btnRect.top - containerRect.top + btnRect.height / 2,
            edgeId: edgeid,
            sourceId: sourceid,
            targetId: targetid,
            context: 'edge'
        };
    }

    dismissModal() {
        this.insertionModal = null;
    }

    onBranchOriginClick(evt) {
        const { sourceid } = evt.currentTarget.dataset;
        const containerRect = this.refs.cyContainer.getBoundingClientRect();
        const btnRect = evt.currentTarget.getBoundingClientRect();
        this.selectedNodeId = null;
        this.selectedEdgeId = null;
        this.conditionDraft = '';
        this.insertionModal = {
            x: btnRect.left - containerRect.left + btnRect.width / 2,
            y: btnRect.top - containerRect.top + btnRect.height / 2,
            edgeId: null,
            sourceId: sourceid,
            targetId: null,
            context: 'branch-origin'
        };
    }

    // ── Modal option handlers ─────────────────────────────────────────
    handleModalStep() {
        if (!this.insertionModal) return;
        const { edgeId, sourceId, targetId, context } = this.insertionModal;
        this.insertionModal = null;
        this.selectedNodeId = null;
        this.selectedEdgeId = null;
        this.conditionDraft = '';

        if (context === 'branch-origin') {
            this._insertStepAtBranchOrigin(sourceId);
        } else {
            this._createPlaceholder(edgeId, sourceId, targetId);
        }
    }

    handleModalBranch() {
        if (!this.insertionModal) return;
        const { sourceId, edgeId } = this.insertionModal;
        this.insertionModal = null;
        if (!sourceId || sourceId === START_ID || isPlaceholder(sourceId)) {
            this.toast('Cannot add branch here', 'Click "+" on an edge from a Step node, then choose Branch.', 'warning');
            return;
        }
        this._addBranchFromNode(sourceId, edgeId);
    }

    // ── Graph-mutation operations ─────────────────────────────────────

    _createPlaceholder(edgeId, sourceId, targetId) {
        this.snapshot();
        this._clearOverlays();
        const cy = this._cy;
        cy.getElementById(edgeId).remove();
        cy.add(makePlaceholderElements(sourceId, targetId, `${PH_PREFIX}${Date.now()}__`));
        cy.nodes().ungrabify();
        this.updateEndConnections();
        this.runLayout();
        this.isDirty = true;
    }

    _insertStepAtBranchOrigin(sourceId) {
        const cy = this._cy;
        const forkNode = cy.getElementById(sourceId);
        if (!forkNode || !forkNode.length) return;

        this.snapshot();
        this._clearOverlays();

        const phId = `${PH_PREFIX}${Date.now()}__`;
        const outEdges = forkNode.outgoers('edge').filter((e) => e.data('type') === 'exclusive');
        const preserved = outEdges.map((e) => ({
            target: e.data('target'),
            condition: e.data('condition') || ''
        }));

        outEdges.remove();

        const newElements = [
            { group: 'nodes', data: { id: phId, nodeType: 'placeholder' } },
            {
                group: 'edges',
                data: {
                    id: `${sourceId}-->${phId}`,
                    source: sourceId,
                    target: phId,
                    type: 'sequential'
                }
            }
        ];
        preserved.forEach((ed) => {
            newElements.push({
                group: 'edges',
                data: {
                    id: `${phId}-->${ed.target}`,
                    source: phId,
                    target: ed.target,
                    type: 'exclusive',
                    condition: ed.condition
                }
            });
        });

        cy.add(newElements);
        cy.nodes().ungrabify();
        this.updateEndConnections();
        this.runLayout();
        this.isDirty = true;
    }

    /**
     * If any node has exactly 1 outgoing exclusive edge, demote it to
     * sequential and clear its condition — it's no longer a real fork.
     */
    _demoteSoleBranches() {
        const cy = this._cy;
        if (!cy) return;
        cy.nodes().forEach((node) => {
            const excOut = node.outgoers('edge').filter((e) => e.data('type') === 'exclusive');
            if (excOut.length === 1) {
                excOut[0].data('type', 'sequential');
                excOut[0].data('condition', '');
            }
        });
    }

    _addBranchFromNode(sourceId, clickedEdgeId = null) {
        try {
            const cy = this._cy;
            const srcNode = cy.getElementById(sourceId);
            if (!srcNode || srcNode.length === 0) {
                this.toast('Branch failed', 'Source node not found on canvas.', 'error');
                return;
            }

            this.snapshot();
            this._clearOverlays();
            this.selectedNodeId = null;

            const existingOut = srcNode.outgoers('edge').filter((e) => !isSentinel(e.data('target')));
            const isFirstFork = existingOut.length <= 1;
            const ts = Date.now();

            if (isFirstFork) {
                // Determine whether there is a real (non-sentinel) child to preserve.
                // Priority: the edge the user clicked on (modal path), then any existing
                // outgoing non-sentinel edge (sidebar "Add branch from here" path).
                let existingTargetId = null;

                if (clickedEdgeId) {
                    const clicked = cy.getElementById(clickedEdgeId);
                    if (clicked.length > 0 && !isSentinel(clicked.data('target'))) {
                        existingTargetId = clicked.data('target');
                        clicked.remove();
                    }
                } else if (existingOut.length === 1) {
                    // Sidebar path: the node already has one sequential outgoing edge.
                    // Remove it so we can replace it with an exclusive re-connection.
                    existingTargetId = existingOut[0].data('target');
                    existingOut[0].remove();
                }

                if (existingTargetId) {
                    // Preserve the existing child as the "Default" branch, add one
                    // new empty placeholder as the other branch.  This prevents the
                    // downstream sub-graph from being orphaned.
                    cy.add(makeBranchElementsPreserving(sourceId, existingTargetId, ts));
                } else {
                    // Source had no real outgoing edge (only a terminal End node) →
                    // fork into two fresh empty placeholders.
                    cy.add(makeBranchElements(sourceId, ts));
                }
            } else {
                // Already branching: append one more exclusive placeholder.
                cy.add(makeAdditionalBranchElement(sourceId, ts));
            }

            // Ensure all outgoing non-sentinel edges from this source are exclusive
            srcNode
                .outgoers('edge')
                .filter((e) => !isSentinel(e.data('target')))
                .forEach((e) => {
                    e.data('type', 'exclusive');
                    if (!e.data('condition')) e.data('condition', '');
                });

            cy.nodes().ungrabify();
            this.updateEndConnections();
            this.runLayout({ fitAfter: true });
            this.isDirty = true;
        } catch (e) {
            console.error('[Branch] ERROR:', e.message, e.stack);
            this.toast('Branch error', e.message, 'error');
        }
    }

    _assignToPlaceholder(phId, toolName) {
        this.snapshot();
        this._clearOverlays();
        const cy = this._cy;
        const stepData = buildStepFromPlaceholder(cy, phId, toolName);
        if (!stepData) return;

        const { stepId, stepNode, stepStyle, inEdges, outEdges } = stepData;
        cy.getElementById(phId).remove();
        cy.add(stepNode);
        cy.getElementById(stepId).style(stepStyle);
        inEdges.forEach((e) => {
            if (cy.getElementById(e.data.id).length === 0) cy.add(e);
        });
        outEdges.forEach((e) => {
            if (cy.getElementById(e.data.id).length === 0) cy.add(e);
        });

        cy.nodes().ungrabify();
        this.updateEndConnections();
        this.runLayout();
        this.syncGraphJson();
        this.isDirty = true;

        // Auto-open inline editor if this step sits on a conditionless exclusive branch
        const exclusiveIn = cy
            .getElementById(stepId)
            .incomers('edge')
            .filter((e) => e.data('type') === 'exclusive' && !(e.data('condition') || '').trim());
        if (exclusiveIn.length > 0) {
            this._pendingConditionEdgeId = exclusiveIn[0].id();
        }
    }

    _dropToolOnStep(stepNode, toolName) {
        const update = computeDropToolOnStep(stepNode, toolName);
        if (!update) {
            this.toast('Already in this step', `"${toolName}" is already running in parallel here. Drop it onto a different step or placeholder.`, 'warning');
            return;
        }
        this.snapshot();
        this._clearOverlays();
        stepNode.data('tools', update.tools);
        stepNode.data('label', update.label);
        stepNode.data('isParallel', update.isParallel);
        stepNode.style({ height: update.height });
        this._cy.nodes().ungrabify();
        this.updateEdgeMidpoints();
        this.syncGraphJson();
        this._refreshDiagnostics();
        this.isDirty = true;
    }

    // ── Drag-and-drop: sidebar palette → canvas ───────────────────────
    onCapabilityDragStart(evt) {
        if (!this.isEditMode) {
            evt.preventDefault();
            return;
        }
        this._draggedTool = evt.currentTarget.dataset.name;
        evt.dataTransfer.setData('text/plain', this._draggedTool);
        evt.dataTransfer.effectAllowed = 'copy';
    }

    onCanvasDragOver(evt) {
        if (!this.isEditMode) return;
        evt.preventDefault();
        const cy = this._cy;
        const target = findDropTarget(cy, this.refs.cyContainer, evt);
        cy.nodes('[nodeType="placeholder"]').data('dropTarget', 'false');
        cy.nodes('[nodeType="step"]').data('dropTarget', 'false');

        if (target) {
            const draggedTool = this._draggedTool || null;
            const adjacent = draggedTool ? getAdjacentTools(cy, target.node.id()) : new Set();
            const ownTools = JSON.parse(target.node.data('tools') || '[]');
            const parallelBlocked = target.type === 'step' && !this._parallelCallingEnabled;
            const blocked = parallelBlocked || (draggedTool && (adjacent.has(draggedTool) || ownTools.includes(draggedTool)));
            target.node.data('dropTarget', blocked ? 'blocked' : 'true');
            evt.dataTransfer.dropEffect = blocked ? 'none' : 'copy';
            this._blockedTools = [...new Set([...adjacent, ...ownTools])];
        } else {
            evt.dataTransfer.dropEffect = 'copy';
            this._blockedTools = [];
        }
    }

    onCanvasDragLeave() {
        if (!this._cy) return;
        this._cy.nodes('[nodeType="placeholder"]').data('dropTarget', 'false');
        this._cy.nodes('[nodeType="step"]').data('dropTarget', 'false');
        this._blockedTools = [];
    }

    onCanvasDrop(evt) {
        if (!this.isEditMode) return;
        evt.preventDefault();
        const name = evt.dataTransfer.getData('text/plain');
        this._blockedTools = [];
        if (!name || !this._cy) return;

        const cy = this._cy;
        cy.nodes('[nodeType="placeholder"]').data('dropTarget', 'false');
        cy.nodes('[nodeType="step"]').data('dropTarget', 'false');

        const target = findDropTarget(cy, this.refs.cyContainer, evt);
        if (!target) return;

        if (getAdjacentTools(cy, target.node.id()).has(name)) {
            this.toast(
                'Cannot place tool here',
                `"${name}" already exists in a directly-connected step. Adjacent nodes cannot share the same capability.`,
                'error'
            );
            return;
        }

        if (target.type === 'placeholder') {
            this._assignToPlaceholder(target.node.id(), name);
        } else if (!this._parallelCallingEnabled) {
            this.toast('Parallel calling disabled', 'Enable Parallel Tool Calling on the agent to run multiple tools in a single step.', 'warning');
        } else {
            this._dropToolOnStep(target.node, name);
        }
    }

    // ── Graph loading ─────────────────────────────────────────────────
    loadGraph(json, options = {}) {
        const { markClean = false, markDirty = false } = options;
        this._clearOverlays();

        // Empty / non-JSON string → clear the canvas (no parse needed)
        if (!json || !json.trim().startsWith('{')) {
            this.isDirty = markClean ? false : markDirty ? true : this.isDirty;
            this.graphJson = json || '';
            if (!this._cy) return;
            this._cy.elements().remove();
            this.addSentinels();
            this.runLayout({ animate: false, fitAfter: true });
            return;
        }

        // Validate and parse BEFORE touching the canvas so that a bad JSON string
        // never wipes the current graph or corrupts the stored graphJson value.
        let parsed;
        try {
            parsed = parseFlowJson(json);
        } catch (e) {
            this.toast('Invalid graph JSON', e.message, 'warning');
            return;
        }

        this.isDirty = markClean ? false : markDirty ? true : this.isDirty;
        this.graphJson = json;

        if (!this._cy) return;
        this._cy.elements().remove();
        this.addSentinels();

        const { rules, entry, stepGroups, toolToStepId } = parsed;

        // Create step nodes
        for (const { stepId, tools } of stepGroups) {
            const isParallel = tools.length > 1;
            this._cy.add({
                group: 'nodes',
                data: { id: stepId, nodeType: 'step', tools: JSON.stringify(tools), label: isParallel ? '' : tools[0], isParallel: String(isParallel) }
            });
            this._cy.getElementById(stepId).style({ width: 200, height: stepHeight(tools.length) });
        }

        // Add directed edges between step nodes
        for (const r of rules) {
            const srcStepId = toolToStepId.get(r.froms[0]);
            if (!srcStepId) continue;

            if (r.type === 'exclusive') {
                for (const t of r.tos) {
                    const tgtStepId = toolToStepId.get(t);
                    if (!tgtStepId || tgtStepId === srcStepId) continue;
                    const eid = `${srcStepId}-->${tgtStepId}`;
                    if (this._cy.getElementById(eid).length === 0) {
                        // For parallel target steps, find the best stored condition
                        // from any tool in that step (guards against partial saves).
                        const cond =
                            r.tos
                                .filter((tt) => toolToStepId.get(tt) === tgtStepId)
                                .map((tt) => r.conditions[tt] || '')
                                .find((c) => c) || '';
                        this._cy.add({ group: 'edges', data: { id: eid, source: srcStepId, target: tgtStepId, type: 'exclusive', condition: cond } });
                    }
                }
            } else {
                const tgtStepId = toolToStepId.get(r.tos[0]);
                if (!tgtStepId || tgtStepId === srcStepId) continue;
                const eid = `${srcStepId}-->${tgtStepId}`;
                if (this._cy.getElementById(eid).length === 0)
                    this._cy.add({ group: 'edges', data: { id: eid, source: srcStepId, target: tgtStepId, type: r.type, condition: '' } });
            }
        }

        // Fill blank conditions from LLM-generated graphs
        applyFallbackConditions(this._cy);

        // Connect entry step nodes from Start
        const seenEntrySteps = new Set();
        for (const name of entry) {
            const stepId = toolToStepId.get(name);
            if (!stepId || seenEntrySteps.has(stepId)) continue;
            seenEntrySteps.add(stepId);
            const eid = `${START_ID}-->${stepId}`;
            if (this._cy.getElementById(eid).length === 0)
                this._cy.add({ group: 'edges', data: { id: eid, source: START_ID, target: stepId, edgeType: 'sentinel' } });
        }

        this._cy.nodes().ungrabify();
        this.updateEndConnections();
        this.runLayout({ fitAfter: true });
    }

    syncGraphJson() {
        if (!this._cy) return;
        this.graphJson = buildFlowJson(this._cy, this._capabilitiesHash);
    }

    _refreshCounts() {
        if (!this._cy) {
            this._nodeCount = 0;
            this._edgeCount = 0;
            return;
        }
        this._nodeCount = this._cy.nodes().filter((n) => isStep(n.id())).length;
        this._edgeCount = this._cy.edges().filter((e) => isStep(e.data('source')) && isStep(e.data('target'))).length;
    }

    _refreshDiagnostics() {
        this.graphDiagnostics = computeGraphDiagnostics(this._cy, this.capabilities, this._parallelCallingEnabled);
    }

    // ── Inline condition editor ───────────────────────────────────────

    _openInlineConditionEditor(edgeId) {
        if (!this._cy) return;
        const label = this.conditionLabels.find((l) => l.edgeId === edgeId);
        const existing = (this._cy.getElementById(edgeId).data('condition') || '').trim();
        const style = label
            ? `left:${label.rawX}px;top:${label.rawY}px;`
            : (() => {
                  const e = this._cy.getElementById(edgeId);
                  if (!e.length) return 'left:50%;top:50%;';
                  const mp = e.midpoint();
                  const p = this._cy.pan();
                  const z = this._cy.zoom();
                  return `left:${Math.round(mp.x * z + p.x)}px;top:${Math.round(mp.y * z + p.y) - 40}px;`;
              })();

        this.inlineConditionEditor = { edgeId, style };
        // Set initial value and focus after LWC renders the uncontrolled input
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => {
            const input = this.template.querySelector('.inline-cond-editor__input');
            if (input) {
                input.value = existing;
                input.focus();
                input.select();
            }
        });
    }

    handleConditionLabelClick(evt) {
        if (!this.isEditMode) return;
        this._suppressNextCyTap = true;
        this._openInlineConditionEditor(evt.currentTarget.dataset.edgeid);
    }

    handleInlineConditionKeyup(evt) {
        if (evt.key === 'Enter') this.saveInlineCondition();
        if (evt.key === 'Escape') this.cancelInlineCondition();
    }

    saveInlineCondition() {
        if (!this.inlineConditionEditor || !this._cy) return;
        const input = this.template.querySelector('.inline-cond-editor__input');
        const value = (input ? input.value : '').trim();
        this._cy.getElementById(this.inlineConditionEditor.edgeId).data('condition', value);
        this.inlineConditionEditor = null;
        this.syncGraphJson();
        this.updateEdgeMidpoints();
        this._refreshDiagnostics();
        this.isDirty = true;
    }

    cancelInlineCondition() {
        this.inlineConditionEditor = null;
    }

    // ── Snapshot / Restore (undo–redo) ────────────────────────────────
    snapshot(push = true) {
        const s = { cyJson: this._cy ? this._cy.json() : null, graphJson: this.graphJson };
        if (push) {
            this._history.push(s);
            this._future = [];
            if (this._history.length > 50) this._history.shift();
        }
        return s;
    }

    restore(s) {
        if (s.cyJson && this._cy) {
            this._cy.json(s.cyJson);
            this._cy.nodes().ungrabify();
        }
        this.graphJson = s.graphJson;
        this.selectedNodeId = null;
        this.selectedEdgeId = null;
        this.conditionDraft = '';
        this.insertionModal = null;
        this._clearOverlays();
        this.isDirty = (this.graphJson || '') !== (this._savedJson || '');
        this.runLayout({ animate: false });
    }

    // ── Node inspector actions ────────────────────────────────────────
    addBranchFromSelected() {
        if (!this.selectedNodeId || this.selectedNodeId === START_ID) return;
        this._addBranchFromNode(this.selectedNodeId, null);
    }

    deleteEdge(evt) {
        const edgeId = evt.currentTarget.dataset.edgeid;
        if (!edgeId) return;
        this.snapshot();
        this._clearOverlays();
        this._cy.getElementById(edgeId).remove();
        this._demoteSoleBranches();
        this.updateEndConnections();
        this.isDirty = true;
        this.syncGraphJson();
        this.runLayout();
    }

    deleteSelectedNode() {
        if (!this.selectedNodeId || !this._cy) return;
        this.snapshot();
        this._clearOverlays();

        const cy = this._cy;
        const nodeId = this.selectedNodeId;
        const node = cy.getElementById(nodeId);
        if (!node || node.length === 0) return;

        const incoming = node.incomers('edge').map((e) => ({
            srcId: e.data('source'),
            type: e.data('type'),
            edgeType: e.data('edgeType'),
            condition: e.data('condition') || ''
        }));
        const outgoing = node
            .outgoers('edge')
            .filter((e) => !isEndNode(e.data('target')))
            .map((e) => ({ tgtId: e.data('target') }));

        node.remove();

        // Reparent: connect each parent directly to each child
        for (const inc of incoming) {
            for (const out of outgoing) {
                if (inc.srcId === out.tgtId) continue;
                if (!cy.getElementById(inc.srcId).length || !cy.getElementById(out.tgtId).length) continue;
                const eid = `${inc.srcId}-->${out.tgtId}`;
                if (cy.getElementById(eid).length > 0) continue;
                cy.add({
                    group: 'edges',
                    data: { id: eid, source: inc.srcId, target: out.tgtId, type: inc.type, edgeType: inc.edgeType, condition: inc.condition }
                });
            }
        }

        this.selectedNodeId = null;
        cy.nodes().ungrabify();
        this._demoteSoleBranches();
        this.updateEndConnections();
        this.isDirty = true;
        this.syncGraphJson();
        this.runLayout();
    }

    // ── Toolbar handlers ──────────────────────────────────────────────
    async handleGenerate() {
        this.isLoading = true;
        try {
            const result = await generateGraph({ agentDefId: this.recordId });
            if (result?.graphJson) {
                this.snapshot();
                this.loadGraph(result.graphJson);
                this.isDirty = true;
                this.toast('Graph generated', 'Review and save when ready.', 'success');
            } else {
                this.toast('No graph generated', result?.errorMessage || 'Agent may have no capabilities.', 'warning');
            }
        } catch (e) {
            this.toast('Generation failed', e.body?.message || e.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleSave() {
        if (this.hasIncompletePlaceholders) {
            this.toast('Finish graph edits before saving', 'One or more placeholder nodes are still empty.', 'warning');
            return;
        }
        this.syncGraphJson();
        this.isLoading = true;
        try {
            await saveGraph({ agentDefId: this.recordId, graphJson: this.graphJson });
            this._savedJson = this.graphJson;
            this.isDirty = false;
            this.isStale = false;
            this.graphWarning = null;
            this.isEditMode = false;
            this.runLayout({ animate: true, fitAfter: false });
            this.toast('Saved', 'Tool flow graph saved successfully.', 'success');
        } catch (e) {
            this.toast('Save failed', e.body?.message || e.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    handleUndo() {
        if (!this._history.length) return;
        const current = this.snapshot(false);
        this._future.push(current);
        this.restore(this._history.pop());
    }

    handleRedo() {
        if (!this._future.length) return;
        const current = this.snapshot(false);
        this._history.push(current);
        this.restore(this._future.pop());
    }

    handleFit() {
        if (this._cy) this._cy.fit(undefined, 50);
    }
    handleZoomIn() {
        if (this._cy) this._cy.zoom({ level: this._cy.zoom() * 1.25, renderedPosition: { x: this._cy.width() / 2, y: this._cy.height() / 2 } });
    }
    handleZoomOut() {
        if (this._cy) this._cy.zoom({ level: this._cy.zoom() * 0.8, renderedPosition: { x: this._cy.width() / 2, y: this._cy.height() / 2 } });
    }

    handleEditClick() {
        this.isEditMode = true;
        this.runLayout({ animate: true, fitAfter: false });
    }

    handleCancelEdit() {
        this.isEditMode = false;
        this.selectedNodeId = null;
        this.insertionModal = null;
        this.inlineConditionEditor = null;
        this.conditionDraft = '';
        if (this._savedJson !== undefined && this._savedJson !== this.graphJson) {
            this.loadGraph(this._savedJson, { markClean: true });
        } else {
            // Graph was not changed — no reload needed, but the layout must be
            // re-run at the tighter read-only rankSep.
            this.runLayout({ animate: true, fitAfter: false });
        }
        this.updateEdgeMidpoints();
    }

    handleClear() {
        if (!this._cy) return;
        // eslint-disable-next-line no-alert
        if (!window.confirm('Clear the entire graph? You can undo this with the Undo button.')) return;
        this.snapshot();
        this._cy.elements().remove();
        this.addSentinels();
        this.graphJson = '';
        this.selectedNodeId = null;
        this.selectedEdgeId = null;
        this.conditionDraft = '';
        this.insertionModal = null;
        this._clearOverlays();
        this.isDirty = true;
        this.runLayout({ animate: false, fitAfter: true });
    }

    handleJsonChange(evt) {
        // markDirty is passed so isDirty is only set to true when the JSON is
        // valid and the canvas is actually updated — not while the user is
        // mid-type with an invalid string.
        this.loadGraph(evt.detail.value, { markDirty: true });
    }

    dismissStale() {
        this.isStale = false;
        this.graphWarning = null;
    }
    toggleJson() {
        this.jsonExpanded = !this.jsonExpanded;
    }

    toast(title, message, variant = 'info') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    // ── Computed getters ──────────────────────────────────────────────
    get cannotUndo() {
        return !this._history.length;
    }
    get cannotRedo() {
        return !this._future.length;
    }
    get hasIncompletePlaceholders() {
        return this._cy ? this._cy.nodes('[nodeType="placeholder"]').length > 0 : false;
    }
    get cannotSave() {
        return this.isLoading || this.hasIncompletePlaceholders;
    }
    // Step and edge counts are maintained as @track fields updated in the layout
    // stop callback, avoiding Cytoscape iteration on every LWC render cycle.
    get nodeCount() {
        return this._nodeCount;
    }
    get edgeCount() {
        return this._edgeCount;
    }
    get nodeCountPlural() {
        return this._nodeCount !== 1;
    }
    get edgeCountPlural() {
        return this._edgeCount !== 1;
    }

    get jsonToggleIcon() {
        return this.jsonExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }
    get showInsertionModal() {
        return !!this.insertionModal;
    }
    get cyWrapStyle() {
        return `height:${this.cyWrapHeight}px;`;
    }

    get branchOptionDisabled() {
        if (!this.insertionModal) return false;
        const src = this.insertionModal.sourceId;
        return !src || src === START_ID || isPlaceholder(src);
    }
    get branchOptionClass() {
        return this.branchOptionDisabled ? 'modal-option modal-option--disabled' : 'modal-option';
    }
    get sourceAlreadyBranching() {
        if (!this.insertionModal || !this._cy) return false;
        const src = this.insertionModal.sourceId;
        if (!src || !isStep(src)) return false;
        const srcNode = this._cy.getElementById(src);
        if (!srcNode || srcNode.length === 0) return false;
        return srcNode.outgoers('edge').filter((e) => !isSentinel(e.data('target'))).length >= 2;
    }
    get isBranchOriginContext() {
        return this.insertionModal?.context === 'branch-origin';
    }
    get modalStepTitle() {
        return this.isBranchOriginContext ? 'Add Step' : 'Step';
    }
    get modalStepDesc() {
        return this.isBranchOriginContext ? 'Insert a step at this branch point' : 'Drop tools to run here';
    }
    get modalBranchTitle() {
        if (this.branchOptionDisabled) return 'Add Branch';
        return this.isBranchOriginContext || this.sourceAlreadyBranching ? 'Add Branch' : 'Branch';
    }
    get modalBranchDesc() {
        if (this.branchOptionDisabled) return 'Click "+" on an edge from a Step';
        return this.isBranchOriginContext || this.sourceAlreadyBranching ? 'Add another exclusive path' : 'Fork into exclusive paths';
    }
    get insertionModalStyle() {
        if (!this.insertionModal) return '';
        return `left:${Math.max(10, this.insertionModal.x - 105)}px;top:${Math.max(10, this.insertionModal.y + 18)}px;`;
    }

    get isReadOnlyMode() {
        return !this.isEditMode;
    }
    get showInlineConditionEditor() {
        return this.isEditMode && !!this.inlineConditionEditor;
    }
    get hasSelectedNode() {
        return !!this.selectedNodeId;
    }
    get showDefaultSidebar() {
        return !this.selectedNodeId && this.isEditMode;
    }
    get showReadOnlyInfo() {
        return !this.selectedNodeId && !this.isEditMode;
    }

    get canForkFromSelected() {
        if (!this.selectedNodeId || !this._cy) return false;
        return isStep(this.selectedNodeId) && !isSentinel(this.selectedNodeId);
    }

    get selectedNodeTools() {
        if (!this.selectedNodeId || !this._cy) return [];
        const node = this._cy.getElementById(this.selectedNodeId);
        if (!node || node.length === 0) return [];
        return JSON.parse(node.data('tools') || '[]').map((t, i) => ({ key: `${t}_${i}`, name: t }));
    }
    get selectedNodeHasMultipleTools() {
        return this.selectedNodeTools.length > 1;
    }

    get selectedNodeLabel() {
        if (!this.selectedNodeId || !this._cy) return '';
        const node = this._cy.getElementById(this.selectedNodeId);
        if (!node || node.length === 0) return this.selectedNodeId;
        const tools = JSON.parse(node.data('tools') || '[]');
        return tools.length > 0 ? tools.join(' + ') : this.selectedNodeId;
    }

    get selectedNodeEdges() {
        if (!this.selectedNodeId || !this._cy) return [];
        return this._cy
            .edges(`[source="${this.selectedNodeId}"]`)
            .filter((e) => !isSentinel(e.data('target')))
            .map((e) => {
                const tgtNode = this._cy.getElementById(e.data('target'));
                const tgtTools = tgtNode ? JSON.parse(tgtNode.data('tools') || '[]') : [];
                const toLabel = isPlaceholder(e.data('target')) ? 'placeholder' : tgtTools.length > 0 ? tgtTools.join(' + ') : e.data('target');
                return {
                    edgeId: e.id(),
                    key: e.id(),
                    toLabel,
                    typeLabel: e.data('type') || 'sequential',
                    typePill: `edge-pill edge-pill--${e.data('type') || 'sequential'}`,
                    condition: e.data('condition') || '',
                    issueText: this._edgeIssueText(e)
                };
            });
    }

    _edgeIssueText(edge) {
        if (!edge || edge.data('type') !== 'exclusive') return '';
        const condition = (edge.data('condition') || '').trim();
        if (!condition) return 'Condition required';
        if (condition === 'Default condition' || /^Condition \d+$/i.test(condition)) {
            return 'Refine condition label';
        }
        return '';
    }

    get conditionEdgeLabel() {
        if (!this.selectedEdgeId || !this._cy) return '';
        const e = this._cy.getElementById(this.selectedEdgeId);
        if (!e || e.length === 0) return '';
        const src = this._cy.getElementById(e.data('source'));
        const tgt = this._cy.getElementById(e.data('target'));
        const srcLabel = src ? JSON.parse(src.data('tools') || '["?"]')[0] : '?';
        const tgtLabel = tgt ? (isPlaceholder(tgt.id()) ? 'placeholder' : JSON.parse(tgt.data('tools') || '["?"]')[0]) : '?';
        return `${srcLabel} → ${tgtLabel}`;
    }

    get availableCapabilities() {
        const blocked = new Set(this._blockedTools || []);
        return (this.capabilities || []).map((c) => {
            const isBlocked = blocked.has(c.capabilityName);
            return {
                name: c.capabilityName,
                blocked: isBlocked,
                itemClass: isBlocked ? 'palette-item palette-item--draggable palette-item--blocked' : 'palette-item palette-item--draggable',
                title: isBlocked ? 'Already used in an adjacent step – cannot place here' : 'Drag onto the canvas'
            };
        });
    }
    get hasAvailableTools() {
        return this.availableCapabilities.length > 0;
    }
    get paletteHint() {
        return this._parallelCallingEnabled
            ? 'Drag onto a dashed placeholder — or drop a second tool onto any step to run them in parallel.'
            : 'Drag onto a dashed placeholder to assign a tool.';
    }
    get parallelLegendHint() {
        return this._parallelCallingEnabled;
    }
    get showStaleBanner() {
        return this.isStale || !!this.graphWarning;
    }
    get staleBannerMessage() {
        if (this.graphWarning) {
            return this.graphWarning;
        }
        return 'Capabilities have changed. Regenerate the graph to keep it current.';
    }
    get hasDiagnosticsWarnings() {
        return (this.graphDiagnostics?.warningCount || 0) > 0;
    }
    get diagnosticsSummary() {
        if (!this.hasDiagnosticsWarnings) return '';
        return 'Graph diagnostics: ' + this.graphDiagnostics.warnings.join('; ') + '.';
    }
}
