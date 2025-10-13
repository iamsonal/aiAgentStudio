/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Generic outcome container for agent actions that provides explicit success/failure states.
 *              Replaces mixed error handling patterns with a unified approach.
 *              Includes LLM-friendly error formatting with emojis and contextual suggestions.
 * @author Sonal
 * @since 2025
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

    /**
     * @description Private constructor to enforce factory method usage
     */
    private ActionOutcome(Boolean isSuccess, Object data, String errorCode, String errorMessage) {
        this.isSuccess = isSuccess;
        this.data = data;
        this.errorCode = errorCode;
        this.errorMessage = errorMessage;
        this.llmFriendlyMessage = formatLLMFriendlyMessage(isSuccess, errorCode, errorMessage);
    }

    /**
     * @description Factory method for successful outcomes
     * @param data The success data to return
     * @return ActionOutcome instance representing success
     */
    public static ActionOutcome success(Object data) {
        return new ActionOutcome(true, data, null, null);
    }

    /**
     * @description Factory method for successful outcomes with no data
     * @return ActionOutcome instance representing success with null data
     */
    public static ActionOutcome success() {
        return success(null);
    }

    /**
     * @description Factory method for failure outcomes
     * @param errorCode Standardized error code from AIAgentConstants
     * @param errorMessage Detailed error message
     * @return ActionOutcome instance representing failure
     */
    public static ActionOutcome failure(String errorCode, String errorMessage) {
        return new ActionOutcome(false, null, errorCode, errorMessage);
    }

    /**
     * @description Factory method for failure outcomes with generic error code
     * @param errorMessage Detailed error message
     * @return ActionOutcome instance representing failure with generic error code
     */
    public static ActionOutcome failure(String errorMessage) {
        return failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, errorMessage);
    }

    /**
     * @description Creates LLM-friendly error messages with emojis and structured suggestions.
     * Sanitizes technical details and provides user-appropriate messaging.
     * @param isSuccess Whether the outcome was successful
     * @param errorCode The error code
     * @param errorMessage The detailed error message (may contain technical details)
     * @return Formatted message for LLM consumption, sanitized for end users
     */
    private String formatLLMFriendlyMessage(Boolean isSuccess, String errorCode, String errorMessage) {
        if (isSuccess) {
            return null; // No LLM message needed for success cases
        }

        String emoji = getErrorEmoji(errorCode);
        String userFriendlyError = sanitizeErrorMessage(errorCode, errorMessage);
        String suggestion = getErrorSuggestion(errorCode);

        return String.format('{0} **Error**: {1}\n\n**Suggestion**: {2}', new List<String>{ emoji, userFriendlyError, suggestion });
    }

    /**
     * @description Sanitizes technical error messages into user-friendly descriptions.
     * Removes stack traces, class names, IDs, and technical jargon while preserving
     * useful context like field names and validation issues.
     *
     * @param errorCode The error code to provide context-appropriate messaging
     * @param rawErrorMessage The raw technical error message
     * @return User-friendly error description
     */
    private String sanitizeErrorMessage(String errorCode, String rawErrorMessage) {
        if (String.isBlank(rawErrorMessage)) {
            return getDefaultErrorMessage(errorCode);
        }

        String sanitized = rawErrorMessage;

        // Remove stack traces (anything after "Stack Trace:" or similar)
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

        // Remove Class.method() references
        sanitized = sanitized.replaceAll('\\w+\\.\\w+\\(\\)', '');

        // Remove 18-character Salesforce IDs
        sanitized = sanitized.replaceAll('[a-zA-Z0-9]{18}', '[Record ID]');
        sanitized = sanitized.replaceAll('[a-zA-Z0-9]{15}', '[Record ID]');

        // Remove exception type names (e.g., "DmlException:", "QueryException:")
        sanitized = sanitized.replaceAll('\\w+Exception:\\s*', '');

        // Remove "System." prefixes
        sanitized = sanitized.replaceAll('System\\.', '');

        // Clean up common technical phrases with user-friendly alternatives
        sanitized = sanitized.replaceAll('(?i)insufficient access', 'you do not have permission');
        sanitized = sanitized.replaceAll('(?i)security enforced', 'permission check');
        sanitized = sanitized.replaceAll('(?i)field is not writeable', 'field cannot be modified');
        sanitized = sanitized.replaceAll('(?i)UNABLE_TO_LOCK_ROW', 'record is currently locked by another user');
        sanitized = sanitized.replaceAll('(?i)FIELD_CUSTOM_VALIDATION_EXCEPTION', 'a validation rule prevented this operation');
        sanitized = sanitized.replaceAll('(?i)REQUIRED_FIELD_MISSING', 'required field is missing');
        sanitized = sanitized.replaceAll('(?i)STRING_TOO_LONG', 'value exceeds maximum length');
        sanitized = sanitized.replaceAll('(?i)DUPLICATE_VALUE', 'duplicate value detected');

        // Limit length to avoid overwhelming the LLM with details
        if (sanitized.length() > 300) {
            sanitized = sanitized.substring(0, 297) + '...';
        }

        // If after sanitization the message is too short or empty, use default
        if (String.isBlank(sanitized) || sanitized.length() < 10) {
            return getDefaultErrorMessage(errorCode);
        }

        // Capitalize first letter and ensure proper sentence ending
        sanitized = sanitized.trim();
        if (!sanitized.endsWith('.') && !sanitized.endsWith('!') && !sanitized.endsWith('?')) {
            sanitized += '.';
        }
        if (sanitized.length() > 0) {
            sanitized = sanitized.substring(0, 1).toUpperCase() + sanitized.substring(1);
        }

        return sanitized;
    }

    /**
     * @description Provides default user-friendly error messages when raw message
     * is unavailable or too technical to sanitize effectively.
     *
     * @param errorCode The error code
     * @return Default user-friendly message for the error type
     */
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

    /**
     * @description Maps error codes to appropriate emojis for visual clarity
     * @param errorCode The error code to map
     * @return Appropriate emoji for the error type
     */
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

    /**
     * @description Override toString for debugging purposes
     * @return String representation of the ActionOutcome
     */
    public override String toString() {
        return String.format(
            'ActionOutcome[isSuccess={0}, errorCode={1}, errorMessage={2}]',
            new List<String>{ String.valueOf(this.isSuccess), this.errorCode, this.errorMessage }
        );
    }
}
