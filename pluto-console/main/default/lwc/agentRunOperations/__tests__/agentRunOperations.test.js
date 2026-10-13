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
import AgentRunOperations from 'c/agentRunOperations';
import getRunView from '@salesforce/apex/AgentRunOperatorController.getRunView';
import rescue from '@salesforce/apex/AgentRunOperatorController.rescue';
import cancel from '@salesforce/apex/AgentRunOperatorController.cancel';
import reconcile from '@salesforce/apex/AgentRunOperatorController.reconcile';

jest.mock('@salesforce/apex/AgentRunOperatorController.getRunView', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/AgentRunOperatorController.rescue', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/AgentRunOperatorController.pause', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/AgentRunOperatorController.cancel', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/AgentRunOperatorController.reconcile', () => ({ default: jest.fn() }), { virtual: true });

const RUN_ID = 'a07000000000001AAA';
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((candidate) => candidate.label === label);

async function mount(view) {
    getRunView.mockResolvedValue(view);
    const element = createElement('c-agent-run-operations', { is: AgentRunOperations });
    document.body.appendChild(element);
    element.recordId = RUN_ID;
    await flush();
    return element;
}

const pausedOnBudget = {
    status: 'Paused',
    errorCode: 'BUDGET_EXCEEDED',
    errorMessage: 'Max tool calls reached.',
    canRescue: true,
    canCancel: true
};

describe('c-agent-run-operations', () => {
    beforeAll(() => registerSa11yMatcher());

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('explains why the run paused and what to do', async () => {
        const element = await mount(pausedOnBudget);
        const root = element.shadowRoot;
        expect(root.querySelector('.state-title').textContent).toBe('The run used its whole budget');
        expect(root.querySelector('.state-action').textContent).toContain('Raise Max Model Calls');
        expect(root.querySelector('lightning-icon').variant).toBe('warning');
        const actions = root.querySelector('lightning-radio-group[data-field="action"]');
        expect(actions.options).toEqual([
            { value: 'rescue', label: 'Rescue' },
            { value: 'cancel', label: 'Cancel' }
        ]);
        expect(actions.value).toBe('rescue');
        expect(root.textContent).toContain('The agent gets your guidance');
    });

    it('names the spent limits and holds rescue until Core would accept it', async () => {
        const budget = {
            modelCalls: 3,
            maxModelCalls: 3,
            toolCalls: 3,
            maxToolCalls: 3,
            tokens: 4859,
            maxTokens: 250000,
            perReply: false,
            rescueBlockedBy: 'model'
        };
        const element = await mount({ ...pausedOnBudget, agentId: 'a05000000000001AAA', budget });
        const root = element.shadowRoot;
        expect(root.querySelector('.state').className).toContain('state_warning');
        expect(root.querySelector('.state-title').textContent).toBe('Out of model calls and tool calls');
        expect(root.querySelector('.state-action').textContent).toContain('Raise Max Model Calls and Max Tool Calls on the agent, then rescue the run.');
        const values = [...root.querySelectorAll('.budget-value')];
        expect(values.map((value) => value.textContent)).toEqual(['3 of 3', '3 of 3', '4,859 of 250,000']);
        expect(values.map((value) => value.classList.contains('budget-value_spent'))).toEqual([true, true, false]);
        expect(root.querySelector('.rescue-blocked-text').textContent).toContain('the next step needs a model call, and none are left');
        expect(root.querySelector('.agent-link').getAttribute('href')).toBe('/a05000000000001AAA');
        expect(button(element, 'Rescue Run').disabled).toBe(true);

        getRunView.mockResolvedValue({ ...pausedOnBudget, budget: { ...budget, maxModelCalls: 10, maxToolCalls: 10, rescueBlockedBy: null } });
        button(element, 'Check again').click();
        await flush();
        expect(root.querySelector('.state-title').textContent).toBe('The limits now allow the next step');
        expect(root.querySelector('.rescue-blocked')).toBeNull();
        expect(button(element, 'Rescue Run').disabled).toBe(false);
    });

    it('rescues with the guidance the operator wrote', async () => {
        rescue.mockResolvedValue(RUN_ID);
        const element = await mount(pausedOnBudget);
        const guidance = element.shadowRoot.querySelector('lightning-textarea[data-field="guidance"]');
        guidance.value = 'Limits raised. Continue.';
        guidance.dispatchEvent(new CustomEvent('change'));
        await flush();
        button(element, 'Rescue Run').click();
        await flush();
        expect(rescue).toHaveBeenCalledWith({ runId: RUN_ID, guidance: 'Limits raised. Continue.' });
    });

    it('marks cancelling as destructive', async () => {
        cancel.mockResolvedValue(RUN_ID);
        const element = await mount(pausedOnBudget);
        const actions = element.shadowRoot.querySelector('lightning-radio-group[data-field="action"]');
        actions.dispatchEvent(new CustomEvent('change', { detail: { value: 'cancel' } }));
        await flush();
        const submit = button(element, 'Cancel Run');
        expect(submit.variant).toBe('destructive');
        expect(element.shadowRoot.textContent).toContain('This cannot be undone.');
        submit.click();
        await flush();
        expect(cancel).toHaveBeenCalledWith({ runId: RUN_ID, reason: undefined });
    });

    it('asks for a reconciliation when a tool result is unknown', async () => {
        const element = await mount({ status: 'Waiting', unknownToolName: 'place_order', canReconcile: true });
        const root = element.shadowRoot;
        expect(root.querySelector('.state-title').textContent).toBe('A tool result needs checking');
        expect(root.querySelector('.caution').textContent).toContain('place order');
        expect(button(element, 'Record Outcome').disabled).toBe(true);
    });

    it('says why only the starter can continue a run of an agent without an identity', async () => {
        const reason = 'Only the person who started this run can continue it. Cancel it, or ask them to start again.';
        const element = await mount({ status: 'Paused', canRescue: false, canCancel: true, rescueBlockedReason: reason });
        const root = element.shadowRoot;
        expect(root.querySelector('.continue-blocked').textContent).toBe(reason);
        expect(root.querySelector('lightning-radio-group[data-field="action"]')).toBeNull();
        expect(root.querySelector('.only-action').textContent).toBe('Cancel Run');
    });

    it('says what a waiting run waits for, until when, and what cancelling it closes', async () => {
        const element = await mount({
            status: 'Waiting',
            waitingReason: 'Refunds over 200 need Finance approval.',
            waitExpiresAt: '2026-10-09T19:35:00.000Z',
            canCancel: true
        });
        const root = element.shadowRoot;
        expect(root.querySelector('.state-title').textContent).toBe('Waiting');
        expect(root.querySelector('lightning-badge')).toBeNull();
        expect(root.querySelector('.state-until').textContent).toMatch(/^It waits until .+\.$/);
        expect(root.querySelector('lightning-radio-group[data-field="action"]')).toBeNull();
        expect(root.querySelector('.action-description').textContent).toContain('An approval it waits for closes without a decision');
        expect(root.querySelector('lightning-textarea[data-field="reason"]').label).toBe('Reason (optional)');
    });

    it('keeps the status badge when the title explains it in other words', async () => {
        const element = await mount(pausedOnBudget);
        expect(element.shadowRoot.querySelector('lightning-badge').label).toBe('Paused');
    });

    it('lets an operator who cannot continue the run only settle it as failed and paused', async () => {
        reconcile.mockResolvedValue('Paused');
        const element = await mount({
            status: 'Waiting',
            unknownToolName: 'place_order',
            canReconcile: true,
            canReconcileContinue: false,
            rescueBlockedReason: 'Only the person who started this run can continue it.'
        });
        const root = element.shadowRoot;
        const decisions = [...root.querySelectorAll('lightning-radio-group')].find((group) => group.label === 'What happened');
        expect(decisions.options).toEqual([{ value: 'ConfirmFailed', label: 'It did not happen' }]);
        const evidence = root.querySelector('lightning-textarea[data-field="reason"]');
        evidence.value = 'No order in the ERP.';
        evidence.dispatchEvent(new CustomEvent('change'));
        await flush();
        button(element, 'Record Outcome').click();
        await flush();
        expect(reconcile).toHaveBeenCalledWith(expect.objectContaining({ decision: 'ConfirmFailed', pauseRun: true }));
    });

    it('is accessible', async () => {
        const element = await mount(pausedOnBudget);
        await expect(element).toBeAccessible();
    });
});
