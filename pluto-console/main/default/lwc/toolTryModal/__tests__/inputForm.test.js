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

import { parseSchema, buildSections, emptyValues, buildInput, valuesFromInput, fieldForProblem } from '../inputForm';

const CASE_SCHEMA = {
    type: 'object',
    properties: {
        caseId: { type: 'string', format: 'salesforce-id', description: 'The Case to update.' },
        recordData: {
            type: 'object',
            description: 'Field values for the Case.',
            properties: {
                Subject: { type: 'string', maxLength: 255, description: 'Subject of the Case.' },
                Priority: { type: 'string', enum: ['High', 'Low'] },
                IsEscalated: { type: 'boolean' },
                Count: { type: 'integer' },
                DueOn: { type: 'string', format: 'date' }
            },
            required: ['Subject'],
            additionalProperties: false
        },
        notify: {
            type: 'object',
            properties: { email: { type: 'string', format: 'email' } },
            required: ['email']
        },
        tags: { type: 'array', items: { type: 'string' } },
        confirm: { type: 'boolean' }
    },
    required: ['recordData', 'confirm'],
    additionalProperties: false
};

describe('inputForm', () => {
    const sections = buildSections(CASE_SCHEMA);

    it('turns each object into a section and picks a control for each input type', () => {
        expect(sections.map((section) => section.heading)).toEqual(['', 'recordData', 'notify']);
        const byPath = Object.fromEntries(sections.flatMap((section) => section.fields).map((field) => [field.path, field]));
        expect(byPath.caseId).toMatchObject({ kind: 'text', isSalesforceId: true, help: 'The Case to update.', required: false });
        expect(byPath['recordData.Subject']).toMatchObject({ kind: 'text', required: true, maxLength: 255 });
        expect(byPath['recordData.Priority'].options.map((option) => option.value)).toEqual(['High', 'Low']);
        expect(byPath['recordData.IsEscalated'].kind).toBe('choice');
        expect(byPath.confirm.kind).toBe('checkbox');
        expect(byPath['recordData.Count']).toMatchObject({ kind: 'number', isInteger: true });
        expect(byPath['recordData.DueOn'].inputType).toBe('date');
        expect(byPath['notify.email'].inputType).toBe('email');
        expect(byPath.tags).toMatchObject({ kind: 'json', isList: true });
    });

    it('builds the input the agent would send, leaving out what the admin left empty', () => {
        const values = {
            ...emptyValues(sections),
            'recordData.Subject': 'Broken printer',
            'recordData.Count': '3',
            'recordData.IsEscalated': 'false',
            tags: '["a"]'
        };

        const { input, errors } = buildInput(CASE_SCHEMA, sections, values);

        expect(errors).toEqual({});
        expect(input).toEqual({ recordData: { Subject: 'Broken printer', Count: 3, IsEscalated: false }, tags: ['a'], confirm: false });
    });

    it('reports empty required fields and bad values, but not inside an optional object left empty', () => {
        const values = { ...emptyValues(sections), caseId: '123', 'recordData.Count': '1.5', tags: '{"a":1}' };

        const { errors } = buildInput(CASE_SCHEMA, sections, values);

        expect(errors).toEqual({
            caseId: 'Enter a 15- or 18-character Salesforce Id.',
            'recordData.Subject': 'Complete this field.',
            'recordData.Count': 'Enter a whole number.',
            tags: 'Enter a JSON list, like ["first", "second"].'
        });
        expect(buildInput(CASE_SCHEMA, sections, { ...values, 'notify.email': 'x@example.com' }).errors['notify.email']).toBeUndefined();
    });

    it('fills the form from JSON and refuses inputs the form cannot show', () => {
        const filled = valuesFromInput(sections, { recordData: { Subject: 'Hi', IsEscalated: true }, tags: ['a'], confirm: true });
        expect(filled.values['recordData.Subject']).toBe('Hi');
        expect(filled.values['recordData.IsEscalated']).toBe('true');
        expect(filled.values.tags).toBe('["a"]');
        expect(filled.values.confirm).toBe(true);

        expect(valuesFromInput(sections, { extra: 1 }).error).toContain('no field for extra');
        expect(valuesFromInput(sections, []).error).toContain('JSON object');
    });

    it('finds the field a server message is about', () => {
        expect(fieldForProblem('Tool input.recordData is missing the required property Subject.', sections)).toEqual({
            path: 'recordData.Subject',
            message: 'Complete this field.'
        });
        expect(fieldForProblem('Tool input is missing the required property confirm.', sections).path).toBe('confirm');
        expect(fieldForProblem('Tool input.recordData.Count must be an integer.', sections)).toEqual({
            path: 'recordData.Count',
            message: 'This must be an integer.'
        });
        expect(fieldForProblem('Tool input contains extra, which the schema does not allow.', sections)).toBeNull();
    });

    it('treats a missing or unreadable schema as a tool with no inputs', () => {
        expect(buildSections(parseSchema(''))).toEqual([]);
        expect(buildSections(parseSchema('{not json'))).toEqual([]);
    });
});
