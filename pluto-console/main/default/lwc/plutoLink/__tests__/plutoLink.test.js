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
import PlutoLink, { recordPage } from 'c/plutoLink';
import { getNavigateCalledWith, mockNavigate } from 'lightning/navigation';

async function render(props) {
    const element = createElement('c-pluto-link', { is: PlutoLink });
    Object.assign(element, props);
    document.body.appendChild(element);
    await Promise.resolve();
    await Promise.resolve();
    return element;
}

describe('c-pluto-link', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        mockNavigate.mockClear();
    });

    it('carries the real URL so it can open in a new tab', async () => {
        const element = await render({ label: 'Open agent', pageReference: recordPage('a03000000000001AAA', 'AgentDefinition__c') });
        const anchor = element.shadowRoot.querySelector('a');
        expect(anchor.textContent).toBe('Open agent');
        expect(anchor.getAttribute('href')).toBe('https://www.example.com');
    });

    it('navigates inside the app on a plain click', async () => {
        const reference = recordPage('a05000000000001AAA', 'AgentTool__c');
        const element = await render({ label: 'get_case', pageReference: reference });
        element.shadowRoot.querySelector('a').dispatchEvent(new MouseEvent('click', { button: 0, bubbles: true, cancelable: true }));
        expect(getNavigateCalledWith().pageReference).toEqual(reference);
    });

    it('leaves a new-tab click to the browser', async () => {
        const element = await render({ label: 'get_case', pageReference: recordPage('a05000000000001AAA', 'AgentTool__c') });
        element.shadowRoot.querySelector('a').dispatchEvent(new MouseEvent('click', { button: 0, metaKey: true, bubbles: true, cancelable: true }));
        expect(mockNavigate).not.toHaveBeenCalled();
    });

    it('shows only an icon, with the label for screen readers, in the icon variant', async () => {
        const element = await render({ variant: 'icon', label: 'Open tool get_case', pageReference: recordPage('a05000000000001AAA', 'AgentTool__c') });
        const anchor = element.shadowRoot.querySelector('a');
        expect(anchor.title).toBe('Open tool get_case');
        expect(anchor.querySelector('lightning-icon').alternativeText).toBe('Open tool get_case');
    });
});
