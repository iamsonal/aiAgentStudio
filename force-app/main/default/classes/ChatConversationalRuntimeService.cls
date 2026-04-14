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
public inherited sharing class ChatConversationalRuntimeService implements IAgentRuntime {
    private static final String LOG_PREFIX = '[ChatIterativeRuntime] ';
    private AIAgentDefinition__c agentDefinition;

    public ChatConversationalRuntimeService() {
    }
    public ChatConversationalRuntimeService(AIAgentDefinition__c agentDefinition) {
        configure(agentDefinition);
    }

    public void configure(AIAgentDefinition__c agentDefinition) {
        if (agentDefinition == null) {
            throw new AIAgentException.OrchestrationException('Agent definition is required for ChatConversationalRuntimeService');
        }
        this.agentDefinition = agentDefinition;
    }

    public AIAgentDefinition__c getAgentDefinition() {
        return this.agentDefinition;
    }

    public AgentExecutionService.ExecutionResult start(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting conversational execution');

        try {
            if (String.isBlank(payload.userMessage)) {
                throw new AIAgentException.OrchestrationException('User message is required for conversational execution');
            }
            if (String.isBlank(payload.turnIdentifier)) {
                throw new AIAgentException.OrchestrationException('Turn identifier is required for conversational execution');
            }

            String interactionChannel = String.isNotBlank(payload.interactionChannel) ? payload.interactionChannel : RuntimeRegistryService.CHANNEL_CHAT;

            Id executionId;

            if (payload.existingExecutionId != null) {
                validateExecutionAccess(payload.existingExecutionId, payload.userId);
                AgentExecution__c existingExecution = [
                    SELECT InteractionChannel__c, InteractionSession__c
                    FROM AgentExecution__c
                    WHERE Id = :payload.existingExecutionId
                    LIMIT 1
                ];
                executionId = payload.existingExecutionId;
                logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '][Exec:' + executionId + '] ';
                if (String.isBlank(payload.interactionChannel) && String.isNotBlank(existingExecution.InteractionChannel__c)) {
                    interactionChannel = existingExecution.InteractionChannel__c;
                }
                if (payload.interactionSessionId == null) {
                    payload.interactionSessionId = existingExecution.InteractionSession__c;
                }

                if (shouldExecuteSynchronously(payload, logPrefix)) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'Executing initial LLM call synchronously (callout-safe)');
                    TransactionContext.getInstance().markSyncFinalizationRecovery(executionId, payload.turnIdentifier);
                    AgentExecutionService.ExecutionResult syncResult = executeSynchronously(executionId, payload, logPrefix);
                    // Sync path cannot pre-stamp the turn identifier before callouts (Apex DML-before-callout restriction).
                    // completeTurnSuccessfully() inside may have been silently skipped by the stale check.
                    // Finalize the execution status now that all callouts are complete.
                    Boolean finalizationApplied = new AgentStateService()
                        .syncFinalizeExecution(executionId, payload.turnIdentifier, syncResult.status, syncResult.message, logPrefix);
                    if (!finalizationApplied) {
                        syncResult.success = false;
                        syncResult.status = AIAgentConstants.EXECUTION_STATUS_PAUSED;
                        syncResult.message = 'Execution paused due to sync finalization recovery failure';
                        syncResult.errorCode = AIAgentConstants.ERR_CODE_SYNC_FINALIZATION_FAILED;
                        syncResult.errorMessage = 'Synchronous turn finalization recovery failed and the execution was paused for operator review.';
                        return syncResult;
                    }
                    if (syncResult.success == true && syncResult.executionId != null && syncResult.status == AIAgentConstants.STATUS_PROCESSING) {
                        syncResult.status = AIAgentConstants.STATUS_IDLE;
                        syncResult.message = 'Turn completed';
                    }
                    return syncResult;
                }

                if (payload.interactionSessionId == null) {
                    InteractionRuntimeModels.InteractionSessionContext sessionContext = resolveInteractionSession(payload, interactionChannel, logPrefix);
                    payload.interactionSessionId = sessionContext != null ? sessionContext.sessionId : null;
                }

                AgentStateService agentStateSvc = new AgentStateService();
                agentStateSvc.updateStatus(
                    executionId,
                    'Processing',
                    AIAgentConstants.STATUS_PROCESSING,
                    payload.turnIdentifier,
                    'Processing conversational turn'
                );
                update new AgentExecution__c(
                    Id = executionId,
                    InteractionChannel__c = interactionChannel,
                    InteractionSession__c = payload.interactionSessionId,
                    TriggerPayload__c = payload.triggerPayload,
                    SessionLastInboundAt__c = Datetime.now()
                );
            } else {
                InteractionRuntimeModels.InteractionSessionContext sessionContext = resolveInteractionSession(payload, interactionChannel, logPrefix);
                payload.interactionSessionId = sessionContext != null ? sessionContext.sessionId : null;
                AgentStateService agentStateService = new AgentStateService();
                executionId = agentStateService.createExecution(
                    RuntimeRegistryService.getExecutionStrategyKey(agentDefinition),
                    agentDefinition.Id,
                    payload.triggerSource,
                    payload.triggerPayload,
                    payload.sourceRecordId,
                    payload.userId,
                    payload.serviceUserId,
                    null, // parentExecutionId
                    payload.turnIdentifier, // pre-set so async updateStatus(Processing) passes the stale check
                    payload.executionIdentityProfileDeveloperName,
                    payload.executionIdentityNamedCredential
                );
                update new AgentExecution__c(
                    Id = executionId,
                    InteractionChannel__c = interactionChannel,
                    InteractionSession__c = payload.interactionSessionId,
                    SessionStartedAt__c = Datetime.now(),
                    SessionLastInboundAt__c = Datetime.now()
                );
                logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '][Exec:' + executionId + '] ';
            }

            if (payload.interactionSessionId != null) {
                new InteractionSessionService().stampExecution(payload.interactionSessionId, executionId);
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Created/updated execution');

            // Determine async strategy based ONLY on AsyncDispatchType__c
            String asyncDispatchType = resolveAsyncDispatchType();

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

    public AgentExecutionService.ExecutionResult resume(Id executionId, ExecutionResumeModels.ResumeOptions options) {
        String logPrefix = LOG_PREFIX + '[resume Exec:' + executionId + '] ';
        try {
            AgentExecution__c execution = AgentRuntimeSupport.validateResumable(executionId, logPrefix);
            ExecutionResumeModels.ResumePoint resumePoint = determineResumePoint(executionId, execution, options, logPrefix);
            String newTurnIdentifier = AgentRuntimeSupport.generateTurnIdentifier();

            if (!shouldDeferResumePreparation(execution, resumePoint, options)) {
                AgentRuntimeSupport.clearResumeTurnGuard(executionId, execution, logPrefix);
                AgentRuntimeSupport.logResumeAttempt(executionId, execution, newTurnIdentifier, resumePoint, options, logPrefix);
            }

            return executeResume(executionId, execution, newTurnIdentifier, resumePoint, options, logPrefix);
        } catch (AIAgentException.OrchestrationException e) {
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Resume failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AIAgentException.OrchestrationException('Failed to resume execution: ' + e.getMessage());
        }
    }

    public Boolean canResume(Id executionId) {
        return AgentRuntimeSupport.canResume(executionId);
    }

    private String resolveAsyncDispatchType() {
        Map<String, Object> fields = agentDefinition != null ? agentDefinition.getPopulatedFieldsAsMap() : new Map<String, Object>();
        String dispatchType = (String) fields.get('AsyncDispatchType__c');
        if (String.isNotBlank(dispatchType)) {
            return dispatchType;
        }
        if (agentDefinition != null && agentDefinition.Id != null) {
            try {
                AIAgentDefinition__c hydrated = AIAgentConfigService.getAgentDefinition(agentDefinition.Id);
                if (String.isNotBlank(hydrated.AsyncDispatchType__c)) {
                    return hydrated.AsyncDispatchType__c;
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Could not hydrate AsyncDispatchType__c: ' + e.getMessage());
            }
        }
        return 'Low';
    }

    private InteractionRuntimeModels.InteractionSessionContext resolveInteractionSession(
        AgentExecutionService.ExecutionPayload payload,
        String interactionChannel,
        String logPrefix
    ) {
        Map<String, Object> metadata = new Map<String, Object>{
            'existingExecutionId' => payload.existingExecutionId != null ? String.valueOf(payload.existingExecutionId) : null,
            'interactionSessionId' => payload.interactionSessionId != null ? String.valueOf(payload.interactionSessionId) : null,
            'userId' => payload.userId != null ? String.valueOf(payload.userId) : null,
            'turnIdentifier' => payload.turnIdentifier,
            'conversationKey' => String.isNotBlank(payload.conversationKey) ? payload.conversationKey : UUID.randomUUID().toString()
        };

        InteractionRuntimeModels.IInteractionChannel adapter = InteractionChannelRegistryService.resolveAdapter(
            agentDefinition,
            payload.existingExecutionId,
            interactionChannel
        );
        InboundInteractionPipelineService.ResolvedInbound resolved = new InboundInteractionPipelineService()
            .resolve(agentDefinition, adapter, payload.sourceRecordId, payload.userMessage, metadata, logPrefix);
        return resolved.sessionContext;
    }

    /**
     * @description Determines whether the initial LLM call can run inline.
     * Defaults to synchronous only when the current transaction can make callouts
     * and the agent does not require service user context routing.
     */
    private Boolean shouldExecuteSynchronously(AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        if (String.isNotBlank(agentDefinition.ExecutionIdentityProfileDeveloperName__c)) {
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

    // CHILD AGENT COMPLETION (agent-as-capability)

    /**
     * @description Called by AgentExecutionTriggerHandler when a child agent execution completes.
     * Maps the child's result back to the original tool call, creates a ToolResult execution step,
     * and delegates to OrchestrationService.onAsyncToolCompleted() for counter management and
     * follow-up LLM invocation.
     */
    public void onChildComplete(Id executionId, Map<String, Object> asyncPayload) {
        String logPrefix = '[ChatConversationalRuntimeService][onChildComplete] ';

        Id childExecutionId = (Id) asyncPayload.get('childExecutionId');
        Boolean success = (Boolean) asyncPayload.get('success');
        String response = (String) asyncPayload.get('response');
        String errorMessage = (String) asyncPayload.get('errorMessage');
        String completedAgent = (String) asyncPayload.get('completedAgent');

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'Child agent completed: ' +
                completedAgent +
                ', Success: ' +
                success +
                ', ChildExecId: ' +
                childExecutionId +
                ', ParentExecId: ' +
                executionId
        );

        String toolCallId = null;
        String toolName = null;
        String parentTurnIdentifier = null;
        Integer parentTurnCount = null;
        try {
            AgentExecution__c childExec = [
                SELECT TriggerPayload__c
                FROM AgentExecution__c
                WHERE Id = :childExecutionId
                LIMIT 1
            ];

            if (String.isNotBlank(childExec.TriggerPayload__c)) {
                Map<String, Object> triggerData = (Map<String, Object>) JSON.deserializeUntyped(childExec.TriggerPayload__c);
                toolCallId = (String) triggerData.get('toolCallId');
                toolName = (String) triggerData.get('toolName');
                parentTurnIdentifier = (String) triggerData.get('parentTurnIdentifier');
                Object turnCountObj = triggerData.get('parentTurnCount');
                if (turnCountObj != null) {
                    parentTurnCount = Integer.valueOf(String.valueOf(turnCountObj));
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Could not retrieve toolCallId from child execution: ' + e.getMessage());
        }

        if (String.isBlank(toolCallId)) {
            toolCallId = String.valueOf(childExecutionId);
        }
        if (String.isBlank(toolName)) {
            toolName = completedAgent;
        }

        AgentExecution__c parentExec = [
            SELECT CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];

        // Early stale-turn detection: if the parent's turn has rotated since
        // this child was spawned, the completion is orphaned. Drop it before
        // creating any ToolResult steps to avoid polluting the current turn.
        if (
            String.isNotBlank(parentTurnIdentifier) &&
            String.isNotBlank(parentExec.CurrentTurnIdentifier__c) &&
            !parentTurnIdentifier.equals(parentExec.CurrentTurnIdentifier__c)
        ) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix +
                    'Stale child completion detected. Spawned under turn: ' +
                    parentTurnIdentifier +
                    ', Parent current turn: ' +
                    parentExec.CurrentTurnIdentifier__c +
                    '. Ignoring.'
            );
            return;
        }

        String turnIdentifier = String.isNotBlank(parentTurnIdentifier) ? parentTurnIdentifier : parentExec.CurrentTurnIdentifier__c;
        Integer currentTurnCount = (parentTurnCount != null) ? parentTurnCount : 0;

        String resultContent;
        Boolean isError = false;
        if (success) {
            resultContent = JSON.serialize(
                new Map<String, Object>{
                    'success' => true,
                    'agent' => completedAgent,
                    'result' => String.isNotBlank(response) ? response : 'Agent completed successfully.'
                }
            );
        } else {
            isError = true;
            resultContent = JSON.serialize(
                new Map<String, Object>{
                    'success' => false,
                    'agent' => completedAgent,
                    'error' => String.isNotBlank(errorMessage) ? errorMessage : 'Agent execution failed.',
                    'code' => asyncPayload.get('errorCode')
                }
            );
        }

        try {
            ExecutionStepService executionStepService = new ExecutionStepService();
            executionStepService.createToolResultStep(
                executionId,
                toolCallId,
                toolName,
                resultContent,
                turnIdentifier,
                currentTurnCount,
                0L,
                true,
                null,
                isError,
                false
            );
            System.debug(LoggingLevel.INFO, logPrefix + 'Created ToolResult step for agent capability: ' + toolName);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create ToolResult step: ' + e.getMessage());
        }

        OrchestrationService.onAsyncToolCompleted(executionId, turnIdentifier, currentTurnCount, toolCallId, logPrefix);
    }

    // LLM CUSTOMIZATION HOOKS (override from BaseAgentOrchestrator)

    /**
     * Injects summarization instructions for multi-step conversational turns.
     * This ensures the user gets a coherent summary after tool executions.
     */
    public String buildSystemPromptAdditions(OrchestrationContext context) {
        // Only inject for multi-step turns where we're doing a follow-up call (no user message)
        Boolean isMultiStepTurn = context.currentTurnCount > 1;
        Boolean isFollowUpCall = (context.userMessageData == null || String.isBlank(context.userMessageData.content));

        if (isMultiStepTurn && isFollowUpCall) {
            System.debug(LoggingLevel.INFO, context.logPrefix + 'Injecting summarization instructions for conversational agent');

            return AIAgentConstants.PROMPT_SECTION_FINAL_INSTRUCTIONS + AIAgentConstants.PROMPT_FOLLOWUP_SUMMARIZE;
        }

        return '';
    }

    /**
     * Handles conversational-specific behavior after tool completion.
     * For approval scenarios, creates an assistant message and completes the turn.
     */
    public String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario) {
        String logPrefix = context.logPrefix + '[ConvToolCompletion] ';

        if (scenario == 'APPROVAL_REQUIRED') {
            // For conversational agents, approvals can coexist with async tools/child agents in the
            // same turn. If async work is still outstanding, keep the execution in the shared waiting
            // state instead of completing the turn early and orphaning later completions.

            // Find the tool that requires approval
            String toolName = 'the requested action';
            if (toolResults != null && !toolResults.isEmpty()) {
                toolName = toolResults[0].toolName;
            }

            String assistantMessage = String.format(AIAgentConstants.MSG_APPROVAL_SUBMITTED_TEMPLATE, new List<Object>{ toolName });

            ExecutionStepService executionStepService = new ExecutionStepService();
            Id assistantMessageId = executionStepService.createAgentResponseStep(
                context.executionId,
                assistantMessage,
                context.turnIdentifier,
                context.currentTurnCount
            );

            context.decisionLogger.log(IDecisionStepLogger.EventType.FINAL_RESPONSE, new List<Object>{ assistantMessage });

            AgentExecution__c execution = [
                SELECT PendingAsyncToolCount__c
                FROM AgentExecution__c
                WHERE Id = :context.executionId
                LIMIT 1
            ];
            Integer pendingAsyncCount = execution.PendingAsyncToolCount__c != null ? Integer.valueOf(execution.PendingAsyncToolCount__c) : 0;
            if (pendingAsyncCount > 0) {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Approval requested while ' + pendingAsyncCount + ' async tool(s) are still pending. Keeping the turn in Awaiting Action.'
                );
                return OrchestrationService.OUTCOME_QUEUED_ACTION;
            }

            // No async work is outstanding, so this approval can safely complete the current chat turn.
            context.agentStateSvc.completeTurnSuccessfully(context.executionId, context.turnIdentifier, assistantMessageId, logPrefix);

            return OrchestrationService.OUTCOME_COMPLETED;
        }

        // Delegate to base class for all other scenarios (e.g. CONTENT_ONLY_RESPONSE retry enforcement)
        return AgentRuntimeSupport.evaluateToolOutcome(context, toolResults, scenario);
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
    public void runAsync(Map<String, Object> payload, String logPrefix) {
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

        new ConversationalTurnExecutionService()
            .executeInitialTurn(
                executionId,
                originalUserId,
                executionUserId,
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                userMessage,
                currentRecordId,
                logPrefix
            );
    }

    // RESUME IMPLEMENTATION

    /**
     * Determines resume point for conversational executions.
     * Conversational agents typically resume with an LLM call to continue the conversation.
     */
    private ExecutionResumeModels.ResumePoint determineResumePoint(
        Id executionId,
        AgentExecution__c execution,
        ExecutionResumeModels.ResumeOptions options,
        String logPrefix
    ) {
        ExecutionResumeModels.ResumePoint resumePoint = new ExecutionResumeModels.ResumePoint();
        resumePoint.lastTurnCount = AgentRuntimeSupport.getLastTurnCount(executionId);
        resumePoint.turnCount = 1; // Reset for fresh cycle budget

        // Check if we should retry a failed tool
        Boolean shouldRetryTool = options?.retryFailedTool;

        if (shouldRetryTool == null) {
            if ('Retry Failed Operation'.equals(resolveResumeMode())) {
                Map<String, Object> failedTool = AgentRuntimeSupport.findLastFailedTool(executionId);
                shouldRetryTool = (failedTool != null);

                if (shouldRetryTool) {
                    resumePoint.toolCallId = (String) failedTool.get('toolCallId');
                    resumePoint.toolName = (String) failedTool.get('toolName');
                    System.debug(LoggingLevel.INFO, logPrefix + 'Auto-detected failed tool (ResumeMode=Retry Failed Operation): ' + resumePoint.toolName);
                } else {
                    System.debug(LoggingLevel.WARN, logPrefix + 'ResumeMode=Retry Failed Operation but no failed tool found, defaulting to LLM_CONTINUE');
                }
            } else {
                shouldRetryTool = false;
                System.debug(LoggingLevel.INFO, logPrefix + 'ResumeMode=LLM First, defaulting to LLM_CONTINUE');
            }
        } else if (shouldRetryTool == true) {
            // Explicit retry - find the failed tool
            Map<String, Object> failedTool = AgentRuntimeSupport.findLastFailedTool(executionId);
            if (failedTool != null) {
                resumePoint.toolCallId = (String) failedTool.get('toolCallId');
                resumePoint.toolName = (String) failedTool.get('toolName');
            } else {
                // No failed tool found, fall back to LLM continue
                shouldRetryTool = false;
                System.debug(LoggingLevel.WARN, logPrefix + 'No failed tool found, falling back to LLM_CONTINUE');
            }
        }

        resumePoint.resumeType = shouldRetryTool ? ExecutionResumeModels.ResumeType.RETRY_FAILED_TOOL : ExecutionResumeModels.ResumeType.LLM_CONTINUE;

        System.debug(LoggingLevel.INFO, logPrefix + 'Resume strategy: ' + resumePoint.resumeType);
        return resumePoint;
    }

    private String resolveResumeMode() {
        Map<String, Object> populatedFields = agentDefinition != null ? agentDefinition.getPopulatedFieldsAsMap() : null;
        String resumeMode = populatedFields != null ? (String) populatedFields.get('ResumeMode__c') : null;
        return String.isBlank(resumeMode) ? 'LLM First' : resumeMode;
    }

    /**
     * Executes resume for conversational executions.
     * Enqueues a follow-up LLM call or tool retry.
     */
    private AgentExecutionService.ExecutionResult executeResume(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ExecutionResumeModels.ResumePoint resumePoint,
        ExecutionResumeModels.ResumeOptions options,
        String logPrefix
    ) {
        if (resumePoint.resumeType == ExecutionResumeModels.ResumeType.RETRY_FAILED_TOOL) {
            // Retry the failed tool
            return retryFailedTool(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
        } else {
            // Update execution with new turn identifier
            AgentStateService agentStateSvc = new AgentStateService();
            agentStateSvc.updateStatus(executionId, 'Processing', AIAgentConstants.STATUS_PROCESSING, newTurnIdentifier, 'Resuming conversational execution');
            // Continue with LLM call
            return continueWithLLMCall(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
        }
    }

    private Boolean shouldDeferResumePreparation(
        AgentExecution__c execution,
        ExecutionResumeModels.ResumePoint resumePoint,
        ExecutionResumeModels.ResumeOptions options
    ) {
        if (resumePoint == null || resumePoint.resumeType != ExecutionResumeModels.ResumeType.RETRY_FAILED_TOOL || String.isBlank(resumePoint.toolName)) {
            return false;
        }

        AgentCapability__c capability = AIAgentConfigService.getCapability(agentDefinition.Id, resumePoint.toolName);
        return capability != null && capability.RunAsynchronously__c != true;
    }

    /**
     * Retries a failed tool execution.
     */
    private AgentExecutionService.ExecutionResult retryFailedTool(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ExecutionResumeModels.ResumePoint resumePoint,
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

        if (shouldDeferResumePreparation(execution, resumePoint, null)) {
            update new AgentExecution__c(Id = executionId, CurrentTurnIdentifier__c = newTurnIdentifier, AsyncToolTurnIdentifier__c = null);
            AgentRuntimeSupport.logResumeAttempt(executionId, execution, newTurnIdentifier, resumePoint, null, logPrefix);
        }

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
            null,
            null,
            null,
            true
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
            // For a user-initiated manual retry, always fail immediately regardless of the
            // shouldFailFast setting. The agent has already been given one extra chance via
            // the resume; silently continuing to an LLM call without telling the user the
            // retry still failed would be confusing. The LLM also has no context about the
            // retry failure without an explicit error turn.
            AgentStateService agentStateSvc = new AgentStateService();
            agentStateSvc.failTurn(executionId, newTurnIdentifier, toolOutcome.errorMessage, toolOutcome.errorCode, logPrefix);
            return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Tool retry failed: ' + toolOutcome.errorMessage);
        }

        // Tool succeeded — let the LLM see the result and continue the conversation.
        return continueWithLLMCall(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
    }

    /**
     * Continues execution with an LLM call.
     */
    private AgentExecutionService.ExecutionResult continueWithLLMCall(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ExecutionResumeModels.ResumePoint resumePoint,
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
            'executionId' => executionId,
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
            'userMessage' => payload.userMessage,
            'interactionChannel' => String.isNotBlank(payload.interactionChannel) ? payload.interactionChannel : RuntimeRegistryService.CHANNEL_CHAT
        };

        UnifiedAgentQueueable queueable = new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_ITERATIVE, queueablePayload);
        Id jobId = new AgentJobEnqueuer().enqueueQueueable(queueable, logPrefix, agentDefinition.Id);
        System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued UnifiedAgentQueueable job (Conversational type): ' + jobId + ' for execution: ' + executionId);
    }

    /**
     * Executes a conversational turn synchronously without queueable overhead.
     * Supports multi-LLM optimization when sync tools don't perform DML/callouts.
     */
    private AgentExecutionService.ExecutionResult executeSynchronously(Id executionId, AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        try {
            ConversationalTurnExecutionService.RunResult runResult = new ConversationalTurnExecutionService()
                .executeInitialTurn(
                    executionId,
                    payload.userId,
                    payload.userId,
                    agentDefinition.Id,
                    agentDefinition.LLMConfiguration__c,
                    payload.turnIdentifier,
                    payload.userMessage,
                    payload.currentRecordId,
                    logPrefix
                );
            String outcome = runResult.outcome;

            // Determine status based on outcome — must distinguish QUEUED_ACTION from
            // QUEUED_FOLLOWUP so that syncFinalizeExecution() stamps the correct
            // ProcessingStatus__c. Collapsing both to STATUS_PROCESSING would cause
            // the follow-up worker to abort (it expects Awaiting Followup).
            String status = AIAgentConstants.STATUS_IDLE;
            String message = 'Turn completed';

            if (outcome == OrchestrationService.OUTCOME_FAILED) {
                status = AIAgentConstants.STATUS_FAILED;
                message = 'Turn failed';
            } else if (outcome == OrchestrationService.OUTCOME_QUEUED_ACTION) {
                status = AIAgentConstants.STATUS_AWAITING_ACTION;
                message = 'Processing tool actions';
            } else if (outcome == OrchestrationService.OUTCOME_QUEUED_FOLLOWUP) {
                status = AIAgentConstants.STATUS_AWAITING_FOLLOWUP;
                message = 'Awaiting follow-up LLM call';
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
}
