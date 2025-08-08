/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Submits Salesforce records for approval with intelligent processing.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *
 *              MAINTAINS: Comprehensive approval process handling, lock detection, and detailed error handling.
 *              ENHANCED: Simplified interface while preserving all robustness features.
 * @extends BaseAgentAction
 */
public with sharing class ActionSubmitForApproval extends BaseAgentAction {
    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction and validation.
     *              ENHANCED: Maintains approval process robustness while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        Id recordId = validateAndExtractRecordId(params);
        String submitterComment = (String) params.get('submitterComment');
        String processDefinitionNameOrId = (String) params.get('processDefinitionNameOrId');
        List<Id> nextApproverIds = validateAndExtractApproverIds(params.get('nextApproverIds'));
        Boolean skipEntryCriteria = (Boolean) params.get('skipEntryCriteria');

        performPreSubmissionChecks(recordId);

        Approval.ProcessSubmitRequest request = buildApprovalRequest(
            recordId,
            submitterComment,
            processDefinitionNameOrId,
            nextApproverIds,
            skipEntryCriteria
        );

        Approval.ProcessResult result = executeApprovalSubmission(request, recordId);

        ApprovalResult approvalResult = processApprovalResult(result, recordId);

        Long executionTime = System.currentTimeMillis() - startTime;

        return approvalResult;
    }

    /**
     * @description Validates and extracts record ID with enhanced error handling
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
     * @description Validates and extracts approver IDs with flexible input handling
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
     * @description Performs comprehensive pre-submission validation
     */
    private void performPreSubmissionChecks(Id recordId) {
        try {
            if (Approval.isLocked(recordId)) {
                throw new ValidationException('Record is locked and cannot be submitted for approval: ' + recordId, 'recordId');
            }

            String objectType = recordId.getSObjectType().getDescribe().getName();
            String query = 'SELECT Id FROM ' + objectType + ' WHERE Id = :recordId LIMIT 1';
            List<SObject> records = Database.queryWithBinds(query, new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);

            if (records.isEmpty()) {
                throw new ValidationException('Record not found or user lacks access: ' + recordId, 'recordId');
            }
        } catch (System.QueryException qe) {
            String enhancedMessage = 'Failed to validate record access for approval submission: ' + qe.getMessage();

            throw new ValidationException(enhancedMessage, 'recordId', qe);
        } catch (Exception ex) {
            throw ex;
        }
    }

    /**
     * @description Builds approval request with enhanced validation
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
            if (submitterComment.length() > 32000) {
                submitterComment = submitterComment.substring(0, 32000);
            }
            request.setComments(submitterComment);
        }

        if (String.isNotBlank(processDefinitionNameOrId)) {
            request.setProcessDefinitionNameOrId(processDefinitionNameOrId);
        }

        if (nextApproverIds != null && !nextApproverIds.isEmpty()) {
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
     * @description Executes approval submission with enhanced error handling
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

            throw new ValidationException(enhancedMessage, null, ex);
        }
    }

    /**
     * @description Processes approval result with enhanced validation
     */
    private ApprovalResult processApprovalResult(Approval.ProcessResult result, Id recordId) {
        if (result.isSuccess()) {
            String instanceId = result.getInstanceId();
            List<Id> actorIds = result.getActorIds();

            return new ApprovalResult(recordId.toString(), instanceId, actorIds, 'Record ' + recordId + ' submitted for approval successfully.');
        } else {
            String errorMessage = processApprovalErrors(result.getErrors());
            String enhancedError = 'Approval submission failed for record ' + recordId + ': ' + errorMessage;

            throw new ValidationException(enhancedError, null);
        }
    }

    /**
     * @description Enhances approval error messages with context
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
     * @description Processes approval errors into readable format
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

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

    public class ApprovalResult {
        public String recordId;
        public String processInstanceId;
        public List<Id> actorIds;
        public String message;
        public Map<String, Object> metadata;

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
