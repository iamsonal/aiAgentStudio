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
