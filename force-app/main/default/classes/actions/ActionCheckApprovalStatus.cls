/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Standard Action: Checks the approval status of a specific Salesforce record.
 *              Extends BaseAgentAction for standardized execution flow and error handling.
 * @implements BaseAgentAction
 */
public class ActionCheckApprovalStatus extends BaseAgentAction {
    private static final String ARG_RECORD_ID = 'recordId';

    private static final String ERR_CODE_INPUT = AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
    private static final String ERR_CODE_NOT_FOUND = AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND;
    private static final String ERR_CODE_QUERY = AIAgentConstants.ERR_CODE_SOQL_ERROR;
    private static final String ERR_CODE_SECURITY = AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
    private static final String ERR_CODE_UNEXPECTED = AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;
    private static final String NA = 'N/A';

    /**
     * @description Provides a specific log prefix for this action type.
     * @return String 'ActionCheckApprovalStatus'
     */
    protected override String getLogPrefixName() {
        return 'ActionCheckApprovalStatus';
    }

    /**
     * @description Parses ActionConfiguration. CheckApprovalStatus generally doesn't need config.
     * @param actionConfigurationJson The raw JSON string.
     * @param logPrefix Logging prefix.
     * @throws ValidationException if JSON is provided but invalid.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

    /**
     * @description Defines the structure for arguments specific to CheckApprovalStatus.
     */
    class CheckApprovalStatusParsedArguments extends BaseAgentAction.ParsedArguments {
        public Id recordSObjectId { get; private set; }

        public CheckApprovalStatusParsedArguments(String jsonArguments) {
            if (String.isBlank(jsonArguments)) {
                throw new ValidationException('Input arguments JSON cannot be blank.', null);
            }
            Map<String, Object> parsedArgs = (Map<String, Object>) JSON.deserializeUntyped(jsonArguments);

            this.recordSObjectId = ParameterExtractionUtils.getRequiredId(parsedArgs, ARG_RECORD_ID, null);
        }
    }

    /**
     * @description Parses and validates the LLM arguments (just 'recordId').
     * @param argumentsJson Raw JSON string from the LLM.
     * @param logPrefix Logging prefix.
     * @return CheckApprovalStatusParsedArguments instance.
     * @throws ValidationException If arguments are invalid.
     */
    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        try {
            return new CheckApprovalStatusParsedArguments(argumentsJson);
        } catch (Exception e) {
            throw new ValidationException('Failed to parse/validate CheckApprovalStatus arguments: ' + e.getMessage(), null);
        }
    }

    /**
     * @description Core logic: Executes secure SOQL query for ProcessInstance and related data.
     * @param validatedArgs Parsed arguments (must be cast).
     * @param logPrefix Logging prefix.
     * @return ActionResult Result containing approval status details.
     * @throws ActionSecurityException if security enforced query fails due to permissions.
     * @throws QueryException for other SOQL errors (will be mapped by base).
     */
    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        CheckApprovalStatusParsedArguments args = (CheckApprovalStatusParsedArguments) validatedArgs;
        ProcessInstance instance = null;

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
                WHERE TargetObjectId = :args.recordSObjectId
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];

            if (instances.isEmpty()) {
                String notFoundMsg = 'No approval process instance found or accessible for Record ID: ' + args.recordSObjectId;

                return this.runtimeError(notFoundMsg, ERR_CODE_NOT_FOUND, null);
            }
            instance = instances[0];
        } catch (System.QueryException qe) {
            throw qe;
        } catch (Exception ex) {
            throw ex;
        }

        String status = instance.Status;
        String assignedTo = NA;
        String lastComment = NA;
        String lastActorName = NA;
        Datetime lastActionDate = null;

        if (status == 'Pending' && instance.Workitems != null && !instance.Workitems.isEmpty()) {
            List<String> assignees = new List<String>();
            for (ProcessInstanceWorkitem workItem : instance.Workitems) {
                if (workItem.Actor?.Name != null)
                    assignees.add(workItem.Actor.Name);
            }
            assignedTo = assignees.isEmpty() ? NA : String.join(assignees, ', ');
        }

        if (instance.Steps != null && !instance.Steps.isEmpty()) {
            ProcessInstanceStep latestCompletedStep = null;
            for (ProcessInstanceStep step : instance.Steps) {
                if (step.StepStatus != 'Pending' && step.StepStatus != 'Started') {
                    latestCompletedStep = step;
                    break;
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
        if (String.isBlank(lastComment))
            lastComment = NA;

        Map<String, Object> outputMap = new Map<String, Object>{
            'isSuccess' => true,
            'recordId' => args.recordSObjectId,
            'recordName' => instance.TargetObject?.Name ?? NA,
            'processInstanceId' => instance.Id,
            'overallStatus' => status,
            'currentAssignee' => assignedTo,
            'lastActionBy' => lastActorName,
            'lastComment' => lastComment,
            'processInitiatedDate' => instance.CreatedDate,
            'processCompletedDate' => instance.CompletedDate,
            'lastActionDate' => lastActionDate
        };

        String internalDetails = 'Status=' + status + ', Assignee=' + assignedTo + ' for InstanceId=' + instance.Id;

        return this.success(outputMap, internalDetails);
    }
}
