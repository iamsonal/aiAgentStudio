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
import PlutoContextProviderDetail from 'c/plutoContextProviderDetail';
import searchSObjects from '@salesforce/apex/ToolAuthoringController.searchSObjects';
import getFieldSetOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getFieldSetOptions';

jest.mock('@salesforce/apex/ToolAuthoringController.searchSObjects', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/PlutoImplementationDiscoveryService.getFieldSetOptions', () => ({ default: jest.fn() }), { virtual: true });

describe('c-pluto-context-provider-detail', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('prompts for a selection when no record is set', () => {
        const element = createElement('c-pluto-context-provider-detail', { is: PlutoContextProviderDetail });
        document.body.appendChild(element);

        return Promise.resolve().then(() => {
            expect(element.shadowRoot.querySelector('p').textContent).toContain('Select a context provider');
            expect(element.shadowRoot.querySelector('c-pluto-record-layout')).toBeNull();
        });
    });

    it('configures implementation-specific fields and requirements', () => {
        const element = createElement('c-pluto-context-provider-detail', { is: PlutoContextProviderDetail });
        element.isNew = true;
        document.body.appendChild(element);

        return Promise.resolve().then(() => {
            const form = element.shadowRoot.querySelector('c-pluto-record-layout');
            expect(form.requiredFields).toEqual(['DeveloperName__c', 'ImplementationType__c']);
            expect(form.fieldDependencies).toEqual([
                {
                    controllingField: 'ImplementationType__c',
                    controllingValue: 'Field Set',
                    showFields: ['ObjectApiName__c', 'FieldSetName__c'],
                    requiredFields: ['ContextSubject__c', 'ObjectApiName__c', 'FieldSetName__c']
                },
                {
                    controllingField: 'ImplementationType__c',
                    controllingValue: 'Apex',
                    showFields: ['ImplementationReference__c', 'ImplementationConfiguration__c'],
                    requiredFields: ['ImplementationReference__c']
                },
                {
                    controllingField: 'ContextSubject__c',
                    controllingValue: 'Initiating User',
                    fixedValues: { ObjectApiName__c: 'User' }
                }
            ]);
        });
    });

    it('clears fields from the previous implementation when the type changes', async () => {
        const element = createElement('c-pluto-context-provider-detail', { is: PlutoContextProviderDetail });
        element.isNew = true;
        document.body.appendChild(element);
        await Promise.resolve();

        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        form.setFieldValue('ImplementationReference__c', 'ExampleProvider');
        form.setFieldValue('ImplementationConfiguration__c', '{}');
        form.dispatchEvent(new CustomEvent('fieldchange', { detail: { fieldName: 'ImplementationType__c', value: 'Field Set' } }));

        expect(form.getFieldValue('ImplementationReference__c')).toBeNull();
        expect(form.getFieldValue('ImplementationConfiguration__c')).toBeNull();
    });

    it('searches objects and loads Field Sets for the selected object', async () => {
        searchSObjects.mockResolvedValue([{ label: 'Account • Account', value: 'Account', iconName: 'standard:account' }]);
        getFieldSetOptions.mockResolvedValue([{ label: 'Summary (Summary)', value: 'Summary' }]);
        const element = createElement('c-pluto-context-provider-detail', { is: PlutoContextProviderDetail });
        element.isNew = true;
        document.body.appendChild(element);
        await Promise.resolve();

        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        expect(form.customFieldRenderers.ObjectApiName__c.renderer).toBe('smartLookup');
        expect(form.customFieldRenderers.ImplementationConfiguration__c).toEqual({ renderer: 'json', objectOnly: true });
        form.dispatchEvent(new CustomEvent('fieldsearch', { detail: { fieldName: 'ObjectApiName__c', searchTerm: 'Acc' } }));
        await Promise.resolve();
        await Promise.resolve();
        expect(searchSObjects).toHaveBeenCalledWith({ term: 'Acc' });
        expect(form.fieldOptions.ObjectApiName__c).toEqual([{ label: 'Account • Account', value: 'Account', subtitle: 'Account', icon: 'standard:account' }]);

        form.setFieldValue('FieldSetName__c', 'OldFieldSet');
        form.dispatchEvent(new CustomEvent('fieldchange', { detail: { fieldName: 'ObjectApiName__c', value: 'Account' } }));
        await Promise.resolve();
        await Promise.resolve();
        expect(getFieldSetOptions).toHaveBeenCalledWith({ objectApiName: 'Account' });
        expect(form.fieldOptions.FieldSetName__c).toEqual([{ label: 'Summary (Summary)', value: 'Summary' }]);
        expect(form.getFieldValue('FieldSetName__c')).toBeNull();
    });
    it('starts with a Field Set on the anchor record while preserving supplied defaults', async () => {
        const element = createElement('c-pluto-context-provider-detail', { is: PlutoContextProviderDetail });
        element.isNew = true;
        element.defaultValues = { AgentDefinition__c: 'agent-id' };
        document.body.appendChild(element);
        await Promise.resolve();
        const form = element.shadowRoot.querySelector('c-pluto-record-layout');
        expect(form.defaultValues).toEqual({ AgentDefinition__c: 'agent-id', ImplementationType__c: 'Field Set', ContextSubject__c: 'Anchor Record' });
    });
});
