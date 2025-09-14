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
 *              Includes LLM-friendly error formatting and ActionResult conversion for framework compatibility.
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
     * @description Converts ActionOutcome to ActionResult for framework compatibility
     * @param actionName Optional action name for context (can be null)
     * @return ActionResult instance for orchestration service
     */
    public ActionResult toActionResult(String actionName) {
        if (this.isSuccess) {
            // For successful results, return the data with appropriate message extraction
            return new ActionResult(this.data, 'Action completed successfully');
        } else {
            // For failed results, create structured error output
            Map<String, Object> errorOutput = new Map<String, Object>{
                'success' => false,
                'errorCode' => this.errorCode,
                'messageForUser' => this.llmFriendlyMessage,
                'data' => new Map<String, Object>()
            };

            return new ActionResult(errorOutput, this.errorMessage, this.errorCode);
        }
    }

    /**
     * @description Converts ActionOutcome to ActionResult for framework compatibility (overloaded method)
     * @return ActionResult instance for orchestration service
     */
    public ActionResult toActionResult() {
        return toActionResult(null);
    }

    /**
     * @description Creates LLM-friendly error messages with emojis and structured suggestions
     * @param isSuccess Whether the outcome was successful
     * @param errorCode The error code
     * @param errorMessage The detailed error message
     * @return Formatted message for LLM consumption
     */
    private String formatLLMFriendlyMessage(Boolean isSuccess, String errorCode, String errorMessage) {
        if (isSuccess) {
            return null; // No LLM message needed for success cases
        }

        String emoji = getErrorEmoji(errorCode);
        String suggestion = getErrorSuggestion(errorCode);

        return String.format('{0} **Error**: {1}\n\n**Suggestion**: {2}', new List<String>{ emoji, errorMessage, suggestion });
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
            when 'VALIDATION_ERROR' {
                return '❌';
            }
            when 'SECURITY_ERROR' {
                return '🔒';
            }
            when 'RECORD_NOT_FOUND' {
                return '🔍';
            }
            when 'SOQL_ERROR' {
                return '🗄️';
            }
            when 'DML_ERROR' {
                return '💾';
            }
            when 'CONNECT_API_ERROR' {
                return '🔌';
            }
            when 'FLOW_ERROR' {
                return '🔄';
            }
            when else {
                return '⚠️';
            }
        }
    }

    /**
     * @description Provides contextual suggestions based on error type
     * @param errorCode The error code to provide suggestions for
     * @return Helpful suggestion text for the error type
     */
    private String getErrorSuggestion(String errorCode) {
        if (errorCode == null)
            return 'Please check the input parameters and try again.';

        switch on errorCode {
            when 'VALIDATION_ERROR' {
                return 'Please verify all required fields are provided and have valid values.';
            }
            when 'SECURITY_ERROR' {
                return 'Please ensure you have the necessary permissions to perform this action.';
            }
            when 'RECORD_NOT_FOUND' {
                return 'Please verify the record ID exists and you have access to view it.';
            }
            when 'SOQL_ERROR' {
                return 'There may be an issue with the database query. Please contact your administrator.';
            }
            when 'DML_ERROR' {
                return 'Please check for validation rules, required fields, or permission issues.';
            }
            when 'CONNECT_API_ERROR' {
                return 'There may be a temporary connectivity issue. Please try again in a moment.';
            }
            when 'FLOW_ERROR' {
                return 'Please check the flow configuration and ensure all required inputs are provided.';
            }
            when else {
                return 'An unexpected error occurred. Please contact your administrator if the issue persists.';
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
