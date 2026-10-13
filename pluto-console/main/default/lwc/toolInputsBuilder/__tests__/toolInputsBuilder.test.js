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
import ToolInputsBuilder from 'c/toolInputsBuilder';

const SCHEMA = JSON.stringify({
    type: 'object',
    properties: {
        orderId: { type: 'string', format: 'salesforce-id', description: 'The order.' },
        lines: {
            type: 'array',
            description: 'Order lines.',
            items: {
                type: 'object',
                properties: { sku: { type: 'string', maxLength: 20, pattern: '^[A-Z]+$', description: 'The SKU.' } },
                required: ['sku'],
                additionalProperties: false
            }
        }
    },
    required: ['orderId'],
    additionalProperties: false
});

function create(props = {}) {
    const element = createElement('c-tool-inputs-builder', { is: ToolInputsBuilder });
    Object.assign(element, props);
    document.body.appendChild(element);
    return element;
}

function rows(element) {
    return [...element.shadowRoot.querySelectorAll('[data-input]')];
}

function lastSent(handler) {
    return JSON.parse(handler.mock.calls[handler.mock.calls.length - 1][0].detail.value);
}

describe('c-tool-inputs-builder', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('shows each input of a saved schema, with a group inside a list indented under it', async () => {
        const element = create({ value: SCHEMA });
        await Promise.resolve();
        expect(rows(element).map((row) => row.dataset.input)).toEqual(['orderId', 'lines', 'sku']);
        expect(rows(element)[0].querySelector('[data-type-input]').value).toBe('recordId');
        expect(rows(element)[1].querySelector('[data-item-type-input]').value).toBe('group');
        expect(rows(element)[2].className).toContain('depth-1');
    });

    it('keeps keys it does not show when it saves', async () => {
        const element = create({ value: SCHEMA });
        const changed = jest.fn();
        element.addEventListener('schemachange', changed);
        await Promise.resolve();

        const description = rows(element)[0].querySelector('[data-description-input]');
        description.dispatchEvent(new CustomEvent('change', { detail: { value: 'The order to refund.' } }));
        const sent = lastSent(changed);
        expect(sent.properties.orderId.description).toBe('The order to refund.');
        expect(sent.properties.lines.items.properties.sku.pattern).toBe('^[A-Z]+$');
        expect(sent.required).toEqual(['orderId']);
    });

    it('adds a picklist input and names what is missing until it is complete', async () => {
        const element = create();
        const changed = jest.fn();
        element.addEventListener('schemachange', changed);
        await Promise.resolve();

        element.shadowRoot.querySelector('[data-add]').click();
        await Promise.resolve();
        const row = rows(element)[0];
        row.querySelector('[data-type-input]').dispatchEvent(new CustomEvent('change', { detail: { value: 'picklist' } }));
        await Promise.resolve();
        expect(element.reportValidity()).toBe(false);
        await Promise.resolve();
        const errors = rows(element)[0].querySelector('[data-errors]').textContent;
        expect(errors).toContain('Enter a name.');
        expect(errors).toContain('List at least one value.');

        const filled = rows(element)[0];
        filled.querySelector('[data-name-input]').dispatchEvent(new CustomEvent('change', { detail: { value: 'decision' } }));
        filled.querySelector('[data-description-input]').dispatchEvent(new CustomEvent('change', { detail: { value: 'released or hold.' } }));
        await Promise.resolve();
        rows(element)[0]
            .querySelector('[data-values-input]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'released\nhold\n' } }));
        expect(element.reportValidity()).toBe(true);
        expect(lastSent(changed)).toEqual({
            type: 'object',
            properties: { decision: { type: 'string', enum: ['released', 'hold'], description: 'released or hold.' } },
            required: ['decision'],
            additionalProperties: false
        });
    });

    it('refuses two inputs with one name', async () => {
        const element = create({
            value: JSON.stringify({
                type: 'object',
                properties: { a: { type: 'string', description: 'A.' }, b: { type: 'string', description: 'B.' } },
                additionalProperties: false
            })
        });
        await Promise.resolve();
        rows(element)[1]
            .querySelector('[data-name-input]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'a' } }));
        expect(element.reportValidity()).toBe(false);
        await Promise.resolve();
        expect(rows(element)[1].querySelector('[data-errors]').textContent).toContain('Another input here is also named a.');
    });

    it('shows no edit controls when read-only', async () => {
        const element = create({ value: SCHEMA, readOnly: true });
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('[data-add]')).toBeNull();
        expect(element.shadowRoot.querySelector('[data-remove]')).toBeNull();
    });
});
