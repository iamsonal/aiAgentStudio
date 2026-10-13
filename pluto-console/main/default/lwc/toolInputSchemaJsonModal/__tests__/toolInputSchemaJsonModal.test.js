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
import ToolInputSchemaJsonModal from 'c/toolInputSchemaJsonModal';

async function flush() {
    await new Promise((resolve) => setTimeout(resolve, 0));
    await Promise.resolve();
}

function open(props) {
    const element = createElement('c-tool-input-schema-json-modal', { is: ToolInputSchemaJsonModal });
    Object.assign(element, { inputSchema: '{"type":"object","properties":{},"additionalProperties":false}', ...props });
    document.body.appendChild(element);
    return element;
}

const $ = (element, selector) => element.shadowRoot.querySelector(selector);
const button = (element, label) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((item) => item.label === label);

describe('c-tool-input-schema-json-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('starts from the current schema and closes only after it applies', async () => {
        const applySchema = jest.fn(() => Promise.resolve([]));
        const element = open({ applySchema });
        await flush();
        expect($(element, 'c-json-editor').value).toContain('"additionalProperties":false');

        $(element, 'c-json-editor').dispatchEvent(
            new CustomEvent('change', { detail: { value: '{"type":"object","properties":{"caseNumber":{"type":"string"}}}' } })
        );
        button(element, 'Apply').click();
        await flush();

        expect(applySchema).toHaveBeenCalledWith('{"type":"object","properties":{"caseNumber":{"type":"string"}}}');
        expect(element.closeValue).toBe('applied');
    });

    it('shows the problem, stays open, and says The inputs have not changed', async () => {
        const element = open({
            applySchema: jest.fn(() => Promise.resolve(["Core builds this tool's inputs from its settings, so it cannot take: recordId."]))
        });
        await flush();

        button(element, 'Apply').click();
        await flush();

        expect(element.closeValue).toBeUndefined();
        expect($(element, '[data-problems]').textContent).toContain('cannot take: recordId');
        expect($(element, '[data-problems]').textContent).toContain('The inputs have not changed.');
    });

    it('shows a server refusal, such as a user who cannot edit tools, as a problem', async () => {
        const element = open({ applySchema: jest.fn(() => Promise.reject({ body: { message: 'The current user cannot edit this tool.' } })) });
        await flush();

        button(element, 'Apply').click();
        await flush();

        expect($(element, '[data-problems]').textContent).toContain('cannot edit this tool');
    });

    it('only shows the schema when the tool is locked', async () => {
        const element = open({ readOnly: true });
        await flush();

        expect($(element, 'c-json-editor')).toBeNull();
        expect($(element, 'c-tool-json-read-only-preview').value).toContain('"type":"object"');
        expect(button(element, 'Apply')).toBeUndefined();
        expect(button(element, 'Close')).toBeDefined();
    });
});
