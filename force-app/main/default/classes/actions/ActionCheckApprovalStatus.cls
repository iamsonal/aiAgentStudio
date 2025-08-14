/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionCheckApprovalStatus is a robust Apex action for retrieving and summarizing the approval process status of a Salesforce record.
 * It leverages the agent action framework to handle parameter extraction, validation, security, and result formatting automatically.
 *
 * Responsibilities:
 *   - Validates and extracts the recordId parameter from input.
 *   - Queries the most recent approval process instance for the specified record, with comprehensive error handling.
 *   - Processes and summarizes approval status, current assignees, last action, and approval history.
 *   - Returns a structured, LLM-friendly result object for downstream consumption or user display.
 *
 * Scope:
 *   - Focused on approval process status reporting; does not initiate, modify, or interact with approval steps beyond querying.
 *   - Designed for extensibility and clarity, with detailed debug output and maintainable documentation.
 *
 * @extends BaseAgentAction
 */
public class ActionCheckApprovalStatus extends BaseAgentAction {
    private static final String NA = 'N/A';

    /**
     * @description
     * Main entry point for the action. Validates input, queries approval process, and returns a summary result.
     *
     * @param params Map<String, Object> - Must include 'recordId' (String or Id) for the record to check.
     * @return ApprovalStatusResult - Structured summary of approval status and history.
     * @throws ValidationException if required parameters are missing or invalid, or if no approval process is found.
     *
     * Side effects: Logs key steps and performance metrics for troubleshooting and monitoring.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        Id recordId = validateAndExtractRecordId(params);
        System.debug(LoggingLevel.INFO, '[ActionCheckApprovalStatus] Initiating approval status check for recordId: ' + recordId);

        ProcessInstance processInstance = queryApprovalProcessInstance(recordId);
        ApprovalStatusResult statusResult = processApprovalStatus(processInstance, recordId);

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(
            LoggingLevel.INFO,
            '[ActionCheckApprovalStatus] Approval status check for recordId ' + recordId + ' completed in ' + executionTime + ' ms.'
        );

        return statusResult;
    }

    /**
     * @description
     * Validates and extracts the 'recordId' parameter from the input map.
     *
     * @param params Map<String, Object> - Input parameters, must contain 'recordId'.
     * @return Id - The validated Salesforce record Id.
     * @throws ValidationException if 'recordId' is missing or not a valid Salesforce Id.
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
     * Queries the most recent approval process instance for the given recordId.
     *
     * @param recordId Id - The Salesforce record Id to check.
     * @return ProcessInstance - The latest approval process instance for the record.
     * @throws ValidationException if no approval process is found or if a query error occurs.
     */
    private ProcessInstance queryApprovalProcessInstance(Id recordId) {
        try {
            List<ProcessInstance> instances = [
                SELECT
                    Id,
                    Status,
                    CreatedDate,
                    CompletedDate,
                    TargetObjectId,
                    TargetObject.Name,
                    (SELECT StepStatus, Comments, Actor.Name, CreatedDate FROM Steps ORDER BY CreatedDate DESC, Id DESC),
                    (SELECT Actor.Name FROM Workitems WHERE ActorId != NULL ORDER BY CreatedDate DESC)
                FROM ProcessInstance
                WHERE TargetObjectId = :recordId
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (instances.isEmpty()) {
                System.debug(LoggingLevel.WARN, '[ActionCheckApprovalStatus] No approval process instance found for recordId: ' + recordId);
                throw new ValidationException('No approval process instance found for record: ' + recordId, 'recordId');
            }
            System.debug(
                LoggingLevel.DEBUG,
                '[ActionCheckApprovalStatus] Queried approval process instance: ' + instances[0].Id + ' for recordId: ' + recordId
            );
            return instances[0];
        } catch (System.QueryException qe) {
            String enhancedMessage = 'Failed to query approval process information: ' + qe.getMessage();
            System.debug(
                LoggingLevel.ERROR,
                '[ActionCheckApprovalStatus] QueryException while retrieving approval process for recordId ' + recordId + ': ' + qe.getMessage()
            );
            throw new ValidationException(enhancedMessage, 'recordId', qe);
        } catch (Exception ex) {
            String enhancedMessage = 'Unexpected error querying approval status: ' + ex.getMessage();
            System.debug(
                LoggingLevel.ERROR,
                '[ActionCheckApprovalStatus] Unexpected exception while retrieving approval process for recordId ' + recordId + ': ' + ex.getMessage()
            );
            throw new ValidationException(enhancedMessage, null, ex);
        }
    }

    /**
     * @description
     * Processes the approval process instance to extract status, assignees, last action, and history.
     *
     * @param instance ProcessInstance - The approval process instance to summarize.
     * @param recordId Id - The Salesforce record Id being checked.
     * @return ApprovalStatusResult - Structured summary of approval status and history.
     *
     * Notes:
     *   - Handles both completed and in-progress approval processes.
     *   - Builds a user-friendly message and detailed history for downstream use.
     */
    private ApprovalStatusResult processApprovalStatus(ProcessInstance instance, Id recordId) {
        String status = instance.Status;
        String assignedTo = NA;
        String lastComment = NA;
        String lastActorName = NA;
        DateTime lastActionDate = null;
        List<Map<String, Object>> approvalHistory = new List<Map<String, Object>>();

        // Identify current assignees for pending approvals
        if (status == 'Pending' && instance.Workitems != null && !instance.Workitems.isEmpty()) {
            List<String> assignees = new List<String>();
            for (ProcessInstanceWorkitem workItem : instance.Workitems) {
                if (workItem.Actor?.Name != null) {
                    assignees.add(workItem.Actor.Name);
                }
            }
            assignedTo = assignees.isEmpty() ? NA : String.join(assignees, ', ');
            System.debug(LoggingLevel.DEBUG, '[ActionCheckApprovalStatus] Pending approval assigned to: ' + assignedTo);
        }

        // Build approval history and determine last action
        if (instance.Steps != null && !instance.Steps.isEmpty()) {
            ProcessInstanceStep latestCompletedStep = null;
            for (ProcessInstanceStep step : instance.Steps) {
                approvalHistory.add(
                    new Map<String, Object>{
                        'stepStatus' => step.StepStatus,
                        'comments' => step.Comments ?? NA,
                        'actorName' => step.Actor?.Name ?? NA,
                        'actionDate' => step.CreatedDate
                    }
                );
                // Find the most recent completed step for summary
                if (step.StepStatus != 'Pending' && step.StepStatus != 'Started' && latestCompletedStep == null) {
                    latestCompletedStep = step;
                }
            }
            if (latestCompletedStep != null) {
                lastComment = latestCompletedStep.Comments;
                lastActorName = latestCompletedStep.Actor?.Name ?? NA;
                lastActionDate = latestCompletedStep.CreatedDate;
            } else {
                // If no completed steps, use the first step for initial status
                ProcessInstanceStep firstStep = instance.Steps[instance.Steps.size() - 1];
                lastComment = firstStep.Comments;
                lastActorName = firstStep.Actor?.Name ?? 'Submitter';
                lastActionDate = instance.CreatedDate;
            }
        }

        if (String.isBlank(lastComment)) {
            lastComment = NA;
        }

        // Compose user-facing message
        String message = 'The approval status for ' + (instance.TargetObject?.Name ?? 'this record') + ' is currently "' + status + '".';
        if (status == 'Pending') {
            message += ' Awaiting action from: ' + assignedTo + '.';
        } else if (status == 'Approved') {
            message += ' The approval was completed successfully.';
        } else if (status == 'Rejected') {
            message += ' The approval was rejected.';
        }

        System.debug(
            LoggingLevel.INFO,
            '[ActionCheckApprovalStatus] Approval status for recordId ' + recordId + ': ' + status + '. Last action by: ' + lastActorName + '.'
        );

        return new ApprovalStatusResult(
            recordId.toString(),
            instance.TargetObject?.Name ?? NA,
            instance.Id,
            status,
            assignedTo,
            lastActorName,
            lastComment,
            instance.CreatedDate,
            instance.CompletedDate,
            lastActionDate,
            approvalHistory,
            message
        );
    }

    /**
     * @description
     * Parses action configuration JSON if provided. This action does not require custom configuration,
     * but logs a debug message if configuration is present for transparency.
     *
     * @param actionConfigurationJson String - The JSON configuration string (optional).
     * @param logPrefix String - Prefix for log output.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
            System.debug(
                LoggingLevel.DEBUG,
                '[ActionCheckApprovalStatus] Action configuration JSON was provided but is not required for this action.'
            );
        }
    }

    /**
     * @description
     * Result object representing the approval status and history for a record.
     *
     * Fields:
     *   - recordId: String - The Salesforce record Id.
     *   - recordName: String - The name of the record (if available).
     *   - processInstanceId: String - The Id of the approval process instance.
     *   - overallStatus: String - The overall approval status (e.g., Pending, Approved, Rejected).
     *   - currentAssignee: String - The current assignee(s) for pending approvals.
     *   - lastActionBy: String - The name of the user who performed the last action.
     *   - lastComment: String - The most recent comment in the approval process.
     *   - processInitiatedDate: DateTime - When the approval process started.
     *   - processCompletedDate: DateTime - When the approval process completed (if applicable).
     *   - lastActionDate: DateTime - When the last action was taken.
     *   - approvalHistory: List<Map<String, Object>> - Chronological list of approval steps.
     *   - message: String - User-friendly summary message.
     *   - metadata: Map<String, Object> - Additional context for downstream consumers.
     */
    public class ApprovalStatusResult {
        public String recordId;
        public String recordName;
        public String processInstanceId;
        public String overallStatus;
        public String currentAssignee;
        public String lastActionBy;
        public String lastComment;
        public DateTime processInitiatedDate;
        public DateTime processCompletedDate;
        public DateTime lastActionDate;
        public List<Map<String, Object>> approvalHistory;
        public String message;
        public Map<String, Object> metadata;

        public ApprovalStatusResult(
            String recordId,
            String recordName,
            String processInstanceId,
            String overallStatus,
            String currentAssignee,
            String lastActionBy,
            String lastComment,
            DateTime processInitiatedDate,
            DateTime processCompletedDate,
            DateTime lastActionDate,
            List<Map<String, Object>> approvalHistory,
            String message
        ) {
            this.recordId = recordId;
            this.recordName = recordName;
            this.processInstanceId = processInstanceId;
            this.overallStatus = overallStatus;
            this.currentAssignee = currentAssignee;
            this.lastActionBy = lastActionBy;
            this.lastComment = lastComment;
            this.processInitiatedDate = processInitiatedDate;
            this.processCompletedDate = processCompletedDate;
            this.lastActionDate = lastActionDate;
            this.approvalHistory = approvalHistory;
            this.message = message;
            this.metadata = new Map<String, Object>{
                'recordId' => recordId,
                'status' => overallStatus,
                'isPending' => overallStatus == 'Pending',
                'isCompleted' => processCompletedDate != null,
                'historyStepCount' => approvalHistory != null ? approvalHistory.size() : 0
            };
        }
    }
}
