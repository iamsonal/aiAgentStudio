// ── Cytoscape visual style ────────────────────────────────────────────────
export const CY_STYLE = [
    // Base node fallback
    {
        selector: 'node',
        style: {
            width: 200,
            height: 52,
            shape: 'round-rectangle',
            'background-color': '#ffffff',
            'border-width': 1.5,
            'border-color': '#d0d6e0',
            label: 'data(label)',
            'font-size': '12px',
            'font-family': 'Salesforce Sans, Arial, sans-serif',
            'font-weight': '600',
            color: '#181818',
            'text-valign': 'center',
            'text-halign': 'center',
            'text-max-width': '180px',
            'text-wrap': 'wrap',
            'shadow-blur': 5,
            'shadow-color': '#00000018',
            'shadow-offset-x': 0,
            'shadow-offset-y': 2
        }
    },
    // Step node (single tool)
    {
        selector: 'node[nodeType="step"]',
        style: {
            shape: 'round-rectangle',
            'background-color': '#ffffff',
            'border-width': 1.5,
            'border-color': '#d0d6e0',
            'font-size': '12px',
            'font-weight': '600',
            color: '#181818',
            'text-valign': 'center',
            'text-halign': 'center',
            'text-max-width': '180px',
            'text-wrap': 'wrap'
        }
    },
    // Parallel step — label suppressed; chips rendered as HTML overlay
    {
        selector: 'node[nodeType="step"][isParallel="true"]',
        style: {
            label: '',
            'background-color': '#f0fbfa',
            'border-color': '#06a59a',
            'border-width': 2
        }
    },
    // Selected node
    {
        selector: 'node:selected',
        style: {
            'border-color': '#0176d3',
            'border-width': 2.5,
            'shadow-color': '#0176d340',
            'shadow-blur': 10
        }
    },
    // Placeholder (dashed grey box)
    {
        selector: 'node[nodeType="placeholder"]',
        style: {
            width: 180,
            height: 52,
            shape: 'round-rectangle',
            'background-color': '#f8f9fb',
            'border-width': 2,
            'border-style': 'dashed',
            'border-color': '#9fadb5',
            label: 'Drop tool here',
            'font-size': '11px',
            'font-style': 'italic',
            color: '#9fadb5',
            'font-weight': '500',
            'shadow-blur': 0,
            'text-wrap': 'none'
        }
    },
    // Placeholder — valid drop target
    {
        selector: 'node[nodeType="placeholder"][dropTarget="true"]',
        style: {
            'background-color': '#e8f4fd',
            'border-color': '#0176d3',
            color: '#0176d3'
        }
    },
    // Placeholder — blocked (tool already in adjacent node)
    {
        selector: 'node[nodeType="placeholder"][dropTarget="blocked"]',
        style: {
            'background-color': '#fff0f0',
            'border-color': '#c23934',
            'border-style': 'dashed',
            color: '#c23934',
            label: '✕ Not allowed here'
        }
    },
    // Step — valid drop target (append mode)
    {
        selector: 'node[nodeType="step"][dropTarget="true"]',
        style: {
            'border-color': '#06a59a',
            'border-width': 2.5,
            'shadow-color': '#06a59a40',
            'shadow-blur': 8
        }
    },
    // Step — blocked drop target
    {
        selector: 'node[nodeType="step"][dropTarget="blocked"]',
        style: {
            'border-color': '#c23934',
            'border-width': 2.5,
            'shadow-color': '#c2393440',
            'shadow-blur': 8
        }
    },
    // Start sentinel
    {
        selector: 'node[nodeType="start"]',
        style: {
            width: 84,
            height: 34,
            shape: 'round-rectangle',
            'background-color': '#2e7d32',
            'border-width': 0,
            color: '#ffffff',
            'font-size': '11px',
            'font-weight': '700',
            label: 'Start',
            'shadow-blur': 4,
            'shadow-color': '#00000025',
            'shadow-offset-x': 0,
            'shadow-offset-y': 2,
            'text-wrap': 'none'
        }
    },
    // End sentinel
    {
        selector: 'node[nodeType="end"]',
        style: {
            width: 64,
            height: 34,
            shape: 'round-rectangle',
            'background-color': '#3e3e3c',
            'border-width': 0,
            color: '#ffffff',
            'font-size': '11px',
            'font-weight': '700',
            label: 'End',
            'shadow-blur': 4,
            'shadow-color': '#00000025',
            'shadow-offset-x': 0,
            'shadow-offset-y': 2,
            'text-wrap': 'none'
        }
    },
    // Default edges
    {
        selector: 'edge',
        style: {
            width: 2,
            'line-color': '#9fadb5',
            'target-arrow-color': '#9fadb5',
            'target-arrow-shape': 'triangle',
            'arrow-scale': 0.85,
            'curve-style': 'taxi',
            'taxi-direction': 'downward',
            'taxi-turn': '60%',
            opacity: 0.85
        }
    },
    {
        selector: 'edge[type="parallel"]',
        style: { 'line-color': '#06a59a', 'target-arrow-color': '#06a59a' }
    },
    // Exclusive — no condition (grey dashed; condition label rendered as HTML overlay)
    {
        selector: 'edge[type="exclusive"]',
        style: {
            'line-color': '#a0adb5',
            'target-arrow-color': '#a0adb5',
            'line-style': 'dashed',
            'line-dash-pattern': [6, 5]
        }
    },
    // Exclusive — condition set (orange dashed)
    {
        selector: 'edge[type="exclusive"][condition!=""]',
        style: {
            'line-color': '#c45a00',
            'target-arrow-color': '#c45a00'
        }
    },
    {
        selector: 'edge[edgeType="sentinel"], edge[edgeType="end-connection"]',
        style: { 'line-color': '#b0bec5', 'target-arrow-color': '#b0bec5', width: 1.5, opacity: 0.6 }
    },
    { selector: 'edge:selected', style: { width: 3, opacity: 1 } }
];

// ── Dagre rankSep values — controls vertical distance between node ranks ─
// Edit mode needs more vertical room for "+" buttons and condition-label pills.
// Read-only mode can use tighter spacing for a more compact view.
export const RANKSEP_EDIT = 80;
export const RANKSEP_READONLY = 52;

// ── Dagre hierarchical layout options ────────────────────────────────────
export const LAYOUT_OPTIONS = {
    name: 'dagre',
    rankDir: 'TB',
    ranker: 'network-simplex',
    nodeSep: 80,
    rankSep: RANKSEP_READONLY, // overridden per-call based on edit mode
    edgeSep: 10,
    padding: 60,
    animate: true,
    animationDuration: 300,
    animationEasing: 'ease-out-cubic'
};
