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

import fs from 'fs';
import path from 'path';

const frameScript = fs.readFileSync(path.join(__dirname, '../../../staticresources/plutoJsonEditor/editor.js'), 'utf8');

function initializeFrame(withCodeMirror = true) {
    const textarea = document.createElement('textarea');
    const editor = {
        value: '',
        getValue() {
            return this.value;
        },
        setValue(value) {
            this.value = value;
            this.change();
        },
        on(name, listener) {
            this.change = listener;
        },
        setOption: jest.fn(),
        focus: jest.fn()
    };
    let listener;
    const frameWindow = {
        location: { search: '?channel=test&parentOrigin=https%3A%2F%2Fparent.example' },
        parent: { postMessage: jest.fn() },
        addEventListener(name, callback) {
            listener = callback;
        },
        CodeMirror: withCodeMirror ? { fromTextArea: jest.fn(() => editor) } : undefined
    };
    // Execute the bundled bridge against a frame-local DOM and editor.
    new Function('window', 'document', frameScript)(frameWindow, { getElementById: () => textarea });
    const send = (type, payload, overrides = {}) =>
        listener({
            source: frameWindow.parent,
            origin: 'https://parent.example',
            data: { channel: 'test', type, payload },
            ...overrides
        });
    return { frameWindow, textarea, editor, send };
}

describe('bundled JSON editor frame', () => {
    it('only accepts its parent origin and never echoes programmatic value changes', () => {
        const { frameWindow, editor, send } = initializeFrame();
        frameWindow.parent.postMessage.mockClear();
        send('initialize', { value: '{"a":1}', label: 'Configuration', disabled: false });
        expect(editor.value).toBe('{"a":1}');
        expect(frameWindow.parent.postMessage).not.toHaveBeenCalled();
        send('setValue', { value: '{}' }, { origin: 'https://other.example' });
        send('setValue', { value: '{}' }, { source: {} });
        expect(editor.value).toBe('{"a":1}');
        editor.value = '{';
        editor.change();
        expect(frameWindow.parent.postMessage).toHaveBeenCalledWith({ channel: 'test', type: 'change', payload: { value: '{' } }, 'https://parent.example');
        send('setDisabled', { disabled: true });
        expect(editor.setOption).toHaveBeenCalledWith('readOnly', true);
        send('focus');
        expect(editor.focus).toHaveBeenCalled();
    });

    it('retains editing and initialization if the CodeMirror library is unavailable', () => {
        const { frameWindow, textarea, send } = initializeFrame(false);
        send('initialize', { value: '{}', label: 'Configuration', disabled: true });
        expect(textarea.value).toBe('{}');
        expect(textarea.readOnly).toBe(true);
        expect(textarea.getAttribute('aria-label')).toBe('Configuration');
        send('setDisabled', { disabled: false });
        textarea.value = '{"a":true}';
        textarea.dispatchEvent(new Event('input'));
        expect(frameWindow.parent.postMessage).toHaveBeenLastCalledWith(
            { channel: 'test', type: 'change', payload: { value: '{"a":true}' } },
            'https://parent.example'
        );
    });
});
