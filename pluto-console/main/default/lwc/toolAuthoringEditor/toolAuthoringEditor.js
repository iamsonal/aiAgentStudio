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
import LightningConfirm from 'lightning/confirm';
import getToolTypes from '@salesforce/apex/ToolAuthoringController.getToolTypes';
import loadTool from '@salesforce/apex/ToolAuthoringController.loadTool';
import describeDraft from '@salesforce/apex/ToolAuthoringController.describeDraft';
import getStartingFields from '@salesforce/apex/ToolAuthoringController.getStartingFields';
import ToolInputSchemaJsonModal from 'c/toolInputSchemaJsonModal';
import ToolJsonPreviewModal from 'c/toolJsonPreviewModal';
import { EMPTY_SCHEMA } from 'c/toolInputsBuilder';

const OVERRIDES = 'inputOverrides';
/** Core is asked soon after a click, and only once the admin stops typing. */
const DESCRIBE_DELAY = 300;
const TYPING_DELAY = 800;
/** Settings the admin types into, so each keystroke must not ask Core. */
const TYPED_SETTINGS = new Set(['query', 'string', 'text', 'textlist', 'keyvalues', 'json', 'integer', 'number']);
const TOOL_TARGETS = ['toolType', 'settings', 'tool', 'inputSchema'];
const IMPLEMENTATION_TYPES = [
    { value: 'Standard', label: 'Standard', description: 'Ready-made tools that read and change records or post to Chatter.' },
    { value: 'Flow', label: 'Flow', description: 'Runs an autolaunched Flow.' },
    { value: 'Apex', label: 'Apex', description: 'Runs Apex code, such as an API call or a tool a developer wrote.' }
];

/**
 * A tool's type, settings, and the inputs the model sees, as one draft:
 * { toolType, settings, inputSchema }. Core builds and checks everything;
 * each change asks Core what the draft gives the model, so the inputs and
 * JSON shown are always Core's. The hosting page saves the draft.
 */
export default class ToolAuthoringEditor extends LightningElement {
    @api disabled = false;
    /** Controlled by the hosting page header: view or edit. */
    @api editing = false;
    /** Renders without the outer card, as one section of the hosting page. */
    @api bare = false;

    toolTypes = [];
    _recordId;
    _connected = false;
    toolType = '';
    /** The Implementation Type the admin picked before a Tool Type; otherwise the Tool Type's own. */
    chosenImplementationType = '';
    settings = {};
    inputSchema = '';
    view = null;
    isLoading = false;
    showRequired = false;
    _describeTimer = null;
    _describeVersion = 0;
    /** True from a change until Core's answer for it arrives; the view shown until then is for the old draft. */
    checking = false;
    /**
     * Core's problems as last shown. They change only when Core answers, so
     * a problem with the old draft never flashes up and the page does not
     * jump while the admin types.
     */
    shownProblems = [];

    @wire(getToolTypes)
    wiredToolTypes({ data }) {
        if (data) {
            this.toolTypes = data;
        }
    }

    @api
    get recordId() {
        return this._recordId;
    }

    /** A new tool gets its Id when it is first saved; the editor then shows what was stored. */
    set recordId(value) {
        const changed = value !== this._recordId;
        this._recordId = value;
        if (changed && this._connected) {
            this.load();
        }
    }

    connectedCallback() {
        this._connected = true;
        this.load();
    }

    /** Shows what the server stored, after the hosting page saves. */
    @api
    reload() {
        return this.load();
    }

    disconnectedCallback() {
        this._connected = false;
        clearTimeout(this._describeTimer);
    }

    async load() {
        if (!this.recordId) {
            return;
        }
        this.isLoading = true;
        try {
            const state = await loadTool({ toolId: this.recordId });
            this.toolType = state.toolType || '';
            this.chosenImplementationType = '';
            this.settings = this.parse(state.implementationConfiguration);
            this.inputSchema = state.inputSchema || '';
            this.view = state.view;
        } catch (error) {
            this.view = { problems: [{ target: 'tool', message: this.messageOf(error) }], inputs: [], settings: [] };
        } finally {
            this.isLoading = false;
            this.showProblems();
        }
    }

    // ===== VIEW =====

    get articleClass() {
        return this.bare ? '' : 'slds-card';
    }

    get bodyClass() {
        return this.bare ? 'slds-is-relative' : 'slds-is-relative slds-card__body slds-card__body_inner';
    }

    get readOnly() {
        return !this.editing || this.disabled;
    }

    get implementationType() {
        const type = this.toolTypes.find((candidate) => candidate.value === this.toolType);
        return type ? type.implementationType : this.chosenImplementationType;
    }

    get implementationTypeOptions() {
        const offered = new Set(this.toolTypes.map((type) => type.implementationType));
        return IMPLEMENTATION_TYPES.filter((type) => offered.has(type.value));
    }

    get implementationTypeLabel() {
        return this.implementationType || '';
    }

    get hasImplementationType() {
        return !!this.implementationType;
    }

    get toolTypeOptions() {
        return this.toolTypes.filter((type) => type.implementationType === this.implementationType).map((type) => ({ label: type.label, value: type.value }));
    }

    get toolTypePlaceholder() {
        return this.hasImplementationType ? 'Choose what this tool does' : 'Choose an Implementation Type first';
    }

    get toolTypeDisabled() {
        return !this.hasImplementationType;
    }

    get toolTypeLabel() {
        const type = this.toolTypes.find((candidate) => candidate.value === this.toolType);
        return type ? type.label : this.toolType;
    }

    get hasToolType() {
        return !!this.toolType;
    }

    get buildsInputs() {
        return this.view?.buildsInputs === true;
    }

    get declaredSettings() {
        return this.view?.settings || [];
    }

    get undeclaredSettings() {
        return this.hasToolType && this.view?.declaresSettings === false;
    }

    get toolSectionClass() {
        return this.firstCheck ? 'slds-is-relative tool-section_loading' : 'slds-is-relative';
    }

    /** Core has not yet answered for this Tool Type, so its settings are not known. */
    get firstCheck() {
        return this.checking && !this.view;
    }

    get showCheckingSpinner() {
        return this.checking && !!this.view;
    }

    /** The admin writes this tool's inputs, and is editing them now. */
    get showInputsBuilder() {
        return this.hasToolType && !this.buildsInputs && !this.readOnly && !!this.view;
    }

    get showInputsList() {
        return this.hasToolType && !this.showInputsBuilder;
    }

    /** A tool that builds its inputs has none to show until its required settings are filled in. */
    get showWaitingNote() {
        return this.showInputsList && this.buildsInputs && this.requiredSettingMissing && !this.readOnly;
    }

    /** A tool Core could not build shows its problems above instead of an empty list. */
    get showBuiltInputs() {
        return this.showInputsList && !this.showWaitingNote && (this.inputs.length > 0 || !this.hasToolProblems);
    }

    get waitingNote() {
        return 'Fill in the required settings to see the inputs Pluto builds.';
    }

    get settingsWithoutOverrides() {
        const values = { ...this.settings };
        delete values[OVERRIDES];
        return values;
    }

    get overrides() {
        return this.settings[OVERRIDES] || {};
    }

    get inputs() {
        return this.view?.inputs || [];
    }

    get schemaJson() {
        return this.view?.schemaJson || '';
    }

    /**
     * Shows Core's problems with the draft once the admin has filled in the
     * required settings or tried to save. Until then a problem only repeats
     * that a setting is still empty, which the form already shows.
     */
    showProblems() {
        const problems = this.view?.problems || [];
        this.shownProblems = this.requiredSettingMissing && !this.showRequired ? problems.filter((problem) => problem.target === 'toolType') : problems;
    }

    get requiredSettingMissing() {
        return this.declaredSettings.some((setting) => setting.required && !this.isFilled(this.settings[setting.name]));
    }

    get toolTypeProblems() {
        return this.messagesFor((target) => target === 'toolType');
    }

    get toolTypeError() {
        return this.toolTypeProblems.join(' ');
    }

    /** Problems with the tool as a whole, in one place. Core can report one problem against both the settings and the inputs. */
    get toolProblems() {
        // A tool the admin has given no inputs yet saves as one that takes none, so "needs an Input Schema" is noise here.
        const skipInputSchema = this.showInputsBuilder && !this.inputSchema;
        const messages = this.messagesFor((target) => ['settings', 'tool'].includes(target) || (target === 'inputSchema' && !skipInputSchema));
        return [...new Set(messages)];
    }

    get hasToolProblems() {
        return this.toolProblems.length > 0;
    }

    get problemsByPath() {
        const byPath = {};
        this.shownProblems
            .filter((problem) => !TOOL_TARGETS.includes(problem.target))
            .forEach((problem) => {
                byPath[problem.target] = [...(byPath[problem.target] || []), problem.message];
            });
        return byPath;
    }

    get inputsHelp() {
        if (!this.buildsInputs) {
            return 'Pluto cannot work out what this tool takes, so you list the inputs. Give each one a name, a type, and a description the model reads.';
        }
        return 'Pluto builds these from the settings. Names and types come from Salesforce. You can reword a description, make an input required, limit its values, or lower its length limit.';
    }

    get showEditInputs() {
        return this.showInputsBuilder;
    }

    messagesFor(match) {
        return this.shownProblems.filter((problem) => match(problem.target)).map((problem) => problem.message);
    }

    // ===== CHANGES =====

    async handleImplementationTypeChange(event) {
        const next = event.detail.value;
        const combobox = event.target;
        if (next === this.implementationType) {
            return;
        }
        if (this.hasDraftWork() && !(await this.confirmReplace('Implementation Type'))) {
            combobox.value = this.implementationType;
            return;
        }
        this.chosenImplementationType = next;
        this.toolType = '';
        this.settings = {};
        this.inputSchema = '';
        this.view = null;
        this.shownProblems = [];
        // A type with one tool type, such as Flow's Run Flow, is chosen for the admin.
        const only = this.toolTypeOptions;
        if (only.length === 1) {
            this.toolType = only[0].value;
            this.describeNow();
        }
    }

    handleInputsBuilt(event) {
        this.inputSchema = event.detail.value || '';
        this.scheduleDescribe(TYPING_DELAY);
    }

    async handleToolTypeChange(event) {
        const next = event.detail.value;
        const combobox = event.target;
        if (next === this.toolType) {
            return;
        }
        if (this.hasDraftWork() && !(await this.confirmReplace('Tool Type'))) {
            combobox.value = this.toolType;
            return;
        }
        this.chosenImplementationType = this.implementationType;
        this.toolType = next;
        this.settings = {};
        this.inputSchema = '';
        this.view = null;
        this.shownProblems = [];
        this.describeNow();
    }

    async handleSettingChange(event) {
        const { name, value, revert } = event.detail;
        const setting = this.declaredSettings.find((candidate) => candidate.name === name);
        const dependents = this.declaredSettings.filter((candidate) => candidate.objectSetting === name);
        const next = { ...this.settings };
        if (setting?.type === 'object' && value !== this.settings[name]) {
            this.checking = true;
            const hasDependentWork = dependents.some((dependent) => this.isFilled(this.settings[dependent.name])) || this.hasOverrides();
            if (this.settings[name] && hasDependentWork && !(await this.confirmReplace('Object'))) {
                revert?.();
                this.settings = { ...this.settings };
                this.checking = false;
                return;
            }
            dependents.forEach((dependent) => delete next[dependent.name]);
            delete next[OVERRIDES];
            if (value) {
                const fieldsSetting = dependents.find((dependent) => dependent.type === 'fields');
                if (fieldsSetting) {
                    next[fieldsSetting.name] = await this.startingFields(value);
                }
            }
        }
        this.assign(next, name, value);
        this.settings = next;
        this.scheduleDescribe(this.isTyped(setting) ? TYPING_DELAY : DESCRIBE_DELAY);
    }

    handleSettingsReplace(event) {
        this.settings = { ...event.detail.value };
        this.scheduleDescribe(TYPING_DELAY);
    }

    handleOverridesChange(event) {
        const next = { ...this.settings };
        this.assign(next, OVERRIDES, Object.keys(event.detail.value).length ? event.detail.value : undefined);
        this.settings = next;
        this.scheduleDescribe();
    }

    async handleShowJson() {
        await ToolJsonPreviewModal.open({ size: 'medium', inputSchema: this.schemaJson });
    }

    async handleEditInputs() {
        await ToolInputSchemaJsonModal.open({
            size: 'large',
            inputSchema: this.inputSchema,
            readOnly: this.readOnly,
            applySchema: (json) => this.applyInputSchema(json)
        });
    }

    /** Asks Core about the pasted schema; keeps it only when Core has no problem with it. */
    async applyInputSchema(json) {
        const view = await describeDraft({ toolType: this.toolType, implementationConfiguration: this.configurationJson(), inputSchema: json });
        const problems = (view.problems || []).filter((problem) => problem.target === 'inputSchema').map((problem) => problem.message);
        if (problems.length) {
            return problems;
        }
        this.inputSchema = json;
        this.view = view;
        this.showProblems();
        const builder = this.template.querySelector('c-tool-inputs-builder');
        if (builder) {
            builder.value = json;
        }
        return [];
    }

    async startingFields(objectApiName) {
        try {
            return (await getStartingFields({ objectApiName, toolType: this.toolType })) || [];
        } catch (error) {
            return [];
        }
    }

    // ===== CORE =====

    scheduleDescribe(delay = DESCRIBE_DELAY) {
        this.checking = true;
        // A newer change makes any answer on its way stale.
        this._describeVersion++;
        clearTimeout(this._describeTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._describeTimer = setTimeout(() => this.describeNow(), delay);
    }

    async describeNow() {
        clearTimeout(this._describeTimer);
        if (!this.toolType) {
            this.checking = false;
            return;
        }
        const version = ++this._describeVersion;
        this.checking = true;
        try {
            const view = await describeDraft({
                toolType: this.toolType,
                implementationConfiguration: this.configurationJson(),
                inputSchema: this.buildsInputs ? null : this.inputSchema
            });
            // A later change wins over an answer that arrives late.
            if (version === this._describeVersion) {
                this.view = view;
                this.checking = false;
                this.showProblems();
            }
        } catch (error) {
            if (version === this._describeVersion) {
                this.view = { inputs: [], settings: [], ...(this.view || {}), problems: [{ target: 'tool', message: this.messageOf(error) }] };
                this.checking = false;
                this.showProblems();
            }
        }
    }

    /** The draft for the hosting page's one save, or null when a required setting is empty. */
    @api
    prepareDraft() {
        if (!this.toolType) {
            this.showRequired = true;
            return null;
        }
        if (this.requiredSettingMissing) {
            this.showRequired = true;
            this.showProblems();
            return null;
        }
        const builder = this.template.querySelector('c-tool-inputs-builder');
        if (builder && !builder.reportValidity()) {
            return null;
        }
        this.showRequired = false;
        return {
            toolType: this.toolType,
            implementationConfiguration: this.configurationJson(),
            // A tool the admin gave no inputs takes none.
            inputSchema: this.buildsInputs ? null : this.inputSchema || EMPTY_SCHEMA
        };
    }

    // ===== HELPERS =====

    configurationJson() {
        return Object.keys(this.settings).length ? JSON.stringify(this.settings) : null;
    }

    isTyped(setting) {
        return !!setting && TYPED_SETTINGS.has((setting.type || '').toLowerCase()) && !(setting.allowedValues || []).length;
    }

    hasDraftWork() {
        return Object.keys(this.settings).length > 0 || !!this.inputSchema;
    }

    hasOverrides() {
        return Object.keys(this.overrides).length > 0;
    }

    isFilled(value) {
        if (value === undefined || value === null || value === '') {
            return false;
        }
        if (Array.isArray(value)) {
            return value.length > 0;
        }
        return typeof value !== 'object' || Object.keys(value).length > 0;
    }

    assign(target, name, value) {
        if (value === undefined) {
            delete target[name];
        } else {
            target[name] = value;
        }
    }

    async confirmReplace(changed) {
        return LightningConfirm.open({
            message: `Changing the ${changed} clears the settings and input edits that depend on it.`,
            label: `Change ${changed}?`,
            theme: 'warning'
        });
    }

    parse(json) {
        if (!json) {
            return {};
        }
        try {
            const parsed = JSON.parse(json);
            return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
        } catch (error) {
            return {};
        }
    }

    messageOf(error) {
        return error?.body?.message || error?.message || 'Pluto could not read this tool.';
    }
}
