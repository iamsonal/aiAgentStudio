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
import ToolSettingsForm from 'c/toolSettingsForm';
import getFieldOptions from '@salesforce/apex/ToolAuthoringController.getFieldOptions';
import getRecordTypeOptions from '@salesforce/apex/ToolAuthoringController.getRecordTypeOptions';
import searchFlows from '@salesforce/apex/ToolAuthoringController.searchFlows';

jest.mock('@salesforce/apex/ToolAuthoringController.searchStandardTargetSObjects', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getFieldOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getRecordTypeOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.searchFlows', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.searchReports', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock(
    '@salesforce/apex/ToolAuthoringController.getQueueOptions',
    () => ({ default: jest.fn(() => Promise.resolve([{ value: 'Support', label: 'Support • Support' }])) }),
    { virtual: true }
);
jest.mock('@salesforce/apex/ToolAuthoringController.getNamedCredentialOptions', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getChildRelationshipOptions', () => ({ default: jest.fn(() => Promise.resolve([])) }), { virtual: true });

const CREATE_RECORD = [
    { name: 'objectApiName', label: 'Object', type: 'object', required: true },
    { name: 'fields', label: 'Fields the Agent May Set', type: 'fields', required: true, objectSetting: 'objectApiName' },
    { name: 'defaultFieldValues', label: 'Fixed Field Values', type: 'fieldValues', required: false, objectSetting: 'objectApiName' },
    { name: 'recordTypeDeveloperName', label: 'Record Type', type: 'recordType', required: false, objectSetting: 'objectApiName' }
];

function create(props) {
    const element = createElement('c-tool-settings-form', { is: ToolSettingsForm });
    Object.assign(element, { toolType: 'CreateRecord', settings: CREATE_RECORD, values: {} }, props);
    document.body.appendChild(element);
    return element;
}

function control(element, name) {
    return element.shadowRoot.querySelector(`[data-setting="${name}"]`);
}

async function flush() {
    await new Promise((resolve) => setTimeout(resolve, 0));
    await Promise.resolve();
}

describe('c-tool-settings-form', () => {
    beforeEach(() => {
        getFieldOptions.mockResolvedValue([
            { value: 'Subject', label: 'Subject', createable: true, updateable: true },
            { value: 'CaseNumber', label: 'Case Number', createable: false, updateable: false }
        ]);
        getRecordTypeOptions.mockResolvedValue([{ value: 'Support', label: 'Support' }]);
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows one control for each Create Record setting', async () => {
        const element = create({ values: { objectApiName: 'Case' } });
        await flush();

        expect(control(element, 'objectApiName').querySelector('c-smart-lookup')).not.toBeNull();
        const fields = control(element, 'fields').querySelector('lightning-dual-listbox');
        expect(fields.options).toEqual([{ label: 'Subject (Subject)', value: 'Subject' }]);
        expect(control(element, 'defaultFieldValues').querySelector('c-tool-field-values-editor')).not.toBeNull();
        expect(
            control(element, 'recordTypeDeveloperName')
                .querySelector('lightning-combobox')
                .options.map((option) => option.value)
        ).toEqual(['', 'Support']);
    });

    it('shows the field settings and Record Type only once an object is chosen', async () => {
        const element = create();
        await flush();

        expect(control(element, 'fields')).toBeNull();
        expect(control(element, 'defaultFieldValues')).toBeNull();
        expect(control(element, 'recordTypeDeveloperName')).toBeNull();
        expect(getFieldOptions).not.toHaveBeenCalled();

        element.values = { objectApiName: 'Case' };
        await flush();
        expect(control(element, 'fields')).not.toBeNull();
        expect(control(element, 'recordTypeDeveloperName')).not.toBeNull();
    });

    it('keeps a field either fixed or set by the agent', async () => {
        getFieldOptions.mockResolvedValue([
            { value: 'Subject', label: 'Subject', createable: true },
            { value: 'Origin', label: 'Case Origin', createable: true },
            { value: 'Priority', label: 'Priority', createable: true },
            { value: 'CaseNumber', label: 'Case Number', createable: false }
        ]);
        const element = create({ values: { objectApiName: 'Case', fields: ['Subject'], defaultFieldValues: { Origin: 'Web' } } });
        await flush();

        const agentChoices = control(element, 'fields')
            .querySelector('lightning-dual-listbox')
            .options.map((option) => option.value);
        expect(agentChoices).toEqual(['Subject', 'Priority']);
        const fixedChoices = control(element, 'defaultFieldValues')
            .querySelector('c-tool-field-values-editor')
            .fields.map((field) => field.value);
        expect(fixedChoices).toEqual(['Origin', 'Priority']);
    });

    it('sends each change by setting name', async () => {
        const element = create({ values: { objectApiName: 'Case' } });
        const changed = jest.fn();
        element.addEventListener('settingchange', changed);
        await flush();

        control(element, 'fields')
            .querySelector('lightning-dual-listbox')
            .dispatchEvent(new CustomEvent('change', { detail: { value: ['Subject'] } }));

        expect(changed.mock.calls[0][0].detail).toEqual(expect.objectContaining({ name: 'fields', value: ['Subject'] }));
    });

    it('names an empty required setting after a failed save', async () => {
        const element = create({ showRequired: true });
        await flush();

        expect(control(element, 'objectApiName').querySelector('[data-missing]').textContent).toBe('Object is required.');
        expect(control(element, 'defaultFieldValues')).toBeNull();
    });

    it('takes undeclared settings as one JSON object', async () => {
        const element = create({ settings: [], undeclared: true, toolType: 'BillingRefund' });
        const replaced = jest.fn();
        element.addEventListener('settingschange', replaced);
        await flush();

        const box = element.shadowRoot.querySelector('[data-undeclared]');
        box.dispatchEvent(new CustomEvent('change', { detail: { value: '["not","an","object"]' } }));
        await flush();
        expect(replaced).not.toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('[data-json-error]').textContent).toContain('must be a JSON object');

        box.dispatchEvent(new CustomEvent('change', { detail: { value: '{"namedCredential":"Billing_API"}' } }));
        expect(replaced.mock.calls[0][0].detail.value).toEqual({ namedCredential: 'Billing_API' });
    });

    it('loads Flows when the settings arrive after it starts, and keeps a saved Flow the list lacks', async () => {
        searchFlows.mockResolvedValue([{ value: 'Other_Flow', label: 'Other • Other_Flow' }]);
        const element = create({ settings: [], values: {} });
        await flush();
        element.settings = [{ name: 'flowApiName', label: 'Flow', type: 'flow', required: true }];
        element.values = { flowApiName: 'Saved_Flow' };
        await flush();

        const combobox = control(element, 'flowApiName').querySelector('lightning-combobox');
        expect(combobox.options.map((option) => option.value)).toEqual(['Other_Flow', 'Saved_Flow']);
        expect(combobox.value).toBe('Saved_Flow');
    });

    it('offers the blank choice of an optional record setting, then a picker for the chosen object', async () => {
        const settings = [
            {
                name: 'targetId',
                label: 'Post To',
                type: 'record',
                required: false,
                blankMeaning: "The run's record",
                recordObjects: [
                    { value: 'User', label: 'User', meta: '005' },
                    { value: 'CollaborationGroup', label: 'Group', meta: '0F9' }
                ]
            }
        ];
        const element = create({ toolType: 'PostChatter', settings, values: { targetId: '0F9000000000001AAA' } });
        const changed = jest.fn();
        element.addEventListener('settingchange', changed);
        await flush();

        const kinds = control(element, 'targetId').querySelector('[data-record-kind]');
        expect(kinds.options.map((option) => option.value)).toEqual(['', 'User', 'CollaborationGroup', '__other']);
        expect(kinds.value).toBe('CollaborationGroup');
        expect(control(element, 'targetId').querySelector('lightning-record-picker').objectApiName).toBe('CollaborationGroup');

        kinds.dispatchEvent(new CustomEvent('change', { detail: { value: '' } }));
        expect(changed.mock.calls[0][0].detail).toEqual(expect.objectContaining({ name: 'targetId', value: undefined }));
    });

    it('edits name and value rows as one object, with a choice of values', async () => {
        const settings = [{ name: 'inputs', label: 'Where Each Input Goes', type: 'keyValues', required: false, allowedValues: ['path', 'query', 'body'] }];
        const element = create({ toolType: 'CallApi', settings, values: { inputs: { orderId: 'path' } } });
        const changed = jest.fn();
        element.addEventListener('settingchange', changed);
        await flush();

        control(element, 'inputs').querySelector('[data-add-row]').click();
        await flush();
        const rows = control(element, 'inputs').querySelectorAll('[data-key-value-row]');
        expect(rows.length).toBe(2);
        rows[1].querySelector('lightning-input[data-part="name"]').dispatchEvent(new CustomEvent('change', { detail: { value: 'amount' } }));
        await flush();
        control(element, 'inputs')
            .querySelectorAll('[data-key-value-row]')[1]
            .querySelector('lightning-combobox[data-part="value"]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'body' } }));

        expect(changed.mock.calls[changed.mock.calls.length - 1][0].detail.value).toEqual({ orderId: 'path', amount: 'body' });
    });

    it('turns a list setting into one value per line, and lists queues', async () => {
        const settings = [
            { name: 'responseFields', label: 'Response Fields', type: 'textList', required: false },
            { name: 'queue', label: 'Hand-Off Queue', type: 'queue', required: false, blankMeaning: "Keep the record's owner" }
        ];
        const element = create({ toolType: 'CallApi', settings, values: {} });
        const changed = jest.fn();
        element.addEventListener('settingchange', changed);
        await flush();

        control(element, 'responseFields')
            .querySelector('lightning-textarea')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'status\n order.eta \n' } }));
        expect(changed.mock.calls[0][0].detail.value).toEqual(['status', 'order.eta']);
        expect(control(element, 'queue').querySelector('lightning-combobox').options).toEqual([
            { label: "Keep the record's owner", value: '' },
            { label: 'Support • Support', value: 'Support' }
        ]);
    });

    it('leaves out Record Type when the chosen object has none', async () => {
        getRecordTypeOptions.mockResolvedValue([]);
        const element = create({ values: { objectApiName: 'Case' } });
        await flush();
        expect(control(element, 'recordTypeDeveloperName')).toBeNull();
        expect(control(element, 'fields')).not.toBeNull();
    });

    it('keeps Fixed Field Values an object when a field box inside sends its own change', async () => {
        const element = create({ values: { objectApiName: 'Case' } });
        const changed = jest.fn();
        element.addEventListener('settingchange', changed);
        await flush();

        const editor = control(element, 'defaultFieldValues').querySelector('c-tool-field-values-editor');
        editor.dispatchEvent(new CustomEvent('change', { detail: { value: 'Subject' }, bubbles: true, composed: true }));
        expect(changed).not.toHaveBeenCalled();

        editor.dispatchEvent(new CustomEvent('valueschange', { detail: { value: { Origin: 'Web' } } }));
        expect(changed.mock.calls[0][0].detail).toEqual(expect.objectContaining({ name: 'defaultFieldValues', value: { Origin: 'Web' } }));
    });

    it('sends the query as typed, so a space after a suggestion stays', async () => {
        const element = create({ toolType: 'QueryRecords', settings: [{ name: 'query', label: 'Query', type: 'query', required: true }] });
        const changed = jest.fn();
        element.addEventListener('settingchange', changed);
        await flush();

        const editor = control(element, 'query').querySelector('c-tool-query-editor');
        expect(editor.label).toBe('Query');
        expect(editor.required).toBe(true);
        editor.dispatchEvent(new CustomEvent('querychange', { detail: { value: 'SELECT Id FROM Case WHERE AccountId ' } }));
        editor.dispatchEvent(new CustomEvent('querychange', { detail: { value: '   ' } }));

        expect(changed.mock.calls[0][0].detail.value).toBe('SELECT Id FROM Case WHERE AccountId ');
        expect(changed.mock.calls[1][0].detail.value).toBeUndefined();
    });
});
