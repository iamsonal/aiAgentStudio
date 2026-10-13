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
import PlutoExecutionIdentityDetail from 'c/plutoExecutionIdentityDetail';
import getNamedCredentialOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getNamedCredentialOptions';
jest.mock(
    '@salesforce/apex/PlutoImplementationDiscoveryService.getNamedCredentialOptions',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
describe('c-pluto-execution-identity-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('prompts for a selection when no record is set', () => {
        const element = createElement('c-pluto-execution-identity-detail', { is: PlutoExecutionIdentityDetail });
        document.body.appendChild(element);

        return Promise.resolve().then(() => {
            expect(element.shadowRoot.querySelector('p').textContent).toContain('Select an Agent Execution Identity');
            expect(element.shadowRoot.querySelector('c-pluto-record-layout')).toBeNull();
        });
    });

    it('offers Named Credentials by API name', async () => {
        const element = createElement('c-pluto-execution-identity-detail', { is: PlutoExecutionIdentityDetail });
        element.isNew = true;
        document.body.appendChild(element);
        getNamedCredentialOptions.emit([{ label: 'Agent Core Loopback (Agent_Core_Loopback)', value: 'Agent_Core_Loopback' }]);
        await Promise.resolve();

        expect(element.shadowRoot.querySelector('c-pluto-record-layout').fieldOptions.LoopbackNamedCredential__c).toEqual([
            { label: 'Agent Core Loopback (Agent_Core_Loopback)', value: 'Agent_Core_Loopback' }
        ]);
    });

    it('passes the record page header choice to the form', async () => {
        const element = createElement('c-pluto-execution-identity-detail', { is: PlutoExecutionIdentityDetail });
        element.recordId = 'a0B000000000001AAA';
        element.hideHeader = true;
        document.body.appendChild(element);
        await Promise.resolve();
        expect(element.shadowRoot.querySelector('c-pluto-record-layout').hideHeader).toBe(true);
    });
});
