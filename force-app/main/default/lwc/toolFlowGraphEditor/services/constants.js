// ── Node / edge ID constants ──────────────────────────────────────────────
export const START_ID = '__START__';
export const END_PREFIX = '__end_';
export const EMPTY_END_ID = `${END_PREFIX}start__`;
export const SENTINEL_EMPTY = '__s2e__';
export const PH_PREFIX = '__ph_';
export const STEP_PREFIX = 'step_';

// ── Node-type predicates ──────────────────────────────────────────────────
export const isEndNode = (id) => id != null && id.startsWith(END_PREFIX);
export const isSentinel = (id) => id === START_ID || isEndNode(id);
export const isPlaceholder = (id) => id != null && id.startsWith(PH_PREFIX);
export const isStep = (id) => id != null && id.startsWith(STEP_PREFIX);
// Overlay = anything that is NOT a real tool step (sentinel or placeholder)
export const isOverlay = (id) => isSentinel(id) || isPlaceholder(id);

// ── Flow-rule helpers ─────────────────────────────────────────────────────
// Normalise a flow-rule's fromTools/toTools — LLM sometimes uses 'from'/'to'
export const normaliseArr = (v) => (Array.isArray(v) ? v : v != null && v !== '' ? [String(v)] : []);

export const VALID_TYPES = new Set(['sequential', 'parallel', 'exclusive']);

// ── Node sizing ───────────────────────────────────────────────────────────
// Step node height: 36px base + 26px per tool, minimum 52px
export const stepHeight = (toolCount) => Math.max(52, 36 + toolCount * 26);

// ── Drag-and-drop thresholds ──────────────────────────────────────────────
// Maximum graph-unit distance from a placeholder centroid that counts as a drop
export const PLACEHOLDER_SNAP_RADIUS = 140;
