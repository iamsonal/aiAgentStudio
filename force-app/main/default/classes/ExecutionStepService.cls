/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Manages ExecutionStep__c records in the unified agentic framework. Supports all execution types and step patterns.
 */
public inherited sharing class ExecutionStepService {
    private static final String LOG_PREFIX = '[ExecutionStepService] ';

    public class ExecutionStepException extends AIAgentException {
    }
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
            null, // capabilityId
            null // confidence
        );
    }

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
        Id capabilityId,
        Decimal confidence
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
                AIAgentCapability__c = capabilityId,
                Confidence__c = confidence
            );

            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                TransactionContext.getInstance().bufferInsert(step);
                System.debug(LoggingLevel.DEBUG, logPrefix + 'Buffered ExecutionStep__c for deferred insert. Type: ' + stepType + ' Role: ' + stepRole);
                return null;
            }

            insert step;

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Created ExecutionStep__c: ' + step.Id + ' Type: ' + stepType + ' Role: ' + stepRole);

            return step.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create step: ' + e.getMessage());
            throw new ExecutionStepException('Failed to create execution step: ' + e.getMessage());
        }
    }

    public Id createUserInputStep(Id executionId, String userMessage, String turnIdentifier, Integer turnCount) {
        return createStep(executionId, 'UserInput', 'User', userMessage, 'Text', turnIdentifier, turnCount);
    }

    public Id createAgentResponseStep(Id executionId, String agentResponse, String turnIdentifier, Integer turnCount) {
        return createStep(executionId, 'AgentResponse', 'Assistant', agentResponse, 'Text', turnIdentifier, turnCount);
    }

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
            null, // capabilityId
            null // confidence
        );
    }

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
        String toolRationale,
        Decimal confidence,
        String nextStepSuggestion,
        Boolean isResumed
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
                ToolRationale__c = toolRationale,
                Confidence__c = confidence,
                NextStepSuggestion__c = nextStepSuggestion,
                IsResumed__c = isResumed != null ? isResumed : false
            );

            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                TransactionContext.getInstance().bufferInsert(step);
                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix + 'Buffered ToolCall ExecutionStep__c for deferred insert. Tool: ' + toolName + ' IsResumed: ' + (isResumed == true)
                );
                return null;
            }

            insert step;

            System.debug(
                LoggingLevel.DEBUG,
                logPrefix +
                    'Created ToolCall ExecutionStep__c: ' +
                    step.Id +
                    ' Tool: ' +
                    toolName +
                    ' HasRationale: ' +
                    String.isNotBlank(toolRationale) +
                    ' IsResumed: ' +
                    (isResumed == true)
            );

            return step.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create tool call step: ' + e.getMessage());
            throw new ExecutionStepException('Failed to create tool call step: ' + e.getMessage());
        }
    }

    /**
     * Builds a ToolCall ExecutionStep__c without performing DML.
     * Use this for bulk insert scenarios to reduce DML operations.
     */
    public ExecutionStep__c buildToolCallStep(
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
        String toolRationale,
        Decimal confidence,
        String nextStepSuggestion,
        Boolean isResumed
    ) {
        Decimal estimatedCost = calculateCost(modelIdentifier, promptTokens, completionTokens);

        return new ExecutionStep__c(
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
            ToolRationale__c = toolRationale,
            Confidence__c = confidence,
            NextStepSuggestion__c = nextStepSuggestion,
            IsResumed__c = isResumed != null ? isResumed : false
        );
    }

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
        Boolean isError,
        Boolean isResumed
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

            Map<String, Object> errorMetadata = extractErrorMetadata(toolResult);
            String errorCategory = (String) errorMetadata.get('errorCategory');
            Boolean isRetryable = coerceBoolean(errorMetadata.get('isRetryable'));
            if (isRetryable == null) {
                isRetryable = false;
            }

            Boolean isActualError = isError == true;

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
                AIAgentCapability__c = capabilityId,
                IsResumed__c = isResumed != null ? isResumed : false,
                ErrorCategory__c = errorCategory,
                RetryPending__c = isActualError && isRetryable == true
            );
            applyRetryableField(step, isRetryable);

            // Multi-LLM optimization: Check if deferred DML mode is enabled
            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                TransactionContext.getInstance().bufferInsert(step);
                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix + 'Buffered tool result step for deferred insert. Tool: ' + toolName + ' retryPending: ' + (isActualError && isRetryable == true)
                );
                return null;
            }

            insert step;

            System.debug(
                LoggingLevel.DEBUG,
                logPrefix +
                    'Created tool result step: ' +
                    step.Id +
                    ' for tool: ' +
                    toolName +
                    ' (async=' +
                    isAsyncToolExecution +
                    ', isError=' +
                    step.IsError__c +
                    ', retryPending=' +
                    step.RetryPending__c +
                    ')'
            );

            return step.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create tool result step: ' + e.getMessage());
            throw new ExecutionStepException('Failed to create tool result step: ' + e.getMessage());
        }
    }

    /**
     * Builds a ToolResult ExecutionStep__c without performing DML.
     * Use this for bulk insert scenarios to reduce DML operations.
     */
    public ExecutionStep__c buildToolResultStep(
        Id executionId,
        String toolCallId,
        String toolName,
        String toolResult,
        String turnIdentifier,
        Integer turnCount,
        Long processingDuration,
        Boolean isAsyncToolExecution,
        Id capabilityId,
        Boolean isError,
        Boolean isResumed
    ) {
        Map<String, Object> metadata = new Map<String, Object>();
        if (processingDuration != null) {
            metadata.put('processingDuration', processingDuration);
        }
        if (isAsyncToolExecution != null) {
            metadata.put('isAsyncToolExecution', isAsyncToolExecution);
        }

        Map<String, Object> errorMetadata = extractErrorMetadata(toolResult);
        String errorCategory = (String) errorMetadata.get('errorCategory');
        Boolean isRetryable = coerceBoolean(errorMetadata.get('isRetryable'));
        if (isRetryable == null) {
            isRetryable = false;
        }

        Boolean isActualError = isError == true;

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
            AIAgentCapability__c = capabilityId,
            IsResumed__c = isResumed != null ? isResumed : false,
            ErrorCategory__c = errorCategory,
            RetryPending__c = isActualError && isRetryable == true
        );
        applyRetryableField(step, isRetryable);
        return step;
    }

    public Id updateToolResultStep(Id executionId, String toolCallId, String toolResult, Long processingDuration) {
        return updateToolResultStep(executionId, toolCallId, toolResult, processingDuration, false);
    }

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

            step.ToolResult__c = toolResult;
            step.HasResult__c = String.isNotBlank(toolResult);
            step.IsError__c = isError != null ? isError : false;
            step.Timestamp__c = Datetime.now();

            Map<String, Object> errorMetadata = extractErrorMetadata(toolResult);
            step.ErrorCategory__c = (String) errorMetadata.get('errorCategory');
            Boolean isRetryable = coerceBoolean(errorMetadata.get('isRetryable'));
            if (isRetryable == null) {
                isRetryable = false;
            }
            applyRetryableField(step, isRetryable);
            step.RetryPending__c = isError == true && isRetryable == true;

            Map<String, Object> metadata = new Map<String, Object>();
            if (String.isNotBlank(step.StepMetadata__c)) {
                try {
                    metadata = (Map<String, Object>) JSON.deserializeUntyped(step.StepMetadata__c);
                } catch (Exception e) {
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
     * @description Injects a framework enforcement message into the conversation history
     * when the LLM returned a text response without retrying one or more failed retryable tools.
     * The step is marked IsInternal__c=true so it is hidden in the Storyboard UI but included
     * in the LLM message history (user role) to instruct the model to retry.
     *
     * @param executionId  The AgentExecution__c ID
     * @param failures     List of unretried retryable failures from OrchestrationService
     * @param turnIdentifier  Current turn identifier
     * @param turnCount    Current turn/cycle count
     */
    public void createRetryEnforcementStep(Id executionId, List<OrchestrationService.UnretriedFailure> failures, String turnIdentifier, Integer turnCount) {
        if (failures == null || failures.isEmpty()) {
            return;
        }

        List<String> lines = new List<String>{ AIAgentConstants.PROMPT_RETRY_ENFORCEMENT_HEADER, AIAgentConstants.PROMPT_RETRY_ENFORCEMENT_DIRECTIVE, '' };
        for (OrchestrationService.UnretriedFailure f : failures) {
            String argStr = String.isNotBlank(f.originalArguments) ? f.originalArguments : '{}';
            lines.add('- ' + f.toolName + ': ' + argStr);
        }

        String content = String.join(lines, '\n');

        ExecutionStep__c step = new ExecutionStep__c(
            AgentExecution__c = executionId,
            StepType__c = 'UserInput',
            StepRole__c = 'User',
            Content__c = content,
            ContentType__c = 'Text',
            Timestamp__c = Datetime.now(),
            TurnIdentifier__c = turnIdentifier,
            TurnCount__c = turnCount,
            IsInternal__c = false
        );

        // Always buffer — never insert directly.
        // Salesforce prohibits callouts after uncommitted DML in the same transaction. In
        // IMMEDIATE_FOLLOWUP mode the next LLM cycle follows immediately in the same queueable, so a
        // direct insert would cause a CalloutException on the very next HTTP request.
        // TransactionContext.getBufferedExecutionSteps() is called by getHistory() to merge buffered
        // steps into the DB-queried history, so the LLM will see this instruction without needing a
        // DB commit first.
        TransactionContext.getInstance().bufferInsert(step);
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + '[createRetryEnforcementStep] Buffered enforcement step for ' + failures.size() + ' unretried tool(s).');
    }

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
            null,
            null,
            null,
            null,
            JSON.serialize(metadata),
            null,
            null,
            null,
            null,
            null,
            false,
            null,
            null,
            null // confidence
        );
    }

    @SuppressWarnings('PMD.ApexSOQLInjection')
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
            List<ExecutionStep__c> dbResults = Database.query(query);

            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                List<ExecutionStep__c> bufferedSteps = TransactionContext.getInstance().getBufferedExecutionSteps(executionId);

                if (!bufferedSteps.isEmpty()) {
                    List<ExecutionStep__c> filteredBuffered = new List<ExecutionStep__c>();
                    Set<String> stepTypeSet = (stepTypes != null && !stepTypes.isEmpty()) ? new Set<String>(stepTypes) : null;

                    for (ExecutionStep__c step : bufferedSteps) {
                        if (!includeInternal && step.IsInternal__c == true) {
                            continue;
                        }
                        if (stepTypeSet != null && !stepTypeSet.contains(step.StepType__c)) {
                            continue;
                        }
                        filteredBuffered.add(step);
                    }

                    if (!filteredBuffered.isEmpty()) {
                        System.debug(
                            LoggingLevel.DEBUG,
                            logPrefix + 'Multi-LLM optimization: Adding ' + filteredBuffered.size() + ' buffered steps to history'
                        );

                        // Merge database results with buffered steps using sortable wrappers
                        List<ExecutionStepWrapper> wrappers = new List<ExecutionStepWrapper>();
                        Boolean isDescending = 'DESC'.equalsIgnoreCase(order);

                        for (ExecutionStep__c step : dbResults) {
                            wrappers.add(new ExecutionStepWrapper(step, isDescending));
                        }
                        for (ExecutionStep__c step : filteredBuffered) {
                            wrappers.add(new ExecutionStepWrapper(step, isDescending));
                        }

                        // OPTIMIZATION: Defensive limit to prevent CPU timeout with large datasets.
                        // Always retain buffered in-flight steps, then trim database history around them.
                        final Integer MAX_SORTABLE_STEPS = 500;
                        if (wrappers.size() > MAX_SORTABLE_STEPS) {
                            System.debug(
                                LoggingLevel.WARN,
                                logPrefix +
                                    'Step count (' +
                                    wrappers.size() +
                                    ') exceeds safe sorting limit (' +
                                    MAX_SORTABLE_STEPS +
                                    '). ' +
                                    'Truncating to prevent CPU timeout. Consider using maxResults parameter or database ORDER BY.'
                            );
                            Integer bufferedCount = filteredBuffered.size();
                            Integer dbSlots = Math.max(0, MAX_SORTABLE_STEPS - bufferedCount);
                            List<ExecutionStepWrapper> truncated = new List<ExecutionStepWrapper>();

                            if (dbSlots > 0) {
                                if (isDescending) {
                                    for (Integer i = 0; i < dbSlots && i < dbResults.size(); i++) {
                                        truncated.add(new ExecutionStepWrapper(dbResults[i], isDescending));
                                    }
                                } else {
                                    Integer dbStart = Math.max(0, dbResults.size() - dbSlots);
                                    for (Integer i = dbStart; i < dbResults.size(); i++) {
                                        truncated.add(new ExecutionStepWrapper(dbResults[i], isDescending));
                                    }
                                }
                            }

                            for (ExecutionStep__c step : filteredBuffered) {
                                truncated.add(new ExecutionStepWrapper(step, isDescending));
                            }
                            wrappers = truncated;
                        }

                        // Sort wrappers by timestamp
                        wrappers.sort();

                        // Extract sorted steps
                        List<ExecutionStep__c> merged = new List<ExecutionStep__c>();
                        for (ExecutionStepWrapper wrapper : wrappers) {
                            merged.add(wrapper.step);
                        }

                        // Apply maxResults limit if specified
                        if (maxResults != null && maxResults > 0 && merged.size() > maxResults) {
                            List<ExecutionStep__c> limited = new List<ExecutionStep__c>();
                            for (Integer i = 0; i < maxResults && i < merged.size(); i++) {
                                limited.add(merged[i]);
                            }
                            return limited;
                        }

                        return merged;
                    }
                }
            }

            return dbResults;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve execution history: ' + e.getMessage());
            throw new ExecutionStepException('Failed to retrieve execution history: ' + e.getMessage());
        }
    }

    private class ExecutionStepWrapper implements Comparable {
        public ExecutionStep__c step;
        private Boolean descending;

        public ExecutionStepWrapper(ExecutionStep__c step, Boolean descending) {
            this.step = step;
            this.descending = descending;
        }

        public Integer compareTo(Object other) {
            ExecutionStepWrapper otherWrapper = (ExecutionStepWrapper) other;
            Datetime thisTime = this.step.Timestamp__c;
            Datetime otherTime = otherWrapper.step.Timestamp__c;

            if (thisTime == null && otherTime == null) {
                return 0;
            } else if (thisTime == null) {
                return descending ? -1 : 1;
            } else if (otherTime == null) {
                return descending ? 1 : -1;
            }

            Integer result = thisTime < otherTime ? -1 : (thisTime > otherTime ? 1 : 0);
            return descending ? -result : result;
        }
    }

    @SuppressWarnings('PMD.ApexSOQLInjection')
    public List<ExecutionStep__c> getHistoryWithCompleteTurns(Id executionId, Integer turnLimit, String sortOrder, Boolean includeInternal) {
        String logPrefix = LOG_PREFIX + '[getHistoryWithCompleteTurns] ';

        try {
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
                // No committed turns, but buffered steps from the current in-flight turn may exist
                // (IMMEDIATE_FOLLOWUP Cycle 2+ scenario — deferred DML not yet committed).
                if (TransactionContext.getInstance().isDeferredDMLMode()) {
                    List<ExecutionStep__c> bufferedSteps = TransactionContext.getInstance().getBufferedExecutionSteps(executionId);
                    if (!bufferedSteps.isEmpty()) {
                        List<ExecutionStep__c> filtered = new List<ExecutionStep__c>();
                        for (ExecutionStep__c step : bufferedSteps) {
                            if (!includeInternal && step.IsInternal__c == true) {
                                continue;
                            }
                            if (step.TurnIdentifier__c == null) {
                                continue;
                            }
                            filtered.add(step);
                        }
                        if (!filtered.isEmpty()) {
                            System.debug(
                                LoggingLevel.DEBUG,
                                logPrefix +
                                    'Multi-LLM optimization: No DB turns found; returning ' +
                                    filtered.size() +
                                    ' buffered steps for current in-flight turn'
                            );
                            List<ExecutionStepWrapper> wrappers = new List<ExecutionStepWrapper>();
                            for (ExecutionStep__c step : filtered) {
                                wrappers.add(new ExecutionStepWrapper(step, false));
                            }
                            wrappers.sort();
                            List<ExecutionStep__c> sortedFiltered = new List<ExecutionStep__c>();
                            for (ExecutionStepWrapper w : wrappers) {
                                sortedFiltered.add(w.step);
                            }
                            return sortedFiltered;
                        }
                    }
                }
                return new List<ExecutionStep__c>();
            }

            Set<String> turnIdentifiers = new Set<String>();
            for (AggregateResult ar : turnResults) {
                String turnId = (String) ar.get('TurnIdentifier__c');
                if (String.isNotBlank(turnId)) {
                    turnIdentifiers.add(turnId);
                }
            }

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

            stepsQuery += 'ORDER BY Timestamp__c ASC, Id ASC';

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Retrieved ' + turnIdentifiers.size() + ' complete turns for execution: ' + executionId);
            List<ExecutionStep__c> dbResults = Database.query(stepsQuery);

            // Merge buffered steps so that IMMEDIATE_FOLLOWUP Cycle 2+ sees current-turn context.
            // When deferred DML is active, the current turn's steps (user input, tool call, tool
            // result) are in TransactionContext.insertBuffer and not yet in the DB.  getHistory()
            // already does this merge; we mirror the same logic here so the turn-limited path
            // behaves consistently.
            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                List<ExecutionStep__c> bufferedSteps = TransactionContext.getInstance().getBufferedExecutionSteps(executionId);

                if (!bufferedSteps.isEmpty()) {
                    List<ExecutionStep__c> filteredBuffered = new List<ExecutionStep__c>();
                    for (ExecutionStep__c step : bufferedSteps) {
                        if (!includeInternal && step.IsInternal__c == true) {
                            continue;
                        }
                        if (step.TurnIdentifier__c == null) {
                            continue;
                        }
                        filteredBuffered.add(step);
                    }

                    if (!filteredBuffered.isEmpty()) {
                        System.debug(
                            LoggingLevel.DEBUG,
                            logPrefix + 'Multi-LLM optimization: Merging ' + filteredBuffered.size() + ' buffered steps into turn-limited history'
                        );

                        List<ExecutionStepWrapper> wrappers = new List<ExecutionStepWrapper>();
                        for (ExecutionStep__c step : dbResults) {
                            wrappers.add(new ExecutionStepWrapper(step, false));
                        }
                        for (ExecutionStep__c step : filteredBuffered) {
                            wrappers.add(new ExecutionStepWrapper(step, false));
                        }
                        wrappers.sort();

                        List<ExecutionStep__c> merged = new List<ExecutionStep__c>();
                        for (ExecutionStepWrapper w : wrappers) {
                            merged.add(w.step);
                        }
                        return merged;
                    }
                }
            }

            return dbResults;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve complete turns: ' + e.getMessage());
            throw new ExecutionStepException('Failed to retrieve complete turns: ' + e.getMessage());
        }
    }

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

    @SuppressWarnings('PMD.ApexSOQLInjection')
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
            List<ExecutionStep__c> dbResults = Database.query(query);

            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                List<ExecutionStep__c> bufferedSteps = TransactionContext.getInstance().getBufferedExecutionSteps(executionId);
                if (!bufferedSteps.isEmpty()) {
                    List<ExecutionStep__c> filteredBuffered = new List<ExecutionStep__c>();
                    for (ExecutionStep__c step : bufferedSteps) {
                        if (step == null || step.IsSummarized__c == true) {
                            continue;
                        }
                        if (!includeInternal && step.IsInternal__c == true) {
                            continue;
                        }
                        filteredBuffered.add(step);
                    }

                    if (!filteredBuffered.isEmpty()) {
                        List<ExecutionStepWrapper> wrappers = new List<ExecutionStepWrapper>();
                        for (ExecutionStep__c step : dbResults) {
                            wrappers.add(new ExecutionStepWrapper(step, false));
                        }
                        for (ExecutionStep__c step : filteredBuffered) {
                            wrappers.add(new ExecutionStepWrapper(step, false));
                        }

                        wrappers.sort();

                        List<ExecutionStep__c> merged = new List<ExecutionStep__c>();
                        for (ExecutionStepWrapper wrapper : wrappers) {
                            merged.add(wrapper.step);
                        }
                        return merged;
                    }
                }
            }

            return dbResults;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve unsummarized steps: ' + e.getMessage());
            throw new ExecutionStepException('Failed to retrieve unsummarized steps: ' + e.getMessage());
        }
    }

    /**
     * Calculates the estimated cost for an LLM call using centralized pricing logic.
     * Delegates to AIAgentConfigService for consistent pricing across the framework.
     *
     * @param modelIdentifier  The model identifier (e.g., gpt-4o, gpt-4o-mini)
     * @param promptTokens     Number of tokens in the prompt
     * @param completionTokens Number of tokens in the completion
     * @return                 The estimated cost in USD, or null if pricing not available
     */
    private static Decimal calculateCost(String modelIdentifier, Integer promptTokens, Integer completionTokens) {
        return AIAgentConfigService.calculateLLMCost(modelIdentifier, promptTokens, completionTokens);
    }

    private static Map<String, Object> extractErrorMetadata(String toolResult) {
        Map<String, Object> metadata = new Map<String, Object>{ 'errorCategory' => null, 'isRetryable' => null };
        if (String.isBlank(toolResult)) {
            return metadata;
        }

        try {
            Object raw = JSON.deserializeUntyped(toolResult);
            if (!(raw instanceof Map<String, Object>)) {
                return metadata;
            }
            Map<String, Object> result = (Map<String, Object>) raw;

            if (result.containsKey('retryable')) {
                metadata.put('isRetryable', coerceBoolean(result.get('retryable')));
            }
        } catch (Exception e) {
        }

        return metadata;
    }

    private static Boolean coerceBoolean(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        if (value instanceof String) {
            String normalized = ((String) value).trim().toLowerCase();
            if (normalized == 'true') {
                return true;
            }
            if (normalized == 'false') {
                return false;
            }
            return null;
        }
        if (value instanceof Integer || value instanceof Long || value instanceof Decimal) {
            Decimal numVal = (value instanceof Decimal) ? (Decimal) value : Decimal.valueOf(String.valueOf(value));
            if (numVal == 1) {
                return true;
            }
            if (numVal == 0) {
                return false;
            }
        }
        return null;
    }

    private static void applyRetryableField(SObject record, Boolean isRetryable) {
        if (record == null) {
            return;
        }

        try {
            Map<String, Schema.SObjectField> fields = record.getSObjectType().getDescribe().fields.getMap();
            if (!fields.containsKey('IsRetryable__c')) {
                return;
            }

            Schema.DisplayType fieldType = fields.get('IsRetryable__c').getDescribe().getType();
            if (fieldType == Schema.DisplayType.Boolean) {
                record.put('IsRetryable__c', isRetryable);
                return;
            }
            if (fieldType == Schema.DisplayType.String) {
                record.put('IsRetryable__c', String.valueOf(isRetryable));
                return;
            }

            record.put('IsRetryable__c', isRetryable);
        } catch (Exception e) {
        }
    }
}
