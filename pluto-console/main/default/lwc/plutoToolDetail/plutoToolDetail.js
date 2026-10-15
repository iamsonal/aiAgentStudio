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
const PACKAGE_FIELDS = [{ fieldApiName: 'ApprovalRoute__c', before: 'ApprovalTimeoutMinutes__c' }];

const ALWAYS_REQUIRED = 'Always Required';
const DECIDED_BY_POLICY = 'Decided by Policy';
const CAN_WAIT = [ALWAYS_REQUIRED, DECIDED_BY_POLICY];
const APPROVER_FIELDS = ['ApproverType__c', 'ApproverUser__c', 'ApproverQueue__c'];
const WAIT_FIELDS = ['ApprovalTimeoutMinutes__c', 'ApprovalExpiryAction__c', 'ApprovalRoute__c'];
// The tool names its approver only for Always Required; for Decided by Policy the policy names one.
const FIELD_DEPENDENCIES = [
    {
        controllingField: 'ApprovalMode__c',
        controllingValue: ALWAYS_REQUIRED,
        showFields: ['ApproverType__c'],
        requiredFields: ['ApproverType__c']
    },
    {
        controllingField: 'ApprovalMode__c',
        controllingValue: CAN_WAIT,
        showFields: ['ApprovalTimeoutMinutes__c', 'ApprovalExpiryAction__c'],
        requiredFields: ['ApprovalExpiryAction__c']
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
        controllingValue: ['User', 'Queue', 'Anchor Record Owner', "Requester's Manager"],
        showFields: ['ApprovalRoute__c']
    },
    {
        controllingField: 'ApprovalMode__c',
        controllingValue: DECIDED_BY_POLICY,
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
        const { fieldName, value } = event.detail || {};
        const inactiveFields = [];
        if (fieldName === 'ApprovalMode__c') {
            if (value !== ALWAYS_REQUIRED) {
                inactiveFields.push(...APPROVER_FIELDS);
            }
            if (!CAN_WAIT.includes(value)) {
                inactiveFields.push(...WAIT_FIELDS);
            }
        } else if (fieldName === 'ApproverType__c') {
            if (value !== 'User') {
                inactiveFields.push('ApproverUser__c');
            }
            if (value !== 'Queue' && value !== 'Anchor Record Owner') {
                inactiveFields.push('ApproverQueue__c');
            }
            if (value === 'Delivery Channel') {
                inactiveFields.push('ApprovalRoute__c');
            }
        }
        inactiveFields.forEach((inactive) => {
            if (form?.getFieldValue(inactive)) {
                form.setFieldValue(inactive, null);
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
