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

import { api } from 'lwc';
import LightningModal from 'lightning/modal';
import getTryState from '@salesforce/apex/ToolTryController.getTryState';
import tryTool from '@salesforce/apex/ToolTryController.tryTool';
import { parseSchema, buildSections, emptyValues, buildInput, valuesFromInput, fieldForProblem } from './inputForm';

/** Starts the error message that carries a dry run's result (ToolTryController.RESULT_MARKER). */
const RESULT_MARKER = 'PLUTO_DRY_RUN:';
const SALESFORCE_ID = /^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$/;
const MODE_OPTIONS = [
    { label: 'Form', value: 'form' },
    { label: 'JSON', value: 'json' }
];

/**
 * Try tool, in two screens: fill in what the agent would send, then run the
 * tool once and see what the agent would get back. Change input goes back
 * with the values kept. The server always answers with an error, so the
 * platform drops all the tool's work; a marked error carries the result.
 */
export default class ToolTryModal extends LightningModal {
    @api toolId;

    isLoading = true;
    isRunning = false;
    state = null;
    loadError = '';

    schema = null;
    formSections = [];
    values = {};
    fieldErrors = {};
    mode = 'form';
    jsonText = '{}';
    inputError = '';
    inputErrorHint = '';
    /** input, or result once a run has answered. */
    screen = 'input';

    recordId = '';
    lastRecordId = '';
    recordError = '';
    showMoreOptions = false;

    result = null;
    runError = '';
    lastInput = null;

    modeOptions = MODE_OPTIONS;

    /** Fields shown with an error, so a fixed field is cleared once. */
    _reportedPaths = new Set();

    connectedCallback() {
        this.load();
    }

    /** Shows each error on its own field, in the base components' own style, so a message never appears twice. */
    renderedCallback() {
        const errors = { ...this.fieldErrors, recordId: this.recordError };
        this.template.querySelectorAll('[data-path]').forEach((element) => {
            const path = element.dataset.path;
            const message = errors[path] || '';
            if (!message && !this._reportedPaths.has(path)) {
                return;
            }
            if (typeof element.setCustomValidity === 'function') {
                element.setCustomValidity(message);
            }
            if (typeof element.reportValidity === 'function') {
                element.reportValidity();
            }
            if (message) {
                this._reportedPaths.add(path);
            } else {
                this._reportedPaths.delete(path);
            }
        });
    }

    async load() {
        this.isLoading = true;
        try {
            this.state = await getTryState({ toolId: this.toolId });
            this.schema = parseSchema(this.state.inputSchema);
            this.formSections = buildSections(this.schema);
            this.values = emptyValues(this.formSections);
        } catch (error) {
            this.loadError = readMessage(error);
        } finally {
            this.isLoading = false;
        }
    }

    // ===== HEADER =====

    get headerLabel() {
        return this.state && this.state.toolName ? `Try ${this.state.toolName}` : 'Try tool';
    }

    get canTry() {
        return !!this.state && this.state.canTry === true;
    }

    get cannotTry() {
        return !!this.state && this.state.canTry !== true;
    }

    get dryRunNote() {
        return 'Dry run as you, even if the agent runs as an execution user. Every change is undone.';
    }

    get showResultScreen() {
        return this.screen === 'result';
    }

    get showApprovalNote() {
        return this.canTry && this.state.requiresApproval === true;
    }

    // ===== INPUT =====

    get isFormMode() {
        return this.mode === 'form';
    }

    get hasInputs() {
        return this.formSections.length > 0;
    }

    get sections() {
        return this.formSections.map((section) => ({
            ...section,
            hasHeading: !!section.heading,
            fields: section.fields.map((field) => {
                const error = this.fieldErrors[field.path] || '';
                return {
                    ...field,
                    value: this.values[field.path],
                    error,
                    isText: field.kind === 'text',
                    isNumber: field.kind === 'number',
                    isPicklist: field.kind === 'picklist',
                    isCheckbox: field.kind === 'checkbox',
                    isChoice: field.kind === 'choice',
                    isJson: field.kind === 'json',
                    picklistOptions: field.required ? field.options : [{ label: 'Not set', value: '' }, ...(field.options || [])],
                    choiceOptions: [
                        { label: 'Not set', value: '' },
                        { label: 'True', value: 'true' },
                        { label: 'False', value: 'false' }
                    ],
                    step: field.isInteger ? '1' : 'any',
                    jsonPlaceholder: field.isList ? '["first", "second"]' : '{ }'
                };
            })
        }));
    }

    get needsRecord() {
        return !!this.state && this.state.needsRecord === true;
    }

    get showRecordField() {
        return this.needsRecord || this.showMoreOptions;
    }

    get showMoreOptionsLink() {
        return !this.needsRecord && !this.showMoreOptions;
    }

    get recordHelp() {
        return this.needsRecord ? this.state.recordHelp : 'Only for tools that act on the record the agent was started from.';
    }

    handleFieldChange(event) {
        const path = event.target.dataset.path;
        const kind = event.target.dataset.kind;
        const value = kind === 'checkbox' ? event.target.checked : event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
        this.values = { ...this.values, [path]: value };
        if (this.fieldErrors[path]) {
            const remaining = { ...this.fieldErrors };
            delete remaining[path];
            this.fieldErrors = remaining;
        }
        this.clearInputError();
    }

    clearInputError() {
        this.inputError = '';
        this.inputErrorHint = '';
    }

    handleModeChange(event) {
        const next = event.detail.value;
        if (next === this.mode) {
            return;
        }
        if (next === 'json') {
            const { input } = buildInput(this.schema, this.formSections, this.values, false);
            this.jsonText = JSON.stringify(input, null, 2);
            this.clearInputError();
            this.mode = 'json';
            return;
        }
        let parsed;
        try {
            parsed = JSON.parse(this.jsonText || '{}');
        } catch (notJson) {
            this.inputError = 'Fix the JSON before switching to the form.';
            return;
        }
        const filled = valuesFromInput(this.formSections, parsed);
        if (filled.error) {
            this.inputError = filled.error;
            return;
        }
        this.values = filled.values;
        this.fieldErrors = {};
        this.clearInputError();
        this.mode = 'form';
    }

    handleJsonChange(event) {
        this.jsonText = event.target.value;
        this.clearInputError();
    }

    handleRecordIdChange(event) {
        this.recordId = (event.target.value || '').trim();
        this.recordError = '';
    }

    handleShowMoreOptions() {
        this.showMoreOptions = true;
    }

    /** Checks the form here first, so a missing value never costs a round trip. */
    readInput() {
        let input;
        if (this.isFormMode) {
            const built = buildInput(this.schema, this.formSections, this.values, true);
            this.fieldErrors = built.errors;
            if (Object.keys(built.errors).length > 0) {
                this.inputError = 'Fix the highlighted fields, then click Run.';
                return null;
            }
            input = JSON.stringify(built.input);
        } else {
            try {
                const parsed = JSON.parse(this.jsonText || '{}');
                if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
                    this.inputError = 'Tool input must be a JSON object, like { "subject": "Broken printer" }.';
                    return null;
                }
                input = JSON.stringify(parsed);
            } catch (notJson) {
                this.inputError = 'This is not valid JSON. Check for a missing quote, comma, or brace.';
                return null;
            }
        }
        if (this.needsRecord && !this.recordId) {
            this.recordError = 'Complete this field.';
            return null;
        }
        if (this.recordId && !SALESFORCE_ID.test(this.recordId)) {
            this.recordError = 'Enter a 15- or 18-character Salesforce Id.';
            return null;
        }
        return input;
    }

    // ===== RUN =====

    get runLabel() {
        return this.showResultScreen ? 'Run Again' : 'Run';
    }

    get runDisabled() {
        return !this.canTry || this.isRunning;
    }

    async handleRun() {
        this.clearInputError();
        this.recordError = '';
        this.runError = '';
        const input = this.readInput();
        if (input === null) {
            // The problem is on the input screen.
            this.screen = 'input';
            return;
        }
        this.lastInput = input;
        this.lastRecordId = this.recordId;
        this.isRunning = true;
        try {
            await tryTool({ toolId: this.toolId, input, recordId: this.recordId || null });
            // The server always answers with an error; a normal answer means the work was not undone as designed.
            this.result = null;
            this.runError = 'The dry run ended without undoing its work. Check the records this tool changes before trying again.';
            this.screen = 'result';
        } catch (error) {
            const message = readMessage(error);
            if (message.startsWith(RESULT_MARKER)) {
                this.showResult(JSON.parse(message.substring(RESULT_MARKER.length)));
            } else {
                this.result = null;
                this.runError = message;
                this.screen = 'result';
            }
        } finally {
            this.isRunning = false;
        }
    }

    /** A refused input never reached the tool, so it goes back on the input screen, on the field it is about. */
    showResult(result) {
        if (result.inputProblem) {
            this.result = null;
            this.screen = 'input';
            this.inputError = `The tool did not run: ${result.inputProblem}`;
            this.inputErrorHint = 'In a real run the agent gets this message and can correct its input.';
            if (this.isFormMode) {
                const problem = fieldForProblem(result.inputProblem, this.formSections);
                if (problem) {
                    this.fieldErrors = { ...this.fieldErrors, [problem.path]: problem.message };
                }
            }
            return;
        }
        this.result = result;
        this.screen = 'result';
    }

    handleBack() {
        this.screen = 'input';
    }

    // ===== RESULT =====

    get status() {
        const result = this.result || {};
        const look = (tone, label, icon) => ({ label, icon, bannerClass: `banner banner_${tone}`, iconClass: `banner__icon banner__icon_${tone}` });
        if (result.outcome === 'Waiting') {
            return look('info', 'Waiting for an answer', 'utility:clock');
        }
        if (result.outcome === 'Outcome Unknown') {
            return look('warning', 'Outcome unknown', 'utility:question');
        }
        return result.success ? look('success', 'Succeeded', 'utility:check') : look('error', 'Failed', 'utility:close');
    }

    get resultFacts() {
        const result = this.result || {};
        const changes = result.undoneRecordChanges || 0;
        const facts = [`${result.durationMs || 0} ms`, changes === 0 ? 'No record changes' : `${changes} record change${changes === 1 ? '' : 's'} undone`];
        if (result.ranAs) {
            facts.push(`Ran as ${result.ranAs}`);
        }
        return facts;
    }

    get problemText() {
        return (this.result && this.result.errorMessage) || '';
    }

    get summaryText() {
        const result = this.result || {};
        if (result.outcome === 'Retryable') {
            return 'In a real run, Core would try this call again.';
        }
        if (result.outcome === 'Outcome Unknown') {
            return 'In a real run, Core would stop and ask an admin to confirm what happened.';
        }
        if (result.outcome === 'Waiting') {
            return 'In a real run, the agent would wait for an outside answer.';
        }
        return result.success ? 'The agent gets the output below.' : 'The agent gets this error and decides what to do next.';
    }

    /** The input and record of the last run, so the result screen says what it answers. */
    get sentText() {
        let input = this.lastInput || '{}';
        try {
            input = JSON.stringify(JSON.parse(input), null, 2);
        } catch (notJson) {
            // Shown as sent.
        }
        return this.lastRecordId ? `${input}\n\nRecord: ${this.lastRecordId}` : input;
    }

    get hasNotUndone() {
        return !!this.result && Array.isArray(this.result.notUndone) && this.result.notUndone.length > 0;
    }

    get outputIsJson() {
        if (!this.result || !this.result.output) {
            return false;
        }
        try {
            JSON.parse(this.result.output);
            return true;
        } catch (notJson) {
            return false;
        }
    }

    get outputIsText() {
        return !!this.result && !!this.result.output && !this.outputIsJson;
    }

    handleClose() {
        this.close();
    }
}

function readMessage(error) {
    return (error && error.body && error.body.message) || (error && error.message) || 'Something went wrong.';
}
