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
import PlutoRecordModal from 'c/plutoRecordModal';
import { getRecord } from 'lightning/uiRecordApi';
import { registerLdsTestWireAdapter } from '@salesforce/sfdx-lwc-jest';

const recordAdapter = registerLdsTestWireAdapter(getRecord);

const TOOL_ID = 'a05000000000001AAA';

function render(props) {
    const element = createElement('c-pluto-record-modal', { is: PlutoRecordModal });
    Object.assign(element, props);
    document.body.appendChild(element);
    return element;
}

const header = (element) => element.shadowRoot.querySelector('lightning-modal-header');

describe('c-pluto-record-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('opens New with the host defaults and no page header', async () => {
        const element = render({ objectApiName: 'AgentTool__c', objectLabel: 'Agent Tool', isNew: true, defaultValues: { AgentDefinition__c: 'a03' } });
        await Promise.resolve();

        const detail = element.shadowRoot.querySelector('c-pluto-tool-detail');
        expect(header(element).label).toBe('New Agent Tool');
        expect(detail.isNew).toBe(true);
        expect(detail.mode).toBe('edit');
        expect(detail.hideHeader).toBe(true);
        expect(detail.defaultValues).toEqual({ AgentDefinition__c: 'a03' });
    });

    it('titles Edit with the record name once it loads', async () => {
        const element = render({ objectApiName: 'AgentExecutionIdentity__c', objectLabel: 'Agent Execution Identity', recordId: TOOL_ID });
        await Promise.resolve();
        expect(header(element).label).toBe('Edit Agent Execution Identity');

        recordAdapter.emit({ apiName: 'AgentExecutionIdentity__c', fields: { Name: { value: 'Service User' } } });
        await Promise.resolve();
        expect(header(element).label).toBe('Edit Service User');
        expect(element.shadowRoot.querySelector('c-pluto-execution-identity-detail').recordId).toBe(TOOL_ID);
    });

    it('closes with the saved record', async () => {
        const element = render({ objectApiName: 'AgentTool__c', objectLabel: 'Agent Tool', isNew: true });
        await Promise.resolve();

        element.shadowRoot.querySelector('c-pluto-tool-detail').dispatchEvent(new CustomEvent('recordsaved', { detail: { recordId: TOOL_ID } }));
        expect(element.closeValue).toEqual({ action: 'save', recordId: TOOL_ID });
    });

    it('closes as cancelled when New or Edit is cancelled', async () => {
        const element = render({ objectApiName: 'AgentDefinition__c', objectLabel: 'Agent Definition', recordId: TOOL_ID });
        await Promise.resolve();

        element.shadowRoot.querySelector('c-pluto-agent-detail').dispatchEvent(new CustomEvent('modechange', { detail: { mode: 'view' } }));
        expect(element.closeValue).toEqual({ action: 'cancel' });
    });
});
