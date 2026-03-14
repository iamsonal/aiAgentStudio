/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Factory/dispatcher for SingleShot strategy runtimes that routes to specialized execution patterns.
 * This runtime delegates to:
 * - SingleShotSyncRuntimeService: Tool-terminating pattern (0-1 sync tools)
 * - SingleShotAsyncRuntimeService: Iterative agentic pattern (2+ tools or 1 async tool)
 * - AgentExecutionDispatcher: Bulk execution (multiple sourceRecordIds)
 *
 * **Key Characteristics:**
 * - **Pure Factory**: No business logic, only routing decisions
 * - **Stateless**: No conversation history or memory across invocations
 * - **Single-Shot**: One input → One output (no multi-turn dialogue)
 * - **Pattern Selection**: Routes based on capability count and async nature
 * - **Bulk Support**: Automatically routes to bulk execution when multiple records provided
 *
 * **Routing Logic:**
 * - sourceRecordIds.size() > 1 → AgentExecutionDispatcher (parallel queueables)
 * - existingExecutionId provided → SingleShotAsyncRuntimeService (pipeline step or sub-agent)
 * - 0-1 sync tools → SingleShotSyncRuntimeService (immediate return)
 * - 1 async tool or 2+ tools → SingleShotAsyncRuntimeService (queueable chain)
 *
 * @example
 * // Create SingleShot agent
 * AIAgentDefinition__c functionAgent = new AIAgentDefinition__c(
 *     Name = 'Case Summarizer',
 *     AgentType__c = 'SingleShot',
 *     AuditLevel__c = 'Standard'
 * );
 *
 * // Invoke via runtime service
 * SingleShotRuntimeService runtimeService = new SingleShotRuntimeService(functionAgent);
 * FunctionExecutionResult result = runtimeService.execute('Summarize this case', caseId);
 *
 * @author Sonal
 * @since 2025
 */
public with sharing class SingleShotRuntimeService implements IAgentRuntime {
    private static final String LOG_PREFIX = '[FunctionOrch] ';

    private AIAgentDefinition__c agentDefinition;
    private LLMConfiguration__c llmConfig;
    private String triggerPayload;

    /**
     * @description No-argument constructor for dynamic instantiation via Type.newInstance().
     * Must call configure() before using the runtime service.
     */
    public SingleShotRuntimeService() {
        // No-op constructor for reflection-based instantiation
    }

    /**
     * @description Parameterized constructor for direct instantiation.
     * @param agentDef The agent definition (must resolve to the API/function runtime)
     * @throws AIAgentException.OrchestrationException if agent definition is null or does not resolve to the single-shot runtime
     */
    public SingleShotRuntimeService(AIAgentDefinition__c agentDef) {
        configure(agentDef);
    }

    // ===================================================================================
    // LIFECYCLE METHODS
    // ===================================================================================

    /**
     * @description Configures the runtime service with the agent definition.
     * @param agentDef The agent definition configuration
     * @throws AIAgentException.OrchestrationException if agent definition is null or not a SingleShot strategy
     */
    public void configure(AIAgentDefinition__c agentDef) {
        if (agentDef == null) {
            throw new AIAgentException.OrchestrationException('Agent definition is required for SingleShotRuntimeService');
        }

        String strategyKey = RuntimeRegistryService.getExecutionStrategyKey(agentDef);
        if (!String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.SingleShot).equalsIgnoreCase(strategyKey)) {
            throw new AIAgentException.OrchestrationException('SingleShotRuntimeService requires the SingleShot strategy. Provided strategy: ' + strategyKey);
        }

        this.agentDefinition = agentDef;
        this.llmConfig = AgentRuntimeSupport.loadLlmConfiguration(agentDef);
    }

    public AIAgentDefinition__c getAgentDefinition() {
        return this.agentDefinition;
    }

    /**
     * @description
     * Starts a single-shot execution for the strategy runtime.
     * Routes to the appropriate specialized runtime based on execution context.
     *
     * **Multi-Record Routing (DLQ Pattern):**
     * - Multiple records → DLQ dispatch with self-regulating workers
     * - Progress tracked via BatchId__c aggregate queries
     *
     * @param agentName The developer name of the agent
     * @param payload The execution payload containing user message and context
     * @return ExecutionResult with immediate response or processing status
     * @throws AIAgentException.OrchestrationException if payload is invalid
     */
    public AgentExecutionService.ExecutionResult start(String agentName, AgentExecutionService.ExecutionPayload payload) {
        String logPrefix = '[SingleShotRuntimeService.start] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting function execution for agent: ' + agentName);

        // Validate payload
        validatePayload(payload);

        this.triggerPayload = payload.triggerPayload;

        AgentExecutionService.ExecutionResult multiRecordResult = tryDispatchMultiRecord(logPrefix, agentName, payload);
        if (multiRecordResult != null) {
            return multiRecordResult;
        }

        // SINGLE RECORD EXECUTION - Continue with normal function processing

        // Normalize payload: if sourceRecordIds has exactly 1 element, extract it to sourceRecordId
        if (payload.sourceRecordId == null && payload.sourceRecordIds != null && payload.sourceRecordIds.size() == 1) {
            payload.sourceRecordId = payload.sourceRecordIds[0];
            System.debug(logPrefix + 'Normalized single-element sourceRecordIds list to sourceRecordId: ' + payload.sourceRecordId);
        }

        // Use sourceRecordId if available, otherwise try currentRecordId (for conversational context)
        Id contextRecordId = payload.sourceRecordId != null ? payload.sourceRecordId : payload.currentRecordId;

        // Execute the single-shot runtime flow
        FunctionExecutionResult functionResult = execute(
            payload.userMessage,
            contextRecordId,
            payload.userId,
            payload.turnIdentifier,
            payload.existingExecutionId // Pass existing execution ID from payload (pipeline step or bulk context)
        );

        // Convert to standard ExecutionResult format
        AgentExecutionService.ExecutionResult result = convertToExecutionResult(functionResult);

        System.debug(LoggingLevel.INFO, logPrefix + 'Function execution completed. Success: ' + result.success);
        return result;
    }

    public AgentExecutionService.ExecutionResult resume(Id executionId, ExecutionResumeModels.ResumeOptions options) {
        String logPrefix = LOG_PREFIX + '[resume Exec:' + executionId + '] ';
        try {
            AgentExecution__c execution = AgentRuntimeSupport.validateResumable(executionId, logPrefix);
            ExecutionResumeModels.ResumePoint resumePoint = determineResumePoint(executionId, execution, options, logPrefix);
            String newTurnIdentifier = generateResumeIdentifier(execution, options);

            if (!shouldDeferResumePreparation(execution, resumePoint, options)) {
                AgentRuntimeSupport.clearResumeTurnGuard(executionId, execution, logPrefix);
                logResumeAttempt(executionId, execution, newTurnIdentifier, resumePoint, options, logPrefix);
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

    /**
     * Handles multi-record DLQ dispatch when payload contains multiple sourceRecordIds.
     * Returns an ExecutionResult if dispatch occurred, or null if not applicable.
     */
    private AgentExecutionService.ExecutionResult tryDispatchMultiRecord(String logPrefix, String agentName, AgentExecutionService.ExecutionPayload payload) {
        if (payload == null || payload.sourceRecordIds == null || payload.sourceRecordIds.size() <= 1) {
            return null;
        }

        Integer recordCount = payload.sourceRecordIds.size();
        System.debug(LoggingLevel.INFO, logPrefix + 'DLQ dispatch for ' + recordCount + ' records');

        AgentExecutionDispatcher.DispatchResult dispatchResult = AgentExecutionDispatcher.dispatch(agentName, payload);

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'DLQ dispatch completed. BatchId: ' +
                dispatchResult.batchId +
                ', Created: ' +
                dispatchResult.executionIds.size() +
                ' executions' +
                ', Enqueued: ' +
                dispatchResult.enqueuedJobCount +
                ' workers'
        );

        return new AgentExecutionService.ExecutionResult(
            dispatchResult.executionIds.isEmpty() ? null : dispatchResult.executionIds[0],
            'Processing',
            'DLQ dispatch started for ' +
                recordCount +
                ' records. ' +
                dispatchResult.enqueuedJobCount +
                ' workers enqueued. ' +
                'BatchId: ' +
                dispatchResult.batchId +
                '. Workers will self-pull remaining work.'
        );
    }

    /**
     * @description
     * Core factory method that routes to appropriate execution strategy.
     * Acts as a pure dispatcher to delegate to specialized runtime services.
     *
     * Centralized DML detection: If pre-existing DML is detected, execution is deferred
     * to a Queueable worker before routing to the specialized runtime services. This ensures callout
     * safety is handled in one place.
     *
     * @param input The primary text input for the task
     * @param recordId The record context for the task (can be null)
     * @param userId The user ID (defaults to current user if null)
     * @param turnIdentifier The turn identifier (auto-generated if null)
     * @param existingExecutionId Optional execution ID to reuse (for pipeline step agents or bulk context)
     * @return FunctionExecutionResult containing the response or processing status
     */
    public FunctionExecutionResult execute(String input, Id recordId, Id userId, String turnIdentifier, Id existingExecutionId) {
        // Use provided userId or default to current user
        if (userId == null) {
            userId = UserInfo.getUserId();
        }

        // Auto-generate turn identifier if not provided
        if (String.isBlank(turnIdentifier)) {
            turnIdentifier = UUID.randomUUID().toString();
        }

        String logPrefix = '[SingleShotRuntimeService Agent:' + agentDefinition.DeveloperName__c + ' Turn:' + turnIdentifier.left(8) + '] ';

        try {
            // Query capabilities to determine execution pattern
            List<AgentCapability__c> capabilities = [
                SELECT Id, CapabilityName__c, RunAsynchronously__c, ImplementationType__c
                FROM AgentCapability__c
                WHERE AIAgentDefinition__c = :agentDefinition.Id AND ExposureLevel__c = 'External'
            ];
            Integer capabilityCount = capabilities.size();

            System.debug(LoggingLevel.INFO, logPrefix + 'Agent has ' + capabilityCount + ' capabilities configured');

            // --- CENTRALIZED PRE-EXISTING DML DETECTION ---
            // If DML has already occurred in this transaction (e.g., trigger context, flow with prior DML),
            // we cannot make HTTP callouts. Defer execution to a Queueable worker which runs in a fresh
            // transaction with Database.AllowsCallouts. This check is centralized here so specialized runtimes
            // don't need to duplicate this logic.
            if (hasPriorUncommittedWork()) {
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix +
                        'Pre-existing uncommitted work detected (DML or email). Cannot make LLM callouts in this transaction. ' +
                        'Deferring to Queueable worker.'
                );
                return deferToQueueableWorker(input, recordId, userId, turnIdentifier, capabilities, logPrefix);
            }

            // ROUTE BY CAPABILITIES (NOT CONTEXT): Decouple Execution Strategy from Execution Context
            if (capabilityCount <= 1) {
                Boolean hasAsyncCapability = false;
                if (capabilityCount == 1) {
                    hasAsyncCapability = capabilities[0].RunAsynchronously__c == true || 'Agent'.equalsIgnoreCase(capabilities[0].ImplementationType__c);
                }

                if (hasAsyncCapability) {
                    // Async tool with <=1 capabilities: Use SingleShotAsyncRuntimeService (Iterative Strategy)
                    System.debug(LoggingLevel.INFO, logPrefix + 'Delegating to SingleShotAsyncRuntimeService (1 async tool)');
                    SingleShotAsyncRuntimeService asyncOrchestrator = new SingleShotAsyncRuntimeService(agentDefinition, llmConfig);
                    asyncOrchestrator.setTriggerPayload(this.triggerPayload);
                    return asyncOrchestrator.execute(input, recordId, userId, turnIdentifier, capabilities, existingExecutionId);
                } else {
                    // Synchronous tool or no tools: Use SingleShotSyncRuntimeService (Tool-Terminating Strategy)
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix +
                            'Delegating to SingleShotSyncRuntimeService (0-1 sync tools)' +
                            (existingExecutionId != null ? ' with existing execution context' : '')
                    );
                    SingleShotSyncRuntimeService syncOrchestrator = new SingleShotSyncRuntimeService(agentDefinition, llmConfig);
                    syncOrchestrator.setTriggerPayload(this.triggerPayload);
                    return syncOrchestrator.execute(input, recordId, userId, turnIdentifier, capabilities, existingExecutionId);
                }
            } else {
                // Iterative Agentic Pattern: Multi-turn execution like conversational agents
                System.debug(LoggingLevel.INFO, logPrefix + 'Delegating to SingleShotAsyncRuntimeService (2+ tools)');
                SingleShotAsyncRuntimeService asyncOrchestrator = new SingleShotAsyncRuntimeService(agentDefinition, llmConfig);
                asyncOrchestrator.setTriggerPayload(this.triggerPayload);
                return asyncOrchestrator.execute(input, recordId, userId, turnIdentifier, capabilities, existingExecutionId);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, e.getMessage());
        }
    }

    /**
     * @description
     * Defers execution to a Queueable worker when pre-existing DML prevents callouts.
     * This follows the same pattern as bulk execution:
     * - Transaction 1 (this method): Create AgentExecution__c record (DML), enqueue worker
     * - Transaction 2 (worker): Worker runs with Database.AllowsCallouts, makes LLM call in clean transaction
     *
     * @param input The user input/task description
     * @param recordId The source record ID for context
     * @param userId The user ID
     * @param turnIdentifier The turn identifier
     * @param capabilities List of agent capabilities
     * @param logPrefix Logging prefix
     * @return FunctionExecutionResult with Processing status
     */
    private FunctionExecutionResult deferToQueueableWorker(
        String input,
        Id recordId,
        Id userId,
        String turnIdentifier,
        List<AgentCapability__c> capabilities,
        String logPrefix
    ) {
        try {
            // 1. Create execution record (DML is allowed - no callout in this method)
            AgentStateService execSvc = new AgentStateService();
            String executionLabel = 'Function - ' + Datetime.now().format('MM/dd HH:mm:ss');
            Id executionId = execSvc.createExecution(
                RuntimeRegistryService.getExecutionStrategyKey(agentDefinition),
                agentDefinition.Id,
                'API',
                'Deferred Function (DML in transaction): ' + executionLabel,
                recordId,
                userId,
                null // serviceUserId
            );

            // Set tool-terminating mode flag if ≤1 capabilities
            if (capabilities.size() <= 1) {
                AgentExecution__c execution = new AgentExecution__c(
                    Id = executionId,
                    IsToolTerminatingMode__c = true,
                    CurrentTurnIdentifier__c = turnIdentifier
                );
                update execution;
            } else {
                // Just update turn identifier for multi-tool agents
                AgentExecution__c execUpdate = new AgentExecution__c(Id = executionId, CurrentTurnIdentifier__c = turnIdentifier);
                update execUpdate;
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Created execution record for deferred processing: ' + executionId);

            // Stamp triggerPayload onto the already-created execution record so workers can read it later
            if (String.isNotBlank(this.triggerPayload)) {
                update new AgentExecution__c(Id = executionId, TriggerPayload__c = this.triggerPayload);
            }

            // 2. Build payload for the worker (same pattern as bulk execution)
            AgentExecutionService.ExecutionPayload workerPayload = new AgentExecutionService.ExecutionPayload();
            workerPayload.userId = userId;
            workerPayload.sourceRecordId = recordId;
            workerPayload.turnIdentifier = turnIdentifier;
            workerPayload.userMessage = input;
            workerPayload.triggerSource = 'API';
            workerPayload.triggerPayload = this.triggerPayload;
            workerPayload.existingExecutionId = executionId; // Key: pass the execution ID so worker reuses it

            // 3. Enqueue AgentExecutionWorker - it implements Database.AllowsCallouts
            // so it can make LLM callouts in a fresh transaction
            Id jobId = System.enqueueJob(new AgentExecutionWorker(agentDefinition.DeveloperName__c, workerPayload));

            System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued AgentExecutionWorker for deferred LLM call. Job ID: ' + jobId);

            // 4. Return "Processing" status (same as bulk execution pattern)
            String executionUrl = '/lightning/r/AgentExecution__c/' + executionId + '/view';
            return createProcessingResult(executionId, executionUrl, 'Execution deferred to async worker due to prior DML in transaction');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to defer to queueable worker: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return createFailureResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Failed to defer execution: ' + e.getMessage());
        }
    }

    /**
     * @description Factory method for creating a processing result (async execution)
     */
    private FunctionExecutionResult createProcessingResult(Id executionId, String executionUrl, String statusMessage) {
        FunctionExecutionResult result = new FunctionExecutionResult();
        result.success = true;
        result.status = 'Processing';
        result.requiresPolling = true;
        result.executionId = executionId;
        result.executionUrl = executionUrl;
        result.response = statusMessage;
        return result;
    }

    // ===================================================================================
    // QUEUEABLE JOB EXECUTION
    // ===================================================================================

    /**
     * Executes a Function agent in deferred mode when invoked from a queueable job.
     * Unpacks payload parameters and delegates to this.execute() for proper routing.
     */
    public void runAsync(Map<String, Object> payload, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing Function job in deferred mode');

        if (payload == null) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Payload is null');
            throw new AIAgentException.OrchestrationException('Payload cannot be null');
        }

        try {
            // Extract parameters from payload
            String input = (String) payload.get('input');
            Id recordId = (Id) payload.get('recordId');
            Id userId = (Id) payload.get('userId');
            String turnIdentifier = (String) payload.get('turnIdentifier');
            Id existingExecutionId = (Id) payload.get('existingExecutionId');

            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    'Unpacked payload - input: ' +
                    (input != null ? input.left(50) + '...' : 'null') +
                    ', recordId: ' +
                    recordId +
                    ', userId: ' +
                    userId +
                    ', turnIdentifier: ' +
                    (turnIdentifier != null ? turnIdentifier.left(8) : 'null') +
                    ', existingExecutionId: ' +
                    existingExecutionId
            );

            // Delegate to execute method which will route to appropriate strategy
            FunctionExecutionResult result = this.execute(input, recordId, userId, turnIdentifier, existingExecutionId);

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Deferred execution completed. Success: ' + result.success + ', Status: ' + result.status + ', ExecutionId: ' + result.executionId
            );

            // Note: For deferred execution, we don't return the result since this is running in a queueable
            // The execution status is already updated in the database by the runtime flow
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in deferred execution: ' + e.getMessage() + '\n' + e.getStackTraceString());

            // Try to fail the execution if we have an existing execution ID
            Id existingExecutionId = (Id) payload.get('existingExecutionId');
            String turnIdentifier = (String) payload.get('turnIdentifier');

            if (existingExecutionId != null && String.isNotBlank(turnIdentifier)) {
                try {
                    AgentStateService agentStateSvc = new AgentStateService();
                    agentStateSvc.failTurn(
                        existingExecutionId,
                        turnIdentifier,
                        'Deferred execution failed: ' + e.getMessage(),
                        AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                        logPrefix
                    );
                    System.debug(LoggingLevel.INFO, logPrefix + 'Marked execution as failed due to deferred execution error');
                } catch (Exception failEx) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution status: ' + failEx.getMessage());
                }
            }

            throw new AIAgentException.OrchestrationException('Failed to execute deferred function: ' + e.getMessage());
        }
    }

    // ===================================================================================
    // CHILD AGENT COMPLETION (agent-as-capability)
    // ===================================================================================

    /**
     * @description Called by AgentExecutionTriggerHandler when a child agent execution completes.
     * Maps the child's result back to the original tool call, creates a ToolResult execution step,
     * and delegates to OrchestrationService.onAsyncToolCompleted() for counter management and
     * follow-up LLM invocation.
     */
    public void onChildComplete(Id executionId, Map<String, Object> asyncPayload) {
        String logPrefix = '[SingleShotRuntimeService][onChildComplete] ';

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

        // Retrieve toolCallId and originating-turn contract from child TriggerPayload
        String toolCallId = null;
        String toolName = null;
        String parentTurnIdentifier = null;
        Integer parentTurnCount = null;
        try {
            AgentExecution__c childExec = [
                SELECT TriggerPayload__c, CurrentTurnIdentifier__c
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
            System.debug(LoggingLevel.WARN, logPrefix + 'No toolCallId found on child execution. Using childExecutionId as fallback.');
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

        // Create a ToolResult execution step on the parent execution
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

        // Decrement the async counter and potentially trigger follow-up LLM call
        OrchestrationService.onAsyncToolCompleted(executionId, turnIdentifier, currentTurnCount, toolCallId, logPrefix);
    }

    // ===================================================================================
    // FACTORY METHODS
    // ===================================================================================

    /**
     * @description Factory method for creating a failure result
     */
    private FunctionExecutionResult createFailureResult(String errorCode, String errorMessage) {
        FunctionExecutionResult result = new FunctionExecutionResult();
        result.success = false;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        result.status = 'Failed';
        result.requiresPolling = false;
        return result;
    }

    /**
     * @description Checks for operations that prevent HTTP callouts in the current transaction.
     * Salesforce blocks callouts after DML, email sends, or other uncommitted work.
     */
    public static Boolean hasPriorUncommittedWork() {
        return Limits.getDMLStatements() > 0 || Limits.getDMLRows() > 0 || Limits.getEmailInvocations() > 0;
    }

    /**
     * @description Converts FunctionExecutionResult to AgentExecutionService.ExecutionResult
     * @return ExecutionResult in standard format
     */
    private AgentExecutionService.ExecutionResult convertToExecutionResult(FunctionExecutionResult functionResult) {
        if (functionResult.success) {
            return new AgentExecutionService.ExecutionResult(functionResult.executionId, functionResult.status, functionResult.response);
        }
        return new AgentExecutionService.ExecutionResult(functionResult.errorCode, functionResult.errorMessage);
    }

    /**
     * @description Validates the execution payload
     */
    private void validatePayload(AgentExecutionService.ExecutionPayload payload) {
        if (payload == null) {
            throw new AIAgentException.OrchestrationException('Execution payload is required');
        }

        if (payload.userId == null) {
            throw new AIAgentException.OrchestrationException('User ID is required in execution payload');
        }

        // userMessage can be null for single-shot agents when record context alone is sufficient
    }

    // ===================================================================================
    // RESUME IMPLEMENTATION
    // ===================================================================================

    /**
     * Determines resume point for function executions.
     * Analyzes execution steps to find failed tools or determine LLM continue strategy.
     */
    private ExecutionResumeModels.ResumePoint determineResumePoint(
        Id executionId,
        AgentExecution__c execution,
        ExecutionResumeModels.ResumeOptions options,
        String logPrefix
    ) {
        ExecutionResumeModels.ResumePoint resumePoint = new ExecutionResumeModels.ResumePoint();
        resumePoint.lastTurnCount = AgentRuntimeSupport.getLastTurnCount(executionId);
        // Reset turn count to 1 for fresh cycle budget
        resumePoint.turnCount = 1;

        // Determine resume strategy based on options
        Boolean shouldRetryTool = options?.retryFailedTool;

        if (shouldRetryTool == null) {
            // Auto-detect default strategy respects ErrorRecoveryMode__c:
            // - Fail Fast: RETRY_FAILED_TOOL — human explicitly overrides a hard stop; direct retry is appropriate.
            // - Autonomous: LLM_CONTINUE — the LLM already saw the failure and the circuit breaker fired;
            //   giving it the full conversation history (including correctionGuidance) is more useful than
            //   a blind tool retry that may hit the circuit breaker again immediately.
            if ('Fail Fast'.equals(agentDefinition.ErrorRecoveryMode__c)) {
                Map<String, Object> failedTool = AgentRuntimeSupport.findLastFailedTool(executionId);
                shouldRetryTool = (failedTool != null);
                if (shouldRetryTool) {
                    resumePoint.toolCallId = (String) failedTool.get('toolCallId');
                    resumePoint.toolName = (String) failedTool.get('toolName');
                    System.debug(LoggingLevel.INFO, logPrefix + 'Auto-detected failed tool (Fail Fast mode): ' + resumePoint.toolName);
                }
            } else {
                // Autonomous mode: default to LLM_CONTINUE
                shouldRetryTool = false;
                System.debug(LoggingLevel.INFO, logPrefix + 'Autonomous mode: defaulting to LLM_CONTINUE for informed recovery decision');
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

        System.debug(
            LoggingLevel.INFO,
            logPrefix +
                'Resume strategy: ' +
                resumePoint.resumeType +
                '. Turn count reset to 1 (previous execution had ' +
                resumePoint.lastTurnCount +
                ' turns).'
        );
        return resumePoint;
    }

    /**
     * Executes resume for function executions.
     * Handles both tool retry and LLM continue strategies.
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
            return retryFailedToolForFunction(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
        } else {
            // Update execution with new turn identifier
            AgentExecution__c execUpdate = new AgentExecution__c(Id = executionId, CurrentTurnIdentifier__c = newTurnIdentifier);
            update execUpdate;

            // Log the function resume operation with detailed information
            logFunctionResumeOperation(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
            return continueWithLLMCallForFunction(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
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

    // ===================================================================================
    // RESUME HELPER METHODS
    // ===================================================================================

    /**
     * @description Retries a failed tool execution for single-shot agents.
     */
    private AgentExecutionService.ExecutionResult retryFailedToolForFunction(
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

        if (String.isBlank(toolArguments)) {
            throw new AIAgentException.OrchestrationException('Cannot retry tool: Tool arguments not found for toolCallId: ' + resumePoint.toolCallId);
        }

        // Lookup capability
        AgentCapability__c capability = AIAgentConfigService.getCapability(agentDefinition.Id, resumePoint.toolName);
        if (capability == null) {
            throw new AIAgentException.OrchestrationException('Cannot retry tool: Capability not found for tool: ' + resumePoint.toolName);
        }

        if (capability.ExposureLevel__c == 'Disabled') {
            throw new AIAgentException.OrchestrationException('Cannot retry tool: Capability "' + resumePoint.toolName + '" is disabled.');
        }

        // Generate new tool call ID for retry
        String retryToolCallId = generateRetryToolCallId(resumePoint.toolCallId);

        // Check if tool is async
        if (capability.RunAsynchronously__c == true) {
            // Enqueue async tool execution with proper tracking
            AgentStateService agentStateSvc = new AgentStateService();
            agentStateSvc.pauseForAsyncActionWithTracking(executionId, newTurnIdentifier, 1, capability.CapabilityName__c, logPrefix);

            // Create tool call step with resume tracking
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

            return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Retrying async tool: ' + resumePoint.toolName);
        }

        // Synchronous tool - execute now (before DML)
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
            'FunctionResume'
        );

        CapabilityExecutionService capabilityService = new CapabilityExecutionService();
        Long toolStartTime = System.currentTimeMillis();
        ActionOutcome toolOutcome = capabilityService.executeSingleAction(capability, toolArguments, actionContext);
        Long toolProcessingTime = System.currentTimeMillis() - toolStartTime;

        if (shouldDeferResumePreparation(execution, resumePoint, null)) {
            update new AgentExecution__c(Id = executionId, CurrentTurnIdentifier__c = newTurnIdentifier, AsyncToolTurnIdentifier__c = null);
            logFunctionResumeOperation(executionId, execution, newTurnIdentifier, resumePoint, logPrefix);
        }

        // Check fail-fast policy for resume operations.
        // ErrorRecoveryMode is checked but MaxToolRetries is intentionally skipped —
        // the user explicitly requested this retry via the resume action.
        if (!toolOutcome.isSuccess && shouldFailFastForResume(capability, agentDefinition, toolOutcome, executionId, logPrefix)) {
            // Log the tool result step first so users can see what happened
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(executionId, newTurnIdentifier);

            // Log the tool result and error - pass domain objects
            decisionLogger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ capability, toolOutcome, toolProcessingTime });
            decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ capability, toolOutcome });
            decisionLogger.commitSteps();

            // Also create ExecutionStep records for consistency
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

            stepSvc.createToolResultStep(
                executionId,
                retryToolCallId,
                resumePoint.toolName,
                JSON.serialize(toolOutcome),
                newTurnIdentifier,
                resumePoint.turnCount,
                toolProcessingTime,
                false, // isAsyncToolExecution
                capability.Id,
                true, // isError
                true // isResumed = true
            );

            AgentStateService agentStateSvc = new AgentStateService();
            agentStateSvc.updateStatus(
                executionId,
                'Failed',
                AIAgentConstants.STATUS_FAILED,
                newTurnIdentifier,
                'Tool retry failed (fail-fast): ' + toolOutcome.errorMessage
            );
            String toolErrorCode = String.isBlank(toolOutcome.errorCode) ? AIAgentConstants.ERR_CODE_ACTION_EXECUTION : toolOutcome.errorCode;
            return new AgentExecutionService.ExecutionResult(toolErrorCode, 'Tool retry failed: ' + toolOutcome.errorMessage);
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
            toolProcessingTime,
            false,
            capability.Id,
            !toolOutcome.isSuccess,
            true // isResumed = true
        );

        // Log tool execution result as decision step for timeline visibility
        // IMPORTANT: Commit steps BEFORE checking tool outcome to ensure they persist even if exception is thrown
        try {
            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(executionId, newTurnIdentifier, execution.User__c);
            // Pass domain objects - addon extracts all details
            decisionLogger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ capability, toolOutcome, toolProcessingTime });
            decisionLogger.commitSteps();
            System.debug(LoggingLevel.INFO, logPrefix + 'Logged tool execution result as decision step');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to log tool result decision step: ' + e.getMessage());
        }

        if (!toolOutcome.isSuccess) {
            if ('Fail Fast'.equals(agentDefinition.ErrorRecoveryMode__c)) {
                // Fail Fast mode: halt immediately — consistent with its semantics even on human-initiated retry.
                AgentStateService agentStateSvc = new AgentStateService();
                agentStateSvc.updateStatus(
                    executionId,
                    'Failed',
                    AIAgentConstants.STATUS_FAILED,
                    newTurnIdentifier,
                    'Tool retry failed (Fail Fast): ' + toolOutcome.errorMessage
                );
                String toolErrorCode = String.isBlank(toolOutcome.errorCode) ? AIAgentConstants.ERR_CODE_ACTION_EXECUTION : toolOutcome.errorCode;
                return new AgentExecutionService.ExecutionResult(toolErrorCode, 'Tool retry failed: ' + toolOutcome.errorMessage);
            }

            // Autonomous mode: route the failure to the LLM for a recovery decision.
            // The ActionOutcome.correctionGuidance tells the LLM what to try next.
            System.debug(LoggingLevel.INFO, logPrefix + 'Autonomous mode: tool retry failed, routing error to LLM for recovery decision.');
            if (execution.SourceRecordId__c != null) {
                try {
                    ContextManagerService contextMgr = new ContextManagerService();
                    contextMgr.commitExecutionTurnContext(executionId, resumePoint.turnCount, execution.SourceRecordId__c, null);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit page context: ' + e.getMessage());
                }
            }
            AgentStateService agentStateSvcAutonomous = new AgentStateService();
            agentStateSvcAutonomous.resumeForFollowUpLlmCall(executionId, newTurnIdentifier, null, logPrefix);
            AgentJobEnqueuer autonomousEnqueuer = new AgentJobEnqueuer();
            autonomousEnqueuer.enqueueFollowUp(
                executionId,
                execution.User__c,
                agentDefinition.Id,
                newTurnIdentifier,
                resumePoint.turnCount,
                logPrefix,
                false,
                execution.SourceRecordId__c
            );
            return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Tool retry failed, routing to LLM for recovery');
        }

        // Commit page context before follow-up LLM call
        if (execution.SourceRecordId__c != null) {
            try {
                ContextManagerService contextMgr = new ContextManagerService();
                contextMgr.commitExecutionTurnContext(executionId, resumePoint.turnCount, execution.SourceRecordId__c, null);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit page context: ' + e.getMessage());
            }
        }

        // Continue with follow-up LLM call
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

        return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Tool retry succeeded, continuing with LLM call');
    }

    /**
     * @description Continues function execution with an LLM call.
     */
    private AgentExecutionService.ExecutionResult continueWithLLMCallForFunction(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ExecutionResumeModels.ResumePoint resumePoint,
        String logPrefix
    ) {
        // Create a resume message for the LLM
        String resumeMessage =
            'The previous execution was interrupted or failed. Please review the execution history above and continue from where it left off. ' +
            'If there were any errors, please address them and continue with the task.';

        ExecutionStepService stepSvc = new ExecutionStepService();
        stepSvc.createUserInputStep(executionId, resumeMessage, newTurnIdentifier, resumePoint.turnCount);

        // Commit page context before follow-up LLM call
        if (execution.SourceRecordId__c != null) {
            try {
                ContextManagerService contextMgr = new ContextManagerService();
                contextMgr.commitExecutionTurnContext(executionId, resumePoint.turnCount, execution.SourceRecordId__c, null);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Non-fatal: Failed to commit page context: ' + e.getMessage());
            }
        }

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
     * @description Logs the function resume operation with detailed information and updates resume tracking fields.
     */
    private void logFunctionResumeOperation(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ExecutionResumeModels.ResumePoint resumePoint,
        String logPrefix
    ) {
        try {
            // Query current resume count to ensure we have the latest value
            AgentExecution__c currentExec = [
                SELECT FunctionResumeCount__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            // Update resume tracking fields
            Integer currentResumeCount = (currentExec.FunctionResumeCount__c != null) ? Integer.valueOf(currentExec.FunctionResumeCount__c) : 0;
            Integer newResumeCount = currentResumeCount + 1;

            AgentExecution__c execUpdate = new AgentExecution__c(Id = executionId);
            execUpdate.FunctionResumeCount__c = newResumeCount;
            execUpdate.LastFunctionResumeTimestamp__c = Datetime.now();
            update execUpdate;

            System.debug(LoggingLevel.INFO, logPrefix + 'Updated function resume tracking: Resume #' + newResumeCount);

            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(executionId, newTurnIdentifier, execution.User__c);

            String resumeDetails = 'Resume Type: ' + resumePoint.resumeType;
            if (resumePoint.resumeType == ExecutionResumeModels.ResumeType.RETRY_FAILED_TOOL) {
                resumeDetails += ', Tool: ' + resumePoint.toolName + ', ToolCallId: ' + resumePoint.toolCallId;
            }
            resumeDetails += ', Turn: ' + resumePoint.turnCount + ', Resume #' + newResumeCount;

            // Pass resume context - addon decides title/description
            decisionLogger.log(IDecisionStepLogger.EventType.AGENT_RESUMED, new List<Object>{ 'function', resumeDetails });
            decisionLogger.commitSteps();
            System.debug(LoggingLevel.INFO, logPrefix + 'Logged function resume operation');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Non-critical: Failed to log resume operation: ' + e.getMessage());
        }
    }

    /**
     * Generates a new tool call ID for retry operations following OpenAI's format.
     * OpenAI format: call_ + 24 random characters (total 29 characters)
     * Ensures the retry ID stays within OpenAI's 40-character limit.
     */
    private String generateRetryToolCallId(String originalToolCallId) {
        // Generate a completely new OpenAI-format tool call ID for the retry
        // This maintains consistency with OpenAI's expected format
        return generateOpenAIToolCallId();
    }

    /**
     * Generates a new tool call ID following OpenAI's format.
     * Format: call_ + 24 random alphanumeric characters
     */
    private String generateOpenAIToolCallId() {
        // OpenAI uses base62 characters: a-z, A-Z, 0-9
        String chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';

        String randomPart = '';
        for (Integer i = 0; i < 24; i++) {
            Integer randomIndex = Math.mod(Math.abs(Crypto.getRandomInteger()), chars.length());
            randomPart += chars.substring(randomIndex, randomIndex + 1);
        }

        return 'call_' + randomPart;
    }

    /**
     * @description Checks if we should fail fast for resume operations.
     * Only applies the agent-level ErrorRecoveryMode check. The MaxToolRetries circuit breaker
     * is intentionally skipped because the user explicitly requested a retry via resume.
     */
    private Boolean shouldFailFastForResume(
        AgentCapability__c capability,
        AIAgentDefinition__c agentDef,
        ActionOutcome toolOutcome,
        Id executionId,
        String logPrefix
    ) {
        if ('Fail Fast'.equals(agentDef.ErrorRecoveryMode__c)) {
            System.debug(LoggingLevel.WARN, logPrefix + 'FAIL FAST mode: halting resume tool execution for "' + capability.CapabilityName__c + '"');
            return true;
        }

        return false;
    }
    /**
     * @description
     * Function agents preserve the existing turn identifier during resume operations.
     * This maintains continuity with the original execution context.
     * @param execution The execution record containing the current turn identifier
     * @param options Resume options (not used for Function agents)
     * @return String The existing turn identifier from the execution
     */
    private String generateResumeIdentifier(AgentExecution__c execution, ExecutionResumeModels.ResumeOptions options) {
        String existingTurnIdentifier = execution.CurrentTurnIdentifier__c;

        if (String.isNotBlank(existingTurnIdentifier)) {
            System.debug(LoggingLevel.INFO, '[SingleShotRuntimeService] Preserving existing turn identifier for resume: ' + existingTurnIdentifier);
            return existingTurnIdentifier;
        } else {
            // Fallback: generate new identifier if none exists (shouldn't happen in normal flow)
            String newIdentifier = AgentRuntimeSupport.generateTurnIdentifier();
            System.debug(LoggingLevel.WARN, '[SingleShotRuntimeService] No existing turn identifier found, generating new one: ' + newIdentifier);
            return newIdentifier;
        }
    }
    /**
     * @description
     * Override the base class resume attempt logging to prevent duplicate "Execution Resumed" steps.
     * Function agents use logFunctionResumeOperation() instead for more detailed logging.
     */
    private void logResumeAttempt(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        ExecutionResumeModels.ResumePoint resumePoint,
        ExecutionResumeModels.ResumeOptions options,
        String logPrefix
    ) {
        // No-op: Function agents use logFunctionResumeOperation() for resume logging
        // This prevents the generic "Execution Resumed" step from being created
        System.debug(LoggingLevel.DEBUG, logPrefix + 'Skipping base resume attempt logging - using Function-specific logging instead');
    }

    // ===================================================================================
    // LLM CUSTOMIZATION HOOKS (override from BaseAgentOrchestrator)
    // ===================================================================================

    /**
     * Function agents don't add system prompt additions - they use default behavior.
     * @param context The orchestration context for the current turn
     * @return Empty string (no additions)
     */
    public String buildSystemPromptAdditions(OrchestrationContext context) {
        return '';
    }

    /**
     * Single-shot agents do not have special tool outcome evaluation.
     * Use the default strategy behavior.
     *
     * @param context The orchestration context
     * @param toolResults Results from tool execution(s)
     * @param scenario The scenario type
     * @return null to use default behavior
     */
    public String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario) {
        return AgentRuntimeSupport.evaluateToolOutcome(context, toolResults, scenario);
    }
}
