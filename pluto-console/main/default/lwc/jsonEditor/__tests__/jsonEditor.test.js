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
import JsonEditor from 'c/jsonEditor';

jest.mock('@salesforce/resourceUrl/plutoJsonEditor', () => ({ default: '/resource/plutoJsonEditor' }), { virtual: true });

function makeEditor(options = {}) {
    const element = createElement('c-json-editor', { is: JsonEditor });
    Object.assign(element, options);
    document.body.appendChild(element);
    return element;
}

function sendChange(element, value, overrides = {}) {
    const frame = element.shadowRoot.querySelector('iframe');
    const url = new URL(frame.src);
    window.dispatchEvent(
        new MessageEvent('message', {
            source: frame.contentWindow,
            origin: url.origin,
            data: { channel: url.searchParams.get('channel'), type: 'change', payload: { value } },
            ...overrides
        })
    );
}

describe('c-json-editor', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.restoreAllMocks();
    });

    it('preserves invalid drafts and rejects messages from other sources, origins, or channels', () => {
        const element = makeEditor({ value: '{}', objectOnly: true });
        const changed = jest.fn();
        element.addEventListener('change', changed);
        sendChange(element, '{', { source: window });
        sendChange(element, '{', { origin: 'https://untrusted.example' });
        sendChange(element, '{', { data: { channel: 'another-editor', type: 'change', payload: { value: '{' } } });
        expect(element.value).toBe('{}');
        expect(changed).not.toHaveBeenCalled();

        sendChange(element, '{');
        expect(element.value).toBe('{');
        expect(element.reportValidity()).toBe(false);
        expect(changed.mock.calls[0][0].detail.value).toBe('{');
        sendChange(element, '{"option":true}');
        expect(element.reportValidity()).toBe(true);
    });

    it('allows blank optional configuration, but rejects required blanks and nonobjects', () => {
        const element = makeEditor({ objectOnly: true });
        expect(element.checkValidity()).toBe(true);
        element.required = true;
        expect(element.reportValidity()).toBe(false);
        for (const value of ['null', '[]', '42', '"text"']) {
            element.value = value;
            expect(element.checkValidity()).toBe(false);
        }
        element.value = '{"enabled":false}';
        expect(element.checkValidity()).toBe(true);
    });

    it('formats explicitly and does not replace invalid input', async () => {
        const element = makeEditor({ value: '{"enabled":true}' });
        const changed = jest.fn();
        element.addEventListener('change', changed);
        element.shadowRoot.querySelector('lightning-button').click();
        expect(element.value).toBe('{\n  "enabled": true\n}');
        expect(changed).toHaveBeenCalledTimes(1);
        element.value = '{';
        element.shadowRoot.querySelector('lightning-button').click();
        await Promise.resolve();
        expect(element.value).toBe('{');
        expect(changed).toHaveBeenCalledTimes(1);
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('Enter valid JSON');
    });

    it('enforces field length without expanding a valid compact draft beyond its limit', () => {
        const element = makeEditor({ value: '{"a":1}', maxLength: 7 });
        element.shadowRoot.querySelector('lightning-button').click();
        expect(element.value).toBe('{"a":1}');
        expect(element.checkValidity()).toBe(true);
        element.value = '{"a":100}';
        expect(element.reportValidity()).toBe(false);
    });

    it('initializes the latest value after iframe readiness and supports server errors', () => {
        const element = makeEditor({ value: '{"a":1}', label: 'Implementation Configuration' });
        const frame = element.shadowRoot.querySelector('iframe');
        const post = jest.spyOn(frame.contentWindow, 'postMessage');
        element.value = '{"a":2}';
        frame.dispatchEvent(new Event('load'));
        expect(post).toHaveBeenLastCalledWith(
            expect.objectContaining({
                type: 'initialize',
                payload: { value: '{"a":2}', label: 'Implementation Configuration', disabled: false }
            }),
            new URL(frame.src).origin
        );
        element.setCustomValidity('Unknown implementation option.');
        expect(element.reportValidity()).toBe(false);
        element.setCustomValidity('');
        expect(element.checkValidity()).toBe(true);
    });

    it('disables editing and formatting in view mode and removes its message listener on disconnect', async () => {
        const element = makeEditor({ value: '{"a":1}', disabled: true });
        expect(element.shadowRoot.querySelector('lightning-button')).toBeNull();
        expect(element.shadowRoot.querySelector('iframe')).toBeNull();
        expect(element.shadowRoot.querySelector('pre').textContent).toBe('{\n  "a": 1\n}');
        expect(element.value).toBe('{"a":1}');
        const remove = jest.spyOn(window, 'removeEventListener');
        element.remove();
        await Promise.resolve();
        expect(remove).toHaveBeenCalledWith('message', expect.any(Function));
    });

    it('switches between a formatted view and an editor without rewriting the stored draft', async () => {
        const element = makeEditor({ value: '{"a":1}' });
        const changed = jest.fn();
        element.addEventListener('change', changed);
        element.disabled = true;
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('pre').textContent).toBe('{\n  "a": 1\n}');
        element.value = '{"a":2}';
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('pre').textContent).toContain('2');
        element.disabled = false;
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('pre')).toBeNull();
        expect(element.shadowRoot.querySelector('iframe')).not.toBeNull();
        expect(element.value).toBe('{"a":2}');
        expect(changed).not.toHaveBeenCalled();
    });

    it('shows blank and legacy invalid values without presenting an editable input', async () => {
        const element = makeEditor({ disabled: true });
        expect(element.shadowRoot.querySelector('pre').textContent).toBe('');
        element.value = '{invalid';
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('pre').textContent).toBe('{invalid');
    });
});
