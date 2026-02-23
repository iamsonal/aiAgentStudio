/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Orchestrator for conversational (chat-based) agent executions. Handles multi-turn conversations and async dispatch.
 */
public inherited sharing class ConversationalOrchestrator extends BaseAgentOrchestrator {
    private static final String LOG_PREFIX = '[ConversationalOrch] ';

    public ConversationalOrchestrator() {
    }
    public ConversationalOrchestrator(AIAgentDefinition__c agentDefinition) {
        configure(agentDefinition);
    }

    public override AgentExecutionService.ExecutionResult start(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting conversational execution');

        try {
            if (String.isBlank(payload.userMessage)) {
                throw new AIAgentException.OrchestrationException('User message is required for conversational execution');
            }
            if (String.isBlank(payload.turnIdentifier)) {
                throw new AIAgentException.OrchestrationException('Turn identifier is required for conversational execution');
            }

            Id executionId;

            if (payload.existingExecutionId != null) {
                validateExecutionAccess(payload.existingExecutionId, payload.userId);
                executionId = payload.existingExecutionId;
                logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '][Exec:' + executionId + '] ';

                if (shouldExecuteSynchronously(payload, logPrefix)) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'Executing initial LLM call synchronously (callout-safe)');
                    return executeSynchronously(executionId, payload, logPrefix);
                }

                AgentStateService agentStateSvc = new AgentStateService();
                agentStateSvc.updateStatus(
                    executionId,
                    'Processing',
                    AIAgentConstants.STATUS_PROCESSING,
                    payload.turnIdentifier,
                    'Processing conversational turn'
                );
            } else {
                // Create new AgentExecution__c record
                AgentStateService agentStateService = new AgentStateService();
                String executionLabel = 'Chat - ' + Datetime.now().format('MM/dd HH:mm:ss');

                executionId = agentStateService.createExecution(
                    'Conversational',
                    agentDefinition.Id,
                    payload.triggerSource,
                    executionLabel,
                    payload.sourceRecordId,
                    payload.userId,
                    payload.serviceUserId
                );
                logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '][Exec:' + executionId + '] ';
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Created/updated execution');

            // Determine async strategy based ONLY on AsyncDispatchType__c
            String asyncDispatchType = agentDefinition.AsyncDispatchType__c != null ? agentDefinition.AsyncDispatchType__c : 'Low';

            if ('High'.equalsIgnoreCase(asyncDispatchType)) {
                // High dispatch type: Use Platform Event for high-throughput, fire-and-forget processing
                publishPlatformEvent(executionId, payload, logPrefix);
                return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Processing message asynchronously');
            } else {
                // Low dispatch type: Use Queueable for guaranteed sequential processing
                enqueueQueueable(executionId, payload, logPrefix);
                return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Processing message');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error initiating conversational execution: ' + e.getMessage());
            throw new AIAgentException.OrchestrationException('Failed to start conversational execution: ' + e.getMessage());
        }
    }

    /**
     * @description Determines whether the initial LLM call can run inline.
     * Defaults to synchronous only when the current transaction can make callouts
     * and the agent does not require service user context routing.
     */
    private Boolean shouldExecuteSynchronously(AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        if (agentDefinition.RequiresServiceUserContext__c == true) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Service user context required - skipping synchronous execution');
            return false;
        }

        if (!canMakeCalloutNow()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Callout not allowed in this transaction - routing async');
            return false;
        }

        return true;
    }

    /**
     * @description Checks if the current transaction can safely make callouts.
     * Callouts are disallowed after DML or email operations.
     */
    private Boolean canMakeCalloutNow() {
        return Limits.getDMLStatements() == 0 && Limits.getDMLRows() == 0 && Limits.getEmailInvocations() == 0;
    }

    // CAPABILITY QUERY METHODS

    // Note: ConversationalOrchestrator does not override onChildComplete()
    // because it uses ConversationalQueueable/ProcessLLMMessage events instead of callbacks

    // LLM CUSTOMIZATION HOOKS (override from BaseAgentOrchestrator)

    /**
     * Injects summarization instructions for multi-step conversational turns.
     * This ensures the user gets a coherent summary after tool executions.
     */
    public override String buildSystemPromptAdditions(OrchestrationContext context) {
        // Only inject for multi-step turns where we're doing a follow-up call (no user message)
        Boolean isMultiStepTurn = context.currentTurnCount > 1;
        Boolean isFollowUpCall = (context.userMessageData == null || String.isBlank(context.userMessageData.content));

        if (isMultiStepTurn && isFollowUpCall) {
            System.debug(LoggingLevel.INFO, context.logPrefix + 'Injecting summarization instructions for conversational agent');

            return '\n\n# FINAL INSTRUCTIONS\n\n' +
                'You have just completed one or more tool actions that the user did not see. ' +
                'Your task is to synthesize the results of all actions into a single, user-friendly summary. ' +
                'This will be the only message the user sees for this turn. ' +
                'Do not ask questions; provide a conclusive, final response.';
        }

        return '';
    }

    /**
     * Handles conversational-specific behavior after tool completion.
     * For approval scenarios, creates an assistant message and completes the turn.
     */
    public override String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario) {
        String logPrefix = context.logPrefix + '[ConvToolCompletion] ';

        if (scenario == 'APPROVAL_REQUIRED') {
            // For conversational agents: create programmatic assistant response and complete turn
            // This allows user to continue chatting while approval is pending

            // Find the tool that requires approval
            String toolName = 'the requested action';
            if (toolResults != null && !toolResults.isEmpty()) {
                toolName = toolResults[0].toolName;
            }

            String assistantMessage =
                'I\'ve submitted your request to ' +
                toolName +
                ' for approval. You\'ll be notified when it\'s processed. Feel free to continue our conversation.';

            ExecutionStepService executionStepService = new ExecutionStepService();
            Id assistantMessageId = executionStepService.createAgentResponseStep(
                context.executionId,
                assistantMessage,
                context.turnIdentifier,
                context.currentTurnCount
            );

            context.decisionLogger.log(IDecisionStepLogger.EventType.FINAL_RESPONSE, new List<Object>{ assistantMessage });

            // Complete the turn successfully - user can continue chatting
            context.agentStateSvc.completeTurnSuccessfully(context.executionId, context.turnIdentifier, assistantMessageId, logPrefix);

            return OrchestrationService.OUTCOME_COMPLETED;
        }

        // Delegate to base class for all other scenarios (e.g. CONTENT_ONLY_RESPONSE retry enforcement)
        return super.evaluateToolOutcome(context, toolResults, scenario);
    }

    // QUEUEABLE JOB EXECUTION

    /**
     * Executes LLM processing for conversational agents when invoked from a queueable job.
     * Handles async LLM calls and orchestration for chat-based interactions.
     *
     * Required payload fields:
     * - executionId (Id): Execution record ID
     * - originalUserId (Id): Original user ID
     * - executionUserId (Id): Execution user ID (may differ for service user context)
     * - agentDefinitionId (Id): Agent definition ID
     * - llmConfigurationId (Id): LLM configuration ID
     * - turnIdentifier (String): Turn identifier
     * - userMessage (String): User's message content
     * Optional payload fields:
     * - currentRecordId (Id): Current page record context
     */
    public override void runAsync(Map<String, Object> payload, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing Conversational job');

        // Extract and validate required payload fields
        Id executionId = getRequiredId(payload, 'executionId', logPrefix);
        Id originalUserId = getRequiredId(payload, 'originalUserId', logPrefix);
        Id executionUserId = getRequiredId(payload, 'executionUserId', logPrefix);
        Id agentDefinitionId = getRequiredId(payload, 'agentDefinitionId', logPrefix);
        Id llmConfigurationId = getRequiredId(payload, 'llmConfigurationId', logPrefix);
        String turnIdentifier = getRequiredString(payload, 'turnIdentifier', logPrefix);
        String userMessage = getRequiredString(payload, 'userMessage', logPrefix);

        // Extract optional fields
        Id currentRecordId = (Id) payload.get('currentRecordId');

        System.debug(LoggingLevel.INFO, logPrefix + 'Starting LLM processing for turn: ' + turnIdentifier + ', Exec: ' + executionId);

        // Initialize decision logger - must be outside try block for finally access
        IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(executionId, turnIdentifier, originalUserId);

        try {
            // Get user and agent names for dynamic description
            String userName = getUserName(originalUserId);
            String agentName = getAgentName(agentDefinitionId);

            decisionLogger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ userMessage, userName, agentName });

            // Prepare user message data
            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = userMessage;

            // Multi-LLM Optimization: Enable deferred DML mode and track LLM calls
            TransactionContext txnCtx = TransactionContext.getInstance();
            txnCtx.enableDeferredDMLMode();
            txnCtx.incrementLLMCallCount();
            txnCtx.resetTurnSafetyTracking(); // Reset sticky flag and capture baselines at turn start

            // Execution record was created in a previous transaction (queueable entry point)
            txnCtx.setHasPreExistingExecution(true);

            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome;
            Integer currentTurnCount = 1;

            // Multi-LLM loop: Continue making LLM calls while conditions allow
            do {
                // Instantiate LLM interaction service for this iteration
                LLMInteractionService interactionService = new LLMInteractionService(
                    executionId,
                    originalUserId,
                    agentDefinitionId,
                    llmConfigurationId,
                    turnIdentifier,
                    currentTurnCount,
                    currentRecordId,
                    false,
                    decisionLogger
                );

                // Execute LLM interaction
                // First call includes user message, subsequent calls don't (follow-up pattern)
                LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(
                    currentTurnCount == 1 ? currentUserMessageData : null
                );

                if (llmResult == null) {
                    throw new AIAgentException.OrchestrationException('LLMInteractionService returned a null result');
                }

                // Process LLM result
                outcome = orchestrationSvc.processLlmResult(
                    llmResult,
                    executionId,
                    originalUserId,
                    executionUserId,
                    agentDefinitionId,
                    turnIdentifier,
                    currentTurnCount,
                    currentTurnCount == 1 ? currentUserMessageData : null,
                    currentRecordId,
                    decisionLogger
                );

                System.debug(LoggingLevel.INFO, logPrefix + 'LLM call ' + txnCtx.getLLMCallCount() + ' completed. Outcome: ' + outcome);

                // If immediate follow-up is needed, prepare for next iteration
                if (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP) {
                    currentTurnCount++;
                    txnCtx.incrementLLMCallCount();
                    txnCtx.resetTurnSafetyTracking(); // Reset sticky flag for new turn
                    System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization: Continuing with immediate follow-up (turn ' + currentTurnCount + ')');
                }
            } while (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP);

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'LLM processing completed. Final outcome: ' + outcome + ', Total LLM calls: ' + txnCtx.getLLMCallCount()
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'ERROR: LLM processing failed. Exception: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString());

            // Mark turn as failed (this will commit buffer due to terminal state)
            try {
                AgentStateService ass = new AgentStateService();
                ass.failTurn(executionId, turnIdentifier, 'LLM processing failed: ' + e.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            } catch (Exception failEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'CRITICAL: Failed to update execution state after processing failure: ' + failEx.getMessage());
            }
        } finally {
            // Multi-LLM optimization: Commit any remaining buffered DML and decision steps
            // This handles cases where the loop exited without a terminal state update
            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                TransactionContext.getInstance().commitBuffer();
                TransactionContext.getInstance().disableDeferredDMLMode();
            }
            decisionLogger.commitSteps();
        }
    }

    // RESUME IMPLEMENTATION

    /**
     * Determines resume point for conversational executions.
     * Conversational agents typically resume with an LLM call to continue the conversation.
     */
    protected override BaseAgentOrchestrator.ResumePoint determineResumePoint(
        Id executionId,
        AgentExecution__c execution,
        BaseAgentOrchestrator.ResumeOptions options,
        String logPrefix
    ) {
        BaseAgentOrchestrator.ResumePoint resumePoint = new BaseAgentOrchestrator.ResumePoint();
        resumePoint.lastTurnCount = getLastTurnCount(executionId);
        resumePoint.turnCount = 1; // Reset for fresh cycle budget

        // Check if we should retry a failed tool
        Boolean shouldRetryTool = options?.retryFailedTool;

        if (shouldRetryTool == null) {
            // Auto-detect: check for failed tool
            Map<String, Object> failedTool = findLastFailedTool(executionId, logPrefix);
            shouldRetryTool = (failedTool != null);

            if (shouldRetryTool) {
                resumePoint.toolCallId = (String) failedTool.get('toolCallId');
                resumePoint.toolName = (String) failedTool.get('toolName');
                System.debug(LoggingLevel.INFO, logPrefix + 'Auto-detected failed tool: ' + resumePoint.toolName);
            }
        } else if (shouldRetryTool == true) {
            // Explicit retry - find the failed tool
            Map<String, Object> failedTool = findLastFailedTool(executionId, logPrefix);
            if (failedTool != null) {
                resumePoint.toolCallId = (String) failedTool.get('toolCallId');
                resumePoint.toolName = (String) failedTool.get('toolName');
            } else {
                // No failed tool found, fall back to LLM continue
                shouldRetryTool = false;
                System.debug(LoggingLevel.WARN, logPrefix + 'No failed tool found, falling back to LLM_CONTINUE');
            }
        }

        resumePoint.resumeType = shouldRetryTool ? BaseAgentOrchestrator.ResumeType.RETRY_FAILED_TOOL : BaseAgentOrchestrator.ResumeType.LLM_CONTINUE;

        System.debug(LoggingLevel.INFO, logPrefix + 'Resume strategy: ' + resumePoint.resumeType);
        return resumePoint;
    }

    /**
     * Executes resume for conversational executions.
     * Enqueues a follow-up LLM call or tool retry.
     */
    protected override AgentExecutionService.ExecutionResult executeResume(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        BaseAgentOrchestrator.ResumePoint resumePoint,
        BaseAgentOrchestrator.ResumeOptions options,
        String logPrefix
    ) {
        // Update execution with new turn identifier
        AgentStateService agentStateSvc = new AgentStateService();
        agentStateSvc.updateStatus(executionId, 'Processing', AIAgentConstants.STATUS_PROCESSING, newTurnIdentifier, 'Resuming conversational execution');

        if (resumePoint.resumeType == BaseAgentOrchestrator.ResumeType.RETRY_FAILED_TOOL) {
            // Retry the failed tool
            return retryFailedTool(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
        } else {
            // Continue with LLM call
            return continueWithLLMCall(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
        }
    }

    /**
     * Retries a failed tool execution.
     */
    private AgentExecutionService.ExecutionResult retryFailedTool(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        BaseAgentOrchestrator.ResumePoint resumePoint,
        String logPrefix
    ) {
        // Find the tool call step to get arguments
        List<ExecutionStep__c> toolCallSteps = [
            SELECT ToolArguments__c, ToolName__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :executionId AND StepType__c = 'ToolCall' AND ToolCallId__c = :resumePoint.toolCallId
            ORDER BY Timestamp__c DESC
            LIMIT 1
        ];

        if (toolCallSteps.isEmpty()) {
            throw new AIAgentException.OrchestrationException('Cannot retry tool: ToolCall step not found for toolCallId: ' + resumePoint.toolCallId);
        }

        String toolArguments = toolCallSteps[0].ToolArguments__c;

        // Lookup capability
        AgentCapability__c capability = AIAgentConfigService.getCapability(agentDefinition.Id, resumePoint.toolName);
        if (capability == null) {
            throw new AIAgentException.OrchestrationException('Cannot retry tool: Capability not found for tool: ' + resumePoint.toolName);
        }

        // Generate new tool call ID for retry
        String retryToolCallId = generateRetryToolCallId(resumePoint.toolCallId);

        // Check if tool is async
        if (capability.RunAsynchronously__c == true) {
            // Enqueue async tool execution with proper tracking
            AgentStateService agentStateSvc = new AgentStateService();
            agentStateSvc.pauseForAsyncActionWithTracking(executionId, newTurnIdentifier, 1, capability.CapabilityName__c, logPrefix);

            AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
            enqueuer.enqueueAsyncAction(
                executionId,
                execution.User__c,
                agentDefinition.Id,
                null,
                retryToolCallId,
                toolArguments,
                capability,
                execution.SourceRecordId__c,
                newTurnIdentifier,
                resumePoint.turnCount,
                logPrefix
            );

            return new AgentExecutionService.ExecutionResult(
                executionId,
                AIAgentConstants.STATUS_PROCESSING,
                'Retrying tool asynchronously: ' + resumePoint.toolName
            );
        }

        // Synchronous tool - execute now
        ActionContext actionContext = new ActionContext(
            executionId,
            execution.User__c,
            execution.User__c,
            execution.SourceRecordId__c,
            agentDefinition.Id,
            capability.Id,
            capability.ImplementationDetail__c,
            newTurnIdentifier,
            resumePoint.turnCount,
            'ConversationalResume'
        );

        CapabilityExecutionService capabilityService = new CapabilityExecutionService();
        ActionOutcome toolOutcome = capabilityService.executeSingleAction(capability, toolArguments, actionContext);

        // Create tool call and result steps with resume tracking
        ExecutionStepService stepSvc = new ExecutionStepService();
        stepSvc.createToolCallStep(
            executionId,
            retryToolCallId,
            resumePoint.toolName,
            toolArguments,
            newTurnIdentifier,
            resumePoint.turnCount,
            null,
            null,
            null,
            null,
            null,
            capability.Id,
            true // isResumed = true
        );

        String toolResultJson = OrchestrationService.serializeActionOutcome(toolOutcome, logPrefix);
        stepSvc.createToolResultStep(
            executionId,
            retryToolCallId,
            resumePoint.toolName,
            toolResultJson,
            newTurnIdentifier,
            resumePoint.turnCount,
            0L,
            false,
            capability.Id,
            !toolOutcome.isSuccess,
            true // isResumed = true
        );

        if (!toolOutcome.isSuccess) {
            // Check fail-fast
            if (OrchestrationService.shouldFailFast(capability, agentDefinition, toolOutcome, executionId, logPrefix)) {
                AgentStateService agentStateSvc = new AgentStateService();
                agentStateSvc.failTurn(executionId, newTurnIdentifier, toolOutcome.errorMessage, toolOutcome.errorCode, logPrefix);
                return new AgentExecutionService.ExecutionResult(toolOutcome.errorCode, 'Tool retry failed: ' + toolOutcome.errorMessage);
            }
        }

        // Continue with follow-up LLM call
        return continueWithLLMCall(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
    }

    /**
     * Continues execution with an LLM call.
     */
    private AgentExecutionService.ExecutionResult continueWithLLMCall(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        BaseAgentOrchestrator.ResumePoint resumePoint,
        String logPrefix
    ) {
        AgentStateService agentStateSvc = new AgentStateService();
        agentStateSvc.resumeForFollowUpLlmCall(executionId, newTurnIdentifier, null, logPrefix);

        AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
        enqueuer.enqueueFollowUp(
            executionId,
            execution.User__c,
            agentDefinition.Id,
            newTurnIdentifier,
            resumePoint.turnCount,
            logPrefix,
            false,
            execution.SourceRecordId__c
        );

        return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Resuming with LLM call');
    }

    /**
     * Generates a retry tool call ID that fits within OpenAI's 40-character limit.
     */
    private String generateRetryToolCallId(String originalToolCallId) {
        String timestamp = String.valueOf(System.currentTimeMillis());
        String originalId = originalToolCallId != null ? originalToolCallId : 'call_retry';

        // Calculate max length for originalId: 40 - 'retry_' (6) - '_' (1) - timestamp (13) = 20
        Integer maxOriginalIdLength = 40 - 6 - 1 - timestamp.length();
        if (originalId.length() > maxOriginalIdLength) {
            originalId = originalId.substring(0, maxOriginalIdLength);
        }

        String retryToolCallId = 'retry_' + originalId + '_' + timestamp;

        if (retryToolCallId.length() > 40) {
            retryToolCallId = retryToolCallId.substring(0, 40);
        }

        return retryToolCallId;
    }

    /**
     * Publishes a Platform Event for high dispatch type scenarios.
     */
    private void publishPlatformEvent(Id executionId, AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        Map<String, Object> llmPayload = new Map<String, Object>{
            'sessionId' => executionId,
            'originalUserId' => payload.userId,
            'agentDefinitionId' => agentDefinition.Id,
            'llmConfigurationId' => agentDefinition.LLMConfiguration__c,
            'turnIdentifier' => payload.turnIdentifier,
            'userMessage' => payload.userMessage,
            'currentRecordId' => payload.currentRecordId,
            'logPrefix' => logPrefix
        };

        AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
            AgentExecutionId__c = executionId,
            TurnIdentifier__c = payload.turnIdentifier,
            JobType__c = 'ProcessLLMMessage',
            Payload__c = JSON.serialize(llmPayload)
        );

        Database.SaveResult sr = EventBus.publish(event);
        if (!sr.isSuccess()) {
            String errMsg = logPrefix + 'EventBus.publish failed for ProcessLLMMessage: ' + JSON.serialize(sr.getErrors());
            System.debug(LoggingLevel.ERROR, errMsg);
            throw new AIAgentException.OrchestrationException('Failed to publish ProcessLLMMessage event: ' + errMsg);
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Published ProcessLLMMessage platform event for execution: ' + executionId);
    }

    /**
     * Enqueues a Queueable job for low dispatch type scenarios.
     */
    private void enqueueQueueable(Id executionId, AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        Map<String, Object> queueablePayload = new Map<String, Object>{
            'executionId' => executionId,
            'originalUserId' => payload.userId,
            'executionUserId' => payload.userId,
            'agentDefinitionId' => agentDefinition.Id,
            'llmConfigurationId' => agentDefinition.LLMConfiguration__c,
            'turnIdentifier' => payload.turnIdentifier,
            'currentRecordId' => payload.currentRecordId,
            'userMessage' => payload.userMessage
        };

        UnifiedAgentQueueable queueable = new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_CONVERSATIONAL, queueablePayload);

        Id jobId = System.enqueueJob(queueable);
        System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued UnifiedAgentQueueable job (Conversational type): ' + jobId + ' for execution: ' + executionId);
    }

    /**
     * Executes a conversational turn synchronously without queueable overhead.
     * Supports multi-LLM optimization when sync tools don't perform DML/callouts.
     */
    private AgentExecutionService.ExecutionResult executeSynchronously(Id executionId, AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        // Initialize decision logger - must be outside try block for finally access
        IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(executionId, payload.turnIdentifier, payload.userId);

        try {
            // Get user and agent names for dynamic description
            String userName = getUserName(payload.userId);
            String agentName = getAgentName(agentDefinition.Id);

            decisionLogger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ payload.userMessage, userName, agentName });

            // Prepare user message data
            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = payload.userMessage;

            // Multi-LLM Optimization: Enable deferred DML mode and track LLM calls
            TransactionContext txnCtx = TransactionContext.getInstance();
            txnCtx.enableDeferredDMLMode();
            txnCtx.incrementLLMCallCount();
            txnCtx.resetTurnSafetyTracking(); // Reset sticky flag and capture baselines at turn start

            // Execution record already exists (passed in from caller via existingExecutionId)
            txnCtx.setHasPreExistingExecution(true);

            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome;
            Integer currentTurnCount = 1;

            // Multi-LLM loop: Continue making LLM calls while conditions allow
            do {
                // Instantiate LLM interaction service for this iteration
                LLMInteractionService interactionService = new LLMInteractionService(
                    executionId,
                    payload.userId,
                    agentDefinition.Id,
                    agentDefinition.LLMConfiguration__c,
                    payload.turnIdentifier,
                    currentTurnCount,
                    payload.currentRecordId,
                    false,
                    decisionLogger
                );

                // Execute LLM interaction
                // First call includes user message, subsequent calls don't (follow-up pattern)
                LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(
                    currentTurnCount == 1 ? currentUserMessageData : null
                );

                if (llmResult == null) {
                    throw new AIAgentException.OrchestrationException('LLMInteractionService returned a null result');
                }

                // Process LLM result
                outcome = orchestrationSvc.processLlmResult(
                    llmResult,
                    executionId,
                    payload.userId,
                    payload.userId,
                    agentDefinition.Id,
                    payload.turnIdentifier,
                    currentTurnCount,
                    currentTurnCount == 1 ? currentUserMessageData : null,
                    payload.currentRecordId,
                    decisionLogger
                );

                System.debug(LoggingLevel.INFO, logPrefix + 'LLM call ' + txnCtx.getLLMCallCount() + ' completed. Outcome: ' + outcome);

                // If immediate follow-up is needed, prepare for next iteration
                if (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP) {
                    currentTurnCount++;
                    txnCtx.incrementLLMCallCount();
                    txnCtx.resetTurnSafetyTracking(); // Reset sticky flag for new turn
                    System.debug(LoggingLevel.INFO, logPrefix + 'Multi-LLM optimization: Continuing with immediate follow-up (turn ' + currentTurnCount + ')');
                }
            } while (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP);

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Synchronous execution completed. Final outcome: ' + outcome + ', Total LLM calls: ' + txnCtx.getLLMCallCount()
            );

            // Determine status based on outcome
            String status = AIAgentConstants.STATUS_IDLE;
            String message = 'Turn completed';

            if (outcome == OrchestrationService.OUTCOME_FAILED) {
                status = AIAgentConstants.STATUS_FAILED;
                message = 'Turn failed';
            } else if (outcome == OrchestrationService.OUTCOME_QUEUED_ACTION || outcome == OrchestrationService.OUTCOME_QUEUED_FOLLOWUP) {
                status = AIAgentConstants.STATUS_PROCESSING;
                message = 'Processing tool actions';
            } else if (outcome == OrchestrationService.OUTCOME_AWAITING_CONFIRMATION) {
                status = AIAgentConstants.STATUS_IDLE;
                message = 'Awaiting user confirmation';
            }

            return new AgentExecutionService.ExecutionResult(executionId, status, message);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());

            try {
                AgentStateService ass = new AgentStateService();
                ass.failTurn(
                    executionId,
                    payload.turnIdentifier,
                    'Synchronous execution failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not update turn state: ' + failEx.getMessage());
            }

            return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_FAILED, 'Execution failed: ' + e.getMessage());
        } finally {
            // Multi-LLM optimization: Commit any remaining buffered DML and decision steps
            // This handles cases where the loop exited without a terminal state update
            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                TransactionContext.getInstance().commitBuffer();
                TransactionContext.getInstance().disableDeferredDMLMode();
            }
            decisionLogger.commitSteps();
        }
    }

    /**
     * Validates that the user has access to the specified execution and that the execution
     * belongs to the agent this orchestrator was configured for.
     *
     * The agent-definition cross-check (below) prevents cross-agent injection: a user who
     * legitimately owns an execution for AgentA cannot re-drive it through AgentB's
     * orchestrator by passing a mismatched existingExecutionId.
     */
    private void validateExecutionAccess(Id executionId, Id userId) {
        List<AgentExecution__c> executions = [
            SELECT Id, ProcessingStatus__c, AIAgentDefinition__c
            FROM AgentExecution__c
            WHERE Id = :executionId AND User__c = :userId
            LIMIT 1
        ];

        if (executions.isEmpty()) {
            throw new AIAgentException.OrchestrationException('Execution not found or access denied: ' + executionId);
        }

        AgentExecution__c execution = executions[0];
        if (execution.ProcessingStatus__c != AIAgentConstants.STATUS_IDLE && execution.ProcessingStatus__c != AIAgentConstants.STATUS_FAILED) {
            throw new AIAgentException.OrchestrationException('Execution is currently busy (Status: ' + execution.ProcessingStatus__c + ')');
        }

        // Verify the execution is bound to the same agent this orchestrator serves.
        // configure() is always called before start(), so agentDefinition is guaranteed non-null here.
        if (this.agentDefinition != null && execution.AIAgentDefinition__c != this.agentDefinition.Id) {
            throw new AIAgentException.OrchestrationException('Execution ' + executionId + ' does not belong to the requested agent. Access denied.');
        }
    }

    /**
     * Helper method to extract required String field from payload.
     */
    private String getRequiredString(Map<String, Object> payload, String fieldName, String logPrefix) {
        if (!payload.containsKey(fieldName) || payload.get(fieldName) == null) {
            String errorMsg = 'Required field missing from payload: ' + fieldName;
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
            throw new AIAgentException.OrchestrationException(errorMsg);
        }
        return (String) payload.get(fieldName);
    }

    /**
     * Helper method to extract required Id field from payload.
     */
    private Id getRequiredId(Map<String, Object> payload, String fieldName, String logPrefix) {
        if (!payload.containsKey(fieldName) || payload.get(fieldName) == null) {
            String errorMsg = 'Required field missing from payload: ' + fieldName;
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
            throw new AIAgentException.OrchestrationException(errorMsg);
        }
        return (Id) payload.get(fieldName);
    }

    /**
     * Helper method to get user name for dynamic descriptions
     *
     * @param userId The user ID
     * @return User name or fallback
     */
    private String getUserName(Id userId) {
        try {
            if (userId != null) {
                User user = [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
                return user.Name;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not retrieve user name for ID: ' + userId + '. Error: ' + e.getMessage());
        }
        return 'User';
    }

    /**
     * Helper method to get agent name for dynamic descriptions
     *
     * @param agentDefinitionId The agent definition ID
     * @return Agent name or fallback
     */
    private String getAgentName(Id agentDefinitionId) {
        return AIAgentConfigService.getAgentName(agentDefinitionId);
    }
}
