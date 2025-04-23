/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Defines constants used throughout the AI Agent Framework, particularly for ProcessingStatus__c values.
 */
public inherited sharing class AIAgentConstants {
    public static final String STATUS_IDLE = 'Idle';
    public static final String STATUS_QUEUED_FOR_PROCESSING = 'QueuedForProcessing';
    public static final String STATUS_PREPARING_LLM_CALL = 'PreparingLLMCall';
    public static final String STATUS_AWAITING_LLM_RESPONSE = 'AwaitingLLMResponse';
    public static final String STATUS_PROCESSING_LLM_RESPONSE = 'ProcessingLLMResponse';
    public static final String STATUS_QUEUED_FOR_ACTION = 'QueuedForAction';
    public static final String STATUS_EXECUTING_ACTIONS = 'ExecutingActions';
    public static final String STATUS_AWAITING_ACTION_RESULT_LLM = 'AwaitingActionResultLLM';
    public static final String STATUS_FINALIZING = 'Finalizing';
    public static final String STATUS_FAILED = 'Failed';

    public static final String NEXT_EXPECTED_NONE = 'None';
    public static final String NEXT_EXPECTED_PREPARE_LLM = 'PrepareLLM';
    public static final String NEXT_EXPECTED_EXECUTE_LLM = 'ExecuteLLM';
    public static final String NEXT_EXPECTED_EXECUTE_ACTIONS = 'ExecuteActions';
    public static final String NEXT_EXPECTED_FINALIZE = 'Finalize';

    public static final String EVENT_STEP_PREPARE_LLM_WITH_RESULTS = 'PrepareLLMCallWithResults';

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
    public static final String ERR_CODE_UNEXPECTED_ERROR = 'UNEXPECTED_ERROR';
    public static final String ERR_CODE_ACTION_HANDLER_NULL_RESULT = 'ACTION_HANDLER_NULL_RESULT';
    public static final String ERR_CODE_SYSTEM_LIMIT = 'SYSTEM_LIMIT_EXCEEDED';
}
