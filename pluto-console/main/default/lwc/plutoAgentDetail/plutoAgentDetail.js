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
import getClassOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getClassOptions';
import getModelOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getModelOptions';

const FIELD_DEPENDENCIES = [
    {
        controllingField: 'IsActive__c',
        controllingValue: true,
        requiredFields: ['Model__c']
    }
];

function toOptions(rows) {
    return (rows || []).map((row) => ({ label: row.label, value: row.value }));
}

export default class PlutoAgentDetail extends LightningElement {
    @api recordId;
    @api isNew = false;
    @api mode = 'view';
    @api hideHeader = false;
    /** 'modal' when shown in the New or Edit modal. */
    @api variant = 'page';

    objectApiName = 'AgentDefinition__c';
    fieldDependencies = FIELD_DEPENDENCIES;
    requiredFields = ['DeveloperName__c'];
    @api defaultValues = {};
    customFieldRenderers = {
        Name: { helpText: 'A clear display name for this agent, such as Case Triage. Integrations use Developer Name rather than this label.' },
        Instructions__c: { renderer: 'markdown' },
        OutputSchema__c: { renderer: 'json', objectOnly: true }
    };
    showAssistant = true;

    @wire(getClassOptions, { interfaceName: 'IToolAuthorizationPolicy' })
    authPolicies;

    @wire(getModelOptions)
    models;

    /**
     * Picklists for the model and class-name text fields. The generic form
     * only renders what it is given; all discovery lives here.
     */
    get fieldOptions() {
        const options = {};
        options.ToolAuthorizationPolicyClass__c = this.authPolicies?.data?.length
            ? toOptions(this.authPolicies.data)
            : [{ label: this.authPolicies?.error ? 'Authorization policies unavailable' : 'No custom authorization policies', value: '' }];
        options.Model__c = this.models?.data?.length ? toOptions(this.models.data) : [{ label: 'No active Agent Models', value: '' }];
        return options;
    }

    get hasSelection() {
        return this.isNew || !!this.recordId;
    }

    get effectiveMode() {
        return this.isNew ? 'new' : this.mode;
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
