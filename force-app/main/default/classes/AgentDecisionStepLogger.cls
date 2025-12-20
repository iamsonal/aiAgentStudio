/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AgentDecisionStepLogger is responsible for capturing internal diagnostic and observability steps
 * of the AI agent for visualization in the storyboard UI.
 *
 * This class now follows the Unit of Work pattern, collecting all decision steps in an
 * in-memory list rather than performing immediate DML. A commitSteps() method performs
 * a single, bulk INSERT of all collected steps at the end of the transaction.
 *
 * Responsibilities:
 *   - Collect AgentDecisionStep__c records for internal diagnostic steps only
 *   - Provide methods for each internal step type in the agent's decision process
 *   - Handle error logging with detailed information
 *   - Commit all steps in a single bulk DML operation
 *
 * This class is designed to be used throughout the agent framework to capture
 * the internal decision-making journey for visualization purposes, working exclusively
 * with the unified AgentExecution__c model.
 */
public inherited sharing class AgentDecisionStepLogger {
    public enum StepType {
        USER_INPUT,
        CONTEXT_GATHERING,
        SYSTEM_PROMPT_CONSTRUCTION,
        LLM_REQUEST,
        LLM_RESPONSE,
        TOOL_SELECTION,
        TOOL_EXECUTION,
        TOOL_RESULT,
        ERROR,
        AVAILABLE_TOOLS,
        FINAL_RESPONSE,
        RESUME_APPROVED_FRAMEWORK_ACTION,
        HANDLE_REJECTED_FRAMEWORK_ACTION
    }

    private Id executionId;
    private String turnIdentifier;
    private Id originalUserId;
    private List<AgentDecisionStep__c> stepsToCommit;
    private Integer nextSequenceNumber;
    private Id lastLoggedStepId;
    private Map<String, Id> toolCallIdToStepMap;

    /**
     * Constructor to initialize the logger with execution context
     * Works exclusively with the unified AgentExecution__c model
     *
     * @param executionId The AgentExecution__c ID
     * @param turnIdentifier The turn identifier
     */
    public AgentDecisionStepLogger(Id executionId, String turnIdentifier) {
        this(executionId, turnIdentifier, null);
    }

    /**
     * Constructor to initialize the logger with execution context and user information
     * Works exclusively with the unified AgentExecution__c model
     *
     * @param executionId The AgentExecution__c ID
     * @param turnIdentifier The turn identifier
     * @param originalUserId The ID of the user who initiated the conversation
     */
    public AgentDecisionStepLogger(Id executionId, String turnIdentifier, Id originalUserId) {
        this.executionId = executionId;
        this.turnIdentifier = turnIdentifier;
        this.originalUserId = originalUserId;
        this.stepsToCommit = new List<AgentDecisionStep__c>();
        this.toolCallIdToStepMap = new Map<String, Id>();

        // Initialize sequence counter by querying the last step number for this turn.
        // This ensures continuity across synchronous and asynchronous transaction boundaries.
        Integer lastKnownSequence = 0;
        try {
            List<AggregateResult> results = [
                SELECT MAX(StepOrder__c) maxSeq
                FROM AgentDecisionStep__c
                WHERE TurnIdentifier__c = :turnIdentifier AND AgentExecution__c = :executionId
            ];

            if (!results.isEmpty() && results[0].get('maxSeq') != null) {
                lastKnownSequence = Integer.valueOf(results[0].get('maxSeq'));
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AgentDecisionStepLogger] Could not query for last sequence number: ' + e.getMessage());
            // If query fails, we proceed with 0, but log the error.
        }

        this.nextSequenceNumber = lastKnownSequence + 1;
        System.debug(
            LoggingLevel.INFO,
            '[AgentDecisionStepLogger] Initialized for AgentExecution ' +
                executionId +
                ', turn ' +
                turnIdentifier +
                '. Starting sequence at: ' +
                this.nextSequenceNumber
        );
    }

    /**
     * Get the next global step sequence for this turn using an in-memory counter
     * This ensures correct sequencing within a single transaction
     *
     * @return The next global step sequence number
     */
    private Integer getNextGlobalStepSequence() {
        // Use in-memory counter to ensure correct sequencing within transaction
        Integer currentSequence = this.nextSequenceNumber;
        this.nextSequenceNumber++;
        return currentSequence;
    }

    /**
     * Log a user input step
     *
     * @param title Descriptive title for the step
     * @param userMessage The user's message content
     * @param durationMs Duration of processing this step
     */
    public void logUserInput(String title, String userMessage, Long durationMs) {
        logStep(StepType.USER_INPUT, title, 'User provided input to the AI agent', userMessage, durationMs, true, null, null);
    }

    /**
     * Log a context gathering step
     *
     * @param title Descriptive title for the step
     * @param contextDescription Description of context gathered
     * @param contextJson JSON representation of context data
     * @param durationMs Duration of processing this step
     */
    public void logContextGathering(String title, String contextDescription, String contextJson, Long durationMs) {
        logStep(StepType.CONTEXT_GATHERING, title, contextDescription, contextJson, durationMs, true, null, null);
    }

    /**
     * Log a context gathering step with separate raw and formatted context data
     *
     * @param title Descriptive title for the step
     * @param contextDescription Description of context gathered
     * @param rawContextJson JSON representation of raw context data
     * @param formattedContext The formatted context as presented to the LLM
     * @param durationMs Duration of processing this step
     */
    public void logContextGatheringWithFormatting(
        String title,
        String contextDescription,
        String rawContextJson,
        String formattedContext,
        Long durationMs
    ) {
        // For backward compatibility, we'll store the raw context in ContentJson__c
        // and the formatted context in the new FormattedContext__c field
        logStepWithContextFormatting(
            StepType.CONTEXT_GATHERING,
            title,
            contextDescription,
            rawContextJson,
            formattedContext,
            durationMs,
            true,
            null,
            null
        );
    }

    /**
     * Log a system prompt construction step
     *
     * @param title Descriptive title for the step
     * @param promptDescription Description of prompt construction
     * @param promptContent The actual prompt content
     * @param durationMs Duration of processing this step
     */
    public void logSystemPromptConstruction(String title, String promptDescription, String promptContent, Long durationMs) {
        // For system prompt construction, we'll store the prompt content in FormattedContext__c
        // to keep the ContentJson__c field for metadata about the prompt construction process
        logStepWithFormattedContext(
            StepType.SYSTEM_PROMPT_CONSTRUCTION,
            title,
            promptDescription,
            promptContent, // This will go to FormattedContext__c
            durationMs,
            true,
            null,
            null
        );
    }

    /**
     * Log an LLM request step
     *
     * @param title Descriptive title for the step
     * @param requestDescription Description of the request
     * @param requestJson JSON representation of the request
     * @param durationMs Duration of processing this step
     */
    public void logLLMRequest(String title, String requestDescription, String requestJson, Long durationMs) {
        logStep(StepType.LLM_REQUEST, title, requestDescription, requestJson, durationMs, true, null, null);
    }

    /**
     * Log an LLM response step
     *
     * @param title Descriptive title for the step
     * @param responseDescription Description of the response
     * @param responseJson JSON representation of the response
     * @param durationMs Duration of processing this step
     */
    public void logLLMResponse(String title, String responseDescription, String responseJson, Long durationMs) {
        logStep(StepType.LLM_RESPONSE, title, responseDescription, responseJson, durationMs, true, null, null);
    }

    /**
     * Log LLM response with token usage and cost tracking
     *
     * @param title Descriptive title for the step
     * @param responseDescription Description of the response
     * @param responseJson JSON representation of the response
     * @param durationMs Duration of processing this step
     * @param promptTokens Number of tokens in the prompt
     * @param completionTokens Number of tokens in the completion
     * @param totalTokens Total tokens used
     * @param modelIdentifier Model identifier (e.g., gpt-4)
     * @param provider LLM provider (e.g., OpenAI)
     * @param temperature Temperature setting used
     */
    public void logLLMResponseWithMetrics(
        String title,
        String responseDescription,
        String responseJson,
        Long durationMs,
        Integer promptTokens,
        Integer completionTokens,
        Integer totalTokens,
        String modelIdentifier,
        String provider,
        Decimal temperature
    ) {
        try {
            // Calculate estimated cost based on model
            Decimal estimatedCost = calculateCost(modelIdentifier, promptTokens, completionTokens);

            // Calculate context size for tracking
            Integer contextSize = responseJson != null ? responseJson.length() : 0;
            Boolean isTruncated = contextSize > 131072; // Salesforce Long Text Area limit

            // Get next global step sequence using in-memory counter
            Integer globalStepSequence = getNextGlobalStepSequence();

            // Map enum to picklist value
            String stepTypeValue = mapStepTypeToPicklistValue(StepType.LLM_RESPONSE);

            // Create the decision step record with enhanced metrics
            AgentDecisionStep__c step = new AgentDecisionStep__c(
                TurnIdentifier__c = this.turnIdentifier,
                StepType__c = stepTypeValue,
                StepOrder__c = globalStepSequence,
                Title__c = title,
                Description__c = responseDescription,
                ContentJson__c = responseJson,
                DurationMs__c = durationMs,
                IsSuccess__c = true,
                // NEW FIELDS
                PromptTokens__c = promptTokens,
                CompletionTokens__c = completionTokens,
                TotalTokens__c = totalTokens,
                EstimatedCostUSD__c = estimatedCost,
                ModelIdentifier__c = modelIdentifier,
                LLMProvider__c = provider,
                Temperature__c = temperature,
                ContextSizeBytes__c = contextSize,
                ContextTruncated__c = isTruncated
            );

            // Set the AgentExecution lookup field
            step.AgentExecution__c = this.executionId;

            // Add user information if available
            if (this.originalUserId != null) {
                step.put('OriginalUser__c', this.originalUserId);
            }

            // Always set the execution user to the current user
            step.put('ExecutionUser__c', UserInfo.getUserId());

            // Add to the list of steps to commit
            stepsToCommit.add(step);

            // Track last logged step for causality
            this.lastLoggedStepId = step.Id;

            System.debug(
                LoggingLevel.INFO,
                '[AgentDecisionStepLogger] Collected LLM step with metrics: ' +
                    stepTypeValue +
                    ' - ' +
                    title +
                    ' | Tokens: ' +
                    totalTokens +
                    ' | Cost: $' +
                    estimatedCost +
                    ' | Sequence: ' +
                    globalStepSequence
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AgentDecisionStepLogger] Failed to log LLM metrics: ' + e.getMessage());
        }
    }

    /**
     * Log the list of available tools presented to the LLM
     *
     * @param title Descriptive title for the step
     * @param toolsDescription Description of available tools
     * @param toolsJson JSON representation of available tools
     * @param durationMs Duration of processing this step
     */
    public void logAvailableTools(String title, String toolsDescription, String toolsJson, Long durationMs) {
        logStep(StepType.AVAILABLE_TOOLS, title, toolsDescription, toolsJson, durationMs, true, null, null);
    }

    /**
     * Log a tool execution step with enhanced parameters for success status and error details
     *
     * @param title Descriptive title for the step
     * @param executionDescription Description of tool execution
     * @param executionJson JSON representation of execution details
     * @param durationMs Duration of processing this step
     * @param isSuccess Whether the tool execution was successful
     * @param errorCode Error code if execution failed
     * @param errorMessage Error message if execution failed
     */
    public void logToolExecution(
        String title,
        String executionDescription,
        String executionJson,
        Long durationMs,
        Boolean isSuccess,
        String errorCode,
        String errorMessage
    ) {
        logStep(StepType.TOOL_EXECUTION, title, executionDescription, executionJson, durationMs, isSuccess, errorCode, errorMessage);
    }

    /**
     * Log a tool result step with enhanced parameters for success status and error details
     *
     * @param title Descriptive title for the step
     * @param resultDescription Description of tool result
     * @param resultJson JSON representation of result details
     * @param durationMs Duration of processing this step
     * @param isSuccess Whether the tool execution was successful
     * @param errorCode Error code if execution failed
     * @param errorMessage Error message if execution failed
     */
    public void logToolResult(
        String title,
        String resultDescription,
        String resultJson,
        Long durationMs,
        Boolean isSuccess,
        String errorCode,
        String errorMessage
    ) {
        logStep(StepType.TOOL_RESULT, title, resultDescription, resultJson, durationMs, isSuccess, errorCode, errorMessage);
    }

    /**
     * Log a final response step
     *
     * @param title Descriptive title for the step
     * @param responseDescription Description of the final response
     * @param responseContent The final response content
     * @param durationMs Duration of processing this step
     */
    public void logFinalResponse(String title, String responseDescription, String responseContent, Long durationMs) {
        logStep(StepType.FINAL_RESPONSE, title, responseDescription, responseContent, durationMs, true, null, null);
    }

    /**
     * Log an error step
     *
     * @param title Descriptive title for the step
     * @param errorDescription Description of the error
     * @param errorCode Error code
     * @param errorMessage Detailed error message
     * @param errorDetails JSON representation of error details
     * @param durationMs Duration of processing this step
     */
    public void logError(String title, String errorDescription, String errorCode, String errorMessage, String errorDetails, Long durationMs) {
        logStep(StepType.ERROR, title, errorDescription, errorDetails, durationMs, false, errorCode, errorMessage);
    }

    /**
     * Log a resume approved framework action step.
     * Called by AgentApprovalService when processing approved requests.
     *
     * @param title Descriptive title for the step
     * @param description Description of the action
     * @param actionDetails JSON representation of action details
     * @param durationMs Duration of processing this step
     */
    public void logResumeApprovedFrameworkAction(String title, String description, String actionDetails, Long durationMs) {
        logStep(StepType.RESUME_APPROVED_FRAMEWORK_ACTION, title, description, actionDetails, durationMs, true, null, null);
    }

    /**
     * Log a handle rejected framework action step.
     * Called by AgentApprovalService when processing rejected requests.
     *
     * @param title Descriptive title for the step
     * @param description Description of the action
     * @param actionDetails JSON representation of action details
     * @param durationMs Duration of processing this step
     */
    public void logHandleRejectedFrameworkAction(String title, String description, String actionDetails, Long durationMs) {
        logStep(StepType.HANDLE_REJECTED_FRAMEWORK_ACTION, title, description, actionDetails, durationMs, true, null, null);
    }

    /**
     * Log a step with parent relationship for causality tracking
     *
     * @param stepType The type of step
     * @param title Descriptive title
     * @param description Detailed description
     * @param contentJson JSON content related to the step
     * @param durationMs Duration in milliseconds
     * @param isSuccess Whether the step was successful
     * @param parentStepId The ID of the parent step
     * @param triggeringToolCallId The tool call ID that triggered this step
     */
    public void logStepWithParent(
        StepType stepType,
        String title,
        String description,
        String contentJson,
        Long durationMs,
        Boolean isSuccess,
        Id parentStepId,
        String triggeringToolCallId
    ) {
        try {
            // Get next global step sequence using in-memory counter
            Integer globalStepSequence = getNextGlobalStepSequence();

            // Map enum to picklist value
            String stepTypeValue = mapStepTypeToPicklistValue(stepType);

            // Create the decision step record with causality tracking
            AgentDecisionStep__c step = new AgentDecisionStep__c(
                TurnIdentifier__c = this.turnIdentifier,
                StepType__c = stepTypeValue,
                StepOrder__c = globalStepSequence,
                Title__c = title,
                Description__c = description,
                ContentJson__c = contentJson,
                DurationMs__c = durationMs,
                IsSuccess__c = isSuccess,
                ParentStepId__c = parentStepId
            );

            // Set the AgentExecution lookup field
            step.AgentExecution__c = this.executionId;

            // Add user information if available
            if (this.originalUserId != null) {
                step.put('OriginalUser__c', this.originalUserId);
            }

            // Always set the execution user to the current user
            step.put('ExecutionUser__c', UserInfo.getUserId());

            // Link to triggering tool call if provided
            if (String.isNotBlank(triggeringToolCallId)) {
                step.RelatedToolCallId__c = triggeringToolCallId;
                if (toolCallIdToStepMap.containsKey(triggeringToolCallId)) {
                    step.TriggeringStepId__c = toolCallIdToStepMap.get(triggeringToolCallId);
                }
            }

            // Add to the list of steps to commit
            stepsToCommit.add(step);

            // Track last logged step for causality
            this.lastLoggedStepId = step.Id;

            System.debug(
                LoggingLevel.INFO,
                '[AgentDecisionStepLogger] Collected step with causality: ' +
                    stepTypeValue +
                    ' - ' +
                    title +
                    ' | Parent: ' +
                    parentStepId +
                    ' | Tool Call: ' +
                    triggeringToolCallId +
                    ' | Sequence: ' +
                    globalStepSequence
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AgentDecisionStepLogger] Failed to log step with parent: ' + e.getMessage());
        }
    }

    /**
     * Register a tool call ID for later reference
     * This allows linking tool execution steps back to the LLM response that requested them
     *
     * @param toolCallId The tool call ID from the LLM response
     * @param stepId The step ID that contains this tool call
     */
    public void registerToolCall(String toolCallId, Id stepId) {
        if (String.isNotBlank(toolCallId) && stepId != null) {
            toolCallIdToStepMap.put(toolCallId, stepId);
            System.debug(LoggingLevel.INFO, '[AgentDecisionStepLogger] Registered tool call: ' + toolCallId + ' -> Step: ' + stepId);
        }
    }

    /**
     * Get the ID of the last logged step for causality chains
     *
     * @return The ID of the last logged step
     */
    public Id getLastLoggedStepId() {
        return this.lastLoggedStepId;
    }

    /**
     * Update the execution ID for all collected (but not yet committed) decision steps.
     * This is useful when steps are collected with a temporary execution ID during read-only operations,
     * and need to be linked to a real execution record created later (after callout).
     *
     * @param newExecutionId The new execution ID to set on all collected steps
     */
    public void updateExecutionId(Id newExecutionId) {
        if (newExecutionId == null) {
            System.debug(LoggingLevel.WARN, '[AgentDecisionStepLogger] Cannot update to null execution ID.');
            return;
        }

        // Update the instance variable so future steps use the correct ID
        this.executionId = newExecutionId;

        // Update all steps that have been collected but not yet committed
        for (AgentDecisionStep__c step : stepsToCommit) {
            step.AgentExecution__c = newExecutionId;
        }

        System.debug(
            LoggingLevel.INFO,
            '[AgentDecisionStepLogger] Updated execution ID to ' + newExecutionId + ' for ' + stepsToCommit.size() + ' collected steps.'
        );
    }

    /**
     * Commit all collected steps in a single bulk DML operation
     * This method should be called at the end of the orchestration process
     */
    public void commitSteps() {
        if (stepsToCommit.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[AgentDecisionStepLogger] No steps to commit.');
            return;
        }

        try {
            // Insert all collected steps in a single bulk operation
            insert stepsToCommit;
            System.debug(LoggingLevel.INFO, '[AgentDecisionStepLogger] Committed ' + stepsToCommit.size() + ' decision steps.');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AgentDecisionStepLogger] Failed to commit steps: ' + e.getMessage());
            // We don't throw the exception to avoid disrupting the main agent flow
        }
    }

    /**
     * Private method to create and collect a decision step record in memory
     *
     * @param stepType The type of step
     * @param title Descriptive title
     * @param description Detailed description
     * @param contentJson JSON content related to the step
     * @param durationMs Duration in milliseconds
     * @param isSuccess Whether the step was successful
     * @param errorCode Error code if failed
     * @param errorMessage Error message if failed
     */
    private void logStep(
        StepType stepType,
        String title,
        String description,
        String contentJson,
        Long durationMs,
        Boolean isSuccess,
        String errorCode,
        String errorMessage
    ) {
        try {
            // Get next global step sequence using in-memory counter
            Integer globalStepSequence = getNextGlobalStepSequence();

            // Map enum to picklist value
            String stepTypeValue = mapStepTypeToPicklistValue(stepType);

            // Create the decision step record with the correct lookup field
            AgentDecisionStep__c step = new AgentDecisionStep__c(
                TurnIdentifier__c = this.turnIdentifier,
                StepType__c = stepTypeValue,
                StepOrder__c = globalStepSequence,
                Title__c = title,
                Description__c = description,
                ContentJson__c = contentJson,
                DurationMs__c = durationMs,
                IsSuccess__c = isSuccess,
                ErrorCode__c = errorCode,
                ErrorMessage__c = errorMessage
            );

            // Set the AgentExecution lookup field
            step.AgentExecution__c = this.executionId;

            // Add user information if available
            if (this.originalUserId != null) {
                step.put('OriginalUser__c', this.originalUserId);
            }

            // Always set the execution user to the current user
            step.put('ExecutionUser__c', UserInfo.getUserId());

            // Add to the list of steps to commit
            stepsToCommit.add(step);

            System.debug(
                LoggingLevel.INFO,
                '[AgentDecisionStepLogger] Collected step: ' + stepTypeValue + ' - ' + title + ' with global sequence: ' + globalStepSequence
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AgentDecisionStepLogger] Failed to collect step: ' + e.getMessage());
            // We don't throw the exception to avoid disrupting the main agent flow
        }
    }

    /**
     * Map StepType enum to picklist value
     *
     * @param stepType The enum value
     * @return The corresponding picklist value
     */
    private String mapStepTypeToPicklistValue(StepType stepType) {
        switch on stepType {
            when USER_INPUT {
                return 'User Input';
            }
            when CONTEXT_GATHERING {
                return 'Context Gathering';
            }
            when SYSTEM_PROMPT_CONSTRUCTION {
                return 'System Prompt Construction';
            }
            when LLM_REQUEST {
                return 'LLM Request';
            }
            when LLM_RESPONSE {
                return 'LLM Response';
            }
            when TOOL_SELECTION {
                return 'Tool Selection';
            }
            when TOOL_EXECUTION {
                return 'Tool Execution';
            }
            when TOOL_RESULT {
                return 'Tool Result';
            }
            when AVAILABLE_TOOLS {
                return 'Available Tools';
            }
            when FINAL_RESPONSE {
                return 'Final Response';
            }
            when ERROR {
                return 'Error';
            }
            when RESUME_APPROVED_FRAMEWORK_ACTION {
                return 'Resume Approved Framework Action';
            }
            when HANDLE_REJECTED_FRAMEWORK_ACTION {
                return 'Handle Rejected Framework Action';
            }
        }
        return 'Error'; // Default fallback
    }

    /**
     * Private method to create and collect a decision step record in memory with support for formatted context
     *
     * @param stepType The type of step
     * @param title Descriptive title
     * @param description Detailed description
     * @param contentJson JSON content related to the step
     * @param formattedContext Formatted context as presented to the LLM
     * @param durationMs Duration in milliseconds
     * @param isSuccess Whether the step was successful
     * @param errorCode Error code if failed
     * @param errorMessage Error message if failed
     */
    private void logStepWithContextFormatting(
        StepType stepType,
        String title,
        String description,
        String contentJson,
        String formattedContext,
        Long durationMs,
        Boolean isSuccess,
        String errorCode,
        String errorMessage
    ) {
        try {
            // Get next global step sequence using in-memory counter
            Integer globalStepSequence = getNextGlobalStepSequence();

            // Map enum to picklist value
            String stepTypeValue = mapStepTypeToPicklistValue(stepType);

            // Create the decision step record with the correct lookup field
            AgentDecisionStep__c step = new AgentDecisionStep__c(
                TurnIdentifier__c = this.turnIdentifier,
                StepType__c = stepTypeValue,
                StepOrder__c = globalStepSequence,
                Title__c = title,
                Description__c = description,
                ContentJson__c = contentJson,
                DurationMs__c = durationMs,
                IsSuccess__c = isSuccess,
                ErrorCode__c = errorCode,
                ErrorMessage__c = errorMessage
            );

            // Set the AgentExecution lookup field
            step.AgentExecution__c = this.executionId;

            // Add user information if available
            if (this.originalUserId != null) {
                step.put('OriginalUser__c', this.originalUserId);
            }

            // Always set the execution user to the current user
            step.put('ExecutionUser__c', UserInfo.getUserId());

            // Add the formatted context if provided
            if (String.isNotBlank(formattedContext)) {
                step.put('FormattedContext__c', formattedContext);
            }

            // Add to the list of steps to commit
            stepsToCommit.add(step);

            System.debug(
                LoggingLevel.INFO,
                '[AgentDecisionStepLogger] Collected step: ' + stepTypeValue + ' - ' + title + ' with global sequence: ' + globalStepSequence
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AgentDecisionStepLogger] Failed to collect step: ' + e.getMessage());
            // We don't throw the exception to avoid disrupting the main agent flow
        }
    }

    /**
     * Private method to create and collect a decision step record in memory with support for formatted context
     * This is used specifically for steps that need to store primary content in FormattedContext__c
     *
     * @param stepType The type of step
     * @param title Descriptive title
     * @param description Detailed description
     * @param formattedContext Formatted context as presented to the LLM or primary content
     * @param durationMs Duration in milliseconds
     * @param isSuccess Whether the step was successful
     * @param errorCode Error code if failed
     * @param errorMessage Error message if failed
     */
    private void logStepWithFormattedContext(
        StepType stepType,
        String title,
        String description,
        String formattedContext,
        Long durationMs,
        Boolean isSuccess,
        String errorCode,
        String errorMessage
    ) {
        try {
            // Get next global step sequence using in-memory counter
            Integer globalStepSequence = getNextGlobalStepSequence();

            // Map enum to picklist value
            String stepTypeValue = mapStepTypeToPicklistValue(stepType);

            // Create the decision step record with the correct lookup field
            AgentDecisionStep__c step = new AgentDecisionStep__c(
                TurnIdentifier__c = this.turnIdentifier,
                StepType__c = stepTypeValue,
                StepOrder__c = globalStepSequence,
                Title__c = title,
                Description__c = description,
                DurationMs__c = durationMs,
                IsSuccess__c = isSuccess,
                ErrorCode__c = errorCode,
                ErrorMessage__c = errorMessage
            );

            // Set the AgentExecution lookup field
            step.AgentExecution__c = this.executionId;

            // Add user information if available
            if (this.originalUserId != null) {
                step.put('OriginalUser__c', this.originalUserId);
            }

            // Always set the execution user to the current user
            step.put('ExecutionUser__c', UserInfo.getUserId());

            // Add the formatted context as the primary content
            if (String.isNotBlank(formattedContext)) {
                step.put('FormattedContext__c', formattedContext);
            }

            // Add to the list of steps to commit
            stepsToCommit.add(step);

            System.debug(
                LoggingLevel.INFO,
                '[AgentDecisionStepLogger] Collected step: ' + stepTypeValue + ' - ' + title + ' with global sequence: ' + globalStepSequence
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AgentDecisionStepLogger] Failed to collect step: ' + e.getMessage());
            // We don't throw the exception to avoid disrupting the main agent flow
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
    private Decimal calculateCost(String modelIdentifier, Integer promptTokens, Integer completionTokens) {
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
        System.debug(LoggingLevel.WARN, '[AgentDecisionStepLogger] No pricing found for model: ' + modelIdentifier);
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
            System.debug(LoggingLevel.DEBUG, '[AgentDecisionStepLogger] Initialized pricing cache with ' + pricingCache.size() + ' models');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AgentDecisionStepLogger] Failed to initialize pricing cache: ' + e.getMessage());
            // Initialize empty cache to avoid repeated failures
            isPricingCacheInitialized = true;
        }
    }
}
