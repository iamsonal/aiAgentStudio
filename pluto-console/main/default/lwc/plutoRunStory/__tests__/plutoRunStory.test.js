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

import { createElement } from 'lwc';
import { registerSa11yMatcher } from '@sa11y/jest';
import PlutoRunStory from 'c/plutoRunStory';
import getStory from '@salesforce/apex/PlutoRunStoryController.getStory';
import getStepDetail from '@salesforce/apex/PlutoRunStoryController.getStepDetail';
import { subscribe, isEmpEnabled } from 'lightning/empApi';

jest.mock('@salesforce/apex/PlutoRunStoryController.getStory', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/PlutoRunStoryController.getStepDetail', () => ({ default: jest.fn() }), { virtual: true });

const T0 = Date.parse('2026-09-30T17:18:35.000Z');
const at = (seconds) => new Date(T0 + seconds * 1000).toISOString();

function story(runOverrides = {}) {
    return {
        run: {
            Id: 'a07000000000001AAA',
            Name: 'RUN-00000001',
            Status__c: 'Succeeded',
            AgentDefinition__c: 'a03000000000001AAA',
            AgentDefinition__r: { Name: 'Case support', MaxModelCalls__c: 5, MaxToolCalls__c: 4 },
            ModelCallCount__c: 2,
            ToolCallCount__c: 1,
            TotalTokenCount__c: 1200,
            StartedAt__c: at(0),
            CompletedAt__c: at(10),
            Input__c: '{"caseNumber":"00001028"}',
            Output__c: '{"summary":"All done."}',
            ...runOverrides
        },
        commands: [
            { Id: 'a01000000000001AAA', Sequence__c: 1, CommandType__c: 'Model', Status__c: 'Succeeded', OperationKey__c: 'k:1:Model', CreatedDate: at(1) },
            {
                Id: 'a01000000000002AAA',
                Sequence__c: 2,
                CommandType__c: 'Tool',
                ToolName__c: 'get_case',
                Status__c: 'Succeeded',
                OperationKey__c: 'k:2:Tool:get_case',
                CreatedDate: at(3)
            },
            { Id: 'a01000000000003AAA', Sequence__c: 3, CommandType__c: 'Model', Status__c: 'Succeeded', OperationKey__c: 'k:3:Model', CreatedDate: at(5) }
        ],
        invocations: [
            {
                Id: 'i1',
                AgentCommand__c: 'a01000000000001AAA',
                StartedAt__c: at(1),
                DurationMs__c: 1500,
                TotalTokens__c: 600,
                ModelIdentifier__c: 'gpt-4o-mini'
            },
            { Id: 'i2', AgentCommand__c: 'a01000000000002AAA', StartedAt__c: at(3), DurationMs__c: 40 },
            {
                Id: 'i3',
                AgentCommand__c: 'a01000000000003AAA',
                StartedAt__c: at(5),
                DurationMs__c: 1200,
                TotalTokens__c: 600,
                ModelIdentifier__c: 'gpt-4o-mini'
            }
        ],
        approvals: [],
        events: [
            { Id: 'e1', Sequence__c: 1, EventType__c: 'Run Started', OccurredAt__c: at(0) },
            { Id: 'e2', Sequence__c: 2, EventType__c: 'Input Accepted', OccurredAt__c: at(1), CommandKey__c: 'k:1:Model' },
            { Id: 'e3', Sequence__c: 3, EventType__c: 'Tool Requested', OccurredAt__c: at(3), CommandKey__c: 'k:2:Tool:get_case' },
            { Id: 'e4', Sequence__c: 4, EventType__c: 'Run Completed', OccurredAt__c: at(10), CommandKey__c: 'k:3:Model' }
        ],
        truncated: false
    };
}

/** A succeeded run with many uneventful steps, alternating model and tool. */
function longStory(count) {
    const data = story();
    data.commands = Array.from({ length: count }, (unused, index) => {
        const isModel = index % 2 === 0;
        return {
            Id: `a01000000000${String(index).padStart(3, '0')}AAA`,
            Sequence__c: index + 1,
            CommandType__c: isModel ? 'Model' : 'Tool',
            ToolName__c: isModel ? undefined : 'get_case',
            Status__c: 'Succeeded',
            OperationKey__c: `k:${index + 1}:${isModel ? 'Model' : 'Tool:get_case'}`,
            CreatedDate: at(index)
        };
    });
    data.invocations = [];
    data.events = [{ Id: 'e1', Sequence__c: 1, EventType__c: 'Run Started', OccurredAt__c: at(0) }];
    return data;
}

async function flush() {
    for (let i = 0; i < 4; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
}

async function render(data) {
    getStory.mockResolvedValue(data);
    const element = createElement('c-pluto-run-story', { is: PlutoRunStory });
    element.recordId = 'a07000000000001AAA';
    document.body.appendChild(element);
    await flush();
    return element;
}

describe('c-pluto-run-story', () => {
    beforeAll(() => {
        registerSa11yMatcher();
        // jsdom has no layout, so it has no scrollIntoView.
        Element.prototype.scrollIntoView = jest.fn();
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders the header, the answer, and the steps in order', async () => {
        const element = await render(story());
        const root = element.shadowRoot;
        expect(getStory).toHaveBeenCalledWith({ runId: 'a07000000000001AAA' });
        expect(root.querySelector('.run-name').textContent).toBe('Case support');
        expect(root.querySelector('.headline').textContent).toContain('All done.');
        const titles = [...root.querySelectorAll('.card-title')].map((node) => node.textContent);
        expect(titles).toEqual(['Decided to call Get case', 'Get case', 'Wrote the final answer']);
        expect(root.querySelector('.attention')).toBeNull();
    });

    it('leads with the answer in a header coloured by the run status', async () => {
        const element = await render(story());
        const head = element.shadowRoot.querySelector('header');
        expect(head.className).toContain('head_success');
        expect(head.querySelector('.eyebrow').textContent).toContain('RUN-00000001');
        expect(head.querySelector('.headline').textContent).toContain('All done.');
        expect(element.shadowRoot.querySelector('.outcome .headline')).toBeNull();
    });

    it('does not subscribe for live updates once a run has finished', async () => {
        await render(story());
        expect(subscribe).not.toHaveBeenCalled();
    });

    it('subscribes to lifecycle events while the run is active', async () => {
        isEmpEnabled.mockResolvedValue(true);
        const element = await render(story({ Status__c: 'Running', CompletedAt__c: null }));
        expect(subscribe).toHaveBeenCalledWith('/event/AgentLifecycleEvent__e', -1, expect.any(Function));
        await flush();
        expect(element.shadowRoot.querySelector('.live').textContent).toContain('Live');
    });

    it('explains a paused run and offers the operator action', async () => {
        const element = await render(story({ Status__c: 'Paused', CompletedAt__c: null, ErrorCode__c: 'BUDGET_EXCEEDED', ModelCallCount__c: 5 }));
        const attention = element.shadowRoot.querySelector('.attention');
        expect(attention.textContent).toContain('The run used its whole budget');
        expect(attention.querySelector('lightning-button').label).toBe('Rescue or cancel');
        const full = element.shadowRoot.querySelector('.kpi-value_full').closest('.kpi');
        expect(full.querySelector('.kpi-label').textContent).toContain('Model calls');
        expect(full.querySelector('.kpi-value').textContent).toContain('5');
        expect(full.querySelector('.kpi-note').textContent).toBe('of 5 allowed');
    });

    it('shows a limit a succeeded run reached as a warning, not an error', async () => {
        const element = await render(story({ ModelCallCount__c: 5 }));
        expect(element.shadowRoot.querySelector('.kpi-value_full')).toBeNull();
        expect(element.shadowRoot.querySelector('.kpi-value_high')).not.toBeNull();
        expect(element.shadowRoot.querySelector('.meter-warn')).toBeNull();
    });

    it("shows tokens once, with the agent's token limit on the same tile", async () => {
        const element = await render(
            story({ TotalTokenCount__c: 1200, AgentDefinition__r: { Name: 'Case support', MaxModelCalls__c: 5, MaxToolCalls__c: 4, MaxTotalTokens__c: 5000 } })
        );
        const labels = [...element.shadowRoot.querySelectorAll('.kpi-label')].map((node) => node.textContent.trim());
        expect(labels).toEqual(['Elapsed', 'Working time', 'Model calls', 'Tool calls', 'Tokens', 'Estimated cost']);
        const tokens = element.shadowRoot.querySelectorAll('.kpi')[4];
        expect(tokens.querySelector('.kpi-value').textContent).toContain('1,200');
        expect(tokens.querySelector('.kpi-note').textContent).toBe('of 5,000 allowed');
        expect(tokens.querySelector('.meter')).not.toBeNull();
    });

    it('links the agent and the execution identity to their record pages', async () => {
        const element = await render(
            story({ ExecutionIdentity__c: 'a08000000000001AAA', ExecutionIdentity__r: { PrincipalUser__r: { Name: 'Integration User' } } })
        );
        const links = [...element.shadowRoot.querySelectorAll('.head-meta c-pluto-link')];
        const byLabel = Object.fromEntries(links.map((link) => [link.label, link.pageReference]));
        expect(byLabel['Open agent']).toEqual({
            type: 'standard__recordPage',
            attributes: { recordId: 'a03000000000001AAA', objectApiName: 'AgentDefinition__c', actionName: 'view' }
        });
        expect(byLabel['Runs as Integration User'].attributes).toMatchObject({ recordId: 'a08000000000001AAA', objectApiName: 'AgentExecutionIdentity__c' });
    });

    it('says only that the run uses an execution user when the viewer cannot read who it is', async () => {
        const element = await render(story({ ExecutionIdentity__c: 'a08000000000001AAA' }));
        const labels = [...element.shadowRoot.querySelectorAll('.head-meta c-pluto-link')].map((link) => link.label);
        expect(labels).toContain('Runs as execution user');
    });

    it('shows where the time went before the timeline', async () => {
        const element = await render(story());
        const sections = [...element.shadowRoot.querySelectorAll('section')].map((section) => section.className);
        expect(sections.indexOf('time')).toBeLessThan(sections.indexOf('timeline'));
    });

    it("calls the model's reason for a tool call by a plain name", async () => {
        const data = story();
        data.commands[1].Rationale__c = 'The case number is in the input.';
        const element = await render(data);
        const rationale = element.shadowRoot.querySelector('.step-rationale');
        expect(rationale.querySelector('figcaption').textContent).toContain("The agent's reasoning");
        expect(rationale.textContent).not.toContain('not verified');
        expect(rationale.querySelector('blockquote').textContent).toBe('The case number is in the input.');
        expect(rationale.querySelector('lightning-helptext').content).toContain('Agent Core does not check it');
    });

    it('loads a step payload only when the step is opened', async () => {
        getStepDetail.mockResolvedValue({ input: '{"caseNumber":"00001028"}', output: '{"priority":"High"}', payloadHidden: false, attempts: [] });
        const element = await render(story());
        expect(getStepDetail).not.toHaveBeenCalled();
        const toggle = element.shadowRoot.querySelectorAll('.card-head')[1];
        toggle.click();
        await flush();
        expect(getStepDetail).toHaveBeenCalledWith({ commandId: 'a01000000000002AAA' });
        expect(toggle.getAttribute('aria-expanded')).toBe('true');
        const payloads = element.shadowRoot.querySelectorAll('.panel c-pluto-run-story-payload');
        expect(payloads.length).toBe(2);
        expect(payloads[1].value).toBe('{"priority":"High"}');
    });

    it('shows the model prompt and reply when a model step is opened', async () => {
        getStepDetail.mockResolvedValue({
            input: '{}',
            output: null,
            payloadHidden: false,
            evidenceHidden: false,
            attempts: [{ Id: 'i1', AttemptNumber__c: 1, InvocationType__c: 'Model' }],
            evidence: [
                {
                    AttemptNumber__c: 1,
                    Request__c: '{"instructions":"Triage.","characterBudget":100,"characterCount":10,"contexts":[],"transcript":[],"tools":[]}',
                    Response__c: '{"isSuccess":true,"toolCalls":[{"toolName":"get_case","toolInput":"{}"}]}'
                }
            ],
            userNames: {}
        });
        const element = await render(story());
        element.shadowRoot.querySelectorAll('.card-head')[0].click();
        await flush();
        const calls = element.shadowRoot.querySelectorAll('c-pluto-run-story-call');
        expect(calls.length).toBe(1);
        expect(calls[0].call.reply.summary).toBe('Asked for 1 tool call');
        expect(calls[0].expanded).toBe(true);
        expect(element.shadowRoot.querySelector('.panel-grid')).toBeNull();
    });

    it('explains that model evidence needs the sensitive data permission', async () => {
        getStepDetail.mockResolvedValue({ input: '{}', output: null, payloadHidden: false, evidenceHidden: true, attempts: [], evidence: [], userNames: {} });
        const element = await render(story());
        element.shadowRoot.querySelectorAll('.card-head')[0].click();
        await flush();
        expect(element.shadowRoot.querySelector('.evidence-note').textContent).toContain('Agent Kernel Sensitive Data');
    });

    it("shows the approver's comment apart from the reason Core asked", async () => {
        const data = story();
        data.approvals = [
            {
                Id: 'a00000000000001AAA',
                Name: 'APR-00000001',
                AgentCommand__c: 'a01000000000002AAA',
                Status__c: 'Rejected',
                ApproverType__c: 'Queue',
                Owner: { Name: 'Agent Approvers' },
                DecidedBy__r: { Name: 'Pat Lee' },
                Reason__c: 'A person must approve a Case priority change.',
                DecisionComment__c: 'Not urgent; keep it Medium.',
                CreatedDate: at(3),
                ClosedAt__c: at(4)
            }
        ];
        const element = await render(data);
        const approval = element.shadowRoot.querySelector('.approval');
        expect(approval.querySelector('.approval-summary').textContent).toBe('Rejected by Pat Lee after 1.0 s');
        expect(approval.querySelector('.approval-comment').textContent).toBe('Not urgent; keep it Medium.');
        expect(approval.querySelector('.approval-reason').textContent).toBe('Why: A person must approve a Case priority change.');
        expect(approval.querySelector('.approval-who').textContent).toContain('Sent to the Agent Approvers queue');
        const link = approval.querySelector('.approval-link');
        expect(link.label).toBe('Open APR-00000001');
        expect(link.pageReference).toMatchObject({ type: 'standard__recordPage', attributes: { objectApiName: 'AgentApproval__c' } });
    });

    it('flags a rejected tool in red beside the status and opens it on click', async () => {
        getStepDetail.mockResolvedValue({ input: '{}', output: null, payloadHidden: false, attempts: [], evidence: [], userNames: {} });
        const data = story();
        data.commands[1] = { ...data.commands[1], Status__c: 'Failed', ErrorCode__c: 'TOOL_APPROVAL_DENIED' };
        data.approvals = [{ Id: 'apr1', AgentCommand__c: 'a01000000000002AAA', Status__c: 'Rejected', CreatedDate: at(3), ClosedAt__c: at(4) }];
        const element = await render(data);
        const root = element.shadowRoot;
        const flag = root.querySelector('.highlight');
        expect(flag.className).toContain('highlight_error');
        expect(flag.textContent.trim()).toBe('1 approval rejected');
        const badge = root.querySelector('[data-key="a01000000000002AAA"] .badge');
        expect(badge.className).toContain('badge_error');
        expect(badge.textContent.trim()).toBe('Rejected');
        expect(root.querySelector('.attention')).toBeNull();
        flag.click();
        await flush();
        expect(root.querySelectorAll('.card-head')[1].getAttribute('aria-expanded')).toBe('true');
        expect(getStepDetail).toHaveBeenCalledWith({ commandId: 'a01000000000002AAA' });
    });

    it('filters the timeline to tool steps', async () => {
        const element = await render(story());
        const toolFilter = [...element.shadowRoot.querySelectorAll('.filter')].find((node) => node.dataset.value === 'tool');
        toolFilter.click();
        await flush();
        expect(toolFilter.getAttribute('aria-pressed')).toBe('true');
        const titles = [...element.shadowRoot.querySelectorAll('.card-title')].map((node) => node.textContent);
        expect(titles).toEqual(['Get case']);
    });

    it('opens the failing step on load and offers the next steps for a failed run', async () => {
        getStepDetail.mockResolvedValue({ input: '{}', output: null, payloadHidden: false, attempts: [], evidence: [], userNames: {} });
        const data = story({ Status__c: 'Failed', ErrorCode__c: 'TOOL_CONFIGURATION_ERROR' });
        data.commands[1] = { ...data.commands[1], Status__c: 'Failed', ErrorCode__c: 'TOOL_CONFIGURATION_ERROR' };
        const element = await render(data);
        await flush();
        const root = element.shadowRoot;
        expect(getStepDetail).toHaveBeenCalledTimes(1);
        expect(getStepDetail).toHaveBeenCalledWith({ commandId: 'a01000000000002AAA' });
        expect(root.querySelectorAll('.card-head')[1].getAttribute('aria-expanded')).toBe('true');
        const attention = root.querySelector('.attention');
        expect(attention.querySelector('.focus-link').label).toBe('Show the step');
        expect(attention.querySelector('.copy-diagnostics').label).toBe('Copy details');
        const agentLink = [...attention.querySelectorAll('c-pluto-link')].find((link) => link.label === 'Open agent');
        expect(agentLink.pageReference.attributes).toMatchObject({ objectApiName: 'AgentDefinition__c', actionName: 'view' });
    });

    it('copies identifiers, not payloads, for support', async () => {
        const writeText = jest.fn().mockResolvedValue();
        Object.defineProperty(navigator, 'clipboard', { value: { writeText }, configurable: true });
        const element = await render(story({ Status__c: 'Paused', CompletedAt__c: null, ErrorCode__c: 'BUDGET_EXCEEDED' }));
        element.shadowRoot.querySelector('.copy-diagnostics').click();
        await flush();
        const text = writeText.mock.calls[0][0];
        expect(text).toContain('Agent run: RUN-00000001 (a07000000000001AAA)');
        expect(text).toContain('Error: BUDGET_EXCEEDED');
        expect(text).not.toContain('00001028');
        expect(element.shadowRoot.querySelector('.copy-diagnostics').label).toBe('Copied');
    });

    it('opens at most ten steps at once', async () => {
        getStepDetail.mockResolvedValue({ input: '{}', output: '{}', payloadHidden: false, attempts: [] });
        const element = await render(longStory(14));
        element.shadowRoot.querySelector('.expand-all').click();
        await flush();
        expect(getStepDetail).toHaveBeenCalledTimes(10);
        expect(element.shadowRoot.querySelector('.expand-note').textContent).toBe('Opened the first 10 of 14 steps. Open the others one at a time.');
    });

    it('folds routine steps in a long run until the reader asks for them', async () => {
        const element = await render(longStory(14));
        const root = element.shadowRoot;
        expect(root.querySelectorAll('.card').length).toBe(0);
        const reveal = root.querySelector('.group-reveal');
        expect(reveal.label).toBe('Show 14 steps');
        reveal.click();
        await flush();
        expect(root.querySelectorAll('.card').length).toBe(14);
        expect(root.querySelector('.group-reveal')).toBeNull();
    });

    it('jumps from the time legend to the longest step of that kind', async () => {
        getStepDetail.mockResolvedValue({ input: '{}', output: '{}', payloadHidden: false, attempts: [] });
        const element = await render(story());
        const root = element.shadowRoot;
        expect(root.querySelector('.track').getAttribute('aria-hidden')).toBe('true');
        const model = [...root.querySelectorAll('.legend-item_link')].find((node) => node.textContent.includes('Model'));
        expect(model.getAttribute('aria-label')).toContain('Show the longest one');
        model.click();
        await flush();
        expect(getStepDetail).toHaveBeenCalledWith({ commandId: 'a01000000000001AAA' });
    });

    it('announces a status change to screen readers', async () => {
        isEmpEnabled.mockResolvedValue(false);
        const element = await render(story({ Status__c: 'Running', CompletedAt__c: null }));
        const live = element.shadowRoot.querySelector('[aria-live="polite"]');
        expect(live.textContent).toBe('');
        getStory.mockResolvedValue(story({ Status__c: 'Failed', ErrorCode__c: 'RETRY_EXHAUSTED' }));
        element.shadowRoot.querySelector('lightning-button-icon').click();
        await flush();
        expect(live.textContent).toBe('The run is now Failed. Retries ran out.');
    });

    it('shows times from the start of the run when asked', async () => {
        const element = await render(story());
        element.shadowRoot.querySelector('.time-mode').click();
        await flush();
        const times = [...element.shadowRoot.querySelectorAll('.card-head .when')].map((node) => node.textContent);
        expect(times).toEqual(['+0:01', '+0:03', '+0:05']);
    });

    it('shows one attempt of a retried step at a time', async () => {
        const request = '{"instructions":"Triage.","characterBudget":100,"characterCount":10,"contexts":[],"transcript":[],"tools":[]}';
        getStepDetail.mockResolvedValue({
            input: '{}',
            output: null,
            payloadHidden: false,
            evidenceHidden: false,
            attempts: [
                { Id: 'i1', AttemptNumber__c: 1, InvocationType__c: 'Model', Outcome__c: 'Failed', ErrorCode__c: 'PROVIDER_TIMEOUT' },
                { Id: 'i2', AttemptNumber__c: 2, InvocationType__c: 'Model', Outcome__c: 'Succeeded' }
            ],
            evidence: [
                { AttemptNumber__c: 1, Request__c: request, Response__c: '{"isSuccess":false}' },
                { AttemptNumber__c: 2, Request__c: request, Response__c: '{"isSuccess":true,"toolCalls":[{"toolName":"get_case","toolInput":"{}"}]}' }
            ],
            userNames: {}
        });
        const element = await render(story());
        const root = element.shadowRoot;
        root.querySelectorAll('.card-head')[0].click();
        await flush();
        let calls = root.querySelectorAll('c-pluto-run-story-call');
        expect(calls.length).toBe(1);
        expect(calls[0].call.heading).toBe('Attempt 2 of 2');
        root.querySelector('.attempt-view[aria-pressed="false"]').click();
        await flush();
        calls = root.querySelectorAll('c-pluto-run-story-call');
        expect(calls[0].call.heading).toBe('Attempt 1 of 2');
    });

    it('keeps an open step on screen while a refresh reloads it', async () => {
        isEmpEnabled.mockResolvedValue(false);
        getStepDetail.mockResolvedValueOnce({ input: '{"caseNumber":"00001028"}', output: null, payloadHidden: false, attempts: [] });
        const data = story({ Status__c: 'Running', CompletedAt__c: null, CurrentCommand__c: 'a01000000000002AAA' });
        data.commands[1].Status__c = 'Leased';
        const element = await render(data);
        const root = element.shadowRoot;
        root.querySelectorAll('.card-head')[1].click();
        await flush();
        expect(root.querySelectorAll('.panel c-pluto-run-story-payload').length).toBe(2);

        let finish;
        getStepDetail.mockReturnValueOnce(
            new Promise((resolve) => {
                finish = resolve;
            })
        );
        root.querySelector('lightning-button-icon').click();
        await flush();
        expect(getStepDetail).toHaveBeenCalledTimes(2);
        expect(root.querySelector('.panel-loading')).toBeNull();
        expect(root.querySelectorAll('.panel c-pluto-run-story-payload')[0].value).toBe('{"caseNumber":"00001028"}');

        finish({ input: '{"caseNumber":"00001029"}', output: '{"priority":"High"}', payloadHidden: false, attempts: [] });
        await flush();
        expect(root.querySelectorAll('.panel c-pluto-run-story-payload')[0].value).toBe('{"caseNumber":"00001029"}');
    });

    it("lets screen readers hear a step's status, not just its title", async () => {
        const data = story({ Status__c: 'Failed', ErrorCode__c: 'TOOL_CONFIGURATION_ERROR' });
        data.commands[1] = { ...data.commands[1], Status__c: 'Failed', ErrorCode__c: 'TOOL_CONFIGURATION_ERROR' };
        getStepDetail.mockResolvedValue({ input: '{}', output: null, payloadHidden: false, attempts: [], evidence: [], userNames: {} });
        const element = await render(data);
        const toggle = element.shadowRoot.querySelectorAll('.card-head')[1];
        expect(toggle.hasAttribute('aria-label')).toBe(false);
        expect(toggle.textContent).toContain('Failed');
    });

    it('lays out an answer not written yet like the input beside it', async () => {
        const element = await render(story({ Status__c: 'Running', CompletedAt__c: null, Output__c: null }));
        const payloads = [...element.shadowRoot.querySelectorAll('.outcome c-pluto-run-story-payload')];
        expect(payloads.map((payload) => payload.label)).toEqual(['Input', 'Final answer']);
        expect(payloads[1].emptyText).toBe('Not written yet.');
    });

    it('shows a plain-text answer once, as the headline', async () => {
        const element = await render(story({ Output__c: 'The case is a billing question.' }));
        const root = element.shadowRoot;
        expect(root.querySelector('.headline').textContent).toContain('The case is a billing question.');
        const labels = [...root.querySelectorAll('.outcome c-pluto-run-story-payload')].map((payload) => payload.label);
        expect(labels).toEqual(['Input']);
    });

    it('still offers Expand all when only the step opened on load is open', async () => {
        getStepDetail.mockResolvedValue({ input: '{}', output: null, payloadHidden: false, attempts: [], evidence: [], userNames: {} });
        const data = story({ Status__c: 'Failed', ErrorCode__c: 'TOOL_CONFIGURATION_ERROR' });
        data.commands[1] = { ...data.commands[1], Status__c: 'Failed', ErrorCode__c: 'TOOL_CONFIGURATION_ERROR' };
        const element = await render(data);
        const button = element.shadowRoot.querySelector('.expand-all');
        expect(button.label).toBe('Expand all');
        button.click();
        await flush();
        expect(button.label).toBe('Collapse all');
    });

    it('expands and collapses every step from one link, again and again', async () => {
        getStepDetail.mockResolvedValue({ input: '{}', output: '{}', payloadHidden: false, attempts: [] });
        const element = await render(story());
        const root = element.shadowRoot;
        const button = root.querySelector('.expand-all');
        const states = () => [...root.querySelectorAll('.card-head')].map((head) => head.getAttribute('aria-expanded'));
        for (const [label, open] of [
            ['Collapse all', 'true'],
            ['Expand all', 'false'],
            ['Collapse all', 'true']
        ]) {
            button.click();
            // eslint-disable-next-line no-await-in-loop
            await flush();
            expect(button.label).toBe(label);
            expect(states()).toEqual([open, open, open]);
        }
    });

    it('shows a closed step as its title and one line of measures', async () => {
        const element = await render(story());
        const head = element.shadowRoot.querySelectorAll('.card-head')[0];
        const meta = [...head.querySelectorAll('.card-meta > span')].map((node) => node.textContent);
        expect(meta).toEqual(['Model', 'gpt-4o-mini', '1.5 s', '600 tokens']);
        expect(element.shadowRoot.querySelector('.chips')).toBeNull();
        const tool = element.shadowRoot.querySelectorAll('.card-head')[1];
        expect(tool.querySelector('.card-subtitle')).toBeNull();
    });

    it('folds routine steps again after the reader opened them', async () => {
        const element = await render(longStory(14));
        const root = element.shadowRoot;
        expect(root.querySelector('.refold')).toBeNull();
        root.querySelector('.group-reveal').click();
        await flush();
        root.querySelector('.refold').click();
        await flush();
        expect(root.querySelectorAll('.card').length).toBe(0);
        expect(root.querySelector('.group-reveal')).not.toBeNull();
    });

    it('offers no fold when the legend points at a step that was never folded', async () => {
        getStepDetail.mockResolvedValue({ input: '{}', output: '{}', payloadHidden: false, attempts: [] });
        const element = await render(story());
        const root = element.shadowRoot;
        root.querySelector('.legend-item_link').click();
        await flush();
        expect(root.querySelector('.refold')).toBeNull();
    });

    it('keeps the steps the reader opened when folding again', async () => {
        getStepDetail.mockResolvedValue({ input: '{}', output: '{}', payloadHidden: false, attempts: [] });
        const element = await render(longStory(14));
        const root = element.shadowRoot;
        root.querySelector('.group-reveal').click();
        await flush();
        root.querySelectorAll('.card-head')[0].click();
        await flush();
        root.querySelector('.refold').click();
        await flush();
        expect(root.querySelectorAll('.card').length).toBe(1);
        expect(root.querySelector('.group-reveal').label).toBe('Show 13 steps');
        expect(root.querySelector('.refold')).toBeNull();
    });

    it('moves focus to the first step a group held when it opens', async () => {
        const element = await render(longStory(14));
        const root = element.shadowRoot;
        root.querySelector('.group-reveal').click();
        await flush();
        await new Promise((resolve) => requestAnimationFrame(resolve));
        expect(root.activeElement).toBe(root.querySelectorAll('.card-head')[0]);
    });

    it('boxes the tools one model reply asked for together, headed by the reply', async () => {
        const data = story();
        data.commands.splice(2, 0, {
            Id: 'a01000000000004AAA',
            Sequence__c: 2.5,
            CommandType__c: 'Tool',
            ToolName__c: 'search_policy',
            Status__c: 'Succeeded',
            OperationKey__c: 'k:2.5:Tool:search_policy',
            CreatedDate: at(3)
        });
        const element = await render(data);
        const rows = [...element.shadowRoot.querySelectorAll('.row_step')];
        const roles = rows.map((row) => ['lead', 'member', 'end'].find((role) => row.classList.contains(`row_batch-${role}`)) || null);
        expect(roles).toEqual(['lead', 'member', 'end', null]);
        expect(rows[0].classList.contains('row_batch-start')).toBe(true);
        expect(rows[0].querySelector('.card-title').textContent).toBe('Decided to call 2 tools');
    });

    it('leaves a model reply that asked for one tool out of a box', async () => {
        const element = await render(story());
        expect(element.shadowRoot.querySelector('.row_batch')).toBeNull();
    });

    it('shows a readable error when the run cannot be loaded', async () => {
        getStory.mockRejectedValue({ body: { message: 'This run does not exist or is not shared with you.' } });
        const element = createElement('c-pluto-run-story', { is: PlutoRunStory });
        element.recordId = 'a07000000000001AAA';
        document.body.appendChild(element);
        await flush();
        expect(element.shadowRoot.querySelector('.load-error').textContent).toContain('not shared with you');
    });

    it('is accessible', async () => {
        const element = await render(story({ Status__c: 'Paused', CompletedAt__c: null, ErrorCode__c: 'TOOL_BINDING_CHANGED' }));
        await expect(element).toBeAccessible();
    });
});
