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
import ToolInputsList from 'c/toolInputsList';

const INPUTS = [
    { path: 'recordData', name: 'recordData', depth: 0, typeLabel: 'Group', required: true, requiredByTool: true, hasChildren: true, editable: true },
    {
        path: 'recordData.Subject',
        name: 'Subject',
        depth: 1,
        typeLabel: 'Text (255)',
        required: false,
        requiredByTool: false,
        description: 'Subject of the Case.',
        toolDescription: 'Subject of the Case.',
        editable: true
    },
    {
        path: 'recordData.Priority',
        name: 'Priority',
        depth: 1,
        typeLabel: 'Picklist',
        required: false,
        requiredByTool: false,
        description: 'Priority of the Case.',
        toolDescription: 'Priority of the Case.',
        allowedValues: ['Low', 'Medium', 'High'],
        offeredValues: ['Low', 'Medium', 'High'],
        editable: true
    },
    {
        path: 'recordData.Status',
        name: 'Status',
        depth: 1,
        typeLabel: 'Picklist',
        required: true,
        requiredByTool: true,
        description: 'Status of the Case.',
        toolDescription: 'Status of the Case.',
        allowedValues: ['New'],
        offeredValues: ['New', 'Closed'],
        edited: true,
        editable: true
    }
];

function create(props = {}) {
    const element = createElement('c-tool-inputs-list', { is: ToolInputsList });
    Object.assign(element, { inputs: INPUTS, overrides: {} }, props);
    document.body.appendChild(element);
    return element;
}

function row(element, path) {
    return element.shadowRoot.querySelector(`[data-row="${path}"]`);
}

function lastOverrides(handler) {
    return handler.mock.calls[handler.mock.calls.length - 1][0].detail.value;
}

async function flush() {
    await Promise.resolve();
    await Promise.resolve();
}

describe('c-tool-inputs-list', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('locks Required on an input the tool requires', async () => {
        const element = create();
        await flush();

        expect(row(element, 'recordData.Status').querySelector('[data-required]').disabled).toBe(true);
        expect(row(element, 'recordData.Subject').querySelector('[data-required]').disabled).toBe(false);
    });

    it('makes an optional input required as an edit', async () => {
        const element = create();
        const changed = jest.fn();
        element.addEventListener('overrideschange', changed);
        await flush();

        const checkbox = row(element, 'recordData.Subject').querySelector('[data-required]');
        checkbox.dispatchEvent(new CustomEvent('change', { detail: { checked: true } }));

        expect(lastOverrides(changed)).toEqual({ 'recordData.Subject': { required: true } });
    });

    it('limits values in the order the tool offers them, and keeping all is no edit', async () => {
        const element = create();
        const changed = jest.fn();
        element.addEventListener('overrideschange', changed);
        await flush();

        row(element, 'recordData.Priority').querySelector('[data-limit-values]').click();
        await flush();
        const group = row(element, 'recordData.Priority').querySelector('[data-values-editor]');
        group.dispatchEvent(new CustomEvent('change', { detail: { value: ['High', 'Medium'] } }));
        row(element, 'recordData.Priority').querySelector('[data-save-values]').click();
        expect(lastOverrides(changed)).toEqual({ 'recordData.Priority': { allowedValues: ['Medium', 'High'] } });

        element.overrides = lastOverrides(changed);
        await flush();
        row(element, 'recordData.Priority').querySelector('[data-limit-values]').click();
        await flush();
        row(element, 'recordData.Priority')
            .querySelector('[data-values-editor]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: ['Low', 'Medium', 'High'] } }));
        row(element, 'recordData.Priority').querySelector('[data-save-values]').click();
        expect(lastOverrides(changed)).toEqual({});
    });

    it('asks to keep at least one value', async () => {
        const element = create();
        const changed = jest.fn();
        element.addEventListener('overrideschange', changed);
        await flush();

        row(element, 'recordData.Priority').querySelector('[data-limit-values]').click();
        await flush();
        row(element, 'recordData.Priority')
            .querySelector('[data-values-editor]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: [] } }));
        row(element, 'recordData.Priority').querySelector('[data-save-values]').click();
        await flush();

        expect(changed).not.toHaveBeenCalled();
        expect(row(element, 'recordData.Priority').querySelector('[data-values-error]').textContent).toBe('Keep at least one value.');
    });

    it('rewords a description, and the tool wording again is no edit', async () => {
        const element = create();
        const changed = jest.fn();
        element.addEventListener('overrideschange', changed);
        await flush();

        row(element, 'recordData.Subject').querySelector('[data-edit-description]').click();
        await flush();
        row(element, 'recordData.Subject')
            .querySelector('[data-description-editor]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'One line naming the product.' } }));
        row(element, 'recordData.Subject').querySelector('[data-save-description]').click();
        expect(lastOverrides(changed)).toEqual({ 'recordData.Subject': { description: 'One line naming the product.' } });

        element.overrides = lastOverrides(changed);
        await flush();
        row(element, 'recordData.Subject').querySelector('[data-edit-description]').click();
        await flush();
        row(element, 'recordData.Subject')
            .querySelector('[data-description-editor]')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Subject of the Case.' } }));
        row(element, 'recordData.Subject').querySelector('[data-save-description]').click();
        expect(lastOverrides(changed)).toEqual({});
    });

    it('resets an edited input to what the tool builds', async () => {
        const element = create({ overrides: { 'recordData.Status': { allowedValues: ['New'] }, 'recordData.Subject': { required: true } } });
        const changed = jest.fn();
        element.addEventListener('overrideschange', changed);
        await flush();

        expect(row(element, 'recordData.Status').querySelector('[data-edited]')).not.toBeNull();
        row(element, 'recordData.Status').querySelector('[data-reset]').click();

        expect(lastOverrides(changed)).toEqual({ 'recordData.Subject': { required: true } });
    });

    it('shows problems on the input they belong to', async () => {
        const element = create({ problemsByPath: { 'recordData.Priority': ['recordData.Priority does not offer the value Urgent.'] } });
        await flush();

        expect(row(element, 'recordData.Priority').querySelector('[data-problems]').textContent).toContain('Urgent');
    });

    it('offers no edits when read-only', async () => {
        const element = create({ readOnly: true });
        await flush();

        expect(element.shadowRoot.querySelector('[data-edit-description]')).toBeNull();
        expect(element.shadowRoot.querySelector('[data-reset]')).toBeNull();
    });

    it('limits free text to listed values and a shorter length', async () => {
        const element = createElement('c-tool-inputs-list', { is: ToolInputsList });
        element.inputs = [{ path: 'reason', name: 'reason', depth: 0, typeLabel: 'Text', editable: true, isText: true, toolMaxLength: 255, maxLength: 255 }];
        element.overrides = {};
        const changed = jest.fn();
        element.addEventListener('overrideschange', changed);
        document.body.appendChild(element);
        await Promise.resolve();

        element.shadowRoot.querySelector('[data-limit-values]').click();
        await Promise.resolve();
        element.shadowRoot.querySelector('[data-free-values-editor]').dispatchEvent(new CustomEvent('change', { detail: { value: 'released\nhold' } }));
        element.shadowRoot.querySelector('[data-save-free-values]').click();
        expect(changed.mock.calls[0][0].detail.value).toEqual({ reason: { allowedValues: ['released', 'hold'] } });

        await Promise.resolve();
        element.shadowRoot.querySelector('[data-limit-length]').click();
        await Promise.resolve();
        element.shadowRoot.querySelector('[data-length-editor]').dispatchEvent(new CustomEvent('change', { detail: { value: '300' } }));
        element.shadowRoot.querySelector('[data-save-length]').click();
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('[data-length-error]').textContent).toContain('at most 255');

        element.shadowRoot.querySelector('[data-length-editor]').dispatchEvent(new CustomEvent('change', { detail: { value: '100' } }));
        element.shadowRoot.querySelector('[data-save-length]').click();
        expect(changed.mock.calls[1][0].detail.value).toEqual({ reason: { allowedValues: ['released', 'hold'], maxLength: 100 } });
    });

    it('hides the row links while one of its editors is open', async () => {
        const element = create();
        await flush();

        row(element, 'recordData.Subject').querySelector('[data-edit-description]').click();
        await flush();
        expect(row(element, 'recordData.Subject').querySelector('[data-edit-description]')).toBeNull();
        expect(row(element, 'recordData.Priority').querySelector('[data-limit-values]')).not.toBeNull();

        row(element, 'recordData.Subject').querySelector('lightning-button').click();
        await flush();
        expect(row(element, 'recordData.Subject').querySelector('[data-edit-description]')).not.toBeNull();
    });
});
