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

    public static final String ARTIFACT_TYPE_TOOL_APPROVAL = 'Tool Approval';
    public static final String ARTIFACT_TYPE_OUTBOUND_DRAFT_REVIEW = 'Outbound Draft Review';
    public static final String APPROVAL_CATEGORY_TOOL_APPROVAL = 'Tool Approval';
    public static final String APPROVAL_CATEGORY_OUTBOUND_DRAFT_REVIEW = 'Outbound Draft Review';

    // Notification preference constants
    public static final String NOTIFICATION_PREF_ALWAYS_NOTIFY = 'Always Notify';
    public static final String NOTIFICATION_PREF_REJECTION_ONLY = 'Notify on Rejection Only';

    // Notification event type constants
    public static final String NOTIFICATION_TYPE_APPROVAL = 'approval';
    public static final String NOTIFICATION_TYPE_REJECTION = 'rejection';
    public static final String NOTIFICATION_TYPE_ERROR = 'error';

    private static final String LOG_PREFIX = '[HITLGateway] ';
    private static final String HITL_EXECUTION_IDENTITY_ERROR =
        'Approval-based HITL requires an execution identity. ' +
        'If the execution has ExecutionIdentityProfileDeveloperName__c, HITL uses that. ' +
        'Otherwise configure AIAgentFrameworkSettings__c.DefaultHITLExecIdentityProfile__c.';

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

    public class ReviewArtifactResult {
        public Boolean success { get; set; }
        public Id pendingActionId { get; set; }
        public String errorMessage { get; set; }
        public String confirmationPrompt { get; set; }
        public String hitlType { get; set; }

        public ReviewArtifactResult() {
            this.success = false;
        }
    }

    private class ApprovalSubmissionResult {
        public Boolean success { get; set; }
        public String errorMessage { get; set; }
        public Id processInstanceId { get; set; }

        public ApprovalSubmissionResult() {
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

    public static ReviewArtifactResult createDraftReviewArtifact(
        AIAgentDefinition__c agentDefinition,
        InteractionRuntimeModels.IInteractionChannel adapter,
        OrchestrationContext context,
        String contentResponse,
        String logPrefix
    ) {
        String debugPrefix = String.isNotBlank(logPrefix) ? logPrefix + '[HITLGateway] ' : '[HITLGateway] ';
        ReviewArtifactResult result = new ReviewArtifactResult();

        if (adapter == null) {
            result.errorMessage = 'Channel adapter is required to create a review artifact.';
            return result;
        }

        InteractionRuntimeModels.ReviewPayload reviewPayload = adapter.buildReviewPayload(agentDefinition, context, contentResponse, debugPrefix);
        if (reviewPayload == null || String.isBlank(reviewPayload.payloadJson)) {
            result.errorMessage = 'Channel adapter did not return a review payload.';
            return result;
        }

        List<AgentExecution__c> executions = [
            SELECT Id, User__c, SourceRecordId__c, InteractionChannel__c, ExecutionIdentityProfileDeveloperName__c, ExecutionIdentityNamedCredential__c
            FROM AgentExecution__c
            WHERE Id = :context.executionId
            LIMIT 1
        ];
        if (executions.isEmpty()) {
            result.errorMessage = 'Execution not found for review artifact creation: ' + context.executionId;
            return result;
        }

        AgentExecution__c execution = executions[0];
        AIAgentConfigService.ResolvedExecutionIdentity hitlExecutionIdentity;
        try {
            hitlExecutionIdentity = ensureApprovalBasedHitlExecutionIdentity(execution, true, debugPrefix);
        } catch (Exception e) {
            result.errorMessage = e.getMessage();
            return result;
        }
        String interactionChannel = String.isNotBlank(reviewPayload.interactionChannel) ? reviewPayload.interactionChannel : execution.InteractionChannel__c;
        if (String.isBlank(interactionChannel)) {
            interactionChannel = RuntimeRegistryService.getInteractionChannel(agentDefinition, context.executionId);
        }

        PendingHITLAction__c pendingAction = new PendingHITLAction__c(
            ArtifactType__c = ARTIFACT_TYPE_OUTBOUND_DRAFT_REVIEW,
            AgentExecution__c = context.executionId,
            HITLType__c = HITL_MODE_APPROVAL,
            Status__c = STATUS_PENDING,
            TurnIdentifier__c = context.turnIdentifier,
            TurnCount__c = context.currentTurnCount,
            ToolCallId__c = 'review-' + String.valueOf(context.turnIdentifier),
            ToolName__c = 'Review Before Send',
            ConfirmationPrompt__c = reviewPayload.summaryText,
            RequestingUser__c = context.originalUserId != null ? context.originalUserId : execution.User__c,
            RequestedAt__c = Datetime.now(),
            SourceRecordId__c = execution.SourceRecordId__c != null ? String.valueOf(execution.SourceRecordId__c) : null,
            InteractionChannel__c = interactionChannel,
            GeneratedPayloadJson__c = reviewPayload.payloadJson,
            ReviewedPayloadJson__c = reviewPayload.payloadJson
        );

        try {
            HITLApprovalRouteResolver.ResolvedRoute route = HITLApprovalRouteResolver.resolveForOutboundDraftReview(agentDefinition, interactionChannel);
            applyApprovalRouteSnapshot(pendingAction, route);
        } catch (Exception e) {
            result.errorMessage = 'Failed to resolve review approval route: ' + e.getMessage();
            return result;
        }

        insert pendingAction;
        result.pendingActionId = pendingAction.Id;
        result.confirmationPrompt = reviewPayload.summaryText;
        result.hitlType = HITL_MODE_APPROVAL;

        if (String.isNotBlank(reviewPayload.inboundDedupKey)) {
            new InteractionMessageService().updateInboundStatus(reviewPayload.inboundDedupKey, 'Drafted', null, null, null, pendingAction.Id);
        }

        try {
            ApprovalSubmissionResult submissionResult = submitPendingActionForApproval(
                pendingAction,
                'AI agent response requires review before send. Channel: ' +
                    interactionChannel +
                    '. Summary: ' +
                    (String.isNotBlank(reviewPayload.summaryText) ? reviewPayload.summaryText.abbreviate(1000) : 'No summary provided.'),
                debugPrefix
            );
            if (!submissionResult.success) {
                if (String.isNotBlank(reviewPayload.inboundDedupKey)) {
                    new InteractionMessageService()
                        .updateInboundStatus(
                            reviewPayload.inboundDedupKey,
                            'Failed',
                            null,
                            AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                            submissionResult.errorMessage
                        );
                }
                Database.delete(pendingAction, false);
                result.errorMessage = 'Failed to submit review artifact for approval: ' + submissionResult.errorMessage;
                return result;
            }
        } catch (Exception e) {
            if (String.isNotBlank(reviewPayload.inboundDedupKey)) {
                new InteractionMessageService()
                    .updateInboundStatus(reviewPayload.inboundDedupKey, 'Failed', null, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, e.getMessage());
            }
            Database.delete(pendingAction, false);
            result.errorMessage = 'Failed to create review artifact approval: ' + e.getMessage();
            return result;
        }

        result.success = true;
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
                ', Strategy: ' +
                context.agentDefinition.RuntimeStrategy__c
        );

        if (hitlMode == null) {
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'No HITL required (mode=None)');
            return createProceedDecision();
        }

        if (hitlMode == HITL_MODE_CONFIRMATION) {
            if (resolveRuntimeTraits(context).supportsConfirmationHitl != true) {
                String errorMsg =
                    'Confirmation mode is only supported for interactive chat agents. ' +
                    'Capability "' +
                    context.capability.CapabilityName__c +
                    '" has HITLMode=Confirmation ' +
                    'but agent "' +
                    context.agentDefinition.DeveloperName__c +
                    '" is strategy "' +
                    context.agentDefinition.RuntimeStrategy__c +
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
            if (resolveRuntimeTraits(context).supportsConfirmationHitl != true) {
                String errorMsg =
                    'ConfirmationThenApproval mode is only supported for interactive chat agents. ' +
                    'Capability "' +
                    context.capability.CapabilityName__c +
                    '" has HITLMode=ConfirmationThenApproval ' +
                    'but agent "' +
                    context.agentDefinition.DeveloperName__c +
                    '" is strategy "' +
                    context.agentDefinition.RuntimeStrategy__c +
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

            try {
                ensureApprovalBasedHitlExecutionIdentity(context.executionId, false, debugPrefix);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, debugPrefix + e.getMessage());
                return createInvalidConfigDecision(e.getMessage());
            }

            System.debug(LoggingLevel.INFO, debugPrefix + 'HITL ConfirmationThenApproval required for: ' + context.capability.CapabilityName__c);
            return createInterventionDecision(HITL_MODE_CONFIRMATION_THEN_APPROVAL);
        }

        if (hitlMode == HITL_MODE_APPROVAL) {
            try {
                ensureApprovalBasedHitlExecutionIdentity(context.executionId, false, debugPrefix);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, debugPrefix + e.getMessage());
                return createInvalidConfigDecision(e.getMessage());
            }
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

    private static InteractionRuntimeModels.TraitSet resolveRuntimeTraits(HITLContext context) {
        if (context != null && context.executionId != null) {
            return RuntimeRegistryService.getTraits(context.executionId);
        }

        AIAgentDefinition__c agentDefinition = context != null ? context.agentDefinition : null;
        String interactionChannel = RuntimeRegistryService.getInteractionChannel(agentDefinition, null);
        return RuntimeRegistryService.getTraits(agentDefinition, interactionChannel);
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
        try {
            ensureApprovalBasedHitlExecutionIdentity(context.executionId, false, context.logPrefix + '[evaluateConditionalApproval] ');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, context.logPrefix + '[evaluateConditionalApproval] ' + e.getMessage());
            return createInvalidConfigDecision(e.getMessage());
        }
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
        AIAgentConfigService.ResolvedExecutionIdentity hitlExecutionIdentity = ensureApprovalBasedHitlExecutionIdentity(context.executionId, true, debugPrefix);

        PendingHITLAction__c pendingAction = new PendingHITLAction__c(
            ArtifactType__c = ARTIFACT_TYPE_TOOL_APPROVAL,
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
            SourceRecordId__c = context.sourceRecordId != null ? String.valueOf(context.sourceRecordId) : null,
            InteractionChannel__c = RuntimeRegistryService.getInteractionChannel(context.agentDefinition, context.executionId)
        );

        try {
            HITLApprovalRouteResolver.ResolvedRoute route = HITLApprovalRouteResolver.resolveForToolApproval(
                context,
                pendingAction.InteractionChannel__c
            );
            applyApprovalRouteSnapshot(pendingAction, route);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Failed to resolve approval route: ' + e.getMessage());
            return createFailureResult('Failed to resolve approval route: ' + e.getMessage());
        }

        insert pendingAction;
        System.debug(LoggingLevel.INFO, debugPrefix + 'Created PendingHITLAction for ConfirmationThenApproval: ' + pendingAction.Id);

        try {
            ApprovalSubmissionResult submissionResult = submitPendingActionForApproval(
                pendingAction,
                'AI Agent action requires approval (user confirmed in chat). Tool: ' +
                    context.capability.CapabilityName__c +
                    '. Justification: ' +
                    approvalPrompt,
                debugPrefix
            );

            if (submissionResult.success) {
                return createSuccessResult(pendingAction.Id, approvalPrompt, HITL_MODE_CONFIRMATION_THEN_APPROVAL, null);
            }

            System.debug(LoggingLevel.ERROR, debugPrefix + 'Approval submission failed: ' + submissionResult.errorMessage);

            Database.DeleteResult deleteResult = Database.delete(pendingAction, false);
            if (!deleteResult.isSuccess()) {
                System.debug(
                    LoggingLevel.WARN,
                    debugPrefix + 'Could not delete PendingHITLAction after approval failure: ' + deleteResult.getErrors()[0].getMessage()
                );
            }

            return createFailureResult('Failed to submit to approval process: ' + submissionResult.errorMessage);
        } catch (Exception e) {
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
        AIAgentConfigService.ResolvedExecutionIdentity hitlExecutionIdentity = ensureApprovalBasedHitlExecutionIdentity(context.executionId, true, debugPrefix);

        PendingHITLAction__c pendingAction = new PendingHITLAction__c(
            ArtifactType__c = ARTIFACT_TYPE_TOOL_APPROVAL,
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
            SourceRecordId__c = context.sourceRecordId != null ? String.valueOf(context.sourceRecordId) : null,
            InteractionChannel__c = RuntimeRegistryService.getInteractionChannel(context.agentDefinition, context.executionId)
        );

        try {
            HITLApprovalRouteResolver.ResolvedRoute route = HITLApprovalRouteResolver.resolveForToolApproval(
                context,
                pendingAction.InteractionChannel__c
            );
            applyApprovalRouteSnapshot(pendingAction, route);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Failed to resolve approval route: ' + e.getMessage());
            return createFailureResult('Failed to resolve approval route: ' + e.getMessage());
        }

        insert pendingAction;
        System.debug(LoggingLevel.INFO, debugPrefix + 'Created PendingHITLAction for approval: ' + pendingAction.Id);

        // Submit to Salesforce Approval Process
        try {
            ApprovalSubmissionResult submissionResult = submitPendingActionForApproval(
                pendingAction,
                'AI Agent action requires approval. Tool: ' + context.capability.CapabilityName__c + '. Justification: ' + approvalPrompt,
                debugPrefix
            );

            if (submissionResult.success) {
                return createSuccessResult(pendingAction.Id, approvalPrompt, HITL_MODE_APPROVAL, null);
            }

            System.debug(LoggingLevel.ERROR, debugPrefix + 'Approval submission failed: ' + submissionResult.errorMessage);

            Database.DeleteResult deleteResult = Database.delete(pendingAction, false);
            if (!deleteResult.isSuccess()) {
                System.debug(
                    LoggingLevel.WARN,
                    debugPrefix + 'Could not delete PendingHITLAction after approval failure: ' + deleteResult.getErrors()[0].getMessage()
                );
            }

            return createFailureResult('Failed to submit to approval process: ' + submissionResult.errorMessage);
        } catch (Exception e) {
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
                    ArtifactType__c,
                    InteractionChannel__c,
                    ToolArgumentsJSON__c,
                    ReviewedPayloadJson__c,
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
            result.toolArguments = action.ArtifactType__c == ARTIFACT_TYPE_OUTBOUND_DRAFT_REVIEW ? action.ReviewedPayloadJson__c : action.ToolArgumentsJSON__c;

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
        return new PendingActionAccess().getPendingAction(pendingActionId);
    }

    public static List<PendingHITLAction__c> getPendingActionsForExecution(Id executionId) {
        return new PendingActionAccess().getPendingActionsForExecution(executionId);
    }

    private without sharing class PendingActionAccess {
        private PendingHITLAction__c getPendingAction(Id pendingActionId) {
            if (pendingActionId == null) {
                return null;
            }
            List<PendingHITLAction__c> actions = [
                SELECT
                    Id,
                    Name,
                    Status__c,
                    HITLType__c,
                    ToolCallId__c,
                    ToolName__c,
                    ArtifactType__c,
                    InteractionChannel__c,
                    ToolArgumentsJSON__c,
                    ConfirmationPrompt__c,
                    GeneratedPayloadJson__c,
                    ReviewedPayloadJson__c,
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
                    ApprovalProcessInstanceId__c,
                    ApprovalRouteDeveloperName__c,
                    ApprovalProcessDeveloperName__c,
                    ApprovalCategory__c,
                    ApproverRoutingType__c,
                    ApproverRoutingKey__c
                FROM PendingHITLAction__c
                WHERE Id = :pendingActionId
                LIMIT 1
            ];
            return actions.isEmpty() ? null : actions[0];
        }

        private List<PendingHITLAction__c> getPendingActionsForExecution(Id executionId) {
            if (executionId == null) {
                return new List<PendingHITLAction__c>();
            }
            return [
                SELECT
                    Id,
                    Name,
                    Status__c,
                    HITLType__c,
                    ToolCallId__c,
                    ToolName__c,
                    ArtifactType__c,
                    InteractionChannel__c,
                    ToolArgumentsJSON__c,
                    ConfirmationPrompt__c,
                    GeneratedPayloadJson__c,
                    ReviewedPayloadJson__c,
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
                    SourceRecordId__c,
                    ApprovalRouteDeveloperName__c,
                    ApprovalProcessDeveloperName__c,
                    ApprovalCategory__c,
                    ApproverRoutingType__c,
                    ApproverRoutingKey__c
                FROM PendingHITLAction__c
                WHERE AgentExecution__c = :executionId AND Status__c = :STATUS_PENDING
                ORDER BY RequestedAt__c ASC
            ];
        }
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

    private static void applyApprovalRouteSnapshot(
        PendingHITLAction__c pendingAction,
        HITLApprovalRouteResolver.ResolvedRoute route
    ) {
        if (pendingAction == null || route == null) {
            return;
        }

        pendingAction.ApprovalRouteDeveloperName__c = route.routeDeveloperName;
        pendingAction.ApprovalProcessDeveloperName__c = route.approvalProcessDeveloperName;
        pendingAction.ApprovalCategory__c = route.approvalCategory;
        pendingAction.ApproverRoutingType__c = route.approverRoutingType;
        pendingAction.ApproverRoutingKey__c = route.approverRoutingKey;
    }

    private static ApprovalSubmissionResult submitPendingActionForApproval(
        PendingHITLAction__c pendingAction,
        String comments,
        String debugPrefix
    ) {
        ApprovalSubmissionResult result = new ApprovalSubmissionResult();
        if (pendingAction == null || pendingAction.Id == null) {
            result.errorMessage = 'Pending action must be inserted before approval submission.';
            return result;
        }
        if (String.isBlank(pendingAction.ApprovalProcessDeveloperName__c)) {
            result.errorMessage = 'Pending action is missing ApprovalProcessDeveloperName__c.';
            return result;
        }

        Approval.ProcessSubmitRequest approvalRequest = new Approval.ProcessSubmitRequest();
        approvalRequest.setObjectId(pendingAction.Id);
        approvalRequest.setProcessDefinitionNameOrId(pendingAction.ApprovalProcessDeveloperName__c);
        approvalRequest.setComments(comments);

        Approval.ProcessResult approvalResult = Approval.process(approvalRequest);
        if (!approvalResult.isSuccess()) {
            String errors = '';
            for (Database.Error err : approvalResult.getErrors()) {
                errors += err.getMessage() + '; ';
            }
            result.errorMessage = errors;
            return result;
        }

        result.success = true;
        result.processInstanceId = approvalResult.getInstanceId();
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

        return result;
    }

    private static AIAgentConfigService.ResolvedExecutionIdentity ensureApprovalBasedHitlExecutionIdentity(
        Id executionId,
        Boolean persistToExecution,
        String debugPrefix
    ) {
        AIAgentConfigService.ResolvedExecutionIdentity executionIdentity = AIAgentConfigService.resolveExecutionIdentityForExecution(executionId);
        if (executionIdentity.requiresPrivilegedContext) {
            return executionIdentity;
        }

        return ensureApprovalBasedHitlExecutionIdentity(executionId == null ? null : new AgentExecution__c(Id = executionId), persistToExecution, debugPrefix);
    }

    private static AIAgentConfigService.ResolvedExecutionIdentity ensureApprovalBasedHitlExecutionIdentity(
        AgentExecution__c execution,
        Boolean persistToExecution,
        String debugPrefix
    ) {
        AIAgentConfigService.ResolvedExecutionIdentity executionIdentity = AIAgentConfigService.resolveExecutionIdentityForExecution(execution);
        if (executionIdentity.requiresPrivilegedContext) {
            return executionIdentity;
        }

        String defaultProfileDeveloperName = AIAgentFrameworkSettings.getDefaultHITLExecutionIdentityProfileDeveloperName();
        if (String.isBlank(defaultProfileDeveloperName)) {
            throw new HITLConfigurationException(HITL_EXECUTION_IDENTITY_ERROR);
        }

        AIAgentConfigService.ResolvedExecutionIdentity fallbackIdentity;
        try {
            fallbackIdentity = AIAgentConfigService.resolveExecutionIdentityForProfile(defaultProfileDeveloperName);
        } catch (Exception e) {
            throw new HITLConfigurationException('AIAgentFrameworkSettings__c.DefaultHITLExecIdentityProfile__c is invalid: ' + e.getMessage());
        }
        if (persistToExecution == true && execution != null && execution.Id != null) {
            update new AgentExecution__c(
                Id = execution.Id,
                ExecutionIdentityProfileDeveloperName__c = fallbackIdentity.profileDeveloperName,
                ExecutionIdentityNamedCredential__c = fallbackIdentity.namedCredentialDeveloperName
            );
            execution.ExecutionIdentityProfileDeveloperName__c = fallbackIdentity.profileDeveloperName;
            execution.ExecutionIdentityNamedCredential__c = fallbackIdentity.namedCredentialDeveloperName;
            System.debug(
                LoggingLevel.INFO,
                debugPrefix + 'Snapshotted default HITL execution identity onto execution: ' + fallbackIdentity.profileDeveloperName
            );
        }
        return fallbackIdentity;
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
        if (context.isConditionalApproval == true && String.isNotBlank(context.llmApprovalReason)) {
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
