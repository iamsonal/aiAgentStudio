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
import AgentCoreHealth from 'c/agentCoreHealth';
import { getNavigateCalledWith } from 'lightning/navigation';
import getHealth from '@salesforce/apex/AgentRunOperatorController.getHealth';
import runRecoveryNow from '@salesforce/apex/AgentRunOperatorController.runRecoveryNow';
import retryApprovalRelays from '@salesforce/apex/PlutoHitlController.retryApprovalRelays';

jest.mock('@salesforce/apex/AgentRunOperatorController.getHealth', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/AgentRunOperatorController.installSchedules', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/AgentRunOperatorController.runRecoveryNow', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/PlutoHitlController.retryApprovalRelays', () => ({ default: jest.fn() }), { virtual: true });

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function mount(report) {
    getHealth.mockResolvedValue({ lookbackHours: 24, actions: [], ...report });
    const element = createElement('c-agent-core-health', { is: AgentCoreHealth });
    document.body.appendChild(element);
    await flush();
    return element;
}

describe('c-agent-core-health', () => {
    beforeAll(() => registerSa11yMatcher());

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('says all is well when nothing needs attention', async () => {
        const element = await mount({ status: 'Healthy' });
        const root = element.shadowRoot;
        expect(root.querySelector('.verdict-title').textContent).toBe('Healthy');
        expect(root.querySelector('.all-clear').textContent).toContain('Nothing needs attention.');
        expect(root.querySelector('.tile-button')).toBeNull();
    });

    it('opens the list behind a count', async () => {
        const element = await mount({
            status: 'Warning',
            pausedRuns: 2,
            actions: [
                {
                    code: 'RESCUE_OR_CANCEL_PAUSED_RUNS',
                    reason: 'Paused runs wait for an operator.',
                    fixTarget: 'Agent Run: Operate',
                    counts: { rescuablePausedRuns: 2 }
                }
            ]
        });
        const tile = element.shadowRoot.querySelector('.tile-button');
        expect(tile.textContent).toContain('2');
        tile.click();
        expect(getNavigateCalledWith().pageReference).toEqual({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'AgentRun__c', actionName: 'list' },
            state: { filterName: 'Paused_Runs' }
        });
    });

    it('offers the fix beside the finding it solves', async () => {
        runRecoveryNow.mockResolvedValue();
        const element = await mount({
            status: 'Critical',
            actions: [
                {
                    code: 'INSTALL_OR_REPAIR_SCHEDULES',
                    reason: 'Work is waiting for the next recovery pass.',
                    fixTarget: 'Agent Core Health',
                    counts: { staleLeasedCommands: 3 }
                }
            ]
        });
        const root = element.shadowRoot;
        expect(root.querySelector('.verdict-title').textContent).toBe('Action required');
        expect(root.querySelector('.finding').className).toContain('finding_error');
        expect(root.querySelector('.finding-details').textContent).toContain('3 steps overdue for recovery');
        expect(root.querySelector('.finding-button').label).toBe('Run Recovery');
        root.querySelector('.finding-button').click();
        await flush();
        expect(runRecoveryNow).toHaveBeenCalled();
    });

    it('links open issues to their list and explains each count', async () => {
        const element = await mount({
            status: 'Warning',
            openIssuesByCode: { FLOW_START_LOST: 2 },
            actions: [
                {
                    code: 'REVIEW_OPEN_ISSUES',
                    reason: 'Failures need a person.',
                    fixTarget: 'Agent Operational Issues tab, Open list view',
                    counts: { FLOW_START_LOST: 2 }
                }
            ]
        });
        const root = element.shadowRoot;
        expect(root.querySelector('.finding-title').textContent).toBe('Failures need a person');
        expect(root.querySelector('.finding-details').textContent).toContain('2 FLOW_START_LOST');
        const issuesTile = [...root.querySelectorAll('.tile-button')].find((candidate) => candidate.textContent.includes('Open issues'));
        issuesTile.click();
        expect(getNavigateCalledWith().pageReference.attributes.objectApiName).toBe('AgentOperationalIssue__c');
    });

    it('retries failed approval relays from the issues action', async () => {
        retryApprovalRelays.mockResolvedValue(2);
        const element = await mount({
            status: 'Warning',
            openIssuesByCode: { AGENT_HITL_RELAY_FAILED: 2 },
            actions: [{ code: 'REVIEW_OPEN_ISSUES', reason: 'Failures need a person.', fixTarget: 'Issues', counts: { AGENT_HITL_RELAY_FAILED: 2 } }]
        });
        element.shadowRoot.querySelector('.finding-secondary').click();
        await flush();
        expect(retryApprovalRelays).toHaveBeenCalled();
    });

    it('is accessible', async () => {
        const element = await mount({
            status: 'Warning',
            pausedRuns: 1,
            actions: [
                {
                    code: 'RESCUE_OR_CANCEL_PAUSED_RUNS',
                    reason: 'Paused runs wait for an operator.',
                    fixTarget: 'Agent Run: Operate',
                    counts: { rescuablePausedRuns: 2 }
                }
            ]
        });
        await expect(element).toBeAccessible();
    });
});
