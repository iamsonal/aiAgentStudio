/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Represents the structured result of executing an IAgentAction.
 *              Provides clear accessors for success status, output payload, internal details, and error codes.
 */
public class ActionResult {
    /** @description Indicates whether the action's primary logic completed successfully. */
    @AuraEnabled
    public Boolean isSuccess { get; private set; }

    /**
     * @description The payload intended to be returned to the LLM (or used by subsequent actions).
     *              Can be a String, List<SObject>, Map<String, Object>, etc. Its structure depends on the specific action.
     *              In case of failure, this might contain a user-friendly error summary.
     */
    @AuraEnabled
    public Object outputForLlm { get; private set; }

    /** @description Detailed information about the action's execution (success or failure) primarily for logging and debugging. Not typically sent to the LLM. */
    public String internalDetails { get; private set; }

    /** @description An optional, machine-readable code indicating the type of error if isSuccess is false. */
    @AuraEnabled
    public String errorCode { get; private set; }

    /**
     * @description Constructor for a successful action result.
     * @param outputData The data payload to return.
     * @param details Diagnostic information about the execution.
     */
    public ActionResult(Object outputData, String details) {
        this.isSuccess = true;
        this.outputForLlm = outputData;
        this.internalDetails = details;
        this.errorCode = null;
    }

    /**
     * @description Constructor for a failed action result.
     * @param errorOutput Data/message summarizing the failure for the LLM (can be a simple string).
     * @param details Detailed diagnostic information about the failure.
     * @param code Machine-readable error category.
     */
    public ActionResult(Object errorOutput, String details, String code) {
        this.isSuccess = false;
        this.outputForLlm = errorOutput;
        this.internalDetails = details;
        this.errorCode = code;
    }

    /** @description Helper method for quick boolean check. */
    public Boolean isFailure() {
        return !this.isSuccess;
    }

    public Boolean getIsSuccess() {
        return this.isSuccess;
    }
    public Object getOutputForLlm() {
        return this.outputForLlm;
    }
    public String getInternalDetails() {
        return this.internalDetails;
    }
    public String getErrorCode() {
        return this.errorCode;
    }
}
