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

import { LightningElement, api, wire } from 'lwc';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import { getLayout } from 'lightning/uiLayoutApi';
import { getRecord, updateRecord, createRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const LAYOUT_MODES = { new: 'Create', edit: 'Edit', view: 'View' };

/**
 * Returns options plus the stored value when it no longer resolves, so a
 * deleted class or credential renders honestly instead of blank.
 */
function withStaleFallback(loaded, value) {
    const options = [...loaded];
    if (value && !options.some((option) => option.value === value)) {
        options.push({ label: `${value} (unavailable)`, value });
    }
    return options;
}

/**
 * Splits a save or load failure into page-level messages and messages keyed
 * by field API name. Understands UI API errors (body.output), Apex errors
 * (body.message, body.pageErrors, body.fieldErrors), arrays, Error objects,
 * and strings. UI API puts only a generic wrapper in body.message, so it is
 * used only when nothing more specific is present.
 */
function reduceErrors(error) {
    const pageErrors = [];
    const fieldErrors = {};
    const addPage = (message) => {
        if (message && !pageErrors.includes(message)) {
            pageErrors.push(message);
        }
    };
    const addFields = (errorsByField) => {
        Object.keys(errorsByField || {}).forEach((fieldName) => {
            (errorsByField[fieldName] || []).forEach((fieldError) => {
                if (fieldError?.message) {
                    fieldErrors[fieldName] = [...(fieldErrors[fieldName] || []), fieldError.message];
                }
            });
        });
    };
    const collect = (item) => {
        if (!item) {
            return;
        }
        if (Array.isArray(item)) {
            item.forEach(collect);
            return;
        }
        if (typeof item === 'string') {
            addPage(item);
            return;
        }
        const body = item.body;
        if (Array.isArray(body)) {
            body.forEach(collect);
            return;
        }
        if (body) {
            const found = pageErrors.length + Object.keys(fieldErrors).length;
            (body.output?.errors || []).forEach((pageError) => addPage(pageError.message));
            addFields(body.output?.fieldErrors);
            (body.pageErrors || []).forEach((pageError) => addPage(pageError.message));
            addFields(body.fieldErrors);
            if (pageErrors.length + Object.keys(fieldErrors).length === found) {
                addPage(body.message);
            }
            return;
        }
        addPage(item.message);
    };
    collect(error);
    if (!pageErrors.length && !Object.keys(fieldErrors).length) {
        addPage('An unknown error occurred.');
    }
    return { pageErrors, fieldErrors };
}

function isBlank(value) {
    return value === null || value === undefined || value === '';
}

function isValueMatch(currentValue, controllingValue) {
    if (controllingValue === null || controllingValue === undefined) {
        return isBlank(currentValue);
    }
    if (isBlank(currentValue)) {
        return false;
    }
    if (Array.isArray(controllingValue)) {
        return controllingValue.includes(currentValue);
    }
    return currentValue === controllingValue;
}

/**
 * Record page for any object, laid out from the page layout assigned to the
 * user: the same sections, columns, and field order as a Lightning record
 * page. Standard fields render with lightning-input-field and
 * lightning-output-field; a host can give a field a Pluto renderer
 * (markdown, json, smartLookup) or caller-supplied options. Saves go
 * through UI API with only the changed fields, or to the host when
 * deferSave is set.
 *
 * The layout decides which fields show. A host hides fields it owns
 * elsewhere with hiddenFields, and adds fields that optional packages put
 * on the object with additionalFields: [{ fieldApiName, before }]. Fields
 * the user cannot see are left out.
 */
export default class PlutoRecordLayout extends LightningElement {
    @api recordId;
    @api objectApiName;
    @api fieldDependencies = [];
    @api requiredFields = [];
    @api hiddenFields = [];
    @api additionalFields = [];
    /**
     * Heading of the layout section the form-sections-after slot belongs to.
     * The section shows even with no fields, and collapsing it hides the
     * slot. It must be the last section, since the slot follows the form.
     */
    @api slotSection;
    @api fieldOptions = {};
    @api iconName = 'custom:custom64';
    @api deferSave = false;

    /** A Lightning record page shows the name and actions in its highlights panel. */
    @api hideHeader = false;
    /** 'page' (default) or 'modal'. In a modal the form has no card or section toggles, and Save sits at the right, as in standard edit modals. */
    @api variant = 'page';

    /**
     * Renderer and helpText overrides by field API name, e.g.
     * `{ Description__c: { renderer: 'markdown' } }`. Renderers: markdown,
     * json (with objectOnly), smartLookup.
     */
    @api customFieldRenderers = {};

    @api
    get defaultValues() {
        return this._defaultValues;
    }
    set defaultValues(value) {
        this._defaultValues = value || {};
        this.applyNewRecordDefaults();
    }

    /**
     * The hosting page owns navigation and passes 'view', 'edit', or 'new'.
     * Leaving edit discards unsaved values.
     */
    @api
    get mode() {
        return this._mode;
    }
    set mode(value) {
        this._mode = value;
        this.pageErrors = [];
        this.errorFields = [];
        this.isSaveErrorOpen = false;
        this.fieldErrors = {};
        if (this.isReadOnly) {
            this.dirtyFields = new Set();
            this.applyRecordValues();
        }
        this.enforceFixedValues();
    }

    saving = false;
    loadError;
    pageErrors = [];
    errorFields = [];
    isSaveErrorOpen = false;
    saveErrorLocation = 'footer';
    values = {};
    fieldErrors = {};
    dirtyFields = new Set();
    collapsedSections = new Set();

    _mode = 'view';
    _defaultValues = {};
    _objectInfo;
    _layout;
    _recordData;
    _validityPending = false;
    _revalidateFields = new Set();
    _focusErrorSummary = false;

    // ===== WIRES =====

    @wire(getObjectInfo, { objectApiName: '$objectApiName' })
    wiredObjectInfo({ error, data }) {
        if (data) {
            this._objectInfo = data;
            this.applyNewRecordDefaults();
        } else if (error) {
            this.handleLoadError(error);
        }
    }

    @wire(getLayout, { objectApiName: '$objectApiName', layoutType: 'Full', mode: '$layoutMode', recordTypeId: '$layoutRecordTypeId' })
    wiredLayout({ error, data }) {
        if (data) {
            this._layout = data;
            this.enforceFixedValues();
        } else if (error) {
            this.handleLoadError(error);
        }
    }

    @wire(getRecord, { recordId: '$recordId', layoutTypes: ['Full'], modes: ['View'], optionalFields: '$optionalFields' })
    wiredRecord({ error, data }) {
        if (data) {
            this._recordData = data;
            this.applyRecordValues();
            this.enforceFixedValues();
        } else if (error && this.recordId) {
            this.handleLoadError(error);
        }
    }

    get layoutMode() {
        return LAYOUT_MODES[this.effectiveActionName] || 'View';
    }

    get layoutRecordTypeId() {
        return this._recordData?.recordTypeId || this._objectInfo?.defaultRecordTypeId;
    }

    /** Fields the form reads that a layout may not carry. */
    get optionalFields() {
        if (!this.objectApiName) {
            return undefined;
        }
        const names = new Set([
            ...(this.additionalFields || []).map((entry) => entry.fieldApiName),
            ...(this.hiddenFields || []),
            ...(this.requiredFields || []),
            ...(this.fieldDependencies || []).flatMap((rule) => [rule.controllingField, ...Object.keys(rule.fixedValues || {})])
        ]);
        return [...names].filter(Boolean).map((fieldName) => `${this.objectApiName}.${fieldName}`);
    }

    // ===== LIFECYCLE =====

    connectedCallback() {
        if (!this.objectApiName) {
            this.handleLoadError('objectApiName is required for c-pluto-record-layout.');
        }
    }

    renderedCallback() {
        if (this._focusField && !this.isReadOnly) {
            const input = this.fieldInputs().find((element) => element.dataset.field === this._focusField);
            if (input) {
                this._focusField = null;
                input.focus?.();
            }
        }
        if (this.isModal && !this._modalFocused && !this.isReadOnly) {
            const first = this.fieldInputs().find((element) => !element.disabled);
            if (first) {
                this._modalFocused = true;
                first.focus?.();
            }
        }
        // Custom validity can only be set on rendered inputs, so server field
        // errors are pushed to the inputs that support it after rendering.
        if (this._validityPending) {
            this._validityPending = false;
            this.fieldInputs().forEach((input) => {
                if (typeof input.setCustomValidity !== 'function') {
                    return;
                }
                const fieldName = input.dataset.field;
                const message = this.fieldErrors[fieldName] || '';
                input.setCustomValidity(message);
                if (message || this._revalidateFields.has(fieldName)) {
                    input.reportValidity?.();
                }
            });
            this._revalidateFields.clear();
        }
        if (this._focusErrorSummary) {
            const popover = this.template.querySelector('c-pluto-save-error-popover');
            if (popover) {
                this._focusErrorSummary = false;
                popover.scrollIntoView?.({ block: 'nearest' });
                popover.focusPopover();
            }
        }
    }

    // ===== VALUES =====

    applyRecordValues() {
        const fields = this._recordData?.fields;
        if (!fields) {
            return;
        }
        const next = { ...this.values };
        Object.keys(fields).forEach((fieldName) => {
            // Metadata and the record can re-emit mid-edit; keep what the admin typed.
            if (!this.dirtyFields.has(fieldName)) {
                next[fieldName] = fields[fieldName].value;
            }
        });
        this.values = next;
    }

    applyNewRecordDefaults() {
        if (this.effectiveActionName !== 'new' || !this._objectInfo) {
            return;
        }
        const next = { ...this.values };
        Object.keys(this._objectInfo.fields).forEach((fieldName) => {
            if (this.dirtyFields.has(fieldName)) {
                return;
            }
            const field = this._objectInfo.fields[fieldName];
            if (this._defaultValues[fieldName] !== undefined) {
                next[fieldName] = this._defaultValues[fieldName];
            } else if (field.defaultValue !== null && field.defaultValue !== undefined) {
                next[fieldName] = field.defaultValue;
            } else {
                next[fieldName] = field.dataType === 'Boolean' ? false : null;
            }
        });
        this.values = next;
        this.enforceFixedValues();
    }

    updateFieldValue(fieldName, value) {
        this.dirtyFields = new Set([...this.dirtyFields, fieldName]);
        this.values = { ...this.values, [fieldName]: value };
        if (this.fieldErrors[fieldName]) {
            const { [fieldName]: cleared, ...rest } = this.fieldErrors;
            this.fieldErrors = rest;
            this._revalidateFields.add(fieldName);
            this._validityPending = true;
        }
        if (this.errorFields.some((errorField) => errorField.fieldApiName === fieldName)) {
            this.errorFields = this.errorFields.filter((errorField) => errorField.fieldApiName !== fieldName);
        }
    }

    // ===== LAYOUT MODEL =====

    /**
     * Visibility, required state, and locked values from the host's rules
     * and the current values. A field shown by any rule stays hidden until
     * one of its rules matches; required wins over optional.
     */
    evaluateRules() {
        const hidden = new Set(this.hiddenFields || []);
        const dependent = new Set();
        const shown = new Set();
        const hiddenByRule = new Set();
        const required = new Set();
        const optional = new Set();
        const fixed = new Map();
        (this.fieldDependencies || []).forEach((rule) => {
            (rule.showFields || []).forEach((fieldName) => dependent.add(fieldName));
            if (!isValueMatch(this.values[rule.controllingField], rule.controllingValue)) {
                return;
            }
            (rule.showFields || []).forEach((fieldName) => shown.add(fieldName));
            (rule.hideFields || []).forEach((fieldName) => hiddenByRule.add(fieldName));
            (rule.requiredFields || []).forEach((fieldName) => required.add(fieldName));
            (rule.optionalFields || []).forEach((fieldName) => optional.add(fieldName));
            Object.entries(rule.fixedValues || {}).forEach(([fieldName, value]) => fixed.set(fieldName, value));
        });
        const isVisible = (fieldName) => !hidden.has(fieldName) && !hiddenByRule.has(fieldName) && (!dependent.has(fieldName) || shown.has(fieldName));
        return { isVisible, required, optional, fixed };
    }

    /** Layout sections as [{ label, showHeading, columns: [[layoutItem]] }] with additional fields placed. */
    layoutSections() {
        const fields = this._objectInfo?.fields;
        if (!fields || !this._layout) {
            return [];
        }
        const placed = new Set();
        const sections = (this._layout.sections || []).map((section, sectionIndex) => {
            const columnCount = Math.max(1, section.columns || 1);
            const columns = Array.from({ length: columnCount }, () => []);
            (section.layoutRows || []).forEach((row) => {
                (row.layoutItems || []).forEach((layoutItem, columnIndex) => {
                    const component = (layoutItem.layoutComponents || []).find((candidate) => candidate.componentType === 'Field');
                    const fieldName = component?.apiName;
                    if (!fieldName || !fields[fieldName] || placed.has(fieldName)) {
                        return;
                    }
                    placed.add(fieldName);
                    columns[Math.min(columnIndex, columnCount - 1)].push({ fieldName, layoutItem });
                });
            });
            return {
                key: section.id || `section-${sectionIndex}`,
                label: section.heading || '',
                showHeading: section.useHeading !== false && !!section.heading,
                collapsible: section.collapsible !== false,
                columns
            };
        });
        (this.additionalFields || []).forEach(({ fieldApiName, before }) => {
            if (!fields[fieldApiName] || placed.has(fieldApiName) || !sections.length) {
                return;
            }
            placed.add(fieldApiName);
            const entry = { fieldName: fieldApiName, layoutItem: {} };
            for (const section of sections) {
                for (const column of section.columns) {
                    const index = column.findIndex((item) => item.fieldName === before);
                    if (index >= 0) {
                        column.splice(index, 0, entry);
                        return;
                    }
                }
            }
            const last = sections[sections.length - 1].columns;
            last[last.length - 1].push(entry);
        });
        return sections;
    }

    buildItem(fieldName, layoutItem, rules) {
        const field = this._objectInfo.fields[fieldName];
        const action = this.effectiveActionName;
        const editable =
            action === 'new' ? field.createable && layoutItem.editableForNew !== false : field.updateable && layoutItem.editableForUpdate !== false;
        const readOnly = action === 'view' || !editable;
        const isCheckbox = field.dataType === 'Boolean';
        const baseRequired = (!isCheckbox && (field.required || layoutItem.required === true)) || (this.requiredFields || []).includes(fieldName);
        const isRequired = rules.required.has(fieldName) || (!rules.optional.has(fieldName) && baseRequired);
        const isLocked = !readOnly && rules.fixed.has(fieldName);
        const renderer = this.customFieldRenderers?.[fieldName] || {};
        const callerOptions = this.fieldOptions?.[fieldName] || [];
        const value = this.values[fieldName];
        const kind =
            renderer.renderer === 'markdown' || renderer.renderer === 'json' || renderer.renderer === 'smartLookup'
                ? renderer.renderer
                : callerOptions.length
                  ? 'options'
                  : 'field';
        const options = kind === 'options' ? withStaleFallback(callerOptions, value) : callerOptions;
        const helpText = renderer.helpText ?? field.inlineHelpText ?? '';
        const errorMessage = this.fieldErrors[fieldName] || '';
        const selected = options.find((option) => option.value === value);
        const isInputField = !readOnly && kind === 'field';
        // lightning-input-field draws its own label and metadata help, even with
        // variant label-hidden, so Pluto draws the label only for a host help
        // override on a field with no metadata help.
        const drawsOwnLabel = isInputField && !(renderer.helpText && !field.inlineHelpText);
        let elementClass;
        if (action === 'view') {
            elementClass = 'slds-form-element slds-form-element_edit slds-form-element_readonly slds-hint-parent record-field record-field_view';
        } else if (readOnly) {
            elementClass = 'slds-form-element slds-form-element_readonly record-field record-field_locked';
        } else if (drawsOwnLabel) {
            elementClass = `record-field${errorMessage ? ' slds-has-error' : ''}`;
        } else {
            elementClass = `slds-form-element slds-form-element_stacked record-field${errorMessage ? ' slds-has-error' : ''}`;
        }
        return {
            key: fieldName,
            fieldApiName: fieldName,
            label: field.label,
            helpText,
            hasHelpText: !!helpText,
            isRequired: isRequired && !readOnly,
            readOnly,
            isLocked,
            isDisabled: readOnly || isLocked,
            value,
            displayValue: selected ? selected.label : (value ?? ''),
            options,
            jsonObjectOnly: renderer.objectOnly === true,
            maxLength: field.length,
            errorMessage,
            showErrorText: !!errorMessage && !readOnly && (kind === 'field' || kind === 'markdown'),
            canInlineEdit: action === 'view' && !!this.recordId && field.updateable && layoutItem.editableForUpdate !== false,
            editLabel: `Edit ${field.label}`,
            // Edit renderers
            isInputField,
            showLabel: !drawsOwnLabel,
            // Stacked, as on standard edit forms: a checkbox label sits above the box.
            inputFieldVariant: drawsOwnLabel ? 'label-stacked' : 'label-hidden',
            isOptionsInput: !readOnly && kind === 'options',
            isSmartLookupInput: !readOnly && kind === 'smartLookup',
            isMarkdownInput: !readOnly && kind === 'markdown',
            isJsonInput: !readOnly && kind === 'json',
            // Read-only renderers
            isOutputField: readOnly && kind === 'field',
            isTextOutput: readOnly && (kind === 'options' || kind === 'smartLookup'),
            isMarkdownOutput: readOnly && kind === 'markdown',
            isJsonOutput: readOnly && kind === 'json',
            elementClass
        };
    }

    /**
     * The rendered model: visible sections, each as rows of cells, as on
     * standard record pages, so the fields in a row share one height and
     * their underlines line up. Hidden fields close up their column first, so
     * a rule never leaves a gap in the middle of a column.
     */
    get sections() {
        if (!this._objectInfo || !this._layout) {
            return [];
        }
        const rules = this.evaluateRules();
        const isNew = this.effectiveActionName === 'new';
        const inModal = this.isModal;
        return this.layoutSections()
            .map((section) => {
                const columns = section.columns
                    .map((column) =>
                        column
                            .filter(({ fieldName }) => rules.isVisible(fieldName))
                            .map(({ fieldName, layoutItem }) => this.buildItem(fieldName, layoutItem, rules))
                            // A new record has nothing to show in a read-only field.
                            .filter((item) => !(isNew && item.readOnly))
                    )
                    .filter((items) => items.length);
                const width = columns.length;
                const cellClass = `slds-form__item slds-no-space slds-size_1-of-1${width > 1 ? ` slds-medium-size_1-of-${width}` : ''} record-form-item`;
                const rowCount = Math.max(0, ...columns.map((items) => items.length));
                const rows = Array.from({ length: rowCount }, (unused, rowIndex) => ({
                    key: `${section.key}-row-${rowIndex}`,
                    cells: columns.map((items, columnIndex) => {
                        const item = items[rowIndex];
                        return item
                            ? { ...item, cellKey: item.key, cellClass, isBlank: false, dataId: 'layout-item' }
                            : { cellKey: `${section.key}-blank-${rowIndex}-${columnIndex}`, cellClass, isBlank: true };
                    })
                }));
                const isOpen = !section.showHeading || inModal || !this.collapsedSections.has(section.key);
                return {
                    ...section,
                    rows,
                    items: columns.flat(),
                    showToggle: section.showHeading && !inModal,
                    showPlainHeading: section.showHeading && inModal,
                    isOpen,
                    contentId: `${section.key}-content`,
                    sectionClass: `slds-section${isOpen ? ' slds-is-open' : ''}`
                };
            })
            .filter((section) => section.rows.length || this.isSlotSection(section));
    }

    isSlotSection(section) {
        return !!this.slotSection && section.label === this.slotSection;
    }

    get slotClass() {
        const section = this.sections.find((candidate) => this.isSlotSection(candidate));
        return section && !section.isOpen ? 'slds-hide' : '';
    }

    /** Every item the user would see in this mode, in layout order. */
    visibleItems() {
        return this.sections.flatMap((section) => section.items);
    }

    /**
     * Sets and locks each visible, editable field that a matching rule fixes,
     * including a stored value the rule no longer allows. Hosts hear the
     * change as a normal fieldchange.
     */
    enforceFixedValues() {
        if (this.isReadOnly || !this._objectInfo || !this._layout) {
            return;
        }
        // Until the record loads, values are empty; setting one now would mark it dirty.
        if (this.effectiveActionName !== 'new' && !this._recordData) {
            return;
        }
        const rules = this.evaluateRules();
        if (!rules.fixed.size) {
            return;
        }
        this.visibleItems()
            .filter((item) => item.isLocked && item.value !== rules.fixed.get(item.fieldApiName))
            .forEach((item) => {
                const value = rules.fixed.get(item.fieldApiName);
                this.updateFieldValue(item.fieldApiName, value);
                this.dispatchFieldChangeEvent(item.fieldApiName, value);
            });
    }

    // ===== FIELD EVENTS =====

    handleInputFieldChange(event) {
        const fieldName = event.target.dataset.field;
        const dataType = this._objectInfo?.fields?.[fieldName]?.dataType;
        let value = event.detail && 'value' in event.detail ? event.detail.value : event.target.value;
        if (dataType === 'Boolean' && event.detail && 'checked' in event.detail) {
            value = event.detail.checked;
        }
        if (Array.isArray(value)) {
            value = dataType === 'Reference' ? (value[0] ?? null) : value.join(';');
        }
        this.changeValue(fieldName, value);
    }

    handleOptionsChange(event) {
        this.changeValue(event.target.dataset.field, event.detail?.value ?? event.target.value);
    }

    handleSmartLookupChange(event) {
        this.changeValue(event.target.dataset.field, event.detail?.value || null);
    }

    handleSmartLookupSearch(event) {
        this.dispatchEvent(
            new CustomEvent('fieldsearch', {
                detail: { fieldName: event.target.dataset.field, searchTerm: event.detail?.searchTerm || '' }
            })
        );
    }

    handleMarkdownChange(event) {
        const fieldName = event.target?.dataset?.field;
        if (fieldName) {
            this.changeValue(fieldName, event.detail?.value ?? '');
        }
    }

    handleJsonChange(event) {
        const fieldName = event.target?.dataset?.field;
        if (fieldName) {
            this.changeValue(fieldName, event.detail?.value ?? '');
        }
    }

    changeValue(fieldName, value) {
        this.updateFieldValue(fieldName, value);
        this.enforceFixedValues();
        this.dispatchFieldChangeEvent(fieldName, value);
    }

    dispatchFieldChangeEvent(fieldName, value) {
        this.dispatchEvent(
            new CustomEvent('fieldchange', {
                detail: { fieldName, value, allFieldValues: { ...this.values } }
            })
        );
    }

    handleToggleSection(event) {
        const key = event.currentTarget.dataset.section;
        const next = new Set(this.collapsedSections);
        if (next.has(key)) {
            next.delete(key);
        } else {
            next.add(key);
        }
        this.collapsedSections = next;
    }

    // ===== HEADER AND NAVIGATION =====

    handleEdit() {
        this.dispatchEvent(new CustomEvent('edit'));
    }

    /** The host switches to edit; the clicked field takes focus once its input renders. */
    handleInlineEdit(event) {
        const fieldApiName = event.currentTarget.dataset.field;
        this._focusField = fieldApiName;
        this.dispatchEvent(new CustomEvent('edit', { detail: { fieldApiName } }));
    }

    /** Return to the list. Composed so it crosses host boundaries. */
    handleBack() {
        this.dispatchEvent(new CustomEvent('back', { bubbles: true, composed: true }));
    }

    handleCancel() {
        this.dispatchEvent(new CustomEvent('cancel'));
    }

    // ===== SAVE =====

    /** Enter in an input submits lightning-record-edit-form; route it through the same save. */
    handleFormSubmit(event) {
        event.preventDefault();
        this.handleSave();
    }

    handleSave(event) {
        if (this.cannotSave) {
            return;
        }
        this.clearSaveErrors();
        this.saveErrorLocation = event?.currentTarget?.dataset?.location === 'header' ? 'header' : 'footer';
        if (!this.validateFields()) {
            return;
        }
        const recordInput = this.prepareRecordForSave();
        this.saving = true;
        if (this.deferSave) {
            this.dispatchEvent(new CustomEvent('saverequest', { detail: { recordInput } }));
            return;
        }
        // Nothing changed: leave edit mode the way a record page does,
        // without a request or a "saved" toast.
        if (this.effectiveActionName === 'edit' && Object.keys(recordInput.fields).length === 1) {
            this.handleSaveSuccess(this.recordId, false);
            return;
        }
        const request =
            this.effectiveActionName === 'new'
                ? createRecord({ ...recordInput, recordTypeId: this.layoutRecordTypeId }).then((result) => result.id)
                : updateRecord(recordInput).then(() => this.recordId);
        request.then((recordId) => this.handleSaveSuccess(recordId)).catch((error) => this.handleSaveError(error));
    }

    /**
     * Only fields the user may write: on create, every visible editable
     * field; on update, only what changed. A host can change or clear a field
     * the layout hides (an inactive dependent, or one it owns), and that
     * change is saved too.
     */
    prepareRecordForSave() {
        const objectFields = this._objectInfo.fields;
        const isNew = this.effectiveActionName === 'new';
        const writable = (fieldName) => {
            const field = objectFields[fieldName];
            return !!field && (isNew ? field.createable : field.updateable);
        };
        const normalize = (fieldName, value) => {
            const field = objectFields[fieldName];
            if (field.dataType === 'Boolean' && (value === null || value === undefined)) {
                return false;
            }
            return value === '' && (field.dataType === 'Picklist' || field.dataType === 'Reference' || this.fieldOptions?.[fieldName]?.length) ? null : value;
        };
        const fields = {};
        if (isNew) {
            this.visibleItems()
                .filter((item) => !item.readOnly)
                .forEach((item) => {
                    fields[item.fieldApiName] = normalize(item.fieldApiName, item.value);
                });
            // A hidden field is owned elsewhere; create it only with a value the host chose.
            (this.hiddenFields || [])
                .filter((fieldName) => writable(fieldName) && this._defaultValues[fieldName] !== undefined)
                .forEach((fieldName) => {
                    fields[fieldName] = normalize(fieldName, this.values[fieldName]);
                });
        }
        [...this.dirtyFields].filter(writable).forEach((fieldName) => {
            fields[fieldName] = normalize(fieldName, this.values[fieldName]);
        });
        return isNew ? { apiName: this.objectApiName, fields } : { fields: { ...fields, Id: this.recordId } };
    }

    handleSaveSuccess(recordId, changed = true) {
        this.saving = false;
        this.clearSaveErrors();
        // Saved values are now the record's; let the refreshed record,
        // including server-side changes, replace them.
        this.dirtyFields = new Set();
        if (changed) {
            const name = this.values[this.nameFieldApiName] || this.recordName;
            const subject = name ? `${this.objectLabel} "${name}"` : this.objectLabel;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: `${subject} was ${this.effectiveActionName === 'new' ? 'created' : 'saved'}.`,
                    variant: 'success'
                })
            );
        }
        this.dispatchEvent(new CustomEvent('save', { detail: { recordId, action: this.effectiveActionName } }));
    }

    @api
    completeSave(recordId) {
        this.handleSaveSuccess(recordId);
    }

    @api
    failSave(error) {
        this.handleSaveError(error);
    }

    /**
     * Shows a save failure the way a record page does: each field error on
     * its field, and a summary with the remaining messages and a link to
     * every field with an error. No toast.
     */
    handleSaveError(error) {
        this.saving = false;
        const { pageErrors, fieldErrors } = reduceErrors(error);
        const shown = new Set(
            this.visibleItems()
                .filter((item) => !item.readOnly)
                .map((item) => item.fieldApiName)
        );
        const unplacedErrors = [];
        const placed = {};
        Object.keys(fieldErrors).forEach((fieldName) => {
            if (shown.has(fieldName)) {
                placed[fieldName] = fieldErrors[fieldName].join(' ');
            } else {
                const label = this._objectInfo?.fields?.[fieldName]?.label || fieldName;
                fieldErrors[fieldName].forEach((message) => unplacedErrors.push(`${label}: ${message}`));
            }
        });
        this.fieldErrors = placed;
        this._validityPending = true;
        const ordered = this.visibleItems()
            .map((item) => item.fieldApiName)
            .filter((fieldName) => placed[fieldName]);
        this.showErrorSummary([...pageErrors, ...unplacedErrors], ordered);
    }

    showErrorSummary(pageErrors, fieldApiNames) {
        const labels = this._objectInfo?.fields || {};
        this.pageErrors = pageErrors.map((message, index) => ({ key: `page-error-${index}`, message }));
        this.errorFields = fieldApiNames.map((fieldApiName) => ({ fieldApiName, label: labels[fieldApiName]?.label || fieldApiName }));
        this.isSaveErrorOpen = this.hasErrorSummary;
        this._focusErrorSummary = this.hasErrorSummary;
    }

    clearSaveErrors() {
        this.pageErrors = [];
        this.errorFields = [];
        this.isSaveErrorOpen = false;
        if (Object.keys(this.fieldErrors).length) {
            this.fieldErrors = {};
            this._validityPending = true;
        }
    }

    /** Load failures replace the form with an inline message, like a record page that cannot load. */
    handleLoadError(error) {
        const { pageErrors, fieldErrors } = reduceErrors(error);
        this.loadError = [...pageErrors, ...Object.values(fieldErrors).flat()].join(' ');
    }

    handleSaveErrorToggle() {
        this.isSaveErrorOpen = !this.isSaveErrorOpen;
    }

    handleSaveErrorClose() {
        this.isSaveErrorOpen = false;
    }

    handleSaveErrorFieldSelect(event) {
        const target = this.fieldInputs().find((element) => element.dataset.field === event.detail.fieldApiName);
        target?.focus?.();
    }

    // ===== VALIDATION =====

    fieldInputs() {
        return [...this.template.querySelectorAll('.field-input')];
    }

    /**
     * Checks every editable field with its component's own validity
     * (required, format, and range), so messages match a record page. The
     * markdown editor has no validity API; it is checked for required only.
     */
    validateFields() {
        if (this.isReadOnly) {
            return true;
        }
        const invalid = new Set();
        const messages = {};
        this.fieldInputs().forEach((input) => {
            input.setCustomValidity?.('');
            if (input.reportValidity?.() === false) {
                invalid.add(input.dataset.field);
            }
        });
        this.visibleItems()
            .filter((item) => item.isMarkdownInput && item.isRequired && isBlank(item.value))
            .forEach((item) => {
                invalid.add(item.fieldApiName);
                messages[item.fieldApiName] = 'Complete this field.';
            });
        this.fieldErrors = messages;
        if (!invalid.size) {
            return true;
        }
        const ordered = this.visibleItems()
            .map((item) => item.fieldApiName)
            .filter((fieldName) => invalid.has(fieldName));
        this.showErrorSummary([], ordered);
        return false;
    }

    // ===== PUBLIC METHODS =====

    @api
    getFieldValue(fieldApiName) {
        return Object.prototype.hasOwnProperty.call(this.values, fieldApiName) ? this.values[fieldApiName] : '';
    }

    @api
    setFieldValue(fieldApiName, fieldValue) {
        this.updateFieldValue(fieldApiName, fieldValue);
    }

    @api
    validate() {
        return this.validateFields();
    }

    // ===== COMPUTED =====

    get effectiveActionName() {
        return this._mode ?? 'view';
    }

    get isReadOnly() {
        return this.effectiveActionName === 'view';
    }

    get isNewRecord() {
        return this.effectiveActionName === 'new';
    }

    get isEditRecord() {
        return this.effectiveActionName === 'edit';
    }

    get isReady() {
        return !!this._objectInfo && !!this._layout && (this.isNewRecord || !!this._recordData);
    }

    get showSpinner() {
        return !this.loadError && (this.saving || !this.isReady);
    }

    get cannotSave() {
        return this.saving || !!this.loadError || !this.isReady;
    }

    get hasLoadError() {
        return !!this.loadError;
    }

    get showSections() {
        return !this.loadError && this.isReady;
    }

    get nameFieldApiName() {
        const nameFields = this._objectInfo?.nameFields || [];
        return nameFields.includes('Name') || !nameFields.length ? 'Name' : nameFields[0];
    }

    get recordName() {
        return this._recordData?.fields?.[this.nameFieldApiName]?.value || '';
    }

    get headerTitle() {
        if (this.isNewRecord) {
            return `New ${this.objectLabel}`;
        }
        if (!this._recordData) {
            return '';
        }
        return this.isEditRecord ? `Edit ${this.recordName}` : this.recordName;
    }

    get isHeaderLoading() {
        return !this.isNewRecord && !this._recordData && !this.loadError;
    }

    get hasErrorSummary() {
        return this.pageErrors.length > 0 || this.errorFields.length > 0;
    }

    get showHeaderSaveErrors() {
        return this.hasErrorSummary && !this.isReadOnly && this.saveErrorLocation === 'header';
    }

    get showFooterSaveErrors() {
        return this.hasErrorSummary && !this.isReadOnly && this.saveErrorLocation === 'footer';
    }

    get objectLabel() {
        return this._objectInfo?.label || this.objectApiName || '';
    }

    get headerIconUrl() {
        return this._objectInfo?.themeInfo?.iconUrl ?? null;
    }

    get headerIconContainerClass() {
        const match = this.headerIconUrl?.match(/\/(standard|custom)\/([a-z0-9]+)_\d+\.png/i);
        const colorClass = match ? `slds-icon-${match[1].toLowerCase()}-${match[2].toLowerCase()}` : '';
        return `slds-icon_container ${colorClass}`.trim();
    }

    get isModal() {
        return this.variant === 'modal';
    }

    /** In a modal the modal is the card, so the form adds no card of its own. */
    get cardClass() {
        return this.isModal ? 'record-page-card record-page-card_modal' : 'slds-card record-page-card';
    }

    /** Editing on the page outlines the form, as standard inline edit does; a modal needs no outline. */
    get bodyClass() {
        return `slds-is-relative record-form-body${!this.isReadOnly && !this.isModal ? ' record-form-body_edit' : ''}`;
    }

    get footerClass() {
        return `record-docked-footer${this.isModal ? ' record-docked-footer_modal' : ''}`;
    }
}
