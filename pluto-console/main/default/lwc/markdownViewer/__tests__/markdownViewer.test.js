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
import MarkdownViewer from 'c/markdownViewer';
import { loadScript } from 'lightning/platformResourceLoader';

jest.mock('lightning/platformResourceLoader', () => ({ loadScript: jest.fn(() => Promise.resolve()) }));
jest.mock('@salesforce/resourceUrl/micromark', () => ({ default: '/resource/micromark' }), { virtual: true });

async function flushPromises() {
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
}

describe('c-markdown-viewer', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
        delete window.plutoMarkdown;
        delete window.plutoMarkdownGfm;
    });

    it('renders markdown through micromark once the library loads', async () => {
        window.plutoMarkdown = { micromark: jest.fn(() => '<h1>Title</h1>') };
        window.plutoMarkdownGfm = { gfm: jest.fn(() => ({})), gfmHtml: jest.fn(() => ({})) };
        const element = createElement('c-markdown-viewer', { is: MarkdownViewer });
        element.value = '# Title';
        document.body.appendChild(element);
        await flushPromises();

        expect(loadScript).toHaveBeenCalledTimes(2);
        expect(window.plutoMarkdown.micromark).toHaveBeenCalledWith('# Title', expect.objectContaining({ allowDangerousHtml: false }));
        expect(element.shadowRoot.querySelector('lightning-formatted-rich-text').value).toBe('<h1>Title</h1>');
    });

    it('surfaces an error with fallback html when the library fails to load', async () => {
        loadScript.mockRejectedValueOnce(new Error('404')).mockRejectedValueOnce(new Error('404'));
        const element = createElement('c-markdown-viewer', { is: MarkdownViewer });
        element.value = '**bold**';
        document.body.appendChild(element);
        await flushPromises();

        expect(element.shadowRoot.textContent).toContain('Failed to load markdown renderer');
        expect(element.html).toContain('<strong>bold</strong>');
        expect(element.hasError).toBe(true);
    });
});
