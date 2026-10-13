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

import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getRunView from '@salesforce/apex/AgentRunOperatorController.getRunView';
import rescue from '@salesforce/apex/AgentRunOperatorController.rescue';
import pause from '@salesforce/apex/AgentRunOperatorController.pause';
import cancel from '@salesforce/apex/AgentRunOperatorController.cancel';
import reconcile from '@salesforce/apex/AgentRunOperatorController.reconcile';
import { explain } from 'c/agentRunGuide';

const ACTIONS = [
    {
        value: 'rescue',
        flag: 'canRescue',
        label: 'Rescue',
        description: 'Continue the run. The agent gets your guidance and picks up where it stopped.',
        submit: 'Rescue Run',
        done: 'Run rescued'
    },
    {
        value: 'reconcile',
        flag: 'canReconcile',
        label: 'Reconcile',
        description: 'Record what the unconfirmed tool call actually did.',
        submit: 'Record Outcome',
        done: 'Outcome recorded'
    },
    {
        value: 'pause',
        flag: 'canPause',
        label: 'Pause',
        description: 'Stop before the next step. You can rescue the run later.',
        submit: 'Pause Run',
        done: 'Run paused'
    },
    {
        value: 'cancel',
        flag: 'canCancel',
        label: 'Cancel',
        description: 'End the run for good. An approval it waits for closes without a decision, and the tool does not run. This cannot be undone.',
        submit: 'Cancel Run',
        done: 'Run cancelled',
        destructive: true
    }
];

/** How the run looks to an operator when no error explains it. */
const STATES = {
    Running: { tone: 'info', icon: 'utility:sync', title: 'Running', detail: 'The run is working. You can pause it before its next step or cancel it.' },
    Waiting: { tone: 'info', icon: 'utility:clock', title: 'Waiting', detail: 'The run continues when what it waits for arrives.' },
    Paused: { tone: 'warning', icon: 'utility:pause', title: 'Paused for an operator', detail: '' },
    Failed: { tone: 'error', icon: 'utility:error', title: 'The run failed', detail: '' },
    Succeeded: { tone: 'success', icon: 'utility:success', title: 'Finished', detail: 'The run completed. Nothing is left to do.' },
    Cancelled: { tone: 'neutral', icon: 'utility:ban', title: 'Cancelled', detail: 'The run was stopped and will not continue.' }
};

/** The limits a budget pause can name, in the words the agent's setup page uses. */
const LIMITS = [
    { key: 'model', label: 'Model calls', field: 'Max Model Calls', noun: 'model call', used: 'modelCalls', max: 'maxModelCalls' },
    { key: 'tool', label: 'Tool calls', field: 'Max Tool Calls', noun: 'tool call', used: 'toolCalls', max: 'maxToolCalls' },
    { key: 'token', label: 'Tokens', field: 'Max Total Tokens', noun: 'token', used: 'tokens', max: 'maxTokens' }
];

const DECISIONS = [
    { value: 'ConfirmFailed', label: 'It did not happen' },
    { value: 'ConfirmSucceeded', label: 'It happened' },
    { value: 'Retry', label: 'Run it again' }
];

export default class AgentRunOperations extends LightningElement {
    _recordId;
    view;
    action;
    decision = 'ConfirmFailed';
    values = {};
    pauseRun = false;
    safeToRetry = false;
    busy = false;
    errorMessage;

    // Quick actions set recordId after the first render. The template does not
    // read it, so no re-render follows; load when it arrives instead.
    @api
    get recordId() {
        return this._recordId;
    }

    set recordId(value) {
        const changed = value && value !== this._recordId;
        this._recordId = value;
        if (changed) {
            this.load();
        }
    }

    async load() {
        await this.run(async () => {
            this.view = await getRunView({ runId: this.recordId });
            const first = ACTIONS.find((candidate) => this.view[candidate.flag]);
            this.action = first ? first.value : undefined;
        });
    }

    get loading() {
        return this.busy && !this.view;
    }

    get availableActions() {
        return this.view ? ACTIONS.filter((candidate) => this.view[candidate.flag]) : [];
    }

    get actionOptions() {
        return this.availableActions.map(({ value, label }) => ({ value, label }));
    }

    /** What happened, in words, and what the operator should do about it. */
    get state() {
        const view = this.view || {};
        const base = STATES[view.status] || { tone: 'neutral', icon: 'utility:info', title: view.status, detail: '' };
        if (view.canReconcile) {
            return {
                ...base,
                tone: 'warning',
                icon: 'utility:question',
                title: 'A tool result needs checking',
                detail: `${this.unknownToolLabel} may have acted, but Core could not confirm it.`,
                action: 'Check the target system, then reconcile below.',
                code: view.errorCode,
                message: view.errorMessage
            };
        }
        if (view.status === 'Waiting') {
            return { ...base, detail: view.waitingReason || base.detail, until: waitsUntil(view.waitExpiresAt), action: '', code: '', message: '' };
        }
        if (view.budget) {
            const spent = this.spentLimits;
            return {
                ...base,
                title: spent.length ? `Out of ${joinWords(spent.map((limit) => limit.label.toLowerCase()))}` : 'The limits now allow the next step',
                detail: view.budget.perReply ? 'Counts are for this reply. A conversational agent gets a fresh budget for each reply.' : '',
                action: spent.length
                    ? `Raise ${joinWords(spent.map((limit) => limit.field))} on the agent, then rescue the run.`
                    : 'Rescue the run to continue.',
                code: view.errorCode,
                message: ''
            };
        }
        const explanation = (view.status === 'Paused' || view.status === 'Failed') && explain(view.errorCode, view.errorMessage);
        if (explanation) {
            return {
                ...base,
                title: explanation.title,
                detail: explanation.detail,
                action: explanation.action,
                code: explanation.code,
                message: explanation.detail === explanation.message ? '' : explanation.message
            };
        }
        return { ...base, action: '', code: '', message: '' };
    }

    get stateClass() {
        return `state state_${this.state.tone} slds-box slds-m-bottom_medium`;
    }

    /** Limits the run has used up; any of them pauses the run again, even when rescue itself fits. */
    get spentLimits() {
        const budget = this.view?.budget;
        return budget ? LIMITS.filter((limit) => budget[limit.max] != null && budget[limit.used] >= budget[limit.max]) : [];
    }

    get budgetRows() {
        const budget = this.view?.budget;
        if (!budget) {
            return undefined;
        }
        const spent = new Set(this.spentLimits.map((limit) => limit.key));
        return LIMITS.map((limit) => ({
            key: limit.key,
            label: limit.label,
            value: `${formatCount(budget[limit.used])} of ${formatCount(budget[limit.max])}`,
            valueClass: spent.has(limit.key) ? 'budget-value budget-value_spent' : 'budget-value'
        }));
    }

    /** Core refuses a rescue whose first step does not fit the budget; say so before the button is pressed. */
    get rescueBudgetNote() {
        const limit = LIMITS.find((candidate) => candidate.key === this.view?.budget?.rescueBlockedBy);
        if (!limit || !this.isRescue) {
            return undefined;
        }
        return `Rescue cannot start yet: the next step needs a ${limit.noun}, and none are left. Raise ${limit.field} on the agent, then check again.`;
    }

    get agentUrl() {
        return this.view?.agentId ? `/${this.view.agentId}` : undefined;
    }

    /** The badge adds the status only when the title has not already said it. */
    get showStatusBadge() {
        return Boolean(this.view?.status) && this.state.title !== this.view.status;
    }

    /** One choice needs no radio list: the button names it. */
    get hasChoice() {
        return this.availableActions.length > 1;
    }

    get stateIconVariant() {
        return ['warning', 'error', 'success'].includes(this.state.tone) ? this.state.tone : undefined;
    }

    get unknownToolLabel() {
        const name = this.view?.unknownToolName;
        return name ? name.replace(/_/g, ' ') : 'The tool';
    }

    get resultPlaceholder() {
        return '{"id": "..."}';
    }

    /** Decisions this operator may record: someone who cannot continue the run may only settle it as failed and paused. */
    get decisionOptions() {
        return this.mustPause ? DECISIONS.filter((option) => option.value === 'ConfirmFailed') : DECISIONS;
    }

    /** Only the person who started a run of an agent without an identity can continue it. */
    get continueBlockedReason() {
        return this.view?.rescueBlockedReason;
    }

    get mustPause() {
        return this.view?.canReconcileContinue === false;
    }

    get hasActions() {
        return this.availableActions.length > 0;
    }

    get isRescue() {
        return this.action === 'rescue';
    }

    get isPause() {
        return this.action === 'pause';
    }

    get isCancel() {
        return this.action === 'cancel';
    }

    get isReconcile() {
        return this.action === 'reconcile';
    }

    get isConfirmSucceeded() {
        return this.decision === 'ConfirmSucceeded';
    }

    get isConfirmFailed() {
        return this.decision === 'ConfirmFailed';
    }

    get isRetry() {
        return this.decision === 'Retry';
    }

    get selectedAction() {
        return ACTIONS.find((candidate) => candidate.value === this.action);
    }

    get submitLabel() {
        return this.busy ? 'Working…' : this.selectedAction?.submit || 'Submit';
    }

    get submitVariant() {
        return this.selectedAction?.destructive ? 'destructive' : 'brand';
    }

    get submitDisabled() {
        if (this.busy || !this.action || this.rescueBudgetNote) {
            return true;
        }
        if (this.isReconcile) {
            return !this.values.reason || (this.isRetry && !this.safeToRetry) || (this.isConfirmSucceeded && !this.values.confirmedOutput);
        }
        return false;
    }

    handleAction(event) {
        this.action = event.detail.value;
        this.values = {};
    }

    handleDecision(event) {
        this.decision = event.detail.value;
    }

    handleText(event) {
        this.values = { ...this.values, [event.target.dataset.field]: event.target.value };
    }

    handlePauseRun(event) {
        this.pauseRun = event.target.checked;
    }

    handleSafeToRetry(event) {
        this.safeToRetry = event.target.checked;
    }

    async handleSubmit() {
        const runId = this.recordId;
        const done = await this.run(async () => {
            if (this.isRescue) {
                await rescue({ runId, guidance: this.values.guidance });
            } else if (this.isPause) {
                await pause({ runId, reason: this.values.reason });
            } else if (this.isCancel) {
                await cancel({ runId, reason: this.values.reason });
            } else if (this.isReconcile) {
                await reconcile({
                    runId,
                    decision: this.decision,
                    reason: this.values.reason,
                    confirmedOutput: this.values.confirmedOutput,
                    failureMessage: this.values.failureMessage,
                    safeToRetry: this.safeToRetry,
                    pauseRun: this.mustPause || this.pauseRun
                });
            }
        });
        if (done) {
            await notifyRecordUpdateAvailable([{ recordId: runId }]);
            this.dispatchEvent(new ShowToastEvent({ title: this.selectedAction?.done || 'Done', variant: 'success' }));
            this.close();
        }
    }

    async run(work) {
        this.busy = true;
        this.errorMessage = undefined;
        try {
            await work();
            return true;
        } catch (error) {
            this.errorMessage = error?.body?.message || error?.message || 'The run could not be updated.';
            return false;
        } finally {
            this.busy = false;
        }
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}

const DATE_FORMAT = { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' };

function formatCount(value) {
    return value == null ? '—' : new Intl.NumberFormat().format(value);
}

function joinWords(words) {
    return words.length > 1 ? `${words.slice(0, -1).join(', ')} and ${words[words.length - 1]}` : words[0];
}

function waitsUntil(value) {
    return value ? `It waits until ${new Intl.DateTimeFormat(undefined, DATE_FORMAT).format(new Date(value))}.` : '';
}
