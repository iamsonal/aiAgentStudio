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
import PlutoToolDetail from 'c/plutoToolDetail';
import saveTool from '@salesforce/apex/ToolAuthoringController.saveTool';
import getApproverQueueOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getApproverQueueOptions';
jest.mock('@salesforce/apex/ToolAuthoringController.saveTool', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getToolTypes', () => ({ default: jest.fn() }), { virtual: true });
jest.mock(
    '@salesforce/apex/ToolAuthoringController.loadTool',
    () => ({ default: jest.fn(() => Promise.resolve({ view: { inputs: [], settings: [], problems: [] } })) }),
    { virtual: true }
);
jest.mock('@salesforce/apex/ToolAuthoringController.describeDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getStartingFields', () => ({ default: jest.fn() }), { virtual: true });
jest.mock(
    '@salesforce/apex/PlutoImplementationDiscoveryService.getApproverQueueOptions',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
describe('c-pluto-tool-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('passes the record page header choice to the form', async () => {
        const element = createElement('c-pluto-tool-detail', { is: PlutoToolDetail });
        element.recordId = 'a00000000000000AAA';
        element.hideHeader = true;
        document.body.appendChild(element);
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('c-pluto-record-layout').hideHeader).toBe(true);
    });

    it('prompts for a selection when no record is set', () => {
        const element = createElement('c-pluto-tool-detail', { is: PlutoToolDetail });
        document.body.appendChild(element);

        return Promise.resolve().then(() => {
            expect(element.shadowRoot.querySelector('p').textContent).toContain('Select a tool');
            expect(element.shadowRoot.querySelector('c-pluto-record-layout')).toBeNull();
        });
    });

    it('submits the header, tool type, settings, and schema in one save request', async () => {
        saveTool.mockResolvedValue('a00000000000000AAA');
        const element = createElement('c-pluto-tool-detail', { is: PlutoToolDetail });
        element.isNew = true;
        document.body.appendChild(element);
        await Promise.resolve();

        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        const editor = element.shadowRoot.querySelector('c-tool-authoring-editor');
        const draft = { toolType: 'QueryRecords', implementationConfiguration: '{"query":"SELECT Id FROM Case LIMIT 1"}', inputSchema: null };
        editor.prepareDraft = jest.fn(() => draft);
        editor.reload = jest.fn();
        form.completeSave = jest.fn();
        form.dispatchEvent(new CustomEvent('saverequest', { detail: { recordInput: { fields: { Name: 'Lookup' } } } }));
        await Promise.resolve();
        await Promise.resolve();

        expect(saveTool).toHaveBeenCalledWith({
            header: { Name: 'Lookup' },
            toolType: 'QueryRecords',
            implementationConfiguration: '{"query":"SELECT Id FROM Case LIMIT 1"}',
            inputSchema: null
        });
        expect(editor.reload).toHaveBeenCalled();
        expect(form.completeSave).toHaveBeenCalledWith('a00000000000000AAA');
    });

    it('leaves editor-owned fields to the tool editor, places the HITL route, and applies approver-specific fields', async () => {
        const element = createElement('c-pluto-tool-detail', { is: PlutoToolDetail });
        element.isNew = true;
        document.body.appendChild(element);
        await Promise.resolve();

        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        expect(form.hiddenFields).toEqual(['ToolType__c', 'ImplementationType__c', 'ImplementationConfiguration__c', 'InputSchema__c']);
        expect(form.additionalFields).toEqual([{ fieldApiName: 'ApprovalRoute__c', before: 'ApprovalTimeoutMinutes__c' }]);
        expect(form.fieldDependencies).toEqual([
            { controllingField: 'ApprovalMode__c', controllingValue: 'Always Required', showFields: ['ApproverType__c'], requiredFields: ['ApproverType__c'] },
            {
                controllingField: 'ApprovalMode__c',
                controllingValue: ['Always Required', 'Decided by Policy'],
                showFields: ['ApprovalTimeoutMinutes__c', 'ApprovalExpiryAction__c'],
                requiredFields: ['ApprovalExpiryAction__c']
            },
            { controllingField: 'ApproverType__c', controllingValue: 'User', showFields: ['ApproverUser__c'], requiredFields: ['ApproverUser__c'] },
            { controllingField: 'ApproverType__c', controllingValue: ['Queue', 'Anchor Record Owner'], showFields: ['ApproverQueue__c'] },
            { controllingField: 'ApproverType__c', controllingValue: 'Queue', requiredFields: ['ApproverQueue__c'] },
            {
                controllingField: 'ApproverType__c',
                controllingValue: ['User', 'Queue', 'Anchor Record Owner', "Requester's Manager"],
                showFields: ['ApprovalRoute__c']
            },
            { controllingField: 'ApprovalMode__c', controllingValue: 'Decided by Policy', showFields: ['ApprovalRoute__c'] }
        ]);

        form.setFieldValue('ApproverUser__c', '005000000000000AAA');
        form.dispatchEvent(new CustomEvent('fieldchange', { detail: { fieldName: 'ApproverType__c', value: 'Queue' } }));
        expect(form.getFieldValue('ApproverUser__c')).toBeNull();
    });

    it('leaves the tool type and implementation type to the editor in every mode', async () => {
        const element = createElement('c-pluto-tool-detail', { is: PlutoToolDetail });
        element.recordId = 'a00000000000000AAA';
        element.mode = 'view';
        document.body.appendChild(element);
        await Promise.resolve();
        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        expect(form.hiddenFields).toEqual(['ToolType__c', 'ImplementationType__c', 'ImplementationConfiguration__c', 'InputSchema__c']);

        element.mode = 'edit';
        await Promise.resolve();
        expect(form.hiddenFields).toEqual(['ToolType__c', 'ImplementationType__c', 'ImplementationConfiguration__c', 'InputSchema__c']);
    });

    it('offers approval queues by label and stores their API names', async () => {
        const element = createElement('c-pluto-tool-detail', { is: PlutoToolDetail });
        element.isNew = true;
        document.body.appendChild(element);
        getApproverQueueOptions.emit([{ label: 'Review Team (Review_Team)', value: 'Review_Team' }]);
        await Promise.resolve();
        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        expect(form.fieldOptions.ApproverQueue__c).toEqual([{ label: 'Review Team (Review_Team)', value: 'Review_Team' }]);
    });

    it('keeps a picklist when no eligible queues exist or discovery fails', async () => {
        const element = createElement('c-pluto-tool-detail', { is: PlutoToolDetail });
        element.isNew = true;
        document.body.appendChild(element);
        getApproverQueueOptions.emit([]);
        await Promise.resolve();
        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        expect(form.fieldOptions.ApproverQueue__c).toEqual([{ label: 'No queues support Agent Approval', value: '' }]);
        getApproverQueueOptions.error({ message: 'Unavailable' });
        await Promise.resolve();
        expect(form.fieldOptions.ApproverQueue__c).toEqual([{ label: 'Queues unavailable', value: '' }]);
    });
    it('clears the settings each Approval choice does not use', async () => {
        const element = createElement('c-pluto-tool-detail', { is: PlutoToolDetail });
        element.isNew = true;
        document.body.appendChild(element);
        await Promise.resolve();
        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        const approverFields = ['ApproverType__c', 'ApproverUser__c', 'ApproverQueue__c'];
        const waitFields = ['ApprovalTimeoutMinutes__c', 'ApprovalExpiryAction__c', 'ApprovalRoute__c'];
        [...approverFields, ...waitFields].forEach((field) => form.setFieldValue(field, 'kept'));

        form.dispatchEvent(new CustomEvent('fieldchange', { detail: { fieldName: 'ApprovalMode__c', value: 'Decided by Policy' } }));
        approverFields.forEach((field) => expect(form.getFieldValue(field)).toBeNull());
        waitFields.forEach((field) => expect(form.getFieldValue(field)).toBe('kept'));

        form.dispatchEvent(new CustomEvent('fieldchange', { detail: { fieldName: 'ApprovalMode__c', value: 'Not Required' } }));
        waitFields.forEach((field) => expect(form.getFieldValue(field)).toBeNull());
        expect(form.requiredFields).toContain('DeveloperName__c');
        expect(element.shadowRoot.querySelector('c-tool-authoring-editor').parentElement.getAttribute('slot')).toBe('form-sections-after');
    });

    it('clears a notification route when the approval is delivered through a channel', async () => {
        const element = createElement('c-pluto-tool-detail', { is: PlutoToolDetail });
        element.isNew = true;
        document.body.appendChild(element);
        await Promise.resolve();
        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        form.setFieldValue('ApprovalRoute__c', 'old-route');
        form.dispatchEvent(new CustomEvent('fieldchange', { detail: { fieldName: 'ApproverType__c', value: 'Delivery Channel' } }));
        expect(form.getFieldValue('ApprovalRoute__c')).toBeNull();
    });
});
