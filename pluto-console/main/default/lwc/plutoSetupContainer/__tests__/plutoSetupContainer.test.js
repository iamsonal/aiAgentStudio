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
import PlutoSetupContainer from 'c/plutoSetupContainer';
import { CurrentPageReference } from 'lightning/navigation';

jest.mock('lightning/navigation', () => {
    const { createTestWireAdapter } = require('@salesforce/wire-service-jest-util');
    const Navigate = Symbol('Navigate');
    const navigateMock = jest.fn();
    const NavigationMixin = (Base) =>
        class extends Base {
            [Navigate](...args) {
                navigateMock(...args);
            }
        };
    NavigationMixin.Navigate = Navigate;
    return {
        CurrentPageReference: createTestWireAdapter(jest.fn()),
        NavigationMixin,
        navigateMock
    };
});

const { navigateMock } = require('lightning/navigation');

async function render(state) {
    const element = createElement('c-pluto-setup-container', { is: PlutoSetupContainer });
    document.body.appendChild(element);
    CurrentPageReference.emit({ state });
    await Promise.resolve();
    return element;
}

describe('c-pluto-setup-container', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        navigateMock.mockClear();
    });

    it('offers only Overview and Settings, since setup records live on their own tabs', async () => {
        const element = await render({});
        const names = [...element.shadowRoot.querySelectorAll('lightning-vertical-navigation-item-icon')].map((item) => item.name);
        expect(names).toEqual(['overview', 'settings']);
        expect(element.shadowRoot.querySelector('c-agent-core-health')).not.toBeNull();
    });

    it('opens Overview for a link to a record section that no longer exists', async () => {
        const element = await render({ c__section: 'approvalRoutes', c__view: 'record', c__id: 'a09000000000000AAA' });
        expect(element.shadowRoot.querySelector('c-agent-core-health')).not.toBeNull();
    });

    it('switches section by replacing the URL', async () => {
        const element = await render({ c__section: 'overview' });
        element.shadowRoot.querySelector('lightning-vertical-navigation').dispatchEvent(new CustomEvent('select', { detail: { name: 'settings' } }));
        expect(navigateMock).toHaveBeenCalledWith(
            { type: 'standard__navItemPage', attributes: { apiName: 'PlutoHome' }, state: { c__section: 'settings' } },
            true
        );

        CurrentPageReference.emit({ state: { c__section: 'settings' } });
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('c-agent-core-health')).toBeNull();
        expect(element.shadowRoot.querySelector('.setup-content lightning-card').title).toBe('Settings');
    });
});
