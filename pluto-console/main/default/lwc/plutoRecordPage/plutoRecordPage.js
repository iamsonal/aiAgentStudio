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
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import { decodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import PlutoRecordModal from 'c/plutoRecordModal';

const DETAIL_BY_OBJECT = {
    AgentDefinition__c: 'agent',
    AgentTool__c: 'tool',
    AgentContextProvider__c: 'contextProvider',
    AgentExecutionIdentity__c: 'executionIdentity',
    AgentApprovalRoute__c: 'approvalRoute',
    AgentChannelRoute__c: 'channelRoute'
};

let modalOpen = false;

/**
 * The record a related list's New started from. Lightning passes it as
 * inContextOfRef: "1." followed by a base64 page reference.
 */
function contextRecord(inContextOfRef) {
    if (!inContextOfRef) {
        return null;
    }
    try {
        const encoded = inContextOfRef.startsWith('1.') ? inContextOfRef.substring(2) : inContextOfRef;
        const { recordId, objectApiName } = JSON.parse(window.atob(encoded))?.attributes ?? {};
        return recordId ? { recordId, objectApiName } : null;
    } catch (error) {
        return null;
    }
}

/**
 * The Pluto editor on a record page (View) and behind the New and Edit
 * buttons, which open it in a modal as standard Lightning does. The page URL
 * decides the mode, so every Edit, from any list or page, lands on the same
 * editor.
 */
export default class PlutoRecordPage extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;
    /**
     * Set by the New and Edit override. Lightning keeps the record page
     * mounted behind the override and sends it the Edit URL too, so only the
     * override may open the modal.
     */
    @api inButtonOverride = false;

    actionName = 'view';
    pageRecordId;
    pageObjectApiName;
    urlDefaults = {};
    startedFrom = null;
    showDetail = true;
    inlineEditing = false;
    objectInfo;
    _pageKey;
    _modalShown = false;

    @wire(CurrentPageReference)
    setPageReference(pageRef) {
        if (!pageRef) {
            return;
        }
        const attributes = pageRef.attributes ?? {};
        const state = pageRef.state ?? {};
        const actionName = attributes.actionName === 'new' || attributes.actionName === 'edit' ? attributes.actionName : 'view';
        if (actionName !== 'view' && !this.inButtonOverride) {
            return;
        }
        this.actionName = actionName;
        this.pageRecordId = attributes.recordId;
        this.pageObjectApiName = attributes.objectApiName;
        this.urlDefaults = state.defaultFieldValues ? decodeDefaultFieldValues(state.defaultFieldValues) || {} : {};
        this.startedFrom = contextRecord(state.inContextOfRef);

        // A button override stays mounted from one page to the next; remount
        // the editor so a draft never carries over to another record.
        const key = JSON.stringify([this.actionName, this.pageRecordId, this.pageObjectApiName, state.defaultFieldValues, state.inContextOfRef]);
        if (this._pageKey && key !== this._pageKey) {
            this.inlineEditing = false;
            this.showDetail = false;
            Promise.resolve().then(() => {
                this.showDetail = true;
            });
        }
        this._pageKey = key;
        this.openModalIfNeeded();
    }

    get effectiveRecordId() {
        return this.isNew ? null : this.pageRecordId || this.recordId;
    }

    get effectiveObjectApiName() {
        return this.pageObjectApiName || this.objectApiName;
    }

    @wire(getObjectInfo, { objectApiName: '$effectiveObjectApiName' })
    wiredObjectInfo(result) {
        this.objectInfo = result;
        this.openModalIfNeeded();
    }

    get detail() {
        return DETAIL_BY_OBJECT[this.effectiveObjectApiName];
    }

    get isAgent() {
        return this.detail === 'agent';
    }

    get isTool() {
        return this.detail === 'tool';
    }

    get isContextProvider() {
        return this.detail === 'contextProvider';
    }

    get isExecutionIdentity() {
        return this.detail === 'executionIdentity';
    }

    get isApprovalRoute() {
        return this.detail === 'approvalRoute';
    }

    get isChannelRoute() {
        return this.detail === 'channelRoute';
    }

    get isUnsupported() {
        return !!this.effectiveObjectApiName && !this.detail;
    }

    get isNew() {
        return this.actionName === 'new';
    }

    get detailMode() {
        return this.actionName === 'edit' ? 'edit' : 'view';
    }

    get isViewMode() {
        return !this.isNew && this.detailMode === 'view';
    }

    get showInline() {
        return this.showDetail && this.isViewMode;
    }

    /** The record page edits in place, as standard inline edit does; only the buttons use the modal. */
    get inlineMode() {
        return this.inlineEditing ? 'edit' : 'view';
    }

    /** The modal waits for object metadata: New reads its defaults once, and the title needs the object label. */
    get isModalReady() {
        return !this.isViewMode && !!this.detail && (!!this.objectInfo?.data || !!this.objectInfo?.error);
    }

    /**
     * One modal per override, and one at a time. Lightning mounts a new
     * override for every New or Edit but keeps the previous one alive, hidden,
     * and still sent page references. If that one opened the modal, Lightning
     * would remove it while the modal is open, and its navigation on close
     * would be dropped, leaving the admin on the Edit URL.
     */
    async openModalIfNeeded() {
        if (!this.isModalReady || this._modalShown || modalOpen) {
            return;
        }
        const key = this._pageKey;
        this._modalShown = true;
        modalOpen = true;
        let result;
        try {
            result = await PlutoRecordModal.open({
                size: 'medium',
                label: this.isNew ? 'New record' : 'Edit record',
                recordId: this.effectiveRecordId,
                objectApiName: this.effectiveObjectApiName,
                objectLabel: this.objectInfo?.data?.label,
                isNew: this.isNew,
                defaultValues: this.isNew ? this.newDefaultValues : {}
            });
        } finally {
            modalOpen = false;
        }
        if (this._pageKey !== key) {
            return;
        }
        // Both replace the New or Edit page, so Back goes to where the admin started.
        if (result?.action === 'save') {
            this.navigateToRecord(result.recordId ?? this.effectiveRecordId, 'view', true);
        } else {
            this.returnAfterCancel();
        }
    }

    /** Lookups that may hold the record New started from. */
    get createableLookups() {
        return Object.values(this.objectInfo?.data?.fields ?? {}).filter((field) => field.dataType === 'Reference' && field.createable);
    }

    /**
     * URL defaults, plus the parent a related list's New started from when
     * exactly one lookup points to that parent's object.
     */
    get newDefaultValues() {
        const defaults = { ...this.urlDefaults };
        const parent = this.startedFrom;
        if (parent?.objectApiName) {
            const lookups = this.createableLookups.filter((field) => (field.referenceToInfos ?? []).some((info) => info.apiName === parent.objectApiName));
            if (lookups.length === 1 && defaults[lookups[0].apiName] === undefined) {
                defaults[lookups[0].apiName] = parent.recordId;
            }
        }
        return defaults;
    }

    /** Cancel on New returns to the record it started from, if any. */
    get returnRecordId() {
        if (this.startedFrom?.recordId) {
            return this.startedFrom.recordId;
        }
        const lookup = this.createableLookups.find((field) => this.urlDefaults[field.apiName]);
        return lookup ? this.urlDefaults[lookup.apiName] : null;
    }

    navigateToRecord(recordId, actionName, replace) {
        this[NavigationMixin.Navigate](
            { type: 'standard__recordPage', attributes: { recordId, objectApiName: this.effectiveObjectApiName, actionName } },
            replace
        );
    }

    navigateToList(replace) {
        this[NavigationMixin.Navigate](
            { type: 'standard__objectPage', attributes: { objectApiName: this.effectiveObjectApiName, actionName: 'list' } },
            replace
        );
    }

    /** On the record page only a field's pencil asks for edit, and Cancel asks for view. */
    handleModeChange(event) {
        this.inlineEditing = event.detail?.mode === 'edit';
    }

    handleInlineSaved() {
        this.inlineEditing = false;
    }

    /** Cancel on Edit returns to the record; on New, to where New started, or the list. */
    returnAfterCancel() {
        if (!this.isNew) {
            this.navigateToRecord(this.effectiveRecordId, 'view', true);
            return;
        }
        const recordId = this.returnRecordId;
        if (recordId) {
            this[NavigationMixin.Navigate]({ type: 'standard__recordPage', attributes: { recordId, actionName: 'view' } }, true);
            return;
        }
        this.navigateToList(true);
    }

    handleBack() {
        this.navigateToList(false);
    }
}
