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
import ToolAuthoringEditor from 'c/toolAuthoringEditor';
import loadTool from '@salesforce/apex/ToolAuthoringController.loadTool';
import describeDraft from '@salesforce/apex/ToolAuthoringController.describeDraft';
import getStartingFields from '@salesforce/apex/ToolAuthoringController.getStartingFields';
import LightningConfirm from 'lightning/confirm';
import ToolInputSchemaJsonModal from 'c/toolInputSchemaJsonModal';
import ToolJsonPreviewModal from 'c/toolJsonPreviewModal';
import getToolTypes from '@salesforce/apex/ToolAuthoringController.getToolTypes';

jest.mock(
    '@salesforce/apex/ToolAuthoringController.getToolTypes',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
jest.mock('@salesforce/apex/ToolAuthoringController.loadTool', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.describeDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getStartingFields', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.searchStandardTargetSObjects', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getFieldOptions', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getRecordTypeOptions', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.searchFlows', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.searchReports', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getQueueOptions', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getNamedCredentialOptions', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getChildRelationshipOptions', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('lightning/confirm', () => ({ __esModule: true, default: { open: jest.fn(() => Promise.resolve(true)) } }));
jest.mock('c/toolInputSchemaJsonModal', () => ({ __esModule: true, default: { open: jest.fn() } }));
jest.mock('c/toolJsonPreviewModal', () => ({ __esModule: true, default: { open: jest.fn() } }));

const CREATE_SETTINGS = [
    { name: 'objectApiName', label: 'Object', type: 'object', required: true },
    { name: 'fields', label: 'Fields the Agent May Set', type: 'fields', required: true, objectSetting: 'objectApiName' },
    { name: 'defaultFieldValues', label: 'Fixed Field Values', type: 'fieldValues', required: false, objectSetting: 'objectApiName' }
];

function createView(overrides = {}) {
    return {
        toolType: 'CreateRecord',
        buildsInputs: true,
        settings: CREATE_SETTINGS,
        inputs: [{ path: 'recordData.Subject', name: 'Subject', depth: 1, typeLabel: 'Text (255)', editable: true }],
        schemaJson: '{"type":"object"}',
        problems: [],
        ...overrides
    };
}

function create(props = {}) {
    const element = createElement('c-tool-authoring-editor', { is: ToolAuthoringEditor });
    Object.assign(element, { editing: true }, props);
    document.body.appendChild(element);
    return element;
}

function form(element) {
    return element.shadowRoot.querySelector('c-tool-settings-form');
}

function toolProblems(element) {
    return [...element.shadowRoot.querySelectorAll('[data-tool-problems] li')].map((item) => item.textContent);
}

function inputsList(element) {
    return element.shadowRoot.querySelector('c-tool-inputs-list');
}

async function flush() {
    for (let i = 0; i < 10; i++) {
        // eslint-disable-next-line no-await-in-loop
        await Promise.resolve();
    }
}

describe('c-tool-authoring-editor', () => {
    beforeEach(() => {
        loadTool.mockResolvedValue({
            toolType: 'CreateRecord',
            implementationConfiguration: '{"objectApiName":"Case","fields":["Subject"],"inputOverrides":{"recordData.Subject":{"required":true}}}',
            inputSchema: null,
            view: createView()
        });
        describeDraft.mockResolvedValue(createView());
        getStartingFields.mockResolvedValue(['Subject']);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        jest.useRealTimers();
    });

    it('loads the saved tool and shows what Core built for it', async () => {
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();

        expect(form(element).settings).toEqual(CREATE_SETTINGS);
        expect(form(element).values).toEqual({ objectApiName: 'Case', fields: ['Subject'] });
        expect(inputsList(element).overrides).toEqual({ 'recordData.Subject': { required: true } });
        expect(inputsList(element).inputs).toHaveLength(1);
    });

    it('shows the settings and inputs read-only in view mode', async () => {
        const element = create({ recordId: 'a00000000000000AAA', editing: false });
        await flush();

        expect(element.shadowRoot.querySelector('[data-tool-type]')).toBeNull();
        expect(form(element).readOnly).toBe(true);
        expect(inputsList(element).readOnly).toBe(true);
    });

    it('asks Core about the draft once the admin stops changing settings', async () => {
        jest.useFakeTimers();
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();

        form(element).dispatchEvent(new CustomEvent('settingchange', { detail: { name: 'fields', value: ['Subject', 'Priority'] } }));
        form(element).dispatchEvent(new CustomEvent('settingchange', { detail: { name: 'fields', value: ['Subject', 'Priority', 'Origin'] } }));
        await flush();
        expect(describeDraft).not.toHaveBeenCalled();

        jest.advanceTimersByTime(400);
        await flush();
        expect(describeDraft).toHaveBeenCalledTimes(1);
        const sent = JSON.parse(describeDraft.mock.calls[0][0].implementationConfiguration);
        expect(sent.fields).toEqual(['Subject', 'Priority', 'Origin']);
        expect(sent.inputOverrides).toEqual({ 'recordData.Subject': { required: true } });
        expect(describeDraft.mock.calls[0][0].inputSchema).toBeNull();
    });

    it('keeps the object and its edits when the admin cancels the prompt', async () => {
        LightningConfirm.open.mockResolvedValue(false);
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();
        const revert = jest.fn();

        form(element).dispatchEvent(new CustomEvent('settingchange', { detail: { name: 'objectApiName', value: 'Lead', revert } }));
        await flush();

        expect(LightningConfirm.open).toHaveBeenCalled();
        expect(revert).toHaveBeenCalled();
        expect(form(element).values.objectApiName).toBe('Case');
        expect(inputsList(element).overrides).toEqual({ 'recordData.Subject': { required: true } });
    });

    it('starts a new object with the fields its records need, and clears edits for the old one', async () => {
        LightningConfirm.open.mockResolvedValue(true);
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();

        form(element).dispatchEvent(new CustomEvent('settingchange', { detail: { name: 'objectApiName', value: 'Lead' } }));
        await flush();

        expect(getStartingFields).toHaveBeenCalledWith({ objectApiName: 'Lead', toolType: 'CreateRecord' });
        expect(form(element).values).toEqual({ objectApiName: 'Lead', fields: ['Subject'] });
        expect(inputsList(element).overrides).toEqual({});
    });

    it('stores input edits in the settings', async () => {
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();

        inputsList(element).dispatchEvent(
            new CustomEvent('overrideschange', { detail: { value: { 'recordData.Subject': { description: 'One line naming the product.' } } } })
        );
        await flush();

        const draft = element.prepareDraft();
        expect(JSON.parse(draft.implementationConfiguration).inputOverrides).toEqual({ 'recordData.Subject': { description: 'One line naming the product.' } });
        expect(draft.inputSchema).toBeNull();
    });

    it('places each problem where it belongs', async () => {
        loadTool.mockResolvedValue({
            toolType: 'CreateRecord',
            implementationConfiguration: '{"objectApiName":"Case","fields":["Subject"]}',
            view: createView({
                problems: [
                    { target: 'recordData.Status', message: 'The edit for recordData.Status names an input this tool does not have.' },
                    { target: 'settings', message: 'Field Region__c does not exist on Case.' }
                ]
            })
        });
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();

        expect(inputsList(element).problemsByPath).toEqual({ 'recordData.Status': ['The edit for recordData.Status names an input this tool does not have.'] });
        expect(toolProblems(element)).toEqual(['Field Region__c does not exist on Case.']);
    });

    it('waits for the required settings before showing what Core says is wrong', async () => {
        loadTool.mockResolvedValue({
            toolType: 'CreateRecord',
            implementationConfiguration: null,
            view: createView({
                inputs: [],
                problems: [{ target: 'settings', message: 'Tool type CreateRecord acts on one Salesforce object: set objectApiName.' }]
            })
        });
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();
        expect(toolProblems(element)).toEqual([]);

        expect(element.prepareDraft()).toBeNull();
        await flush();
        expect(toolProblems(element)).toEqual(['Tool type CreateRecord acts on one Salesforce object: set objectApiName.']);
    });

    it('hides problems with the old draft while Core checks a change', async () => {
        jest.useFakeTimers();
        loadTool.mockResolvedValue({
            toolType: 'CreateRecord',
            implementationConfiguration: '{"fields":["Subject"]}',
            view: createView({ problems: [{ target: 'settings', message: 'Tool type CreateRecord acts on one Salesforce object: set objectApiName.' }] })
        });
        getStartingFields.mockResolvedValue(['Subject']);
        let answer;
        describeDraft.mockImplementation(
            () =>
                new Promise((resolve) => {
                    answer = resolve;
                })
        );
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();

        form(element).dispatchEvent(new CustomEvent('settingchange', { detail: { name: 'objectApiName', value: 'Case' } }));
        await flush();
        expect(toolProblems(element)).toEqual([]);

        jest.runAllTimers();
        await flush();
        expect(toolProblems(element)).toEqual([]);

        answer(createView({ problems: [{ target: 'settings', message: 'Field Region__c does not exist on Case.' }] }));
        await flush();
        expect(toolProblems(element)).toEqual(['Field Region__c does not exist on Case.']);
        jest.useRealTimers();
    });

    it('refuses to hand over a draft with an empty required setting', async () => {
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();
        form(element).dispatchEvent(new CustomEvent('settingchange', { detail: { name: 'fields', value: undefined } }));
        await flush();

        expect(element.prepareDraft()).toBeNull();
        await flush();
        expect(form(element).showRequired).toBe(true);
    });

    it('checks a pasted schema with Core and keeps it only without problems', async () => {
        loadTool.mockResolvedValue({
            toolType: 'BillingRefund',
            implementationConfiguration: '{"namedCredential":"Billing_API"}',
            inputSchema: '{"type":"object","properties":{},"additionalProperties":false}',
            view: { toolType: 'BillingRefund', buildsInputs: false, settings: [], inputs: [], problems: [] }
        });
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();

        element.shadowRoot.querySelector('[data-edit-inputs]').click();
        const { applySchema } = ToolInputSchemaJsonModal.open.mock.calls[0][0];

        describeDraft.mockResolvedValueOnce({
            buildsInputs: false,
            problems: [{ target: 'inputSchema', message: 'Tool input schema uses unsupported keyword pattern.' }]
        });
        expect(await applySchema('{"type":"object","properties":{"a":{"type":"string","pattern":"x"}}}')).toEqual([
            'Tool input schema uses unsupported keyword pattern.'
        ]);
        expect(element.prepareDraft().inputSchema).toBe('{"type":"object","properties":{},"additionalProperties":false}');

        const good = '{"type":"object","properties":{"orderNumber":{"type":"string","description":"The order number."}},"additionalProperties":false}';
        describeDraft.mockResolvedValueOnce({ buildsInputs: false, inputs: [{ path: 'orderNumber', name: 'orderNumber' }], problems: [] });
        expect(await applySchema(good)).toEqual([]);
        expect(element.prepareDraft().inputSchema).toBe(good);
    });

    it('asks for the Implementation Type first, then offers only its tool types', async () => {
        describeDraft.mockResolvedValue({ toolType: 'RunFlow', buildsInputs: true, declaresSettings: true, settings: [], inputs: [], problems: [] });
        const element = create();
        getToolTypes.emit([
            { value: 'CreateRecord', label: 'Create Record', implementationType: 'Standard', buildsInputs: true },
            { value: 'RunFlow', label: 'Run Flow', implementationType: 'Flow', buildsInputs: true },
            { value: 'CallApi', label: 'Call API', implementationType: 'Apex', buildsInputs: false }
        ]);
        await flush();

        const toolType = element.shadowRoot.querySelector('[data-tool-type]');
        expect(toolType.disabled).toBe(true);
        expect(element.shadowRoot.querySelector('[data-implementation-type]').options.map((option) => option.value)).toEqual(['Standard', 'Flow', 'Apex']);

        element.shadowRoot.querySelector('[data-implementation-type]').dispatchEvent(new CustomEvent('change', { detail: { value: 'Flow' } }));
        await flush();
        expect(element.shadowRoot.querySelector('[data-tool-type]').options).toEqual([{ label: 'Run Flow', value: 'RunFlow' }]);
        expect(element.shadowRoot.querySelector('[data-tool-type]').value).toBe('RunFlow');
    });

    it('lets the admin build the inputs of a tool type that does not build them', async () => {
        loadTool.mockResolvedValue({
            toolType: 'CallApi',
            implementationConfiguration: '{"namedCredential":"Billing_API"}',
            inputSchema: null,
            view: { toolType: 'CallApi', buildsInputs: false, declaresSettings: true, settings: [], inputs: [], problems: [] }
        });
        describeDraft.mockResolvedValue({ toolType: 'CallApi', buildsInputs: false, declaresSettings: true, settings: [], inputs: [], problems: [] });
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();

        const builder = element.shadowRoot.querySelector('c-tool-inputs-builder');
        expect(builder).not.toBeNull();
        expect(element.prepareDraft().inputSchema).toBe('{"type":"object","properties":{},"additionalProperties":false}');

        const schema =
            '{"type":"object","properties":{"orderId":{"type":"string","description":"The order."}},"required":["orderId"],"additionalProperties":false}';
        builder.dispatchEvent(new CustomEvent('schemachange', { detail: { value: schema } }));
        expect(element.prepareDraft().inputSchema).toBe(schema);
    });

    it('shows the exact schema in a modal from the inputs header', async () => {
        const element = create({ recordId: 'a00000000000000AAA', editing: false });
        await flush();

        element.shadowRoot.querySelector('[data-show-json]').click();
        expect(ToolJsonPreviewModal.open).toHaveBeenCalledWith(expect.objectContaining({ inputSchema: '{"type":"object"}' }));
    });

    it('shows a problem Core reports twice once, and keeps it with a spinner while Core checks a change', async () => {
        jest.useFakeTimers();
        const message = 'The query does not run: unexpected token: WHER';
        loadTool.mockResolvedValue({
            toolType: 'CreateRecord',
            implementationConfiguration: '{"objectApiName":"Case","fields":["Subject"]}',
            view: createView({
                inputs: [],
                problems: [
                    { target: 'settings', message },
                    { target: 'inputSchema', message }
                ]
            })
        });
        let answer;
        describeDraft.mockImplementation(
            () =>
                new Promise((resolve) => {
                    answer = resolve;
                })
        );
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();
        expect(toolProblems(element)).toEqual([message]);
        expect(inputsList(element)).toBeNull();

        form(element).dispatchEvent(new CustomEvent('settingchange', { detail: { name: 'fields', value: ['Subject', 'Origin'] } }));
        await flush();
        expect(element.shadowRoot.querySelector('[data-checking]')).not.toBeNull();
        expect(toolProblems(element)).toEqual([message]);

        jest.runAllTimers();
        answer(createView());
        await flush();
        expect(element.shadowRoot.querySelector('[data-checking]')).toBeNull();
        expect(toolProblems(element)).toEqual([]);
        expect(inputsList(element).inputs).toHaveLength(1);
    });

    it('waits until the admin stops typing a query before asking Core', async () => {
        jest.useFakeTimers();
        loadTool.mockResolvedValue({
            toolType: 'QueryRecords',
            implementationConfiguration: '{"query":"SELECT Id FROM Case"}',
            view: createView({ toolType: 'QueryRecords', settings: [{ name: 'query', label: 'Query', type: 'query', required: true }] })
        });
        const element = create({ recordId: 'a00000000000000AAA' });
        await flush();

        form(element).dispatchEvent(new CustomEvent('settingchange', { detail: { name: 'query', value: 'SELECT Id FROM Case W' } }));
        jest.advanceTimersByTime(400);
        await flush();
        expect(describeDraft).not.toHaveBeenCalled();

        jest.advanceTimersByTime(400);
        await flush();
        expect(describeDraft).toHaveBeenCalledTimes(1);
    });
});
