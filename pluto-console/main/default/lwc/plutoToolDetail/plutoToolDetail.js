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
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import saveTool from '@salesforce/apex/ToolAuthoringController.saveTool';
import getApproverQueueOptions from '@salesforce/apex/PlutoImplementationDiscoveryService.getApproverQueueOptions';
// The embedded editor owns and shows the implementation type, tool type, settings, and input schema.
const EDITOR_FIELDS = ['ToolType__c', 'ImplementationType__c', 'ImplementationConfiguration__c', 'InputSchema__c'];
// Agent HITL adds Approval Route to the tool; it shows only where HITL is installed.
const PACKAGE_FIELDS = [{ fieldApiName: 'ApprovalRoute__c', before: 'ApprovalTimeoutHours__c' }];

const APPROVER_TYPES = ['User', 'Queue', 'Anchor Record Owner', "Requester's Manager", 'Delivery Channel'];
// Approver Type stays visible without Requires Approval: an authorization policy
// may still ask for approval, and Core then uses the tool's approver.
const FIELD_DEPENDENCIES = [
    {
        controllingField: 'RequiresApproval__c',
        controllingValue: true,
        requiredFields: ['ApproverType__c']
    },
    {
        controllingField: 'ApproverType__c',
        controllingValue: 'User',
        showFields: ['ApproverUser__c'],
        requiredFields: ['ApproverUser__c']
    },
    {
        // Anchor Record Owner may name an optional fallback queue for when the owner cannot decide.
        controllingField: 'ApproverType__c',
        controllingValue: ['Queue', 'Anchor Record Owner'],
        showFields: ['ApproverQueue__c']
    },
    {
        controllingField: 'ApproverType__c',
        controllingValue: 'Queue',
        requiredFields: ['ApproverQueue__c']
    },
    {
        controllingField: 'ApproverType__c',
        controllingValue: APPROVER_TYPES,
        showFields: ['ApprovalTimeoutHours__c', 'ApprovalExpiryAction__c']
    },
    {
        controllingField: 'ApproverType__c',
        controllingValue: ['User', 'Queue', 'Anchor Record Owner', "Requester's Manager"],
        showFields: ['ApprovalRoute__c']
    }
];

// Core's output contract is defaulted on create and preserved on update,
// with no extra configuration in Pluto.
export default class PlutoToolDetail extends LightningElement {
    @api recordId;
    @api isNew = false;
    @api mode = 'view';
    @api hideHeader = false;
    /** 'modal' when shown in the New or Edit modal. */
    @api variant = 'page';

    objectApiName = 'AgentTool__c';
    additionalFields = PACKAGE_FIELDS;
    fieldDependencies = FIELD_DEPENDENCIES;
    requiredFields = ['DeveloperName__c'];
    @api defaultValues = {};
    customFieldRenderers = {
        Name: { helpText: 'A clear display name for this action, such as Look Up Case. The model calls it using Developer Name rather than this label.' },
        Description__c: { renderer: 'markdown' }
    };
    showAssistant = true;
    approverQueues = [];
    queueLoadFailed = false;
    queuesLoaded = false;

    @wire(getApproverQueueOptions)
    wiredApproverQueues({ data, error }) {
        if (data) {
            this.approverQueues = data;
            this.queueLoadFailed = false;
            this.queuesLoaded = true;
        } else if (error) {
            this.approverQueues = [];
            this.queueLoadFailed = true;
            this.queuesLoaded = true;
            this.dispatchEvent(new ShowToastEvent({ title: 'Approver queues unavailable', message: 'Refresh this page to try again.', variant: 'error' }));
        }
    }

    get fieldOptions() {
        return {
            ApproverQueue__c: this.approverQueues.length
                ? this.approverQueues
                : [
                      {
                          label: this.queueLoadFailed ? 'Queues unavailable' : this.queuesLoaded ? 'No queues support Agent Approval' : 'Loading queues…',
                          value: ''
                      }
                  ]
        };
    }

    get hasSelection() {
        return this.isNew || !!this.recordId;
    }

    get effectiveMode() {
        return this.isNew ? 'new' : this.mode;
    }

    get isToolEditing() {
        return this.effectiveMode !== 'view';
    }

    get hiddenFields() {
        return EDITOR_FIELDS;
    }

    handleFieldChange(event) {
        const form = this.template.querySelector('c-pluto-record-layout');
        if (event.detail?.fieldName !== 'ApproverType__c') {
            return;
        }
        const selectedType = event.detail.value;
        const inactiveFields = [];
        if (selectedType !== 'User') {
            inactiveFields.push('ApproverUser__c');
        }
        if (selectedType !== 'Queue' && selectedType !== 'Anchor Record Owner') {
            inactiveFields.push('ApproverQueue__c');
        }
        if (!selectedType || selectedType === 'Delivery Channel') {
            inactiveFields.push('ApprovalRoute__c');
        }
        if (!selectedType) {
            inactiveFields.push('ApprovalTimeoutHours__c', 'ApprovalExpiryAction__c');
        }
        inactiveFields.forEach((fieldName) => {
            if (form?.getFieldValue(fieldName)) {
                form.setFieldValue(fieldName, null);
            }
        });
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

    async handleSaveRequest(event) {
        const form = this.template.querySelector('c-pluto-record-layout');
        const editor = this.template.querySelector('c-tool-authoring-editor');
        const draft = editor?.prepareDraft();
        if (!draft) {
            form?.failSave({ message: 'Choose a Tool Type, fill in its required settings, and fix the inputs marked in red before saving.' });
            return;
        }
        try {
            const recordId = await saveTool({
                header: event.detail.recordInput.fields,
                toolType: draft.toolType,
                implementationConfiguration: draft.implementationConfiguration,
                inputSchema: draft.inputSchema
            });
            // Apex saves bypass the record cache; refresh it so view mode
            // shows what the server stored.
            notifyRecordUpdateAvailable([{ recordId }]).catch(() => {});
            editor?.reload();
            form?.completeSave(recordId);
        } catch (error) {
            form?.failSave(error);
        }
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
