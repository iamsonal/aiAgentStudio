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
import { registerSa11yMatcher } from '@sa11y/jest';
import PlutoChannelsHealth from 'c/plutoChannelsHealth';
import getChannelsHealth from '@salesforce/apex/PlutoChannelsController.getChannelsHealth';
import installChannelsSweep from '@salesforce/apex/PlutoChannelsController.installChannelsSweep';
import retryChannelMessage from '@salesforce/apex/PlutoChannelsController.retryChannelMessage';

jest.mock('@salesforce/apex/PlutoChannelsController.getChannelsHealth', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/PlutoChannelsController.installChannelsSweep', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/PlutoChannelsController.retryChannelMessage', () => ({ default: jest.fn() }), { virtual: true });

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const MESSAGE_ID = 'a0B000000000001AAA';

async function mount(health) {
    getChannelsHealth.mockResolvedValue(health);
    const element = createElement('c-pluto-channels-health', { is: PlutoChannelsHealth });
    document.body.appendChild(element);
    await flush();
    return element;
}

const parked = {
    available: true,
    snapshot: { parked: 1, overdueReceived: 0, overdueQueued: 0, longRunning: 0, sweepInstalled: false },
    parked: [{ id: MESSAGE_ID, name: 'MSG-0001', issueCode: 'ROUTE_UNMATCHED' }]
};

describe('c-pluto-channels-health', () => {
    beforeAll(() => registerSa11yMatcher());

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows nothing when Agent Channels is not installed', async () => {
        const element = await mount({ available: false });
        expect(element.shadowRoot.querySelector('lightning-card')).toBeNull();
    });

    it('installs the missing sweep as the current admin', async () => {
        installChannelsSweep.mockResolvedValue('08e000000000001AAA');
        const element = await mount(parked);
        element.shadowRoot.querySelector('.install-sweep').click();
        await flush();
        expect(installChannelsSweep).toHaveBeenCalled();
        expect(getChannelsHealth).toHaveBeenCalledTimes(2);
    });

    it('retries a parked email from its row', async () => {
        retryChannelMessage.mockResolvedValue(false);
        const element = await mount(parked);
        const row = element.shadowRoot.querySelector('.parked-row');
        expect(row.textContent).toContain('ROUTE_UNMATCHED');
        row.querySelector('lightning-button').click();
        await flush();
        expect(retryChannelMessage).toHaveBeenCalledWith({ messageId: MESSAGE_ID });
    });

    it('is accessible', async () => {
        const element = await mount(parked);
        await expect(element).toBeAccessible();
    });
});
