/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Authoritative repository of all constants used throughout the AI Agent Framework.
 */
public inherited sharing class AIAgentConstants {
    public static final String STATUS_IDLE = 'Idle';
    public static final String STATUS_PROCESSING = 'Processing';
    public static final String STATUS_AWAITING_ACTION = 'Awaiting Action';
    public static final String STATUS_AWAITING_FOLLOWUP = 'Awaiting Followup';
    public static final String STATUS_FAILED = 'Failed';

    public static final String ROLE_USER = 'user';
    public static final String ROLE_ASSISTANT = 'assistant';
    public static final String ROLE_TOOL = 'tool';
    public static final String ROLE_SYSTEM = 'system';

    public static final String ERR_CODE_INPUT_VALIDATION = 'INPUT_VALIDATION';
    public static final String ERR_CODE_CONFIG_ERROR = 'CONFIG_ERROR';
    public static final String ERR_CODE_PERMISSION_DENIED = 'PERMISSION_DENIED';
    public static final String ERR_CODE_DML_ERROR = 'DML_ERROR';
    public static final String ERR_CODE_SOQL_ERROR = 'SOQL_ERROR';
    public static final String ERR_CODE_RECORD_NOT_FOUND = 'RECORD_NOT_FOUND';
    public static final String ERR_CODE_RECORD_LOCKED = 'RECORD_LOCKED';
    public static final String ERR_CODE_CONNECT_API_ERROR = 'CONNECT_API_ERROR';
    public static final String ERR_CODE_LLM_CALL_FAILED = 'LLM_CALL_FAILED';
    public static final String ERR_CODE_ACTION_EXECUTION = 'ACTION_EXECUTION_FAILED';
    public static final String ERR_CODE_FLOW_FAULT = 'FLOW_FAULT';
    public static final String ERR_CODE_MAX_TURNS_EXCEEDED = 'MAX_TURNS_EXCEEDED';
    public static final String ERR_CODE_UNEXPECTED_ERROR = 'UNEXPECTED_ERROR';
    public static final String ERR_CODE_ACTION_HANDLER_NULL_RESULT = 'ACTION_HANDLER_NULL_RESULT';
    public static final String ERR_CODE_SYSTEM_LIMIT = 'SYSTEM_LIMIT_EXCEEDED';
    public static final String ERR_CODE_USER_REJECTED = 'USER_REJECTED_ACTION';
    public static final String ERR_CODE_CONFIRMATION_TIMEOUT = 'CONFIRMATION_TIMEOUT';
    public static final String ERR_CODE_CONFIRMATION_STATE_ERROR = 'CONFIRMATION_STATE_ERROR';
    public static final String ERR_CODE_COMPLETION_CAPABILITY_FAILED = 'COMPLETION_CAPABILITY_FAILED';
    public static final String ERR_CODE_TOOL_RECOVERY_VIOLATION = 'TOOL_RECOVERY_VIOLATION';
    public static final String ERR_CODE_SAFETY_BLOCKED = 'SAFETY_BLOCKED';
    public static final String ERR_CODE_SAFETY_FLAGGED = 'SAFETY_FLAGGED';
    public static final String ERR_CODE_DEPENDENCY_VALIDATION = 'DEPENDENCY_VALIDATION_ERROR';

    public static final String NEXT_EXPECTED_NONE = 'None';

    /**
     * Patterns stripped from user-controlled context data (Salesforce field values, context provider
     * output) before that data is embedded in the LLM system prompt.
     *
     * These are known prompt-injection payload markers: LLM role-boundary tokens, chat-template
     * delimiters, and separator sequences commonly used to fake section boundaries in adversarial
     * record field values.  The list is intentionally kept here so it can be reviewed, audited, and
     * extended in one place without touching application logic.
     *
     * Stripping is applied AFTER serialisation (JSON/YAML) and BEFORE XML-delimiter wrapping, so it
     * covers all format strategies without modifying ContextFormattingService.
     */
    // ── Prompt section headers ────────────────────────────────────────────────
    public static final String PROMPT_SECTION_CRITICAL_INSTRUCTIONS = '\n\n# CRITICAL INSTRUCTIONS\n\n';
    public static final String PROMPT_SECTION_CONFIDENCE_GUIDANCE = '\n\n# CONFIDENCE GUIDANCE\n\n';
    public static final String PROMPT_SECTION_FINAL_INSTRUCTIONS = '\n\n# FINAL INSTRUCTIONS\n\n';

    // ── LLM instruction bodies ────────────────────────────────────────────────
    public static final String PROMPT_ERROR_RECOVERY =
        'The last tool you tried to use failed. Inform the user of this failure based on the history. ' +
        'Then, check if you have an alternative tool and propose it as the next step. ' +
        'Do not use any tools now; only generate a text response.';

    public static final String PROMPT_CONFIDENCE_GUIDANCE_CONVERSATIONAL =
        'Always report an honest confidence score that reflects your actual certainty. ' +
        'If you are missing key information or have significant ambiguity about a tool call, ' +
        'ask the user for clarification rather than proceeding with incomplete data.';

    public static final String PROMPT_CONFIDENCE_GUIDANCE_EMAIL =
        'Always report an honest confidence score that reflects your actual certainty. ' +
        'If you are missing key information or have significant ambiguity about a tool call, ' +
        'request the missing details in your email reply rather than proceeding with incomplete data.';

    public static final String PROMPT_CONFIDENCE_GUIDANCE_FUNCTION =
        'Always report an honest confidence score that reflects your actual certainty. ' +
        'If you are uncertain or missing information needed for a tool call, ' +
        'use available lookup or search tools to gather additional context before proceeding.';

    public static final String PROMPT_FOLLOWUP_SUMMARIZE =
        'You have just completed one or more tool actions that the user did not see. ' +
        'Your task is to synthesize the results of all actions into a single, user-friendly summary. ' +
        'This will be the only message the user sees for this turn. ' +
        'Do not ask questions; provide a conclusive, final response.';

    // ── Tool parameter descriptions (injected into tool schemas) ─────────────
    public static final String TOOL_PARAM_DESC_RATIONALE =
        'REQUIRED: Explain step-by-step WHY you are selecting this specific tool and how it directly ' +
        'addresses the user\'s request. Be specific about what user need this tool fulfills.';

    public static final String TOOL_PARAM_DESC_REQUIRES_APPROVAL =
        'Set to true if this action requires manager approval based on the conditional approval rules in ' +
        'the capability description. Analyze the context data (account revenue, risk level, transaction ' +
        'amount, etc.) to determine if approval is needed per the rules specified.';

    public static final String TOOL_PARAM_DESC_APPROVAL_REASON =
        'REQUIRED when _requiresApproval=true. Provide a clear, specific explanation of why approval is ' +
        'needed, referencing the relevant approval rule and including concrete data points (e.g., ' +
        '"Enterprise account with $75M annual revenue exceeds $50M approval threshold. Strategic $500k ' +
        'deal with CEO engagement."). This explanation will be shown to the approver.';

    public static final String TOOL_PARAM_DESC_CONFIDENCE_PREFIX =
        'REQUIRED: Your confidence score for this action (0-100). Consider: Do you have all needed data? ' +
        'Are the parameters clear and valid? Is this the right tool for the task? Are there any ambiguities? ' +
        'Rate your certainty: ';

    public static final String TOOL_PARAM_DESC_NEXT_STEP =
        'OPTIONAL: Suggest the next logical action in 5-10 words (e.g., "Schedule follow-up call" or ' +
        '"Send welcome email"). You may reference a tool name or describe a general business action. ' +
        'This is experimental and used for analytics only.';

    public static final String TOOL_HITL_CONFIRMATION_SUFFIX = '\n\nRequires user confirmation before execution.';

    // ── Synthetic tool result messages ────────────────────────────────────────
    // Use String.format() with these templates — {0} = toolName, {1} = confidenceScore
    public static final String TOOL_RESULT_CONFIDENCE_BLOCKED_TEMPLATE =
        'Tool call to \'{0}\' was blocked due to insufficient confidence (score: {1}). ' + 'Gather more information or ask for clarification before retrying.';

    public static final String TOOL_RESULT_PENDING_APPROVAL = 'This action is pending approval. It will be executed once approved.';

    // ── Retry enforcement step content ────────────────────────────────────────
    public static final String PROMPT_RETRY_ENFORCEMENT_HEADER = '[Framework] The following tool(s) failed with retryable errors and were not retried.';
    public static final String PROMPT_RETRY_ENFORCEMENT_DIRECTIVE = 'You MUST call each tool again with its original arguments before completing.';

    // ── Context warning fragments (embedded in system prompt) ─────────────────
    // Use String.format() with PROMPT_CONTEXT_FORMAT_WARN_TEMPLATE — {0} = error message
    public static final String PROMPT_CONTEXT_FORMAT_WARN_TEMPLATE = '<CONTEXT_WARNING>Context formatting failed: {0}. Responses may lack full record details.</CONTEXT_WARNING>';
    public static final String PROMPT_CONTEXT_LOAD_WARN = '<CONTEXT_WARNING>Context data could not be loaded. Proceed with the information available.</CONTEXT_WARNING>';

    // ── Approval confirmation (user-facing assistant message) ─────────────────
    // Use String.format() — {0} = toolName
    public static final String MSG_APPROVAL_SUBMITTED_TEMPLATE = 'I\'ve submitted your request to {0} for approval. You\'ll be notified when it\'s processed. Feel free to continue our conversation.';

    // ── Fallback error messages (included in tool result JSON sent to LLM) ────
    public static final String ERR_MSG_NULL_OUTCOME = 'Action execution did not return an outcome.';
    public static final String ERR_MSG_UNEXPECTED = 'An unexpected error occurred.';
    public static final String ERR_MSG_SERIALIZE_FAILED = 'Failed to serialize action result.';

    public static final List<String> PROMPT_INJECTION_PATTERNS = new List<String>{
        '<|im_start|>', // ChatML system/user/assistant role boundary (OpenAI tiktoken format)
        '<|im_end|>', // ChatML end-of-turn marker
        '<|endoftext|>', // GPT-2/3 special end-of-document token
        '[INST]', // Llama 2 / Mistral instruction open tag
        '[/INST]', // Llama 2 / Mistral instruction close tag
        '<<SYS>>', // Llama 2 system block open tag
        '<</SYS>>', // Llama 2 system block close tag
        '###', // Few-shot separator widely used in injection payloads
        '\n---\n' // Markdown horizontal rule used to fake prompt section boundaries
    };
}
