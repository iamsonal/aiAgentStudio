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
import reviewRequest from '@salesforce/apex/AgentApprovalActions.reviewRequest';
import reviewInput from '@salesforce/apex/AgentApprovalActions.reviewInput';
import decideFromRecord from '@salesforce/apex/AgentApprovalActions.decideFromRecord';

/** What happens when nobody decides in time, by the approval's When Approval Expires value. */
const AFTER_DEADLINE = {
    'Deny and Continue': 'the request is rejected and the agent continues without it',
    'Pause for Operator': 'the agent pauses until an operator steps in'
};
const AFTER_OVERDUE = {
    'Deny and Continue': 'the agent continues without it',
    'Pause for Operator': 'the agent pauses until an operator steps in'
};

/** How a closed approval ended, by status. */
const OUTCOMES = {
    Approved: 'Approved',
    Rejected: 'Rejected',
    Expired: 'Expired. Nobody decided before the deadline.',
    Cancelled: 'Cancelled. The agent stopped before anyone decided.'
};

/** Colour and icon match the run story, so a rejection never reads like a request that went through. */
const OUTCOME_LOOKS = {
    Approved: { tone: 'success', icon: 'utility:success', effect: 'The agent was allowed to go ahead.' },
    Rejected: { tone: 'error', icon: 'utility:close', effect: 'The agent did not do this and continued without it.' },
    Expired: { tone: 'warning', icon: 'utility:clock' },
    Cancelled: { tone: 'neutral', icon: 'utility:ban' }
};

const DATE_FORMAT = { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' };

export default class AgentApprovalDecision extends LightningElement {
    _recordId;
    request;
    revealedInput;
    comment;
    loading = true;
    busy = false;
    errorMessage;
    rationaleExpanded = false;
    rationaleOverflows = false;

    // A quick action sets recordId after the component connects, so loading starts here.
    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.load();
        }
    }

    async load() {
        this.loading = true;
        this.errorMessage = undefined;
        try {
            this.request = await reviewRequest({ approvalId: this._recordId });
        } catch (error) {
            this.request = undefined;
            this.errorMessage = message(error, 'This request could not be loaded. Close this window and try again.');
        } finally {
            this.loading = false;
        }
    }

    get isPending() {
        return this.request?.status === 'Pending';
    }

    get isOverdue() {
        const expiresAt = this.request?.expiresAt;
        return this.isPending && Boolean(expiresAt) && new Date(expiresAt) <= new Date();
    }

    get canDecide() {
        return this.isPending && !this.isOverdue;
    }

    get isDecided() {
        return Boolean(this.request) && !this.isPending;
    }

    get title() {
        return this.request?.title || 'Agent request';
    }

    get agentName() {
        return this.request?.agentName || 'An agent';
    }

    // Expression text keeps its trailing space; LWC drops whitespace-only text between tags.
    get requestedBy() {
        return `Requested by ${this.agentName}${this.anchor ? ' for ' : ''}`;
    }

    get anchor() {
        return this.request?.anchor;
    }

    get anchorUrl() {
        return this.anchor?.name ? `/${this.anchor.recordId}` : undefined;
    }

    get anchorLabel() {
        return this.anchor ? `${this.anchor.objectLabel} ${this.anchor.name}` : undefined;
    }

    get inputs() {
        return (this.request?.inputs || []).map((input, index) => ({
            key: `${index}-${input.label}`,
            label: readable(input.label),
            value: input.value === null || input.value === undefined || input.value === '' ? '(empty)' : input.value
        }));
    }

    get hasInputs() {
        return this.inputs.length > 0;
    }

    get deadline() {
        const expiresAt = this.request?.expiresAt;
        if (!expiresAt) {
            return undefined;
        }
        if (this.isOverdue) {
            // Core refuses decisions after the deadline and closes the request on its next recovery pass.
            const next = AFTER_OVERDUE[this.request.expiryAction] || 'the request closes';
            return `The deadline passed on ${formatDate(expiresAt)}, so this request can no longer be approved or rejected. It closes shortly, and ${next}.`;
        }
        const after = AFTER_DEADLINE[this.request.expiryAction] || 'the request closes without a decision';
        return `If nobody decides by ${formatDate(expiresAt)}, ${after}.`;
    }

    /** How long is left, read once when the window opens; the full deadline is above the buttons. */
    get timeLeft() {
        const expiresAt = this.request?.expiresAt;
        if (!this.canDecide || !expiresAt) {
            return undefined;
        }
        return `Decide within ${formatRemaining(new Date(expiresAt) - new Date())}`;
    }

    get rationaleClass() {
        return this.rationaleExpanded ? 'rationale' : 'rationale rationale_clamped';
    }

    get showRationaleToggle() {
        return this.rationaleOverflows || this.rationaleExpanded;
    }

    get rationaleToggleLabel() {
        return this.rationaleExpanded ? 'Show less' : 'Show more';
    }

    handleRationaleToggle() {
        this.rationaleExpanded = !this.rationaleExpanded;
    }

    /** The explanation is cut to three lines; Show more appears only when the cut hides something. */
    renderedCallback() {
        const text = this.template.querySelector('.rationale_clamped');
        const overflows = Boolean(text) && text.scrollHeight > text.clientHeight + 1;
        if (text && overflows !== this.rationaleOverflows) {
            this.rationaleOverflows = overflows;
        }
    }

    get protectedHint() {
        return 'Values in double braces, such as {{EMAIL_1_…}}, hide personal data. Show them only if you need them to decide. Viewing them is recorded.';
    }

    get showRevealButton() {
        return this.request?.hasProtectedValues && !this.revealedInput;
    }

    get prettyRevealedInput() {
        try {
            return JSON.stringify(JSON.parse(this.revealedInput), null, 2);
        } catch (notJson) {
            return this.revealedInput;
        }
    }

    get outcome() {
        const request = this.request || {};
        const base = OUTCOMES[request.status] || request.status;
        if (request.status !== 'Approved' && request.status !== 'Rejected') {
            return base;
        }
        const by = request.decidedBy ? ` by ${request.decidedBy}` : '';
        const when = request.closedAt ? ` on ${formatDate(request.closedAt)}` : '';
        return `${base}${by}${when}.`;
    }

    get outcomeLook() {
        return OUTCOME_LOOKS[this.request?.status] || OUTCOME_LOOKS.Cancelled;
    }

    get outcomeClass() {
        return `outcome outcome_${this.outcomeLook.tone}`;
    }

    get outcomeIcon() {
        return this.outcomeLook.icon;
    }

    get outcomeEffect() {
        return this.outcomeLook.effect;
    }

    handleComment(event) {
        this.comment = event.target.value;
    }

    async handleReveal() {
        await this.run(async () => {
            this.revealedInput = (await reviewInput({ approvalId: this._recordId })) || '{}';
        });
    }

    handleApprove() {
        return this.decide(true);
    }

    handleReject() {
        return this.decide(false);
    }

    async decide(approved) {
        const decided = await this.run(() => decideFromRecord({ approvalId: this._recordId, approved, comment: this.comment }));
        if (decided) {
            await notifyRecordUpdateAvailable([{ recordId: this._recordId }]);
            this.dispatchEvent(
                new ShowToastEvent({
                    title: approved ? 'Approved' : 'Rejected',
                    message: approved ? 'The agent will go ahead.' : 'The agent will continue without it.',
                    variant: 'success'
                })
            );
            this.close();
        }
    }

    async run(action) {
        this.busy = true;
        this.errorMessage = undefined;
        try {
            await action();
            return true;
        } catch (error) {
            this.errorMessage = message(error, 'Your decision was not saved. Try again.');
            return false;
        } finally {
            this.busy = false;
        }
    }

    close() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}

function message(error, fallback) {
    return error?.body?.message || error?.message || fallback;
}

function formatDate(value) {
    return new Intl.DateTimeFormat(undefined, DATE_FORMAT).format(new Date(value));
}

/** 50 min, 3 h 10 min, or 2 days: enough to judge urgency at a glance. */
function formatRemaining(ms) {
    const minutes = Math.max(0, Math.floor(ms / 60000));
    if (minutes < 1) {
        return 'a minute';
    }
    if (minutes < 60) {
        return `${minutes} min`;
    }
    const hours = Math.floor(minutes / 60);
    if (hours < 48) {
        const rest = minutes % 60;
        return rest ? `${hours} h ${rest} min` : `${hours} h`;
    }
    return `${Math.floor(hours / 24)} days`;
}

/**
 * A tool's input names are written for the model, such as orderNumber or
 * order_number; the approver reads Order number. A label with spaces is
 * already written for people and stays as it is.
 */
function readable(label) {
    if (!label || /\s/.test(label)) {
        return label;
    }
    const words = label
        .replace(/__c$/i, '')
        .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
        .replace(/[_-]+/g, ' ')
        .trim()
        .split(' ')
        .map((word) => (word.length > 1 && word === word.toUpperCase() ? word : word.toLowerCase()))
        .join(' ');
    return words.charAt(0).toUpperCase() + words.slice(1);
}
