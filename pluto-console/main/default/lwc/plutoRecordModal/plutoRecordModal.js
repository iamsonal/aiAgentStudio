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

import { api, wire } from 'lwc';
import LightningModal from 'lightning/modal';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';

/**
 * New and Edit in a modal, as standard Lightning does. Closes with
 * { action: 'save', recordId } after a save and { action: 'cancel' } on
 * Cancel; the X and Esc close with no result.
 */
export default class PlutoRecordModal extends LightningModal {
    @api recordId;
    @api objectApiName;
    @api objectLabel;
    @api isNew = false;
    @api defaultValues = {};

    @wire(getRecord, { recordId: '$recordId', optionalFields: '$nameFields' })
    record;

    get nameFields() {
        return this.objectApiName ? [`${this.objectApiName}.Name`] : undefined;
    }

    get title() {
        if (this.isNew) {
            return `New ${this.objectLabel || ''}`.trim();
        }
        const name = this.record?.data ? getFieldValue(this.record.data, `${this.objectApiName}.Name`) : null;
        return `Edit ${name || this.objectLabel || ''}`.trim();
    }

    get isAgent() {
        return this.objectApiName === 'AgentDefinition__c';
    }

    get isTool() {
        return this.objectApiName === 'AgentTool__c';
    }

    get isContextProvider() {
        return this.objectApiName === 'AgentContextProvider__c';
    }

    get isExecutionIdentity() {
        return this.objectApiName === 'AgentExecutionIdentity__c';
    }

    get isApprovalRoute() {
        return this.objectApiName === 'AgentApprovalRoute__c';
    }

    get isChannelRoute() {
        return this.objectApiName === 'AgentChannelRoute__c';
    }

    handleSaved(event) {
        this.close({ action: 'save', recordId: event.detail?.recordId ?? this.recordId });
    }

    handleCancel() {
        this.close({ action: 'cancel' });
    }
}
