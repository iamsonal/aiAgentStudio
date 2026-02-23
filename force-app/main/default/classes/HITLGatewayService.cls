/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Centralized gateway for all Human-in-the-Loop (HITL) decisions.
 *
 * Supported modes:
 *   - Confirmation            — No system record created; handled entirely via LLM prompt injection.
 *   - Approval                — Creates a PendingHITLAction__c and submits it to an Approval Process.
 *   - ConfirmationThenApproval — Like Approval, but requires prior chat confirmation from the user.
 *   - ConditionalApproval     — The LLM decides at runtime whether approval is needed.
 *                               Call evaluate() first to validate configuration, then
 *                               evaluateConditionalApproval() when the LLM signals approval is required.
 */
public with sharing class HITLGatewayService {
    public static final String HITL_MODE_CONFIRMATION = 'Confirmation';
    public static final String HITL_MODE_APPROVAL = 'Approval';
    public static final String HITL_MODE_CONFIRMATION_THEN_APPROVAL = 'ConfirmationThenApproval';
    public static final String HITL_MODE_CONDITIONAL_APPROVAL = 'ConditionalApproval';

    public static final String STATUS_PENDING = 'Pending';
    public static final String STATUS_CONFIRMED = 'Confirmed';
    public static final String STATUS_DECLINED = 'Declined';
    public static final String STATUS_APPROVED = 'Approved';
    public static final String STATUS_REJECTED = 'Rejected';
    public static final String STATUS_EXPIRED = 'Expired';

    public static final String AGENT_TYPE_CONVERSATIONAL = 'Conversational';
    public static final String AGENT_TYPE_FUNCTION = 'Function';
    public static final String AGENT_TYPE_WORKFLOW = 'Workflow';

    // Notification preference constants
    public static final String NOTIFICATION_PREF_ALWAYS_NOTIFY = 'Always Notify';
    public static final String NOTIFICATION_PREF_REJECTION_ONLY = 'Notify on Rejection Only';

    // Notification event type constants
    public static final String NOTIFICATION_TYPE_APPROVAL = 'approval';
    public static final String NOTIFICATION_TYPE_REJECTION = 'rejection';
    public static final String NOTIFICATION_TYPE_ERROR = 'error';

    private static final String LOG_PREFIX = '[HITLGateway] ';

    public class HITLConfigurationException extends Exception {
    }

    public class HITLProcessingException extends Exception {
    }

    public class HITLContext {
        public AgentCapability__c capability { get; set; }
        public AIAgentDefinition__c agentDefinition { get; set; }
        public Id executionId { get; set; }
        public Id requestingUserId { get; set; }
        public String turnIdentifier { get; set; }
        public Integer turnCount { get; set; }
        public String toolCallId { get; set; }
        public String toolArguments { get; set; }
        public Id sourceRecordId { get; set; }
        public String logPrefix { get; set; }
        // LLM-driven conditional approval fields
        public Boolean isConditionalApproval { get; set; } // true if HITLMode = ConditionalApproval
        public String llmApprovalReason { get; set; } // From _approvalReason parameter

        public HITLContext() {
            this.logPrefix = LOG_PREFIX;
        }

        public void validate() {
            List<String> missingFields = new List<String>();

            if (this.capability == null)
                missingFields.add('capability');
            if (this.agentDefinition == null)
                missingFields.add('agentDefinition');
            if (this.executionId == null)
                missingFields.add('executionId');
            if (String.isBlank(this.turnIdentifier))
                missingFields.add('turnIdentifier');
            if (String.isBlank(this.toolCallId))
                missingFields.add('toolCallId');

            if (!missingFields.isEmpty()) {
                throw new HITLConfigurationException('HITLContext validation failed. Missing required fields: ' + String.join(missingFields, ', '));
            }
        }
    }

    public class HITLDecision {
        public Boolean requiresIntervention { get; set; }
        public String hitlMode { get; set; }
        public Boolean isValidConfiguration { get; set; }
        public String configurationError { get; set; }

        public HITLDecision() {
            this.requiresIntervention = false;
            this.isValidConfiguration = true;
        }
    }

    public static HITLDecision createProceedDecision() {
        HITLDecision decision = new HITLDecision();
        decision.requiresIntervention = false;
        decision.isValidConfiguration = true;
        decision.configurationError = null;
        return decision;
    }

    public static HITLDecision createInterventionDecision(String mode) {
        HITLDecision decision = new HITLDecision();
        decision.requiresIntervention = true;
        decision.hitlMode = mode;
        decision.isValidConfiguration = true;
        decision.configurationError = null;
        return decision;
    }

    public static HITLDecision createInvalidConfigDecision(String errorMessage) {
        HITLDecision decision = new HITLDecision();
        decision.requiresIntervention = false;
        decision.hitlMode = null;
        decision.isValidConfiguration = false;
        decision.configurationError = errorMessage;
        return decision;
    }

    public class HITLResult {
        public Boolean success { get; set; }
        public Id pendingActionId { get; set; }
        public String confirmationPrompt { get; set; }
        public String errorMessage { get; set; }
        public String hitlType { get; set; }
        public DateTime expiresAt { get; set; }

        public HITLResult() {
            this.success = false;
        }
    }

    public static HITLResult createSuccessResult(Id actionId, String prompt, String hitlType, DateTime expires) {
        HITLResult result = new HITLResult();
        result.success = true;
        result.pendingActionId = actionId;
        result.confirmationPrompt = prompt;
        result.hitlType = hitlType;
        result.expiresAt = expires;
        return result;
    }

    public static HITLResult createFailureResult(String error) {
        HITLResult result = new HITLResult();
        result.success = false;
        result.errorMessage = error;
        return result;
    }

    public class HITLResolutionResult {
        public Boolean success { get; set; }
        public String status { get; set; }
        public Boolean shouldProceed { get; set; }
        public String toolArguments { get; set; }
        public AgentCapability__c capability { get; set; }
        public String errorMessage { get; set; }
        public String llmMessage { get; set; }

        public HITLResolutionResult() {
            this.success = false;
            this.shouldProceed = false;
        }
    }

    public static HITLDecision evaluate(HITLContext context) {
        context.validate();
        String debugPrefix = context.logPrefix + '[evaluate] ';

        String hitlMode = context.capability.HITLMode__c;
        if (String.isBlank(hitlMode)) {
            hitlMode = null;
        }

        System.debug(
            LoggingLevel.DEBUG,
            debugPrefix +
                'Evaluating HITL for capability: ' +
                context.capability.CapabilityName__c +
                ', HITLMode: ' +
                hitlMode +
                ', AgentType: ' +
                context.agentDefinition.AgentType__c
        );

        if (hitlMode == null) {
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'No HITL required (mode=None)');
            return createProceedDecision();
        }

        if (hitlMode == HITL_MODE_CONFIRMATION) {
            if (context.agentDefinition.AgentType__c != AGENT_TYPE_CONVERSATIONAL) {
                String errorMsg =
                    'Confirmation mode is only supported for Conversational agents. ' +
                    'Capability "' +
                    context.capability.CapabilityName__c +
                    '" has HITLMode=Confirmation ' +
                    'but agent "' +
                    context.agentDefinition.DeveloperName__c +
                    '" is type "' +
                    context.agentDefinition.AgentType__c +
                    '". Use Approval mode instead or change agent type.';
                System.debug(LoggingLevel.ERROR, debugPrefix + errorMsg);
                return createInvalidConfigDecision(errorMsg);
            }

            if (context.capability.RunAsynchronously__c == true) {
                String errorMsg =
                    'Confirmation mode cannot be used with asynchronous tools. ' +
                    'Capability "' +
                    context.capability.CapabilityName__c +
                    '" has both HITLMode=Confirmation ' +
                    'and RunAsynchronously=true. Use Approval mode for async tools requiring human oversight.';
                System.debug(LoggingLevel.ERROR, debugPrefix + errorMsg);
                return createInvalidConfigDecision(errorMsg);
            }

            System.debug(LoggingLevel.DEBUG, debugPrefix + 'Confirmation mode - no system intervention needed (prompt injection handles this)');
            return createProceedDecision();
        }

        if (hitlMode == HITL_MODE_CONFIRMATION_THEN_APPROVAL) {
            if (context.agentDefinition.AgentType__c != AGENT_TYPE_CONVERSATIONAL) {
                String errorMsg =
                    'ConfirmationThenApproval mode is only supported for Conversational agents. ' +
                    'Capability "' +
                    context.capability.CapabilityName__c +
                    '" has HITLMode=ConfirmationThenApproval ' +
                    'but agent "' +
                    context.agentDefinition.DeveloperName__c +
                    '" is type "' +
                    context.agentDefinition.AgentType__c +
                    '". Use Approval mode instead.';
                System.debug(LoggingLevel.ERROR, debugPrefix + errorMsg);
                return createInvalidConfigDecision(errorMsg);
            }

            if (context.capability.RunAsynchronously__c == true) {
                String errorMsg =
                    'ConfirmationThenApproval mode cannot be used with asynchronous tools. ' +
                    'Capability "' +
                    context.capability.CapabilityName__c +
                    '" has both HITLMode=ConfirmationThenApproval ' +
                    'and RunAsynchronously=true. Use Approval mode for async tools requiring human oversight.';
                System.debug(LoggingLevel.ERROR, debugPrefix + errorMsg);
                return createInvalidConfigDecision(errorMsg);
            }

            System.debug(LoggingLevel.INFO, debugPrefix + 'HITL ConfirmationThenApproval required for: ' + context.capability.CapabilityName__c);
            return createInterventionDecision(HITL_MODE_CONFIRMATION_THEN_APPROVAL);
        }

        if (hitlMode == HITL_MODE_APPROVAL) {
            System.debug(LoggingLevel.INFO, debugPrefix + 'HITL Approval required for: ' + context.capability.CapabilityName__c);
            return createInterventionDecision(HITL_MODE_APPROVAL);
        }

        if (hitlMode == HITL_MODE_CONDITIONAL_APPROVAL) {
            // Configuration is valid. The LLM decides at execution time via _requiresApproval.
            // If the LLM signals approval is needed, the caller must then invoke evaluateConditionalApproval().
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'ConditionalApproval mode configured - call evaluateConditionalApproval() if LLM requests approval');
            return createProceedDecision();
        }

        String errorMsg =
            'Unknown HITLMode value: "' +
            hitlMode +
            '" for capability "' +
            context.capability.CapabilityName__c +
            '". Valid values are: None, Confirmation, Approval, ConfirmationThenApproval, ConditionalApproval.';
        System.debug(LoggingLevel.ERROR, debugPrefix + errorMsg);
        return createInvalidConfigDecision(errorMsg);
    }

    /**
     * @description Produces an Approval intervention decision for ConditionalApproval mode.
     *
     * Call this method when the LLM has signalled (via the _requiresApproval parameter) that
     * the current tool invocation requires human approval. The returned decision can be passed
     * directly to initiateHITL().
     *
     * This keeps ConditionalApproval routing inside the gateway rather than scattering it
     * across response-handler code.
     *
     * @param context A fully populated HITLContext (validate() will be called internally).
     * @return An HITLDecision set to Approval intervention.
     */
    public static HITLDecision evaluateConditionalApproval(HITLContext context) {
        context.validate();
        System.debug(
            LoggingLevel.INFO,
            context.logPrefix +
                '[evaluateConditionalApproval] LLM-driven approval required for capability: ' +
                context.capability.CapabilityName__c +
                (String.isNotBlank(context.llmApprovalReason) ? '. Reason: ' + context.llmApprovalReason : '')
        );
        return createInterventionDecision(HITL_MODE_APPROVAL);
    }

    public static HITLResult initiateHITL(HITLContext context, HITLDecision decision) {
        String debugPrefix = context.logPrefix + '[initiateHITL] ';

        if (!decision.requiresIntervention) {
            return createFailureResult('Cannot initiate HITL when intervention is not required');
        }

        if (!decision.isValidConfiguration) {
            return createFailureResult('Cannot initiate HITL with invalid configuration: ' + decision.configurationError);
        }

        try {
            if (decision.hitlMode == HITL_MODE_APPROVAL) {
                return initiateApproval(context, debugPrefix);
            } else if (decision.hitlMode == HITL_MODE_CONFIRMATION_THEN_APPROVAL) {
                return initiateConfirmationThenApproval(context, debugPrefix);
            } else {
                return createFailureResult('Unknown HITL mode for initiation: ' + decision.hitlMode);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Failed to initiate HITL: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return createFailureResult('Failed to initiate HITL workflow: ' + e.getMessage());
        }
    }

    private static HITLResult initiateConfirmationThenApproval(HITLContext context, String debugPrefix) {
        System.debug(LoggingLevel.INFO, debugPrefix + 'Initiating ConfirmationThenApproval HITL for tool: ' + context.capability.CapabilityName__c);

        String approvalPrompt = generateApprovalPrompt(context);

        PendingHITLAction__c pendingAction = new PendingHITLAction__c(
            AgentExecution__c = context.executionId,
            AIAgentCapability__c = context.capability.Id,
            HITLType__c = HITL_MODE_CONFIRMATION_THEN_APPROVAL,
            Status__c = STATUS_PENDING,
            TurnIdentifier__c = context.turnIdentifier,
            TurnCount__c = context.turnCount,
            ToolCallId__c = context.toolCallId,
            ToolName__c = context.capability.CapabilityName__c,
            ToolArgumentsJSON__c = context.toolArguments,
            ConfirmationPrompt__c = approvalPrompt,
            RequestedAt__c = DateTime.now(),
            RequestingUser__c = context.requestingUserId,
            SourceRecordId__c = context.sourceRecordId != null ? String.valueOf(context.sourceRecordId) : null
        );

        insert pendingAction;
        System.debug(LoggingLevel.INFO, debugPrefix + 'Created PendingHITLAction for ConfirmationThenApproval: ' + pendingAction.Id);

        try {
            Approval.ProcessSubmitRequest approvalRequest = new Approval.ProcessSubmitRequest();
            approvalRequest.setObjectId(pendingAction.Id);
            approvalRequest.setComments(
                'AI Agent action requires approval (user confirmed in chat). Tool: ' +
                    context.capability.CapabilityName__c +
                    '. Justification: ' +
                    approvalPrompt
            );

            Approval.ProcessResult approvalResult = Approval.process(approvalRequest);

            if (approvalResult.isSuccess()) {
                pendingAction.ApprovalProcessInstanceId__c = approvalResult.getInstanceId();
                Database.SaveResult saveResult = Database.update(pendingAction, false);

                if (!saveResult.isSuccess()) {
                    System.debug(
                        LoggingLevel.WARN,
                        debugPrefix +
                            'Could not update ApprovalProcessInstanceId due to record lock (this is expected): ' +
                            saveResult.getErrors()[0].getMessage()
                    );
                    System.debug(
                        LoggingLevel.INFO,
                        debugPrefix + 'Approval process submitted successfully despite update failure. Instance ID: ' + approvalResult.getInstanceId()
                    );
                } else {
                    System.debug(LoggingLevel.INFO, debugPrefix + 'Submitted to approval process. Instance ID: ' + approvalResult.getInstanceId());
                }

                return createSuccessResult(pendingAction.Id, approvalPrompt, HITL_MODE_CONFIRMATION_THEN_APPROVAL, null);
            } else {
                // COVERAGE NOTE: This error path is untestable in unit tests because Approval.process()
                // succeeds by default in test context even without a configured approval process.
                // This is defensive error handling for production scenarios where approval process
                // configuration is missing or invalid.
                String errors = '';
                for (Database.Error err : approvalResult.getErrors()) {
                    errors += err.getMessage() + '; ';
                }
                System.debug(LoggingLevel.ERROR, debugPrefix + 'Approval submission failed: ' + errors);

                Database.DeleteResult deleteResult = Database.delete(pendingAction, false);
                if (!deleteResult.isSuccess()) {
                    System.debug(
                        LoggingLevel.WARN,
                        debugPrefix + 'Could not delete PendingHITLAction after approval failure: ' + deleteResult.getErrors()[0].getMessage()
                    );
                }

                return createFailureResult('Failed to submit to approval process: ' + errors);
            }
        } catch (Exception e) {
            // COVERAGE NOTE: This exception path is untestable in unit tests because Approval.process()
            // rarely throws exceptions in test context. This is defensive error handling for production
            // scenarios where unexpected approval process exceptions may occur.
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Exception submitting approval: ' + e.getMessage());
            try {
                Database.DeleteResult deleteResult = Database.delete(pendingAction, false);
                if (!deleteResult.isSuccess()) {
                    System.debug(
                        LoggingLevel.WARN,
                        debugPrefix + 'Could not delete PendingHITLAction after exception: ' + deleteResult.getErrors()[0].getMessage()
                    );
                }
            } catch (Exception deleteEx) {
                System.debug(LoggingLevel.WARN, debugPrefix + 'Exception during cleanup delete: ' + deleteEx.getMessage());
            }
            return createFailureResult('Exception submitting to approval process: ' + e.getMessage());
        }
    }

    private static HITLResult initiateApproval(HITLContext context, String debugPrefix) {
        System.debug(LoggingLevel.INFO, debugPrefix + 'Initiating Approval HITL for tool: ' + context.capability.CapabilityName__c);

        String approvalPrompt = generateApprovalPrompt(context);

        PendingHITLAction__c pendingAction = new PendingHITLAction__c(
            AgentExecution__c = context.executionId,
            AIAgentCapability__c = context.capability.Id,
            HITLType__c = HITL_MODE_APPROVAL,
            Status__c = STATUS_PENDING,
            TurnIdentifier__c = context.turnIdentifier,
            TurnCount__c = context.turnCount,
            ToolCallId__c = context.toolCallId,
            ToolName__c = context.capability.CapabilityName__c,
            ToolArgumentsJSON__c = context.toolArguments,
            ConfirmationPrompt__c = approvalPrompt,
            RequestedAt__c = DateTime.now(),
            RequestingUser__c = context.requestingUserId,
            SourceRecordId__c = context.sourceRecordId != null ? String.valueOf(context.sourceRecordId) : null
        );

        insert pendingAction;
        System.debug(LoggingLevel.INFO, debugPrefix + 'Created PendingHITLAction for approval: ' + pendingAction.Id);

        // Submit to Salesforce Approval Process
        try {
            Approval.ProcessSubmitRequest approvalRequest = new Approval.ProcessSubmitRequest();
            approvalRequest.setObjectId(pendingAction.Id);
            approvalRequest.setComments(
                'AI Agent action requires approval. Tool: ' + context.capability.CapabilityName__c + '. Justification: ' + approvalPrompt
            );

            Approval.ProcessResult approvalResult = Approval.process(approvalRequest);

            if (approvalResult.isSuccess()) {
                // Update with approval process instance ID
                // Use Database.update with allOrNone=false to handle record locking gracefully
                pendingAction.ApprovalProcessInstanceId__c = approvalResult.getInstanceId();
                Database.SaveResult saveResult = Database.update(pendingAction, false);

                if (!saveResult.isSuccess()) {
                    // Log the update failure but don't fail the entire approval process
                    System.debug(
                        LoggingLevel.WARN,
                        debugPrefix +
                            'Could not update ApprovalProcessInstanceId due to record lock (this is expected): ' +
                            saveResult.getErrors()[0].getMessage()
                    );
                    System.debug(
                        LoggingLevel.INFO,
                        debugPrefix + 'Approval process submitted successfully despite update failure. Instance ID: ' + approvalResult.getInstanceId()
                    );
                } else {
                    System.debug(LoggingLevel.INFO, debugPrefix + 'Submitted to approval process. Instance ID: ' + approvalResult.getInstanceId());
                }

                return createSuccessResult(pendingAction.Id, approvalPrompt, HITL_MODE_APPROVAL, null);
            } else {
                // COVERAGE NOTE: This error path is untestable in unit tests because Approval.process()
                // succeeds by default in test context even without a configured approval process.
                // This is defensive error handling for production scenarios where approval process
                // configuration is missing or invalid.
                String errors = '';
                for (Database.Error err : approvalResult.getErrors()) {
                    errors += err.getMessage() + '; ';
                }
                System.debug(LoggingLevel.ERROR, debugPrefix + 'Approval submission failed: ' + errors);

                Database.DeleteResult deleteResult = Database.delete(pendingAction, false);
                if (!deleteResult.isSuccess()) {
                    System.debug(
                        LoggingLevel.WARN,
                        debugPrefix + 'Could not delete PendingHITLAction after approval failure: ' + deleteResult.getErrors()[0].getMessage()
                    );
                }

                return createFailureResult('Failed to submit to approval process: ' + errors);
            }
        } catch (Exception e) {
            // COVERAGE NOTE: This exception path is untestable in unit tests because Approval.process()
            // rarely throws exceptions in test context. This is defensive error handling for production
            // scenarios where unexpected approval process exceptions may occur.
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Exception submitting approval: ' + e.getMessage());
            try {
                Database.DeleteResult deleteResult = Database.delete(pendingAction, false);
                if (!deleteResult.isSuccess()) {
                    System.debug(
                        LoggingLevel.WARN,
                        debugPrefix + 'Could not delete PendingHITLAction after exception: ' + deleteResult.getErrors()[0].getMessage()
                    );
                }
            } catch (Exception deleteEx) {
                System.debug(LoggingLevel.WARN, debugPrefix + 'Exception during cleanup delete: ' + deleteEx.getMessage());
            }
            return createFailureResult('Exception submitting to approval process: ' + e.getMessage());
        }
    }

    public static HITLResolutionResult resolveApproval(Id pendingActionId, Boolean approved, Id approverId, String comment) {
        String debugPrefix = LOG_PREFIX + '[resolveApproval] ';
        HITLResolutionResult result = new HITLResolutionResult();

        try {
            List<PendingHITLAction__c> actions = [
                SELECT
                    Id,
                    Status__c,
                    HITLType__c,
                    ToolCallId__c,
                    ToolName__c,
                    ToolArgumentsJSON__c,
                    AIAgentCapability__c,
                    AgentExecution__c,
                    TurnIdentifier__c,
                    TurnCount__c,
                    RequestingUser__c
                FROM PendingHITLAction__c
                WHERE Id = :pendingActionId
                FOR UPDATE
            ];

            if (actions.isEmpty()) {
                result.errorMessage = 'Pending HITL action not found: ' + pendingActionId;
                System.debug(LoggingLevel.ERROR, debugPrefix + result.errorMessage);
                return result;
            }

            PendingHITLAction__c action = actions[0];

            if (action.HITLType__c != HITL_MODE_APPROVAL && action.HITLType__c != HITL_MODE_CONFIRMATION_THEN_APPROVAL) {
                result.errorMessage =
                    'Cannot resolve action with resolveApproval. ' +
                    'Action type is: ' +
                    action.HITLType__c +
                    '. Expected Approval or ConfirmationThenApproval.';
                System.debug(LoggingLevel.ERROR, debugPrefix + result.errorMessage);
                return result;
            }

            action.Status__c = approved ? STATUS_APPROVED : STATUS_REJECTED;
            action.ResolvedAt__c = DateTime.now();
            action.ResolvedBy__c = approverId;
            action.ResolutionComment__c = comment;
            update action;

            result.success = true;
            result.status = action.Status__c;
            result.shouldProceed = approved;
            result.toolArguments = action.ToolArgumentsJSON__c;

            if (approved) {
                result.llmMessage = 'Action "' + action.ToolName__c + '" has been approved. Proceeding with execution.';
                System.debug(LoggingLevel.INFO, debugPrefix + 'Action approved: ' + pendingActionId);

                if (action.AIAgentCapability__c != null) {
                    result.capability = AIAgentConfigService.getCapabilityById(action.AIAgentCapability__c);
                }
            } else {
                result.llmMessage = 'Action "' + action.ToolName__c + '" was rejected by approver.';
                if (String.isNotBlank(comment)) {
                    result.llmMessage += ' Reason: ' + comment;
                }
                System.debug(LoggingLevel.INFO, debugPrefix + 'Action rejected: ' + pendingActionId);
            }

            return result;
        } catch (Exception e) {
            result.errorMessage = 'Error resolving approval: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, debugPrefix + result.errorMessage + '\n' + e.getStackTraceString());
            return result;
        }
    }

    public static PendingHITLAction__c getPendingAction(Id pendingActionId) {
        List<PendingHITLAction__c> actions = [
            SELECT
                Id,
                Name,
                Status__c,
                HITLType__c,
                ToolCallId__c,
                ToolName__c,
                ToolArgumentsJSON__c,
                ConfirmationPrompt__c,
                AIAgentCapability__c,
                AIAgentCapability__r.CapabilityName__c,
                AIAgentCapability__r.HITLNotificationPreference__c,
                AgentExecution__c,
                TurnIdentifier__c,
                TurnCount__c,
                ExpiresAt__c,
                RequestedAt__c,
                ResolvedAt__c,
                ResolvedBy__c,
                ResolutionComment__c,
                RequestingUser__c,
                SourceRecordId__c,
                ApprovalProcessInstanceId__c
            FROM PendingHITLAction__c
            WHERE Id = :pendingActionId
            LIMIT 1
        ];
        return actions.isEmpty() ? null : actions[0];
    }

    public static List<PendingHITLAction__c> getPendingActionsForExecution(Id executionId) {
        return [
            SELECT
                Id,
                Name,
                Status__c,
                HITLType__c,
                ToolCallId__c,
                ToolName__c,
                ToolArgumentsJSON__c,
                ConfirmationPrompt__c,
                AIAgentCapability__c,
                AIAgentCapability__r.CapabilityName__c,
                AgentExecution__c,
                TurnIdentifier__c,
                TurnCount__c,
                ExpiresAt__c,
                RequestedAt__c,
                ResolvedAt__c,
                ResolvedBy__c,
                ResolutionComment__c,
                RequestingUser__c,
                SourceRecordId__c
            FROM PendingHITLAction__c
            WHERE AgentExecution__c = :executionId AND Status__c = :STATUS_PENDING
            ORDER BY RequestedAt__c ASC
        ];
    }

    public static Boolean hasPendingActions(Id executionId) {
        return [
                SELECT COUNT()
                FROM PendingHITLAction__c
                WHERE AgentExecution__c = :executionId AND Status__c = :STATUS_PENDING
            ] > 0;
    }
    public static Boolean shouldSendHITLNotification(String preference, String eventType) {
        if (String.isBlank(preference)) {
            return false;
        }

        if (preference == NOTIFICATION_PREF_ALWAYS_NOTIFY) {
            return true;
        }

        if (preference == NOTIFICATION_PREF_REJECTION_ONLY) {
            return eventType == NOTIFICATION_TYPE_REJECTION;
        }

        return false;
    }

    private static String generateApprovalPrompt(HITLContext context) {
        String toolName = context.capability.CapabilityName__c;

        // Extract business-relevant parameters
        Map<String, Object> args = new Map<String, Object>();
        try {
            args = (Map<String, Object>) JSON.deserializeUntyped(context.toolArguments);
        } catch (Exception e) {
            // Fallback to empty map
        }

        // Build concise prompt
        String prompt = '## ⚠️ Approval Required\n\n';

        // What's being requested (extract from recordData if available)
        if (args.containsKey('recordData')) {
            try {
                Map<String, Object> recordData = (Map<String, Object>) args.get('recordData');
                String subject = (String) recordData.get('Subject');
                if (String.isNotBlank(subject)) {
                    prompt += '**' + subject + '**\n\n';
                }
            } catch (Exception e) {
                prompt += '**' + formatToolName(toolName) + '**\n\n';
            }
        } else {
            prompt += '**' + formatToolName(toolName) + '**\n\n';
        }

        // Why approval is needed
        if (context.isConditionalApproval && String.isNotBlank(context.llmApprovalReason)) {
            prompt += context.llmApprovalReason + '\n\n';
        }

        // Key details (compact)
        String details = extractKeyDetails(args);
        if (String.isNotBlank(details)) {
            prompt += details;
        }

        return prompt;
    }

    private static String extractKeyDetails(Map<String, Object> args) {
        String details = '';

        if (args.containsKey('recordData')) {
            try {
                Map<String, Object> recordData = (Map<String, Object>) args.get('recordData');
                String activityDate = (String) recordData.get('ActivityDate');
                String priority = (String) recordData.get('Priority');

                List<String> items = new List<String>();
                if (String.isNotBlank(activityDate)) {
                    items.add('Due: ' + activityDate);
                }
                if (String.isNotBlank(priority)) {
                    items.add('Priority: ' + priority);
                }

                if (!items.isEmpty()) {
                    details = String.join(items, ' • ') + '\n';
                }
            } catch (Exception e) {
                // Fallback
            }
        }

        return details;
    }

    private static String formatToolName(String toolName) {
        // Convert snake_case to Title Case
        if (String.isBlank(toolName)) {
            return 'Unknown Action';
        }
        return toolName.replace('_', ' ').capitalize();
    }

    /**
     * @description Sends custom platform notification to a Salesforce user
     * @param recipientId User ID to send notification to
     * @param title Notification title
     * @param body Notification body text
     * @param targetId Optional record ID to associate with notification (e.g., AgentExecution__c ID)
     */
    public static void sendUserNotification(Id recipientId, String title, String body, Id targetId) {
        String logPrefix = LOG_PREFIX + '[sendNotification] ';
        final String NOTIFICATION_TYPE_API_NAME = 'AI_Agent_Action_Status';

        if (recipientId == null || String.isBlank(title) || String.isBlank(body)) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Notification not sent: missing required parameter(s) (recipientId, title, or body).');
            return;
        }

        try {
            List<CustomNotificationType> notificationTypes = [
                SELECT Id
                FROM CustomNotificationType
                WHERE DeveloperName = :NOTIFICATION_TYPE_API_NAME
                LIMIT 1
            ];
            if (notificationTypes.isEmpty()) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Notification not sent: Custom notification type not found (' + NOTIFICATION_TYPE_API_NAME + ').');
                return;
            }

            // Construct and send the notification
            Messaging.CustomNotification notification = new Messaging.CustomNotification();
            notification.setTitle(title);
            notification.setBody(body);
            notification.setSenderId(UserInfo.getUserId());
            notification.setNotificationTypeId(notificationTypes[0].Id);
            if (targetId != null) {
                notification.setTargetId(targetId);
            }
            Set<String> recipients = new Set<String>{ recipientId };
            notification.send(recipients);
            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Notification sent to user ' + recipientId + ' (type: ' + NOTIFICATION_TYPE_API_NAME + ', title: "' + title + '").'
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Notification delivery failed for user ' + recipientId + ': ' + e.getMessage());
        }
    }
}
