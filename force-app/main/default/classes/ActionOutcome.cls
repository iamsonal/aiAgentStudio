/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Generic outcome container for agent actions with explicit success/failure states.
 * Error attributes (category, default message, LLM guidance, transience) are driven by
 * ErrorHandlerConfig__mdt — one record per error code, keyed by DeveloperName.
 */
public inherited sharing class ActionOutcome {
    @AuraEnabled
    public Boolean isSuccess { get; private set; }

    @AuraEnabled
    public Object data { get; private set; }

    @AuraEnabled
    public String errorCode { get; private set; }

    @AuraEnabled
    public String errorMessage { get; private set; }

    @AuraEnabled
    public String llmFriendlyMessage { get; private set; }

    @AuraEnabled
    public String correctionGuidance { get; private set; }

    @AuraEnabled
    public String errorCategory { get; private set; }

    // ---------------------------------------------------------------------------
    // Metadata cache — zero-SOQL via getAll(), loaded once per transaction
    // ---------------------------------------------------------------------------
    @TestVisible
    private static Map<String, ErrorHandlerConfig__mdt> errorConfigCache;

    @TestVisible
    public static ErrorHandlerConfig__mdt getErrorConfig(String errorCode) {
        if (errorConfigCache == null) {
            errorConfigCache = ErrorHandlerConfig__mdt.getAll();
        }
        if (String.isBlank(errorCode)) {
            return errorConfigCache.get(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR);
        }
        ErrorHandlerConfig__mdt cfg = errorConfigCache.get(errorCode);
        return cfg != null ? cfg : errorConfigCache.get(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR);
    }

    // ---------------------------------------------------------------------------
    // Constructor (private — use factory methods)
    // ---------------------------------------------------------------------------
    private ActionOutcome(Boolean isSuccess, Object data, String errorCode, String errorMessage, String correctionGuidance) {
        this.isSuccess = isSuccess;
        this.data = data;
        this.errorCode = errorCode;
        this.errorMessage = errorMessage;

        if (!isSuccess) {
            ErrorHandlerConfig__mdt cfg = getErrorConfig(errorCode);
            this.errorCategory = cfg?.ErrorCategory__c ?? 'unknown';
            String effectiveGuidance = String.isNotBlank(correctionGuidance) ? correctionGuidance : cfg?.LLMGuidance__c;
            this.correctionGuidance = effectiveGuidance;
            this.llmFriendlyMessage = formatLLMFriendlyMessage(errorCode, errorMessage, effectiveGuidance);
        }
    }

    // ---------------------------------------------------------------------------
    // Factory API
    // ---------------------------------------------------------------------------

    public static ActionOutcome success(Object data) {
        return new ActionOutcome(true, data, null, null, null);
    }

    public static ActionOutcome success() {
        return success(null);
    }

    /**
     * @description Standard failure with error code, message, and optional correction guidance.
     * Category and default LLM guidance are resolved from ErrorHandlerConfig__mdt.
     * If correctionGuidance is provided it overrides the metadata default.
     */
    public static ActionOutcome failure(String errorCode, String errorMessage, String correctionGuidance) {
        return new ActionOutcome(false, null, errorCode, errorMessage, correctionGuidance);
    }

    public static ActionOutcome failure(String errorCode, String errorMessage) {
        return new ActionOutcome(false, null, errorCode, errorMessage, null);
    }

    // ---------------------------------------------------------------------------
    // Framework utility
    // ---------------------------------------------------------------------------

    /**
     * @description Resolves the error category for a given error code via metadata.
     * Used by framework services that need to persist the category to ExecutionStep__c.
     */
    public static String deriveCategory(String errorCode) {
        return getErrorConfig(errorCode)?.ErrorCategory__c ?? 'unknown';
    }

    /**
     * @description Returns whether the error code is classified as transient (can resolve on retry).
     * Used by shouldFailFast() to make machine-readable retry decisions independent of LLM text.
     */
    public static Boolean isTransient(String errorCode) {
        ErrorHandlerConfig__mdt cfg = getErrorConfig(errorCode);
        return cfg?.IsTransient__c == true;
    }

    /**
     * @description Creates an ActionOutcome from an exception, automatically classifying the
     * error code from the exception type. Category and LLM guidance are resolved from metadata.
     *
     * Use this in action catch blocks — no need to remember error codes:
     *   } catch (Exception e) {
     *       return ActionOutcome.fromException(e);
     *   }
     */
    public static ActionOutcome fromException(Exception ex) {
        return fromException(ex, null);
    }

    /**
     * @description Creates an ActionOutcome from an exception with optional domain-specific
     * correction guidance that overrides the metadata default.
     *
     *   } catch (Exception e) {
     *       return ActionOutcome.fromException(e, 'Failed to assign case to queue');
     *   }
     */
    public static ActionOutcome fromException(Exception ex, String correctionGuidance) {
        String errorCode = classifyException(ex);
        return failure(errorCode, ex.getMessage(), correctionGuidance);
    }

    /**
     * @description Maps a standard Apex exception type to the appropriate framework error code.
     * DmlException and QueryException are fully inspected (status codes, message content) so that
     * codes like RECORD_LOCKED and PERMISSION_DENIED are correctly classified regardless of whether
     * the exception is caught in action code or bubbles up through BaseAgentAction.
     */
    @TestVisible
    static String classifyException(Exception ex) {
        if (ex instanceof System.CalloutException)
            return AIAgentConstants.ERR_CODE_CONNECT_API_ERROR;
        if (ex instanceof System.LimitException)
            return AIAgentConstants.ERR_CODE_SYSTEM_LIMIT;
        if (ex instanceof System.MathException)
            return AIAgentConstants.ERR_CODE_ACTION_EXECUTION;
        if (ex instanceof System.NullPointerException)
            return AIAgentConstants.ERR_CODE_ACTION_EXECUTION;
        if (ex instanceof System.SObjectException)
            return AIAgentConstants.ERR_CODE_CONFIG_ERROR;
        if (ex instanceof System.TypeException)
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (ex instanceof System.JSONException)
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (ex instanceof System.NoAccessException)
            return AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
        if (ex instanceof System.SecurityException)
            return AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
        if (ex instanceof System.SearchException)
            return AIAgentConstants.ERR_CODE_SOQL_ERROR;
        if (ex instanceof System.ListException)
            return AIAgentConstants.ERR_CODE_ACTION_EXECUTION;
        if (ex instanceof System.StringException)
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;

        if (ex instanceof DmlException) {
            DmlException dmlEx = (DmlException) ex;
            String statusCode = dmlEx.getNumDml() > 0 ? dmlEx.getDmlStatusCode(0) : null;
            return classifyDmlStatusCode(statusCode);
        }

        if (ex instanceof System.QueryException) {
            String msgLower = ex.getMessage().toLowerCase();
            return (msgLower.contains('security enforced') || msgLower.contains('insufficient access'))
                ? AIAgentConstants.ERR_CODE_PERMISSION_DENIED
                : AIAgentConstants.ERR_CODE_SOQL_ERROR;
        }

        return AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;
    }

    /**
     * @description Maps a DML status code string to the appropriate framework error code.
     * Shared by classifyException() and BaseAgentAction.mapExceptionToOutcome() so that
     * DML classification is consistent whether exceptions are caught in action code or
     * bubble up through the framework.
     */
    public static String classifyDmlStatusCode(String statusCode) {
        if (statusCode == null)
            return AIAgentConstants.ERR_CODE_DML_ERROR;
        if (statusCode == 'UNABLE_TO_LOCK_ROW')
            return AIAgentConstants.ERR_CODE_RECORD_LOCKED;
        if (statusCode == 'FIELD_CUSTOM_VALIDATION_EXCEPTION')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCode == 'REQUIRED_FIELD_MISSING')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCode == 'INSUFFICIENT_ACCESS_OR_READONLY' || statusCode == 'CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY')
            return AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
        if (statusCode == 'INVALID_CROSS_REFERENCE_KEY' || statusCode == 'INVALID_FIELD_FOR_INSERT_UPDATE' || statusCode == 'INVALID_ID_FIELD')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCode == 'STRING_TOO_LONG')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCode == 'DUPLICATE_VALUE')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCode == 'FIELD_FILTER_VALIDATION_EXCEPTION')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCode == 'DELETE_FAILED')
            return AIAgentConstants.ERR_CODE_DML_ERROR;
        return AIAgentConstants.ERR_CODE_DML_ERROR;
    }

    // ---------------------------------------------------------------------------
    // Private formatting helpers
    // ---------------------------------------------------------------------------

    private String formatLLMFriendlyMessage(String errorCode, String errorMessage, String correctionGuidance) {
        String userFriendlyError = sanitizeErrorMessage(errorCode, errorMessage);

        if (String.isNotBlank(correctionGuidance)) {
            return String.format('**Error**: {0}\n\n**How to Fix**: {1}', new List<String>{ userFriendlyError, correctionGuidance });
        }

        return String.format('**Error**: {0}', new List<String>{ userFriendlyError });
    }

    private String sanitizeErrorMessage(String errorCode, String rawErrorMessage) {
        if (String.isBlank(rawErrorMessage)) {
            return getDefaultMessage(errorCode);
        }

        String sanitized = rawErrorMessage;

        if (sanitized.contains('Stack Trace:') || sanitized.contains('stack trace') || sanitized.contains('at line')) {
            Integer stackTraceIndex = sanitized.indexOf('Stack Trace:');
            if (stackTraceIndex == -1) {
                stackTraceIndex = sanitized.toLowerCase().indexOf('stack trace');
            }
            if (stackTraceIndex == -1) {
                stackTraceIndex = sanitized.indexOf('\nat ');
            }
            if (stackTraceIndex > 0) {
                sanitized = sanitized.substring(0, stackTraceIndex).trim();
            }
        }

        sanitized = sanitized.replaceAll('\\w+\\.\\w+\\(\\)', '');
        sanitized = sanitized.replaceAll('\\b[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?\\b', '[Record ID]');
        sanitized = sanitized.replaceAll('\\w+Exception:\\s*', '');
        sanitized = sanitized.replaceAll('System\\.', '');
        sanitized = sanitized.replaceAll('(?i)insufficient access', 'you do not have permission');
        sanitized = sanitized.replaceAll('(?i)security enforced', 'permission check');
        sanitized = sanitized.replaceAll('(?i)field is not writeable', 'field cannot be modified');
        sanitized = sanitized.replaceAll('(?i)UNABLE_TO_LOCK_ROW', 'record is currently locked by another user');
        sanitized = sanitized.replaceAll('(?i)FIELD_CUSTOM_VALIDATION_EXCEPTION', 'a validation rule prevented this operation');
        sanitized = sanitized.replaceAll('(?i)REQUIRED_FIELD_MISSING', 'required field is missing');
        sanitized = sanitized.replaceAll('(?i)STRING_TOO_LONG', 'value exceeds maximum length');
        sanitized = sanitized.replaceAll('(?i)DUPLICATE_VALUE', 'duplicate value detected');

        if (sanitized.length() > 300) {
            sanitized = sanitized.substring(0, 297) + '...';
        }

        if (String.isBlank(sanitized) || sanitized.length() < 10) {
            return getDefaultMessage(errorCode);
        }

        sanitized = sanitized.trim();
        if (!sanitized.endsWith('.') && !sanitized.endsWith('!') && !sanitized.endsWith('?')) {
            sanitized += '.';
        }
        if (sanitized.length() > 0) {
            sanitized = sanitized.substring(0, 1).toUpperCase() + sanitized.substring(1);
        }

        return sanitized;
    }

    private String getDefaultMessage(String errorCode) {
        ErrorHandlerConfig__mdt cfg = getErrorConfig(errorCode);
        return String.isNotBlank(cfg?.DefaultMessage__c) ? cfg.DefaultMessage__c : 'An unexpected error occurred while processing your request.';
    }

    public override String toString() {
        return String.format(
            'ActionOutcome[isSuccess={0}, errorCode={1}, errorCategory={2}, errorMessage={3}]',
            new List<String>{ String.valueOf(this.isSuccess), this.errorCode, this.errorCategory, this.errorMessage }
        );
    }
}
