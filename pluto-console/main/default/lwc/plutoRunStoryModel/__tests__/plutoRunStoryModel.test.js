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

import {
    buildStory,
    collapseRoutine,
    describeCall,
    explain,
    formatCost,
    formatDuration,
    formatOffset,
    highlightJson,
    humanize,
    matchesFilter
} from 'c/plutoRunStoryModel';

const T0 = Date.parse('2026-09-30T17:18:35.000Z');
const at = (seconds) => new Date(T0 + seconds * 1000).toISOString();
const KEY = 'run1';

function command(sequence, type, toolName, extra = {}) {
    return {
        Id: `cmd${sequence}`,
        Sequence__c: sequence,
        CommandType__c: type,
        ToolName__c: toolName,
        Status__c: 'Succeeded',
        OperationKey__c: `${KEY}:${sequence}:${type}${toolName ? `:${toolName}` : ''}`,
        AttemptNumber__c: 1,
        CreatedDate: at(sequence * 3),
        ...extra
    };
}

function invocation(sequence, type, startSeconds, durationMs, extra = {}) {
    return {
        Id: `inv${sequence}-${extra.AttemptNumber__c || 1}`,
        AgentCommand__c: `cmd${sequence}`,
        InvocationType__c: type,
        Outcome__c: 'Succeeded',
        AttemptNumber__c: 1,
        StartedAt__c: at(startSeconds),
        CompletedAt__c: at(startSeconds + durationMs / 1000),
        DurationMs__c: durationMs,
        ...extra
    };
}

function event(sequence, type, seconds, commandKey, payload) {
    return {
        Id: `evt${sequence}`,
        Sequence__c: sequence,
        EventType__c: type,
        OccurredAt__c: at(seconds),
        CommandKey__c: commandKey,
        Payload__c: payload ? JSON.stringify(payload) : null
    };
}

/** The smoke run: approval paused for no approver, rescued, approved, then the budget pause and two rescues. */
function smokeRun(overrides = {}) {
    const run = {
        Id: KEY,
        Name: 'RUN-00000000',
        Status__c: 'Succeeded',
        AgentDefinition__c: 'def1',
        AgentDefinition__r: { Name: 'case_support_openai', MaxModelCalls__c: 8, MaxToolCalls__c: 6 },
        AnchorRecordId__c: '500000000000001',
        InitiatingUser__r: { Name: 'User User' },
        ModelCallCount__c: 6,
        ToolCallCount__c: 5,
        TotalTokenCount__c: 4445,
        StartedAt__c: at(0),
        CompletedAt__c: at(9000),
        Input__c: '{"caseNumber":"00001028","scenario":"case_escalation"}',
        Output__c: '{"recommendedActions":[],"summary":"Case 00001028 was escalated to High."}',
        ...overrides.run
    };
    return {
        run,
        anchorName: '00001028',
        commands: [
            command(1, 'Model'),
            command(2, 'Tool', 'get_case'),
            command(3, 'Model'),
            command(4, 'Tool', 'update_case_priority', { AttemptNumber__c: 3 }),
            command(5, 'Model', null, { CreatedDate: at(8334) }),
            command(6, 'Model', null, { InputSource__c: 'Operator Guidance', CreatedDate: at(8990) })
        ],
        invocations: [
            invocation(1, 'Model', 6, 2307, { TotalTokens__c: 556, EstimatedCostUSD__c: 0.00009, ModelIdentifier__c: 'gpt-4o-mini' }),
            invocation(2, 'Tool', 9, 26),
            invocation(3, 'Model', 10, 1904, { TotalTokens__c: 637, EstimatedCostUSD__c: 0.0001, ModelIdentifier__c: 'gpt-4o-mini' }),
            invocation(4, 'Tool', 8330, 133, { AttemptNumber__c: 3 }),
            invocation(5, 'Model', 8335, 1776, { TotalTokens__c: 785, ModelIdentifier__c: 'gpt-4o-mini' }),
            invocation(6, 'Model', 8995, 1224, { TotalTokens__c: 934, ModelIdentifier__c: 'gpt-4o-mini' })
        ],
        approvals: [
            {
                Id: 'apr1',
                Name: 'APR-00000000',
                AgentCommand__c: 'cmd4',
                Status__c: 'Approved',
                ApproverType__c: 'Queue',
                Owner: { Name: 'Agent Approvers' },
                RequestedBy__r: { Name: 'User User' },
                DecidedBy__r: { Name: 'User User' },
                Reason__c: 'A person must approve a Case priority change.',
                DecisionComment__c: 'Customer is on the premium plan.',
                CreatedDate: at(8200),
                ClosedAt__c: at(8320)
            }
        ],
        events: [
            event(1, 'Run Started', 0),
            event(2, 'Input Accepted', 1, `${KEY}:1:Model`),
            event(3, 'Tool Requested', 8, `${KEY}:2:Tool:get_case`),
            event(4, 'Tool Completed', 9, `${KEY}:2:Tool:get_case`),
            event(5, 'Tool Requested', 12, `${KEY}:4:Tool:update_case_priority`),
            event(6, 'Run Paused', 13, `${KEY}:4:Tool:update_case_priority`),
            event(7, 'Run Rescued', 8190, `${KEY}:4:Tool:update_case_priority`, {
                mode: 'rearm_failed',
                pausedErrorCode: 'APPROVAL_ASSIGNMENT_UNRESOLVED',
                actorId: '005u1'
            }),
            event(8, 'Run Waiting', 8200, `${KEY}:4:Tool:update_case_priority`, { approvalId: 'apr1', approverType: 'Queue' }),
            event(9, 'Run Resumed', 8320, `${KEY}:4:Tool:update_case_priority`, { approvalId: 'apr1' }),
            event(10, 'Tool Completed', 8330, `${KEY}:4:Tool:update_case_priority`),
            event(11, 'Run Paused', 8337, `${KEY}:5:Model`),
            event(12, 'Run Rescued', 8990, `${KEY}:6:Model`, { mode: 'reflect_new_model', pausedErrorCode: 'BUDGET_EXCEEDED' }),
            event(13, 'Configuration Changed', 8991, `${KEY}:6:Model`),
            event(14, 'Run Completed', 9000, `${KEY}:6:Model`)
        ],
        truncated: false,
        userNames: { '005u1': 'User User' },
        ...overrides.story
    };
}

/** The smoke run while it is still paused at its budget, before the last rescue. */
function pausedAtBudget() {
    const data = smokeRun({ run: { Status__c: 'Paused', CompletedAt__c: null, ErrorCode__c: 'BUDGET_EXCEEDED' } });
    data.events = data.events.slice(0, 11);
    data.commands = data.commands.slice(0, 5);
    return data;
}

describe('plutoRunStoryModel', () => {
    it('tells the model decision in words and names the answer', () => {
        const story = buildStory(smokeRun(), T0 + 9000 * 1000);
        const steps = story.timeline.filter((item) => item.type === 'step');
        expect(steps.map((step) => step.title)).toEqual([
            'Decided to call Get case',
            'Get case',
            'Decided to call Update case priority',
            'Update case priority',
            'Decided to call a tool',
            'Wrote the final answer'
        ]);
        expect(steps[4].subtitle).toBe('Paused before the tool ran');
        expect(steps[5].subtitle).toBe('');
    });

    it('names the tools a paused model step chose from its recorded reply', () => {
        const story = buildStory(smokeRun({ story: { requestedTools: { cmd5: ['simulate_escalation_notification'] } } }), T0 + 9000 * 1000);
        const step = story.timeline.find((item) => item.commandId === 'cmd5');
        expect(step.title).toBe('Decided to call Simulate escalation notification');
        expect(step.subtitle).toBe('Paused before the tool ran');
    });

    it('shows the agent explanation on tool steps only', () => {
        const data = smokeRun();
        data.commands[1].Rationale__c = 'Read the case before changing its priority.';
        data.commands[0].Rationale__c = 'Model commands never carry one.';
        const story = buildStory(data, T0 + 9000 * 1000);
        expect(story.timeline.find((item) => item.commandId === 'cmd2').rationale).toBe('Read the case before changing its priority.');
        expect(story.timeline.find((item) => item.commandId === 'cmd1').rationale).toBeNull();
        expect(story.timeline.find((item) => item.commandId === 'cmd4').rationale).toBeNull();
    });

    it('orders steps and run moments by event sequence', () => {
        const story = buildStory(smokeRun(), T0 + 9000 * 1000);
        const order = story.timeline.filter((item) => item.type !== 'gap').map((item) => (item.type === 'step' ? item.commandId : item.title));
        expect(order).toEqual([
            'Run started',
            'cmd1',
            'cmd2',
            'cmd3',
            'Paused for 2 h 16 m: No one could approve this call',
            'cmd4',
            'cmd5',
            'Paused for 10 m 53 s: The run used its whole budget',
            'cmd6',
            'Run succeeded'
        ]);
    });

    it('folds each pause, its rescue, and the setup change into one row that says who did what', () => {
        const story = buildStory(smokeRun(), T0 + 9000 * 1000);
        expect(story.timeline.some((item) => item.kind === 'operator' || item.kind === 'config')).toBe(false);
        const pauses = story.timeline.filter((item) => item.kind === 'pause');
        expect(pauses.map((pause) => pause.detail)).toEqual([
            'User User retried Update case priority.',
            "An operator changed the agent's setup and resumed the run."
        ]);
        expect(pauses[0]).toMatchObject({ at: T0 + 13 * 1000, resumedAt: T0 + 8190 * 1000, endAt: T0 + 8190 * 1000, hasIssue: true });
    });

    it('names the limits an operator raised before resuming', () => {
        const data = smokeRun();
        data.events[11] = event(12, 'Run Rescued', 8990, `${KEY}:6:Model`, { mode: 'reflect_new_model', actorId: '005u1' });
        data.events[12] = event(13, 'Configuration Changed', 8991, `${KEY}:6:Model`, {
            changes: [
                { setting: 'Max Tool Calls', before: 3, after: 4 },
                { setting: 'Max Model Calls', before: 7, after: 5 },
                { tool: 'lookup_order', change: 'added' },
                { setting: 'Instructions' }
            ]
        });
        const pause = buildStory(data, T0 + 9000 * 1000).timeline.filter((item) => item.kind === 'pause')[1];
        expect(pause.detail).toBe(
            'User User raised Max Tool Calls from 3 to 4, lowered Max Model Calls from 7 to 5, made 2 other changes, and resumed the run.'
        );
        data.events[12] = event(13, 'Configuration Changed', 8991, `${KEY}:6:Model`, { changes: [{ setting: 'Max Tool Calls', before: 3, after: 4 }] });
        expect(buildStory(data, T0 + 9000 * 1000).timeline.filter((item) => item.kind === 'pause')[1].detail).toBe(
            'User User raised Max Tool Calls from 3 to 4 and resumed the run.'
        );
    });

    it('places a rescued step where it ran, after the pause', () => {
        const story = buildStory(smokeRun(), T0 + 9000 * 1000);
        const index = story.timeline.findIndex((item) => item.commandId === 'cmd4');
        expect(story.timeline[index - 1].kind).toBe('pause');
        expect(story.timeline[index].at).toBe(T0 + 8190 * 1000);
    });

    it('shows a setup change no rescue explains just before the step that used it', () => {
        const data = smokeRun();
        // Core notices the change when cmd3 finishes, after cmd3 began.
        data.events.push(
            event(15, 'Configuration Changed', 11, `${KEY}:3:Model`, { changes: [{ setting: 'Instructions' }, { context: 'case_history', change: 'removed' }] })
        );
        const story = buildStory(data, T0 + 9000 * 1000);
        const index = story.timeline.findIndex((item) => item.kind === 'config');
        expect(story.timeline[index]).toMatchObject({
            title: 'Agent setup changed',
            detail: 'Changed Instructions and removed the Case history context. Later steps use the new setup.',
            at: story.timeline[index + 1].at
        });
        expect(story.timeline[index + 1].commandId).toBe('cmd3');
    });

    it('says which budget ran out and by how much', () => {
        const data = pausedAtBudget();
        data.events[10] = event(11, 'Run Paused', 8337, `${KEY}:5:Model`, {
            errorCode: 'BUDGET_EXCEEDED',
            budget: { exceeded: 'tool', modelCalls: 3, maxModelCalls: 5, requestedModelCalls: 0, toolCalls: 2, maxToolCalls: 2, requestedToolCalls: 1 }
        });
        const pause = buildStory(data, T0 + 9000 * 1000).timeline.filter((item) => item.kind === 'pause')[1];
        expect(pause.title).toBe('Paused: Out of tool calls');
        expect(pause.detail).toBe(
            'After the model call. The run had used 2 of the 2 tool calls the agent allowed, and the next step needed 1 more. Raise Max Tool Calls on the agent, then rescue the run.'
        );
    });

    it('tells the operator to raise both limits when tool and model calls are both used up', () => {
        const data = smokeRun({
            run: { Status__c: 'Paused', CompletedAt__c: null, ErrorCode__c: 'BUDGET_EXCEEDED', ErrorMessage__c: 'The next step needs 1 more tool call(s).' }
        });
        data.events = data.events.slice(0, 11);
        data.events[10] = event(11, 'Run Paused', 8337, `${KEY}:5:Model`, {
            errorCode: 'BUDGET_EXCEEDED',
            budget: { exceeded: 'tool', modelCalls: 3, maxModelCalls: 3, requestedModelCalls: 0, toolCalls: 3, maxToolCalls: 3, requestedToolCalls: 1 }
        });
        const { attention } = buildStory(data, T0 + 9000 * 1000);
        expect(attention).toMatchObject({
            title: 'Out of tool calls',
            detail: "The run had used 3 of the 3 tool calls the agent allowed, and the next step needed 1 more. Model calls are used up too, and the agent needs one to read the tool's result.",
            action: 'Raise Max Tool Calls and Max Model Calls on the agent, then rescue the run.',
            message: ''
        });
    });

    it('works out an older budget pause after a tool from the model calls made', () => {
        const data = pausedAtBudget();
        data.events[10] = event(11, 'Run Paused', 8337, `${KEY}:4:Tool:update_case_priority`);
        const pause = buildStory(data, T0 + 9000 * 1000).timeline.filter((item) => item.kind === 'pause')[1];
        expect(pause.title).toBe('Paused: Out of model calls');
        expect(pause.detail).toMatch(/^After Update case priority\. The run had used all 3 model calls the agent allowed/);
    });

    it('takes a pause reason from the rescue that ended it', () => {
        const story = buildStory(smokeRun(), T0 + 9000 * 1000);
        const pauses = story.timeline.filter((item) => item.kind === 'pause');
        expect(pauses.map((pause) => pause.code)).toEqual(['APPROVAL_ASSIGNMENT_UNRESOLVED', 'BUDGET_EXCEEDED']);
    });

    it('marks long idle stretches and says why, but not a pause its row already measures', () => {
        const resumed = buildStory(smokeRun(), T0 + 9000 * 1000).timeline.filter((item) => item.type === 'gap');
        expect(resumed.some((gap) => /paused$/.test(gap.title))).toBe(false);
        const open = buildStory(pausedAtBudget(), T0 + 9000 * 1000).timeline.filter((item) => item.type === 'gap');
        expect(open[open.length - 1].title).toMatch(/paused$/);
    });

    it('folds the approval into its step with who decided, how long it took, and what they wrote', () => {
        const story = buildStory(smokeRun(), T0 + 9000 * 1000);
        const tool = story.timeline.find((item) => item.commandId === 'cmd4');
        expect(tool.approvals[0].summary).toBe('Approved by User User after 2 m');
        expect(tool.approvals[0].comment).toBe('Customer is on the premium plan.');
        // Two dispatches paused before the tool ran; only the one run counts as an attempt.
        expect(tool.chips.some((chip) => chip.kind === 'attempts')).toBe(false);
        expect(story.timeline.some((item) => item.title === 'Resumed')).toBe(false);
    });

    it('accounts for where the time went', () => {
        const story = buildStory(smokeRun(), T0 + 9000 * 1000);
        const byKind = Object.fromEntries(story.timeBreakdown.map((entry) => [entry.kind, entry.ms]));
        expect(byKind.model).toBe(2307 + 1904 + 1776 + 1224);
        expect(byKind.tool).toBe(26 + 133);
        expect(byKind.approval).toBe(120000);
        expect(byKind.paused).toBeGreaterThan(8000 * 1000);
        const total = story.timeBreakdown.reduce((sum, entry) => sum + entry.ms, 0);
        expect(total).toBe(9000 * 1000);
    });

    it('shows budgets and flags a limit that is reached', () => {
        const story = buildStory(
            smokeRun({
                run: {
                    Status__c: 'Paused',
                    CompletedAt__c: null,
                    ErrorCode__c: 'BUDGET_EXCEEDED',
                    ModelCallCount__c: 5,
                    AgentDefinition__r: { Name: 'a', MaxModelCalls__c: 5, MaxToolCalls__c: 6 }
                }
            }),
            T0 + 9000 * 1000
        );
        const [models, tools] = story.header.budgets;
        expect(models).toMatchObject({ used: 5, max: 5, tone: 'full', percent: 100 });
        expect(tools).toMatchObject({ used: 5, max: 6, tone: 'high' });
        expect(story.attention).toMatchObject({ heading: 'Needs an operator', title: 'The run used its whole budget', canOperate: true });
        expect(story.isLive).toBe(true);
        expect(story.timeline[story.timeline.length - 1].title).toBe('Paused now');
    });

    it('does not flag a limit that a finished run reached on its last call', () => {
        const story = buildStory(
            smokeRun({ run: { ModelCallCount__c: 4, ToolCallCount__c: 4, AgentDefinition__r: { Name: 'a', MaxModelCalls__c: 4, MaxToolCalls__c: 6 } } }),
            T0 + 9000 * 1000
        );
        const [models, tools] = story.header.budgets;
        expect(models).toMatchObject({ used: 4, max: 4, tone: 'high', percent: 100 });
        expect(tools).toMatchObject({ used: 4, max: 6, tone: 'normal' });
    });

    it('flags a reached limit only while the budget is what stopped the run', () => {
        const limits = { ModelCallCount__c: 5, AgentDefinition__r: { Name: 'a', MaxModelCalls__c: 5, MaxToolCalls__c: 6 } };
        const running = buildStory(smokeRun({ run: { ...limits, Status__c: 'Running', CompletedAt__c: null } }), T0 + 9000 * 1000);
        expect(running.header.budgets[0].tone).toBe('high');
        const otherPause = buildStory(
            smokeRun({ run: { ...limits, Status__c: 'Paused', CompletedAt__c: null, ErrorCode__c: 'TOOL_AUTHORIZATION_POLICY_ERROR' } }),
            T0 + 9000 * 1000
        );
        expect(otherPause.header.budgets[0].tone).toBe('high');
        const failed = buildStory(smokeRun({ run: { ...limits, Status__c: 'Failed', ErrorCode__c: 'BUDGET_EXCEEDED' } }), T0 + 9000 * 1000);
        expect(failed.header.budgets[0].tone).toBe('full');
    });

    it('counts a conversation budget from the latest reply and shows the token budget', () => {
        const story = buildStory(
            smokeRun({
                run: {
                    Status__c: 'Running',
                    CompletedAt__c: null,
                    ModelCallCount__c: 12,
                    ToolCallCount__c: 9,
                    TotalTokenCount__c: 50000,
                    ReplyModelCallBase__c: 10,
                    ReplyToolCallBase__c: 8,
                    ReplyTokenBase__c: 40000,
                    AgentDefinition__r: { Name: 'a', MaxModelCalls__c: 10, MaxToolCalls__c: 15, MaxTotalTokens__c: 250000 }
                }
            }),
            T0 + 9000 * 1000
        );
        const [models, tools, tokens] = story.header.budgets;
        expect(models).toMatchObject({ key: 'modelCalls', label: 'Model calls this reply', used: 2, max: 10 });
        expect(tools).toMatchObject({ key: 'toolCalls', label: 'Tool calls this reply', used: 1, max: 15 });
        expect(tokens).toMatchObject({ key: 'tokens', label: 'Tokens this reply', used: 10000, max: 250000 });
    });

    it('reports model attempts whose tokens were estimated', () => {
        const story = buildStory(smokeRun({ run: { UnmeteredModelAttempts__c: 2 } }), T0 + 9000 * 1000);
        expect(story.header.unmeteredAttempts).toBe(2);
    });

    it('points a waiting run at its pending approval', () => {
        const data = smokeRun({ run: { Status__c: 'Waiting', CompletedAt__c: null } });
        data.approvals[0] = { ...data.approvals[0], Status__c: 'Pending', ClosedAt__c: null, DecidedBy__r: null, ExpiresAt__c: at(8200 + 86400) };
        const story = buildStory(data, T0 + 8260 * 1000);
        expect(story.attention).toMatchObject({ heading: 'Waiting for approval', title: 'Agent Approvers needs to decide', approvalId: 'apr1' });
        expect(story.attention.action).toMatch(/^It expires in 23 h 59 m/);
        expect(story.attention.actionIcon).toBe('utility:clock');
    });

    it('colours a rejected tool without calling it a fault', () => {
        const data = smokeRun();
        data.commands[3] = { ...data.commands[3], Status__c: 'Failed', ErrorCode__c: 'TOOL_APPROVAL_DENIED' };
        data.approvals[0] = { ...data.approvals[0], Status__c: 'Rejected' };
        const story = buildStory(data, T0);
        const step = story.timeline.find((item) => item.key === 'cmd4');
        expect(step).toMatchObject({ status: 'Failed', statusLabel: 'Rejected', tone: 'error', error: null, hasIssue: false });
        expect(step.approvals[0].tone).toBe('error');
        expect(step.approvals[0].outcome).toBe('The tool did not run. The agent was told and continued without it.');
        expect(step.outputEmptyText).toBe('No result. The tool did not run.');
        expect(story.counts.issue).toBe(buildStory(smokeRun(), T0).counts.issue);
    });

    it('marks the final answer with a check and an operator-steered step with a person', () => {
        const final = buildStory(smokeRun(), T0).timeline.find((item) => item.key === 'cmd6');
        expect(final).toMatchObject({ title: 'Wrote the final answer', icon: 'utility:check' });
        const data = smokeRun();
        data.commands.push(command(7, 'Tool', 'get_case', { CreatedDate: at(8999) }));
        const guided = buildStory(data, T0).timeline.find((item) => item.key === 'cmd6');
        expect(guided.icon).toBe('utility:user');
    });

    it('colours a cancelled run and a mid-run configuration change', () => {
        const data = smokeRun({ run: { Status__c: 'Cancelled' } });
        data.events.push(event(20, 'Configuration Changed', 20), event(21, 'Run Cancellation Requested', 8996), event(22, 'Run Cancelled', 8997));
        const story = buildStory(data, T0);
        const tones = Object.fromEntries(story.timeline.filter((item) => item.type === 'marker').map((item) => [item.title, item.tone]));
        expect(story.header.tone).toBe('warning');
        expect(tones).toMatchObject({ 'Agent setup changed': 'info', 'Cancellation requested': 'warning', 'Run cancelled': 'warning' });
    });

    it('flags a rejection beside the status of a run that still succeeded', () => {
        const data = smokeRun();
        data.commands[3] = { ...data.commands[3], Status__c: 'Failed', ErrorCode__c: 'TOOL_APPROVAL_DENIED' };
        data.approvals = [
            { ...data.approvals[0], Status__c: 'Rejected', CreatedDate: at(8100), ClosedAt__c: at(8110) },
            { ...data.approvals[0], Id: 'apr2', Status__c: 'Rejected' }
        ];
        const story = buildStory(data, T0);
        expect(story.header.status).toBe('Succeeded');
        expect(story.highlights[0]).toEqual({ key: 'rejected', tone: 'error', label: '2 approvals rejected', targetKey: 'cmd4' });
        const smooth = smokeRun();
        smooth.events = smooth.events.filter((entry) => !['Run Paused', 'Run Rescued'].includes(entry.EventType__c));
        expect(buildStory(smooth, T0).highlights).toEqual([]);
    });

    it('flags a run that only finished after operators resumed it', () => {
        expect(buildStory(smokeRun(), T0 + 9000 * 1000).highlights).toEqual([
            { key: 'paused', tone: 'warning', label: 'Paused 2 times · 2 h 27 m', targetKey: 'evt6' }
        ]);
    });

    it('leaves the flags to the attention box when the run stopped', () => {
        const data = smokeRun();
        data.run = { ...data.run, Status__c: 'Failed', LastErrorCode__c: 'MODEL_CALL_FAILED' };
        data.commands[3] = { ...data.commands[3], Status__c: 'Failed', ErrorCode__c: 'TOOL_APPROVAL_DENIED' };
        data.approvals[0] = { ...data.approvals[0], Status__c: 'Rejected' };
        const story = buildStory(data, T0);
        expect(story.attention.tone).toBe('error');
        expect(story.highlights).toEqual([]);
    });

    it('keeps an expired approval among the issues, without a second error box', () => {
        const data = smokeRun();
        data.commands[3] = { ...data.commands[3], Status__c: 'Failed', ErrorCode__c: 'TOOL_APPROVAL_EXPIRED' };
        data.approvals[0] = { ...data.approvals[0], Status__c: 'Expired' };
        const step = buildStory(data, T0).timeline.find((item) => item.key === 'cmd4');
        expect(step).toMatchObject({ statusLabel: 'Not run', tone: 'warning', error: null, hasIssue: true });
        expect(step.approvals[0].outcome).toBe('The tool did not run because no one decided in time.');
    });

    it('still explains a rejection when the approval cannot be seen', () => {
        const data = smokeRun();
        data.commands[3] = { ...data.commands[3], Status__c: 'Failed', ErrorCode__c: 'TOOL_APPROVAL_DENIED' };
        data.approvals = [];
        const step = buildStory(data, T0).timeline.find((item) => item.key === 'cmd4');
        expect(step.statusLabel).toBe('Failed');
        expect(step.error.title).toBe('The approver rejected the call');
    });

    it('ends the approval reason with one full stop and says the tool has not run yet', () => {
        const data = smokeRun({ run: { Status__c: 'Waiting', CompletedAt__c: null } });
        data.approvals[0] = {
            ...data.approvals[0],
            Status__c: 'Pending',
            ClosedAt__c: null,
            DecidedBy__r: null,
            Reason__c: 'Refunds over 200 need Finance approval.'
        };
        const story = buildStory(data, T0 + 8260 * 1000);
        expect(story.attention.detail).toMatch(/: Refunds over 200 need Finance approval\.$/);
        const step = story.timeline.find((item) => item.type === 'step' && item.hasApprovals);
        expect(step.outputEmptyText).toBe('No result yet. The tool runs only if the approver approves.');
        const model = story.timeline.find((item) => item.type === 'step' && item.kind === 'model');
        expect(model.outputEmptyText).toContain("The model's reply was the tool calls that follow");
    });

    it('pulls the headline out of a JSON answer', () => {
        const story = buildStory(smokeRun(), T0);
        expect(story.outcome.headline).toBe('Case 00001028 was escalated to High.');
    });

    it('explains an empty input instead of showing {}', () => {
        const fromRecord = buildStory({ ...smokeRun({ run: { Input__c: '{}' } }), anchorName: '00001029' }, T0);
        expect(fromRecord.outcome.input).toBe('');
        expect(fromRecord.outcome.inputEmptyText).toMatch(/started from 00001029/);

        const noRecord = buildStory({ ...smokeRun({ run: { Input__c: '{}', AnchorRecordId__c: null } }), anchorName: null }, T0);
        expect(noRecord.outcome.inputEmptyText).toBe('No input. The agent started from its instructions.');

        const asked = buildStory(smokeRun({ run: { Input__c: '{"request":"Triage"}' } }), T0);
        expect(asked.outcome.input).toBe('{"request":"Triage"}');
    });

    it('filters to issues only', () => {
        const story = buildStory(smokeRun(), T0 + 9000 * 1000);
        const issues = story.timeline.filter((item) => matchesFilter(item, 'issue'));
        expect(issues.map((item) => item.kind)).toEqual(['pause', 'pause']);
        expect(story.counts.issue).toBe(2);
        expect(story.counts.approval).toBe(1);
    });
});

describe('formatting helpers', () => {
    it('formats durations across scales', () => {
        expect(formatDuration(26)).toBe('26 ms');
        expect(formatDuration(2307)).toBe('2.3 s');
        expect(formatDuration(125000)).toBe('2 m 5 s');
        expect(formatDuration(8177000)).toBe('2 h 16 m');
        expect(formatDuration(3 * 86400000 + 3600000)).toBe('3 d 1 h');
    });

    it('formats tiny costs without rounding them to zero', () => {
        expect(formatCost(0.00009105)).toBe('$0.000091');
        expect(formatCost(1.234)).toBe('$1.23');
        expect(formatCost(0)).toBe('');
    });

    it('humanizes tool and field names', () => {
        expect(humanize('update_case_priority')).toBe('Update case priority');
        expect(humanize('caseNumber')).toBe('Case number');
    });

    it('explains provider errors by their shape', () => {
        expect(explain('OPENAI_API_429_RATE_LIMIT_EXCEEDED').title).toBe('The model provider was unavailable');
        expect(explain('OPENAI_API_401_INVALID_API_KEY').title).toBe('The model provider rejected the request');
        expect(explain('SOMETHING_NEW', 'raw message')).toMatchObject({ title: 'Something new', detail: 'raw message' });
    });

    it('highlights sensitive tokens in JSON', () => {
        const { tokens, isJson } = highlightJson('{"email":"{{EMAIL_3_9f2c61ab}}","n":1}');
        expect(isJson).toBe(true);
        expect(tokens.find((token) => token.cls === 'json-sensitive').value).toBe('"{{EMAIL_3_9f2c61ab}}"');
        expect(tokens.find((token) => token.cls === 'json-number').value).toBe('1');
    });
});

describe('describeCall', () => {
    const modelRequest = {
        characterBudget: 50000,
        characterCount: 45000,
        instructions: 'Triage the case.',
        modelName: 'gpt-4o-mini',
        contexts: [{ sourceName: 'Case triage', content: '{"priority":"Medium"}', untrusted: true, truncated: false }],
        transcript: [
            { type: 'OriginalInput', content: '{"caseNumber":"00001028"}', untrusted: true },
            { type: 'ToolCall', toolName: 'get_case', content: '{"caseNumber":"00001028"}' },
            { type: 'OperatorGuidance', content: 'Continue.' }
        ],
        tools: [{ developerName: 'get_case', description: 'Reads a case', requiresApproval: false, inputSchema: '{"type":"object"}' }],
        outputSchema: '{"type":"object"}'
    };
    const modelResponse = {
        isSuccess: true,
        isFinal: false,
        inputTokens: 539,
        outputTokens: 17,
        providerRequestId: 'chatcmpl-1',
        toolCalls: [{ toolCallId: 'call_1', toolName: 'get_case', toolInput: '{"caseNumber":"00001028"}' }]
    };
    const native = {
        request: { model: 'gpt-4o-mini', messages: [] },
        response: { choices: [{ finish_reason: 'tool_calls' }], usage: { prompt_tokens_details: { cached_tokens: 128 } } }
    };

    it('reads a model call as a prompt and a reply', () => {
        const call = describeCall(
            {
                Id: 'inv1',
                InvocationType__c: 'Model',
                AttemptNumber__c: 1,
                DurationMs__c: 2307,
                CpuTimeMs__c: 267,
                SoqlQueries__c: 23,
                DmlStatements__c: 7,
                TransactionId__c: 'txn-1'
            },
            {
                AttemptNumber__c: 1,
                Request__c: JSON.stringify(modelRequest),
                Response__c: JSON.stringify(modelResponse),
                NativeEvidence__c: JSON.stringify(native),
                EvidenceMetadata__c: '{"request":{"redacted":true,"truncated":false}}'
            }
        );
        expect(call.isModel).toBe(true);
        expect(call.tokenized).toBe(true);
        expect(call.prompt.summary).toBe('1 context source · 3 messages · 1 tool');
        expect(call.prompt).toMatchObject({ budgetText: '45,000 of 50,000 characters', budgetTone: 'high' });
        expect(call.prompt.transcript.map((turn) => turn.label)).toEqual(['Input', 'Tool call · get_case', 'Operator guidance']);
        expect(call.reply.summary).toBe('Asked for 1 tool call');
        expect(call.reply.facts.map((fact) => `${fact.label}=${fact.value}`)).toEqual([
            'Input tokens=539',
            'Cached=128',
            'Output tokens=17',
            'Stop reason=tool_calls',
            'Provider request=chatcmpl-1'
        ]);
        expect(call.resources.map((resource) => resource.label)).toEqual(['2.3 s']);
        expect(call.usage.label).toBe('Used: 267 ms CPU · 23 SOQL · 7 DML');
        const olderRow = describeCall(
            { Id: 'old', InvocationType__c: 'Model', AttemptNumber__c: 1, CpuTimeMs__c: 267, SoqlQueries__c: 23 },
            { AttemptNumber__c: 1 }
        );
        expect(olderRow.usage).toBeNull();
        expect(call.hasNative).toBe(true);
        expect(JSON.parse(call.evidenceRequest)).toEqual(native.request);
        expect(JSON.parse(call.evidenceResponse)).toEqual(native.response);
    });

    it('reads a tool call as its outcome, leaving who it ran as to the header', () => {
        const call = describeCall(
            { Id: 'inv2', InvocationType__c: 'Tool', AttemptNumber__c: 1 },
            {
                AttemptNumber__c: 1,
                Request__c: JSON.stringify({
                    toolName: 'get_case',
                    principal: { executionIdentityId: 'a0X000000000001AAA', resolvedPrincipalUserId: '005A', attendedByUserId: '005B' }
                }),
                Response__c: '{"isSuccess":true,"externalReference":"ext-1"}'
            }
        );
        expect(call.isModel).toBe(false);
        expect(call.toolRun).toEqual({ externalReference: 'ext-1', error: null });
        expect(call.evidenceResponse).toBe('{"isSuccess":true,"externalReference":"ext-1"}');
    });

    it('has no evidence when the viewer cannot read it', () => {
        const call = describeCall({ Id: 'inv3', InvocationType__c: 'Model', AttemptNumber__c: 1 }, { AttemptNumber__c: 1 });
        expect(call.hasEvidence).toBe(false);
        expect(call.prompt).toBeNull();
    });
});

describe('collapseRoutine', () => {
    const step = (index, extra = {}) => ({
        key: `s${index}`,
        type: 'step',
        kind: index % 2 ? 'tool' : 'model',
        status: 'Succeeded',
        hasApprovals: false,
        at: index,
        endAt: index,
        activeMs: 100,
        tokens: 10,
        ...extra
    });

    it('leaves short runs alone', () => {
        const items = Array.from({ length: 10 }, (unused, index) => step(index));
        expect(collapseRoutine(items)).toBe(items);
    });

    it('folds uneventful steps and keeps issues, approvals, and kept steps apart', () => {
        const items = Array.from({ length: 14 }, (unused, index) => step(index));
        items[5] = step(5, { status: 'Failed', hasIssue: true });
        items[9] = step(9, { hasApprovals: true });
        const result = collapseRoutine(items, new Set(['s12']));
        expect(result.map((item) => item.key)).toEqual(['group-s0', 's5', 'group-s6', 's9', 's10', 's11', 's12', 's13']);
        expect(result[0].title).toBe('5 steps succeeded');
        expect(result[0].detail).toBe('3 model calls, 2 tool calls · 500 ms working · 50 tokens');
        expect(result[0].stepKeys).toEqual(['s0', 's1', 's2', 's3', 's4']);
    });
});

describe('formatOffset', () => {
    it('shows time since the start', () => {
        expect(formatOffset(42000)).toBe('+0:42');
        expect(formatOffset(3723000)).toBe('+1:02:03');
        expect(formatOffset(null)).toBe('');
    });
});

describe('attention focus', () => {
    it('points at the failing step', () => {
        const story = buildStory(
            {
                run: { Status__c: 'Failed', ErrorCode__c: 'RETRY_EXHAUSTED', StartedAt__c: at(0), CompletedAt__c: at(20) },
                commands: [command(1, 'Model'), command(2, 'Tool', 'get_case', { Status__c: 'Failed', ErrorCode__c: 'RETRY_EXHAUSTED' })],
                invocations: [],
                approvals: [],
                events: []
            },
            T0 + 30000
        );
        expect(story.attention.focusKey).toBe('cmd2');
    });
});
