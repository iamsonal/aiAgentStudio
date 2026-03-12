import { START_ID, PH_PREFIX, STEP_PREFIX, isSentinel, isEndNode, isStep, stepHeight, PLACEHOLDER_SNAP_RADIUS } from './constants.js';

// ── Drag-and-drop helpers ─────────────────────────────────────────────────

/**
 * Returns the set of tool names used by the immediate predecessor and successor
 * step nodes of a given node.  Used to enforce the rule that two directly-
 * connected steps cannot share the same capability.
 *
 * @param {object} cy     - Cytoscape instance
 * @param {string} nodeId
 * @returns {Set<string>}
 */
export function getAdjacentTools(cy, nodeId) {
    const adjacent = new Set();
    const node = cy.getElementById(nodeId);
    if (!node || node.length === 0) return adjacent;

    node.incomers('node').forEach((n) => {
        if (isStep(n.id())) JSON.parse(n.data('tools') || '[]').forEach((t) => adjacent.add(t));
    });
    node.outgoers('node').forEach((n) => {
        if (isStep(n.id())) JSON.parse(n.data('tools') || '[]').forEach((t) => adjacent.add(t));
    });
    return adjacent;
}

/**
 * Resolves which placeholder or step node the user is dragging onto.
 * Checks placeholders first (nearest centroid within 140 graph units),
 * then step bounding-box containment.
 *
 * @param {object}      cy        - Cytoscape instance
 * @param {HTMLElement} container - the cy-wrap DOM element (for getBoundingClientRect)
 * @param {DragEvent}   evt
 * @returns {{ type: 'placeholder'|'step', node: object }|null}
 */
export function findDropTarget(cy, container, evt) {
    const rect = container.getBoundingClientRect();
    const sx = evt.clientX - rect.left;
    const sy = evt.clientY - rect.top;
    const pan = cy.pan();
    const zoom = cy.zoom();
    const gx = (sx - pan.x) / zoom;
    const gy = (sy - pan.y) / zoom;

    let closest = null;
    let minDist = Infinity;

    cy.nodes('[nodeType="placeholder"]').forEach((n) => {
        const pos = n.position();
        const d = Math.hypot(pos.x - gx, pos.y - gy);
        if (d < minDist && d < PLACEHOLDER_SNAP_RADIUS) {
            minDist = d;
            closest = { type: 'placeholder', node: n };
        }
    });
    if (closest) return closest;

    cy.nodes('[nodeType="step"]').forEach((n) => {
        const bb = n.boundingBox();
        if (gx >= bb.x1 && gx <= bb.x2 && gy >= bb.y1 && gy <= bb.y2) {
            closest = { type: 'step', node: n };
        }
    });
    return closest;
}

// ── Element-creation helpers (pure — return element arrays, don't touch cy) ──

/**
 * Returns the Cytoscape element descriptors needed to insert a new placeholder
 * node between sourceId and targetId.
 *
 * @param {string} sourceId
 * @param {string} targetId
 * @param {string} phId     - unique placeholder ID to use
 * @returns {Array}
 */
export function makePlaceholderElements(sourceId, targetId, phId) {
    const e1Etype = sourceId === START_ID ? 'sentinel' : undefined;
    const e1Type = sourceId === START_ID ? undefined : 'sequential';

    const elements = [
        { group: 'nodes', data: { id: phId, nodeType: 'placeholder' } },
        {
            group: 'edges',
            data: {
                id: `${sourceId}-->${phId}`,
                source: sourceId,
                target: phId,
                type: e1Type,
                edgeType: e1Etype
            }
        }
    ];

    // Wire ph → target only when target is a real step/placeholder (not an End node)
    if (!isSentinel(targetId)) {
        elements.push({
            group: 'edges',
            data: {
                id: `${phId}-->${targetId}`,
                source: phId,
                target: targetId,
                type: 'sequential'
            }
        });
    }
    return elements;
}

/**
 * Returns the Cytoscape element descriptors for one branching operation where
 * there is NO existing real child to preserve (i.e. the source had no outgoing
 * real edge, or the caller already determined the target was a sentinel):
 *   → 2 new empty placeholder branches, second gets "Default condition"
 *
 * For the case where an existing real child should be preserved as one branch,
 * use makeBranchElementsPreserving instead.
 *
 * @param {string} sourceId
 * @param {number} ts - timestamp used to generate unique placeholder IDs
 * @returns {Array}
 */
export function makeBranchElements(sourceId, ts) {
    const ph1Id = `${PH_PREFIX}${ts}a__`;
    const ph2Id = `${PH_PREFIX}${ts + 1}b__`;
    return [
        { group: 'nodes', data: { id: ph1Id, nodeType: 'placeholder' } },
        { group: 'nodes', data: { id: ph2Id, nodeType: 'placeholder' } },
        { group: 'edges', data: { id: `${sourceId}-->${ph1Id}`, source: sourceId, target: ph1Id, type: 'exclusive', condition: '' } },
        { group: 'edges', data: { id: `${sourceId}-->${ph2Id}`, source: sourceId, target: ph2Id, type: 'exclusive', condition: 'Default condition' } }
    ];
}

/**
 * Returns the Cytoscape element descriptors for a branching operation where
 * the source already has a real outgoing child that must be preserved as one
 * of the exclusive paths.  One new empty placeholder is added as the other branch.
 *
 * @param {string} sourceId
 * @param {string} existingTargetId - ID of the existing child node to keep
 * @param {number} ts               - timestamp for unique placeholder ID
 * @returns {Array}
 */
export function makeBranchElementsPreserving(sourceId, existingTargetId, ts) {
    const phId = `${PH_PREFIX}${ts}a__`;
    return [
        { group: 'nodes', data: { id: phId, nodeType: 'placeholder' } },
        { group: 'edges', data: { id: `${sourceId}-->${phId}`, source: sourceId, target: phId, type: 'exclusive', condition: '' } },
        {
            group: 'edges',
            data: { id: `${sourceId}-->${existingTargetId}`, source: sourceId, target: existingTargetId, type: 'exclusive', condition: 'Default condition' }
        }
    ];
}

/**
 * Returns the Cytoscape element descriptors for adding one additional branch
 * to a source that already has ≥2 outgoing exclusive edges.
 *
 * @param {string} sourceId
 * @param {number} ts
 * @returns {Array}
 */
export function makeAdditionalBranchElement(sourceId, ts) {
    const phId = `${PH_PREFIX}${ts}c__`;
    return [
        { group: 'nodes', data: { id: phId, nodeType: 'placeholder' } },
        { group: 'edges', data: { id: `${sourceId}-->${phId}`, source: sourceId, target: phId, type: 'exclusive', condition: '' } }
    ];
}

/**
 * Reads the connectivity of a placeholder node and computes what is needed to
 * replace it with a real step node (without yet modifying the graph).
 *
 * @param {object} cy       - Cytoscape instance
 * @param {string} phId
 * @param {string} toolName
 * @returns {{ stepId, stepNode, stepStyle, inEdges, outEdges }|null}
 */
export function buildStepFromPlaceholder(cy, phId, toolName) {
    const ph = cy.getElementById(phId);
    if (!ph || ph.length === 0) return null;

    const incoming = ph.incomers('edge').map((e) => ({
        src: e.data('source'),
        type: e.data('type'),
        eType: e.data('edgeType'),
        condition: e.data('condition') || ''
    }));

    // Exclude edges going to End nodes — updateEndConnections manages those
    const outgoing = ph
        .outgoers('edge')
        .filter((e) => !isEndNode(e.data('target')))
        .map((e) => ({
            tgt: e.data('target'),
            type: e.data('type'),
            eType: e.data('edgeType'),
            condition: e.data('condition') || ''
        }));

    const stepId = `${STEP_PREFIX}${Date.now()}_${Math.random().toString(36).slice(2, 7)}`;

    const stepNode = {
        group: 'nodes',
        data: {
            id: stepId,
            nodeType: 'step',
            tools: JSON.stringify([toolName]),
            label: toolName,
            isParallel: 'false'
        }
    };

    const stepStyle = { width: 200, height: stepHeight(1) };

    const inEdges = incoming.map((e) => ({
        group: 'edges',
        data: { id: `${e.src}-->${stepId}`, source: e.src, target: stepId, type: e.type, edgeType: e.eType, condition: e.condition }
    }));

    const outEdges = outgoing.map((e) => ({
        group: 'edges',
        data: { id: `${stepId}-->${e.tgt}`, source: stepId, target: e.tgt, type: e.type, edgeType: e.eType, condition: e.condition }
    }));

    return { stepId, stepNode, stepStyle, inEdges, outEdges };
}

/**
 * Computes the data updates needed to append an additional tool to an existing
 * step node (parallel execution).  Returns null if the tool is already present.
 *
 * @param {object} stepNode - Cytoscape node element
 * @param {string} toolName
 * @returns {{ tools: string, label: string, isParallel: string, height: number }|null}
 */
export function computeDropToolOnStep(stepNode, toolName) {
    const tools = JSON.parse(stepNode.data('tools') || '[]');
    if (tools.includes(toolName)) return null;

    const newTools = [...tools, toolName];
    return {
        tools: JSON.stringify(newTools),
        label: newTools.length > 1 ? '' : newTools[0],
        isParallel: String(newTools.length > 1),
        height: stepHeight(newTools.length)
    };
}
