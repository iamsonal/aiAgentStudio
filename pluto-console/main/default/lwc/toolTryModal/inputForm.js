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

/**
 * Turns a tool's Input Schema into form sections and back into tool input.
 * Each object with properties becomes a section; every other property becomes
 * one field, keyed by its dotted path (recordData.Subject). Lists and objects
 * without listed properties are typed as JSON.
 */

const MAX_DEPTH = 5;
const SALESFORCE_ID = /^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$/;
const TEXT_INPUT_TYPES = { date: 'date', 'date-time': 'datetime', email: 'email', uri: 'url' };

export function parseSchema(inputSchema) {
    try {
        const schema = inputSchema ? JSON.parse(inputSchema) : null;
        return schema && typeof schema === 'object' && !Array.isArray(schema) ? schema : { type: 'object', properties: {} };
    } catch (unreadable) {
        return { type: 'object', properties: {} };
    }
}

function isSection(property) {
    return !!property && property.type === 'object' && !!property.properties && Object.keys(property.properties).length > 0;
}

function kindOf(property, required) {
    if (Array.isArray(property.enum) && property.enum.length > 0) {
        return 'picklist';
    }
    if (property.type === 'boolean') {
        return required ? 'checkbox' : 'choice';
    }
    if (property.type === 'integer' || property.type === 'number') {
        return 'number';
    }
    if (property.type === 'array' || property.type === 'object') {
        return 'json';
    }
    return 'text';
}

/** Sections in display order; the first holds the top-level fields and has no heading. */
export function buildSections(schema) {
    const sections = [];
    collectSection(schema, '', '', '', sections, 0);
    return sections.filter((section) => section.fields.length > 0);
}

function collectSection(schema, path, heading, description, sections, depth) {
    const section = { key: path || 'root', heading, description, fields: [] };
    sections.push(section);
    const required = new Set(schema.required || []);
    const properties = schema.properties || {};
    Object.keys(properties).forEach((name) => {
        const property = properties[name] || {};
        const fieldPath = path ? `${path}.${name}` : name;
        if (isSection(property) && depth < MAX_DEPTH) {
            const title = property.title || name;
            collectSection(property, fieldPath, heading ? `${heading} › ${title}` : title, property.description || '', sections, depth + 1);
            return;
        }
        const kind = kindOf(property, required.has(name));
        section.fields.push({
            path: fieldPath,
            label: property.title || name,
            help: property.description || '',
            required: required.has(name),
            kind,
            inputType: TEXT_INPUT_TYPES[property.format] || 'text',
            isInteger: property.type === 'integer',
            isSalesforceId: property.format === 'salesforce-id',
            isList: property.type === 'array',
            options: kind === 'picklist' ? property.enum.map((value) => ({ label: String(value), value: String(value) })) : null,
            min: property.minimum,
            max: property.maximum,
            maxLength: property.maxLength
        });
    });
}

/** The starting value of every field: checkboxes start unchecked, everything else empty. */
export function emptyValues(sections) {
    const values = {};
    sections.forEach((section) =>
        section.fields.forEach((field) => {
            values[field.path] = field.kind === 'checkbox' ? false : '';
        })
    );
    return values;
}

function fieldsByPath(sections) {
    const byPath = {};
    sections.forEach((section) => section.fields.forEach((field) => (byPath[field.path] = field)));
    return byPath;
}

/** Reads one field: { isSet, value } or { error }. Empty optional fields are left out, as the agent would. */
function readField(field, raw, enumValues) {
    if (field.kind === 'checkbox') {
        return { isSet: true, value: raw === true };
    }
    if (raw === '' || raw === null || raw === undefined) {
        return { isSet: false };
    }
    if (field.kind === 'choice') {
        return { isSet: true, value: raw === 'true' };
    }
    if (field.kind === 'picklist') {
        const match = enumValues.find((value) => String(value) === raw);
        return { isSet: true, value: match === undefined ? raw : match };
    }
    if (field.kind === 'number') {
        const number = Number(raw);
        if (Number.isNaN(number)) {
            return { error: 'Enter a number.' };
        }
        if (field.isInteger && !Number.isInteger(number)) {
            return { error: 'Enter a whole number.' };
        }
        return { isSet: true, value: number };
    }
    if (field.kind === 'json') {
        try {
            const parsed = JSON.parse(raw);
            if (field.isList && !Array.isArray(parsed)) {
                return { error: 'Enter a JSON list, like ["first", "second"].' };
            }
            return { isSet: true, value: parsed };
        } catch (notJson) {
            return { error: field.isList ? 'Enter a JSON list, like ["first", "second"].' : 'Enter valid JSON.' };
        }
    }
    if (field.isSalesforceId && !SALESFORCE_ID.test(raw.trim())) {
        return { error: 'Enter a 15- or 18-character Salesforce Id.' };
    }
    return { isSet: true, value: raw };
}

/**
 * Builds the tool input from the form. strict also reports empty required
 * fields; a nested object the admin left empty is left out, and its required
 * fields are only checked once it has a value or is itself required.
 */
export function buildInput(schema, sections, values, strict = true) {
    const errors = {};
    const byPath = fieldsByPath(sections);
    const result = collectValue(schema, '', byPath, values, errors, strict, 0);
    return { input: result.value, errors };
}

function collectValue(schema, path, byPath, values, errors, strict, depth) {
    const required = new Set(schema.required || []);
    const properties = schema.properties || {};
    const value = {};
    let hasValue = false;
    Object.keys(properties).forEach((name) => {
        const property = properties[name] || {};
        const fieldPath = path ? `${path}.${name}` : name;
        if (isSection(property) && depth < MAX_DEPTH) {
            const childErrors = {};
            const child = collectValue(property, fieldPath, byPath, values, childErrors, strict, depth + 1);
            if (child.hasValue || required.has(name)) {
                value[name] = child.value;
                hasValue = true;
                Object.assign(errors, childErrors);
            }
            return;
        }
        const field = byPath[fieldPath];
        if (!field) {
            return;
        }
        const read = readField(field, values[fieldPath], property.enum || []);
        if (read.error) {
            errors[fieldPath] = read.error;
        } else if (read.isSet) {
            value[name] = read.value;
            hasValue = true;
        } else if (strict && required.has(name)) {
            errors[fieldPath] = 'Complete this field.';
        }
    });
    return { value, hasValue };
}

/**
 * Fills the form from typed JSON. Returns { values } or { error } when the
 * JSON has an input the form cannot show.
 */
export function valuesFromInput(sections, input) {
    if (!input || typeof input !== 'object' || Array.isArray(input)) {
        return { error: 'Tool input must be a JSON object.' };
    }
    const byPath = fieldsByPath(sections);
    const values = emptyValues(sections);
    const sectionPaths = new Set(sections.map((section) => section.key));
    const unknown = [];
    const visit = (object, prefix) => {
        Object.keys(object).forEach((name) => {
            const path = prefix ? `${prefix}.${name}` : name;
            const value = object[name];
            const field = byPath[path];
            if (field) {
                values[path] = toRaw(field, value);
            } else if (value && typeof value === 'object' && !Array.isArray(value) && hasSectionUnder(sectionPaths, path)) {
                visit(value, path);
            } else {
                unknown.push(path);
            }
        });
    };
    visit(input, '');
    if (unknown.length > 0) {
        return { error: `The form has no field for ${unknown.join(', ')}. Keep editing the JSON, or remove ${unknown.length === 1 ? 'it' : 'them'}.` };
    }
    return { values };
}

function hasSectionUnder(sectionPaths, path) {
    return [...sectionPaths].some((sectionPath) => sectionPath === path || sectionPath.startsWith(`${path}.`));
}

function toRaw(field, value) {
    if (field.kind === 'checkbox') {
        return value === true;
    }
    if (value === null || value === undefined) {
        return '';
    }
    if (field.kind === 'json') {
        return JSON.stringify(value);
    }
    return String(value);
}

/**
 * Finds the field a server message is about, such as
 * "Tool input.recordData is missing the required property Subject."
 */
export function fieldForProblem(problem, sections) {
    const match = /^Tool input(?:\.(\S+?))? (.*)$/.exec(problem || '');
    if (!match) {
        return null;
    }
    const byPath = fieldsByPath(sections);
    const missing = /^is missing the required property (.+)\.$/.exec(match[2]);
    const parent = match[1] || '';
    const path = missing ? (parent ? `${parent}.${missing[1]}` : missing[1]) : parent;
    if (!byPath[path]) {
        return null;
    }
    return { path, message: missing ? 'Complete this field.' : `This ${match[2].replace(/\.$/, '')}.` };
}
