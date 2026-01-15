/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Generic outcome container for agent actions with explicit success/failure states. Provides unified error handling.
 */
public class ActionOutcome {
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
    private ActionOutcome(Boolean isSuccess, Object data, String errorCode, String errorMessage, String correctionGuidance) {
        this.isSuccess = isSuccess;
        this.data = data;
        this.errorCode = errorCode;
        this.errorMessage = errorMessage;
        this.correctionGuidance = correctionGuidance;
        this.llmFriendlyMessage = formatLLMFriendlyMessage(isSuccess, errorCode, errorMessage, correctionGuidance);
    }

    public static ActionOutcome success(Object data) {
        return new ActionOutcome(true, data, null, null, null);
    }

    public static ActionOutcome success() {
        return success(null);
    }

    public static ActionOutcome failure(String errorCode, String errorMessage) {
        return new ActionOutcome(false, null, errorCode, errorMessage, null);
    }

    public static ActionOutcome failureWithGuidance(String errorCode, String errorMessage, String correctionGuidance) {
        return new ActionOutcome(false, null, errorCode, errorMessage, correctionGuidance);
    }

    public static ActionOutcome failure(String errorMessage) {
        return failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, errorMessage);
    }

    private String formatLLMFriendlyMessage(Boolean isSuccess, String errorCode, String errorMessage, String correctionGuidance) {
        if (isSuccess) {
            return null; // No LLM message needed for success cases
        }

        String emoji = getErrorEmoji(errorCode);
        String userFriendlyError = sanitizeErrorMessage(errorCode, errorMessage);
        String suggestion = getErrorSuggestion(errorCode);

        if (String.isNotBlank(correctionGuidance)) {
            return String.format(
                '{0} **Error**: {1}\n\n**How to Fix**: {2}\n\n**Suggestion**: {3}',
                new List<String>{ emoji, userFriendlyError, correctionGuidance, suggestion }
            );
        }

        return String.format('{0} **Error**: {1}\n\n**Suggestion**: {2}', new List<String>{ emoji, userFriendlyError, suggestion });
    }

    private String sanitizeErrorMessage(String errorCode, String rawErrorMessage) {
        if (String.isBlank(rawErrorMessage)) {
            return getDefaultErrorMessage(errorCode);
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
        sanitized = sanitized.replaceAll('[a-zA-Z0-9]{18}', '[Record ID]');
        sanitized = sanitized.replaceAll('[a-zA-Z0-9]{15}', '[Record ID]');
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
            return getDefaultErrorMessage(errorCode);
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

    private String getDefaultErrorMessage(String errorCode) {
        if (errorCode == null) {
            return 'An unexpected error occurred while processing your request.';
        }

        switch on errorCode {
            when 'INPUT_VALIDATION' {
                return 'The provided information is invalid or incomplete.';
            }
            when 'CONFIG_ERROR' {
                return 'There is a configuration issue with this feature.';
            }
            when 'PERMISSION_DENIED' {
                return 'You do not have the necessary permissions to perform this action.';
            }
            when 'DML_ERROR' {
                return 'Unable to save the changes to the database.';
            }
            when 'SOQL_ERROR' {
                return 'Unable to retrieve the requested information from the database.';
            }
            when 'RECORD_NOT_FOUND' {
                return 'The requested record could not be found.';
            }
            when 'RECORD_LOCKED' {
                return 'This record is currently being edited by another user.';
            }
            when 'CONNECT_API_ERROR' {
                return 'Unable to connect to the external service.';
            }
            when 'LLM_CALL_FAILED' {
                return 'The AI service is temporarily unavailable.';
            }
            when 'ACTION_EXECUTION_FAILED' {
                return 'The requested action could not be completed.';
            }
            when 'FLOW_FAULT' {
                return 'An error occurred in the automated process flow.';
            }
            when 'MAX_TURNS_EXCEEDED' {
                return 'This conversation has exceeded the maximum allowed interactions.';
            }
            when 'SYSTEM_LIMIT_EXCEEDED' {
                return 'A system resource limit has been reached.';
            }
            when 'USER_REJECTED_ACTION' {
                return 'You declined to proceed with this action.';
            }
            when 'CONFIRMATION_TIMEOUT' {
                return 'The confirmation request timed out without a response.';
            }
            when 'CONFIRMATION_STATE_ERROR' {
                return 'There was an issue with the confirmation process.';
            }
            when 'COMPLETION_CAPABILITY_FAILED' {
                return 'Unable to complete the final step of this process.';
            }
            when 'ACTION_HANDLER_NULL_RESULT' {
                return 'The action completed but did not return expected results.';
            }
            when else {
                return 'An unexpected error occurred while processing your request.';
            }
        }
    }

    private String getErrorEmoji(String errorCode) {
        if (errorCode == null)
            return '⚠️';

        switch on errorCode {
            when 'INPUT_VALIDATION' {
                return '❌';
            }
            when 'CONFIG_ERROR' {
                return '⚙️';
            }
            when 'PERMISSION_DENIED' {
                return '🔒';
            }
            when 'DML_ERROR' {
                return '💾';
            }
            when 'SOQL_ERROR' {
                return '🗄️';
            }
            when 'RECORD_NOT_FOUND' {
                return '🔍';
            }
            when 'RECORD_LOCKED' {
                return '🔐';
            }
            when 'CONNECT_API_ERROR' {
                return '🔌';
            }
            when 'LLM_CALL_FAILED' {
                return '🤖';
            }
            when 'ACTION_EXECUTION_FAILED' {
                return '⚡';
            }
            when 'FLOW_FAULT' {
                return '🔄';
            }
            when 'MAX_TURNS_EXCEEDED' {
                return '🔢';
            }
            when 'SYSTEM_LIMIT_EXCEEDED' {
                return '⏱️';
            }
            when 'USER_REJECTED_ACTION' {
                return '🚫';
            }
            when 'CONFIRMATION_TIMEOUT' {
                return '⏰';
            }
            when 'CONFIRMATION_STATE_ERROR' {
                return '🔀';
            }
            when 'COMPLETION_CAPABILITY_FAILED' {
                return '🏁';
            }
            when 'ACTION_HANDLER_NULL_RESULT' {
                return '❓';
            }
            when 'UNEXPECTED_ERROR' {
                return '⚠️';
            }
            when else {
                return '⚠️';
            }
        }
    }

    /**
     * @description Provides contextual, actionable suggestions based on error type.
     * Each suggestion should guide the user or LLM toward resolution.
     *
     * @param errorCode The error code to provide suggestions for
     * @return Helpful suggestion text for the error type
     */
    private String getErrorSuggestion(String errorCode) {
        if (errorCode == null)
            return 'Please check the input parameters and try again.';

        switch on errorCode {
            when 'INPUT_VALIDATION' {
                return 'Verify all required fields are provided with valid values. Check for missing or incorrectly formatted data.';
            }
            when 'CONFIG_ERROR' {
                return 'This feature requires administrative configuration. Please contact your Salesforce administrator to review the setup.';
            }
            when 'PERMISSION_DENIED' {
                return 'You need additional permissions to perform this action. Contact your administrator to request access, or try a different approach.';
            }
            when 'DML_ERROR' {
                return 'Check for validation rules, required fields, duplicate values, or field permissions that may be preventing this operation.';
            }
            when 'SOQL_ERROR' {
                return 'Unable to retrieve data. Verify the record exists and you have permission to view it, or try refining your search criteria.';
            }
            when 'RECORD_NOT_FOUND' {
                return 'The record may have been deleted or you may not have access. Verify the record ID and your permissions.';
            }
            when 'RECORD_LOCKED' {
                return 'Please wait for the other user to finish their edits, or try again in a few moments.';
            }
            when 'CONNECT_API_ERROR' {
                return 'Check your internet connection or try again in a few moments. If the issue persists, contact your administrator.';
            }
            when 'LLM_CALL_FAILED' {
                return 'The AI service is experiencing issues. Please try again in a moment. If problems continue, contact your administrator.';
            }
            when 'ACTION_EXECUTION_FAILED' {
                return 'This action encountered an unexpected issue. Try rephrasing your request or breaking it into smaller steps.';
            }
            when 'FLOW_FAULT' {
                return 'The automated process encountered an error. Contact your administrator to review the flow configuration.';
            }
            when 'MAX_TURNS_EXCEEDED' {
                return 'This conversation is too long. Consider starting a new conversation or summarizing your remaining questions.';
            }
            when 'SYSTEM_LIMIT_EXCEEDED' {
                return 'A Salesforce resource limit was reached. Try simplifying your request or contact your administrator to review system limits.';
            }
            when 'USER_REJECTED_ACTION' {
                return 'You chose not to proceed. If you\'d like to try something else, let me know how I can help.';
            }
            when 'CONFIRMATION_TIMEOUT' {
                return 'The request for confirmation expired. If you\'d still like to proceed, please make the request again.';
            }
            when 'CONFIRMATION_STATE_ERROR' {
                return 'There was a problem processing your confirmation. Please try your request again from the beginning.';
            }
            when 'COMPLETION_CAPABILITY_FAILED' {
                return 'The final step couldn\'t be completed. The main work may have succeeded, but final notifications or updates failed.';
            }
            when 'ACTION_HANDLER_NULL_RESULT' {
                return 'The action completed but didn\'t provide expected results. This may indicate a configuration issue - contact your administrator.';
            }
            when 'UNEXPECTED_ERROR' {
                return 'An unexpected error occurred. Try rephrasing your request or contact your administrator if the issue continues.';
            }
            when else {
                return 'An unexpected error occurred. Please try again or contact your administrator if the issue persists.';
            }
        }
    }

    public override String toString() {
        return String.format(
            'ActionOutcome[isSuccess={0}, errorCode={1}, errorMessage={2}]',
            new List<String>{ String.valueOf(this.isSuccess), this.errorCode, this.errorMessage }
        );
    }
}
