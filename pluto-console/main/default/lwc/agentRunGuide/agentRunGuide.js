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

/**
 * Plain-language meaning and next step for the error codes an operator meets
 * on an Agent Run. Shared by Core's Operate action and any product UI that
 * explains a run, so every screen says the same thing about the same code.
 *
 * Pure functions only.
 */

/** Plain-language meaning and next step for the codes an operator meets most. */
const EXPLANATIONS = {
    APPROVAL_ASSIGNMENT_UNRESOLVED: {
        title: 'No one could approve this call',
        detail: 'The tool needs approval, but its approver setup resolved to nobody who may decide.',
        action: "Fix the tool's approver (or add a member with Agent Kernel Human Decision to its queue), then rescue the run."
    },
    BUDGET_EXCEEDED: {
        title: 'The run used its whole budget',
        detail: 'The agent needed more model calls, tool calls, or tokens than the agent allows. A conversational agent gets a fresh budget for each reply.',
        action: 'Raise Max Model Calls, Max Tool Calls, or Max Total Tokens on the agent if the extra work is expected, then rescue the run.'
    },
    DISPATCH_UNDELIVERABLE: {
        title: 'The next step never reached the execution user',
        detail: "Recovery sent the step several times, but it never started as the agent's execution user. The step did not run.",
        action: 'Check the Agent Execution Identity: its user is active, its Named Credential signs in as that user, and the person or schedule that starts work may use the credential. Then rescue the run.'
    },
    MODEL_REQUEST_BUDGET_EXCEEDED: {
        title: 'The model request is too large',
        detail: "The context and transcript exceed the agent's Max Model Request Characters.",
        action: 'Raise the limit or trim context providers, then rescue the run.'
    },
    MODEL_NOT_APPROVED: {
        title: 'The model is not approved',
        detail: "The agent's Agent Model record is inactive or incomplete.",
        action: 'Reactivate the model or choose another one on the agent, then rescue the run.'
    },
    MODEL_OUTPUT_SCHEMA_MISMATCH: {
        title: "The answer didn't match the output schema",
        detail: "The model's final answer kept failing the agent's output schema.",
        action: 'Check the schema and instructions, then rescue the run with guidance.'
    },
    MODEL_REFUSED: {
        title: 'The model declined',
        detail: 'The provider refused to answer this request.',
        action: 'Review the input and instructions before rescuing.'
    },
    MODEL_OUTPUT_TRUNCATED: {
        title: 'The answer was cut off',
        detail: 'The model hit its output token limit.',
        action: "Ask for a shorter answer in guidance, or raise Max Output Tokens on the agent's Agent Model."
    },
    TOOL_BINDING_CHANGED: {
        title: 'The tool changed after it was requested',
        detail: 'The tool was edited or deactivated between the request and the run.',
        action: 'Confirm the tool is correct, then rescue: the agent calls it again.'
    },
    TOOL_CONFIGURATION_ERROR: {
        title: 'The tool is misconfigured',
        detail: 'The tool could not start, or it tried something its tool type does not allow.',
        action: 'Fix the tool or its tool type, then rescue the run.'
    },
    TOOL_OUTCOME_UNKNOWN: {
        title: 'The tool result is unknown',
        detail: 'The tool may have acted, but the result could not be confirmed.',
        action: 'Check the target system, then reconcile what happened. Never repeat it just because no response arrived.'
    },
    UNKNOWN_UNRESOLVED: {
        title: 'Nobody reconciled an unknown tool result in time',
        detail: 'The run paused at its deadline so retention can clear its data. The call was not repeated.',
        action: 'Check the target system, then reconcile what happened. If the work is no longer needed, cancel the run.'
    },
    STALE_LEASE_OUTCOME_UNKNOWN: {
        title: 'The tool result is unknown',
        detail: 'A worker stopped while the tool was running.',
        action: 'Check the target system, then reconcile what happened.'
    },
    TRUST_PROTECTION_ERROR: {
        title: 'Protected values could not be used',
        detail: 'Sensitive values in the tool input could not be resolved for this tool.',
        action: "Check the tool's allowed data categories, then rescue the run."
    },
    TOOL_APPROVAL_DENIED: {
        title: 'The approver rejected the call',
        detail: 'The agent was told and continued without it.'
    },
    TOOL_APPROVAL_EXPIRED: {
        title: 'The approval expired',
        detail: 'No one decided before the approval timed out.'
    },
    RUN_PAUSED: {
        title: 'An operator paused the run',
        detail: 'Someone paused the run before its next step.',
        action: 'Rescue the run to continue, or cancel it.'
    },
    RETRY_EXHAUSTED: {
        title: 'Retries ran out',
        detail: 'The step kept failing with a temporary error.',
        action: 'Check the provider or target system, then rescue the run.'
    }
};

export function explain(code, message) {
    if (!code) {
        return null;
    }
    const known = EXPLANATIONS[code] || explainByPrefix(code);
    return {
        code,
        title: known ? known.title : sentence(code),
        detail: known ? known.detail : message || '',
        action: known ? known.action || '' : '',
        message: message || ''
    };
}

function explainByPrefix(code) {
    if (/^TOOL_AUTHORIZATION_POLICY/.test(code)) {
        return {
            title: 'The tool policy could not decide',
            detail: "The agent's tool authorization policy failed or returned no decision, so Core stopped safely.",
            action: 'Fix the policy class, then rescue the run.'
        };
    }
    if (/_API_(408|429|5\d\d)/.test(code)) {
        return {
            title: 'The model provider was unavailable',
            detail: 'The provider returned a temporary error.',
            action: 'Rescue the run once the provider recovers.'
        };
    }
    if (/_API_\d{3}/.test(code)) {
        return {
            title: 'The model provider rejected the request',
            detail: 'Check the Named Credential, the API key, and the model identifier.',
            action: 'Fix the model setup, then rescue the run.'
        };
    }
    return null;
}

/** TOOL_BATCH_NOT_ALLOWED -> "Tool batch not allowed". */
function sentence(code) {
    const words = String(code).replace(/[_-]+/g, ' ').trim().toLowerCase();
    return words.charAt(0).toUpperCase() + words.slice(1);
}
