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

/**
 * What the model sees: one row per input Core builds, with the admin's
 * edits. An edit can only narrow: reword a description, make an optional
 * input required, keep some of the values an input offers, limit free text
 * to a list of values, or lower its length limit. Edits are
 * the inputOverrides setting, so this list is controlled: it gets the
 * current edits and sends the new ones in an overrideschange event.
 */
export default class ToolInputsList extends LightningElement {
    /** The rows Core returned for the draft. */
    @api inputs = [];
    @api readOnly = false;
    /** Problems by input path. */
    @api problemsByPath = {};

    _overrides = {};
    /** The path whose description or values are open for editing. */
    editingPath = null;
    editingKind = null;
    draftDescription = '';
    draftValues = [];
    draftValuesText = '';
    draftMaxLength = null;
    valuesError = '';

    /** The inputOverrides setting: an object of input path to edit. */
    @api
    get overrides() {
        return this._overrides;
    }

    set overrides(value) {
        this._overrides = value && typeof value === 'object' && !Array.isArray(value) ? value : {};
    }

    get hasInputs() {
        return (this.inputs || []).length > 0;
    }

    get rows() {
        return (this.inputs || []).map((input) => {
            const offered = input.offeredValues || [];
            const allowed = input.allowedValues || [];
            const isEditingDescription = this.editingPath === input.path && this.editingKind === 'description';
            const isEditingValues = this.editingPath === input.path && this.editingKind === 'values';
            const isEditingLength = this.editingPath === input.path && this.editingKind === 'length';
            const isEditing = this.editingPath === input.path;
            const isText = input.isText === true;
            const canEdit = !this.readOnly && input.editable !== false;
            const problems = (this.problemsByPath || {})[input.path] || [];
            return {
                ...input,
                rowClass: `input-row${input.hasChildren ? ' group-row' : ''}${input.leftOut ? ' left-out' : ''}`,
                isChild: (input.depth || 0) > 0,
                // Each level moves right by the width of one connector, so a child's connector sits under its parent's name.
                indentStyle: `padding-left: ${Math.max(0, Math.min(input.depth || 0, 5) - 1) * 1.25}rem`,
                valuesText: allowed.length && !isEditingValues ? this.valuesText(allowed, offered) : '',
                // Only a lowered limit needs saying; the tool's own is in the Type column.
                lengthText:
                    isText && !isEditingLength && input.maxLength && input.maxLength !== input.toolMaxLength ? `At most ${input.maxLength} characters` : '',
                // An open editor has its own Cancel and Done, so the row's other edits wait.
                showActions: canEdit && !isEditing,
                requiredDisabled: !canEdit || input.requiredByTool === true || input.hasChildren === true,
                canEditDescription: canEdit,
                canLimitValues: canEdit && (offered.length > 1 || isText),
                canLimitLength: canEdit && isText,
                canReset: canEdit && input.edited === true,
                isEditingDescription,
                isEditingValues,
                isEditingChoices: isEditingValues && !isText,
                isEditingFreeValues: isEditingValues && isText,
                isEditingLength,
                valueOptions: offered.map((value) => ({ label: value, value })),
                hasProblems: problems.length > 0,
                problems: problems.map((message, index) => ({ key: `${input.path}-${index}`, message }))
            };
        });
    }

    valuesText(allowed, offered) {
        const shown = allowed.slice(0, 10).join(', ') + (allowed.length > 10 ? ', ...' : '');
        return offered.length > allowed.length ? `${shown} (${allowed.length} of ${offered.length} values)` : shown;
    }

    handleRequiredChange(event) {
        const path = event.target.dataset.path;
        this.edit(path, { required: event.detail.checked ? true : undefined });
    }

    handleEditDescription(event) {
        const path = event.currentTarget.dataset.path;
        const input = this.inputOf(path);
        this.editingPath = path;
        this.editingKind = 'description';
        this.draftDescription = input?.description || '';
    }

    handleDescriptionDraft(event) {
        this.draftDescription = event.detail.value;
    }

    handleSaveDescription() {
        const input = this.inputOf(this.editingPath);
        const text = (this.draftDescription || '').trim();
        // The tool's own wording, or none, is no edit.
        this.edit(this.editingPath, { description: !text || text === input?.toolDescription ? undefined : text });
        this.closeEditor();
    }

    handleLimitValues(event) {
        const path = event.currentTarget.dataset.path;
        const input = this.inputOf(path);
        this.editingPath = path;
        this.editingKind = 'values';
        this.draftValues = [...(input?.allowedValues || input?.offeredValues || [])];
        this.draftValuesText = (input?.allowedValues || []).join('\n');
        this.valuesError = '';
    }

    handleLimitLength(event) {
        const path = event.currentTarget.dataset.path;
        this.editingPath = path;
        this.editingKind = 'length';
        this.draftMaxLength = this.inputOf(path)?.maxLength ?? null;
        this.valuesError = '';
    }

    handleValuesTextDraft(event) {
        this.draftValuesText = event.detail.value || '';
        this.valuesError = '';
    }

    handleLengthDraft(event) {
        this.draftMaxLength = event.detail.value === '' || event.detail.value === null ? null : Number(event.detail.value);
        this.valuesError = '';
    }

    /** Free text limited to the listed values; an empty list removes the limit. */
    handleSaveFreeValues() {
        const values = [
            ...new Set(
                this.draftValuesText
                    .split('\n')
                    .map((value) => value.trim())
                    .filter((value) => value)
            )
        ];
        this.edit(this.editingPath, { allowedValues: values.length ? values : undefined });
        this.closeEditor();
    }

    handleSaveLength() {
        const input = this.inputOf(this.editingPath);
        const limit = this.draftMaxLength;
        if (limit !== null && !(Number.isInteger(limit) && limit > 0)) {
            this.valuesError = 'Enter a whole number of at least 1.';
            return;
        }
        if (limit !== null && input?.toolMaxLength && limit > input.toolMaxLength) {
            this.valuesError = `The tool allows at most ${input.toolMaxLength} characters. Enter that or less.`;
            return;
        }
        // The tool's own limit, or none, is no edit.
        this.edit(this.editingPath, { maxLength: limit === null || limit === input?.toolMaxLength ? undefined : limit });
        this.closeEditor();
    }

    handleValuesDraft(event) {
        this.draftValues = event.detail.value;
        this.valuesError = '';
    }

    handleSaveValues() {
        const input = this.inputOf(this.editingPath);
        const offered = input?.offeredValues || [];
        if (!this.draftValues.length) {
            this.valuesError = 'Keep at least one value.';
            return;
        }
        // Keeping every value is no edit, so a value added to the field later is offered too.
        const keepsAll = offered.every((value) => this.draftValues.includes(value));
        this.edit(this.editingPath, { allowedValues: keepsAll ? undefined : offered.filter((value) => this.draftValues.includes(value)) });
        this.closeEditor();
    }

    handleCancelEdit() {
        this.closeEditor();
    }

    handleReset(event) {
        const path = event.currentTarget.dataset.path;
        const next = { ...this._overrides };
        delete next[path];
        this.publish(next);
    }

    closeEditor() {
        this.editingPath = null;
        this.editingKind = null;
        this.valuesError = '';
    }

    inputOf(path) {
        return (this.inputs || []).find((input) => input.path === path);
    }

    /** Sets or clears parts of one input's edit; an edit with nothing left is removed. */
    edit(path, changes) {
        const current = { ...(this._overrides[path] || {}) };
        Object.keys(changes).forEach((key) => {
            if (changes[key] === undefined) {
                delete current[key];
            } else {
                current[key] = changes[key];
            }
        });
        const next = { ...this._overrides };
        if (Object.keys(current).length) {
            next[path] = current;
        } else {
            delete next[path];
        }
        this.publish(next);
    }

    publish(next) {
        this._overrides = next;
        this.dispatchEvent(new CustomEvent('overrideschange', { detail: { value: next } }));
    }
}
