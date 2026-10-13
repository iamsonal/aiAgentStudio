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
import PlutoRunStoryCall from 'c/plutoRunStoryCall';
import { describeCall } from 'c/plutoRunStoryModel';

function modelCall(requestOverrides = {}) {
    return describeCall(
        { Id: 'inv1', InvocationType__c: 'Model', AttemptNumber__c: 1 },
        {
            AttemptNumber__c: 1,
            Request__c: JSON.stringify({
                instructions: 'Triage the case.',
                characterBudget: 100,
                characterCount: 10,
                contexts: [{ sourceName: 'Case triage', content: '{}', untrusted: true }],
                transcript: [{ type: 'OriginalInput', content: '{}' }],
                tools: [{ developerName: 'get_case', description: 'Reads a case' }],
                ...requestOverrides
            }),
            Response__c: '{"isSuccess":true,"toolCalls":[]}'
        }
    );
}

async function render(call, toolIds) {
    const element = createElement('c-pluto-run-story-call', { is: PlutoRunStoryCall });
    element.call = call;
    element.toolIds = toolIds;
    element.expanded = true;
    document.body.appendChild(element);
    await Promise.resolve();
    return element;
}

describe('c-pluto-run-story-call', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('puts the prompt sections in tabs with their counts, without the output schema', async () => {
        const element = await render(modelCall({ outputSchema: '{"type":"object"}' }));
        const labels = [...element.shadowRoot.querySelectorAll('lightning-tab')].map((tab) => tab.label);
        expect(labels).toEqual(['Instructions', 'Context (1)', 'Conversation (1)', 'Tools offered (1)']);
    });

    it('names each offered tool and links it to its record page', async () => {
        const element = await render(modelCall(), { get_case: 'a05000000000001AAA' });
        const tool = element.shadowRoot.querySelector('.tool');
        expect(tool.querySelector('.tool-name').textContent).toBe('get_case');
        expect(tool.textContent).not.toContain('Reads a case');
        const link = tool.querySelector('c-pluto-link');
        expect(link.label).toBe('Open tool get_case');
        expect(link.pageReference).toEqual({
            type: 'standard__recordPage',
            attributes: { recordId: 'a05000000000001AAA', objectApiName: 'AgentTool__c', actionName: 'view' }
        });
    });

    it('renders the instructions as Markdown', async () => {
        const element = await render(modelCall({ instructions: '# Triage\n\n- Read the case.' }));
        expect(element.shadowRoot.querySelector('c-markdown-viewer').value).toBe('# Triage\n\n- Read the case.');
    });

    it('switches between the readable view and the raw evidence', async () => {
        const element = await render(modelCall());
        const root = element.shadowRoot;
        const toggle = root.querySelector('.raw-toggle');
        expect(toggle.label).toBe('Raw evidence');
        expect(root.querySelector('.raw')).toBeNull();
        expect(root.querySelector('lightning-tabset')).not.toBeNull();

        toggle.click();
        await Promise.resolve();
        expect(toggle.label).toBe('Readable view');
        expect([...root.querySelectorAll('.raw c-pluto-run-story-payload')].map((payload) => payload.label)).toEqual(['Request', 'Response']);
        expect(root.querySelector('lightning-tabset')).toBeNull();
    });

    it('shows a tool it cannot find without a link', async () => {
        const element = await render(modelCall(), {});
        expect(element.shadowRoot.querySelector('.tool c-pluto-link')).toBeNull();
    });

    it('leaves out tabs with nothing in them', async () => {
        const element = await render(modelCall({ contexts: [], transcript: [], tools: [] }));
        const labels = [...element.shadowRoot.querySelectorAll('lightning-tab')].map((tab) => tab.label);
        expect(labels).toEqual(['Instructions']);
    });

    it('labels CPU, SOQL, and DML as what the attempt used', async () => {
        const call = describeCall(
            {
                Id: 'inv2',
                InvocationType__c: 'Tool',
                AttemptNumber__c: 1,
                DurationMs__c: 30,
                CpuTimeMs__c: 83,
                SoqlQueries__c: 11,
                DmlStatements__c: 8,
                TransactionId__c: 'txn-1'
            },
            { AttemptNumber__c: 1, Request__c: '{"toolName":"get_case","toolInput":"{}"}', Response__c: '{"isSuccess":true}' }
        );
        const element = await render(call);
        const root = element.shadowRoot;
        expect([...root.querySelectorAll('.resource')].map((node) => node.textContent)).toEqual(['30 ms']);
        const usage = root.querySelector('.usage');
        expect(usage.textContent).toContain('Used: 83 ms CPU · 11 SOQL · 8 DML');
        expect(usage.textContent).toContain('same Transaction ID');
    });
});
