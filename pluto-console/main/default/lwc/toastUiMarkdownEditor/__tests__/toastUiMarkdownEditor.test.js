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
import ToastUiMarkdownEditor from 'c/toastUiMarkdownEditor';

jest.mock('@salesforce/resourceUrl/toastUiEditor', () => ({ default: '/resource/toastUiEditor' }), { virtual: true });

describe('c-toast-ui-markdown-editor', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.restoreAllMocks();
    });

    it('loads Toast UI in a sandboxed static-resource iframe', () => {
        const element = createElement('c-toast-ui-markdown-editor', { is: ToastUiMarkdownEditor });
        element.value = 'Initial description';
        document.body.appendChild(element);

        const frame = element.shadowRoot.querySelector('iframe');
        expect(frame.src).toContain('/resource/toastUiEditor/editor.html?channel=toast-ui-');
        expect(frame.getAttribute('sandbox')).toBe('allow-scripts allow-same-origin');
    });
});
