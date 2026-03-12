import { stepHeight, isEndNode } from './constants.js';

const COND_GAP_PX = 36;

/**
 * Computes the position + style for every "+" button (one per edge).
 * Only populated when isEditMode is true — returns an empty array otherwise.
 *
 * @param {object} cy         - Cytoscape instance
 * @param {number} zoom       - cy.zoom()
 * @param {object} pan        - cy.pan()  { x, y }
 * @param {number} scaledZoom - clamped zoom for scaling HTML overlays
 * @param {boolean} isEditMode
 * @returns {Array<{key, edgeId, sourceId, targetId, style}>}
 */
export function computeEdgeMidpoints(cy, zoom, pan, scaledZoom, isEditMode) {
    const pts = [];
    if (!isEditMode) return pts;

    cy.edges().forEach((e) => {
        // Skip edges that originate FROM an End sentinel (shouldn't exist, but guard anyway).
        // Edges that point TO an End node are intentionally kept so the user can insert
        // a step just before the End of a branch.
        if (isEndNode(e.data('source'))) return;

        let mpx, mpy;

        if (e.data('type') === 'exclusive') {
            // Place the "+" below the condition-label pill, above the target node,
            // centered in the COND_GAP_PX gap between the pill bottom and the node top.
            // The branch-origin "+" (one per fork) is handled by computeBranchOriginButtons.
            const tgtNode = cy.getElementById(e.data('target'));
            if (tgtNode.length > 0) {
                const tgtPos = tgtNode.position();
                const tgtH = tgtNode.height() || 52;
                const targetTopScreen = (tgtPos.y - tgtH / 2) * zoom + pan.y;
                mpx = Math.round(tgtPos.x * zoom + pan.x);
                mpy = Math.round(targetTopScreen) - Math.round(COND_GAP_PX / 2);
            } else {
                const mp = e.midpoint();
                mpx = Math.round(mp.x * zoom + pan.x);
                mpy = Math.round(mp.y * zoom + pan.y);
            }
        } else {
            const mp = e.midpoint();
            mpx = Math.round(mp.x * zoom + pan.x);
            mpy = Math.round(mp.y * zoom + pan.y);
        }

        pts.push({
            key: e.id(),
            edgeId: e.id(),
            sourceId: e.data('source'),
            targetId: e.data('target'),
            style: `left:${mpx}px;top:${mpy}px;` + `transform:translate(-50%,-50%) scale(${scaledZoom});transform-origin:center;`
        });
    });
    return pts;
}

/**
 * Computes the position + style for "branch-origin" + buttons — one per
 * branching source node (a node with ≥ 2 outgoing exclusive edges).
 * Placed just below the source node, centered on its X axis.
 */
export function computeBranchOriginButtons(cy, zoom, pan, scaledZoom, isEditMode) {
    const btns = [];
    if (!isEditMode) return btns;

    const seen = new Set();
    cy.edges('[type="exclusive"]').forEach((e) => {
        const srcId = e.data('source');
        if (seen.has(srcId)) return;
        seen.add(srcId);

        const srcNode = cy.getElementById(srcId);
        if (!srcNode.length) return;

        const exclusiveCount = srcNode.outgoers('edge').filter((oe) => oe.data('type') === 'exclusive').length;
        if (exclusiveCount < 2) return;

        const srcPos = srcNode.position();
        const srcH = srcNode.height() || 52;
        const bx = Math.round(srcPos.x * zoom + pan.x);
        const by = Math.round((srcPos.y + srcH / 2) * zoom + pan.y) + 20;

        btns.push({
            key: `branch-origin-${srcId}`,
            sourceId: srcId,
            style: `left:${bx}px;top:${by}px;` + `transform:translate(-50%,-50%) scale(${scaledZoom});transform-origin:center;`
        });
    });

    return btns;
}

/**
 * Computes condition-label pill positions for every exclusive edge.
 * Labels are anchored just above the target (child) node so each badge is
 * clearly associated with the branch it annotates.
 *
 * @param {object}      cy              - Cytoscape instance
 * @param {number}      zoom            - cy.zoom()
 * @param {object}      pan             - cy.pan()  { x, y }
 * @param {string|null} pendingEdgeId   - edge whose editor should auto-open after layout
 * @returns {{ condLabels: Array, pendingLabel: object|null }}
 */
export function computeConditionLabels(cy, zoom, pan, pendingEdgeId) {
    const condLabels = [];
    let pendingLabel = null;

    cy.edges('[type="exclusive"]').forEach((e) => {
        const tgtNode = cy.getElementById(e.data('target'));
        if (!tgtNode.length) return;

        const tgtPos = tgtNode.position();
        const tgtH = tgtNode.height() || 52;
        // Centre horizontally on the target node.
        // Anchor the BOTTOM of the label 10 px above the node's top edge.
        // Single-line: 12px font × 1.4lh + 10px padding + 2px border ≈ 29px → half = 14-15px.
        const LABEL_HALF_H = 14; // half of ~28px single-line rendered height
        const GAP_PX = COND_GAP_PX;
        const lx = Math.round(tgtPos.x * zoom + pan.x);
        const ly = Math.round((tgtPos.y - tgtH / 2) * zoom + pan.y) - LABEL_HALF_H - GAP_PX;

        const cond = (e.data('condition') || '').trim();
        const cl = {
            key: `cond_${e.id()}`,
            edgeId: e.id(),
            hasCondition: !!cond,
            label: cond || '+ add condition',
            ariaLabel: cond ? `Branch condition: ${cond}` : 'Add branch condition',
            labelClass: cond ? 'cond-label cond-label--set' : 'cond-label cond-label--hint',
            style: `left:${lx}px;top:${ly}px;transform:translate(-50%,-50%);`,
            rawX: lx,
            rawY: ly
        };
        condLabels.push(cl);
        if (pendingEdgeId === e.id()) pendingLabel = cl;
    });

    return { condLabels, pendingLabel };
}

/**
 * Computes the chip-overlay position + tool list for every parallel step node
 * (steps containing more than one tool).  These are absolutely-positioned HTML
 * divs that scale with zoom to stay visually aligned with Cytoscape nodes.
 *
 * @param {object} cy   - Cytoscape instance
 * @param {number} zoom - cy.zoom()
 * @param {object} pan  - cy.pan()  { x, y }
 * @returns {Array<{key, tools, style}>}
 */
export function computeParallelOverlays(cy, zoom, pan) {
    const overlays = [];
    cy.nodes('[nodeType="step"]').forEach((n) => {
        const tools = JSON.parse(n.data('tools') || '[]');
        if (tools.length <= 1) return;

        const pos = n.position();
        const nodeH = stepHeight(tools.length);
        const sx = Math.round(pos.x * zoom + pan.x);
        const sy = Math.round(pos.y * zoom + pan.y);
        overlays.push({
            key: n.id(),
            tools: tools.map((t, i) => ({ key: `${t}_${i}`, name: t })),
            style: `left:${sx}px;top:${sy}px;width:200px;height:${nodeH}px;` + `transform:translate(-50%,-50%) scale(${zoom});transform-origin:center;`
        });
    });
    return overlays;
}
