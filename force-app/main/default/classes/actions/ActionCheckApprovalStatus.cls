/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Checks approval status with comprehensive process information.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *
 *              MAINTAINS: Comprehensive approval process querying, security checks, and detailed status information.
 *              ENHANCED: Simplified interface while preserving all robustness features.
 * @extends BaseAgentAction
 */
public class ActionCheckApprovalStatus extends BaseAgentAction {
    private static final String NA = 'N/A';

    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction and validation.
     *              ENHANCED: Maintains comprehensive approval status checking while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        Id recordId = validateAndExtractRecordId(params);

        ProcessInstance processInstance = queryApprovalProcessInstance(recordId);

        ApprovalStatusResult statusResult = processApprovalStatus(processInstance, recordId);

        Long executionTime = System.currentTimeMillis() - startTime;

        return statusResult;
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
     * @description Queries approval process instance with enhanced error handling
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
                throw new ValidationException('No approval process instance found for record: ' + recordId, 'recordId');
            }

            return instances[0];
        } catch (System.QueryException qe) {
            String enhancedMessage = 'Failed to query approval process information: ' + qe.getMessage();

            throw new ValidationException(enhancedMessage, 'recordId', qe);
        } catch (Exception ex) {
            String enhancedMessage = 'Unexpected error querying approval status: ' + ex.getMessage();

            throw new ValidationException(enhancedMessage, null, ex);
        }
    }

    /**
     * @description Processes approval status with enhanced information extraction
     */
    private ApprovalStatusResult processApprovalStatus(ProcessInstance instance, Id recordId) {
        String status = instance.Status;
        String assignedTo = NA;
        String lastComment = NA;
        String lastActorName = NA;
        DateTime lastActionDate = null;
        List<Map<String, Object>> approvalHistory = new List<Map<String, Object>>();

        if (status == 'Pending' && instance.Workitems != null && !instance.Workitems.isEmpty()) {
            List<String> assignees = new List<String>();
            for (ProcessInstanceWorkitem workItem : instance.Workitems) {
                if (workItem.Actor?.Name != null) {
                    assignees.add(workItem.Actor.Name);
                }
            }
            assignedTo = assignees.isEmpty() ? NA : String.join(assignees, ', ');
        }

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

                if (step.StepStatus != 'Pending' && step.StepStatus != 'Started' && latestCompletedStep == null) {
                    latestCompletedStep = step;
                }
            }

            if (latestCompletedStep != null) {
                lastComment = latestCompletedStep.Comments;
                lastActorName = latestCompletedStep.Actor?.Name ?? NA;
                lastActionDate = latestCompletedStep.CreatedDate;
            } else {
                ProcessInstanceStep firstStep = instance.Steps[instance.Steps.size() - 1];
                lastComment = firstStep.Comments;
                lastActorName = firstStep.Actor?.Name ?? 'Submitter';
                lastActionDate = instance.CreatedDate;
            }
        }

        if (String.isBlank(lastComment)) {
            lastComment = NA;
        }

        String message = 'The approval status for ' + (instance.TargetObject?.Name ?? 'this record') + ' is currently "' + status + '".';
        if (status == 'Pending') {
            message += ' It is assigned to: ' + assignedTo + '.';
        } else if (status == 'Approved') {
            message += ' The approval was completed successfully.';
        } else if (status == 'Rejected') {
            message += ' The approval was rejected.';
        }

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

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

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
