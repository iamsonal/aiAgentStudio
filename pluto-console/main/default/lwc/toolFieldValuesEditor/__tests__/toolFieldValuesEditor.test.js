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
import ToolFieldValuesEditor from 'c/toolFieldValuesEditor';

const FIELDS = [
    { value: 'Origin', label: 'Case Origin', dataType: 'PICKLIST', isPicklist: true, picklistValues: [{ value: 'Agent', label: 'Agent' }] },
    { value: 'IsEscalated', label: 'Escalated', dataType: 'BOOLEAN' },
    { value: 'AccountId', label: 'Account ID', dataType: 'REFERENCE', referenceTo: 'Account', referenceCount: 1 },
    { value: 'Subject', label: 'Subject', dataType: 'STRING' },
    { value: 'ActivityDate', label: 'Due Date', dataType: 'DATE' },
    { value: 'Due__c', label: 'Due', dataType: 'DATETIME' },
    { value: 'Amount__c', label: 'Amount', dataType: 'CURRENCY' }
];

function create(value = {}) {
    const element = createElement('c-tool-field-values-editor', { is: ToolFieldValuesEditor });
    element.fields = FIELDS;
    element.value = value;
    document.body.appendChild(element);
    return element;
}

function lastValue(handler) {
    return handler.mock.calls[handler.mock.calls.length - 1][0].detail.value;
}

async function flush() {
    await Promise.resolve();
    await Promise.resolve();
}

describe('c-tool-field-values-editor', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('shows each fixed value with a control for its field type', async () => {
        const element = create({ Origin: 'Agent', IsEscalated: true });
        await flush();

        const rows = element.shadowRoot.querySelectorAll('[data-row]');
        expect(rows).toHaveLength(2);
        expect(rows[0].querySelector('lightning-combobox[data-value]').value).toBe('Agent');
        expect(rows[1].querySelector('lightning-input[data-value]').checked).toBe(true);
    });

    it('adds a value and sends the whole set', async () => {
        const element = create();
        const changed = jest.fn();
        element.addEventListener('valueschange', changed);
        await flush();

        element.shadowRoot.querySelector('[data-add]').click();
        await flush();
        element.shadowRoot.querySelector('[data-field]').dispatchEvent(new CustomEvent('change', { detail: { value: 'ActivityDate' } }));
        await flush();
        // A field without a value yet is not sent, so Core does not check an empty date.
        expect(lastValue(changed)).toEqual({});
        expect(element.shadowRoot.querySelector('[data-waits]')).not.toBeNull();
        element.shadowRoot.querySelector('[data-field]').dispatchEvent(new CustomEvent('change', { detail: { value: 'Subject' } }));
        await flush();
        element.shadowRoot.querySelector('lightning-input[data-value]').dispatchEvent(new CustomEvent('change', { detail: { value: 'Printer' } }));

        expect(lastValue(changed)).toEqual({ Subject: 'Printer' });
    });

    it('offers what Pluto can fill in only for fields it fits', async () => {
        const element = create({ AccountId: '', Subject: '' });
        await flush();

        const rows = element.shadowRoot.querySelectorAll('[data-row]');
        expect(rows[0].querySelector('[data-mode]').options.map((option) => option.value)).toEqual(['value', ':anchorId']);
        expect(rows[0].querySelector('lightning-record-picker')).not.toBeNull();
        expect(rows[1].querySelector('[data-mode]')).toBeNull();
    });

    it('offers each field once', async () => {
        const element = create({ Subject: 'Printer' });
        await flush();
        element.shadowRoot.querySelector('[data-add]').click();
        await flush();

        const second = element.shadowRoot.querySelectorAll('[data-row]')[1];
        expect(second.querySelector('[data-field]').options.map((option) => option.value)).not.toContain('Subject');
    });

    it('offers five simple choices for a date and builds what Core reads', async () => {
        const element = create({ ActivityDate: '' });
        const changed = jest.fn();
        element.addEventListener('valueschange', changed);
        await flush();

        const row = () => element.shadowRoot.querySelector('[data-row]');
        const mode = () => row().querySelector('[data-mode]');
        expect(mode().options.map((option) => option.value)).toEqual(['value', ':today', 'offset', 'start', 'end']);

        mode().dispatchEvent(new CustomEvent('change', { detail: { value: 'offset' } }));
        await flush();
        expect(lastValue(changed)).toEqual({ ActivityDate: ':today+1d' });
        row()
            .querySelector('[data-part="amount"]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: '-2' } }));
        row()
            .querySelector('[data-part="unit"]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'w' } }));
        await flush();
        expect(lastValue(changed)).toEqual({ ActivityDate: ':today-2w' });
        expect(row().querySelector('[data-summary]').textContent).toBe('Pluto fills in 2 weeks before today on each call.');

        mode().dispatchEvent(new CustomEvent('change', { detail: { value: 'end' } }));
        await flush();
        expect(lastValue(changed)).toEqual({ ActivityDate: ':endOfMonth' });
        row()
            .querySelector('[data-part="which"]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'next' } }));
        row()
            .querySelector('[data-part="period"]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Quarter' } }));
        await flush();
        expect(lastValue(changed)).toEqual({ ActivityDate: ':endOfQuarter+3m' });
        expect(row().querySelector('[data-summary]').textContent).toBe('Pluto fills in the end of next quarter on each call.');
    });

    it('reads saved dates back into the simple choices, and keeps one they cannot show', async () => {
        const element = create({ ActivityDate: ':startOfWeek-1w' });
        await flush();
        const row = () => element.shadowRoot.querySelector('[data-row]');
        expect(row().querySelector('[data-mode]').value).toBe('start');
        expect(row().querySelector('[data-part="which"]').value).toBe('last');
        expect(row().querySelector('[data-part="period"]').value).toBe('Week');

        element.value = { ActivityDate: ':today-1d' };
        await flush();
        expect(row().querySelector('[data-mode]').value).toBe('offset');
        expect(row().querySelector('[data-part="amount"]').value).toBe(-1);

        element.value = { ActivityDate: ':endOfMonth+2m' };
        await flush();
        expect(row().querySelector('[data-mode]').value).toBe(':endOfMonth+2m');
        expect(
            row()
                .querySelector('[data-mode]')
                .options.map((option) => option.label)
        ).toContain('Saved value :endOfMonth+2m');
    });

    it('moves a date and time by hours', async () => {
        const element = create({ Due__c: ':now-4h' });
        await flush();

        const row = element.shadowRoot.querySelector('[data-row]');
        expect(row.querySelector('[data-mode]').value).toBe('offsetTime');
        expect(row.querySelector('[data-part="amount"]').value).toBe(-4);
        expect(row.querySelector('[data-part="unit"]').value).toBe('h');
    });

    it('enters a plain value with a control for the field type', async () => {
        const element = create({ Amount__c: 5, ActivityDate: '2026-02-01' });
        const changed = jest.fn();
        element.addEventListener('valueschange', changed);
        await flush();

        const rows = element.shadowRoot.querySelectorAll('[data-row]');
        expect(rows[0].querySelector('lightning-input[data-value]').type).toBe('number');
        expect(rows[1].querySelector('lightning-input[data-value]').type).toBe('date');
        rows[0].querySelector('lightning-input[data-value]').dispatchEvent(new CustomEvent('change', { detail: { value: '12' } }));
        expect(lastValue(changed)).toEqual({ Amount__c: 12, ActivityDate: '2026-02-01' });
    });

    it('removes a value', async () => {
        const element = create({ Origin: 'Agent', Subject: 'Printer' });
        const changed = jest.fn();
        element.addEventListener('valueschange', changed);
        await flush();

        element.shadowRoot.querySelector('[data-remove]').click();

        expect(lastValue(changed)).toEqual({ Subject: 'Printer' });
    });
});
