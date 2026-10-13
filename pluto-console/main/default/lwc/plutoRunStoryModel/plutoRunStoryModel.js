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

/**
 * Turns one Agent Run's records into the story plutoRunStory renders.
 *
 * Pure functions only: no Apex, no DOM. The controller returns commands,
 * invocations, approvals, and events without payloads; this module orders
 * them into one timeline, explains pauses in plain language, and accounts
 * for where the run's time went.
 */

import { explain } from 'c/agentRunGuide';

export { explain };

const TERMINAL = new Set(['Succeeded', 'Failed', 'Cancelled']);
const TERMINAL_COMMANDS = new Set(['Succeeded', 'Failed', 'Unknown', 'Cancelled']);
const GAP_THRESHOLD_MS = 60 * 1000;

const STATUS_TONES = {
    Running: 'info',
    Waiting: 'waiting',
    Paused: 'warning',
    Succeeded: 'success',
    Failed: 'error',
    // Someone stopped the agent before it finished, which a glance must not read as done.
    Cancelled: 'warning'
};

const COMMAND_TONES = {
    Succeeded: 'success',
    Failed: 'error',
    Unknown: 'error',
    Cancelled: 'neutral',
    Waiting: 'waiting',
    'Retry Waiting': 'warning',
    Leased: 'info',
    Pending: 'neutral',
    Blocked: 'neutral'
};

const APPROVAL_TONES = {
    Pending: 'waiting',
    Approved: 'success',
    Rejected: 'error',
    Expired: 'warning',
    Cancelled: 'neutral'
};

/** Tool failures that are really an approval's outcome: the step takes the approval's label and tone. */
const DECLINED = {
    TOOL_APPROVAL_DENIED: { approvalStatus: 'Rejected', label: 'Rejected', outcome: 'The tool did not run. The agent was told and continued without it.' },
    TOOL_APPROVAL_EXPIRED: { approvalStatus: 'Expired', label: 'Not run', outcome: 'The tool did not run because no one decided in time.' }
};

/** Events that create or precede a step rather than describe it, so they never anchor its position. */
const LEADING_EVENTS = new Set(['Run Rescued', 'Configuration Changed']);

/** What each rescue mode did, given the step it acted on, as the end of "User User raised Max Tool Calls and …". */
const RESCUE_MODES = {
    rearm_failed: (step) => `retried ${step}`,
    rearm_queued: (step) => `restarted ${step}`,
    reflect_new_model: () => 'resumed the run'
};

/** A change list longer than this names the first ones and counts the rest. */
const CHANGES_SHOWN = 3;

// ---------------------------------------------------------------- formatting

export function formatDuration(ms) {
    if (ms === null || ms === undefined || Number.isNaN(ms)) {
        return '';
    }
    if (ms < 1000) {
        return `${Math.max(0, Math.round(ms))} ms`;
    }
    const seconds = ms / 1000;
    if (seconds < 60) {
        return `${seconds < 10 ? seconds.toFixed(1) : Math.round(seconds)} s`;
    }
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) {
        const rest = Math.round(seconds - minutes * 60);
        return rest ? `${minutes} m ${rest} s` : `${minutes} m`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 48) {
        const rest = minutes - hours * 60;
        return rest ? `${hours} h ${rest} m` : `${hours} h`;
    }
    const days = Math.floor(hours / 24);
    const restHours = hours - days * 24;
    return restHours ? `${days} d ${restHours} h` : `${days} d`;
}

export function formatCost(usd) {
    if (!usd) {
        return '';
    }
    if (usd >= 0.01) {
        return `$${usd.toFixed(2)}`;
    }
    return `$${Number(usd.toPrecision(2))}`;
}

export function formatCount(value) {
    if (value === null || value === undefined) {
        return '';
    }
    return Number(value).toLocaleString();
}

/** get_case -> Get case */
export function humanize(name) {
    if (!name) {
        return '';
    }
    const words = String(name)
        .replace(/__c$/i, '')
        .replace(/([a-z])([A-Z])/g, '$1 $2')
        .replace(/[_-]+/g, ' ')
        .trim()
        .toLowerCase();
    return words.charAt(0).toUpperCase() + words.slice(1);
}

// ---------------------------------------------------------------- helpers

function time(value) {
    if (!value) {
        return null;
    }
    const parsed = typeof value === 'number' ? value : Date.parse(value);
    return Number.isNaN(parsed) ? null : parsed;
}

function parseJson(text) {
    if (!text) {
        return null;
    }
    try {
        return JSON.parse(text);
    } catch (error) {
        return null;
    }
}

function groupBy(records, key) {
    const groups = new Map();
    (records || []).forEach((record) => {
        const value = record[key];
        if (value) {
            if (!groups.has(value)) {
                groups.set(value, []);
            }
            groups.get(value).push(record);
        }
    });
    return groups;
}

function plural(count, one, many) {
    return `${count} ${count === 1 ? one : many || `${one}s`}`;
}

function name(record, relationship) {
    return record && record[relationship] ? record[relationship].Name : '';
}

// ---------------------------------------------------------------- story

/**
 * @param {object} story controller payload: run, anchorName, commands, invocations, approvals, events, requestedTools, truncated
 * @param {number} now epoch milliseconds, injected for tests
 */
export function buildStory(story, now = Date.now()) {
    const run = story.run || {};
    const commands = [...(story.commands || [])].sort((a, b) => (a.Sequence__c || 0) - (b.Sequence__c || 0));
    const events = [...(story.events || [])].sort((a, b) => (a.Sequence__c || 0) - (b.Sequence__c || 0));
    const invocationsByCommand = groupBy(story.invocations, 'AgentCommand__c');
    const approvalsByCommand = groupBy(story.approvals, 'AgentCommand__c');
    const eventsByKey = groupBy(events, 'CommandKey__c');
    const terminal = TERMINAL.has(run.Status__c);
    const endAt = terminal ? time(run.CompletedAt__c) || time(run.LastActivityAt__c) || now : now;

    const steps = commands.map((command, index) =>
        buildStep(command, {
            index,
            commands,
            invocations: invocationsByCommand.get(command.Id) || [],
            approvals: approvalsByCommand.get(command.Id) || [],
            events: eventsByKey.get(command.OperationKey__c) || [],
            allEvents: events,
            unrunTools: (story.requestedTools || {})[command.Id],
            run,
            now
        })
    );
    const markers = foldRecoveries(buildMarkers(events, run, now, { userNames: story.userNames || {}, invocations: story.invocations || [] }), steps);
    const items = orderTimeline([...steps, ...markers]);
    const approvalWindows = steps.flatMap((step) => step.approvals).map((approval) => ({ from: approval.createdAt, to: approval.closedAt || now }));
    const timeline = insertGaps(items, approvalWindows);
    const segments = buildSegments({ run, steps, markers, story, startAt: time(run.StartedAt__c) || time(run.CreatedDate), endAt, now });
    const attention = buildAttention(run, story, steps, markers, now);
    if (attention) {
        attention.focusKey = focusFor(attention, timeline);
    }

    return {
        header: buildHeader(run, story, steps, endAt),
        highlights: buildHighlights(steps, markers, attention),
        attention,
        outcome: buildOutcome(run, story),
        timeline,
        segments: segments.segments,
        timeBreakdown: segments.breakdown,
        counts: countByFilter(timeline),
        isLive: !terminal,
        truncated: story.truncated === true
    };
}

function buildStep(command, context) {
    const { index, commands, invocations, approvals, events, unrunTools, run } = context;
    const isModel = command.CommandType__c === 'Model';
    const attempts = [...invocations].sort((a, b) => (a.AttemptNumber__c || 0) - (b.AttemptNumber__c || 0));
    const firstAttempt = attempts[0];
    const lastAttempt = attempts[attempts.length - 1];
    // A step starts when it is requested; failed or paused attempts before the recorded ones still count.
    const startAt = time(command.CreatedDate) || time(firstAttempt && firstAttempt.StartedAt__c);
    const endAt = time(lastAttempt && lastAttempt.CompletedAt__c) || time(command.LastModifiedDate) || startAt;
    const activeMs = attempts.reduce((sum, attempt) => sum + (attempt.DurationMs__c || 0), 0);
    const tokens = attempts.reduce((sum, attempt) => sum + (attempt.TotalTokens__c || 0), 0);
    const cost = attempts.reduce((sum, attempt) => sum + (attempt.EstimatedCostUSD__c || 0), 0);
    const model = lastAttempt ? lastAttempt.ModelIdentifier__c : '';
    const status = command.Status__c;
    const tone = COMMAND_TONES[status] || 'neutral';
    const isCurrent = run.CurrentCommand__c === command.Id || run.WaitingCommand__c === command.Id;
    // Only recorded invocations ran; dispatches that paused before running are told by the pause and rescue markers.
    const attemptCount = attempts.length;
    const resumedAt = lastRescue(events);
    const retries = events.filter((event) => event.EventType__c === 'Command Retry Scheduled').length;

    let title;
    let subtitle = '';
    let icon;
    if (isModel) {
        icon = 'utility:sparkles';
        const requested = requestedTools(commands, index);
        const guided = command.InputSource__c === 'Operator Guidance';
        const paused = events.some((event) => event.EventType__c === 'Run Paused');
        if (requested.length) {
            ({ title, subtitle } = decidedToCall(requested));
        } else if (status === 'Succeeded' && run.Status__c === 'Succeeded' && isLastModel(commands, index)) {
            title = 'Wrote the final answer';
            icon = 'utility:check';
        } else if (status === 'Succeeded' && command.AnswerTurn__c) {
            title = 'Answered';
        } else if (status === 'Succeeded' && (paused || (unrunTools && unrunTools.length))) {
            // No tool step followed: the model's reply names what it chose, and the pause says why it never ran.
            ({ title, subtitle } = decidedToCall(unrunTools || []));
            const why = paused ? 'Paused before the tool ran' : 'The tool did not run';
            subtitle = subtitle ? `${subtitle} · ${why}` : why;
        } else if (status === 'Leased' || status === 'Pending') {
            title = 'Thinking…';
        } else if (status === 'Failed' || status === 'Unknown') {
            title = 'Model call failed';
        } else {
            title = 'Model call';
        }
        // The pause row above already names who resumed it, so the step only marks the operator's hand, and the final answer keeps its check.
        if (guided && icon !== 'utility:check') {
            icon = 'utility:user';
        }
    } else {
        icon = 'utility:apex_plugin';
        title = humanize(command.ToolName__c);
    }

    const approvalViews = approvals.sort((a, b) => time(a.CreatedDate) - time(b.CreatedDate)).map((approval) => buildApproval(approval, context.now));
    // A tool the approver turned down, or nobody decided in time, didn't run; its approval tells why.
    const declined = status === 'Failed' ? DECLINED[command.ErrorCode__c] : null;
    const decision = declined ? [...approvalViews].reverse().find((approval) => approval.status === declined.approvalStatus) : null;
    if (decision) {
        decision.outcome = declined.outcome;
    }
    const error = !decision && (status === 'Failed' || status === 'Unknown') ? explain(command.ErrorCode__c, command.ErrorMessage__c) : null;

    const chips = [];
    if (model) chips.push({ key: 'model', label: model, kind: 'model' });
    if (activeMs) chips.push({ key: 'time', label: formatDuration(activeMs), kind: 'time' });
    if (tokens) chips.push({ key: 'tokens', label: `${formatCount(tokens)} tokens`, kind: 'tokens' });
    if (cost) chips.push({ key: 'cost', label: formatCost(cost), kind: 'cost' });
    if (attemptCount > 1) chips.push({ key: 'attempts', label: plural(attemptCount, 'attempt'), kind: 'attempts' });
    if (retries) chips.push({ key: 'retries', label: plural(retries, 'retry', 'retries'), kind: 'attempts' });
    if (command.BatchSize__c > 1) chips.push({ key: 'batch', label: `${command.BatchOrdinal__c} of ${command.BatchSize__c} in parallel`, kind: 'batch' });

    return {
        key: command.Id,
        type: 'step',
        kind: isModel ? 'model' : 'tool',
        commandId: command.Id,
        operationKey: command.OperationKey__c,
        sequence: command.Sequence__c,
        orderKey: orderKeyFor(command, events, context.allEvents, startAt),
        at: resumedAt ? time(resumedAt.OccurredAt__c) : startAt,
        endAt,
        activeMs,
        tokens,
        cost,
        title,
        subtitle,
        icon,
        status,
        statusLabel: decision ? declined.label : status,
        tone: decision ? decision.tone : tone,
        isCurrent,
        isRunning: status === 'Leased' || status === 'Pending',
        chips,
        approvals: approvalViews,
        hasApprovals: approvalViews.length > 0,
        error,
        // The agent's own explanation of a tool call: shown as its claim, never as evidence.
        rationale: isModel ? null : command.Rationale__c || null,
        // A rejection is the approval doing its job, so it is coloured but not an issue; an expiry means nobody decided.
        hasIssue: Boolean(error) || approvalViews.some((approval) => approval.status === 'Expired'),
        payloadPurged: Boolean(command.PayloadPurgedAt__c),
        inputLabel: isModel ? 'What the model read last' : 'Arguments',
        outputLabel: isModel ? 'Answer' : 'Result',
        outputEmptyText: isModel ? "No output. The model's reply was the tool calls that follow." : emptyToolResult(status, approvalViews, Boolean(decision))
    };
}

/** Why a tool step has no result: it hasn't run yet, never will, or ran and returned nothing. */
function emptyToolResult(status, approvals, declined) {
    if (declined) {
        return 'No result. The tool did not run.';
    }
    if (approvals.some((approval) => approval.status === 'Pending')) {
        return 'No result yet. The tool runs only if the approver approves.';
    }
    return TERMINAL_COMMANDS.has(status) ? 'The tool returned no result.' : 'No result yet.';
}

function requestedTools(commands, index) {
    const names = [];
    for (let next = index + 1; next < commands.length; next++) {
        if (commands[next].CommandType__c !== 'Tool') {
            break;
        }
        names.push(commands[next].ToolName__c);
    }
    return names;
}

function decidedToCall(tools) {
    if (tools.length === 1) {
        return { title: `Decided to call ${humanize(tools[0])}`, subtitle: '' };
    }
    if (tools.length > 1) {
        return { title: `Decided to call ${tools.length} tools`, subtitle: tools.map(humanize).join(', ') };
    }
    // Only a viewer with evidence access sees which tools the model chose.
    return { title: 'Decided to call a tool', subtitle: '' };
}

function isLastModel(commands, index) {
    return !commands.slice(index + 1).some((command) => command.CommandType__c === 'Model');
}

/**
 * Events carry a gapless sequence, so a step sorts just before the first event
 * about it; a step without events (a model call after a tool completes) sorts
 * after the last event that happened before it started.
 */
function orderKeyFor(command, events, allEvents, startAt) {
    // A step an operator rescued is told where it ran: after the pause and the rescue, not where it was first requested.
    const rescue = lastRescue(events);
    const own = events
        .filter((event) => !rescue || event.Sequence__c > rescue.Sequence__c)
        .filter((event) => !LEADING_EVENTS.has(event.EventType__c))
        .map((event) => event.Sequence__c)
        .filter((sequence) => sequence !== null && sequence !== undefined);
    if (own.length) {
        return Math.min(...own) - 0.5;
    }
    if (rescue) {
        return rescue.Sequence__c + 0.5;
    }
    let before = 0;
    allEvents.forEach((event) => {
        const at = time(event.OccurredAt__c);
        if (at !== null && startAt !== null && at <= startAt) {
            before = Math.max(before, event.Sequence__c || 0);
        }
    });
    return before + 0.25 + (command.Sequence__c || 0) / 10000;
}

function lastRescue(events) {
    return [...events].reverse().find((event) => event.EventType__c === 'Run Rescued') || null;
}

/** The step an event is about, from its operation key (run:sequence:type[:tool]). */
function stepName(commandKey) {
    const [, , type, tool] = (commandKey || '').split(':');
    if (type === 'Tool' && tool) {
        return humanize(tool);
    }
    return type === 'Model' ? 'the model call' : 'the step';
}

function buildApproval(approval, now) {
    const createdAt = time(approval.CreatedDate);
    const closedAt = time(approval.ClosedAt__c);
    const waitedMs = createdAt ? (closedAt || now) - createdAt : null;
    const owner = name(approval, 'Owner');
    const decidedBy = name(approval, 'DecidedBy__r');
    const status = approval.Status__c;
    let summary;
    if (status === 'Pending') {
        summary = `Waiting on ${owner || 'the approver'} for ${formatDuration(waitedMs)}`;
    } else if (status === 'Approved' || status === 'Rejected') {
        summary = `${status} by ${decidedBy || 'an approver'} after ${formatDuration(waitedMs)}`;
    } else {
        summary = `${status} after ${formatDuration(waitedMs)}`;
    }
    return {
        key: approval.Id,
        id: approval.Id,
        name: approval.Name,
        status,
        tone: APPROVAL_TONES[status] || 'neutral',
        summary,
        approverType: approval.ApproverType__c,
        owner,
        requestedBy: name(approval, 'RequestedBy__r'),
        decidedBy,
        relayedBy: name(approval, 'RelayedBy__r'),
        reason: approval.Reason__c,
        comment: approval.DecisionComment__c || '',
        createdAt,
        closedAt,
        expiresAt: time(approval.ExpiresAt__c),
        waitedMs
    };
}

/** Run-level moments worth a line of their own; step-level events are folded into their steps. */
function buildMarkers(events, run, now, { userNames, invocations }) {
    const markers = [];
    events.forEach((event, index) => {
        const payload = parseJson(event.Payload__c) || {};
        const at = time(event.OccurredAt__c);
        const base = { key: event.Id || `event-${event.Sequence__c}`, type: 'marker', orderKey: event.Sequence__c, at, endAt: at, sequence: event.Sequence__c };
        switch (event.EventType__c) {
            case 'Run Started':
                markers.push({ ...base, kind: 'start', icon: 'utility:play', tone: 'neutral', title: 'Run started' });
                break;
            case 'Run Paused': {
                const code = payload.errorCode || pausedCode(events, index, run);
                const budget = code === 'BUDGET_EXCEEDED' ? describeBudget(payload.budget, event, invocations) : null;
                const explanation = budget || explain(code, code === run.ErrorCode__c ? run.ErrorMessage__c : '');
                // A budget pause stops before the next step, so it follows the step its event names.
                const where = event.CommandKey__c ? `${budget ? 'After' : 'At'} ${stepName(event.CommandKey__c)}.` : '';
                markers.push({
                    ...base,
                    kind: 'pause',
                    icon: 'utility:pause',
                    tone: 'warning',
                    title: explanation ? `Paused: ${explanation.title}` : 'Paused for an operator',
                    detail: [where, explanation ? explanation.detail : '', budget ? budget.action : ''].filter(Boolean).join(' '),
                    reason: explanation ? explanation.title : '',
                    isRunPause: true,
                    budget,
                    code,
                    hasIssue: true
                });
                break;
            }
            case 'Run Rescued': {
                // Usually folded into the pause it ended; see foldRecoveries.
                const actor = userNames[payload.actorId];
                const mode = RESCUE_MODES[payload.mode];
                markers.push({
                    ...base,
                    kind: 'operator',
                    icon: 'utility:advertising',
                    tone: 'info',
                    title: actor ? `Resumed by ${actor}` : 'Resumed by an operator',
                    actor: actor || 'An operator',
                    did: mode ? mode(stepName(event.CommandKey__c)) : 'resumed the run',
                    commandKey: event.CommandKey__c,
                    isRescue: true
                });
                break;
            }
            case 'Run Waiting':
                if (!payload.approvalId) {
                    markers.push({
                        ...base,
                        kind: 'wait',
                        icon: 'utility:clock',
                        tone: 'waiting',
                        title: run.WaitingReason__c && run.Status__c === 'Waiting' ? `Waiting: ${run.WaitingReason__c}` : 'Waiting for a reply'
                    });
                }
                break;
            case 'Run Resumed':
                if (!payload.approvalId) {
                    markers.push({ ...base, kind: 'wait', icon: 'utility:reply', tone: 'info', title: 'Resumed' });
                }
                break;
            case 'Wait Expired':
                markers.push({ ...base, kind: 'wait', icon: 'utility:clock', tone: 'warning', title: 'The wait expired', hasIssue: true });
                break;
            case 'Configuration Changed':
                markers.push({
                    ...base,
                    kind: 'config',
                    icon: 'utility:settings',
                    tone: 'info',
                    title: 'Agent setup changed',
                    // Core lists the changes only when it can prove them; older or protected events say only that something changed.
                    changes: Array.isArray(payload.changes) ? payload.changes : null,
                    commandKey: event.CommandKey__c
                });
                break;
            case 'Tool Outcome Unknown':
                markers.push({ ...base, kind: 'pause', icon: 'utility:question', tone: 'error', title: 'A tool result is unknown', hasIssue: true });
                break;
            case 'Unknown Outcome Reconciled':
                markers.push({ ...base, kind: 'operator', icon: 'utility:check', tone: 'info', title: 'An operator reconciled the unknown result' });
                break;
            case 'Run Cancellation Requested':
                markers.push({ ...base, kind: 'operator', icon: 'utility:close', tone: 'warning', title: 'Cancellation requested' });
                break;
            case 'Run Completed':
                markers.push({ ...base, kind: 'end', icon: 'utility:success', tone: 'success', title: 'Run succeeded' });
                break;
            case 'Run Failed': {
                const explanation = explain(run.ErrorCode__c, run.ErrorMessage__c);
                markers.push({
                    ...base,
                    kind: 'end',
                    icon: 'utility:error',
                    tone: 'error',
                    title: explanation ? `Failed: ${explanation.title}` : 'Run failed',
                    detail: explanation ? explanation.detail : '',
                    hasIssue: true
                });
                break;
            }
            case 'Run Timed Out':
                markers.push({ ...base, kind: 'end', icon: 'utility:clock', tone: 'error', title: 'Run timed out', hasIssue: true });
                break;
            case 'Run Cancelled':
                markers.push({ ...base, kind: 'end', icon: 'utility:ban', tone: 'warning', title: 'Run cancelled' });
                break;
            default:
                break;
        }
    });
    if (!TERMINAL.has(run.Status__c) && run.Status__c) {
        markers.push({
            key: 'now',
            type: 'marker',
            kind: 'now',
            icon: 'utility:record',
            tone: STATUS_TONES[run.Status__c] || 'neutral',
            title: run.Status__c === 'Paused' ? 'Paused now' : run.Status__c === 'Waiting' ? 'Waiting now' : 'Running now',
            orderKey: Number.MAX_SAFE_INTEGER,
            at: now,
            endAt: now,
            isNow: true
        });
    }
    return markers;
}

/**
 * A pause, the rescue that ended it, and the setup change the rescued step ran
 * with tell one story, so they read as one row: why the run stopped, for how
 * long, and who changed what to resume it. A setup change with no rescue sits
 * just before the step that first used it.
 */
function foldRecoveries(markers, steps) {
    const folded = new Set();
    const configs = markers.filter((marker) => marker.kind === 'config');
    const configFor = (commandKey) => {
        const config = commandKey ? configs.find((candidate) => !folded.has(candidate.key) && candidate.commandKey === commandKey) : null;
        if (config) {
            folded.add(config.key);
        }
        return config;
    };
    let openPause = null;
    [...markers]
        .sort((a, b) => a.orderKey - b.orderKey)
        .forEach((marker) => {
            if (marker.isRunPause) {
                openPause = marker;
                return;
            }
            if (!marker.isRescue) {
                return;
            }
            const config = configFor(marker.commandKey);
            const changed = config ? changeClauses(config.changes) : [];
            if (openPause && openPause.at !== null && marker.at !== null) {
                const pausedFor = formatDuration(Math.max(0, marker.at - openPause.at));
                openPause.title = `Paused for ${pausedFor}${openPause.reason ? `: ${openPause.reason}` : ''}`;
                openPause.detail = `${marker.actor} ${joinList([...changed, marker.did])}.`;
                openPause.resumedAt = marker.at;
                openPause.endAt = marker.at;
                folded.add(marker.key);
            } else {
                // The title already says it resumed, so the detail keeps only what else the operator did.
                const rest = marker.did === RESCUE_MODES.reflect_new_model() ? changed : [...changed, marker.did];
                marker.detail = rest.length ? `${capitalize(joinList(rest))}.` : '';
            }
            openPause = null;
        });
    const stepsByKey = new Map(steps.map((step) => [step.operationKey, step]));
    configs
        .filter((config) => !folded.has(config.key))
        .forEach((config) => {
            const changed = changeClauses(config.changes);
            config.detail = `${changed.length && config.changes ? `${capitalize(joinList(changed))}. ` : ''}Later steps use the new setup.`;
            // Core notices the change when the step that used it finishes, so the row moves to where that step began.
            const step = stepsByKey.get(config.commandKey);
            if (step) {
                config.orderKey = step.orderKey - 0.001;
                config.at = step.at;
                config.endAt = step.at;
            }
        });
    return markers.filter((marker) => !folded.has(marker.key));
}

/** "raised Max Tool Calls from 3 to 4", one per change; a change Core couldn't itemize is still named. */
function changeClauses(changes) {
    if (!changes) {
        return ["changed the agent's setup"];
    }
    const clauses = changes.map(changeClause);
    if (clauses.length > CHANGES_SHOWN) {
        return [...clauses.slice(0, CHANGES_SHOWN - 1), `made ${plural(clauses.length - CHANGES_SHOWN + 1, 'other change')}`];
    }
    return clauses;
}

function changeClause(change) {
    const part = change.tool || change.context;
    if (part) {
        return `${change.change || 'changed'} the ${humanize(part)} ${change.tool ? 'tool' : 'context'}`;
    }
    const { setting, before, after } = change;
    if (!('after' in change)) {
        return `changed ${setting}`;
    }
    if (typeof after === 'boolean') {
        return `turned ${after ? 'on' : 'off'} ${setting}`;
    }
    if (after === null || after === undefined) {
        return `cleared ${setting}`;
    }
    if (before === null || before === undefined) {
        return `set ${setting} to ${formatCount(after)}`;
    }
    if (typeof before === 'number' && typeof after === 'number') {
        return `${after > before ? 'raised' : 'lowered'} ${setting} from ${formatCount(before)} to ${formatCount(after)}`;
    }
    return `changed ${setting}`;
}

function joinList(parts) {
    if (parts.length <= 2) {
        return parts.join(' and ');
    }
    return `${parts.slice(0, -1).join(', ')}, and ${parts[parts.length - 1]}`;
}

function capitalize(text) {
    return text ? text.charAt(0).toUpperCase() + text.slice(1) : '';
}

/**
 * Which budget ran out and by how much. Core records the counts on the pause;
 * an older pause without them is read from the run: after a tool the next step
 * is always a model call, and a counter never passes its limit, so the model
 * calls made by then were the whole allowance.
 */
function describeBudget(facts, event, invocations) {
    const scope = facts && facts.perReply ? 'This reply' : 'The run';
    if (facts && facts.exceeded === 'token') {
        return {
            title: 'Out of tokens',
            detail: `${scope} had used ${facts.tokens} of the ${facts.maxTokens} tokens the agent allowed, and the next step needed another model call.`,
            action: 'Raise Max Total Tokens on the agent, then rescue the run.'
        };
    }
    if (facts && facts.exceeded) {
        const isModel = facts.exceeded === 'model';
        const noun = isModel ? 'model' : 'tool';
        const used = isModel ? facts.modelCalls : facts.toolCalls;
        const max = isModel ? facts.maxModelCalls : facts.maxToolCalls;
        const requested = isModel ? facts.requestedModelCalls : facts.requestedToolCalls;
        const detail = `${scope} had used ${used} of the ${max} ${noun} calls the agent allowed, and the next step needed ${requested || 1} more.`;
        // The model reads every tool result, so raising only tool calls would pause the run again at once.
        if (!isModel && facts.maxModelCalls != null && facts.modelCalls >= facts.maxModelCalls) {
            return {
                title: 'Out of tool calls',
                detail: `${detail} Model calls are used up too, and the agent needs one to read the tool's result.`,
                action: 'Raise Max Tool Calls and Max Model Calls on the agent, then rescue the run.'
            };
        }
        return { title: `Out of ${noun} calls`, detail, action: `Raise Max ${isModel ? 'Model' : 'Tool'} Calls on the agent, then rescue the run.` };
    }
    const [, , type] = (event.CommandKey__c || '').split(':');
    const pausedAt = time(event.OccurredAt__c);
    if (type === 'Tool' && pausedAt !== null) {
        const used = invocations.filter((invocation) => invocation.InvocationType__c === 'Model' && time(invocation.StartedAt__c) <= pausedAt).length;
        return {
            title: 'Out of model calls',
            detail: `The run had used all ${used} model calls the agent allowed, and needed another to continue.`,
            action: 'Raise Max Model Calls on the agent, then rescue the run.'
        };
    }
    return null;
}

/** A pause's code lives on the rescue that ended it, or on the run while it is still paused. */
function pausedCode(events, index, run) {
    for (let next = index + 1; next < events.length; next++) {
        const type = events[next].EventType__c;
        if (type === 'Run Rescued') {
            return (parseJson(events[next].Payload__c) || {}).pausedErrorCode || '';
        }
        if (type === 'Run Paused') {
            break;
        }
    }
    return run.Status__c === 'Paused' ? run.ErrorCode__c || '' : '';
}

function orderTimeline(items) {
    return items.sort((a, b) => {
        if (a.orderKey !== b.orderKey) {
            return a.orderKey - b.orderKey;
        }
        return (a.at || 0) - (b.at || 0);
    });
}

function insertGaps(items, approvalWindows) {
    const result = [];
    let previous = null;
    let pausedSince = false;
    items.forEach((item) => {
        if (previous && previous.endAt !== null && item.at !== null) {
            const gap = item.at - previous.endAt;
            if (gap >= GAP_THRESHOLD_MS) {
                result.push({
                    key: `gap-${item.key}`,
                    type: 'gap',
                    kind: 'gap',
                    at: previous.endAt,
                    endAt: item.at,
                    title: gapTitle(gap, previous, pausedSince, overlapsApproval(approvalWindows, previous.endAt, item.at))
                });
            }
        }
        if (item.kind === 'pause') {
            pausedSince = !item.resumedAt;
        } else if (item.kind === 'operator' || item.kind === 'end') {
            pausedSince = false;
        }
        result.push(item);
        previous = item;
    });
    return result.map((item, index) => ({ ...item, isFirst: index === 0, isLast: index === result.length - 1 }));
}

/** Whether an approval was open for most of the gap. */
function overlapsApproval(windows, from, to) {
    const covered = windows.reduce((sum, window) => sum + Math.max(0, Math.min(to, window.to) - Math.max(from, window.from)), 0);
    return covered >= (to - from) / 2;
}

function gapTitle(gap, previous, paused, awaitingApproval) {
    const duration = formatDuration(gap);
    if (awaitingApproval) {
        return `${duration} waiting for approval`;
    }
    if (paused) {
        return `${duration} paused`;
    }
    if (previous.kind === 'wait') {
        return `${duration} waiting`;
    }
    return `${duration} later`;
}

// ---------------------------------------------------------------- header & attention

/** Who the run's tools act as: the identity's user, by name when the viewer can read it. */
function runsAs(run) {
    if (!run.ExecutionIdentity__c) {
        return 'Runs as its starter';
    }
    const principal = name(run.ExecutionIdentity__r, 'PrincipalUser__r');
    return principal ? `Runs as ${principal}` : 'Runs as execution user';
}

function buildHeader(run, story, steps, endAt) {
    const startAt = time(run.StartedAt__c) || time(run.CreatedDate);
    const definition = run.AgentDefinition__r || {};
    const activeMs = steps.reduce((sum, step) => sum + step.activeMs, 0);
    const tokens = run.TotalTokenCount__c || steps.reduce((sum, step) => sum + step.tokens, 0);
    const cost = steps.reduce((sum, step) => sum + step.cost, 0);
    return {
        runName: run.Name,
        status: run.Status__c,
        tone: STATUS_TONES[run.Status__c] || 'neutral',
        agentName: definition.Name || '',
        agentId: run.AgentDefinition__c,
        anchorId: run.AnchorRecordId__c,
        anchorName: story.anchorName || run.AnchorRecordId__c || '',
        startedBy: name(run, 'InitiatingUser__r'),
        startedById: run.InitiatingUser__c,
        startedAt: startAt,
        parentRunId: run.ParentRun__c,
        parentRunName: name(run, 'ParentRun__r'),
        identityId: run.ExecutionIdentity__c,
        mode: runsAs(run),
        elapsedMs: startAt ? Math.max(0, endAt - startAt) : null,
        activeMs,
        tokens,
        unmeteredAttempts: run.UnmeteredModelAttempts__c || 0,
        cost,
        budgets: budgets(run, definition)
    };
}

/**
 * Budgets count the whole run, or only the calls since the latest reply in a
 * conversation (Core records the counts when each reply arrives).
 */
function budgets(run, definition) {
    const stopped = stoppedByBudget(run);
    const perReply = run.ReplyModelCallBase__c !== null && run.ReplyModelCallBase__c !== undefined;
    const since = (total, base) => Math.max(0, (total || 0) - (perReply ? base || 0 : 0));
    const suffix = perReply ? ' this reply' : '';
    const rows = [
        budget('modelCalls', `Model calls${suffix}`, since(run.ModelCallCount__c, run.ReplyModelCallBase__c), definition.MaxModelCalls__c, stopped),
        budget('toolCalls', `Tool calls${suffix}`, since(run.ToolCallCount__c, run.ReplyToolCallBase__c), definition.MaxToolCalls__c, stopped)
    ];
    if (definition.MaxTotalTokens__c !== null && definition.MaxTotalTokens__c !== undefined) {
        rows.push(budget('tokens', `Tokens${suffix}`, since(run.TotalTokenCount__c, run.ReplyTokenBase__c), definition.MaxTotalTokens__c, stopped));
    }
    return rows;
}

/** Whether the run is stopped right now because a call budget ran out. */
function stoppedByBudget(run) {
    return (run.Status__c === 'Paused' || run.Status__c === 'Failed') && run.ErrorCode__c === 'BUDGET_EXCEEDED';
}

/**
 * A counter at its limit is an error only when the limit stopped the run. A run
 * that finished or is still working on its last allowed call only had no room
 * to spare, which is a warning.
 */
function budget(key, label, used, max, stopped) {
    const count = used || 0;
    const hasMax = max !== null && max !== undefined;
    const ratio = hasMax && max > 0 ? Math.min(1, count / max) : hasMax ? 1 : 0;
    let tone = 'normal';
    if (hasMax && count >= max && stopped) {
        tone = 'full';
    } else if (hasMax && ratio >= 0.8) {
        tone = 'high';
    }
    return { key, label, used: count, max: hasMax ? max : null, percent: Math.round(ratio * 100), tone };
}

const HIGHLIGHTS = [
    {
        key: 'rejected',
        tone: 'error',
        one: 'approval rejected',
        many: 'approvals rejected',
        count: (step) => step.approvals.filter((a) => a.status === 'Rejected').length
    },
    {
        key: 'expired',
        tone: 'warning',
        one: 'approval expired',
        many: 'approvals expired',
        count: (step) => step.approvals.filter((a) => a.status === 'Expired').length
    },
    { key: 'failed', tone: 'error', one: 'step failed', many: 'steps failed', count: (step) => (step.error ? 1 : 0) }
];

/**
 * What changed the outcome, beside the status, for a reader who only glances:
 * a run can succeed after its refund was rejected, or only after an operator
 * resumed it. A stopped run's attention box already says what went wrong, so
 * it gets none.
 */
function buildHighlights(steps, markers, attention) {
    if (attention && attention.tone !== 'waiting') {
        return [];
    }
    const highlights = HIGHLIGHTS.map((kind) => {
        const hits = steps.filter((step) => kind.count(step) > 0);
        const total = hits.reduce((sum, step) => sum + kind.count(step), 0);
        return total ? { key: kind.key, tone: kind.tone, label: plural(total, kind.one, kind.many), targetKey: hits[0].key } : null;
    }).filter(Boolean);
    const resumed = markers.filter((marker) => marker.resumedAt).sort((a, b) => a.orderKey - b.orderKey);
    if (resumed.length) {
        const pausedMs = resumed.reduce((sum, marker) => sum + (marker.resumedAt - marker.at), 0);
        const times = resumed.length === 1 ? 'once' : `${resumed.length} times`;
        highlights.push({ key: 'paused', tone: 'warning', label: `Paused ${times} · ${formatDuration(pausedMs)}`, targetKey: resumed[0].key });
    }
    return highlights;
}

function buildAttention(run, story, steps, markers, now) {
    const status = run.Status__c;
    if (status === 'Paused' || status === 'Failed') {
        // The pause knows which budget ran out; the generic code text only lists them all.
        const lastPause = markers.filter((marker) => marker.kind === 'pause').pop();
        const budget = status === 'Paused' && lastPause && lastPause.code === run.ErrorCode__c ? lastPause.budget : null;
        const explanation = budget ||
            explain(run.ErrorCode__c, run.ErrorMessage__c) || {
                title: status === 'Paused' ? 'Paused for an operator' : 'The run failed',
                detail: run.ErrorMessage__c || '',
                action: ''
            };
        return {
            tone: status === 'Paused' ? 'warning' : 'error',
            icon: status === 'Paused' ? 'utility:pause' : 'utility:error',
            heading: status === 'Paused' ? 'Needs an operator' : 'Run failed',
            title: explanation.title,
            detail: explanation.detail,
            action: explanation.action,
            actionIcon: 'utility:rules',
            code: run.ErrorCode__c,
            message: !budget && run.ErrorMessage__c && run.ErrorMessage__c !== explanation.detail ? run.ErrorMessage__c : '',
            canOperate: status === 'Paused'
        };
    }
    if (status === 'Waiting') {
        const pending = steps.flatMap((step) => step.approvals).find((approval) => approval.status === 'Pending');
        if (pending) {
            return {
                tone: 'waiting',
                icon: 'utility:approval',
                heading: 'Waiting for approval',
                title: `${pending.owner || 'The approver'} needs to decide`,
                // A policy writes its own reason, usually as a full sentence; the detail adds the final stop.
                detail: `Requested ${formatDuration(now - pending.createdAt)} ago${pending.reason ? `: ${pending.reason.trim().replace(/[.!?]+$/, '')}` : ''}.`,
                action: pending.expiresAt ? `It expires in ${formatDuration(Math.max(0, pending.expiresAt - now))}.` : '',
                actionIcon: 'utility:clock',
                approvalId: pending.id,
                canOperate: false
            };
        }
        const expires = time(run.WaitExpiresAt__c);
        return {
            tone: 'waiting',
            icon: 'utility:clock',
            heading: 'Waiting',
            title: run.WaitingReason__c || 'Waiting for a reply',
            detail: expires ? `The wait ends in ${formatDuration(Math.max(0, expires - now))}.` : '',
            action: '',
            canOperate: false
        };
    }
    return null;
}

/** The timeline row an operator should look at first: the pending approval's step, the failing step, or the current one. */
function focusFor(attention, timeline) {
    const steps = timeline.filter((item) => item.type === 'step');
    if (attention.approvalId) {
        const owner = steps.find((step) => step.approvals.some((approval) => approval.id === attention.approvalId));
        if (owner) {
            return owner.key;
        }
    }
    const current = steps.find((step) => step.isCurrent);
    const failing = [...steps].reverse().find((step) => step.error);
    const issue = [...timeline].reverse().find((item) => item.hasIssue);
    const focus = (current && current.hasIssue ? current : null) || failing || current || issue;
    return focus ? focus.key : null;
}

/** True for input that says nothing: blank, or an empty JSON object. */
function isEmptyInput(input) {
    const parsed = parseJson(input);
    return !input || !input.trim() || (parsed && typeof parsed === 'object' && !Array.isArray(parsed) && Object.keys(parsed).length === 0);
}

function buildOutcome(run, story = {}) {
    if (!run.Output__c && !run.Input__c) {
        return null;
    }
    // Core sends the model the run's record even when the caller sent no input, so "{}" is not what the agent was asked.
    const anchor = story.anchorName || run.AnchorRecordId__c;
    const inputEmptyText = anchor
        ? `No input. The agent started from ${anchor}, which the model receives as its first message.`
        : 'No input. The agent started from its instructions.';
    const parsed = parseJson(run.Output__c);
    let headline = '';
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        headline = ['summary', 'answer', 'message', 'reply', 'text'].map((key) => parsed[key]).find((value) => typeof value === 'string' && value.trim()) || '';
    } else if (run.Output__c && !parsed) {
        headline = run.Output__c;
    }
    return {
        input: isEmptyInput(run.Input__c) ? '' : run.Input__c,
        inputEmptyText,
        output: run.Output__c || '',
        hasOutput: Boolean(run.Output__c),
        headline
    };
}

// ---------------------------------------------------------------- time accounting

/**
 * Splits the run's elapsed time into model, tool, approval, paused, and other
 * time. Active calls are measured; approval and pause time come from their
 * records and events; the rest is queueing and platform overhead.
 */
function buildSegments({ run, steps, markers, story, startAt, endAt, now }) {
    if (!startAt || !endAt || endAt <= startAt) {
        return { segments: [], breakdown: [] };
    }
    const intervals = [];
    steps.forEach((step) => {
        (story.invocations || [])
            .filter((invocation) => invocation.AgentCommand__c === step.commandId)
            .forEach((invocation) => {
                const from = time(invocation.StartedAt__c);
                const duration = invocation.DurationMs__c || 0;
                if (from !== null && duration > 0) {
                    intervals.push({ kind: step.kind, from, to: from + duration, key: step.key });
                }
            });
        step.approvals.forEach((approval) => {
            if (approval.createdAt) {
                intervals.push({ kind: 'approval', from: approval.createdAt, to: approval.closedAt || now, key: step.key });
            }
        });
    });
    const ordered = [...markers].sort((a, b) => a.orderKey - b.orderKey);
    ordered.forEach((marker, index) => {
        if (marker.kind !== 'pause' || marker.at === null) {
            return;
        }
        const ends = ordered.slice(index + 1).find((next) => next.kind === 'operator' || next.kind === 'end' || next.isNow);
        const to = marker.resumedAt || (ends ? (ends.isNow ? now : ends.at) : endAt);
        intervals.push({ kind: 'paused', from: marker.at, to, key: marker.key });
    });

    const total = endAt - startAt;
    const clipped = intervals
        .map((interval) => ({ ...interval, from: Math.max(startAt, interval.from), to: Math.min(endAt, interval.to) }))
        .filter((interval) => interval.to > interval.from)
        .sort((a, b) => a.from - b.from);

    const totals = { model: 0, tool: 0, approval: 0, paused: 0 };
    let cursor = startAt;
    const segments = [];
    clipped.forEach((interval) => {
        const from = Math.max(cursor, interval.from);
        if (interval.to <= from) {
            return;
        }
        if (from > cursor) {
            segments.push(segment('other', cursor, from, startAt, total, null));
        }
        segments.push(segment(interval.kind, from, interval.to, startAt, total, interval.key));
        totals[interval.kind] += interval.to - from;
        cursor = interval.to;
    });
    if (cursor < endAt) {
        segments.push(segment('other', cursor, endAt, startAt, total, null));
    }
    const other = Math.max(0, total - totals.model - totals.tool - totals.approval - totals.paused);
    const labels = {
        model: 'Model',
        tool: 'Tools',
        approval: 'Waiting for approval',
        paused: 'Paused',
        other: run.Status__c === 'Waiting' ? 'Waiting and queueing' : 'Queueing and overhead'
    };
    const breakdown = ['model', 'tool', 'approval', 'paused', 'other']
        .map((kind) => {
            const ms = kind === 'other' ? other : totals[kind];
            return { key: kind, kind, label: labels[kind], ms, text: formatDuration(ms), percent: total ? Math.round((ms / total) * 1000) / 10 : 0 };
        })
        .filter((entry) => entry.ms > 0);
    return { segments: mergeAdjacent(segments), breakdown };
}

function segment(kind, from, to, startAt, total, targetKey) {
    return { kind, from, to, left: ((from - startAt) / total) * 100, width: ((to - from) / total) * 100, targetKey };
}

function mergeAdjacent(segments) {
    const merged = [];
    segments.forEach((current) => {
        const last = merged[merged.length - 1];
        if (last && last.kind === current.kind && last.targetKey === current.targetKey && Math.abs(last.to - current.from) < 1) {
            last.to = current.to;
            last.width += current.width;
        } else {
            merged.push({ ...current });
        }
    });
    return merged.map((entry, index) => ({ ...entry, key: `${entry.kind}-${index}`, durationText: formatDuration(entry.to - entry.from) }));
}

// ---------------------------------------------------------------- filters

export const FILTERS = [
    { value: 'all', label: 'All' },
    { value: 'model', label: 'Model' },
    { value: 'tool', label: 'Tools' },
    { value: 'approval', label: 'Approvals' },
    { value: 'issue', label: 'Issues' }
];

export function matchesFilter(item, filter) {
    if (item.type === 'gap') {
        return filter === 'all';
    }
    if (filter === 'all') {
        return true;
    }
    switch (filter) {
        case 'model':
            return item.type === 'step' && item.kind === 'model';
        case 'tool':
            return item.type === 'step' && item.kind === 'tool';
        case 'approval':
            return item.type === 'step' && item.hasApprovals;
        case 'issue':
            return Boolean(item.hasIssue);
        default:
            return true;
    }
}

const ROUTINE_MIN_STEPS = 10;
const ROUTINE_MIN_RUN = 3;

/**
 * Folds runs of uneventful steps (succeeded, no approval, not current, no
 * issue) into one summary row so what matters in a long run stands out.
 * Short runs are left alone, and any step in keep (opened, revealed, or
 * pointed at) always shows.
 */
export function collapseRoutine(items, keep = new Set()) {
    if (items.filter((item) => item.type === 'step').length <= ROUTINE_MIN_STEPS) {
        return items;
    }
    const routine = (item) =>
        item.type === 'step' && item.status === 'Succeeded' && !item.hasApprovals && !item.isCurrent && !item.hasIssue && !keep.has(item.key);
    const result = [];
    let pending = [];
    const flush = () => {
        if (pending.length >= ROUTINE_MIN_RUN) {
            const first = pending[0];
            const last = pending[pending.length - 1];
            const activeMs = pending.reduce((sum, step) => sum + (step.activeMs || 0), 0);
            const tokens = pending.reduce((sum, step) => sum + (step.tokens || 0), 0);
            const models = pending.filter((step) => step.kind === 'model').length;
            result.push({
                key: `group-${first.key}`,
                type: 'group',
                kind: 'group',
                icon: 'utility:rows',
                tone: 'success',
                at: first.at,
                endAt: last.endAt,
                title: `${pending.length} steps succeeded`,
                detail: [
                    [models ? plural(models, 'model call') : '', pending.length - models ? plural(pending.length - models, 'tool call') : '']
                        .filter(Boolean)
                        .join(', '),
                    activeMs ? `${formatDuration(activeMs)} working` : '',
                    tokens ? `${formatCount(tokens)} tokens` : ''
                ]
                    .filter(Boolean)
                    .join(' · '),
                stepKeys: pending.map((step) => step.key)
            });
        } else {
            result.push(...pending);
        }
        pending = [];
    };
    items.forEach((item) => {
        if (routine(item)) {
            pending.push(item);
        } else {
            flush();
            result.push(item);
        }
    });
    flush();
    return result;
}

/** Time since the run started, as +m:ss or +h:mm:ss. */
export function formatOffset(ms) {
    if (ms === null || ms === undefined || Number.isNaN(ms)) {
        return '';
    }
    const total = Math.max(0, Math.floor(ms / 1000));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = String(total % 60).padStart(2, '0');
    return hours ? `+${hours}:${String(minutes).padStart(2, '0')}:${seconds}` : `+${minutes}:${seconds}`;
}

function countByFilter(items) {
    const counts = {};
    FILTERS.forEach((filter) => {
        counts[filter.value] = items.filter((item) => item.type !== 'gap' && matchesFilter(item, filter.value)).length;
    });
    return counts;
}

// ---------------------------------------------------------------- payloads

/**
 * Splits pretty-printed JSON into spans for syntax colouring. Core's
 * sensitive-value tokens ({{EMAIL_3_9f2c61ab}}) get their own class so a
 * reader sees what the model never saw in plain text.
 */
export function highlightJson(text) {
    if (text === null || text === undefined || text === '') {
        return { pretty: '', tokens: [], isJson: false };
    }
    let pretty = String(text);
    let isJson = false;
    try {
        pretty = JSON.stringify(JSON.parse(text), null, 2);
        isJson = true;
    } catch (error) {
        isJson = false;
    }
    const pattern = /("(?:\\.|[^"\\])*"(?:\s*:)?)|\b(true|false|null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g;
    const tokens = [];
    let last = 0;
    let match;
    let index = 0;
    const push = (value, cls) => {
        if (value) {
            tokens.push({ key: `t${index++}`, value, cls });
        }
    };
    if (isJson) {
        while ((match = pattern.exec(pretty)) !== null) {
            push(pretty.slice(last, match.index), 'json-punct');
            if (match[1]) {
                const isKey = /:\s*$/.test(match[1]);
                const cls = isKey ? 'json-key' : /\{\{[A-Z_]+_\d+_[0-9a-f]+\}\}/.test(match[1]) ? 'json-sensitive' : 'json-string';
                push(match[1], cls);
            } else if (match[2]) {
                push(match[2], 'json-literal');
            } else {
                push(match[3], 'json-number');
            }
            last = pattern.lastIndex;
        }
    }
    push(pretty.slice(last), isJson ? 'json-punct' : 'json-plain');
    return { pretty, tokens, isJson };
}

// ---------------------------------------------------------------- model and tool evidence

const TRANSCRIPT_ROLES = {
    OriginalInput: { label: 'Input', tone: 'input' },
    UserInput: { label: 'Person', tone: 'input' },
    ToolCall: { label: 'Tool call', tone: 'model' },
    ToolResult: { label: 'Tool result', tone: 'tool' },
    AssistantOutput: { label: 'Agent answer', tone: 'model' },
    OperatorGuidance: { label: 'Operator guidance', tone: 'operator' },
    ModelFeedback: { label: 'Core feedback', tone: 'operator' }
};

/**
 * One attempt's evidence as the page shows it: what Core sent the model (or
 * tool), what came back, the provider's own request and response, and what
 * the attempt cost. Missing or unreadable parts come back empty, never thrown.
 */
export function describeCall(attempt, evidence) {
    const record = evidence || {};
    const request = parseJson(record.Request__c);
    const response = parseJson(record.Response__c);
    const native = parseJson(record.NativeEvidence__c);
    const metadata = parseJson(record.EvidenceMetadata__c) || {};
    const isModel = (attempt && attempt.InvocationType__c) === 'Model' || Boolean(request && request.instructions !== undefined);
    const call = {
        key: (attempt && attempt.Id) || `attempt-${record.AttemptNumber__c}`,
        attemptNumber: (attempt && attempt.AttemptNumber__c) || record.AttemptNumber__c,
        isModel,
        hasEvidence: Boolean(record.Request__c || record.Response__c),
        tokenized: ['request', 'response', 'nativeEvidence'].some((part) => metadata[part] && metadata[part].redacted),
        truncated: ['request', 'response', 'nativeEvidence'].some((part) => metadata[part] && metadata[part].truncated),
        resources: resources(attempt),
        usage: attemptUsage(attempt),
        rawRequest: record.Request__c || '',
        rawResponse: record.Response__c || '',
        nativeRequest: native && native.request ? JSON.stringify(native.request) : '',
        nativeResponse: native && native.response ? JSON.stringify(native.response) : '',
        hasNative: Boolean(native && (native.request || native.response))
    };
    // The provider's own payloads are what the model actually saw and said; Core's are the fallback.
    call.evidenceRequest = call.nativeRequest || call.rawRequest;
    call.evidenceResponse = call.nativeResponse || call.rawResponse;
    if (isModel) {
        Object.assign(call, describeModelRequest(request), describeModelReply(response, native, attempt));
    } else {
        Object.assign(call, describeToolRequest(response));
    }
    return call;
}

function describeModelRequest(request) {
    if (!request) {
        return { prompt: null };
    }
    const contexts = (request.contexts || []).map((context, index) => ({
        key: `context-${index}`,
        name: context.sourceName || `Context ${index + 1}`,
        content: context.content || '',
        size: `${formatCount((context.content || '').length)} characters`,
        untrusted: context.untrusted !== false,
        truncated: Boolean(context.truncated)
    }));
    const transcript = (request.transcript || []).map((entry, index) => {
        const role = TRANSCRIPT_ROLES[entry.type] || { label: humanize(entry.type), tone: 'input' };
        return {
            key: `turn-${index}`,
            label: entry.toolName ? `${role.label} · ${entry.toolName}` : role.label,
            tone: role.tone,
            className: `turn turn_${role.tone}`,
            content: entry.content || '',
            untrusted: Boolean(entry.untrusted)
        };
    });
    // The tool's own page has its description and schema; the step only names what was offered.
    const tools = (request.tools || []).map((tool) => ({ key: tool.developerName, name: tool.developerName }));
    const used = request.characterCount || 0;
    const limit = request.characterBudget || 0;
    const percent = limit ? Math.min(100, Math.round((used / limit) * 100)) : 0;
    return {
        prompt: {
            model: request.modelName || '',
            instructions: request.instructions || '',
            contexts,
            hasContexts: contexts.length > 0,
            transcript,
            hasTranscript: transcript.length > 0,
            transcriptTruncated: Boolean(request.transcriptTruncated),
            tools,
            hasTools: tools.length > 0,
            contextsLabel: `Context (${contexts.length})`,
            transcriptLabel: `Conversation (${transcript.length})`,
            toolsLabel: `Tools offered (${tools.length})`,
            budgetText: limit ? `${formatCount(used)} of ${formatCount(limit)} characters` : `${formatCount(used)} characters`,
            budgetPercent: percent,
            budgetTone: percent >= 100 ? 'full' : percent >= 80 ? 'high' : 'normal',
            summary: [plural(contexts.length, 'context source'), plural(transcript.length, 'message'), plural(tools.length, 'tool')].join(' · ')
        }
    };
}

function describeModelReply(response, native, attempt) {
    if (!response) {
        return { reply: null };
    }
    const toolCalls = (response.toolCalls || []).map((call, index) => ({
        key: call.toolCallId || `call-${index}`,
        name: call.toolName,
        label: `Calls ${call.toolName}`,
        input: call.toolInput || ''
    }));
    const choice = native && native.response && Array.isArray(native.response.choices) ? native.response.choices[0] || {} : {};
    const usage = (native && native.response && native.response.usage) || {};
    const cached = usage.prompt_tokens_details ? usage.prompt_tokens_details.cached_tokens : null;
    const inputTokens = response.inputTokens ?? (attempt && attempt.InputTokens__c);
    const outputTokens = response.outputTokens ?? (attempt && attempt.OutputTokens__c);
    const facts = [];
    if (inputTokens !== null && inputTokens !== undefined) facts.push({ key: 'in', label: 'Input tokens', value: formatCount(inputTokens) });
    if (cached) facts.push({ key: 'cached', label: 'Cached', value: formatCount(cached) });
    if (outputTokens !== null && outputTokens !== undefined) facts.push({ key: 'out', label: 'Output tokens', value: formatCount(outputTokens) });
    if (choice.finish_reason || response.stopReason) facts.push({ key: 'finish', label: 'Stop reason', value: choice.finish_reason || response.stopReason });
    if (response.providerRequestId) facts.push({ key: 'request', label: 'Provider request', value: response.providerRequestId, mono: true });
    return {
        reply: {
            isFinal: response.isFinal === true,
            output: response.output || '',
            hasOutput: Boolean(response.output),
            toolCalls,
            hasToolCalls: toolCalls.length > 0,
            error: response.isSuccess === false ? explain(response.errorCode, response.errorMessage) : null,
            facts,
            summary: toolCalls.length
                ? `Asked for ${plural(toolCalls.length, 'tool call')}`
                : response.isFinal
                  ? 'Answered'
                  : response.isSuccess === false
                    ? 'Failed'
                    : 'Replied'
        }
    };
}

// Who a tool ran as is the run's, shown once in the header.
function describeToolRequest(response) {
    return {
        toolRun: {
            externalReference: (response && response.externalReference) || '',
            error: response && response.isSuccess === false ? explain(response.errorCode, response.errorMessage) : null
        }
    };
}

/** What this attempt alone took: its own duration and cost. */
function resources(attempt) {
    if (!attempt) {
        return [];
    }
    const items = [];
    if (attempt.DurationMs__c) items.push({ key: 'time', label: formatDuration(attempt.DurationMs__c) });
    if (attempt.EstimatedCostUSD__c) items.push({ key: 'cost', label: formatCost(attempt.EstimatedCostUSD__c) });
    return items;
}

/**
 * Core stores the CPU, SOQL, and DML each attempt used, from its start until
 * Core recorded it, including Core's own work in between. Rows without a
 * Transaction ID come from builds that stored transaction totals instead, so
 * they show nothing rather than a misleading number.
 */
function attemptUsage(attempt) {
    if (!attempt || !attempt.TransactionId__c) {
        return null;
    }
    const has = (value) => value !== null && value !== undefined;
    const parts = [];
    if (has(attempt.CpuTimeMs__c)) parts.push(`${formatCount(attempt.CpuTimeMs__c)} ms CPU`);
    if (has(attempt.SoqlQueries__c)) parts.push(`${attempt.SoqlQueries__c} SOQL`);
    if (has(attempt.DmlStatements__c)) parts.push(`${attempt.DmlStatements__c} DML`);
    if (!parts.length) {
        return null;
    }
    return {
        label: `Used: ${parts.join(' · ')}`,
        help: "Governor limits this attempt used, including Core's own work around the call. Salesforce counts each savepoint as one DML statement. Calls with the same Transaction ID shared one set of limits."
    };
}

export function isTerminal(status) {
    return TERMINAL.has(status);
}
