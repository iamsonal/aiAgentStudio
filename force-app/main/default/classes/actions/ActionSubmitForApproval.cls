/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Standard Action: Submits a Salesforce record into a predefined approval process.
 *              Extends BaseAgentAction for standardized execution flow and error handling.
 * @author AI Agent Framework Team
 * @date 2025-04-18 (Updated for BaseAgentAction)
 * @extends BaseAgentAction
 */
public with sharing class ActionSubmitForApproval extends BaseAgentAction {
    private static final String ARG_RECORD_ID = 'recordId';
    private static final String ARG_SUBMITTER_COMMENT = 'submitterComment';
    private static final String ARG_PROCESS_DEF_NAME_OR_ID = 'processDefinitionNameOrId';
    private static final String ARG_NEXT_APPROVER_IDS = 'nextApproverIds';
    private static final String ARG_SKIP_ENTRY_CRITERIA = 'skipEntryCriteria';

    private static final String ERR_CODE_INPUT = AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
    private static final String ERR_CODE_LOCKED = AIAgentConstants.ERR_CODE_RECORD_LOCKED;
    private static final String ERR_CODE_APPROVAL_FAILURE = 'APPROVAL_SUBMIT_FAILED';
    private static final String ERR_CODE_NO_PROCESS = AIAgentConstants.ERR_CODE_CONFIG_ERROR;
    private static final String ERR_CODE_SECURITY = AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
    private static final String ERR_CODE_UNEXPECTED = AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;

    /**
     * @description Provides a specific log prefix for this action type.
     * @return String 'ActionSubmitForApproval'
     */
    protected override String getLogPrefixName() {
        return 'ActionSubmitForApproval';
    }

    /**
     * @description Parses ActionConfiguration. SubmitForApproval generally doesn't need config.
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
     * @description Defines the structure for arguments specific to SubmitForApproval.
     */
    class SubmitApprovalParsedArguments extends BaseAgentAction.ParsedArguments {
        public Id recordId { get; private set; }
        public String submitterComment { get; private set; }
        public String processDefinitionNameOrId { get; private set; }
        public List<Id> nextApproverIds { get; private set; }
        public Boolean skipEntryCriteria { get; private set; }

        /**
         * @description Constructor that parses and validates JSON arguments
         * @param jsonArguments JSON string with arguments
         * @throws ValidationException If arguments are invalid
         */
        public SubmitApprovalParsedArguments(String jsonArguments) {
            if (String.isBlank(jsonArguments)) {
                throw new ValidationException('Input arguments JSON cannot be blank.', null);
            }

            Map<String, Object> parsedArgs = (Map<String, Object>) JSON.deserializeUntyped(jsonArguments);

            this.recordId = ActionParamUtils.getRequiredId(parsedArgs, ARG_RECORD_ID, null);
            this.submitterComment = ActionParamUtils.getOptionalString(parsedArgs, ARG_SUBMITTER_COMMENT);
            this.processDefinitionNameOrId = ActionParamUtils.getOptionalString(parsedArgs, ARG_PROCESS_DEF_NAME_OR_ID);
            this.nextApproverIds = parseIdList(parsedArgs.get(ARG_NEXT_APPROVER_IDS), ARG_NEXT_APPROVER_IDS);
            this.skipEntryCriteria = ActionParamUtils.getOptionalBoolean(parsedArgs, ARG_SKIP_ENTRY_CRITERIA, false);
        }

        /** Parses optional ID list, allowing string or list<string> input */
        private List<Id> parseIdList(Object approversObj, String key) {
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
                            'Invalid value in "' + key + '" list. All elements must be non-blank strings.',
                            key
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
                throw new ValidationException('Parameter "' + key + '" must be a String or List of Strings.', key);
            }

            for (String strId : stringIds) {
                try {
                    parsedIds.add(Id.valueOf(strId));
                } catch (Exception e) {
                    throw new ValidationException(
                        'Invalid Salesforce ID format found in parameter "' + key + '": ' + strId,
                        key
                    );
                }
            }
            return parsedIds;
        }
    }

    /**
     * @description Parses and validates the LLM arguments specific to SubmitForApproval.
     * @param argumentsJson Raw JSON string from the LLM.
     * @param logPrefix Logging prefix.
     * @return SubmitApprovalParsedArguments instance.
     * @throws ValidationException If arguments are invalid.
     */
    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(
        String argumentsJson,
        String logPrefix
    ) {
        try {
            return new SubmitApprovalParsedArguments(argumentsJson);
        } catch (Exception e) {
            throw new ValidationException(
                'Failed to parse/validate SubmitForApproval arguments: ' + e.getMessage(),
                null
            );
        }
    }

    /**
     * @description Core logic: checks locks/access, builds approval request, submits via Approval.process.
     * @param validatedArgs Parsed arguments (must be cast to SubmitApprovalParsedArguments).
     * @param logPrefix Logging prefix.
     * @return ActionResult Result of the submission.
     * @throws Exception For unexpected errors during approval processing (will be mapped by base).
     */
    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        SubmitApprovalParsedArguments params = (SubmitApprovalParsedArguments) validatedArgs;

        try {
            if (Approval.isLocked(params.recordId)) {
                return this.runtimeError('Record is locked and cannot be submitted.', ERR_CODE_LOCKED, null);
            }

            /*
            if (!hasAccessToSubmit(params.recordId)) {
                throw new ActionSecurityException('User lacks permissions to submit record: ' + params.recordId);
            }*/
        } catch (Exception checkEx) {
            throw checkEx;
        }

        Approval.ProcessSubmitRequest request = buildApprovalRequest(params);
        Approval.ProcessResult result = null;

        try {
            Approval.ProcessResult[] results = Approval.process(new List<Approval.ProcessSubmitRequest>{ request });
            if (results == null || results.isEmpty()) {
                throw new ApprovalSubmitException('Approval.process returned no results.');
            }
            result = results[0];
        } catch (Exception ex) {
            if (ex.getMessage().contains('UNABLE_TO_LOCK_ROW')) {
                return this.runtimeError('Record lock contention during submission.', ERR_CODE_LOCKED, ex);
            } else if (
                ex.getMessage().contains('INVALID_CROSS_REFERENCE_KEY') ||
                ex.getMessage().contains('NO_APPLICABLE_PROCESS') ||
                ex.getMessage().contains('PROCESS_DEFINITION_NOT_FOUND')
            ) {
                return this.runtimeError(
                    'Approval process not found or invalid for this record: ' + ex.getMessage(),
                    ERR_CODE_NO_PROCESS,
                    ex
                );
            } else if (ex.getMessage().contains('INSUFFICIENT_ACCESS')) {
                throw new ActionSecurityException(
                    'Insufficient permissions for approval submission: ' + ex.getMessage()
                );
            }

            throw ex;
        }

        if (result.isSuccess()) {
            String instanceId = result.getInstanceId();
            Map<String, Object> outputMap = new Map<String, Object>{
                'isSuccess' => true,
                'message' => 'Record ' +
                params.recordId +
                ' submitted for approval successfully.',
                'processInstanceId' => instanceId,
                'actorIds' => result.getActorIds()
            };

            return this.success(outputMap, 'Approval process initiated. Instance ID: ' + instanceId);
        } else {
            String errorMessage = processApprovalErrors(result.getErrors());
            String errorCode = determineApprovalErrorCode(errorMessage);
            return this.runtimeError(errorMessage, errorCode, null);
        }
    }

    /** Builds Approval.ProcessSubmitRequest */
    private Approval.ProcessSubmitRequest buildApprovalRequest(SubmitApprovalParsedArguments params) {
        Approval.ProcessSubmitRequest req = new Approval.ProcessSubmitRequest();
        req.setObjectId(params.recordId);
        if (String.isNotBlank(params.submitterComment))
            req.setComments(params.submitterComment);
        if (String.isNotBlank(params.processDefinitionNameOrId))
            req.setProcessDefinitionNameOrId(params.processDefinitionNameOrId);
        if (params.nextApproverIds != null && !params.nextApproverIds.isEmpty())
            req.setNextApproverIds(params.nextApproverIds);
        if (params.skipEntryCriteria != null)
            req.setSkipEntryCriteria(params.skipEntryCriteria);
        return req;
    }

    /** Processes Approval.ProcessResult errors */
    private String processApprovalErrors(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty())
            return 'Unknown approval process error.';
        List<String> errorMessages = new List<String>();
        for (Database.Error err : errors) {
            errorMessages.add(err.getStatusCode() + ': ' + err.getMessage());
        }
        return String.join(errorMessages, '; ');
    }

    /** Determines error code from Approval error message */
    private String determineApprovalErrorCode(String combinedErrorMsg) {
        if (String.isBlank(combinedErrorMsg))
            return ERR_CODE_APPROVAL_FAILURE;
        String lowerCaseMsg = combinedErrorMsg.toLowerCase();
        if (lowerCaseMsg.contains('no applicable process') || lowerCaseMsg.contains('process_definition_not_found'))
            return ERR_CODE_NO_PROCESS;
        if (lowerCaseMsg.contains('unable to lock row'))
            return ERR_CODE_LOCKED;
        if (lowerCaseMsg.contains('insufficient access') || lowerCaseMsg.contains('access denied'))
            return ERR_CODE_SECURITY;
        return ERR_CODE_APPROVAL_FAILURE;
    }

    private class ApprovalSubmitException extends Exception {
    }
}
