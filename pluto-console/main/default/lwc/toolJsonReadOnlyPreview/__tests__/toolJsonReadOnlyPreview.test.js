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
import ToolJsonReadOnlyPreview from 'c/toolJsonReadOnlyPreview';

describe('c-tool-json-read-only-preview', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('formats valid JSON for display', () => {
        const element = createElement('c-tool-json-read-only-preview', { is: ToolJsonReadOnlyPreview });
        element.value = '{"tool":"CreateRecord"}';
        document.body.appendChild(element);

        expect(element.shadowRoot.querySelector('pre').textContent).toBe('{\n  "tool": "CreateRecord"\n}');
    });

    it('displays invalid JSON without modifying it', () => {
        const element = createElement('c-tool-json-read-only-preview', { is: ToolJsonReadOnlyPreview });
        element.value = '{invalid';
        document.body.appendChild(element);

        expect(element.shadowRoot.querySelector('pre').textContent).toBe('{invalid');
    });
});
