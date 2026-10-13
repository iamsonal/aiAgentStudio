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

import { LightningElement, api } from 'lwc';
import searchStandardTargetSObjects from '@salesforce/apex/ToolAuthoringController.searchStandardTargetSObjects';
import getFieldOptions from '@salesforce/apex/ToolAuthoringController.getFieldOptions';
import getRecordTypeOptions from '@salesforce/apex/ToolAuthoringController.getRecordTypeOptions';
import searchFlows from '@salesforce/apex/ToolAuthoringController.searchFlows';
import searchReports from '@salesforce/apex/ToolAuthoringController.searchReports';
import getQueueOptions from '@salesforce/apex/ToolAuthoringController.getQueueOptions';
import getNamedCredentialOptions from '@salesforce/apex/ToolAuthoringController.getNamedCredentialOptions';

/** Core allows at most this many fields on a record tool. */
const MAX_FIELDS = 30;
const OTHER_RECORD = '__other';
const CONTROL_TYPES = [
    'object',
    'fields',
    'query',
    'flow',
    'boolean',
    'text',
    'string',
    'textList',
    'keyValues',
    'record',
    'report',
    'queue',
    'namedCredential'
];

let nextRow = 0;

/**
 * The tool type's settings, one control for each, chosen by the setting's
 * type. Controlled: the parent passes values and gets each change in a
 * settingchange event. A tool type that declares no settings gets one JSON
 * box for all of them.
 */
export default class ToolSettingsForm extends LightningElement {
    @api toolType = '';
    @api readOnly = false;
    /** True when the tool type declares no settings, so they are typed as JSON. */
    @api undeclared = false;
    /** Set by the parent after a failed save, so empty required settings show as errors. */
    @api showRequired = false;

    fieldsByObject = {};
    recordTypesByObject = {};
    flowOptions = [];
    queueOptions = [];
    namedCredentialOptions = [];
    jsonErrors = {};
    jsonDrafts = {};
    keyValueDrafts = {};
    recordKinds = {};
    _settings = [];
    _values = {};
    _loaded = new Set();

    /** The settings the tool type declares, as Core describes them. */
    @api
    get settings() {
        return this._settings;
    }

    set settings(next) {
        this._settings = Array.isArray(next) ? next : [];
        this.loadLists();
        this.loadObjectData();
    }

    @api
    get values() {
        return this._values;
    }

    set values(next) {
        this._values = next && typeof next === 'object' && !Array.isArray(next) ? next : {};
        this.loadObjectData();
    }

    get undeclaredJson() {
        if (this.jsonDrafts.__all !== undefined) {
            return this.jsonDrafts.__all;
        }
        return Object.keys(this._values).length ? JSON.stringify(this._values, null, 2) : '';
    }

    get undeclaredError() {
        return this.jsonErrors.__all || '';
    }

    get controls() {
        return this._settings
            .filter((setting) => !this.waitsForObject(setting) && !this.hiddenRecordType(setting))
            .map((setting) => {
                const value = this._values[setting.name];
                const objectName = this.objectFor(setting);
                const type = this.controlType(setting);
                const empty = value === undefined || value === null || value === '' || (Array.isArray(value) && !value.length);
                const missing = this.showRequired && setting.required && empty;
                const textValue = value === undefined || value === null ? '' : typeof value === 'object' ? '' : String(value);
                const recordKind = type === 'record' ? this.recordKindOf(setting, textValue) : '';
                const recordObject = (setting.recordObjects || []).find((option) => option.value === recordKind);
                return {
                    ...setting,
                    key: setting.name,
                    value,
                    textValue,
                    checked: value === true,
                    isObject: type === 'object',
                    isRecordType: type === 'recordType',
                    isFields: type === 'fields',
                    isFieldValues: type === 'fieldValues',
                    isQuery: type === 'query',
                    isFlow: type === 'flow',
                    isCheckbox: type === 'boolean',
                    isPicklist: type === 'picklist',
                    isTextArea: type === 'text',
                    isNumber: type === 'number',
                    isString: type === 'string',
                    isTextList: type === 'textList',
                    isKeyValues: type === 'keyValues',
                    isRecord: type === 'record',
                    isReport: type === 'report',
                    isQueue: type === 'queue',
                    isNamedCredential: type === 'namedCredential',
                    isJson: type === 'json',
                    placeholder: setting.blankMeaning ? `Blank: ${setting.blankMeaning}` : '',
                    disabled: this.readOnly,
                    missing,
                    missingMessage: missing ? `${setting.label} is required.` : '',
                    options: this.withBlank(
                        setting,
                        (setting.allowedValues || []).map((option) => ({ label: option, value: option }))
                    ),
                    fieldOptions: this.fieldChoices(objectName, value),
                    fieldList: Array.isArray(value) ? value : [],
                    fields: this.fixableFields(objectName, value),
                    fieldValues: value && typeof value === 'object' && !Array.isArray(value) ? value : {},
                    recordTypeOptions: [
                        { label: setting.blankMeaning || 'The default record type', value: '' },
                        ...(this.recordTypesByObject[objectName] || [])
                    ],
                    flowOptions: this.withSaved(this.flowOptions, textValue),
                    queueOptions: this.withBlank(setting, this.withSaved(this.queueOptions, textValue)),
                    namedCredentialOptions: this.withBlank(setting, this.withSaved(this.namedCredentialOptions, textValue)),
                    maxFields: MAX_FIELDS,
                    listText: Array.isArray(value) ? value.join('\n') : '',
                    keyValueRows: this.keyValueRows(setting, value),
                    keyValueChoices: (setting.allowedValues || []).map((option) => ({ label: option, value: option })),
                    hasKeyValueChoices: (setting.allowedValues || []).length > 0,
                    recordKindOptions: this.recordKindOptions(setting),
                    recordKind,
                    recordObjectApiName: recordObject ? recordObject.value : '',
                    recordObjectLabel: recordObject ? recordObject.label : '',
                    isRecordPicker: !!recordObject,
                    isOtherRecord: recordKind === OTHER_RECORD,
                    jsonText:
                        this.jsonDrafts[setting.name] !== undefined ? this.jsonDrafts[setting.name] : value === undefined ? '' : JSON.stringify(value, null, 2),
                    jsonError: this.jsonErrors[setting.name] || ''
                };
            });
    }

    /** A setting about the object's fields appears once an object is chosen. */
    waitsForObject(setting) {
        return !!setting.objectSetting && !this.objectFor(setting);
    }

    /** Record Type appears only once Pluto has found record types on the chosen object. */
    hiddenRecordType(setting) {
        if (this.controlType(setting) !== 'recordType') {
            return false;
        }
        const types = this.recordTypesByObject[this.objectFor(setting)];
        return !Array.isArray(types) || types.length === 0;
    }

    controlType(setting) {
        const type = setting.type || '';
        const lower = type.toLowerCase();
        if ((lower === 'string' || lower === 'text') && (setting.allowedValues || []).length) {
            return 'picklist';
        }
        if (lower === 'integer' || lower === 'number') {
            return 'number';
        }
        if (lower === 'recordtype') {
            return 'recordType';
        }
        if (lower === 'fieldvalues') {
            return 'fieldValues';
        }
        const known = CONTROL_TYPES.find((candidate) => candidate.toLowerCase() === lower);
        return known || 'json';
    }

    /** The object a field setting belongs to: a fixed one, or the value of its object setting. */
    objectFor(setting) {
        if (setting.objectApiName) {
            return setting.objectApiName;
        }
        return setting.objectSetting ? this._values[setting.objectSetting] : null;
    }

    /** An optional setting can go back to blank, which means its blankMeaning. */
    withBlank(setting, options) {
        if (setting.required || !options.length) {
            return options;
        }
        return [{ label: setting.blankMeaning || 'None', value: '' }, ...options];
    }

    /** Keeps a saved value choosable even when the list no longer has it, as with a Flow made inactive. */
    withSaved(options, saved) {
        if (!saved || options.some((option) => option.value === saved)) {
            return options;
        }
        return [...options, { label: saved, value: saved }];
    }

    /** Fields the tool can write: settable on create for Create Record, updateable for Update Record, any readable field otherwise. */
    writableFields(objectName) {
        const type = (this.toolType || '').toLowerCase();
        return (this.fieldsByObject[objectName] || []).filter((field) =>
            type === 'createrecord' ? field.createable : type === 'updaterecord' ? field.updateable : true
        );
    }

    /** A field is either fixed or set by the agent, never both, so each list leaves out the other's fields. */
    fieldChoices(objectName, selected) {
        const fixed = this.fixedFieldNames();
        const keep = new Set(Array.isArray(selected) ? selected : []);
        return this.writableFields(objectName)
            .filter((field) => keep.has(field.value) || !fixed.has(field.value))
            .map((field) => ({ label: `${field.label} (${field.value})`, value: field.value }));
    }

    fixableFields(objectName, fixedValues) {
        const agentFields = new Set(this.settingOfType('fields').flatMap((setting) => this._values[setting.name] || []));
        const fixed = fixedValues && typeof fixedValues === 'object' && !Array.isArray(fixedValues) ? fixedValues : {};
        return this.writableFields(objectName).filter((field) => field.value in fixed || !agentFields.has(field.value));
    }

    fixedFieldNames() {
        const names = new Set();
        this.settingOfType('fieldValues').forEach((setting) => {
            const value = this._values[setting.name];
            if (value && typeof value === 'object' && !Array.isArray(value)) {
                Object.keys(value).forEach((name) => names.add(name));
            }
        });
        return names;
    }

    settingOfType(type) {
        return this._settings.filter((setting) => this.controlType(setting) === type);
    }

    /** The rows being edited, or the saved value as rows. */
    keyValueRows(setting, value) {
        if (this.keyValueDrafts[setting.name]) {
            return this.keyValueDrafts[setting.name];
        }
        const entries = value && typeof value === 'object' && !Array.isArray(value) ? Object.entries(value) : [];
        return entries.map(([name, entry], index) => ({ key: `${setting.name}-${index}`, name, value: String(entry) }));
    }

    draftRows(name) {
        const setting = this._settings.find((candidate) => candidate.name === name);
        return this.keyValueDrafts[name] || this.keyValueRows(setting || { name }, this._values[name]);
    }

    recordKindOptions(setting) {
        const options = [];
        if (!setting.required) {
            options.push({ label: setting.blankMeaning || 'None', value: '' });
        }
        (setting.recordObjects || []).forEach((option) => options.push({ label: `A ${option.label.toLowerCase()}`, value: option.value }));
        options.push({ label: 'Another record, by Id', value: OTHER_RECORD });
        return options;
    }

    recordKindOf(setting, id) {
        if (this.recordKinds[setting.name] !== undefined) {
            return this.recordKinds[setting.name];
        }
        if (!id) {
            return setting.required && (setting.recordObjects || []).length ? setting.recordObjects[0].value : '';
        }
        const owner = (setting.recordObjects || []).find((option) => option.meta && id.startsWith(option.meta));
        return owner ? owner.value : OTHER_RECORD;
    }

    // ===== LOADING =====

    loadLists() {
        const types = new Set(this._settings.map((setting) => this.controlType(setting)));
        this.loadOnce(types.has('flow'), 'flows', async () => {
            this.flowOptions = ((await searchFlows({ term: '' })) || []).map((flow) => ({ label: flow.label, value: flow.value }));
        });
        this.loadOnce(types.has('queue'), 'queues', async () => {
            this.queueOptions = ((await getQueueOptions()) || []).map((queue) => ({ label: queue.label, value: queue.value }));
        });
        this.loadOnce(types.has('namedCredential'), 'namedCredentials', async () => {
            this.namedCredentialOptions = ((await getNamedCredentialOptions()) || []).map((credential) => ({
                label: credential.label,
                value: credential.value
            }));
        });
    }

    async loadOnce(needed, name, load) {
        if (!needed || this._loaded.has(name)) {
            return;
        }
        this._loaded.add(name);
        try {
            await load();
        } catch (error) {
            this._loaded.delete(name);
        }
    }

    async loadObjectData() {
        const objects = new Set();
        this._settings.forEach((setting) => {
            const name = this.objectFor(setting);
            if (name) {
                objects.add(name);
            }
        });
        const wantsRecordTypes = this._settings.some((setting) => setting.type === 'recordType');
        for (const objectName of objects) {
            if (!this.fieldsByObject[objectName]) {
                this.fieldsByObject = { ...this.fieldsByObject, [objectName]: [] };
                try {
                    const fields = (await getFieldOptions({ objectApiName: objectName })) || [];
                    this.fieldsByObject = { ...this.fieldsByObject, [objectName]: fields };
                } catch (error) {
                    this.fieldsByObject = { ...this.fieldsByObject, [objectName]: [] };
                }
            }
            if (wantsRecordTypes && !this.recordTypesByObject[objectName]) {
                this.recordTypesByObject = { ...this.recordTypesByObject, [objectName]: [] };
                try {
                    const types = (await getRecordTypeOptions({ objectApiName: objectName })) || [];
                    this.recordTypesByObject = { ...this.recordTypesByObject, [objectName]: types.map((type) => ({ label: type.label, value: type.value })) };
                } catch (error) {
                    this.recordTypesByObject = { ...this.recordTypesByObject, [objectName]: [] };
                }
            }
        }
    }

    // ===== CHANGES =====

    async handleObjectSearch(event) {
        const lookup = event.target;
        const term = event.detail.searchTerm;
        if (!term || term.length < 2) {
            lookup.setOptions?.([]);
            return;
        }
        try {
            const options = await searchStandardTargetSObjects({ term, operation: this.toolType });
            lookup.setOptions?.(
                (options || []).map((option) => ({
                    label: option.label,
                    value: option.value,
                    subtitle: option.value,
                    icon: option.iconName || 'standard:default'
                }))
            );
        } catch (error) {
            lookup.setOptions?.([]);
        }
    }

    async handleReportSearch(event) {
        const lookup = event.target;
        const term = event.detail.searchTerm;
        if (!term || term.length < 2) {
            lookup.setOptions?.([]);
            return;
        }
        try {
            const options = await searchReports({ term });
            lookup.setOptions?.(
                (options || []).map((option) => ({
                    label: option.label,
                    value: option.value,
                    subtitle: [option.value, option.meta].filter((part) => part).join(' • '),
                    icon: 'standard:report'
                }))
            );
        } catch (error) {
            lookup.setOptions?.([]);
        }
    }

    handleObjectChange(event) {
        const lookup = event.target;
        const name = lookup.dataset.name;
        const previous = this._values[name] || '';
        // The parent may ask first and decline; the lookup then goes back to the saved choice.
        this.change(name, event.detail.value || undefined, () => {
            lookup.value = previous;
        });
    }

    handleLookupChange(event) {
        this.change(event.target.dataset.name, event.detail.value || undefined);
    }

    handleFieldsChange(event) {
        this.change(event.target.dataset.name, [...event.detail.value]);
    }

    handleValueChange(event) {
        const value = event.detail.value;
        this.change(event.target.dataset.name, value === '' ? undefined : value);
    }

    handleNumberChange(event) {
        const value = event.detail.value;
        this.change(event.target.dataset.name, value === '' || value === null ? undefined : Number(value));
    }

    handleCheckboxChange(event) {
        this.change(event.target.dataset.name, event.detail.checked);
    }

    handleFieldValuesChange(event) {
        const value = event.detail.value;
        if (!value || typeof value !== 'object' || Array.isArray(value)) {
            return;
        }
        this.change(event.target.dataset.name, Object.keys(value).length ? value : undefined);
    }

    /** Sent as typed, so a space the admin just typed stays; Core ignores spaces around the query. */
    handleQueryChange(event) {
        const value = event.detail.value || '';
        this.change(event.target.dataset.name, value.trim() ? value : undefined);
    }

    handleTextListChange(event) {
        const values = (event.detail.value || '')
            .split('\n')
            .map((value) => value.trim())
            .filter((value) => value);
        this.change(event.target.dataset.name, values.length ? values : undefined);
    }

    handleKeyValueAdd(event) {
        const name = event.currentTarget.dataset.name;
        this.keyValueDrafts = { ...this.keyValueDrafts, [name]: [...this.draftRows(name), { key: `row-${++nextRow}`, name: '', value: '' }] };
    }

    handleKeyValueRemove(event) {
        const { name, key } = event.currentTarget.dataset;
        this.keyValueDrafts = { ...this.keyValueDrafts, [name]: this.draftRows(name).filter((row) => row.key !== key) };
        this.sendKeyValues(name);
    }

    handleKeyValueEdit(event) {
        const { name, key, part } = event.target.dataset;
        const text = event.detail.value || '';
        this.keyValueDrafts = {
            ...this.keyValueDrafts,
            [name]: this.draftRows(name).map((row) => (row.key === key ? { ...row, [part]: part === 'name' ? text.trim() : text } : row))
        };
        this.sendKeyValues(name);
    }

    /** Rows with a name become the setting; a row still being typed waits. */
    sendKeyValues(name) {
        const value = {};
        (this.keyValueDrafts[name] || []).forEach((row) => {
            if (row.name) {
                value[row.name] = row.value;
            }
        });
        this.change(name, Object.keys(value).length ? value : undefined);
    }

    handleRecordKindChange(event) {
        const name = event.target.dataset.name;
        this.recordKinds = { ...this.recordKinds, [name]: event.detail.value };
        // A new kind starts empty, so a user Id is never kept as a group.
        this.change(name, undefined);
    }

    handleRecordPick(event) {
        this.change(event.target.dataset.name, event.detail.recordId || undefined);
    }

    handleJsonChange(event) {
        const name = event.target.dataset.name;
        const text = event.detail.value;
        this.jsonDrafts = { ...this.jsonDrafts, [name]: text };
        if (!text.trim()) {
            this.jsonErrors = { ...this.jsonErrors, [name]: '' };
            this.change(name, undefined);
            return;
        }
        try {
            const parsed = JSON.parse(text);
            this.jsonErrors = { ...this.jsonErrors, [name]: '' };
            this.change(name, parsed);
        } catch (error) {
            this.jsonErrors = { ...this.jsonErrors, [name]: 'Enter valid JSON.' };
        }
    }

    handleUndeclaredChange(event) {
        const text = event.detail.value;
        this.jsonDrafts = { ...this.jsonDrafts, __all: text };
        if (!text.trim()) {
            this.jsonErrors = { ...this.jsonErrors, __all: '' };
            this.dispatchEvent(new CustomEvent('settingschange', { detail: { value: {} } }));
            return;
        }
        try {
            const parsed = JSON.parse(text);
            if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
                throw new Error('not an object');
            }
            this.jsonErrors = { ...this.jsonErrors, __all: '' };
            this.dispatchEvent(new CustomEvent('settingschange', { detail: { value: parsed } }));
        } catch (error) {
            this.jsonErrors = { ...this.jsonErrors, __all: 'Settings must be a JSON object, such as {"namedCredential": "Billing_API"}.' };
        }
    }

    change(name, value, revert) {
        this.dispatchEvent(new CustomEvent('settingchange', { detail: { name, value, revert } }));
    }
}
