/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ExecutionStepService manages ExecutionStep__c records in the unified agentic framework.
 * Replaces ChatMessageService to support all execution types and step patterns.
 *
 * Responsibilities:
 *   - Create and manage ExecutionStep__c records for all execution patterns
 *   - Support different step types: UserInput, AgentResponse, ToolCall, ToolResult, SystemEvent, Error
 *   - Provide step retrieval and filtering for different execution contexts
 *   - Handle step metadata and performance tracking
 *   - Support both conversational and non-conversational step patterns
 *
 * This service abstracts step management from the specific execution type,
 * enabling consistent step tracking across all agent execution patterns.
 */
public inherited sharing class ExecutionStepService {
    // --- CONSTANTS ---
    private static final String LOG_PREFIX = '[ExecutionStepService] ';

    // --- EXCEPTIONS ---
    public class ExecutionStepException extends AIAgentException {
    }

    /**
     * Creates a new ExecutionStep__c record.
     *
     * @param executionId The parent AgentExecution__c ID
     * @param stepType The type of step (UserInput, AgentResponse, ToolCall, etc.)
     * @param stepRole The role performing this step (User, Assistant, Tool, System)
     * @param content The main content of the step
     * @param contentType The format of the content (Text, JSON, HTML, etc.)
     * @param turnIdentifier The turn identifier for this step
     * @param turnCount The turn number within the execution
     * @return Id of the created ExecutionStep__c record
     */
    public Id createStep(Id executionId, String stepType, String stepRole, String content, String contentType, String turnIdentifier, Integer turnCount) {
        return createStep(
            executionId,
            stepType,
            stepRole,
            content,
            contentType,
            turnIdentifier,
            turnCount,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            false,
            null,
            null // capabilityId
        );
    }

    /**
     * Creates a new ExecutionStep__c record with full parameters.
     *
     * @param executionId The parent AgentExecution__c ID
     * @param stepType The type of step
     * @param stepRole The role performing this step
     * @param content The main content of the step
     * @param contentType The format of the content
     * @param turnIdentifier The turn identifier for this step
     * @param turnCount The turn number within the execution
     * @param toolCallId Optional tool call ID for correlation
     * @param toolName Optional tool name
     * @param toolArguments Optional tool arguments JSON
     * @param toolResult Optional tool result JSON
     * @param stepMetadata Optional step metadata JSON
     * @param promptTokens Optional prompt tokens count for LLM calls
     * @param completionTokens Optional completion tokens count for LLM calls
     * @param totalTokens Optional total tokens count for LLM calls
     * @param modelIdentifier Optional LLM model identifier (e.g., gpt-4o-mini)
     * @param llmCalloutDurationMs Optional LLM API callout duration in milliseconds
     * @param isInternal Whether this is an internal system step
     * @param isAsyncToolExecution Optional flag indicating if this is an async tool execution (applicable to ToolResult steps)
     * @return Id of the created ExecutionStep__c record
     */
    public Id createStep(
        Id executionId,
        String stepType,
        String stepRole,
        String content,
        String contentType,
        String turnIdentifier,
        Integer turnCount,
        String toolCallId,
        String toolName,
        String toolArguments,
        String toolResult,
        String stepMetadata,
        Integer promptTokens,
        Integer completionTokens,
        Integer totalTokens,
        String modelIdentifier,
        Long llmCalloutDurationMs,
        Boolean isInternal,
        Boolean isAsyncToolExecution,
        Id capabilityId
    ) {
        String logPrefix = LOG_PREFIX + '[createStep] ';

        try {
            // Calculate estimated cost if we have token and model information
            Decimal estimatedCost = calculateCost(modelIdentifier, promptTokens, completionTokens);

            ExecutionStep__c step = new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = stepType,
                StepRole__c = stepRole,
                Content__c = content,
                ContentType__c = contentType != null ? contentType : 'Text',
                Timestamp__c = Datetime.now(),
                TurnIdentifier__c = turnIdentifier,
                TurnCount__c = turnCount,
                ToolCallId__c = toolCallId,
                ToolName__c = toolName,
                ToolArguments__c = toolArguments,
                ToolResult__c = toolResult,
                StepMetadata__c = stepMetadata,
                PromptTokens__c = promptTokens,
                CompletionTokens__c = completionTokens,
                TotalTokens__c = totalTokens,
                ModelIdentifier__c = modelIdentifier,
                LLMCalloutDurationMs__c = llmCalloutDurationMs,
                EstimatedCostUSD__c = estimatedCost,
                IsInternal__c = isInternal != null ? isInternal : false,
                IsAsyncToolExecution__c = isAsyncToolExecution != null ? isAsyncToolExecution : false,
                AIAgentCapability__c = capabilityId
            );

            insert step;

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Created ExecutionStep__c: ' + step.Id + ' Type: ' + stepType + ' Role: ' + stepRole);
            if (totalTokens != null) {
                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix +
                        'Token usage - Prompt: ' +
                        promptTokens +
                        ', Completion: ' +
                        completionTokens +
                        ', Total: ' +
                        totalTokens +
                        ', Model: ' +
                        modelIdentifier
                );
            }

            return step.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create step: ' + e.getMessage());
            throw new ExecutionStepException('Failed to create execution step: ' + e.getMessage());
        }
    }

    /**
     * Creates a user input step.
     *
     * @param executionId The execution ID
     * @param userMessage The user's message content
     * @param turnIdentifier The turn identifier
     * @param turnCount The turn number
     * @return Id of the created step
     */
    public Id createUserInputStep(Id executionId, String userMessage, String turnIdentifier, Integer turnCount) {
        return createStep(executionId, 'UserInput', 'User', userMessage, 'Text', turnIdentifier, turnCount);
    }

    /**
     * Creates an agent response step.
     *
     * @param executionId The execution ID
     * @param agentResponse The agent's response content
     * @param turnIdentifier The turn identifier
     * @param turnCount The turn number
     * @return Id of the created step
     */
    public Id createAgentResponseStep(Id executionId, String agentResponse, String turnIdentifier, Integer turnCount) {
        return createStep(executionId, 'AgentResponse', 'Assistant', agentResponse, 'Text', turnIdentifier, turnCount);
    }

    /**
     * Creates an agent response step with token usage data and LLM metrics.
     *
     * @param executionId The execution ID
     * @param agentResponse The agent's response content
     * @param turnIdentifier The turn identifier
     * @param turnCount The turn number
     * @param promptTokens Number of tokens in the prompt
     * @param completionTokens Number of tokens in the completion
     * @param totalTokens Total tokens used
     * @param modelIdentifier LLM model identifier (e.g., gpt-4o-mini)
     * @param llmCalloutDurationMs LLM API callout duration in milliseconds
     * @return Id of the created step
     */
    public Id createAgentResponseStepWithTokens(
        Id executionId,
        String agentResponse,
        String turnIdentifier,
        Integer turnCount,
        Integer promptTokens,
        Integer completionTokens,
        Integer totalTokens,
        String modelIdentifier,
        Long llmCalloutDurationMs
    ) {
        return createStep(
            executionId,
            'AgentResponse',
            'Assistant',
            agentResponse,
            'Text',
            turnIdentifier,
            turnCount,
            null, // toolCallId
            null, // toolName
            null, // toolArguments
            null, // toolResult
            null, // stepMetadata
            promptTokens,
            completionTokens,
            totalTokens,
            modelIdentifier,
            llmCalloutDurationMs,
            false, // isInternal
            null, // isAsyncToolExecution
            null // capabilityId
        );
    }

    /**
     * Creates a tool call step.
     *
     * @param executionId The execution ID
     * @param toolCallId The tool call identifier
     * @param toolName The name of the tool being called
     * @param toolArguments The arguments passed to the tool
     * @param turnIdentifier The turn identifier
     * @param turnCount The turn number
     * @param promptTokens Optional prompt tokens count for the LLM call that generated this tool call
     * @param completionTokens Optional completion tokens count for the LLM call that generated this tool call
     * @param totalTokens Optional total tokens count for the LLM call that generated this tool call
     * @param modelIdentifier Optional LLM model identifier (e.g., gpt-4o-mini)
     * @param llmCalloutDurationMs Optional LLM API callout duration in milliseconds
     * @return Id of the created step
     */
    public Id createToolCallStep(
        Id executionId,
        String toolCallId,
        String toolName,
        String toolArguments,
        String turnIdentifier,
        Integer turnCount,
        Integer promptTokens,
        Integer completionTokens,
        Integer totalTokens,
        String modelIdentifier,
        Long llmCalloutDurationMs,
        Id capabilityId
    ) {
        return createToolCallStep(
            executionId,
            toolCallId,
            toolName,
            toolArguments,
            turnIdentifier,
            turnCount,
            promptTokens,
            completionTokens,
            totalTokens,
            modelIdentifier,
            llmCalloutDurationMs,
            capabilityId,
            null // toolRationale
        );
    }

    /**
     * Creates a tool call step with rationale support.
     *
     * @param executionId The execution ID
     * @param toolCallId The tool call identifier
     * @param toolName The name of the tool being called
     * @param toolArguments The arguments passed to the tool
     * @param turnIdentifier The turn identifier
     * @param turnCount The turn number
     * @param promptTokens Optional prompt tokens count for the LLM call that generated this tool call
     * @param completionTokens Optional completion tokens count for the LLM call that generated this tool call
     * @param totalTokens Optional total tokens count for the LLM call that generated this tool call
     * @param modelIdentifier Optional LLM model identifier (e.g., gpt-4o-mini)
     * @param llmCalloutDurationMs Optional LLM API callout duration in milliseconds
     * @param capabilityId The capability ID
     * @param toolRationale Optional LLM-provided reasoning for selecting this tool
     * @return Id of the created step
     */
    public Id createToolCallStep(
        Id executionId,
        String toolCallId,
        String toolName,
        String toolArguments,
        String turnIdentifier,
        Integer turnCount,
        Integer promptTokens,
        Integer completionTokens,
        Integer totalTokens,
        String modelIdentifier,
        Long llmCalloutDurationMs,
        Id capabilityId,
        String toolRationale
    ) {
        String logPrefix = LOG_PREFIX + '[createToolCallStep] ';

        try {
            // Calculate estimated cost if we have token and model information
            Decimal estimatedCost = calculateCost(modelIdentifier, promptTokens, completionTokens);

            ExecutionStep__c step = new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'ToolCall',
                StepRole__c = 'Assistant',
                Content__c = null,
                ContentType__c = 'JSON',
                Timestamp__c = Datetime.now(),
                TurnIdentifier__c = turnIdentifier,
                TurnCount__c = turnCount,
                ToolCallId__c = toolCallId,
                ToolName__c = toolName,
                ToolArguments__c = toolArguments,
                ToolResult__c = null,
                StepMetadata__c = null,
                PromptTokens__c = promptTokens,
                CompletionTokens__c = completionTokens,
                TotalTokens__c = totalTokens,
                ModelIdentifier__c = modelIdentifier,
                LLMCalloutDurationMs__c = llmCalloutDurationMs,
                EstimatedCostUSD__c = estimatedCost,
                IsInternal__c = false,
                IsAsyncToolExecution__c = false,
                AIAgentCapability__c = capabilityId,
                ToolRationale__c = toolRationale
            );

            insert step;

            System.debug(
                LoggingLevel.DEBUG,
                logPrefix + 'Created ToolCall ExecutionStep__c: ' + step.Id + ' Tool: ' + toolName + ' HasRationale: ' + String.isNotBlank(toolRationale)
            );

            return step.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create tool call step: ' + e.getMessage());
            throw new ExecutionStepException('Failed to create tool call step: ' + e.getMessage());
        }
    }

    /**
     * Creates a tool result step (overload without isError for backward compatibility).
     *
     * @param executionId The execution ID
     * @param toolCallId The tool call identifier for correlation
     * @param toolName The name of the tool
     * @param toolResult The result from the tool execution
     * @param turnIdentifier The turn identifier
     * @param turnCount The turn number
     * @param processingDuration Optional processing duration in milliseconds
     * @param isAsyncToolExecution Whether this tool was executed asynchronously
     * @param capabilityId The capability ID
     * @return Id of the created step
     * @throws ExecutionStepException if step creation fails
     */
    public Id createToolResultStep(
        Id executionId,
        String toolCallId,
        String toolName,
        String toolResult,
        String turnIdentifier,
        Integer turnCount,
        Long processingDuration,
        Boolean isAsyncToolExecution,
        Id capabilityId
    ) {
        return createToolResultStep(executionId, toolCallId, toolName, toolResult, turnIdentifier, turnCount, processingDuration, isAsyncToolExecution, capabilityId, false);
    }

    /**
     * Creates a tool result step.
     *
     * @param executionId The execution ID
     * @param toolCallId The tool call identifier for correlation
     * @param toolName The name of the tool
     * @param toolResult The result from the tool execution
     * @param turnIdentifier The turn identifier
     * @param turnCount The turn number
     * @param processingDuration Optional processing duration in milliseconds
     * @param isAsyncToolExecution Whether this tool was executed asynchronously
     * @param capabilityId The capability ID
     * @param isError Whether the tool execution had an error (optional, defaults to false)
     * @return Id of the created step
     * @throws ExecutionStepException if step creation fails
     */
    public Id createToolResultStep(
        Id executionId,
        String toolCallId,
        String toolName,
        String toolResult,
        String turnIdentifier,
        Integer turnCount,
        Long processingDuration,
        Boolean isAsyncToolExecution,
        Id capabilityId,
        Boolean isError
    ) {
        String logPrefix = LOG_PREFIX + '[createToolResultStep] ';

        try {
            Map<String, Object> metadata = new Map<String, Object>();
            if (processingDuration != null) {
                metadata.put('processingDuration', processingDuration);
            }
            if (isAsyncToolExecution != null) {
                metadata.put('isAsyncToolExecution', isAsyncToolExecution);
            }

            ExecutionStep__c step = new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                Content__c = null,
                ContentType__c = 'JSON',
                Timestamp__c = Datetime.now(),
                TurnIdentifier__c = turnIdentifier,
                TurnCount__c = turnCount,
                ToolCallId__c = toolCallId,
                ToolName__c = toolName,
                ToolResult__c = toolResult,
                HasResult__c = String.isNotBlank(toolResult),
                IsError__c = isError != null ? isError : false,
                ProcessingDuration__c = processingDuration,
                IsAsyncToolExecution__c = isAsyncToolExecution != null ? isAsyncToolExecution : false,
                StepMetadata__c = !metadata.isEmpty() ? JSON.serialize(metadata) : null,
                PromptTokens__c = null,
                CompletionTokens__c = null,
                TotalTokens__c = null,
                ModelIdentifier__c = null,
                LLMCalloutDurationMs__c = null,
                AIAgentCapability__c = capabilityId
            );

            insert step;

            System.debug(
                LoggingLevel.DEBUG,
                logPrefix + 'Created tool result step: ' + step.Id + ' for tool: ' + toolName + ' (async=' + isAsyncToolExecution + ', isError=' + step.IsError__c + ')'
            );

            return step.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create tool result step: ' + e.getMessage());
            throw new ExecutionStepException('Failed to create tool result step: ' + e.getMessage());
        }
    }

    /**
     * Updates an existing tool result step with new result data (overload without isError for backward compatibility).
     * Used when a pending HITL action is resolved and the actual tool result needs to replace
     * the "pending_approval" placeholder.
     *
     * @param executionId The execution ID
     * @param toolCallId The tool call ID to find the existing step
     * @param toolResult The new result from the tool execution
     * @param processingDuration Optional processing duration in milliseconds
     * @return Id of the updated step, or null if not found
     */
    public Id updateToolResultStep(Id executionId, String toolCallId, String toolResult, Long processingDuration) {
        return updateToolResultStep(executionId, toolCallId, toolResult, processingDuration, false);
    }

    /**
     * Updates an existing tool result step with new result data.
     * Used when a pending HITL action is resolved and the actual tool result needs to replace
     * the "pending_approval" placeholder.
     *
     * @param executionId The execution ID
     * @param toolCallId The tool call ID to find the existing step
     * @param toolResult The new result from the tool execution
     * @param processingDuration Optional processing duration in milliseconds
     * @param isError Whether the tool execution had an error (optional, defaults to false)
     * @return Id of the updated step, or null if not found
     */
    public Id updateToolResultStep(Id executionId, String toolCallId, String toolResult, Long processingDuration, Boolean isError) {
        String logPrefix = LOG_PREFIX + '[updateToolResultStep] ';

        try {
            List<ExecutionStep__c> existingSteps = [
                SELECT Id, StepMetadata__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId AND ToolCallId__c = :toolCallId AND StepType__c = 'ToolResult'
                ORDER BY Timestamp__c DESC
                LIMIT 1
            ];

            if (existingSteps.isEmpty()) {
                System.debug(LoggingLevel.WARN, logPrefix + 'No existing tool result step found for toolCallId: ' + toolCallId);
                return null;
            }

            ExecutionStep__c step = existingSteps[0];

            // Update the result
            step.ToolResult__c = toolResult;
            step.HasResult__c = String.isNotBlank(toolResult);
            step.IsError__c = isError != null ? isError : false;
            step.Timestamp__c = Datetime.now();

            // Update metadata
            Map<String, Object> metadata = new Map<String, Object>();
            if (String.isNotBlank(step.StepMetadata__c)) {
                try {
                    metadata = (Map<String, Object>) JSON.deserializeUntyped(step.StepMetadata__c);
                } catch (Exception e) {
                    // Ignore parse errors, start fresh
                }
            }
            if (processingDuration != null) {
                metadata.put('processingDuration', processingDuration);
            }
            metadata.put('updatedAfterApproval', true);
            metadata.put('approvalResolvedAt', Datetime.now());
            step.StepMetadata__c = JSON.serialize(metadata);

            if (processingDuration != null) {
                step.ProcessingDuration__c = processingDuration;
            }

            update step;

            System.debug(LoggingLevel.INFO, logPrefix + 'Updated tool result step: ' + step.Id + ' for toolCallId: ' + toolCallId);

            return step.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update tool result step: ' + e.getMessage());
            throw new ExecutionStepException('Failed to update tool result step: ' + e.getMessage());
        }
    }

    /**
     * Creates an error step.
     *
     * @param executionId The execution ID
     * @param errorMessage The error message
     * @param errorCode Optional error code
     * @param turnIdentifier The turn identifier
     * @param turnCount The turn number
     * @return Id of the created step
     */
    public Id createErrorStep(Id executionId, String errorMessage, String errorCode, String turnIdentifier, Integer turnCount) {
        Map<String, Object> metadata = new Map<String, Object>{ 'errorCode' => errorCode, 'errorTime' => Datetime.now() };

        return createStep(
            executionId,
            'Error',
            'System',
            errorMessage,
            'Text',
            turnIdentifier,
            turnCount,
            null, // toolCallId
            null, // toolName
            null, // toolArguments
            null, // toolResult
            JSON.serialize(metadata),
            null, // promptTokens
            null, // completionTokens
            null, // totalTokens
            null, // modelIdentifier
            null, // llmCalloutDurationMs
            false, // isInternal
            null, // isAsyncToolExecution
            null // capabilityId
        );
    }

    /**
     * Retrieves execution history with comprehensive filtering options.
     * This method parallels ChatMessageService.getHistory() for the unified data model.
     *
     * @param executionId The execution ID
     * @param maxResults Maximum number of results (null for unlimited)
     * @param sortOrder Sort order ('ASC' or 'DESC')
     * @param stepTypes Optional list of step types to filter by
     * @param includeInternal Whether to include internal system steps
     * @return List of ExecutionStep__c records
     */
    public List<ExecutionStep__c> getHistory(Id executionId, Integer maxResults, String sortOrder, List<String> stepTypes, Boolean includeInternal) {
        String logPrefix = LOG_PREFIX + '[getHistory] ';

        try {
            String query =
                'SELECT Id, StepType__c, StepRole__c, Content__c, ContentType__c, ' +
                'Timestamp__c, TurnIdentifier__c, TurnCount__c, ToolCallId__c, ' +
                'ToolName__c, ToolArguments__c, ToolResult__c, ProcessingDuration__c, ' +
                'StepMetadata__c, IsInternal__c ' +
                'FROM ExecutionStep__c ' +
                'WHERE AgentExecution__c = :executionId ';

            if (!includeInternal) {
                query += 'AND IsInternal__c = false ';
            }

            if (stepTypes != null && !stepTypes.isEmpty()) {
                query += 'AND StepType__c IN :stepTypes ';
            }

            String order = (sortOrder != null && 'DESC'.equalsIgnoreCase(sortOrder)) ? 'DESC' : 'ASC';
            query += 'ORDER BY Timestamp__c ' + order + ', Id ' + order + ' ';

            if (maxResults != null && maxResults > 0) {
                query += 'LIMIT :maxResults';
            }

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Executing history query for execution: ' + executionId);
            return Database.query(query);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve execution history: ' + e.getMessage());
            throw new ExecutionStepException('Failed to retrieve execution history: ' + e.getMessage());
        }
    }

    /**
     * Retrieves execution history with complete turns, optimized for memory management.
     * This method parallels ChatMessageService.getHistoryWithCompleteTurns() for the unified data model.
     *
     * @param executionId The execution ID
     * @param turnLimit Maximum number of complete turns to retrieve
     * @param sortOrder Sort order for turns ('ASC' or 'DESC')
     * @param includeInternal Whether to include internal system steps
     * @return List of ExecutionStep__c records representing complete turns
     */
    public List<ExecutionStep__c> getHistoryWithCompleteTurns(Id executionId, Integer turnLimit, String sortOrder, Boolean includeInternal) {
        String logPrefix = LOG_PREFIX + '[getHistoryWithCompleteTurns] ';

        try {
            // First, get the distinct turn identifiers with the specified limit and order
            String turnOrder = (sortOrder != null && 'DESC'.equalsIgnoreCase(sortOrder)) ? 'DESC' : 'ASC';
            String turnQuery =
                'SELECT TurnIdentifier__c ' +
                'FROM ExecutionStep__c ' +
                'WHERE AgentExecution__c = :executionId ' +
                'AND TurnIdentifier__c != NULL ';

            if (!includeInternal) {
                turnQuery += 'AND IsInternal__c = false ';
            }

            turnQuery += 'GROUP BY TurnIdentifier__c ' + 'ORDER BY MIN(Timestamp__c) ' + turnOrder + ' ';

            if (turnLimit != null && turnLimit > 0) {
                turnQuery += 'LIMIT :turnLimit';
            }

            List<AggregateResult> turnResults = Database.query(turnQuery);

            if (turnResults.isEmpty()) {
                System.debug(LoggingLevel.DEBUG, logPrefix + 'No turns found for execution: ' + executionId);
                return new List<ExecutionStep__c>();
            }

            // Extract turn identifiers
            Set<String> turnIdentifiers = new Set<String>();
            for (AggregateResult ar : turnResults) {
                String turnId = (String) ar.get('TurnIdentifier__c');
                if (String.isNotBlank(turnId)) {
                    turnIdentifiers.add(turnId);
                }
            }

            // Now get all steps for these turns
            String stepsQuery =
                'SELECT Id, StepType__c, StepRole__c, Content__c, ContentType__c, ' +
                'Timestamp__c, TurnIdentifier__c, TurnCount__c, ToolCallId__c, ' +
                'ToolName__c, ToolArguments__c, ToolResult__c, ProcessingDuration__c, ' +
                'StepMetadata__c, IsInternal__c ' +
                'FROM ExecutionStep__c ' +
                'WHERE AgentExecution__c = :executionId ' +
                'AND TurnIdentifier__c IN :turnIdentifiers ';

            if (!includeInternal) {
                stepsQuery += 'AND IsInternal__c = false ';
            }

            // Always return steps in chronological order within turns
            stepsQuery += 'ORDER BY Timestamp__c ASC, Id ASC';

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Retrieved ' + turnIdentifiers.size() + ' complete turns for execution: ' + executionId);
            return Database.query(stepsQuery);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve complete turns: ' + e.getMessage());
            throw new ExecutionStepException('Failed to retrieve complete turns: ' + e.getMessage());
        }
    }

    /**
     * Gets the count of unsummarized turns for an execution.
     * This method supports the SummaryBufferMemoryManager strategy.
     *
     * @param executionId The execution ID
     * @return Number of distinct unsummarized turns
     */
    public Integer getUnsummarizedTurnCount(Id executionId) {
        String logPrefix = LOG_PREFIX + '[getUnsummarizedTurnCount] ';

        try {
            List<AggregateResult> results = [
                SELECT COUNT_DISTINCT(TurnIdentifier__c) unsummarizedTurns
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId AND TurnIdentifier__c != NULL AND IsInternal__c = FALSE AND IsSummarized__c = FALSE
            ];

            Integer count = 0;
            if (!results.isEmpty() && results[0].get('unsummarizedTurns') != null) {
                count = (Integer) results[0].get('unsummarizedTurns');
            }

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Found ' + count + ' unsummarized turns for execution: ' + executionId);
            return count;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to count unsummarized turns: ' + e.getMessage());
            throw new ExecutionStepException('Failed to count unsummarized turns: ' + e.getMessage());
        }
    }

    /**
     * Marks execution steps as summarized.
     * Used by the summarization process to track which steps have been processed.
     *
     * @param stepIds List of ExecutionStep__c IDs to mark as summarized
     */
    public void markStepsAsSummarized(List<Id> stepIds) {
        String logPrefix = LOG_PREFIX + '[markStepsAsSummarized] ';

        if (stepIds == null || stepIds.isEmpty()) {
            return;
        }

        try {
            List<ExecutionStep__c> stepsToUpdate = new List<ExecutionStep__c>();
            for (Id stepId : stepIds) {
                stepsToUpdate.add(new ExecutionStep__c(Id = stepId, IsSummarized__c = true));
            }

            update stepsToUpdate;

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Marked ' + stepsToUpdate.size() + ' steps as summarized');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to mark steps as summarized: ' + e.getMessage());
            throw new ExecutionStepException('Failed to mark steps as summarized: ' + e.getMessage());
        }
    }

    /**
     * Gets unsummarized steps for an execution, used by summarization process.
     *
     * @param executionId The execution ID
     * @param includeInternal Whether to include internal system steps
     * @return List of unsummarized ExecutionStep__c records
     */
    public List<ExecutionStep__c> getUnsummarizedSteps(Id executionId, Boolean includeInternal) {
        String logPrefix = LOG_PREFIX + '[getUnsummarizedSteps] ';

        try {
            String query =
                'SELECT Id, StepType__c, StepRole__c, Content__c, ContentType__c, ' +
                'Timestamp__c, TurnIdentifier__c, TurnCount__c, ToolCallId__c, ' +
                'ToolName__c, ToolArguments__c, ToolResult__c, ProcessingDuration__c, ' +
                'StepMetadata__c, IsInternal__c ' +
                'FROM ExecutionStep__c ' +
                'WHERE AgentExecution__c = :executionId ' +
                'AND IsSummarized__c = false ';

            if (!includeInternal) {
                query += 'AND IsInternal__c = false ';
            }

            query += 'ORDER BY Timestamp__c ASC, Id ASC';

            return Database.query(query);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve unsummarized steps: ' + e.getMessage());
            throw new ExecutionStepException('Failed to retrieve unsummarized steps: ' + e.getMessage());
        }
    }

    // Static cache for LLM model pricing to avoid repeated SOQL queries
    private static Map<String, LLMModelPricing__mdt> pricingCache;
    private static Boolean isPricingCacheInitialized = false;

    /**
     * Calculate estimated cost based on model pricing and token usage
     * Pricing is retrieved from LLMModelPricing__mdt custom metadata
     *
     * @param modelIdentifier The model identifier (e.g., gpt-4o, gpt-4o-mini)
     * @param promptTokens Number of tokens in the prompt
     * @param completionTokens Number of tokens in the completion
     * @return The estimated cost in USD, or null if model is unknown or pricing not configured
     */
    private static Decimal calculateCost(String modelIdentifier, Integer promptTokens, Integer completionTokens) {
        if (String.isBlank(modelIdentifier) || promptTokens == null || completionTokens == null) {
            return null;
        }

        // Initialize pricing cache if needed
        ensurePricingCacheInitialized();

        // Normalize model identifier to lowercase for matching
        String normalizedModel = modelIdentifier.toLowerCase();

        // Try exact match first
        if (pricingCache.containsKey(normalizedModel)) {
            LLMModelPricing__mdt pricing = pricingCache.get(normalizedModel);
            Decimal promptCost = (Decimal.valueOf(promptTokens) / 1000000.0) * pricing.PromptPricePer1MTokens__c;
            Decimal completionCost = (Decimal.valueOf(completionTokens) / 1000000.0) * pricing.CompletionPricePer1MTokens__c;
            return promptCost + completionCost;
        }

        // Model not found in pricing metadata
        System.debug(LoggingLevel.WARN, LOG_PREFIX + 'No pricing found for model: ' + modelIdentifier);
        return null;
    }

    /**
     * Ensures pricing cache is initialized with active LLM model pricing records
     */
    private static void ensurePricingCacheInitialized() {
        if (isPricingCacheInitialized) {
            return;
        }

        pricingCache = new Map<String, LLMModelPricing__mdt>();

        try {
            List<LLMModelPricing__mdt> pricingRecords = [
                SELECT ModelIdentifier__c, PromptPricePer1MTokens__c, CompletionPricePer1MTokens__c
                FROM LLMModelPricing__mdt
                WHERE IsActive__c = TRUE
            ];

            for (LLMModelPricing__mdt pricing : pricingRecords) {
                if (String.isNotBlank(pricing.ModelIdentifier__c)) {
                    pricingCache.put(pricing.ModelIdentifier__c.toLowerCase(), pricing);
                }
            }

            isPricingCacheInitialized = true;
            System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Initialized pricing cache with ' + pricingCache.size() + ' models');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Failed to initialize pricing cache: ' + e.getMessage());
            // Initialize empty cache to avoid repeated failures
            isPricingCacheInitialized = true;
        }
    }
}
