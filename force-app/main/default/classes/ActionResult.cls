/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 *  ActionResult is an immutable, standardized result object for agent action execution within the AI Agent Framework.
 *  It encapsulates the outcome of an action—success or failure—along with:
 *    - Output data for downstream processing or LLM consumption
 *    - Internal diagnostic details for logging and debugging
 *    - Machine-readable error codes for consistent error handling
 *
 *  This class is designed to make action results easy to interpret, log, and extend, supporting both success and error scenarios.
 *  All fields are read-only after construction to ensure immutability and thread safety.
 */
public class ActionResult {
    /**
     * @description
     * True if the action completed successfully; false if it failed.
     * This is the canonical indicator for downstream logic and error handling.
     */
    @AuraEnabled
    public Boolean isSuccess { get; private set; }

    /**
     * @description
     * The payload to be returned to the LLM or used by subsequent actions.
     * Can be a String, List<SObject>, Map<String, Object>, etc., depending on the action.
     * On failure, this may contain a user-friendly error summary for the LLM.
     */
    @AuraEnabled
    public Object outputForLlm { get; private set; }

    /**
     * @description
     * Internal diagnostic information about the action's execution, for logging and debugging only.
     * Never sent to the LLM or exposed to end users.
     */
    public String internalDetails { get; private set; }

    /**
     * @description
     * Optional, machine-readable code indicating the error type if isSuccess is false.
     * Enables consistent error handling and categorization across the framework.
     */
    @AuraEnabled
    public String errorCode { get; private set; }

    /**
     * @description
     * Constructs a successful ActionResult.
     * @param outputData The data payload to return to the LLM or next action.
     * @param details    Internal diagnostic information for logging/debugging (optional).
     * @note errorCode is always null for successful results.
     */
    public ActionResult(Object outputData, String details) {
        this.isSuccess = true;
        this.outputForLlm = outputData;
        this.internalDetails = details;
        this.errorCode = null;
        System.debug(
            LoggingLevel.INFO,
            'ActionResult: Success result created. Output=' + String.valueOf(outputData) + (details != null ? ' | Details=' + details : '')
        );
    }

    /**
     * @description
     * Constructs a failed ActionResult.
     * @param errorOutput Data/message summarizing the failure for the LLM (user-friendly).
     * @param details     Internal diagnostic information for debugging (technical).
     * @param code        Machine-readable error category for programmatic handling.
     * @note isSuccess is always false for this constructor.
     */
    public ActionResult(Object errorOutput, String details, String code) {
        this.isSuccess = false;
        this.outputForLlm = errorOutput;
        this.internalDetails = details;
        this.errorCode = code;
        System.debug(
            LoggingLevel.WARN,
            'ActionResult: Failure result created. ErrorOutput=' +
                String.valueOf(errorOutput) +
                (code != null ? ' | ErrorCode=' + code : '') +
                (details != null ? ' | Details=' + details : '')
        );
    }

    /**
     * @description
     * Returns true if the action failed (i.e., isSuccess is false).
     * Useful for concise error handling in client code.
     * @return Boolean True if the result represents a failure; false otherwise.
     */
    public Boolean isFailure() {
        Boolean failed = !this.isSuccess;
        System.debug(LoggingLevel.FINE, 'ActionResult: isFailure() called. Result=' + String.valueOf(failed));
        return failed;
    }

    /**
     * @description
     * Returns the success status of the action.
     * @return Boolean True if successful; false otherwise.
     */
    public Boolean getIsSuccess() {
        return this.isSuccess;
    }

    /**
     * @description
     * Returns the output payload for the LLM or next action.
     * @return Object The output data (type varies by action).
     */
    public Object getOutputForLlm() {
        return this.outputForLlm;
    }

    /**
     * @description
     * Returns the internal diagnostic details for this result.
     * @return String Diagnostic information for logs/debugging.
     */
    public String getInternalDetails() {
        return this.internalDetails;
    }

    /**
     * @description
     * Returns the error code if the action failed.
     * @return String Machine-readable error code, or null if successful.
     */
    public String getErrorCode() {
        return this.errorCode;
    }
}
