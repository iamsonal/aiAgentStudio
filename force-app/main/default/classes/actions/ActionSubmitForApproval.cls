/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionSubmitForApproval: Secure, robust, and intelligent Salesforce approval submission action.
 *
 * This class provides a streamlined, highly reliable mechanism for submitting Salesforce records for approval.
 * It performs deep parameter validation, lock detection, process selection, and error handling, while supporting flexible configuration and LLM-friendly result structures.
 *
 * Key Responsibilities:
 *   - Validates and extracts all required parameters for approval submission.
 *   - Detects and reports record lock status and user access before submission.
 *   - Supports specifying approval process and next approvers.
 *   - Handles all error conditions with actionable, context-rich messages.
 *   - Returns structured, developer- and LLM-friendly results for downstream processing.
 *
 * Usage: Parameters include recordId (required), submitterComment, processDefinitionNameOrId, nextApproverIds, skipEntryCriteria (optional).
 *
 * @extends BaseAgentAction
 */
public with sharing class ActionSubmitForApproval extends BaseAgentAction {
    /**
     * @description
     * Main entry point: Submits a Salesforce record for approval with comprehensive validation and error handling.
     *
     * Steps:
     *   1. Validates and extracts all required parameters.
     *   2. Checks for record lock and user access.
     *   3. Builds and executes the approval request.
     *   4. Processes and returns a structured result.
     *
     * @param params Map<String, Object> containing recordId and optional approval parameters.
     * @return ApprovalResult with process instance ID, approvers, and metadata.
     * @throws ValidationException if parameters are missing or invalid, or if submission fails.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Validate and extract all required parameters
        Id recordId = validateAndExtractRecordId(params);
        String submitterComment = (String) params.get('submitterComment');
        String processDefinitionNameOrId = (String) params.get('processDefinitionNameOrId');
        List<Id> nextApproverIds = validateAndExtractApproverIds(params.get('nextApproverIds'));
        Boolean skipEntryCriteria = (Boolean) params.get('skipEntryCriteria');

        System.debug(
            LoggingLevel.INFO,
            '[ActionSubmitForApproval] Initiating approval submission for record ' +
                recordId +
                (String.isNotBlank(processDefinitionNameOrId) ? ' using process: ' + processDefinitionNameOrId : '') +
                (nextApproverIds != null && !nextApproverIds.isEmpty() ? ' with next approvers: ' + String.join(nextApproverIds, ', ') : '')
        );

        // Pre-submission validation: lock and access checks
        performPreSubmissionChecks(recordId);

        // Build and execute approval request
        Approval.ProcessSubmitRequest request = buildApprovalRequest(
            recordId,
            submitterComment,
            processDefinitionNameOrId,
            nextApproverIds,
            skipEntryCriteria
        );

        Approval.ProcessResult result = executeApprovalSubmission(request, recordId);

        // Process and validate approval result
        ApprovalResult approvalResult = processApprovalResult(result, recordId);

        // Log performance metrics
        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(
            LoggingLevel.INFO,
            '[ActionSubmitForApproval] Approval submission for record ' + recordId + ' completed in ' + executionTime + 'ms.'
        );

        return approvalResult;
    }

    /**
     * @description
     * Validates and extracts the record ID from parameters.
     * Throws ValidationException if the parameter is missing or invalid.
     *
     * @param params Map containing the recordId parameter
     * @return Id of the record to submit for approval
     * @throws ValidationException if recordId is missing or invalid
     */
    private Id validateAndExtractRecordId(Map<String, Object> params) {
        Object recordIdObj = params.get('recordId');

        if (recordIdObj == null) {
            throw new ValidationException('Missing required parameter: "recordId"', 'recordId');
        }

        if (recordIdObj instanceof Id) {
            return (Id) recordIdObj;
        }

        if (recordIdObj instanceof String && String.isNotBlank((String) recordIdObj)) {
            try {
                return Id.valueOf((String) recordIdObj);
            } catch (System.StringException strEx) {
                throw new ValidationException('Invalid ID format for "recordId": ' + recordIdObj, 'recordId');
            }
        }

        throw new ValidationException('Parameter "recordId" must be a valid Salesforce ID', 'recordId');
    }

    /**
     * @description
     * Validates and extracts next approver IDs from parameters, supporting both String and List input.
     * Throws ValidationException if any value is invalid.
     *
     * @param approversObj Object containing nextApproverIds (String or List<String>)
     * @return List<Id> of valid User IDs for next approvers
     * @throws ValidationException if any ID is invalid
     */
    private List<Id> validateAndExtractApproverIds(Object approversObj) {
        List<Id> parsedIds = new List<Id>();
        if (approversObj == null)
            return parsedIds;

        List<String> stringIds = new List<String>();

        if (approversObj instanceof List<Object>) {
            for (Object item : (List<Object>) approversObj) {
                if (item instanceof String && String.isNotBlank((String) item)) {
                    stringIds.add((String) item);
                } else {
                    throw new ValidationException(
                        'Invalid value in "nextApproverIds" list. All elements must be non-blank strings.',
                        'nextApproverIds'
                    );
                }
            }
        } else if (approversObj instanceof String) {
            String str = ((String) approversObj).trim();
            if (String.isNotBlank(str)) {
                // Handle comma or space separated IDs
                for (String part : str.split('[\\s,]+')) {
                    if (String.isNotBlank(part.trim())) {
                        stringIds.add(part.trim());
                    }
                }
            }
        } else {
            throw new ValidationException('Parameter "nextApproverIds" must be a String or List of Strings.', 'nextApproverIds');
        }

        for (String strId : stringIds) {
            try {
                parsedIds.add(Id.valueOf(strId));
            } catch (Exception e) {
                throw new ValidationException('Invalid Salesforce ID format in "nextApproverIds": ' + strId, 'nextApproverIds');
            }
        }

        return parsedIds;
    }

    /**
     * @description
     * Performs pre-submission validation: checks for record lock and user access.
     * Throws ValidationException if record is locked or inaccessible.
     *
     * @param recordId Id of the record to check
     * @throws ValidationException if record is locked or inaccessible
     */
    private void performPreSubmissionChecks(Id recordId) {
        try {
            // Check if record is locked before submission
            if (Approval.isLocked(recordId)) {
                throw new ValidationException('Record is locked and cannot be submitted for approval: ' + recordId, 'recordId');
            }

            // Verify record exists and user has access
            String objectType = recordId.getSObjectType().getDescribe().getName();
            String query = 'SELECT Id FROM ' + objectType + ' WHERE Id = :recordId LIMIT 1';
            List<SObject> records = Database.queryWithBinds(query, new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);

            if (records.isEmpty()) {
                throw new ValidationException('Record not found or user lacks access: ' + recordId, 'recordId');
            }
        } catch (System.QueryException qe) {
            String enhancedMessage = 'Failed to validate record access for approval submission: ' + qe.getMessage();
            System.debug(LoggingLevel.ERROR, '[ActionSubmitForApproval] ' + enhancedMessage);
            throw new ValidationException(enhancedMessage, 'recordId', qe);
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, '[ActionSubmitForApproval] Pre-submission check failed: ' + ex.getMessage());
            throw ex;
        }
    }

    /**
     * @description
     * Builds the Approval.ProcessSubmitRequest with all validated parameters.
     * Throws ValidationException if any approver ID is not a User ID.
     *
     * @param recordId Id of the record to submit
     * @param submitterComment Optional comment for the approval submission
     * @param processDefinitionNameOrId Optional process definition name or ID
     * @param nextApproverIds Optional list of User IDs for next approvers
     * @param skipEntryCriteria Optional flag to skip entry criteria
     * @return Approval.ProcessSubmitRequest ready for submission
     * @throws ValidationException if any approver ID is not a User ID
     */
    private Approval.ProcessSubmitRequest buildApprovalRequest(
        Id recordId,
        String submitterComment,
        String processDefinitionNameOrId,
        List<Id> nextApproverIds,
        Boolean skipEntryCriteria
    ) {
        Approval.ProcessSubmitRequest request = new Approval.ProcessSubmitRequest();
        request.setObjectId(recordId);

        if (String.isNotBlank(submitterComment)) {
            // Truncate comment if it exceeds Salesforce limits
            if (submitterComment.length() > 32000) {
                System.debug(LoggingLevel.WARN, '[ActionSubmitForApproval] Submitter comment truncated to 32000 characters');
                submitterComment = submitterComment.substring(0, 32000);
            }
            request.setComments(submitterComment);
        }

        if (String.isNotBlank(processDefinitionNameOrId)) {
            request.setProcessDefinitionNameOrId(processDefinitionNameOrId);
        }

        if (nextApproverIds != null && !nextApproverIds.isEmpty()) {
            // Validate all next approver IDs are User IDs
            for (Id approverId : nextApproverIds) {
                if (approverId.getSObjectType() != User.SObjectType) {
                    throw new ValidationException('Invalid approver ID - must be User ID: ' + approverId, 'nextApproverIds');
                }
            }
            request.setNextApproverIds(nextApproverIds);
        }

        if (skipEntryCriteria != null) {
            request.setSkipEntryCriteria(skipEntryCriteria);
        }

        return request;
    }

    /**
     * @description
     * Executes the approval submission and returns the result.
     * Throws ValidationException if submission fails or returns no result.
     *
     * @param request Approval.ProcessSubmitRequest to execute
     * @param recordId Id of the record being submitted
     * @return Approval.ProcessResult from the submission
     * @throws ValidationException if submission fails or returns no result
     */
    private Approval.ProcessResult executeApprovalSubmission(Approval.ProcessSubmitRequest request, Id recordId) {
        try {
            Approval.ProcessResult[] results = Approval.process(new List<Approval.ProcessSubmitRequest>{ request });

            if (results == null || results.isEmpty()) {
                throw new ValidationException('Approval.process returned no results for record: ' + recordId, null);
            }

            return results[0];
        } catch (Exception ex) {
            String enhancedMessage = enhanceApprovalErrorMessage(ex.getMessage(), recordId);
            System.debug(LoggingLevel.ERROR, '[ActionSubmitForApproval] ' + enhancedMessage);
            throw new ValidationException(enhancedMessage, null, ex);
        }
    }

    /**
     * @description
     * Processes the Approval.ProcessResult, returning a structured ApprovalResult or throwing on failure.
     *
     * @param result Approval.ProcessResult from the submission
     * @param recordId Id of the record submitted
     * @return ApprovalResult with process instance ID, approvers, and message
     * @throws ValidationException if submission failed
     */
    private ApprovalResult processApprovalResult(Approval.ProcessResult result, Id recordId) {
        if (result.isSuccess()) {
            String instanceId = result.getInstanceId();
            List<Id> actorIds = result.getActorIds();

            System.debug(
                LoggingLevel.INFO,
                '[ActionSubmitForApproval] Record ' + recordId + ' successfully submitted for approval. Instance ID: ' + instanceId
            );

            return new ApprovalResult(recordId.toString(), instanceId, actorIds, 'Record ' + recordId + ' submitted for approval successfully.');
        } else {
            String errorMessage = processApprovalErrors(result.getErrors());
            String enhancedError = 'Approval submission failed for record ' + recordId + ': ' + errorMessage;
            System.debug(LoggingLevel.ERROR, '[ActionSubmitForApproval] ' + enhancedError);
            throw new ValidationException(enhancedError, null);
        }
    }

    /**
     * @description
     * Enhances approval error messages with actionable context for common failure scenarios.
     *
     * @param originalMessage The original error message
     * @param recordId Id of the record being submitted
     * @return String with enhanced error message
     */
    private String enhanceApprovalErrorMessage(String originalMessage, Id recordId) {
        String enhanced = originalMessage;

        if (originalMessage.contains('UNABLE_TO_LOCK_ROW')) {
            enhanced = 'Record is currently locked by another process: ' + recordId;
        } else if (originalMessage.contains('NO_APPLICABLE_PROCESS')) {
            enhanced = 'No applicable approval process found for record: ' + recordId;
        } else if (originalMessage.contains('PROCESS_DEFINITION_NOT_FOUND')) {
            enhanced = 'Specified approval process definition not found for record: ' + recordId;
        } else if (originalMessage.contains('INSUFFICIENT_ACCESS')) {
            enhanced = 'Insufficient permissions to submit record for approval: ' + recordId;
        }

        return enhanced;
    }

    /**
     * @description
     * Processes approval errors into a readable, developer-friendly format.
     *
     * @param errors List<Database.Error> from the failed approval process
     * @return String with concatenated error messages
     */
    private String processApprovalErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'Unknown approval process error';
        }

        List<String> errorMessages = new List<String>();
        for (Database.Error err : errors) {
            String errorDetail = err.getStatusCode() + ': ' + err.getMessage();
            if (!err.getFields().isEmpty()) {
                errorDetail += ' (Fields: ' + String.join(err.getFields(), ', ') + ')';
            }
            errorMessages.add(errorDetail);
        }

        return String.join(errorMessages, '; ');
    }

    /**
     * @description
     * Parses action configuration JSON. No configuration is required for this action, but logs if any is provided.
     *
     * @param actionConfigurationJson JSON string with configuration options
     * @param logPrefix Prefix for debug logging
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[ActionSubmitForApproval] Action configuration JSON was provided but is not required for this action.');
        }
    }

    /**
     * @description
     * Result wrapper for successful approval submissions.
     * Provides structured data for user display and LLM processing.
     *
     * @property recordId The ID of the submitted record
     * @property processInstanceId The approval process instance ID
     * @property actorIds List of User IDs for next approvers
     * @property message User-facing confirmation message
     * @property metadata Additional context for LLMs and downstream consumers
     */
    public class ApprovalResult {
        public String recordId;
        public String processInstanceId;
        public List<Id> actorIds;
        public String message; // Framework uses this for user display
        public Map<String, Object> metadata; // Additional context for LLMs

        public ApprovalResult(String recordId, String processInstanceId, List<Id> actorIds, String message) {
            this.recordId = recordId;
            this.processInstanceId = processInstanceId;
            this.actorIds = actorIds;
            this.message = message;
            this.metadata = new Map<String, Object>{
                'recordId' => recordId,
                'processInstanceId' => processInstanceId,
                'approverCount' => actorIds != null ? actorIds.size() : 0,
                'submissionSuccessful' => true
            };
        }
    }
}
