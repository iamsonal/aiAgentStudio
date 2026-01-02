/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * HITLGatewayService is the centralized gateway for all Human-in-the-Loop (HITL) decisions
 * in the AI Agent Framework. Every tool execution request must pass through this gateway
 * to ensure consistent HITL enforcement across all orchestrator types.
 *
 * This service implements the Strategy pattern to handle different HITL modes:
 * - None: Execute immediately without human intervention
 * - Confirmation: Require in-chat yes/no confirmation (conversational agents only)
 * - Approval: Require formal Salesforce approval process (all agent types)
 *
 * Key Responsibilities:
 * - Evaluate HITL requirements for tool execution requests
 * - Enforce agent-type compatibility (e.g., Confirmation only for Conversational)
 * - Create and manage PendingHITLAction__c records
 * - Handle confirmation responses and resume execution
 * - Integrate with Salesforce Approval Process for formal approvals
 *
 * Thread Safety: This service is stateless and safe for concurrent use.
 *
 * @example
 * // Evaluate HITL requirement before tool execution
 * HITLGatewayService.HITLContext context = new HITLGatewayService.HITLContext();
 * context.capability = myCapability;
 * context.agentDefinition = myAgentDef;
 * context.executionId = execId;
 * // ... populate other fields
 *
 * HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(context);
 * if (decision.requiresIntervention) {
 *     // Handle HITL flow
 *     HITLGatewayService.HITLResult result = HITLGatewayService.initiateHITL(context);
 * }
 */
public with sharing class HITLGatewayService {
    // =============================================================================
    // CONSTANTS
    // =============================================================================

    public static final String HITL_MODE_CONFIRMATION = 'Confirmation';
    public static final String HITL_MODE_APPROVAL = 'Approval';
    public static final String HITL_MODE_CONFIRMATION_THEN_APPROVAL = 'ConfirmationThenApproval';

    public static final String STATUS_PENDING = 'Pending';
    public static final String STATUS_CONFIRMED = 'Confirmed';
    public static final String STATUS_DECLINED = 'Declined';
    public static final String STATUS_APPROVED = 'Approved';
    public static final String STATUS_REJECTED = 'Rejected';
    public static final String STATUS_EXPIRED = 'Expired';

    public static final String AGENT_TYPE_CONVERSATIONAL = 'Conversational';
    public static final String AGENT_TYPE_FUNCTION = 'Function';
    public static final String AGENT_TYPE_WORKFLOW = 'Workflow';

    private static final String LOG_PREFIX = '[HITLGateway] ';

    // =============================================================================
    // EXCEPTION CLASSES
    // =============================================================================

    /**
     * @description Exception thrown when HITL configuration is invalid.
     */
    public class HITLConfigurationException extends Exception {
    }

    /**
     * @description Exception thrown when HITL processing fails.
     */
    public class HITLProcessingException extends Exception {
    }

    // =============================================================================
    // DATA TRANSFER OBJECTS
    // =============================================================================

    /**
     * @description Context object containing all information needed for HITL evaluation.
     * Immutable after construction to ensure thread safety.
     */
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

        public HITLContext() {
            this.logPrefix = LOG_PREFIX;
        }

        /**
         * @description Validates that all required fields are populated.
         * @throws HITLConfigurationException if required fields are missing
         */
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

    /**
     * @description Result of HITL evaluation indicating what action is required.
     */
    public class HITLDecision {
        /** Whether human intervention is required before execution */
        public Boolean requiresIntervention { get; set; }

        /** The type of HITL required (None, Confirmation, Approval) */
        public String hitlMode { get; set; }

        /** Whether the configuration is valid for the agent type */
        public Boolean isValidConfiguration { get; set; }

        /** Error message if configuration is invalid */
        public String configurationError { get; set; }

        public HITLDecision() {
            this.requiresIntervention = false;
            this.isValidConfiguration = true;
        }
    }

    /**
     * @description Creates a decision indicating no HITL is required.
     */
    public static HITLDecision createProceedDecision() {
        HITLDecision decision = new HITLDecision();
        decision.requiresIntervention = false;
        decision.isValidConfiguration = true;
        decision.configurationError = null;
        return decision;
    }

    /**
     * @description Creates a decision indicating HITL intervention is required.
     */
    public static HITLDecision createInterventionDecision(String mode) {
        HITLDecision decision = new HITLDecision();
        decision.requiresIntervention = true;
        decision.hitlMode = mode;
        decision.isValidConfiguration = true;
        decision.configurationError = null;
        return decision;
    }

    /**
     * @description Creates a decision indicating invalid configuration.
     */
    public static HITLDecision createInvalidConfigDecision(String errorMessage) {
        HITLDecision decision = new HITLDecision();
        decision.requiresIntervention = false;
        decision.hitlMode = null;
        decision.isValidConfiguration = false;
        decision.configurationError = errorMessage;
        return decision;
    }

    /**
     * @description Result of initiating a HITL workflow.
     */
    public class HITLResult {
        /** Whether the HITL initiation was successful */
        public Boolean success { get; set; }

        /** The created PendingHITLAction__c record ID */
        public Id pendingActionId { get; set; }

        /** The confirmation prompt to display to the user */
        public String confirmationPrompt { get; set; }

        /** Error message if initiation failed */
        public String errorMessage { get; set; }

        /** The HITL type that was initiated */
        public String hitlType { get; set; }

        /** Expiration timestamp for confirmation requests */
        public DateTime expiresAt { get; set; }

        public HITLResult() {
            this.success = false;
        }
    }

    /**
     * @description Creates a successful HITL result.
     */
    public static HITLResult createSuccessResult(Id actionId, String prompt, String hitlType, DateTime expires) {
        HITLResult result = new HITLResult();
        result.success = true;
        result.pendingActionId = actionId;
        result.confirmationPrompt = prompt;
        result.hitlType = hitlType;
        result.expiresAt = expires;
        return result;
    }

    /**
     * @description Creates a failure HITL result.
     */
    public static HITLResult createFailureResult(String error) {
        HITLResult result = new HITLResult();
        result.success = false;
        result.errorMessage = error;
        return result;
    }

    /**
     * @description Result of resolving (confirming/declining) a HITL action.
     */
    public class HITLResolutionResult {
        /** Whether the resolution was successful */
        public Boolean success { get; set; }

        /** The final status after resolution */
        public String status { get; set; }

        /** Whether execution should proceed */
        public Boolean shouldProceed { get; set; }

        /** The tool arguments to use for execution (if proceeding) */
        public String toolArguments { get; set; }

        /** The capability to execute (if proceeding) */
        public AgentCapability__c capability { get; set; }

        /** Error message if resolution failed */
        public String errorMessage { get; set; }

        /** Message to return to LLM about the resolution */
        public String llmMessage { get; set; }

        public HITLResolutionResult() {
            this.success = false;
            this.shouldProceed = false;
        }
    }

    // =============================================================================
    // PUBLIC API - EVALUATION
    // =============================================================================

    /**
     * @description Evaluates whether a tool execution requires HITL intervention.
     * This is the primary entry point for HITL evaluation.
     *
     * HITL Modes:
     * - None: Execute immediately without human intervention
     * - Confirmation: LLM asks user conversationally before executing (prompt injection, no system enforcement)
     * - Approval: Formal Salesforce approval process (system enforced, all agent types)
     * - ConfirmationThenApproval: LLM asks conversationally, then submits for formal approval (conversational only)
     *
     * @param context The HITL context containing capability and execution information
     * @return HITLDecision indicating whether intervention is required and if config is valid
     * @throws HITLConfigurationException if context validation fails
     */
    public static HITLDecision evaluate(HITLContext context) {
        context.validate();
        String debugPrefix = context.logPrefix + '[evaluate] ';

        // Get HITL mode from capability (default to None if not set)
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

        // No HITL required
        if (hitlMode == null) {
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'No HITL required (mode=None)');
            return createProceedDecision();
        }

        // Confirmation mode - LLM-based conversational confirmation via prompt injection
        // No system enforcement needed - the LLM will ask the user before executing
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

            // Confirmation mode does NOT require system intervention - it's handled via prompt injection
            // The LLM will ask the user conversationally before executing
            System.debug(LoggingLevel.DEBUG, debugPrefix + 'Confirmation mode - no system intervention needed (prompt injection handles this)');
            return createProceedDecision();
        }

        // ConfirmationThenApproval mode - LLM confirms first, then goes to approval
        // This requires system intervention for the approval part
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

            // For ConfirmationThenApproval, we need system intervention for the approval part
            System.debug(LoggingLevel.INFO, debugPrefix + 'HITL ConfirmationThenApproval required for: ' + context.capability.CapabilityName__c);
            return createInterventionDecision(HITL_MODE_CONFIRMATION_THEN_APPROVAL);
        }

        // Approval mode - valid for all agent types
        if (hitlMode == HITL_MODE_APPROVAL) {
            System.debug(LoggingLevel.INFO, debugPrefix + 'HITL Approval required for: ' + context.capability.CapabilityName__c);
            return createInterventionDecision(HITL_MODE_APPROVAL);
        }

        // Unknown mode - treat as configuration error
        String errorMsg =
            'Unknown HITLMode value: "' +
            hitlMode +
            '" for capability "' +
            context.capability.CapabilityName__c +
            '". Valid values are: None, Confirmation, Approval, ConfirmationThenApproval.';
        System.debug(LoggingLevel.ERROR, debugPrefix + errorMsg);
        return createInvalidConfigDecision(errorMsg);
    }

    // =============================================================================
    // PUBLIC API - INITIATION
    // =============================================================================

    /**
     * @description Initiates a HITL workflow by creating a PendingHITLAction__c record.
     * Call this after evaluate() returns requiresIntervention=true.
     *
     * @param context The HITL context
     * @param decision The decision from evaluate() (must have requiresIntervention=true)
     * @return HITLResult containing the pending action details
     */
    public static HITLResult initiateHITL(HITLContext context, HITLDecision decision) {
        context.validate();
        String debugPrefix = context.logPrefix + '[initiateHITL] ';

        if (!decision.requiresIntervention) {
            return createFailureResult('Cannot initiate HITL when intervention is not required');
        }

        if (!decision.isValidConfiguration) {
            return createFailureResult('Cannot initiate HITL with invalid configuration: ' + decision.configurationError);
        }

        try {
            if (decision.hitlMode == HITL_MODE_CONFIRMATION) {
                // Confirmation mode should not reach here - it's handled via prompt injection
                return createFailureResult('Confirmation mode does not require system intervention. This is handled via prompt injection.');
            } else if (decision.hitlMode == HITL_MODE_APPROVAL) {
                return initiateApproval(context, debugPrefix);
            } else if (decision.hitlMode == HITL_MODE_CONFIRMATION_THEN_APPROVAL) {
                return initiateConfirmationThenApproval(context, debugPrefix);
            } else {
                return createFailureResult('Unknown HITL mode: ' + decision.hitlMode);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Failed to initiate HITL: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return createFailureResult('Failed to initiate HITL workflow: ' + e.getMessage());
        }
    }

    /**
     * @description Initiates a ConfirmationThenApproval HITL workflow.
     * The LLM has already asked the user conversationally, now we submit for formal approval.
     */
    private static HITLResult initiateConfirmationThenApproval(HITLContext context, String debugPrefix) {
        System.debug(LoggingLevel.INFO, debugPrefix + 'Initiating ConfirmationThenApproval HITL for tool: ' + context.capability.CapabilityName__c);

        // Generate approval prompt
        String approvalPrompt = generateApprovalPrompt(context);

        // Create PendingHITLAction__c record
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

        // Submit to Salesforce Approval Process
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

                return createSuccessResult(pendingAction.Id, approvalPrompt, HITL_MODE_CONFIRMATION_THEN_APPROVAL, null);
            } else {
                // Approval submission failed - clean up and return error
                String errors = '';
                for (Database.Error err : approvalResult.getErrors()) {
                    errors += err.getMessage() + '; ';
                }
                System.debug(LoggingLevel.ERROR, debugPrefix + 'Approval submission failed: ' + errors);

                // Try to delete the pending action since approval couldn't be started
                // Use Database.delete with allOrNone=false to handle potential locks
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
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Exception submitting approval: ' + e.getMessage());
            // Try to delete the pending action since approval couldn't be started
            // Use try-catch to handle potential record locking
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

    /**
     * @description Initiates an Approval HITL workflow using Salesforce Approval Process.
     */
    private static HITLResult initiateApproval(HITLContext context, String debugPrefix) {
        System.debug(LoggingLevel.INFO, debugPrefix + 'Initiating Approval HITL for tool: ' + context.capability.CapabilityName__c);

        // Generate approval prompt/justification
        String approvalPrompt = generateApprovalPrompt(context);

        // Create PendingHITLAction__c record first
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
                // Approval submission failed - clean up and return error
                String errors = '';
                for (Database.Error err : approvalResult.getErrors()) {
                    errors += err.getMessage() + '; ';
                }
                System.debug(LoggingLevel.ERROR, debugPrefix + 'Approval submission failed: ' + errors);

                // Try to delete the pending action since approval couldn't be started
                // Use Database.delete with allOrNone=false to handle potential locks
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
            System.debug(LoggingLevel.ERROR, debugPrefix + 'Exception submitting approval: ' + e.getMessage());
            // Try to delete the pending action since approval couldn't be started
            // Use try-catch to handle potential record locking
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

    // =============================================================================
    // PUBLIC API - RESOLUTION
    // =============================================================================

    /**
     * @description Handles approval process completion (called from trigger on PendingHITLAction__c
     * or from approval process post-processing).
     *
     * @param pendingActionId The ID of the PendingHITLAction__c that was approved/rejected
     * @param approved Whether the action was approved (true) or rejected (false)
     * @param approverId The user who approved/rejected
     * @param comment Approver's comment
     * @return HITLResolutionResult indicating whether to proceed with execution
     */
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

            // Validate this is an Approval or ConfirmationThenApproval type
            if (action.HITLType__c != HITL_MODE_APPROVAL && action.HITLType__c != HITL_MODE_CONFIRMATION_THEN_APPROVAL) {
                result.errorMessage =
                    'Cannot resolve action with resolveApproval. ' +
                    'Action type is: ' +
                    action.HITLType__c +
                    '. Expected Approval or ConfirmationThenApproval.';
                System.debug(LoggingLevel.ERROR, debugPrefix + result.errorMessage);
                return result;
            }

            // Update the action
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

                // Load the capability for execution
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

    // =============================================================================
    // PUBLIC API - QUERY METHODS
    // =============================================================================

    /**
     * @description Retrieves a pending HITL action by ID.
     *
     * @param pendingActionId The ID of the PendingHITLAction__c
     * @return The PendingHITLAction__c record or null if not found
     */
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

    /**
     * @description Retrieves all pending HITL actions for an execution.
     *
     * @param executionId The AgentExecution__c ID
     * @return List of pending PendingHITLAction__c records
     */
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

    /**
     * @description Checks if there are any pending HITL actions for an execution.
     *
     * @param executionId The AgentExecution__c ID
     * @return True if there are pending actions
     */
    public static Boolean hasPendingActions(Id executionId) {
        return [
                SELECT COUNT()
                FROM PendingHITLAction__c
                WHERE AgentExecution__c = :executionId AND Status__c = :STATUS_PENDING
            ] > 0;
    }
    // =============================================================================
    // PRIVATE HELPER METHODS
    // =============================================================================

    /**
     * @description Generates an approval prompt/justification.
     */
    private static String generateApprovalPrompt(HITLContext context) {
        String toolName = context.capability.CapabilityName__c;
        String description = context.capability.Description__c;

        String prompt = 'AI Agent action requires approval.\n\n';
        prompt += 'Action: ' + toolName + '\n';

        if (String.isNotBlank(description)) {
            prompt += 'Description: ' + description + '\n';
        }

        String formattedArgs = formatArgumentsForDisplay(context.toolArguments);
        if (String.isNotBlank(formattedArgs)) {
            prompt += '\nParameters:\n' + formattedArgs;
        }

        return prompt;
    }

    /**
     * @description Formats tool arguments JSON for human-readable display.
     */
    private static String formatArgumentsForDisplay(String argumentsJson) {
        if (String.isBlank(argumentsJson)) {
            return '';
        }

        try {
            Map<String, Object> args = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);
            if (args.isEmpty()) {
                return '';
            }

            List<String> lines = new List<String>();
            for (String key : args.keySet()) {
                Object value = args.get(key);
                String valueStr = value != null ? String.valueOf(value) : 'null';
                // Truncate long values
                if (valueStr.length() > 200) {
                    valueStr = valueStr.substring(0, 200) + '...';
                }
                lines.add('• ' + key + ': ' + valueStr);
            }
            return String.join(lines, '\n');
        } catch (Exception e) {
            // If parsing fails, return truncated raw JSON
            return argumentsJson.length() > 500 ? argumentsJson.substring(0, 500) + '...' : argumentsJson;
        }
    }
}
