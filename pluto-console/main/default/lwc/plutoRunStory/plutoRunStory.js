/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';
import LOCALE from '@salesforce/i18n/locale';
import TIME_ZONE from '@salesforce/i18n/timeZone';
import getStory from '@salesforce/apex/PlutoRunStoryController.getStory';
import getStepDetail from '@salesforce/apex/PlutoRunStoryController.getStepDetail';
import { recordPage, relatedListPage } from 'c/plutoLink';
import {
    buildStory,
    collapseRoutine,
    describeCall,
    formatCost,
    formatCount,
    formatDuration,
    formatOffset,
    FILTERS,
    matchesFilter,
    isTerminal
} from 'c/plutoRunStoryModel';

const LIFECYCLE_CHANNEL = '/event/AgentLifecycleEvent__e';
const REFRESH_DEBOUNCE_MS = 700;
const POLL_MS = 10000;
// Each opened step loads its payloads; opening more at once floods Apex and the page.
const EXPAND_LIMIT = 10;
const TIME_MODE_KEY = 'plutoRunStory.timeMode';

/**
 * A model step followed straight away by two or more tool steps asked for all
 * of them in one reply. Their rows share one box: the model step heads it.
 */
function batchRoles(items) {
    const roles = new Map();
    items.forEach((item, index) => {
        if (item.type !== 'step' || item.kind !== 'model') {
            return;
        }
        let end = index + 1;
        while (items[end] && items[end].type === 'step' && items[end].kind === 'tool') {
            end++;
        }
        if (end - index - 1 < 2) {
            return;
        }
        roles.set(item.key, 'lead');
        for (let member = index + 1; member < end; member++) {
            roles.set(items[member].key, member === end - 1 ? 'end' : 'member');
        }
    });
    return roles;
}

function readTimeMode() {
    try {
        return window.localStorage.getItem(TIME_MODE_KEY) === 'offset' ? 'offset' : 'clock';
    } catch (error) {
        return 'clock';
    }
}

/**
 * The story of one Agent Run: what it did, who approved it, where its time
 * went, and what an operator should do next. Updates live while it runs.
 */
export default class PlutoRunStory extends NavigationMixin(LightningElement) {
    _recordId;
    raw;
    story;
    loading = true;
    refreshing = false;
    errorMessage;
    filter = 'all';
    expanded = new Set();
    details = {};
    // The latest request per step, so a slow older answer never replaces a newer one.
    detailRequests = {};
    updatedAt;
    liveMode = 'off';
    highlightedKey;
    // Steps the reader unfolded from a group of routine steps.
    revealed = new Set();
    selectedAttempts = {};
    expandNote = '';
    announcement = '';
    timeMode = readTimeMode();
    copyState = 'idle';
    autoFocused = false;

    subscription;
    pollTimer;
    refreshTimer;
    tickTimer;
    requestSequence = 0;
    connected = false;

    // Quick actions and record pages may set recordId after the first render.
    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        const changed = value && value !== this._recordId;
        this._recordId = value;
        if (changed) {
            this.autoFocused = false;
        }
        if (changed && this.connected) {
            this.load();
        }
    }

    connectedCallback() {
        this.connected = true;
        if (this._recordId) {
            this.load();
        }
    }

    disconnectedCallback() {
        this.connected = false;
        this.stopLive();
        clearTimeout(this.refreshTimer);
    }

    // ------------------------------------------------------------ data

    async load({ quiet = false } = {}) {
        const sequence = ++this.requestSequence;
        if (quiet) {
            this.refreshing = true;
        } else {
            this.loading = !this.story;
        }
        try {
            const data = await getStory({ runId: this._recordId });
            if (sequence !== this.requestSequence) {
                return;
            }
            const previousStatus = this.story?.header?.status;
            this.raw = data;
            this.story = buildStory(data, Date.now());
            this.errorMessage = undefined;
            this.updatedAt = Date.now();
            this.announceChange(previousStatus);
            this.dropStaleDetails();
            this.openFocusOnce();
            this.syncLive();
        } catch (error) {
            if (sequence === this.requestSequence) {
                // Apex errors carry a sentence written for the reader; anything else is a transport failure.
                this.errorMessage = error?.body?.message || "Salesforce couldn't be reached. Check your connection, then try again.";
            }
        } finally {
            if (sequence === this.requestSequence) {
                this.loading = false;
                this.refreshing = false;
            }
        }
    }

    /** Tells screen readers when the run moves to another status; routine refreshes stay quiet. */
    announceChange(previousStatus) {
        const { status } = this.story.header;
        if (!previousStatus || previousStatus === status) {
            return;
        }
        const reason = this.story.attention ? ` ${this.story.attention.title}.` : '';
        this.announcement = `The run is now ${status}.${reason}`;
    }

    /** On first load, open the step that needs attention so the operator lands on the cause. */
    openFocusOnce() {
        if (this.autoFocused) {
            return;
        }
        this.autoFocused = true;
        const step = this.focusStep;
        if (step && !this.expanded.has(step.commandId)) {
            this.toggle(step.commandId, true);
        }
    }

    get focusStep() {
        const key = this.story?.attention?.focusKey;
        const item = key ? this.story.timeline.find((entry) => entry.key === key) : null;
        return item && item.type === 'step' ? item : null;
    }

    /**
     * Steps still in progress may change, so open ones reload while the reader
     * keeps seeing what was loaded before; closed ones forget their payloads.
     */
    dropStaleDetails() {
        const settled = new Set(this.story.timeline.filter((item) => item.type === 'step' && !item.isRunning && !item.isCurrent).map((item) => item.commandId));
        const kept = {};
        Object.keys(this.details).forEach((commandId) => {
            if (settled.has(commandId) || this.expanded.has(commandId)) {
                kept[commandId] = this.details[commandId];
            }
        });
        this.details = kept;
        this.expanded.forEach((commandId) => {
            if (!kept[commandId] || !settled.has(commandId)) {
                this.fetchDetail(commandId);
            }
        });
    }

    async fetchDetail(commandId) {
        const previous = this.details[commandId];
        const shown = previous && !previous.loading && !previous.error ? previous : null;
        const request = (this.detailRequests[commandId] || 0) + 1;
        this.detailRequests[commandId] = request;
        if (!shown) {
            this.details = { ...this.details, [commandId]: { loading: true } };
        }
        try {
            const detail = await getStepDetail({ commandId });
            if (this.detailRequests[commandId] === request) {
                this.details = { ...this.details, [commandId]: { loading: false, ...detail } };
            }
        } catch (error) {
            if (this.detailRequests[commandId] === request && !shown) {
                this.details = {
                    ...this.details,
                    [commandId]: { loading: false, error: error?.body?.message || 'This step could not be loaded.' }
                };
            }
        }
    }

    // ------------------------------------------------------------ live updates

    syncLive() {
        if (!this.story || isTerminal(this.story.header.status)) {
            this.stopLive();
            this.liveMode = 'off';
            return;
        }
        this.startTicking();
        if (this.subscription || this.pollTimer) {
            return;
        }
        this.subscribeToLifecycle();
    }

    async subscribeToLifecycle() {
        try {
            const enabled = await isEmpEnabled();
            if (!enabled) {
                this.startPolling();
                return;
            }
            onError(() => this.startPolling());
            this.subscription = await subscribe(LIFECYCLE_CHANNEL, -1, (message) => {
                const payload = message?.data?.payload || {};
                if (payload.RunId__c === this._recordId) {
                    this.scheduleRefresh();
                }
            });
            this.liveMode = 'stream';
        } catch (error) {
            this.startPolling();
        }
    }

    startPolling() {
        if (this.subscription) {
            unsubscribe(this.subscription, () => {});
            this.subscription = undefined;
        }
        if (this.pollTimer) {
            return;
        }
        this.liveMode = 'poll';
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.pollTimer = setInterval(() => {
            if (document.visibilityState !== 'hidden') {
                this.load({ quiet: true });
            }
        }, POLL_MS);
    }

    /** Keeps waiting and paused durations current between updates. */
    startTicking() {
        if (this.tickTimer) {
            return;
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.tickTimer = setInterval(() => {
            if (this.raw) {
                this.story = buildStory(this.raw, Date.now());
            }
        }, 30000);
    }

    scheduleRefresh() {
        clearTimeout(this.refreshTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.refreshTimer = setTimeout(() => this.load({ quiet: true }), REFRESH_DEBOUNCE_MS);
    }

    stopLive() {
        if (this.subscription) {
            unsubscribe(this.subscription, () => {});
            this.subscription = undefined;
        }
        clearInterval(this.pollTimer);
        clearInterval(this.tickTimer);
        this.pollTimer = undefined;
        this.tickTimer = undefined;
    }

    // ------------------------------------------------------------ view state

    get hasStory() {
        return Boolean(this.story);
    }

    get showSpinner() {
        return this.loading && !this.story;
    }

    get header() {
        return this.story.header;
    }

    get headClass() {
        return `head head_${this.header.tone}`;
    }

    get headline() {
        return this.story.outcome?.headline || '';
    }

    get statusClass() {
        return `status status_${this.header.tone}`;
    }

    get highlights() {
        return this.story.highlights.map((highlight) => ({
            ...highlight,
            className: `highlight highlight_${highlight.tone}`,
            actionLabel: `${highlight.label}. Show the step.`
        }));
    }

    get agentPage() {
        return this.header.agentId ? recordPage(this.header.agentId, 'AgentDefinition__c') : null;
    }

    get identityPage() {
        return this.header.identityId ? recordPage(this.header.identityId, 'AgentExecutionIdentity__c') : null;
    }

    get anchorPage() {
        return this.header.anchorId ? recordPage(this.header.anchorId) : null;
    }

    get startedByPage() {
        return this.header.startedById ? recordPage(this.header.startedById, 'User') : null;
    }

    get parentPage() {
        return this.header.parentRunId ? recordPage(this.header.parentRunId, 'AgentRun__c') : null;
    }

    get parentLabel() {
        return `Parent run ${this.header.parentRunName || ''}`.trim();
    }

    get startedText() {
        return this.header.startedAt ? this.formatMoment(this.header.startedAt, true) : '';
    }

    /**
     * One tile per measure. A limit the agent sets is shown on the tile it limits,
     * so tokens appear once even when the agent caps them.
     */
    get kpis() {
        const header = this.header;
        const limits = Object.fromEntries(header.budgets.map((entry) => [entry.key, entry]));
        const share = header.elapsedMs && header.activeMs ? (header.activeMs / header.elapsedMs) * 100 : null;
        const tokens = limits.tokens;
        const tokenNotes = [
            tokens ? this.limitNote(tokens, tokens.label !== 'Tokens') : '',
            header.unmeteredAttempts ? `${formatCount(header.unmeteredAttempts)} estimated` : ''
        ];
        return [
            this.tile(
                'elapsed',
                this.story.isLive ? 'Elapsed so far' : 'Elapsed',
                formatDuration(header.elapsedMs),
                'From start to finish, including waiting.'
            ),
            this.tile(
                'active',
                'Working time',
                formatDuration(header.activeMs),
                'Time spent in model and tool calls. The rest was waiting, approvals, pauses, or queueing.',
                share === null ? '' : `${share >= 1 ? Math.round(share) : '<1'}% of elapsed`
            ),
            this.limitTile(limits.modelCalls, 'Max Model Calls'),
            this.limitTile(limits.toolCalls, 'Max Tool Calls'),
            {
                ...this.tile(
                    'tokens',
                    'Tokens',
                    header.tokens ? formatCount(header.tokens) : '',
                    'Model input and output tokens. An attempt that timed out or failed reports no usage, so Agent Core estimates its input and counts it.' +
                        (tokens ? ' The limit is Max Total Tokens on the agent.' : ''),
                    tokenNotes.filter(Boolean).join(' · ')
                ),
                ...(tokens ? this.limitState(tokens) : {})
            },
            this.tile('cost', 'Estimated cost', formatCost(header.cost), 'Estimated from the prices on the Agent Model.')
        ];
    }

    tile(key, label, value, hint, note = '') {
        return { key, label, value: value || '—', hint, note, valueClass: 'kpi-value', isFull: false, meter: null };
    }

    /** A counter the agent limits: the count, how much of the limit it used, and a meter. */
    limitTile(entry, field) {
        const tile = this.tile(entry.key, entry.label, formatCount(entry.used), `Counts against ${field} on the agent.`, this.limitNote(entry, false));
        return { ...tile, ...this.limitState(entry) };
    }

    limitNote(entry, showUsed) {
        if (entry.max === null) {
            return 'No limit';
        }
        return showUsed ? `${formatCount(entry.used)} of ${formatCount(entry.max)} this reply` : `of ${formatCount(entry.max)} allowed`;
    }

    limitState(entry) {
        if (entry.max === null) {
            return {};
        }
        return {
            valueClass: `kpi-value kpi-value_${entry.tone}`,
            isFull: entry.tone === 'full',
            meter: {
                max: entry.max,
                used: entry.used,
                barClass: `meter-fill meter-fill_${entry.tone}`,
                barStyle: `width: ${Math.max(entry.percent, entry.used ? 3 : 0)}%`,
                assistiveText: `${entry.label}: ${entry.used} of ${entry.max} used`
            }
        };
    }

    get attention() {
        return this.story.attention;
    }

    get attentionClass() {
        return `attention attention_${this.attention.tone}`;
    }

    get attentionRole() {
        return this.attention.tone === 'error' ? 'alert' : 'status';
    }

    get approvalPage() {
        return this.attention?.approvalId ? recordPage(this.attention.approvalId, 'AgentApproval__c') : null;
    }

    get showFocusLink() {
        return Boolean(this.attention?.focusKey);
    }

    /** A failed run can't be rescued; its cause is usually the agent's setup. */
    get attentionAgentPage() {
        return this.header.status === 'Failed' ? this.agentPage : null;
    }

    get canCopyDiagnostics() {
        return this.attention && (this.attention.tone === 'error' || this.attention.tone === 'warning');
    }

    get copyLabel() {
        return { copied: 'Copied', failed: "Couldn't copy" }[this.copyState] || 'Copy details';
    }

    get copyIcon() {
        return { copied: 'utility:check', failed: 'utility:warning' }[this.copyState] || 'utility:copy';
    }

    /** Identifiers an admin or support engineer needs, with no payloads. */
    get diagnostics() {
        const header = this.header;
        const step = this.focusStep;
        return [
            `Agent run: ${header.runName} (${this._recordId})`,
            header.agentName ? `Agent: ${header.agentName} (${header.agentId})` : '',
            `Status: ${header.status}`,
            this.attention.code ? `Error: ${this.attention.code}` : '',
            this.attention.message || this.attention.detail ? `Message: ${this.attention.message || this.attention.detail}` : '',
            step ? `Step: ${step.title} (${step.commandId})` : '',
            header.startedAt ? `Started: ${new Date(header.startedAt).toISOString()}` : ''
        ]
            .filter(Boolean)
            .join('\n');
    }

    get hasSegments() {
        return this.story.segments.length > 0;
    }

    get segments() {
        // The legend below is the accessible way in; the bar is a pointer shortcut.
        return this.story.segments.map((segment) => ({
            ...segment,
            className: `segment segment_${segment.kind}${segment.targetKey ? ' segment_link' : ''}`,
            style: `left: ${segment.left}%; width: max(${segment.width}%, 3px);`,
            label: `${this.segmentLabel(segment.kind)}: ${segment.durationText}`,
            isLink: Boolean(segment.targetKey)
        }));
    }

    get breakdown() {
        return this.story.timeBreakdown.map((entry) => {
            const longest = this.story.segments
                .filter((segment) => segment.kind === entry.kind && segment.targetKey)
                .reduce((best, segment) => (!best || segment.to - segment.from > best.to - best.from ? segment : best), null);
            const percentText = entry.percent >= 1 ? `${Math.round(entry.percent)}%` : '<1%';
            return {
                ...entry,
                swatchClass: `swatch swatch_${entry.kind}`,
                percentText,
                targetKey: longest ? longest.targetKey : null,
                actionLabel: `${entry.label}: ${entry.text}, ${percentText}. Show the longest one.`
            };
        });
    }

    get outcome() {
        return this.story.outcome;
    }

    get showAskedOnly() {
        return this.outcome && !this.outcome.hasOutput;
    }

    /** A plain-text answer is already the headline, so it is not shown twice. */
    get showAnswer() {
        return this.outcome.hasOutput && this.outcome.output !== this.outcome.headline;
    }

    get filters() {
        return FILTERS.map((entry) => {
            const count = this.story.counts[entry.value] || 0;
            const active = this.filter === entry.value;
            return {
                ...entry,
                count,
                active: String(active),
                className: `filter${active ? ' filter_active' : ''}${entry.value === 'issue' && count ? ' filter_issue' : ''}`,
                disabled: entry.value !== 'all' && count === 0
            };
        });
    }

    get visibleSteps() {
        return this.story.timeline.filter((item) => item.type === 'step' && matchesFilter(item, this.filter));
    }

    /** Open as many shown steps as Expand all would; the step opened on load alone doesn't count. */
    get allExpanded() {
        const steps = this.visibleSteps;
        const open = steps.filter((item) => this.expanded.has(item.commandId)).length;
        return open > 0 && open >= Math.min(steps.length, EXPAND_LIMIT);
    }

    get expandLabel() {
        return this.allExpanded ? 'Collapse all' : 'Expand all';
    }

    /** Steps that never fold: the ones the reader opened or is being pointed at. */
    get pinnedKeys() {
        const keep = new Set(this.expanded);
        if (this.highlightedKey) {
            keep.add(this.highlightedKey);
        }
        return keep;
    }

    /** Offered only when folding would hide a step the reader unfolded. */
    get canRefold() {
        if (this.filter !== 'all' || !this.revealed.size) {
            return false;
        }
        const pinned = this.pinnedKeys;
        const shown = collapseRoutine(this.story.timeline, new Set([...pinned, ...this.revealed]));
        return collapseRoutine(this.story.timeline, pinned).length < shown.length;
    }

    get timeline() {
        let items = this.story.timeline.filter((item) => matchesFilter(item, this.filter));
        if (this.filter === 'all') {
            items = collapseRoutine(items, new Set([...this.pinnedKeys, ...this.revealed]));
        }
        const batches = batchRoles(items);
        return items.map((item, index) => this.decorate(item, index === items.length - 1, batches.get(item.key)));
    }

    get relatedStepsPage() {
        return relatedListPage(this._recordId, 'AgentRun__c', 'Commands__r');
    }

    get timeModeLabel() {
        return this.timeMode === 'offset' ? 'Show clock time' : 'Show time from start';
    }

    get emptyFilter() {
        return this.timeline.length === 0;
    }

    get liveText() {
        if (!this.story?.isLive) {
            return '';
        }
        return this.liveMode === 'stream' ? 'Live' : 'Auto-refresh';
    }

    get updatedText() {
        if (this.refreshing) {
            return 'Updating…';
        }
        if (!this.updatedAt) {
            return '';
        }
        return `Updated ${this.formatMoment(this.updatedAt, false)}`;
    }

    /** The stream pushes every change, so a manual refresh only matters while polling or finished. */
    get showRefresh() {
        return !(this.story?.isLive && this.liveMode === 'stream');
    }

    get refreshDisabled() {
        return this.refreshing || this.loading;
    }

    decorate(item, isLast, batchRole) {
        const batchClass = batchRole === 'lead' ? ' row_batch row_batch-start row_batch-lead' : batchRole ? ` row_batch row_batch-${batchRole}` : '';
        const base = {
            ...item,
            isStep: item.type === 'step',
            isMarker: item.type === 'marker',
            isGap: item.type === 'gap',
            isGroup: item.type === 'group',
            revealLabel: item.type === 'group' ? `Show ${item.stepKeys.length} steps` : '',
            timeText: item.at ? this.formatWhen(item.at) : '',
            timeTitle: item.at ? this.formatMoment(item.at, true) : '',
            rowClass: `row row_${item.type} row_${item.kind || ''}${batchClass}${isLast ? ' row_last' : ''}${this.highlightedKey === item.key ? ' row_flash' : ''}`,
            nodeClass: `node node_${item.tone || 'neutral'}${item.isNow ? ' node_now' : ''}`
        };
        if (item.type !== 'step') {
            return base;
        }
        const open = this.expanded.has(item.commandId);
        const detail = this.details[item.commandId];
        return {
            ...base,
            open,
            ariaExpanded: String(open),
            panelId: `panel-${item.commandId}`,
            kindLabel: item.kind === 'model' ? 'Model' : 'Tool',
            chevron: open ? 'utility:chevrondown' : 'utility:chevronright',
            cardClass: `card card_${item.tone}${item.isCurrent ? ' card_current' : ''}${open ? ' card_open' : ''}`,
            badgeClass: `badge badge_${item.tone}`,
            showStatus: item.status !== 'Succeeded',
            approvals: item.approvals.map((approval) => ({
                ...approval,
                pageReference: recordPage(approval.id, 'AgentApproval__c'),
                linkLabel: approval.name ? `Open ${approval.name}` : 'Open approval',
                className: `approval approval_${approval.tone}`,
                icon:
                    approval.status === 'Approved'
                        ? 'utility:check'
                        : approval.status === 'Rejected'
                          ? 'utility:close'
                          : approval.status === 'Pending'
                            ? 'utility:clock'
                            : 'utility:dash',
                who: this.approvalRecipient(approval),
                decidedText: approval.closedAt
                    ? `${approval.status === 'Approved' || approval.status === 'Rejected' ? 'Decided' : approval.status} ${this.formatMoment(approval.closedAt, false)}`
                    : '',
                commentTitle: `${approval.decidedBy || 'The approver'} wrote this when deciding`
            })),
            detailLoading: Boolean(detail?.loading),
            detailError: detail?.error,
            detailReady: Boolean(detail) && !detail.loading && !detail.error,
            detailInput: detail?.input,
            detailOutput: detail?.output,
            detailHidden: detail?.payloadHidden,
            detailPurged: Boolean(detail?.payloadPurgedAt) || item.payloadPurged,
            toolIds: detail?.toolIds,
            hasAttempts: (detail?.attempts || []).length > 1 || (detail?.attempts || []).some((attempt) => attempt.ErrorCode__c),
            ...this.callsFor(item, detail)
        };
    }

    approvalRecipient(approval) {
        if (!approval.owner) {
            return 'Sent to the approver';
        }
        return approval.approverType === 'Queue' ? `Sent to the ${approval.owner} queue` : `Sent to ${approval.owner}`;
    }

    /**
     * Evidence for the step's latest attempts. One attempt shows at a time; the
     * attempts table picks which, and the newest is shown first.
     */
    callsFor(item, detail) {
        if (!detail || detail.loading || detail.error) {
            return { calls: [], hasCalls: false, attempts: [], canPickAttempt: false, showCommandPayloads: item.kind === 'tool' };
        }
        const attempts = detail.attempts || [];
        const evidence = [...(detail.evidence || [])].sort((a, b) => (a.AttemptNumber__c || 0) - (b.AttemptNumber__c || 0));
        const calls = evidence.map((record, index) => {
            const attempt = attempts.find((candidate) => candidate.AttemptNumber__c === record.AttemptNumber__c);
            // Attempts are counted among the calls that ran; Core's attempt number also counts dispatches that paused first.
            const ordinal = attempts.indexOf(attempt) + 1;
            return {
                ...describeCall(attempt, record),
                heading: attempts.length > 1 && ordinal > 0 ? `Attempt ${ordinal} of ${attempts.length}` : item.kind === 'model' ? 'Model call' : 'Tool call',
                expanded: index === evidence.length - 1
            };
        });
        const hasCalls = calls.some((call) => call.hasEvidence);
        const withEvidence = new Set(evidence.map((record) => record.AttemptNumber__c));
        const canPickAttempt = calls.length > 1;
        const newest = evidence.length ? evidence[evidence.length - 1].AttemptNumber__c : null;
        const chosen = this.selectedAttempts[item.commandId];
        const selected = withEvidence.has(chosen) ? chosen : newest;
        const visible = canPickAttempt ? calls.filter((call, index) => evidence[index].AttemptNumber__c === selected) : calls;
        return {
            calls: visible.map((call) => ({ ...call, expanded: true })),
            canPickAttempt,
            attempts: attempts.map((attempt, index) => {
                const isSelected = attempt.AttemptNumber__c === selected;
                return {
                    key: attempt.Id,
                    number: index + 1,
                    attemptNumber: attempt.AttemptNumber__c,
                    outcome: attempt.Outcome__c,
                    outcomeClass: `attempt-outcome attempt-outcome_${(attempt.Outcome__c || '').replace(/\s+/g, '').toLowerCase()}`,
                    when: attempt.StartedAt__c ? this.formatWhen(Date.parse(attempt.StartedAt__c)) : '',
                    duration: formatDuration(attempt.DurationMs__c),
                    error: [attempt.ErrorCode__c, attempt.ErrorMessage__c].filter(Boolean).join(': '),
                    requestId: attempt.ProviderRequestId__c,
                    hasEvidence: withEvidence.has(attempt.AttemptNumber__c),
                    selected: String(isSelected),
                    viewLabel: isSelected ? 'Showing' : 'Show',
                    viewTitle: `Show the evidence for attempt ${index + 1}`,
                    rowClass: isSelected && canPickAttempt ? 'attempt attempt_selected' : 'attempt'
                };
            }),
            hasCalls,
            evidenceHidden: Boolean(detail.evidenceHidden),
            evidenceLimited: attempts.length > evidence.length && evidence.length > 0,
            // Model steps read better from the prompt itself; fall back to the command payloads without it.
            showCommandPayloads: item.kind === 'tool' || !hasCalls
        };
    }

    segmentLabel(kind) {
        return { model: 'Model', tool: 'Tool', approval: 'Waiting for approval', paused: 'Paused', other: 'Queueing and overhead' }[kind] || kind;
    }

    /** A row's time: clock time, or time since the run started when the reader prefers offsets. */
    formatWhen(epoch) {
        const start = this.story?.header?.startedAt;
        if (this.timeMode === 'offset' && start) {
            return formatOffset(epoch - start);
        }
        return this.formatMoment(epoch, false);
    }

    formatMoment(epoch, withDate) {
        const options = { hour: 'numeric', minute: '2-digit', second: '2-digit', timeZone: TIME_ZONE };
        const date = new Date(epoch);
        const start = this.story?.header?.startedAt;
        const sameDay = start && new Date(start).toDateString() === date.toDateString();
        if (withDate || !sameDay) {
            Object.assign(options, { month: 'short', day: 'numeric' });
        }
        try {
            return new Intl.DateTimeFormat(LOCALE, options).format(date);
        } catch (error) {
            return date.toLocaleString();
        }
    }

    // ------------------------------------------------------------ handlers

    handleRefresh() {
        this.load({ quiet: true });
    }

    handleFilter(event) {
        const value = event.currentTarget.dataset.value;
        this.filter = this.filter === value && value !== 'all' ? 'all' : value;
    }

    handleToggle(event) {
        this.toggle(event.currentTarget.dataset.command);
    }

    toggle(commandId, forceOpen) {
        const next = new Set(this.expanded);
        const open = forceOpen === undefined ? !next.has(commandId) : forceOpen;
        if (open) {
            next.add(commandId);
            if (!this.details[commandId]) {
                this.fetchDetail(commandId);
            }
        } else {
            next.delete(commandId);
        }
        this.expanded = next;
    }

    handleExpandAll() {
        this.expandNote = '';
        if (this.allExpanded) {
            this.expanded = new Set();
            return;
        }
        const steps = this.visibleSteps;
        steps.slice(0, EXPAND_LIMIT).forEach((item) => this.toggle(item.commandId, true));
        if (steps.length > EXPAND_LIMIT) {
            this.expandNote = `Opened the first ${EXPAND_LIMIT} of ${steps.length} steps. Open the others one at a time.`;
        }
    }

    handleSegment(event) {
        this.showStep(event.currentTarget.dataset.target);
    }

    handleShowFocus() {
        this.showStep(this.attention?.focusKey);
    }

    handleRevealGroup(event) {
        const group = this.timeline.find((item) => item.key === event.currentTarget.dataset.key);
        if (group) {
            this.revealed = new Set([...this.revealed, ...group.stepKeys]);
            // The button is gone once the group opens, so focus moves to the first step it held.
            this.focusAfterRender(`[data-key="${group.stepKeys[0]}"] .card-head`);
        }
    }

    handleRefold() {
        this.revealed = new Set();
        this.focusAfterRender('.expand-all');
    }

    focusAfterRender(selector) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const target = this.template.querySelector(selector);
            if (target) {
                target.focus();
            }
        });
    }

    handleTimeMode() {
        this.timeMode = this.timeMode === 'offset' ? 'clock' : 'offset';
        try {
            window.localStorage.setItem(TIME_MODE_KEY, this.timeMode);
        } catch (error) {
            // Storage can be blocked; the choice then lasts for this view only.
        }
    }

    handleSelectAttempt(event) {
        const { command, attempt } = event.currentTarget.dataset;
        this.selectedAttempts = { ...this.selectedAttempts, [command]: Number(attempt) };
    }

    async handleCopyDiagnostics() {
        try {
            await navigator.clipboard.writeText(this.diagnostics);
            this.copyState = 'copied';
        } catch (error) {
            this.copyState = 'failed';
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.copyState = 'idle';
        }, 2000);
    }

    /** Opens a step (or reveals a marker), scrolls to it, and briefly highlights it. */
    showStep(key) {
        if (!key) {
            return;
        }
        this.filter = 'all';
        // A folded step stays unfolded after the reader closes it; one already shown needs nothing.
        if (!this.timeline.some((item) => item.key === key)) {
            this.revealed = new Set([...this.revealed, key]);
        }
        const step = this.story.timeline.find((item) => item.key === key);
        if (step && step.type === 'step') {
            this.toggle(step.commandId, true);
        }
        this.flash(key);
    }

    flash(key) {
        this.highlightedKey = key;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            const row = this.template.querySelector(`[data-key="${key}"]`);
            if (row) {
                row.scrollIntoView({ behavior: 'smooth', block: 'center' });
                row.focus({ preventScroll: true });
            }
        });
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (this.highlightedKey === key) {
                this.highlightedKey = undefined;
            }
        }, 1600);
    }

    handleOperate() {
        const background = encodeURIComponent(`/lightning/r/AgentRun__c/${this._recordId}/view`);
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: {
                url: `/lightning/action/quick/AgentRun__c.Operate?objectApiName&context=RECORD_DETAIL&recordId=${this._recordId}&backgroundContext=${background}`
            }
        });
    }
}
