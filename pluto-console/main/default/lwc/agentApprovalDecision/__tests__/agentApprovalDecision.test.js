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
import AgentApprovalDecision from 'c/agentApprovalDecision';
import reviewRequest from '@salesforce/apex/AgentApprovalActions.reviewRequest';
import reviewInput from '@salesforce/apex/AgentApprovalActions.reviewInput';
import decideFromRecord from '@salesforce/apex/AgentApprovalActions.decideFromRecord';

jest.mock('@salesforce/apex/AgentApprovalActions.reviewRequest', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/AgentApprovalActions.reviewInput', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/AgentApprovalActions.decideFromRecord', () => ({ default: jest.fn() }), { virtual: true });

const APPROVAL_ID = 'a0A000000000001AAA';
const CASE_ID = '500000000000001AAA';
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((candidate) => candidate.label === label);

function pending(overrides = {}) {
    return {
        status: 'Pending',
        title: 'Update case priority',
        agentName: 'Case support',
        anchor: { recordId: CASE_ID, objectLabel: 'Case', name: '00001028' },
        inputs: [{ label: 'Priority', value: 'High' }],
        reason: 'A person must approve a Case priority change.',
        rationale: 'All 40 users have been locked out since 8:00.',
        hasProtectedValues: false,
        expiresAt: '2099-10-03T00:51:00.000Z',
        expiryAction: 'Deny and Continue',
        ...overrides
    };
}

async function mount(request = pending()) {
    reviewRequest.mockResolvedValue(request);
    const element = createElement('c-agent-approval-decision', { is: AgentApprovalDecision });
    document.body.appendChild(element);
    // A quick action sets the record ID after the component connects.
    element.recordId = APPROVAL_ID;
    await flush();
    return element;
}

describe('c-agent-approval-decision', () => {
    beforeAll(() => registerSa11yMatcher());

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('loads the request once the quick action supplies the record ID', async () => {
        await mount();
        expect(reviewRequest).toHaveBeenCalledWith({ approvalId: APPROVAL_ID });
    });

    it('shows the requested values, the record, why, and the deadline, with no link to the run', async () => {
        const element = await mount();
        const root = element.shadowRoot;
        expect(root.querySelector('.request-title').textContent).toBe('Update case priority');
        const anchor = root.querySelector('.anchor-link');
        expect(anchor.getAttribute('href')).toBe(`/${CASE_ID}`);
        expect(anchor.textContent).toBe('Case 00001028');
        expect(root.querySelector('.input-label').textContent).toBe('Priority');
        expect(root.querySelector('.input-value').textContent).toBe('High');
        expect(root.querySelector('.request-context').textContent).toContain('Requested by Case support for Case 00001028');
        expect(root.querySelector('.request-reason').textContent).toBe('A person must approve a Case priority change.');
        expect(root.querySelector('.request-rationale').textContent).toBe('All 40 users have been locked out since 8:00.');
        expect(root.querySelector('.deadline').textContent).toContain('the request is rejected and the agent continues without it');
        expect(root.querySelector('a:not(.anchor-link)')).toBeNull();
    });

    it('leads with why a person must approve and how long is left, and ends with what happens after the deadline', async () => {
        const expiresAt = new Date(Date.now() + 50 * 60000 + 30000).toISOString();
        const element = await mount(pending({ expiresAt }));
        const root = element.shadowRoot;
        expect(root.querySelector('.time-left').textContent).toBe('Decide within 50 min');
        expect(root.querySelector('.rule-label').textContent).toBe('Needs approval because');
        const order = [...root.querySelectorAll('.rule, .values, .explanation, .comment, .deadline')].map((node) => node.className.split(' ')[0]);
        expect(order).toEqual(['rule', 'values', 'explanation', 'comment', 'deadline']);
        expect(root.querySelector('.deadline').textContent).toMatch(/^If nobody decides by .+, the request is rejected and the agent continues without it\.$/);
        expect(root.querySelector('.explanation-caption').textContent).toContain('Check the facts before you approve');
    });

    it('names tool inputs in words while keeping labels already written for people', async () => {
        const element = await mount(
            pending({
                inputs: [
                    { label: 'orderNumber', value: '4' },
                    { label: 'refund_reason', value: 'Damaged' },
                    { label: 'SKU', value: 'A-1' },
                    { label: 'Case priority', value: 'High' }
                ]
            })
        );
        const labels = [...element.shadowRoot.querySelectorAll('.input-label')].map((node) => node.textContent);
        expect(labels).toEqual(['Order number', 'Refund reason', 'SKU', 'Case priority']);
    });

    it('never names or links a record the approver cannot open', async () => {
        const element = await mount(pending({ anchor: { recordId: CASE_ID, objectLabel: 'Case', name: null } }));
        const root = element.shadowRoot;
        expect(root.querySelector('.anchor-link')).toBeNull();
        expect(root.querySelector('.anchor-hidden').textContent).toBe("a Case you can't open");
    });

    it('reveals protected values only on request', async () => {
        reviewInput.mockResolvedValue('{"customerEmail":"pat@example.com"}');
        const element = await mount(pending({ hasProtectedValues: true, inputs: [{ label: 'customerEmail', value: '{{EMAIL_1_9f2c61ab}}' }] }));
        expect(reviewInput).not.toHaveBeenCalled();
        button(element, 'Show hidden values').click();
        await flush();
        expect(element.shadowRoot.querySelector('.json').textContent).toBe('{\n  "customerEmail": "pat@example.com"\n}');
    });

    it('offers no decision once the deadline has passed', async () => {
        const element = await mount(pending({ expiresAt: '2020-01-01T00:00:00.000Z' }));
        expect(element.shadowRoot.querySelector('.deadline').textContent).toContain('can no longer be approved or rejected');
        expect(button(element, 'Approve')).toBeUndefined();
        expect(element.shadowRoot.querySelector('lightning-textarea')).toBeNull();
    });

    it('approves with the comment', async () => {
        decideFromRecord.mockResolvedValue();
        const element = await mount();
        const comment = element.shadowRoot.querySelector('lightning-textarea');
        comment.value = 'Looks right.';
        comment.dispatchEvent(new CustomEvent('change'));
        button(element, 'Approve').click();
        await flush();
        expect(decideFromRecord).toHaveBeenCalledWith({ approvalId: APPROVAL_ID, approved: true, comment: 'Looks right.' });
    });

    it('shows who decided a closed approval and offers no decision', async () => {
        const element = await mount({ status: 'Approved', decidedBy: 'Ada Admin', closedAt: '2026-10-02T12:00:00.000Z', decisionComment: 'Fine.', inputs: [] });
        const root = element.shadowRoot;
        expect(root.querySelector('.decided').textContent).toContain('Approved by Ada Admin on');
        expect(root.querySelector('.decision-comment').textContent).toContain('Fine.');
        expect(button(element, 'Approve')).toBeUndefined();
        expect(button(element, 'Close')).toBeTruthy();
    });

    it('shows a rejection in red with what it meant for the agent', async () => {
        const element = await mount({
            status: 'Rejected',
            title: 'Issue refund',
            reason: 'Refunds over 200 need Finance approval.',
            decidedBy: 'Pat Lee',
            closedAt: '2026-10-02T12:00:00.000Z',
            inputs: []
        });
        const root = element.shadowRoot;
        expect(root.querySelector('.request-title').textContent).toBe('Issue refund');
        expect(root.querySelector('.outcome').className).toContain('outcome_error');
        expect(root.querySelector('.outcome-icon').iconName).toBe('utility:close');
        expect(root.querySelector('.outcome-effect').textContent).toBe('The agent did not do this and continued without it.');
        expect(root.querySelector('.decided-reason').textContent).toBe('Why approval was needed: Refunds over 200 need Finance approval.');
    });

    it('says an expired request had no decision', async () => {
        const element = await mount({ status: 'Expired', inputs: [] });
        expect(element.shadowRoot.querySelector('.decided').textContent).toBe('Expired. Nobody decided before the deadline.');
    });

    it('explains a refusal and offers no decision', async () => {
        reviewRequest.mockRejectedValue({ body: { message: 'This request is assigned to other approvers. Only they can see and decide it.' } });
        const element = createElement('c-agent-approval-decision', { is: AgentApprovalDecision });
        document.body.appendChild(element);
        element.recordId = APPROVAL_ID;
        await flush();
        expect(element.shadowRoot.querySelector('.error').textContent).toContain('assigned to other approvers');
        expect(button(element, 'Approve')).toBeUndefined();
    });

    it('is accessible', async () => {
        const element = await mount();
        await expect(element).toBeAccessible();
    });
});
