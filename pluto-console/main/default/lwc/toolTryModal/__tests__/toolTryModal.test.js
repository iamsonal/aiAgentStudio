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
import ToolTryModal from 'c/toolTryModal';
import getTryState from '@salesforce/apex/ToolTryController.getTryState';
import tryTool from '@salesforce/apex/ToolTryController.tryTool';

jest.mock('@salesforce/apex/ToolTryController.getTryState', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolTryController.tryTool', () => ({ default: jest.fn() }), { virtual: true });

const TOOL_ID = 'a00000000000000AAA';
const SCHEMA = JSON.stringify({
    type: 'object',
    properties: {
        recordData: {
            type: 'object',
            properties: { Subject: { type: 'string', description: 'Subject of the Case.' }, Priority: { type: 'string', enum: ['High', 'Low'] } },
            required: ['Subject']
        }
    },
    required: ['recordData']
});

async function flush() {
    await new Promise((resolve) => setTimeout(resolve, 0));
    await Promise.resolve();
}

async function open(state) {
    getTryState.mockResolvedValue({ toolName: 'create_case', canTry: true, inputSchema: SCHEMA, ...state });
    const element = createElement('c-tool-try-modal', { is: ToolTryModal });
    element.toolId = TOOL_ID;
    document.body.appendChild(element);
    await flush();
    return element;
}

const $ = (element, selector) => element.shadowRoot.querySelector(selector);
const runButton = (element) => [...element.shadowRoot.querySelectorAll('lightning-button')].find((button) => button.variant === 'brand');

function type(element, path, value) {
    const input = $(element, `[data-path="${path}"]`);
    input.value = value;
    input.dispatchEvent(new CustomEvent('change', { detail: { value } }));
}

function serverAnswer(result) {
    return { body: { message: 'PLUTO_DRY_RUN:' + JSON.stringify(result) } };
}

describe('c-tool-try-modal', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows a form built from the Input Schema, with the dry run explained up front', async () => {
        const element = await open({ requiresApproval: true });

        // The dry-run tagline is slotted into the header, which the Jest stub does not render.
        expect($(element, 'lightning-modal-header').label).toBe('Try create_case');
        expect($(element, '[data-approval-note]').textContent).toContain('skips approval');
        expect($(element, '.form-section__heading').textContent).toBe('recordData');
        const subject = $(element, '[data-path="recordData.Subject"]');
        expect(subject.label).toBe('Subject');
        expect(subject.required).toBe(true);
        expect(subject.fieldLevelHelp).toBe('Subject of the Case.');
        expect($(element, '[data-path="recordData.Priority"]').options.map((option) => option.value)).toEqual(['', 'High', 'Low']);
        expect($(element, '[data-result]')).toBeNull();
        expect(runButton(element).label).toBe('Run');
    });

    it('catches an empty required field before calling the server', async () => {
        const element = await open();

        runButton(element).click();
        await flush();

        expect(tryTool).not.toHaveBeenCalled();
        expect($(element, '[data-field="recordData.Subject"]').dataset.error).toBe('Complete this field.');
        expect($(element, '[data-input-error]').textContent).toContain('highlighted fields');
    });

    it('sends what the form says and shows what the agent gets back', async () => {
        const element = await open();
        tryTool.mockRejectedValue(serverAnswer({ success: true, output: '{"id":"500000000000001"}', durationMs: 42, undoneRecordChanges: 1, notUndone: [] }));
        type(element, 'recordData.Subject', 'Broken printer');

        runButton(element).click();
        await flush();

        expect(tryTool).toHaveBeenCalledWith({ toolId: TOOL_ID, input: '{"recordData":{"Subject":"Broken printer"}}', recordId: null });
        expect($(element, '[data-status]').textContent).toContain('Succeeded');
        expect($(element, '[data-result]').textContent).toContain('1 record change undone');
        expect($(element, 'c-tool-json-read-only-preview').value).toBe('{"id":"500000000000001"}');
        expect(runButton(element).label).toBe('Run Again');
        expect($(element, '[data-sent]').textContent).toContain('Broken printer');
        // The result is its own screen; Change input goes back with the values kept.
        expect($(element, '[data-path="recordData.Subject"]')).toBeNull();
        $(element, '[data-back]').click();
        await flush();
        expect($(element, '[data-path="recordData.Subject"]').value).toBe('Broken printer');
        expect(runButton(element).label).toBe('Run');
    });

    it('puts an input the server refused on the field it is about', async () => {
        const element = await open();
        tryTool.mockRejectedValue(serverAnswer({ success: false, inputProblem: 'Tool input.recordData.Subject must be a string.', notUndone: [] }));
        type(element, 'recordData.Subject', 'x');

        runButton(element).click();
        await flush();

        // The tool never ran, so the answer stays on the input screen.
        expect($(element, '[data-result]')).toBeNull();
        expect($(element, '[data-input-error]').textContent).toContain('The tool did not run');
        expect($(element, '[data-input-error]').textContent).toContain('can correct its input');
        expect($(element, '[data-field="recordData.Subject"]').dataset.error).toBe('This must be a string.');
    });

    it('shows a failure and any effect the dry run could not undo', async () => {
        const element = await open();
        tryTool.mockRejectedValue(
            serverAnswer({
                success: false,
                errorMessage: 'Subject is too long.',
                durationMs: 5,
                undoneRecordChanges: 0,
                notUndone: ['The tool published an immediate platform event.']
            })
        );
        type(element, 'recordData.Subject', 'x');

        runButton(element).click();
        await flush();

        expect($(element, '[data-status]').textContent).toContain('Failed');
        expect($(element, '[data-problem]').textContent).toContain('Subject is too long.');
        expect($(element, '[data-not-undone]').textContent).toContain('immediate platform event');
    });

    it('switches to JSON with the values typed so far, and back', async () => {
        const element = await open();
        type(element, 'recordData.Subject', 'Broken printer');

        $(element, 'lightning-radio-group').dispatchEvent(new CustomEvent('change', { detail: { value: 'json' } }));
        await flush();
        const json = $(element, 'lightning-textarea');
        expect(JSON.parse(json.value)).toEqual({ recordData: { Subject: 'Broken printer' } });

        json.value = '{"recordData":{"Subject":"Edited"},"extra":1}';
        json.dispatchEvent(new CustomEvent('change'));
        $(element, 'lightning-radio-group').dispatchEvent(new CustomEvent('change', { detail: { value: 'form' } }));
        await flush();
        expect($(element, '[data-input-error]').textContent).toContain('no field for extra');

        json.value = '{"recordData":{"Subject":"Edited"}}';
        json.dispatchEvent(new CustomEvent('change'));
        $(element, 'lightning-radio-group').dispatchEvent(new CustomEvent('change', { detail: { value: 'form' } }));
        await flush();
        expect($(element, '[data-path="recordData.Subject"]').value).toBe('Edited');
    });

    it('asks for the record when the tool acts on it, and checks the Id first', async () => {
        const element = await open({ needsRecord: true, recordHelp: 'This tool reads or changes the record the agent is working on.' });
        type(element, 'recordData.Subject', 'x');
        const record = $(element, '[data-path="recordId"]');
        expect(record.required).toBe(true);
        expect(record.fieldLevelHelp).toContain('record the agent is working on');

        record.value = '123';
        record.dispatchEvent(new CustomEvent('change'));
        runButton(element).click();
        await flush();

        expect(tryTool).not.toHaveBeenCalled();
        expect($(element, '[data-error="Enter a 15- or 18-character Salesforce Id."]')).not.toBeNull();
    });

    it('keeps the record field out of the way for tools that do not use it', async () => {
        const element = await open();
        expect($(element, '[data-path="recordId"]')).toBeNull();

        [...element.shadowRoot.querySelectorAll('lightning-button')].find((button) => button.label === 'Add the record the agent is working on').click();
        await flush();
        expect($(element, '[data-path="recordId"]').required).toBe(false);
    });

    it('says when a tool takes no input', async () => {
        const element = await open({ inputSchema: '{"type":"object","properties":{}}' });
        expect($(element, '[data-no-inputs]')).not.toBeNull();
    });

    it('shows a plain server error, such as a missing permission, on the result screen', async () => {
        const element = await open();
        tryTool.mockRejectedValue({ body: { message: 'You need permission to edit Agent Tools to try one.' } });
        type(element, 'recordData.Subject', 'x');

        runButton(element).click();
        await flush();

        expect($(element, '[data-run-error]').textContent).toContain('permission to edit Agent Tools');
        expect($(element, '[data-status]')).toBeNull();
    });

    it('explains why a tool that reaches outside Salesforce cannot be tried, and offers no run', async () => {
        const element = await open({ canTry: false, reason: 'This tool changes things outside Salesforce, so a dry run cannot undo it.' });

        expect($(element, '[data-cannot-try]').textContent).toContain('outside Salesforce');
        expect(runButton(element)).toBeUndefined();
    });

    it('says who the tool ran as', async () => {
        const element = await open({});
        tryTool.mockRejectedValue(serverAnswer({ success: true, output: 'done', durationMs: 9, undoneRecordChanges: 0, ranAs: 'Ada Admin', notUndone: [] }));
        type(element, 'recordData.Subject', 'Broken printer');

        runButton(element).click();
        await flush();

        expect(tryTool).toHaveBeenCalledWith({ toolId: TOOL_ID, input: '{"recordData":{"Subject":"Broken printer"}}', recordId: null });
        expect($(element, '[data-run-as]')).toBeNull();
        expect($(element, '[data-result]').textContent).toContain('Ran as Ada Admin');
    });
});
