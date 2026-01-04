/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * UnifiedAgentQueueable consolidates all async agent execution patterns into a single,
 * strategy-based queueable implementation. Replaces FunctionQueueable, WorkflowChildQueueable,
 * and ConversationalQueueable to eliminate code duplication.
 *
 * **Supported Job Types:**
 * - Function: Executes deferred function agents (when DML has occurred before invocation)
 * - WorkflowChild: Executes child agents within workflow orchestration
 * - Conversational: Executes conversational agent LLM processing
 *
 * **Architecture Pattern:**
 * - Strategy Pattern: Job type determines execution strategy
 * - Clean Transaction: All executions start with no prior DML (allows LLM callouts)
 * - Standardized Error Handling: Consistent error logging across all job types
 *
 * **Benefits:**
 * - Single source of truth for async agent execution
 * - Eliminates ~300 lines of duplicate code
 * - Easier to add new async execution patterns
 * - Centralized queueable job management
 *
 * @example Function Job
 * Map<String, Object> payload = new Map<String, Object>{
 *     'agentDeveloperName' => 'Case_Summarizer',
 *     'input' => 'Summarize this case',
 *     'recordId' => caseId,
 *     'userId' => userId,
 *     'turnIdentifier' => turnId
 * };
 * System.enqueueJob(new UnifiedAgentQueueable('Function', payload));
 *
 * @example WorkflowChild Job
 * Map<String, Object> payload = new Map<String, Object>{
 *     'childExecutionId' => childExecId,
 *     'parentExecutionId' => parentExecId,
 *     'agentType' => 'enrichment',
 *     'agentDefinitionId' => enrichmentAgentId,
 *     'sourceRecordId' => caseId,
 *     'userId' => userId,
 *     'userMessage' => 'Enrich case data',
 *     'turnIdentifier' => turnId
 * };
 * System.enqueueJob(new UnifiedAgentQueueable('WorkflowChild', payload));
 *
 * @example Conversational Job
 * Map<String, Object> payload = new Map<String, Object>{
 *     'executionId' => execId,
 *     'originalUserId' => userId,
 *     'executionUserId' => userId,
 *     'agentDefinitionId' => agentDefId,
 *     'llmConfigurationId' => llmConfigId,
 *     'turnIdentifier' => turnId,
 *     'currentRecordId' => recordId,
 *     'userMessage' => 'Hello, I need help'
 * };
 * System.enqueueJob(new UnifiedAgentQueueable('Conversational', payload));
 *
 * @author Sonal
 * @since 2025
 */
public class UnifiedAgentQueueable implements Queueable, Database.AllowsCallouts {
    private final String jobType;
    private final Map<String, Object> payload;

    // Job type constants
    public static final String JOB_TYPE_FUNCTION = 'Function';
    public static final String JOB_TYPE_WORKFLOW_CHILD = 'WorkflowChild';
    public static final String JOB_TYPE_CONVERSATIONAL = 'Conversational';

    /**
     * @description Constructor for UnifiedAgentQueueable
     * @param jobType The type of job to execute (Function, WorkflowChild, or Conversational)
     * @param payload Map containing job-specific execution parameters
     * @throws UnifiedQueueableException if jobType or payload is invalid
     */
    public UnifiedAgentQueueable(String jobType, Map<String, Object> payload) {
        if (String.isBlank(jobType)) {
            throw new UnifiedQueueableException('Job type is required for UnifiedAgentQueueable');
        }

        if (payload == null) {
            throw new UnifiedQueueableException('Payload is required for UnifiedAgentQueueable');
        }

        // Validate job type
        Set<String> validJobTypes = new Set<String>{ JOB_TYPE_FUNCTION, JOB_TYPE_WORKFLOW_CHILD, JOB_TYPE_CONVERSATIONAL };
        if (!validJobTypes.contains(jobType)) {
            throw new UnifiedQueueableException('Invalid job type: ' + jobType + '. Must be one of: ' + String.join(new List<String>(validJobTypes), ', '));
        }

        this.jobType = jobType;
        this.payload = payload;
    }

    /**
     * @description Main execution method invoked by the Queueable framework
     * Delegates to appropriate strategy based on job type
     * @param context The QueueableContext provided by Salesforce
     */
    public void execute(QueueableContext context) {
        String logPrefix = '[UnifiedQueueable JobId:' + context.getJobId() + ' Type:' + jobType + '] ';
        Long startTime = System.currentTimeMillis();

        System.debug(LoggingLevel.INFO, logPrefix + 'Starting execution');

        try {
            // Delegate to appropriate strategy
            if (jobType == JOB_TYPE_FUNCTION) {
                executeFunctionJob(logPrefix, startTime);
            } else if (jobType == JOB_TYPE_WORKFLOW_CHILD) {
                executeWorkflowChildJob(logPrefix, startTime);
            } else if (jobType == JOB_TYPE_CONVERSATIONAL) {
                executeConversationalJob(logPrefix, startTime);
            } else {
                throw new UnifiedQueueableException('Unsupported job type: ' + jobType);
            }

            Long duration = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, logPrefix + 'Completed successfully in ' + duration + 'ms');
        } catch (Exception e) {
            Long duration = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed after ' + duration + 'ms: ' + e.getMessage() + '\n' + e.getStackTraceString());
            // Error logging is handled by individual strategies
        }
    }

    /**
     * @description Executes a Function agent in deferred mode
     * Used when DML has occurred before function agent invocation
     *
     * Required payload fields:
     * - agentDeveloperName (String): Developer name of the function agent
     * - input (String): User input/prompt
     * - recordId (Id): Context record ID (optional)
     * - userId (Id): User ID (optional, defaults to current user)
     * - turnIdentifier (String): Turn identifier (optional, auto-generated if null)
     *
     * @param logPrefix Logging prefix for debug output
     * @param startTime Start time for duration calculation
     */
    private void executeFunctionJob(String logPrefix, Long startTime) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing Function job');

        // Extract and validate payload fields
        String agentDeveloperName = getRequiredString('agentDeveloperName', logPrefix);
        String input = (String) payload.get('input');
        Id recordId = (Id) payload.get('recordId');
        Id userId = (Id) payload.get('userId');
        String turnIdentifier = (String) payload.get('turnIdentifier');

        // Default userId to current user if not provided
        if (userId == null) {
            userId = UserInfo.getUserId();
        }

        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Executing agent: ' + agentDeveloperName + ' via AgentExecutionService');

            // Use AgentExecutionService to execute the agent
            // This leverages the metadata-driven orchestrator loading without compile-time dependencies
            AgentExecutionService.ExecutionPayload execPayload = new AgentExecutionService.ExecutionPayload();
            execPayload.userId = userId;
            execPayload.userMessage = input;
            execPayload.sourceRecordId = recordId;
            execPayload.currentRecordId = recordId;
            execPayload.turnIdentifier = turnIdentifier;
            execPayload.triggerSource = 'Apex'; // Valid picklist value (deferred execution from queueable)

            // Execute through service (which handles dynamic orchestrator loading)
            AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(agentDeveloperName, execPayload);

            System.debug(LoggingLevel.INFO, logPrefix + 'Function agent execution completed. Success: ' + result.success + ', Status: ' + result.status);

            // For async executions (iterative pattern), the execution continues via queueables
            // For sync executions (tool-terminating pattern), we're done
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Function agent execution failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            // Error is logged, but we can't return it to original caller
            // User would need to check execution record or use polling
        }
    }

    /**
     * @description Executes a child agent within a workflow
     * Each child agent runs in its own isolated transaction with dedicated governor limits
     *
     * Required payload fields:
     * - childExecutionId (Id): Child execution record ID
     * - parentExecutionId (Id): Parent workflow execution ID
     * - agentType (String): Name of the child agent
     * - agentDefinitionId (Id): Child agent definition ID
     * - userId (Id): User ID
     * - turnIdentifier (String): Turn identifier
     * Optional payload fields:
     * - sourceRecordId (Id): Source record context
     * - userMessage (String): Message to pass to child agent
     *
     * @param logPrefix Logging prefix for debug output
     * @param startTime Start time for duration calculation
     */
    private void executeWorkflowChildJob(String logPrefix, Long startTime) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing WorkflowChild job');

        // Extract and validate required payload fields
        Id childExecutionId = getRequiredId('childExecutionId', logPrefix);
        Id parentExecutionId = getRequiredId('parentExecutionId', logPrefix);
        String agentType = getRequiredString('agentType', logPrefix);
        Id agentDefinitionId = getRequiredId('agentDefinitionId', logPrefix);
        Id userId = getRequiredId('userId', logPrefix);
        String turnIdentifier = getRequiredString('turnIdentifier', logPrefix);

        // Extract optional fields
        Id sourceRecordId = (Id) payload.get('sourceRecordId');
        String userMessage = (String) payload.get('userMessage');

        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Executing child agent: ' + agentType + ', ChildExec: ' + childExecutionId + ', Parent: ' + parentExecutionId
        );

        Boolean success = false;
        String response = '';
        String errorCode = null;
        String errorMessage = null;

        try {
            // Load agent definition
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefinitionId);

            if (agentDef == null) {
                throw new UnifiedQueueableException('Agent definition not found: ' + agentDefinitionId);
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Loaded agent: ' + agentDef.DeveloperName__c);

            // Execute child agent via AgentExecutionService
            // This uses metadata-driven orchestrator loading without compile-time dependencies
            AgentExecutionService.ExecutionPayload execPayload = new AgentExecutionService.ExecutionPayload();
            execPayload.userId = userId;
            execPayload.userMessage = userMessage;
            execPayload.sourceRecordId = sourceRecordId;
            execPayload.currentRecordId = sourceRecordId;
            execPayload.turnIdentifier = turnIdentifier;
            execPayload.existingExecutionId = childExecutionId; // Reuse existing execution record created by WorkflowOrchestrator
            execPayload.triggerSource = 'Workflow';

            // Execute through service
            AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution(agentDef.DeveloperName__c, execPayload);

            // Map result fields
            success = result.success;
            response = result.message != null ? result.message : '';

            // For error scenarios
            if (!result.success) {
                errorCode = AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;
                errorMessage = result.errorMessage;
            }

            Long executionTime = System.currentTimeMillis() - startTime;
            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Child agent execution completed in ' + executionTime + 'ms. Success: ' + success + ', Status: ' + result.status
            );

            // Check if execution requires async polling (multi-tool iterative pattern)
            // Status 'Processing' indicates async execution
            if (result.status == 'Processing') {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Child agent execution is async (Processing status). ' + 'Will wait for completion via WorkflowAsyncCompletionCallback.'
                );
                // Don't notify parent yet - the child execution is still running
                // The completion will be handled by a platform event or callback mechanism
                return;
            }

            // Update child execution record with result (for synchronous/completed execution)
            // The AgentExecutionTrigger will detect this status change and notify the parent workflow
            updateChildExecution(childExecutionId, success, logPrefix, errorMessage);

            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    'Child execution updated to ' +
                    (success ? 'Completed' : 'Failed') +
                    '. AgentExecutionTrigger will notify parent workflow: ' +
                    parentExecutionId
            );
        } catch (Exception e) {
            success = false;
            errorCode = AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;
            errorMessage = e.getMessage();
            response = 'Child agent execution failed: ' + e.getMessage();

            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during child agent execution: ' + e.getMessage() + '\n' + e.getStackTraceString());

            // Update child execution as failed
            // The AgentExecutionTrigger will detect this and notify the parent workflow
            try {
                AgentExecution__c childExec = new AgentExecution__c(
                    Id = childExecutionId,
                    ExecutionStatus__c = 'Failed',
                    ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                    EndTime__c = Datetime.now(),
                    ErrorMessage__c = errorMessage?.abbreviate(255)
                );
                update childExec;

                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Child execution updated to Failed. ' + 'AgentExecutionTrigger will notify parent workflow: ' + parentExecutionId
                );
            } catch (Exception updateEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update child execution: ' + updateEx.getMessage());
            }
        }

        // Note: Parent workflow notification now handled exclusively by AgentExecutionTrigger
        // This prevents the "Too many queueable jobs" error caused by double-enqueuing
        // (once from direct callback, once from trigger)
    }

    /**
     * @description Executes LLM processing for conversational agents
     * Handles async LLM calls and orchestration for chat-based interactions
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
     *
     * @param logPrefix Logging prefix for debug output
     * @param startTime Start time for duration calculation
     */
    private void executeConversationalJob(String logPrefix, Long startTime) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing Conversational job');

        // Extract and validate required payload fields
        Id executionId = getRequiredId('executionId', logPrefix);
        Id originalUserId = getRequiredId('originalUserId', logPrefix);
        Id executionUserId = getRequiredId('executionUserId', logPrefix);
        Id agentDefinitionId = getRequiredId('agentDefinitionId', logPrefix);
        Id llmConfigurationId = getRequiredId('llmConfigurationId', logPrefix);
        String turnIdentifier = getRequiredString('turnIdentifier', logPrefix);
        String userMessage = getRequiredString('userMessage', logPrefix);

        // Extract optional fields
        Id currentRecordId = (Id) payload.get('currentRecordId');

        System.debug(LoggingLevel.INFO, logPrefix + 'Starting LLM processing for turn: ' + turnIdentifier + ', Exec: ' + executionId);

        try {
            // Initialize decision logger
            AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(executionId, turnIdentifier, originalUserId);

            // Log user input
            decisionLogger.logUserInput('User Input Received', userMessage, null);

            // Prepare user message data
            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = userMessage;

            // Instantiate LLM interaction service
            LLMInteractionService interactionService = new LLMInteractionService(
                executionId,
                originalUserId,
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                1,
                currentRecordId,
                false,
                decisionLogger
            );

            // Execute LLM interaction
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(currentUserMessageData);

            if (llmResult == null) {
                throw new UnifiedQueueableException('LLMInteractionService returned a null result');
            }

            // Process LLM result using orchestration service
            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                executionId,
                originalUserId,
                executionUserId,
                agentDefinitionId,
                turnIdentifier,
                1,
                currentUserMessageData,
                currentRecordId,
                decisionLogger
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'LLM processing completed successfully. Outcome: ' + outcome);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'ERROR: LLM processing failed. Exception: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString());

            // Mark turn as failed
            try {
                AgentStateService ass = new AgentStateService();
                ass.failTurn(executionId, turnIdentifier, 'LLM processing failed: ' + e.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            } catch (Exception failEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'CRITICAL: Failed to update execution state after processing failure: ' + failEx.getMessage());
            }
        }
    }

    /**
     * @description Updates the child execution record with the result
     * @param childExecutionId The ID of the child execution to update
     * @param success Whether the execution was successful
     * @param logPrefix Logging prefix for debug output
     * @param errorMessage Optional error message if execution failed
     */
    private void updateChildExecution(Id childExecutionId, Boolean success, String logPrefix, String errorMessage) {
        try {
            AgentExecution__c childExec = new AgentExecution__c(
                Id = childExecutionId,
                ExecutionStatus__c = success ? 'Completed' : 'Failed',
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                EndTime__c = Datetime.now()
            );

            // Set error message if execution failed
            if (!success && String.isNotBlank(errorMessage)) {
                childExec.ErrorMessage__c = errorMessage.abbreviate(255);
            }

            update childExec;

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Updated child execution: ' + childExecutionId + ', Status: ' + childExec.ExecutionStatus__c);
        } catch (DMLException de) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update child execution: ' + de.getMessage());
        }
    }

    /**
     * @description Helper method to extract required String field from payload
     * @param fieldName The field name to extract
     * @param logPrefix Logging prefix for error messages
     * @return String The extracted value
     * @throws UnifiedQueueableException if field is missing or null
     */
    private String getRequiredString(String fieldName, String logPrefix) {
        if (!payload.containsKey(fieldName) || payload.get(fieldName) == null) {
            String errorMsg = 'Required field missing from payload: ' + fieldName;
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
            throw new UnifiedQueueableException(errorMsg);
        }
        return (String) payload.get(fieldName);
    }

    /**
     * @description Helper method to extract required Id field from payload
     * @param fieldName The field name to extract
     * @param logPrefix Logging prefix for error messages
     * @return Id The extracted value
     * @throws UnifiedQueueableException if field is missing or null
     */
    private Id getRequiredId(String fieldName, String logPrefix) {
        if (!payload.containsKey(fieldName) || payload.get(fieldName) == null) {
            String errorMsg = 'Required field missing from payload: ' + fieldName;
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
            throw new UnifiedQueueableException(errorMsg);
        }
        return (Id) payload.get(fieldName);
    }

    /**
     * @description Exception thrown by UnifiedAgentQueueable
     */
    public class UnifiedQueueableException extends Exception {
    }
}
