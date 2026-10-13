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

import { LightningElement, api, wire } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getClassOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getClassOptions';
import searchSObjects from '@salesforce/apex/ToolAuthoringController.searchSObjects';
import getFieldSetOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getFieldSetOptions';

const OBJECT_FIELDS = ['AgentContextProvider__c.ObjectApiName__c'];

const FIELD_DEPENDENCIES = [
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
];

export default class PlutoContextProviderDetail extends LightningElement {
    @api recordId;
    @api isNew = false;
    @api mode = 'view';
    @api hideHeader = false;
    /** 'modal' when shown in the New or Edit modal. */
    @api variant = 'page';

    objectApiName = 'AgentContextProvider__c';
    fieldDependencies = FIELD_DEPENDENCIES;
    requiredFields = ['DeveloperName__c', 'ImplementationType__c'];
    @api defaultValues = {};
    get effectiveDefaultValues() {
        return { ImplementationType__c: 'Field Set', ContextSubject__c: 'Anchor Record', ...this.defaultValues };
    }

    customFieldRenderers = {
        Name: {
            helpText: 'A clear display name for this source of context, such as Case Details. Use different names to distinguish providers on the same agent.'
        },
        Description__c: { renderer: 'markdown' },
        ImplementationConfiguration__c: { renderer: 'json', objectOnly: true },
        ObjectApiName__c: { renderer: 'smartLookup' }
    };
    showAssistant = true;
    objectOptions = [];
    fieldSetOptions = [];
    selectedObjectApiName = '';
    fieldSetRequestId = 0;
    objectSearchRequestId = 0;

    @wire(getClassOptions, { interfaceName: 'IContextProvider' })
    contextProviders;

    @wire(getRecord, { recordId: '$recordId', fields: OBJECT_FIELDS })
    wiredContextProvider({ data }) {
        const objectApiName = data?.fields?.ObjectApiName__c?.value;
        if (objectApiName) {
            this.loadFieldSets(objectApiName);
        }
    }

    /**
     * Class picklist for the implementation reference. The generic form
     * only renders what it is given; all discovery lives here.
     */
    get fieldOptions() {
        return {
            ImplementationReference__c: this.contextProviders?.data?.length
                ? this.contextProviders.data.map((row) => ({ label: row.label, value: row.value }))
                : [{ label: this.contextProviders?.error ? 'Context providers unavailable' : 'No Apex context providers available', value: '' }],
            ObjectApiName__c: this.objectOptions,
            FieldSetName__c: this.fieldSetOptions.length
                ? this.fieldSetOptions
                : [{ label: this.selectedObjectApiName ? 'No Field Sets available' : 'Choose an object first', value: '' }]
        };
    }

    async loadFieldSets(objectApiName) {
        this.selectedObjectApiName = objectApiName || '';
        this.fieldSetOptions = [];
        const requestId = ++this.fieldSetRequestId;
        if (!objectApiName) {
            return;
        }
        try {
            const options = await getFieldSetOptions({ objectApiName });
            if (requestId === this.fieldSetRequestId) {
                this.fieldSetOptions = options.map((row) => ({ label: row.label, value: row.value }));
            }
        } catch (error) {
            if (requestId === this.fieldSetRequestId) {
                this.fieldSetOptions = [];
                this.dispatchEvent(new ShowToastEvent({ title: 'Field Sets unavailable', message: 'Refresh this page to try again.', variant: 'error' }));
            }
        }
    }

    async handleFieldSearch(event) {
        if (event.detail?.fieldName !== 'ObjectApiName__c') {
            return;
        }
        const requestId = ++this.objectSearchRequestId;
        try {
            const options = await searchSObjects({ term: event.detail.searchTerm });
            if (requestId === this.objectSearchRequestId) {
                this.objectOptions = options.map((row) => ({
                    label: row.label,
                    value: row.value,
                    subtitle: row.value,
                    icon: row.iconName || 'standard:default'
                }));
            }
        } catch (error) {
            if (requestId === this.objectSearchRequestId) {
                this.objectOptions = [];
                this.dispatchEvent(new ShowToastEvent({ title: 'Objects unavailable', message: 'Try the search again.', variant: 'error' }));
            }
        }
    }

    get hasSelection() {
        return this.isNew || !!this.recordId;
    }

    get effectiveMode() {
        return this.isNew ? 'new' : this.mode;
    }

    handleFieldChange(event) {
        if (event.detail?.fieldName === 'ObjectApiName__c') {
            const form = this.template.querySelector('c-pluto-record-layout');
            if (form?.getFieldValue('FieldSetName__c')) {
                form.setFieldValue('FieldSetName__c', null);
            }
            this.loadFieldSets(event.detail.value);
            return;
        }
        if (event.detail?.fieldName !== 'ImplementationType__c') {
            return;
        }
        const inactiveFields =
            event.detail.value === 'Field Set' ? ['ImplementationReference__c', 'ImplementationConfiguration__c'] : ['ObjectApiName__c', 'FieldSetName__c'];
        const form = this.template.querySelector('c-pluto-record-layout');
        inactiveFields.forEach((fieldName) => {
            if (form?.getFieldValue(fieldName)) {
                form.setFieldValue(fieldName, null);
            }
        });
        if (event.detail.value !== 'Field Set') {
            this.loadFieldSets('');
        }
    }

    handleEdit() {
        this.dispatchEvent(
            new CustomEvent('modechange', {
                detail: { mode: 'edit' },
                bubbles: true,
                composed: true
            })
        );
    }

    handleSave(event) {
        this.dispatchEvent(
            new CustomEvent('recordsaved', {
                detail: { recordId: event.detail?.recordId },
                bubbles: true,
                composed: true
            })
        );
    }

    handleCancel() {
        if (this.isNew) {
            this.dispatchEvent(
                new CustomEvent('recordcancel', {
                    bubbles: true,
                    composed: true
                })
            );
            return;
        }
        // Edit cancelled: return to view mode via URL, and remount the
        // assistant so unsaved edits are discarded.
        this.dispatchEvent(
            new CustomEvent('modechange', {
                detail: { mode: 'view' },
                bubbles: true,
                composed: true
            })
        );
        this.showAssistant = false;
        Promise.resolve().then(() => {
            this.showAssistant = true;
        });
    }
}
