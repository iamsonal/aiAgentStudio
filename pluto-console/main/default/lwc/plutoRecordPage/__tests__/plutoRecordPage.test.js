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
import PlutoRecordPage from 'c/plutoRecordPage';
import { CurrentPageReference, getNavigateCalledWith, mockNavigate } from 'lightning/navigation';
import { decodeDefaultFieldValues } from 'lightning/pageReferenceUtils';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import { registerLdsTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import PlutoRecordModal from 'c/plutoRecordModal';

jest.mock('c/plutoRecordModal', () => ({ __esModule: true, default: { open: jest.fn() } }));

const objectInfoAdapter = registerLdsTestWireAdapter(getObjectInfo);

const AGENT_ID = 'a03000000000001AAA';
const TOOL_ID = 'a05000000000001AAA';

const TOOL_INFO = {
    apiName: 'AgentTool__c',
    label: 'Agent Tool',
    fields: {
        AgentDefinition__c: { apiName: 'AgentDefinition__c', dataType: 'Reference', createable: true, referenceToInfos: [{ apiName: 'AgentDefinition__c' }] },
        Name: { apiName: 'Name', dataType: 'String', createable: true }
    }
};

function recordPage(recordId, objectApiName, actionName) {
    return { type: 'standard__recordPage', attributes: { recordId, objectApiName, actionName } };
}

function newPage(objectApiName, state = {}) {
    return { type: 'standard__objectPage', attributes: { objectApiName, actionName: 'new' }, state };
}

function inContextOf(recordId, objectApiName) {
    return `1.${window.btoa(JSON.stringify(recordPage(recordId, objectApiName, 'view')))}`;
}

async function render(pageRef, inButtonOverride = pageRef.attributes.actionName !== 'view') {
    const element = createElement('c-pluto-record-page', { is: PlutoRecordPage });
    element.inButtonOverride = inButtonOverride;
    document.body.appendChild(element);
    CurrentPageReference.emit(pageRef);
    await Promise.resolve();
    return element;
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

const toolDetail = (element) => element.shadowRoot.querySelector('c-pluto-tool-detail');

describe('c-pluto-record-page', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        mockNavigate.mockClear();
        decodeDefaultFieldValues.mockReset();
        PlutoRecordModal.open.mockReset();
    });

    it('shows the record in view mode on its record page', async () => {
        const element = await render(recordPage(TOOL_ID, 'AgentTool__c', 'view'));

        expect(toolDetail(element).recordId).toBe(TOOL_ID);
        expect(toolDetail(element).mode).toBe('view');
        expect(toolDetail(element).isNew).toBe(false);
        expect(toolDetail(element).hideHeader).toBe(true);
    });

    it('edits in place from a field pencil, and Save or Cancel return to view without leaving the page', async () => {
        const element = await render(recordPage(TOOL_ID, 'AgentTool__c', 'view'));
        toolDetail(element).dispatchEvent(new CustomEvent('modechange', { detail: { mode: 'edit' } }));
        await Promise.resolve();
        expect(toolDetail(element).mode).toBe('edit');

        toolDetail(element).dispatchEvent(new CustomEvent('recordsaved', { detail: { recordId: TOOL_ID } }));
        await Promise.resolve();
        expect(toolDetail(element).mode).toBe('view');

        toolDetail(element).dispatchEvent(new CustomEvent('modechange', { detail: { mode: 'edit' } }));
        await Promise.resolve();
        toolDetail(element).dispatchEvent(new CustomEvent('modechange', { detail: { mode: 'view' } }));
        await Promise.resolve();
        expect(toolDetail(element).mode).toBe('view');
        expect(mockNavigate).not.toHaveBeenCalled();
        expect(PlutoRecordModal.open).not.toHaveBeenCalled();
    });

    it('opens the Edit button in a modal, and Save replaces the edit page with the record', async () => {
        PlutoRecordModal.open.mockResolvedValue({ action: 'save', recordId: TOOL_ID });
        const override = await render(recordPage(TOOL_ID, 'AgentTool__c', 'edit'));
        objectInfoAdapter.emit(TOOL_INFO);
        await flush();

        expect(toolDetail(override)).toBeNull();
        expect(PlutoRecordModal.open).toHaveBeenCalledTimes(1);
        expect(PlutoRecordModal.open.mock.calls[0][0]).toMatchObject({
            size: 'medium',
            recordId: TOOL_ID,
            objectApiName: 'AgentTool__c',
            objectLabel: 'Agent Tool',
            isNew: false
        });
        expect(getNavigateCalledWith()).toEqual({ pageReference: recordPage(TOOL_ID, 'AgentTool__c', 'view'), replace: true });
    });

    it('closing the Edit modal replaces the edit page with the record', async () => {
        PlutoRecordModal.open.mockResolvedValue(undefined);
        await render(recordPage(TOOL_ID, 'AgentTool__c', 'edit'));
        objectInfoAdapter.emit(TOOL_INFO);
        await flush();

        expect(getNavigateCalledWith()).toEqual({ pageReference: recordPage(TOOL_ID, 'AgentTool__c', 'view'), replace: true });
    });

    it('opens one modal per page, after object metadata loads', async () => {
        let close;
        PlutoRecordModal.open.mockReturnValue(new Promise((resolve) => (close = resolve)));
        await render(newPage('AgentContextProvider__c'));
        expect(PlutoRecordModal.open).not.toHaveBeenCalled();

        objectInfoAdapter.emit({ ...TOOL_INFO, apiName: 'AgentContextProvider__c', label: 'Agent Context Provider' });
        objectInfoAdapter.emit({ ...TOOL_INFO, apiName: 'AgentContextProvider__c', label: 'Agent Context Provider' });
        await flush();

        expect(PlutoRecordModal.open).toHaveBeenCalledTimes(1);
        expect(PlutoRecordModal.open.mock.calls[0][0]).toMatchObject({ size: 'medium', recordId: null, isNew: true, defaultValues: {} });
        close();
        await flush();
    });

    it('leaves the next Edit to the new override when Lightning keeps the earlier one alive', async () => {
        PlutoRecordModal.open.mockResolvedValue(undefined);
        await render(recordPage(TOOL_ID, 'AgentTool__c', 'edit'));
        objectInfoAdapter.emit(TOOL_INFO);
        await flush();

        CurrentPageReference.emit(recordPage(TOOL_ID, 'AgentTool__c', 'view'));
        await flush();
        const sameRecordReordered = `1.${window.btoa(JSON.stringify({ type: 'standard__recordPage', attributes: { objectApiName: 'AgentTool__c', recordId: TOOL_ID, actionName: 'view' } }))}`;
        CurrentPageReference.emit({ ...recordPage(TOOL_ID, 'AgentTool__c', 'edit'), state: { inContextOfRef: sameRecordReordered, count: '2' } });
        await flush();

        expect(PlutoRecordModal.open).toHaveBeenCalledTimes(1);
    });

    it('leaves Edit to the button override when the record page is still mounted behind it', async () => {
        let close;
        PlutoRecordModal.open.mockReturnValue(new Promise((resolve) => (close = resolve)));
        const page = await render(recordPage(TOOL_ID, 'AgentTool__c', 'view'));
        const override = await render(recordPage(TOOL_ID, 'AgentTool__c', 'edit'), true);
        CurrentPageReference.emit(recordPage(TOOL_ID, 'AgentTool__c', 'edit'));
        objectInfoAdapter.emit(TOOL_INFO);
        await flush();

        expect(PlutoRecordModal.open).toHaveBeenCalledTimes(1);
        expect(toolDetail(page).mode).toBe('view');
        expect(toolDetail(override)).toBeNull();
        close();
        await flush();
    });

    it('prefills the parent when New starts from a related list, and Cancel returns to it', async () => {
        PlutoRecordModal.open.mockResolvedValue({ action: 'cancel' });
        await render(newPage('AgentTool__c', { inContextOfRef: inContextOf(AGENT_ID, 'AgentDefinition__c') }));
        objectInfoAdapter.emit(TOOL_INFO);
        await flush();

        expect(PlutoRecordModal.open.mock.calls[0][0].defaultValues).toEqual({ AgentDefinition__c: AGENT_ID });
        expect(getNavigateCalledWith()).toEqual({
            pageReference: { type: 'standard__recordPage', attributes: { recordId: AGENT_ID, actionName: 'view' } },
            replace: true
        });
    });

    it('uses URL defaults and opens the saved record', async () => {
        decodeDefaultFieldValues.mockReturnValue({ AgentDefinition__c: AGENT_ID });
        PlutoRecordModal.open.mockResolvedValue({ action: 'save', recordId: TOOL_ID });
        await render(newPage('AgentTool__c', { defaultFieldValues: 'AgentDefinition__c=' + AGENT_ID }));
        objectInfoAdapter.emit(TOOL_INFO);
        await flush();

        expect(PlutoRecordModal.open.mock.calls[0][0].defaultValues).toEqual({ AgentDefinition__c: AGENT_ID });
        expect(getNavigateCalledWith()).toEqual({ pageReference: recordPage(TOOL_ID, 'AgentTool__c', 'view'), replace: true });
    });

    it('returns to the parent from URL defaults on Cancel', async () => {
        decodeDefaultFieldValues.mockReturnValue({ AgentDefinition__c: AGENT_ID });
        PlutoRecordModal.open.mockResolvedValue({ action: 'cancel' });
        await render(newPage('AgentTool__c', { defaultFieldValues: 'AgentDefinition__c=' + AGENT_ID }));
        objectInfoAdapter.emit(TOOL_INFO);
        await flush();

        expect(getNavigateCalledWith().pageReference.attributes.recordId).toBe(AGENT_ID);
    });

    it('ignores an unreadable inContextOfRef and returns to the list on Cancel', async () => {
        PlutoRecordModal.open.mockResolvedValue({ action: 'cancel' });
        await render(newPage('AgentTool__c', { inContextOfRef: '1.not-base64-json' }));
        objectInfoAdapter.emit(TOOL_INFO);
        await flush();

        expect(PlutoRecordModal.open.mock.calls[0][0].defaultValues).toEqual({});
        expect(getNavigateCalledWith()).toEqual({
            pageReference: { type: 'standard__objectPage', attributes: { objectApiName: 'AgentTool__c', actionName: 'list' } },
            replace: true
        });
    });

    it('remounts the editor when the page moves to another record', async () => {
        const element = await render(recordPage(TOOL_ID, 'AgentTool__c', 'view'));
        const first = toolDetail(element);

        CurrentPageReference.emit(recordPage('a05000000000002AAA', 'AgentTool__c', 'view'));
        await Promise.resolve();
        await Promise.resolve();
        expect(toolDetail(element)).not.toBe(first);
        expect(toolDetail(element).recordId).toBe('a05000000000002AAA');
    });

    it('says so when placed on a page for another object', async () => {
        const element = await render(recordPage('a0A000000000001AAA', 'Account', 'view'));

        expect(element.shadowRoot.querySelector('[data-id="unsupported"]')).not.toBeNull();
    });

    it('opens no modal for an object Pluto does not edit', async () => {
        await render(recordPage('a0A000000000001AAA', 'Account', 'edit'));
        objectInfoAdapter.emit({ apiName: 'Account', label: 'Account', fields: {} });
        await flush();

        expect(PlutoRecordModal.open).not.toHaveBeenCalled();
    });
});
