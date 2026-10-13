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
import PlutoRecordLayout from 'c/plutoRecordLayout';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import { getLayout } from 'lightning/uiLayoutApi';
import { getRecord, updateRecord, createRecord } from 'lightning/uiRecordApi';
import { registerLdsTestWireAdapter } from '@salesforce/sfdx-lwc-jest';

jest.mock('lightning/uiRecordApi', () => ({
    getRecord: jest.fn(),
    updateRecord: jest.fn(() => Promise.resolve()),
    createRecord: jest.fn(() => Promise.resolve({ id: 'a01000000000001AAA' }))
}));

const objectInfoAdapter = registerLdsTestWireAdapter(getObjectInfo);
const layoutAdapter = registerLdsTestWireAdapter(getLayout);
const recordAdapter = registerLdsTestWireAdapter(getRecord);

function field(label, dataType, editable = true) {
    return { label, dataType, required: false, createable: editable, updateable: editable };
}

function item(apiName, options = {}) {
    return {
        editableForNew: options.editableForNew ?? true,
        editableForUpdate: options.editableForUpdate ?? true,
        required: options.required ?? false,
        layoutComponents: [{ apiName, componentType: 'Field' }]
    };
}

const OBJECT_INFO = {
    apiName: 'AgentTool__c',
    label: 'Agent Tool',
    nameFields: ['Name'],
    defaultRecordTypeId: '012000000000000AAA',
    fields: {
        Name: field('Tool', 'String'),
        AllowedSensitiveDataCategories__c: field('Sensitive categories', 'MultiPicklist'),
        DeveloperName__c: field('Developer Name', 'String', false),
        Description__c: { ...field('Description', 'LongTextArea'), inlineHelpText: 'Describe what the tool does.' },
        SortOrder__c: field('Sort Order', 'Double'),
        ApproverUser__c: field('Approver User', 'Reference'),
        IsActive__c: field('Active', 'Boolean'),
        ApprovalRoute__c: field('Approval Route', 'Reference'),
        ImplementationType__c: field('Implementation Type', 'String')
    }
};

function layout(extraRows = []) {
    return {
        sections: [
            {
                id: 'identity',
                heading: 'Identity',
                useHeading: true,
                collapsible: true,
                columns: 2,
                layoutRows: [
                    { layoutItems: [item('Name', { required: true }), item('IsActive__c')] },
                    { layoutItems: [item('DeveloperName__c'), item('SortOrder__c')] },
                    {
                        layoutItems: [
                            item('AllowedSensitiveDataCategories__c'),
                            item('ImplementationType__c', { editableForUpdate: false, editableForNew: false })
                        ]
                    },
                    ...extraRows
                ]
            },
            {
                id: 'approval',
                heading: 'Approval',
                useHeading: true,
                collapsible: true,
                columns: 1,
                layoutRows: [{ layoutItems: [item('ApproverUser__c')] }, { layoutItems: [item('Hidden_From_User__c')] }]
            },
            {
                id: 'links',
                heading: 'Custom Links',
                useHeading: true,
                columns: 1,
                layoutRows: [{ layoutItems: [{ layoutComponents: [{ componentType: 'CustomLinks' }] }] }]
            }
        ]
    };
}

async function makeForm(options = {}) {
    const element = createElement('c-pluto-record-layout', { is: PlutoRecordLayout });
    element.objectApiName = 'AgentTool__c';
    element.recordId = options.isNew ? undefined : 'a01000000000000AAA';
    element.mode = options.mode || (options.isNew ? 'new' : 'edit');
    element.deferSave = options.deferSave || false;
    element.fieldDependencies = options.fieldDependencies || [];
    element.customFieldRenderers = options.customFieldRenderers || {};
    element.fieldOptions = options.fieldOptions || {};
    element.requiredFields = options.requiredFields || [];
    element.hiddenFields = options.hiddenFields || [];
    element.additionalFields = options.additionalFields || [];
    element.defaultValues = options.defaultValues || {};
    if (options.variant) element.variant = options.variant;
    if (options.slotSection) element.slotSection = options.slotSection;
    document.body.appendChild(element);
    objectInfoAdapter.emit(OBJECT_INFO);
    layoutAdapter.emit(layout(options.extraFields ? [{ layoutItems: options.extraFields.map((name) => item(name)) }] : []));
    if (!options.isNew) {
        recordAdapter.emit({
            recordTypeId: '012000000000000AAA',
            fields: {
                Name: { value: options.name ?? 'Original' },
                AllowedSensitiveDataCategories__c: { value: 'PII;Financial' },
                DeveloperName__c: { value: 'stable_name' },
                Description__c: { value: options.description ?? 'Looks up a tool.' },
                SortOrder__c: { value: 1 },
                IsActive__c: { value: true },
                ApproverUser__c: { value: null },
                ApprovalRoute__c: { value: 'a05000000000000AAA' },
                ImplementationType__c: { value: 'Apex' }
            }
        });
    }
    await flush();
    return element;
}

function inputFor(element, fieldName) {
    return [...element.shadowRoot.querySelectorAll('.field-input')].find((input) => input.dataset.field === fieldName);
}

function shownFields(element) {
    return [...element.shadowRoot.querySelectorAll('[data-id="layout-item"]')].map((node) => node.dataset.field);
}

function clickSave(element, location = 'header') {
    [...element.shadowRoot.querySelectorAll('lightning-button')].find((button) => button.label === 'Save' && button.dataset.location === location).click();
}

function errorPopover(element) {
    return element.shadowRoot.querySelector('c-pluto-save-error-popover');
}

async function change(element, fieldName, value) {
    const input = inputFor(element, fieldName);
    input.value = value;
    input.dispatchEvent(new CustomEvent('change', { detail: { value } }));
    await flush();
}

async function flush() {
    for (let i = 0; i < 4; i++) {
        await Promise.resolve();
    }
}

function summary(element) {
    return errorPopover(element)?.shadowRoot.querySelector('[data-id="error-summary"]') ?? null;
}

function summaryText(element) {
    return summary(element)?.textContent ?? null;
}

const UI_API_SAVE_ERROR = {
    body: {
        message: 'An error occurred while trying to update the record. Please try again.',
        output: {
            errors: [{ errorCode: 'FIELD_CUSTOM_VALIDATION_EXCEPTION', message: 'Active tools need an approver.' }],
            fieldErrors: {
                Name: [{ errorCode: 'DUPLICATE_VALUE', message: 'A tool with this name already exists.' }],
                ApprovalRoute__c: [{ errorCode: 'REQUIRED_FIELD_MISSING', message: 'Choose a route.' }]
            }
        }
    }
};

describe('c-pluto-record-layout', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    describe('layout', () => {
        it('renders the page layout sections as rows, so fields side by side line up', async () => {
            const element = await makeForm({ mode: 'view' });
            const sections = [...element.shadowRoot.querySelectorAll('[data-id="layout-section"]')];
            expect(sections.map((section) => section.querySelector('.slds-section__title span').textContent)).toEqual(['Identity', 'Approval']);
            const rows = [...sections[0].querySelectorAll('.record-form-row')];
            expect(rows.map((row) => [...row.querySelectorAll('[data-id="layout-item"]')].map((node) => node.dataset.field))).toEqual([
                ['Name', 'IsActive__c'],
                ['DeveloperName__c', 'SortOrder__c'],
                ['AllowedSensitiveDataCategories__c', 'ImplementationType__c']
            ]);
            expect(rows[0].querySelector('[data-id="layout-item"]').className).toContain('slds-medium-size_1-of-2');
        });

        it('shows the pencil with the field name and keeps the help icon beside the label', async () => {
            const element = await makeForm({ mode: 'view', extraFields: ['Description__c'] });
            const item = [...element.shadowRoot.querySelectorAll('[data-id="layout-item"]')].find((node) => node.dataset.field === 'Description__c');
            const pencil = item.querySelector('.inline-edit-action');
            expect(pencil.title).toBe('Edit Description');
            expect(pencil.parentElement.className).toContain('slds-form-element__control');
            expect(item.querySelector('.slds-form-element__label').nextElementSibling.tagName).toBe('LIGHTNING-HELPTEXT');
        });

        it('fits the modal: no card, plain section headings, Save at the right', async () => {
            const element = await makeForm({ variant: 'modal' });
            expect(element.shadowRoot.querySelector('article').className).not.toContain('slds-card');
            expect(element.shadowRoot.querySelector('button[data-section]')).toBeNull();
            expect(element.shadowRoot.querySelector('.section-heading_plain').textContent).toContain('Identity');
            expect(element.shadowRoot.querySelector('[data-id="docked-footer"]').className).toContain('record-docked-footer_modal');
            expect(element.shadowRoot.querySelector('[data-id="docked-footer"]').className).not.toContain('slds-docked-form-footer');
        });

        it('keeps the slot section with no fields and hides the slotted content when it collapses', async () => {
            const element = await makeForm({ mode: 'view', slotSection: 'Approval', hiddenFields: ['ApproverUser__c'] });
            const sectionKeys = [...element.shadowRoot.querySelectorAll('[data-id="layout-section"]')].map((node) => node.dataset.section);
            expect(sectionKeys).toEqual(['identity', 'approval']);
            const after = element.shadowRoot.querySelector('[data-id="sections-after"]');
            expect(after.className).not.toContain('slds-hide');

            element.shadowRoot.querySelector('button[data-section="approval"]').click();
            await flush();
            expect(after.className).toContain('slds-hide');

            element.shadowRoot.querySelector('button[data-section="identity"]').click();
            await flush();
            expect(after.className).toContain('slds-hide');
        });

        it('drops an empty section that does not own the slot', async () => {
            const element = await makeForm({ mode: 'view', hiddenFields: ['ApproverUser__c'] });
            const sectionKeys = [...element.shadowRoot.querySelectorAll('[data-id="layout-section"]')].map((node) => node.dataset.section);
            expect(sectionKeys).toEqual(['identity']);
            expect(element.shadowRoot.querySelector('[data-id="sections-after"]').className).not.toContain('slds-hide');
        });

        it('puts focus in the first field when the modal opens, once', async () => {
            const focused = [];
            const focus = jest.spyOn(HTMLElement.prototype, 'focus').mockImplementation(function record() {
                focused.push(this.dataset?.field);
            });
            const element = await makeForm({ variant: 'modal' });
            element.mode = 'edit';
            await Promise.resolve();
            const first = [...element.shadowRoot.querySelectorAll('.field-input')].find((input) => !input.disabled);
            expect(focused).toEqual([first.dataset.field]);
            focus.mockRestore();
        });

        it('leaves focus alone when the editor opens on the page', async () => {
            const focus = jest.spyOn(HTMLElement.prototype, 'focus').mockImplementation(() => {});
            await makeForm();
            expect(focus).not.toHaveBeenCalled();
            focus.mockRestore();
        });

        it('outlines the form while editing on the page and docks the footer inside it', async () => {
            const element = await makeForm();
            const body = element.shadowRoot.querySelector('.record-form-body');
            expect(body.className).toContain('record-form-body_edit');
            expect(body.querySelector('[data-id="docked-footer"]')).not.toBeNull();
            expect(element.shadowRoot.querySelector('.record-required-legend').textContent).toContain('Required Information');
        });

        it('leaves out layout fields the user cannot see and sections with nothing to show', async () => {
            const element = await makeForm({ mode: 'view' });
            expect(shownFields(element)).not.toContain('Hidden_From_User__c');
            expect(element.shadowRoot.textContent).not.toContain('Custom Links');
        });

        it('hides fields the host owns and places fields an optional package adds', async () => {
            const element = await makeForm({
                mode: 'view',
                hiddenFields: ['ImplementationType__c'],
                additionalFields: [
                    { fieldApiName: 'ApprovalRoute__c', before: 'ApproverUser__c' },
                    { fieldApiName: 'Missing__c', before: 'Name' }
                ]
            });
            expect(shownFields(element)).not.toContain('ImplementationType__c');
            const approval = element.shadowRoot.querySelectorAll('[data-id="layout-section"]')[1];
            expect([...approval.querySelectorAll('[data-id="layout-item"]')].map((node) => node.dataset.field)).toEqual([
                'ApprovalRoute__c',
                'ApproverUser__c'
            ]);
        });

        it('reads fields the layout does not carry through optional fields', async () => {
            const element = await makeForm({ additionalFields: [{ fieldApiName: 'ApprovalRoute__c' }], hiddenFields: ['ImplementationType__c'] });
            expect(recordAdapter.getLastConfig().optionalFields).toEqual(
                expect.arrayContaining(['AgentTool__c.ApprovalRoute__c', 'AgentTool__c.ImplementationType__c'])
            );
            expect(element.getFieldValue('ApprovalRoute__c')).toBe('a05000000000000AAA');
        });

        it('does not offer an optional approval route when UI API withholds field access', async () => {
            const element = await makeForm({ additionalFields: [{ fieldApiName: 'ApprovalRoute__c' }] });
            const { ApprovalRoute__c: withheld, ...visibleFields } = OBJECT_INFO.fields;
            objectInfoAdapter.emit({ ...OBJECT_INFO, fields: visibleFields });
            await flush();

            expect(shownFields(element)).not.toContain('ApprovalRoute__c');
        });

        it('asks for the layout that matches the mode and the record type', async () => {
            const element = await makeForm();
            expect(layoutAdapter.getLastConfig()).toMatchObject({
                objectApiName: 'AgentTool__c',
                layoutType: 'Full',
                mode: 'Edit',
                recordTypeId: '012000000000000AAA'
            });
            element.mode = 'view';
            await flush();
            expect(layoutAdapter.getLastConfig().mode).toBe('View');
        });

        it('collapses and reopens a section', async () => {
            const element = await makeForm({ mode: 'view' });
            const toggle = element.shadowRoot.querySelector('button[data-section="identity"]');
            toggle.click();
            await flush();
            expect(shownFields(element)).not.toContain('Name');
            expect(toggle.getAttribute('aria-expanded')).toBe('false');
            toggle.click();
            await flush();
            expect(shownFields(element)).toContain('Name');
        });

        it('shows each field help once: caller guidance on Name, metadata help from the input field', async () => {
            const element = await makeForm({
                customFieldRenderers: { Name: { helpText: 'Choose a clear display name for this action.' } },
                extraFields: ['Description__c']
            });
            const help = [...element.shadowRoot.querySelectorAll('lightning-helptext')].map((node) => node.content);
            expect(help).toEqual(['Choose a clear display name for this action.']);
            expect(inputFor(element, 'Name').variant).toBe('label-hidden');
            expect(inputFor(element, 'Description__c').variant).toBe('label-stacked');
        });

        it('shows metadata help once in view mode', async () => {
            const element = await makeForm({ mode: 'view', extraFields: ['Description__c'] });
            const help = [...element.shadowRoot.querySelectorAll('lightning-helptext')].map((node) => node.content);
            expect(help).toEqual(['Describe what the tool does.']);
        });

        it('replaces the fields with an inline message when the layout cannot load', async () => {
            const element = createElement('c-pluto-record-layout', { is: PlutoRecordLayout });
            element.objectApiName = 'AgentTool__c';
            element.recordId = 'a01000000000000AAA';
            element.mode = 'view';
            document.body.appendChild(element);
            objectInfoAdapter.emit(OBJECT_INFO);
            layoutAdapter.error({ message: 'Layout unavailable' }, 403);
            await flush();
            expect(element.shadowRoot.querySelector('[data-id="load-error"]').textContent).toContain('Layout unavailable');
            expect(element.shadowRoot.querySelector('lightning-record-edit-form')).toBeNull();
        });
    });

    describe('view mode', () => {
        it('shows standard fields with output fields and caller options as their labels', async () => {
            const element = await makeForm({ mode: 'view', fieldOptions: { Name: [{ label: 'Original tool', value: 'Original' }] } });
            expect(element.shadowRoot.querySelector('lightning-output-field[data-field="SortOrder__c"]')).not.toBeNull();
            expect(element.shadowRoot.querySelector('[data-field="Name"] [data-id="text-output"]').textContent).toBe('Original tool');
            expect(element.shadowRoot.querySelector('.field-input')).toBeNull();
        });

        it('shows a stored option that no longer resolves as unavailable instead of blank', async () => {
            const element = await makeForm({ fieldOptions: { Name: [{ label: 'Other', value: 'Other' }] } });
            expect(inputFor(element, 'Name').options).toEqual([
                { label: 'Other', value: 'Other' },
                { label: 'Original (unavailable)', value: 'Original' }
            ]);
        });

        it('offers an inline edit pencil only on fields the user may edit', async () => {
            const element = await makeForm({ mode: 'view' });
            const pencils = [...element.shadowRoot.querySelectorAll('button.inline-edit-action')].map((node) => node.dataset.field);
            expect(pencils).toContain('Name');
            expect(pencils).not.toContain('DeveloperName__c');
            expect(pencils).not.toContain('ImplementationType__c');

            const edited = jest.fn();
            element.addEventListener('edit', edited);
            element.shadowRoot.querySelector('button.inline-edit-action[data-field="Name"]').click();
            expect(edited.mock.calls[0][0].detail).toEqual({ fieldApiName: 'Name' });
        });

        it('focuses the field whose pencil was clicked once the host switches to edit', async () => {
            const element = await makeForm({ mode: 'view' });
            const focused = [];
            const focus = jest.spyOn(HTMLElement.prototype, 'focus').mockImplementation(function record() {
                focused.push(this.dataset?.field);
            });
            element.addEventListener('edit', () => {
                element.mode = 'edit';
            });

            element.shadowRoot.querySelector('button.inline-edit-action[data-field="Description__c"], button.inline-edit-action[data-field="Name"]').click();
            await flush();

            expect(focused).toEqual(['Name']);
            focus.mockRestore();
        });

        it('leaves the name and actions to the highlights panel when the host hides the header', async () => {
            const element = await makeForm({ mode: 'view' });
            const labels = () => [...element.shadowRoot.querySelectorAll('lightning-button')].map((candidate) => candidate.label);
            expect(labels()).toEqual(['Back to List', 'Edit']);

            element.hideHeader = true;
            await flush();
            expect(element.shadowRoot.querySelector('.slds-page-header')).toBeNull();
            expect(labels()).toEqual([]);
            expect(shownFields(element)).toContain('Name');
            expect(element.shadowRoot.querySelector('button.inline-edit-action[data-field="Name"]')).not.toBeNull();
        });

        it('discards unsaved values when the host returns to view mode', async () => {
            const element = await makeForm();
            await change(element, 'Name', 'Unsaved');
            element.mode = 'view';
            await flush();
            expect(element.getFieldValue('Name')).toBe('Original');
        });

        it('shows JSON read-only in view mode', async () => {
            const element = await makeForm({
                mode: 'view',
                extraFields: ['Description__c'],
                customFieldRenderers: { Description__c: { renderer: 'json' } },
                description: '{"option":true}'
            });
            const editor = element.shadowRoot.querySelector('c-json-editor');
            expect(editor.disabled).toBe(true);
            expect(editor.shadowRoot.querySelector('lightning-button')).toBeNull();
            expect(editor.shadowRoot.querySelector('pre').textContent).toBe('{\n  "option": true\n}');
        });

        it('leaves tabs to the record page', async () => {
            const element = await makeForm();
            expect(element.shadowRoot.querySelector('lightning-tabset')).toBeNull();
        });
    });

    describe('edit mode', () => {
        it('renders standard fields with input fields and layout read-only fields as output', async () => {
            const element = await makeForm();
            expect(inputFor(element, 'AllowedSensitiveDataCategories__c').value).toBe('PII;Financial');
            expect(inputFor(element, 'Name').required).toBe(true);
            expect(inputFor(element, 'ImplementationType__c')).toBeUndefined();
            expect(element.shadowRoot.querySelector('lightning-output-field[data-field="ImplementationType__c"]')).not.toBeNull();
            expect(element.shadowRoot.querySelector('.record-required-legend')).not.toBeNull();
        });

        it('shows a field the user cannot edit as read-only, and never saves a value set on it', async () => {
            const element = await makeForm();
            expect(inputFor(element, 'DeveloperName__c')).toBeUndefined();
            expect(element.shadowRoot.querySelector('lightning-output-field[data-field="DeveloperName__c"]')).not.toBeNull();

            element.setFieldValue('DeveloperName__c', 'forced');
            await change(element, 'Name', 'Revised');
            clickSave(element);
            await flush();

            expect(updateRecord).toHaveBeenCalledWith({ fields: { Id: 'a01000000000000AAA', Name: 'Revised' } });
        });

        it('updates only a field the admin changed', async () => {
            const element = await makeForm();
            await change(element, 'Name', 'Revised');
            clickSave(element);
            await flush();
            expect(updateRecord).toHaveBeenCalledWith({ fields: { Id: 'a01000000000000AAA', Name: 'Revised' } });
        });

        it('leaves edit without a request or a toast when nothing changed', async () => {
            const element = await makeForm();
            const saved = jest.fn();
            const toasts = jest.fn();
            element.addEventListener('save', saved);
            element.addEventListener('lightning__showtoast', toasts);
            clickSave(element);
            await flush();
            expect(updateRecord).not.toHaveBeenCalled();
            expect(saved).toHaveBeenCalledTimes(1);
            expect(toasts).not.toHaveBeenCalled();
        });

        it('normalizes lookup and checkbox values from the input fields', async () => {
            const element = await makeForm();
            const approver = inputFor(element, 'ApproverUser__c');
            approver.dispatchEvent(new CustomEvent('change', { detail: { value: ['005000000000000AAA'] } }));
            const active = inputFor(element, 'IsActive__c');
            active.dispatchEvent(new CustomEvent('change', { detail: { value: false, checked: false } }));
            await flush();
            clickSave(element);
            await flush();
            expect(updateRecord).toHaveBeenCalledWith({ fields: { Id: 'a01000000000000AAA', ApproverUser__c: '005000000000000AAA', IsActive__c: false } });
        });

        it('keeps what the admin typed when the record re-emits', async () => {
            const element = await makeForm();
            await change(element, 'Name', 'Unsaved name');
            recordAdapter.emit({ recordTypeId: '012000000000000AAA', fields: { Name: { value: 'Server name' }, SortOrder__c: { value: 7 } } });
            await flush();
            expect(element.getFieldValue('Name')).toBe('Unsaved name');
            expect(element.getFieldValue('SortOrder__c')).toBe(7);
        });

        it('saves through its own path when Enter submits the form', async () => {
            const element = await makeForm();
            await change(element, 'Name', 'Revised');
            const submit = new CustomEvent('submit', { cancelable: true });
            element.shadowRoot.querySelector('lightning-record-edit-form').dispatchEvent(submit);
            await flush();
            expect(submit.defaultPrevented).toBe(true);
            expect(updateRecord).toHaveBeenCalledWith({ fields: { Id: 'a01000000000000AAA', Name: 'Revised' } });
        });

        it('leaves navigation to the host on Cancel', async () => {
            const element = await makeForm();
            const cancelled = jest.fn();
            element.addEventListener('cancel', cancelled);
            [...element.shadowRoot.querySelectorAll('lightning-button')].find((button) => button.label === 'Cancel').click();
            expect(cancelled).toHaveBeenCalledTimes(1);
        });

        it('defers persistence until the host completes a combined save', async () => {
            const element = await makeForm({ deferSave: true });
            const requested = jest.fn();
            const saved = jest.fn();
            element.addEventListener('saverequest', requested);
            element.addEventListener('save', saved);
            await change(element, 'Name', 'Revised');

            clickSave(element);
            expect(requested.mock.calls[0][0].detail.recordInput.fields).toEqual({ Id: 'a01000000000000AAA', Name: 'Revised' });
            expect(updateRecord).not.toHaveBeenCalled();
            expect(saved).not.toHaveBeenCalled();

            element.completeSave('a01000000000000AAA');
            expect(saved).toHaveBeenCalledTimes(1);
        });

        it('reports every change with all current values', async () => {
            const element = await makeForm();
            const changes = jest.fn();
            element.addEventListener('fieldchange', changes);
            await change(element, 'Name', 'Revised');
            expect(changes.mock.calls[0][0].detail).toMatchObject({
                fieldName: 'Name',
                value: 'Revised',
                allFieldValues: { Name: 'Revised', SortOrder__c: 1 }
            });
        });
    });

    describe('rules', () => {
        it('recalculates dependent visibility when the controller changes', async () => {
            const element = await makeForm({
                fieldDependencies: [{ controllingField: 'Name', controllingValue: 'Revised', showFields: ['AllowedSensitiveDataCategories__c'] }]
            });
            expect(inputFor(element, 'AllowedSensitiveDataCategories__c')).toBeUndefined();
            await change(element, 'Name', 'Revised');
            expect(inputFor(element, 'AllowedSensitiveDataCategories__c')).not.toBeUndefined();
        });

        it('shows a field that any matching rule shows', async () => {
            const element = await makeForm({
                fieldDependencies: [
                    { controllingField: 'Name', controllingValue: 'Original', showFields: ['SortOrder__c'] },
                    { controllingField: 'Name', controllingValue: 'Other', showFields: ['SortOrder__c'] }
                ]
            });
            expect(inputFor(element, 'SortOrder__c')).not.toBeUndefined();
        });

        it('makes a field required while its rule matches', async () => {
            const element = await makeForm({
                fieldDependencies: [{ controllingField: 'IsActive__c', controllingValue: true, requiredFields: ['SortOrder__c'] }]
            });
            expect(inputFor(element, 'SortOrder__c').required).toBe(true);
            inputFor(element, 'IsActive__c').dispatchEvent(new CustomEvent('change', { detail: { checked: false, value: false } }));
            await flush();
            expect(inputFor(element, 'SortOrder__c').required).toBe(false);
        });

        it('saves an explicit clearing of a hidden dependent field', async () => {
            const element = await makeForm({
                fieldDependencies: [{ controllingField: 'Name', controllingValue: 'Revised', showFields: ['AllowedSensitiveDataCategories__c'] }]
            });
            element.setFieldValue('AllowedSensitiveDataCategories__c', null);
            clickSave(element);
            await flush();
            expect(updateRecord).toHaveBeenCalledWith({ fields: { Id: 'a01000000000000AAA', AllowedSensitiveDataCategories__c: null } });
        });

        it('sets and locks a fixed value while its rule matches', async () => {
            const element = await makeForm({
                customFieldRenderers: { Description__c: { renderer: 'smartLookup' } },
                extraFields: ['Description__c'],
                fieldDependencies: [{ controllingField: 'Name', controllingValue: 'Revised', fixedValues: { Description__c: 'User' } }]
            });
            const changes = [];
            element.addEventListener('fieldchange', (event) => changes.push(event.detail.fieldName));
            expect(inputFor(element, 'Description__c').disabled).toBe(false);

            await change(element, 'Name', 'Revised');
            expect(element.getFieldValue('Description__c')).toBe('User');
            expect(inputFor(element, 'Description__c').disabled).toBe(true);
            expect(changes).toEqual(['Description__c', 'Name']);

            clickSave(element);
            await flush();
            expect(updateRecord).toHaveBeenCalledWith({ fields: { Id: 'a01000000000000AAA', Name: 'Revised', Description__c: 'User' } });

            await change(element, 'Name', 'Other');
            expect(inputFor(element, 'Description__c').disabled).toBe(false);
            expect(element.getFieldValue('Description__c')).toBe('User');
        });

        it('replaces a stored value that a matching fixed-value rule no longer allows', async () => {
            const element = await makeForm({
                name: 'Revised',
                customFieldRenderers: { Description__c: { renderer: 'smartLookup' } },
                extraFields: ['Description__c'],
                fieldDependencies: [{ controllingField: 'Name', controllingValue: 'Revised', fixedValues: { Description__c: 'User' } }]
            });
            expect(element.getFieldValue('Description__c')).toBe('User');
            expect(inputFor(element, 'Description__c').disabled).toBe(true);
        });

        it('never forces a fixed value onto a field the user cannot edit', async () => {
            const element = await makeForm({
                name: 'Revised',
                fieldDependencies: [{ controllingField: 'Name', controllingValue: 'Revised', fixedValues: { DeveloperName__c: 'fixed' } }]
            });
            expect(element.getFieldValue('DeveloperName__c')).toBe('stable_name');
        });
    });

    describe('renderers', () => {
        it('renders a smart lookup and forwards search and selection', async () => {
            const element = await makeForm({
                customFieldRenderers: { Name: { renderer: 'smartLookup' } },
                fieldOptions: { Name: [{ label: 'Account', value: 'Account' }] }
            });
            const lookup = element.shadowRoot.querySelector('c-smart-lookup');
            expect(lookup.options).toEqual([{ label: 'Account', value: 'Account' }]);
            const searched = jest.fn();
            element.addEventListener('fieldsearch', searched);
            lookup.dispatchEvent(new CustomEvent('search', { detail: { searchTerm: 'Acc' } }));
            lookup.dispatchEvent(new CustomEvent('change', { detail: { value: 'Account' } }));
            await flush();

            expect(searched.mock.calls[0][0].detail).toEqual({ fieldName: 'Name', searchTerm: 'Acc' });
            expect(element.getFieldValue('Name')).toBe('Account');
            expect(element.shadowRoot.querySelector('lightning-input-field[data-field="Name"]')).toBeNull();
        });

        it('renders caller options as a picklist and saves None as blank', async () => {
            const element = await makeForm({
                fieldOptions: {
                    Name: [
                        { label: '--None--', value: '' },
                        { label: 'Original', value: 'Original' }
                    ]
                }
            });
            const picklist = inputFor(element, 'Name');
            expect(picklist.tagName).toBe('LIGHTNING-COMBOBOX');
            picklist.dispatchEvent(new CustomEvent('change', { detail: { value: '' } }));
            await flush();
            clickSave(element);
            await flush();
            expect(updateRecord).toHaveBeenCalledWith({ fields: { Id: 'a01000000000000AAA', Name: null } });
        });

        it('blocks invalid JSON drafts and saves corrected JSON', async () => {
            const element = await makeForm({
                extraFields: ['Description__c'],
                customFieldRenderers: { Description__c: { renderer: 'json', objectOnly: true } },
                description: '{'
            });
            clickSave(element);
            await flush();
            expect(updateRecord).not.toHaveBeenCalled();
            const editor = element.shadowRoot.querySelector('c-json-editor');
            expect(editor.shadowRoot.querySelector('[role="alert"]').textContent).toContain('Enter valid JSON');
            expect(summaryText(element)).toContain('Description');

            editor.dispatchEvent(new CustomEvent('change', { detail: { value: '{"option":true}' } }));
            await flush();
            clickSave(element);
            await flush();
            expect(updateRecord).toHaveBeenCalledWith({ fields: { Id: element.recordId, Description__c: '{"option":true}' } });
        });
    });

    describe('new records', () => {
        it('starts from host defaults and creates every visible editable field', async () => {
            const element = await makeForm({ isNew: true, defaultValues: { Name: 'Draft', SortOrder__c: 3 } });
            expect(element.shadowRoot.querySelector('.slds-page-header__title').textContent).toContain('New Agent Tool');
            expect(shownFields(element)).not.toContain('ImplementationType__c');
            expect(layoutAdapter.getLastConfig().mode).toBe('Create');

            const toasts = jest.fn();
            const saved = jest.fn();
            element.addEventListener('lightning__showtoast', toasts);
            element.addEventListener('save', saved);
            clickSave(element);
            await flush();

            expect(createRecord).toHaveBeenCalledWith({
                apiName: 'AgentTool__c',
                recordTypeId: '012000000000000AAA',
                fields: { Name: 'Draft', IsActive__c: false, SortOrder__c: 3, AllowedSensitiveDataCategories__c: null, ApproverUser__c: null }
            });
            expect(toasts.mock.calls[0][0].detail.title).toBe('Agent Tool "Draft" was created.');
            expect(saved.mock.calls[0][0].detail).toEqual({ recordId: 'a01000000000001AAA', action: 'new' });
        });

        it('creates a hidden field the host set', async () => {
            const element = await makeForm({ isNew: true, hiddenFields: ['ImplementationType__c'], defaultValues: { ImplementationType__c: 'Flow' } });
            clickSave(element);
            await flush();
            expect(createRecord.mock.calls[0][0].fields.ImplementationType__c).toBe('Flow');
        });
    });

    describe('errors', () => {
        it('shows UI API save errors on their fields and in a summary instead of the generic wrapper or a toast', async () => {
            updateRecord.mockRejectedValueOnce(UI_API_SAVE_ERROR);
            const element = await makeForm();
            const toasts = jest.fn();
            element.addEventListener('lightning__showtoast', toasts);
            await change(element, 'Name', 'Duplicate');

            clickSave(element);
            await flush();

            const text = summaryText(element);
            expect(text).toContain('We hit a snag.');
            expect(text).toContain('Active tools need an approver.');
            expect(text).toContain('Approval Route: Choose a route.');
            expect(text).toContain('Review the following fields');
            expect(text).toContain('Tool');
            expect(text).not.toContain('Please try again');
            expect(element.shadowRoot.querySelector('[data-id="field-error"][data-field="Name"]').textContent).toBe('A tool with this name already exists.');
            expect(element.shadowRoot.querySelector('[data-field="Name"] .slds-has-error')).not.toBeNull();
            expect(errorPopover(element).shadowRoot.activeElement).toBe(summary(element));
            expect(toasts).not.toHaveBeenCalled();
        });

        it('pushes a server error into a custom input that supports custom validity', async () => {
            updateRecord.mockRejectedValueOnce(UI_API_SAVE_ERROR);
            const element = await makeForm({ fieldOptions: { Name: [{ label: 'Duplicate', value: 'Duplicate' }] } });
            await change(element, 'Name', 'Duplicate');
            const name = inputFor(element, 'Name');
            name.setCustomValidity = jest.fn();
            name.reportValidity = jest.fn();

            clickSave(element);
            await flush();

            expect(name.setCustomValidity).toHaveBeenCalledWith('A tool with this name already exists.');
            expect(name.reportValidity).toHaveBeenCalled();
            expect(element.shadowRoot.querySelector('[data-id="field-error"]')).toBeNull();
        });

        it('opens the error popover beside the Save button that was clicked', async () => {
            updateRecord.mockRejectedValueOnce(UI_API_SAVE_ERROR).mockRejectedValueOnce(UI_API_SAVE_ERROR);
            const element = await makeForm();
            await change(element, 'Name', 'Duplicate');

            clickSave(element, 'header');
            await flush();
            expect(errorPopover(element).placement).toBe('below');
            expect(errorPopover(element).closest('[data-id="docked-footer"]')).toBeNull();

            clickSave(element, 'footer');
            await flush();
            expect(element.shadowRoot.querySelectorAll('c-pluto-save-error-popover')).toHaveLength(1);
            expect(errorPopover(element).placement).toBe('above');
            expect(errorPopover(element).closest('[data-id="docked-footer"]')).not.toBeNull();
        });

        it('closes the popover but keeps the error icon to reopen it', async () => {
            updateRecord.mockRejectedValueOnce(UI_API_SAVE_ERROR);
            const element = await makeForm();
            await change(element, 'Name', 'Duplicate');
            clickSave(element);
            await flush();

            errorPopover(element).dispatchEvent(new CustomEvent('close'));
            await flush();
            expect(summary(element)).toBeNull();
            expect(errorPopover(element)).not.toBeNull();

            errorPopover(element).dispatchEvent(new CustomEvent('toggle'));
            await flush();
            expect(summaryText(element)).toContain('Active tools need an approver.');
        });

        it('focuses a field chosen from the popover', async () => {
            updateRecord.mockRejectedValueOnce(UI_API_SAVE_ERROR);
            const element = await makeForm();
            await change(element, 'Name', 'Duplicate');
            clickSave(element);
            await flush();
            const name = inputFor(element, 'Name');
            name.focus = jest.fn();

            summary(element).querySelector('a[data-field="Name"]').click();

            expect(name.focus).toHaveBeenCalled();
        });

        it('clears a field error when the admin edits that field', async () => {
            updateRecord.mockRejectedValueOnce(UI_API_SAVE_ERROR);
            const element = await makeForm();
            await change(element, 'Name', 'Duplicate');
            clickSave(element);
            await flush();

            await change(element, 'Name', 'Unique');

            expect(element.shadowRoot.querySelector('[data-id="field-error"][data-field="Name"]')).toBeNull();
            expect(summaryText(element)).not.toContain('Review the following fields');
            expect(summaryText(element)).toContain('Active tools need an approver.');
        });

        it('removes the summary once a retry saves, and toasts the saved record', async () => {
            updateRecord.mockRejectedValueOnce(UI_API_SAVE_ERROR);
            const element = await makeForm();
            const toasts = jest.fn();
            element.addEventListener('lightning__showtoast', toasts);
            await change(element, 'Name', 'Duplicate');
            clickSave(element);
            await flush();
            expect(summaryText(element)).not.toBeNull();

            await change(element, 'Name', 'Revised');
            clickSave(element);
            await flush();

            expect(summaryText(element)).toBeNull();
            expect(toasts).toHaveBeenCalledTimes(1);
            expect(toasts.mock.calls[0][0].detail).toMatchObject({ title: 'Agent Tool "Revised" was saved.', variant: 'success' });
        });

        it('shows an Apex failure passed to failSave and lets the admin retry', async () => {
            const element = await makeForm({ deferSave: true });
            await change(element, 'Name', 'Revised');
            clickSave(element);
            await flush();
            const save = [...element.shadowRoot.querySelectorAll('lightning-button')].find((button) => button.label === 'Save');
            expect(save.disabled).toBe(true);

            element.failSave({ body: { message: 'Tool type UpdateRecord needs an object.' } });
            await flush();

            expect(summaryText(element)).toContain('Tool type UpdateRecord needs an object.');
            expect(save.disabled).toBe(false);
        });

        it('blocks save and lists the fields the base components report invalid', async () => {
            const element = await makeForm();
            await change(element, 'Name', '');
            inputFor(element, 'Name').reportValidity = jest.fn(() => false);

            clickSave(element);
            await flush();

            expect(updateRecord).not.toHaveBeenCalled();
            const link = summary(element).querySelector('a');
            expect(link.dataset.field).toBe('Name');
            expect(link.textContent).toBe('Tool');
        });

        it('marks an empty required smart lookup red and lists it before saving', async () => {
            const element = await makeForm({
                requiredFields: ['Name'],
                customFieldRenderers: { Name: { renderer: 'smartLookup' } },
                name: ''
            });

            clickSave(element);
            await flush();

            expect(updateRecord).not.toHaveBeenCalled();
            const lookup = element.shadowRoot.querySelector('c-smart-lookup');
            expect(lookup.shadowRoot.querySelector('.slds-has-error')).not.toBeNull();
            expect(lookup.shadowRoot.querySelector('.slds-form-element__help').textContent).toBe('Complete this field.');
            expect(summary(element).querySelector('a[data-field="Name"]').textContent).toBe('Tool');
        });

        it('saves a required smart lookup whose stored value has no loaded options yet', async () => {
            const element = await makeForm({
                requiredFields: ['Name'],
                customFieldRenderers: { Name: { renderer: 'smartLookup' } }
            });
            const saved = jest.fn();
            element.addEventListener('save', saved);

            clickSave(element);
            await flush();

            expect(summary(element)).toBeNull();
            expect(saved).toHaveBeenCalledTimes(1);
        });

        it('requires a markdown field and says so under the editor', async () => {
            const element = await makeForm({
                extraFields: ['Description__c'],
                requiredFields: ['Description__c'],
                customFieldRenderers: { Description__c: { renderer: 'markdown' } },
                description: ''
            });

            clickSave(element);
            await flush();

            expect(updateRecord).not.toHaveBeenCalled();
            expect(element.shadowRoot.querySelector('[data-id="field-error"][data-field="Description__c"]').textContent).toBe('Complete this field.');
            expect(summaryText(element)).toContain('Description');
        });

        it('replaces the fields with an inline message when the record cannot load', async () => {
            const element = createElement('c-pluto-record-layout', { is: PlutoRecordLayout });
            element.objectApiName = 'AgentTool__c';
            element.recordId = 'a01000000000000AAA';
            element.mode = 'view';
            const toasts = jest.fn();
            element.addEventListener('lightning__showtoast', toasts);
            document.body.appendChild(element);
            objectInfoAdapter.emit(OBJECT_INFO);
            layoutAdapter.emit(layout());
            recordAdapter.error({ message: 'The requested resource does not exist' }, 404);
            await flush();

            expect(element.shadowRoot.querySelector('[data-id="load-error"]').textContent).toContain('The requested resource does not exist');
            expect(element.shadowRoot.querySelector('[data-id="layout-section"]')).toBeNull();
            expect(toasts).not.toHaveBeenCalled();
        });
    });
});
