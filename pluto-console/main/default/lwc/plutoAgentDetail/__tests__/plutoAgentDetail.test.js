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
import PlutoAgentDetail from 'c/plutoAgentDetail';
import getModelOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getModelOptions';

jest.mock(
    '@salesforce/apex/PlutoImplementationDiscoveryService.getModelOptions',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

describe('c-pluto-agent-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('prompts for a selection when no record is set', () => {
        const element = createElement('c-pluto-agent-detail', { is: PlutoAgentDetail });
        document.body.appendChild(element);

        return Promise.resolve().then(() => {
            expect(element.shadowRoot.querySelector('p').textContent).toContain('Select an agent');
            expect(element.shadowRoot.querySelector('c-pluto-record-layout')).toBeNull();
        });
    });

    it('offers active Agent Models by API name', async () => {
        const element = createElement('c-pluto-agent-detail', { is: PlutoAgentDetail });
        element.isNew = true;
        document.body.appendChild(element);
        getModelOptions.emit([
            { label: 'Model A (model-a)', value: 'Model_A' },
            { label: 'Model B (model-b)', value: 'Model_B' }
        ]);
        await Promise.resolve();

        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        expect(form.fieldOptions.Model__c).toEqual([
            { label: 'Model A (model-a)', value: 'Model_A' },
            { label: 'Model B (model-b)', value: 'Model_B' }
        ]);
    });

    it('requires a model for an active agent and renders instructions and output schema with Pluto editors', async () => {
        const element = createElement('c-pluto-agent-detail', { is: PlutoAgentDetail });
        element.isNew = true;
        document.body.appendChild(element);
        await Promise.resolve();

        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        expect(form.customFieldRenderers.Instructions__c).toEqual({ renderer: 'markdown' });
        expect(form.customFieldRenderers.OutputSchema__c).toEqual({ renderer: 'json', objectOnly: true });
        expect(form.fieldDependencies).toEqual([{ controllingField: 'IsActive__c', controllingValue: true, requiredFields: ['Model__c'] }]);
        expect(form.requiredFields).toEqual(['DeveloperName__c']);
    });
});
