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

export const TYPES = [
    { value: 'text', label: 'Text' },
    { value: 'picklist', label: 'Picklist' },
    { value: 'integer', label: 'Whole number' },
    { value: 'number', label: 'Number' },
    { value: 'boolean', label: 'Checkbox' },
    { value: 'recordId', label: 'Record Id' },
    { value: 'date', label: 'Date' },
    { value: 'dateTime', label: 'Date and time' },
    { value: 'email', label: 'Email' },
    { value: 'group', label: 'Group' },
    { value: 'list', label: 'List' }
];
const ITEM_TYPES = TYPES.filter((type) => type.value !== 'list');
const FORMATS = { 'salesforce-id': 'recordId', date: 'date', 'date-time': 'dateTime', email: 'email' };
const KIND_FORMATS = { recordId: 'salesforce-id', date: 'date', dateTime: 'date-time', email: 'email' };
/** Keys the builder shows; any other key on an input is kept as it is. */
const SHOWN_KEYS = ['type', 'description', 'enum', 'format', 'maxLength', 'minimum', 'maximum', 'properties', 'required', 'additionalProperties', 'items'];
const NAME = /^[A-Za-z][A-Za-z0-9_]{0,63}$/;
const MAX_DEPTH = 3;
export const EMPTY_SCHEMA = '{"type":"object","properties":{},"additionalProperties":false}';

let nextId = 0;

/**
 * Builds a hand-written Input Schema one input at a time: a name, a type,
 * whether the model must send it, a description, and the type's limits.
 * A Group holds inputs of its own; a List holds values of one type.
 * Controlled: it gets the schema as JSON in value and sends each change
 * in a schemachange event, not change, because the change events of the
 * base components inside cross its shadow boundary. Keys it does not show
 * are kept on save.
 */
export default class ToolInputsBuilder extends LightningElement {
    @api readOnly = false;

    inputs = [];
    unreadable = false;
    _value = '';
    _lastSent;
    showErrors = false;

    @api
    get value() {
        return this._value;
    }

    set value(next) {
        this._value = next || '';
        // The schema this component just sent comes back from the parent; keep the open draft.
        if (this._value === this._lastSent) {
            return;
        }
        this.inputs = this.parse(this._value);
    }

    /** Shows each input's errors; true when the schema can be saved. */
    @api
    reportValidity() {
        this.showErrors = true;
        return this.errorsByInput().size === 0 && !this.unreadable;
    }

    // ===== VIEW =====

    get typeOptions() {
        return TYPES;
    }

    get itemTypeOptions() {
        return ITEM_TYPES;
    }

    get hasInputs() {
        return this.inputs.length > 0;
    }

    get rows() {
        const errors = this.showErrors ? this.errorsByInput() : new Map();
        const rows = [];
        const walk = (list, depth) => {
            list.forEach((input, index) => {
                const kind = input.kind === 'list' ? input.itemKind : input.kind;
                const holdsInputs = kind === 'group';
                const inputErrors = errors.get(input.id) || [];
                rows.push({
                    ...input,
                    depth,
                    rowClass: `input-card slds-box slds-box_x-small slds-m-bottom_x-small depth-${depth}`,
                    isList: input.kind === 'list',
                    isText: kind === 'text',
                    isPicklist: kind === 'picklist',
                    isNumeric: kind === 'integer' || kind === 'number',
                    isGroup: holdsInputs,
                    canAddInside: holdsInputs && depth + 1 < MAX_DEPTH && !this.readOnly,
                    moveUpDisabled: index === 0,
                    moveDownDisabled: index === list.length - 1,
                    valuesText: (input.values || []).join('\n'),
                    hasErrors: inputErrors.length > 0,
                    errors: inputErrors.map((message, position) => ({ key: `${input.id}-${position}`, message })),
                    nameLabel: depth ? 'Name in the group' : 'Name'
                });
                if (holdsInputs) {
                    walk(input.children, depth + 1);
                }
            });
        };
        walk(this.inputs, 0);
        return rows;
    }

    // ===== CHANGES =====

    handleAdd() {
        this.inputs = [...this.inputs, this.newInput()];
        this.send();
    }

    handleAddInside(event) {
        const id = event.currentTarget.dataset.id;
        this.update(id, (input) => ({ ...input, children: [...input.children, this.newInput()] }));
    }

    handleRemove(event) {
        const id = event.currentTarget.dataset.id;
        const remove = (list) => list.filter((input) => input.id !== id).map((input) => ({ ...input, children: remove(input.children) }));
        this.inputs = remove(this.inputs);
        this.send();
    }

    handleMove(event) {
        const { id, direction } = event.currentTarget.dataset;
        const step = direction === 'up' ? -1 : 1;
        const move = (list) => {
            const index = list.findIndex((input) => input.id === id);
            if (index === -1) {
                return list.map((input) => ({ ...input, children: move(input.children) }));
            }
            const next = [...list];
            [next[index], next[index + step]] = [next[index + step], next[index]];
            return next;
        };
        this.inputs = move(this.inputs);
        this.send();
    }

    handleNameChange(event) {
        this.set(event.target.dataset.id, { name: (event.detail.value || '').trim() });
    }

    handleTypeChange(event) {
        const kind = event.detail.value;
        this.update(event.target.dataset.id, (input) => ({
            ...input,
            kind,
            itemKind: kind === 'list' ? input.itemKind || 'text' : input.itemKind,
            children: kind === 'group' || (kind === 'list' && input.itemKind === 'group') ? input.children : []
        }));
    }

    handleItemTypeChange(event) {
        const itemKind = event.detail.value;
        this.update(event.target.dataset.id, (input) => ({ ...input, itemKind, children: itemKind === 'group' ? input.children : [] }));
    }

    handleRequiredChange(event) {
        this.set(event.target.dataset.id, { required: event.detail.checked });
    }

    handleDescriptionChange(event) {
        this.set(event.target.dataset.id, { description: event.detail.value || '' });
    }

    handleValuesChange(event) {
        const values = (event.detail.value || '')
            .split('\n')
            .map((value) => value.trim())
            .filter((value) => value);
        this.set(event.target.dataset.id, { values });
    }

    handleNumberChange(event) {
        const raw = event.detail.value;
        const number = raw === '' || raw === null || raw === undefined ? null : Number(raw);
        this.set(event.target.dataset.id, { [event.target.dataset.field]: Number.isFinite(number) ? number : null });
    }

    set(id, changes) {
        this.update(id, (input) => ({ ...input, ...changes }));
    }

    update(id, change) {
        const apply = (list) => list.map((input) => (input.id === id ? change(input) : { ...input, children: apply(input.children) }));
        this.inputs = apply(this.inputs);
        this.send();
    }

    send() {
        this.unreadable = false;
        this._lastSent = this.serialize(this.inputs);
        this._value = this._lastSent;
        this.dispatchEvent(new CustomEvent('schemachange', { detail: { value: this._lastSent, valid: this.errorsByInput().size === 0 } }));
    }

    newInput() {
        nextId += 1;
        return {
            id: `input-${nextId}`,
            name: '',
            kind: 'text',
            itemKind: 'text',
            required: true,
            description: '',
            values: [],
            children: [],
            extra: {},
            itemExtra: {}
        };
    }

    // ===== CHECKS =====

    /** Each input's problems, by input id. */
    errorsByInput() {
        const errors = new Map();
        const check = (list) => {
            const seen = new Set();
            list.forEach((input) => {
                const found = [];
                const kind = input.kind === 'list' ? input.itemKind : input.kind;
                if (!input.name) {
                    found.push('Enter a name.');
                } else if (!NAME.test(input.name)) {
                    found.push('Start the name with a letter and use only letters, digits, and underscores.');
                } else if (seen.has(input.name.toLowerCase())) {
                    found.push(`Another input here is also named ${input.name}.`);
                }
                seen.add((input.name || '').toLowerCase());
                if (!input.description.trim()) {
                    found.push('Describe what the model should send.');
                }
                if (kind === 'picklist' && !(input.values || []).length) {
                    found.push('List at least one value.');
                }
                if (kind === 'group' && !input.children.length) {
                    found.push('Add at least one input to the group.');
                }
                if (
                    input.minimum !== null &&
                    input.minimum !== undefined &&
                    input.maximum !== null &&
                    input.maximum !== undefined &&
                    input.minimum > input.maximum
                ) {
                    found.push('The minimum is more than the maximum.');
                }
                if (input.maxLength !== null && input.maxLength !== undefined && !(Number.isInteger(input.maxLength) && input.maxLength > 0)) {
                    found.push('Max length must be a whole number of at least 1.');
                }
                if (found.length) {
                    errors.set(input.id, found);
                }
                check(input.children);
            });
        };
        check(this.inputs);
        return errors;
    }

    // ===== JSON =====

    parse(json) {
        if (!json) {
            return [];
        }
        try {
            const schema = JSON.parse(json);
            this.unreadable = !schema || schema.type !== 'object';
            return this.unreadable ? [] : this.readProperties(schema);
        } catch (error) {
            this.unreadable = true;
            return [];
        }
    }

    readProperties(objectSchema) {
        const properties = objectSchema.properties && typeof objectSchema.properties === 'object' ? objectSchema.properties : {};
        const required = new Set(Array.isArray(objectSchema.required) ? objectSchema.required : []);
        return Object.keys(properties).map((name) => this.readInput(name, properties[name] || {}, required.has(name)));
    }

    readInput(name, node, required) {
        nextId += 1;
        const isList = node.type === 'array';
        const values = isList && node.items && typeof node.items === 'object' ? node.items : node;
        const kind = this.kindOf(values);
        return {
            id: `input-${nextId}`,
            name,
            kind: isList ? 'list' : kind,
            itemKind: isList ? kind : 'text',
            required,
            description: node.description || '',
            values: Array.isArray(values.enum) ? values.enum.map(String) : [],
            maxLength: Number.isInteger(values.maxLength) ? values.maxLength : null,
            minimum: typeof values.minimum === 'number' ? values.minimum : null,
            maximum: typeof values.maximum === 'number' ? values.maximum : null,
            children: kind === 'group' ? this.readProperties(values) : [],
            extra: this.extraKeys(node),
            itemExtra: isList ? this.extraKeys(values) : {}
        };
    }

    kindOf(node) {
        if (node.type === 'object') {
            return 'group';
        }
        if (node.type === 'string') {
            if (Array.isArray(node.enum)) {
                return 'picklist';
            }
            return FORMATS[node.format] || 'text';
        }
        return ['integer', 'number', 'boolean'].includes(node.type) ? node.type : 'text';
    }

    extraKeys(node) {
        const extra = {};
        Object.keys(node || {}).forEach((key) => {
            if (!SHOWN_KEYS.includes(key)) {
                extra[key] = node[key];
            }
        });
        return extra;
    }

    serialize(inputs) {
        return JSON.stringify(this.objectSchema(inputs));
    }

    objectSchema(inputs) {
        const properties = {};
        const required = [];
        inputs.forEach((input) => {
            if (!input.name) {
                return;
            }
            properties[input.name] = this.inputSchema(input);
            if (input.required) {
                required.push(input.name);
            }
        });
        const schema = { type: 'object', properties };
        if (required.length) {
            schema.required = required;
        }
        schema.additionalProperties = false;
        return schema;
    }

    inputSchema(input) {
        const node =
            input.kind === 'list'
                ? { type: 'array', items: { ...input.itemExtra, ...this.valueSchema(input.itemKind, input) } }
                : { ...this.valueSchema(input.kind, input) };
        if (input.description.trim()) {
            node.description = input.description.trim();
        }
        return { ...input.extra, ...node };
    }

    valueSchema(kind, input) {
        if (kind === 'group') {
            return this.objectSchema(input.children);
        }
        if (kind === 'picklist') {
            return { type: 'string', enum: [...(input.values || [])] };
        }
        if (kind === 'integer' || kind === 'number') {
            const node = { type: kind };
            if (input.minimum !== null && input.minimum !== undefined) {
                node.minimum = input.minimum;
            }
            if (input.maximum !== null && input.maximum !== undefined) {
                node.maximum = input.maximum;
            }
            return node;
        }
        if (kind === 'boolean') {
            return { type: 'boolean' };
        }
        if (KIND_FORMATS[kind]) {
            return { type: 'string', format: KIND_FORMATS[kind] };
        }
        const node = { type: 'string' };
        if (input.maxLength) {
            node.maxLength = input.maxLength;
        }
        return node;
    }
}
