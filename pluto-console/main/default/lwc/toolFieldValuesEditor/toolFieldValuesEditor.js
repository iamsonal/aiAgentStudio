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
import { RUN_VALUES, DATE_UNITS, TIME_UNITS, parseRelative, relativeText } from 'c/toolRunValues';

const VALUE = 'value';
const OFFSET = 'offset';
const OFFSET_TIME = 'offsetTime';
const START = 'start';
const END = 'end';
const NUMBER_TYPES = new Set(['INTEGER', 'DOUBLE', 'CURRENCY', 'PERCENT']);
const NAMED = new Set(RUN_VALUES.map((option) => option.value));
const WHICH = [
    { value: 'this', label: 'This' },
    { value: 'next', label: 'Next' },
    { value: 'last', label: 'Last' }
];
const PERIODS = [
    { value: 'Week', label: 'Week' },
    { value: 'Month', label: 'Month' },
    { value: 'Quarter', label: 'Quarter' },
    { value: 'Year', label: 'Year' }
];
/** How far next and last move from this period, as Core's offset. */
const STEP = { Week: { amount: 1, unit: 'w' }, Month: { amount: 1, unit: 'm' }, Quarter: { amount: 3, unit: 'm' }, Year: { amount: 1, unit: 'y' } };

let nextKey = 0;

/**
 * Fixed Field Values: rows of a field and the value every record gets. The
 * agent cannot change these fields, so they are not inputs. Each row asks
 * what to set the field to: a value the admin enters with a control for the
 * field's type, or a value Pluto fills in on each call, such as the run's
 * record or the end of this month. Controlled: the parent passes value and
 * gets each change in a valueschange event. It is not named change, because
 * the change events of the base components inside cross its shadow boundary
 * and would reach the same handler.
 */
export default class ToolFieldValuesEditor extends LightningElement {
    @api label = 'Fixed Field Values';
    @api helpText = '';
    @api readOnly = false;
    /** The fields a row may choose, as getFieldOptions returns them. */
    @api fields = [];

    rows = [];
    _value = {};

    /** An object of field API name to value. */
    @api
    get value() {
        return this._value;
    }

    set value(next) {
        this._value = next && typeof next === 'object' && !Array.isArray(next) ? next : {};
        if (JSON.stringify(this.toValue(this.rows)) !== JSON.stringify(this._value)) {
            this.rows = Object.keys(this._value).map((field) => this.rowFor(field, this._value[field]));
        }
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get canAdd() {
        return !this.readOnly && this.rows.length < (this.fields || []).length;
    }

    get rowViews() {
        const byName = new Map((this.fields || []).map((field) => [field.value, field]));
        return this.rows.map((row) => {
            const field = byName.get(row.field);
            const type = field?.dataType || '';
            const choices = field ? this.choicesFor(field, row) : [];
            const mode = choices.some((choice) => choice.value === row.mode) ? row.mode : VALUE;
            const entering = !!field && mode === VALUE;
            const isPicklist = entering && field.isPicklist === true && type !== 'MULTIPICKLIST';
            const isRecordPicker = entering && type === 'REFERENCE' && field.referenceCount === 1;
            const input = entering && !isPicklist && !isRecordPicker && !['BOOLEAN', 'MULTIPICKLIST', 'TEXTAREA'].includes(type);
            return {
                ...row,
                mode,
                fieldOptions: this.fieldOptionsFor(row),
                hasChoices: choices.length > 1,
                choices,
                needsField: !field,
                isPicklist,
                picklistOptions: isPicklist ? this.picklistOptions(field) : [],
                isMultiPicklist: entering && type === 'MULTIPICKLIST',
                multiOptions: entering && type === 'MULTIPICKLIST' ? this.picklistOptions(field) : [],
                multiValue: typeof row.value === 'string' && row.value ? row.value.split(';') : [],
                isCheckbox: entering && type === 'BOOLEAN',
                checked: row.value === true || row.value === 'true',
                isTextArea: entering && type === 'TEXTAREA',
                isRecordPicker,
                referenceTo: field?.referenceTo || '',
                isInput: input,
                inputType: this.inputType(type),
                inputStep: type === 'INTEGER' ? '1' : 'any',
                inputLabel: type === 'REFERENCE' || type === 'ID' ? 'Record Id' : 'Value',
                textValue: row.value === null || row.value === undefined ? '' : String(row.value),
                waitsForValue: !!field && type !== 'BOOLEAN' && mode === VALUE && (row.value === undefined || row.value === null || row.value === ''),
                isOffset: !!field && (mode === OFFSET || mode === OFFSET_TIME),
                units: mode === OFFSET_TIME ? TIME_UNITS : DATE_UNITS,
                amountHelp: mode === OFFSET_TIME ? 'Use a minus sign for a time before now.' : 'Use a minus sign for a date before today.',
                isPeriod: !!field && (mode === START || mode === END),
                whichOptions: WHICH,
                periodOptions: PERIODS,
                summary: this.summaryOf(row, mode)
            };
        });
    }

    /**
     * What the field can be set to: a value the admin enters, then the run
     * values that fit its type. A saved value these choices cannot show, such
     * as :endOfMonth+2m, is kept as a choice of its own.
     */
    choicesFor(field, row) {
        const type = field.dataType;
        const saved = row.mode && row.mode.startsWith(':') && !NAMED.has(row.mode) ? [{ label: `Saved value ${row.mode}`, value: row.mode }] : [];
        if (type === 'DATE') {
            return [
                { label: 'A date you choose', value: VALUE },
                { label: 'Today', value: ':today' },
                { label: 'Days, weeks, months, or years from today', value: OFFSET },
                { label: 'The start of a week, month, quarter, or year', value: START },
                { label: 'The end of a week, month, quarter, or year', value: END },
                ...saved
            ];
        }
        if (type === 'DATETIME') {
            return [
                { label: 'A date and time you choose', value: VALUE },
                { label: 'Now', value: ':now' },
                { label: 'Hours or days from now', value: OFFSET_TIME },
                ...saved
            ];
        }
        if (type === 'REFERENCE' || type === 'ID') {
            const choices = [
                { label: 'A record you choose', value: VALUE },
                { label: "The run's record", value: ':anchorId' }
            ];
            if (field.pointsToUser) {
                choices.push({ label: 'The user who started the run', value: ':initiatingUserId' });
                choices.push({ label: 'The user the run acts as', value: ':principalUserId' });
            }
            return choices;
        }
        return [{ label: 'A value you choose', value: VALUE }];
    }

    /** Fields not already used by another row, plus this row's own. */
    fieldOptionsFor(row) {
        const used = new Set(this.rows.filter((other) => other.key !== row.key).map((other) => other.field));
        const options = (this.fields || [])
            .filter((field) => !used.has(field.value))
            .map((field) => ({ label: `${field.label} (${field.value})`, value: field.value }));
        if (row.field && !options.some((option) => option.value === row.field)) {
            options.push({ label: row.field, value: row.field });
        }
        return options;
    }

    picklistOptions(field) {
        return (field.picklistValues || []).map((entry) => ({ label: entry.label, value: entry.value }));
    }

    inputType(type) {
        if (NUMBER_TYPES.has(type)) {
            return 'number';
        }
        return { DATE: 'date', DATETIME: 'datetime', TIME: 'time', EMAIL: 'email', PHONE: 'tel', URL: 'url' }[type] || 'text';
    }

    /** Says in words what the date comes to, so the admin can check it. */
    summaryOf(row, mode) {
        if (mode === OFFSET || mode === OFFSET_TIME) {
            const amount = Math.trunc(Number(row.amount) || 0);
            const from = mode === OFFSET_TIME ? 'now' : 'today';
            if (!amount) {
                return `Pluto fills in ${from} on each call.`;
            }
            const unit = (mode === OFFSET_TIME ? TIME_UNITS : DATE_UNITS).find((option) => option.value === row.unit);
            const word = unit ? unit.label.toLowerCase() : '';
            const count = Math.abs(amount);
            return `Pluto fills in ${count} ${count === 1 ? word.replace(/s$/, '') : word} ${amount < 0 ? 'before' : 'from'} ${from} on each call.`;
        }
        if (mode === START || mode === END) {
            return `Pluto fills in the ${mode} of ${row.which || 'this'} ${(row.period || 'Month').toLowerCase()} on each call.`;
        }
        return '';
    }

    // ===== CHANGES =====

    handleAdd() {
        this.rows = [...this.rows, { key: `row-${nextKey++}`, field: '', mode: VALUE, value: '' }];
    }

    handleRemove(event) {
        const key = event.currentTarget.dataset.key;
        this.rows = this.rows.filter((row) => row.key !== key);
        this.notify();
    }

    handleFieldChange(event) {
        this.update(event.currentTarget.dataset.key, { field: event.detail.value, mode: VALUE, value: '' });
    }

    handleModeChange(event) {
        const mode = event.detail.value;
        if (mode === OFFSET || mode === OFFSET_TIME) {
            this.update(event.currentTarget.dataset.key, { mode, amount: 1, unit: mode === OFFSET_TIME ? 'h' : 'd' });
        } else if (mode === START || mode === END) {
            this.update(event.currentTarget.dataset.key, { mode, which: 'this', period: 'Month' });
        } else {
            this.update(event.currentTarget.dataset.key, { mode, value: mode === VALUE ? '' : mode });
        }
    }

    handleValueChange(event) {
        this.update(event.currentTarget.dataset.key, { value: event.detail.value });
    }

    handleMultiChange(event) {
        this.update(event.currentTarget.dataset.key, { value: (event.detail.value || []).join(';') });
    }

    handleCheckboxChange(event) {
        this.update(event.currentTarget.dataset.key, { value: event.detail.checked });
    }

    handleRecordPick(event) {
        this.update(event.currentTarget.dataset.key, { value: event.detail.recordId || '' });
    }

    handlePartChange(event) {
        const { key, part } = event.currentTarget.dataset;
        this.update(key, { [part]: event.detail.value });
    }

    update(key, changes) {
        this.rows = this.rows.map((row) => (row.key === key ? { ...row, ...changes } : row));
        this.notify();
    }

    notify() {
        this._value = this.toValue(this.rows);
        this.dispatchEvent(new CustomEvent('valueschange', { detail: { value: this._value } }));
    }

    // ===== VALUES =====

    rowFor(field, value) {
        const row = { key: `row-${nextKey++}`, field, mode: VALUE, value };
        if (typeof value !== 'string' || !value.trim().startsWith(':')) {
            return row;
        }
        const text = value.trim();
        const relative = NAMED.has(text) ? null : parseRelative(text);
        if (!relative) {
            return { ...row, mode: text };
        }
        if (!relative.period) {
            return { ...row, mode: relative.base === 'now' ? OFFSET_TIME : OFFSET, amount: relative.amount, unit: relative.unit };
        }
        const kind = relative.period.startsWith('start') ? START : END;
        const period = relative.period.replace(/^(start|end)Of/, '');
        const step = STEP[period];
        const which = !relative.amount
            ? 'this'
            : relative.unit === step.unit && Math.abs(relative.amount) === step.amount
              ? relative.amount > 0
                  ? 'next'
                  : 'last'
              : null;
        // A move this form does not offer, such as :endOfMonth+2m, stays as saved.
        return which ? { ...row, mode: kind, which, period } : { ...row, mode: text };
    }

    valueOf(row) {
        if (row.mode === OFFSET || row.mode === OFFSET_TIME) {
            return relativeText({ base: row.mode === OFFSET_TIME ? 'now' : 'today', amount: row.amount, unit: row.unit, period: '' });
        }
        if (row.mode === START || row.mode === END) {
            const period = row.period || 'Month';
            const step = STEP[period];
            const amount = row.which === 'next' ? step.amount : row.which === 'last' ? -step.amount : 0;
            return relativeText({ base: 'today', amount, unit: step.unit, period: `${row.mode}Of${period}` });
        }
        return row.mode === VALUE ? row.value : row.mode;
    }

    /**
     * Rows without a field or a value are still being filled in, so they are
     * not part of the value; otherwise Core would check an empty value
     * against the field's type before the admin has entered one.
     */
    toValue(rows) {
        const byName = new Map((this.fields || []).map((field) => [field.value, field]));
        const result = {};
        rows.forEach((row) => {
            if (!row.field) {
                return;
            }
            const value = this.valueOf(row);
            const type = byName.get(row.field)?.dataType;
            if (type !== 'BOOLEAN' && (value === undefined || value === null || value === '')) {
                return;
            }
            if (type === 'BOOLEAN') {
                result[row.field] = value === true || value === 'true';
            } else if (NUMBER_TYPES.has(type) && value !== '' && value !== null && !isNaN(Number(value))) {
                result[row.field] = Number(value);
            } else {
                result[row.field] = value === undefined || value === null ? '' : value;
            }
        });
        return result;
    }
}
