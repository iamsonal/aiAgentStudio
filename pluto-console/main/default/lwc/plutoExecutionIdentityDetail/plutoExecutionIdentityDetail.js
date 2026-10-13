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
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getNamedCredentialOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getNamedCredentialOptions';
export default class PlutoExecutionIdentityDetail extends LightningElement {
    @api recordId;
    @api isNew = false;
    @api mode = 'view';
    @api hideHeader = false;
    /** 'modal' when shown in the New or Edit modal. */
    @api variant = 'page';

    customFieldRenderers = {
        Name: {
            helpText:
                'A clear display name for this user and credential pair, such as Case Automation. Choose a name that helps admins select the right identity for an agent.'
        }
    };
    objectApiName = 'AgentExecutionIdentity__c';
    requiredFields = ['PrincipalUser__c', 'LoopbackNamedCredential__c'];
    @api defaultValues = {};
    showAssistant = true;

    namedCredentials = [];

    @wire(getNamedCredentialOptions)
    wiredNamedCredentials({ data, error }) {
        if (data) {
            this.namedCredentials = data;
        } else if (error) {
            this.namedCredentials = [];
            this.dispatchEvent(new ShowToastEvent({ title: 'Named Credentials unavailable', message: 'Refresh this page to try again.', variant: 'error' }));
        }
    }

    get fieldOptions() {
        return {
            LoopbackNamedCredential__c: this.namedCredentials.length
                ? this.namedCredentials.map((row) => ({ label: row.label, value: row.value }))
                : [{ label: 'No Named Credentials available', value: '' }]
        };
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
