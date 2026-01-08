/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIAgentConstants is the authoritative repository of all constants used throughout the AI Agent Framework.
 * Its responsibilities include:
 *   - Defining standardized values for processing statuses, conversation roles, error codes, and enumerations
 *   - Ensuring consistency, clarity, and maintainability across all framework components
 *   - Serving as a single source of truth for all static values referenced by triggers, services, and UI logic
 *
 * This class contains only static, immutable values and is not intended to be instantiated or extended.
 */
public inherited sharing class AIAgentConstants {
    public static final String STATUS_IDLE = 'Idle'; // Ready for new input or processing completed successfully (terminal state)
    public static final String STATUS_PROCESSING = 'Processing'; // Active processing in progress (LLM call, synchronous action execution)
    public static final String STATUS_AWAITING_ACTION = 'Awaiting Action'; // Action requested and queued for execution
    public static final String STATUS_AWAITING_FOLLOWUP = 'Awaiting Followup'; // Waiting for follow-up LLM interaction after action completion
    public static final String STATUS_FAILED = 'Failed'; // Terminal error state - unrecoverable failure occurred

    // Conversation Roles (used in LLM conversations)
    public static final String ROLE_USER = 'user'; // Message from the end user
    public static final String ROLE_ASSISTANT = 'assistant'; // Message from the AI agent
    public static final String ROLE_TOOL = 'tool'; // Tool execution result
    public static final String ROLE_SYSTEM = 'system'; // System prompts and instructions

    // Standardized Error Codes (for consistent error categorization)
    public static final String ERR_CODE_INPUT_VALIDATION = 'INPUT_VALIDATION'; // Invalid input parameters or data
    public static final String ERR_CODE_CONFIG_ERROR = 'CONFIG_ERROR'; // Configuration or setup issues
    public static final String ERR_CODE_PERMISSION_DENIED = 'PERMISSION_DENIED'; // Insufficient permissions or access denied
    public static final String ERR_CODE_DML_ERROR = 'DML_ERROR'; // Database operation failures
    public static final String ERR_CODE_SOQL_ERROR = 'SOQL_ERROR'; // Query execution failures (non-permission related)
    public static final String ERR_CODE_RECORD_NOT_FOUND = 'RECORD_NOT_FOUND'; // Required records not found
    public static final String ERR_CODE_RECORD_LOCKED = 'RECORD_LOCKED'; // Record locking conflicts
    public static final String ERR_CODE_CONNECT_API_ERROR = 'CONNECT_API_ERROR'; // External API callout failures (non-LLM)
    public static final String ERR_CODE_LLM_CALL_FAILED = 'LLM_CALL_FAILED'; // LLM communication failures after retries
    public static final String ERR_CODE_ACTION_EXECUTION = 'ACTION_EXECUTION_FAILED'; // Generic action execution failures
    public static final String ERR_CODE_FLOW_FAULT = 'FLOW_FAULT'; // Flow execution failures via fault path
    public static final String ERR_CODE_MAX_TURNS_EXCEEDED = 'MAX_TURNS_EXCEEDED'; // Conversation turn limit exceeded
    public static final String ERR_CODE_UNEXPECTED_ERROR = 'UNEXPECTED_ERROR'; // Unhandled or unexpected errors
    public static final String ERR_CODE_ACTION_HANDLER_NULL_RESULT = 'ACTION_HANDLER_NULL_RESULT'; // Action handler returned null
    public static final String ERR_CODE_SYSTEM_LIMIT = 'SYSTEM_LIMIT_EXCEEDED'; // Salesforce platform limits exceeded
    public static final String ERR_CODE_USER_REJECTED = 'USER_REJECTED_ACTION'; // User explicitly rejected an action
    public static final String ERR_CODE_CONFIRMATION_TIMEOUT = 'CONFIRMATION_TIMEOUT'; // User confirmation timed out
    public static final String ERR_CODE_CONFIRMATION_STATE_ERROR = 'CONFIRMATION_STATE_ERROR'; // Confirmation state inconsistency
    public static final String ERR_CODE_COMPLETION_CAPABILITY_FAILED = 'COMPLETION_CAPABILITY_FAILED'; // Completion capability execution failed
    public static final String ERR_CODE_TOOL_RECOVERY_VIOLATION = 'TOOL_RECOVERY_VIOLATION'; // Function agent violated strict recovery rules
    public static final String ERR_CODE_SAFETY_BLOCKED = 'SAFETY_BLOCKED'; // Message blocked by prompt safety service (jailbreak detection)
    public static final String ERR_CODE_SAFETY_FLAGGED = 'SAFETY_FLAGGED'; // Message flagged for review by prompt safety service

    // Miscellaneous
    public static final String NEXT_EXPECTED_NONE = 'None'; // Indicates no next expected action
}
