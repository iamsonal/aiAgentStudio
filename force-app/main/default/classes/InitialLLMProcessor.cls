/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * InitialLLMProcessor handles the initial LLM processing for all non-conversational agent executions.
 * This class consolidates the LLM processing logic for Email, Scheduled, DataChange, Batch, and API triggers,
 * eliminating code duplication and providing a single, maintainable entry point.
 *
 * Responsibilities:
 *   - Loads existing AgentExecution__c records created in the DML phase
 *   - Formats trigger-specific content for LLM processing
 *   - Executes LLM interactions with proper error handling
 *   - Routes results through the orchestration pipeline
 *   - Updates execution status and handles failures
 */
public class InitialLLMProcessor {

    /**
     * Exception thrown when LLM processing fails.
     */
    public class LLMProcessingException extends Exception {}

    /**
     * Data structure for execution processing context.
     */
    public class ProcessingContext {
        public Id executionId;
        public Id agentDefinitionId;
        public String triggerSource;
        public String turnIdentifier;
        public Id userId;
        public Map<String, Object> triggerData;
        public String initialMessage;
    }

    /**
     * Processes an agent execution through the LLM pipeline.
     * This is the main entry point for all non-conversational execution types.
     *
     * @param executionId The AgentExecution__c record ID
     * @param triggerSource The source that initiated this execution (Email, Schedule, DataChange, etc.)
     * @param triggerData Additional data specific to the trigger source
     */
    public static void processExecution(Id executionId, String triggerSource, Map<String, Object> triggerData) {
        String logPrefix = '[InitialLLMProcessor.' + triggerSource + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing execution: ' + executionId);

        try {
            // Load the execution context
            ProcessingContext context = loadExecutionContext(executionId, triggerSource, triggerData);

            // Format the initial message based on trigger source
            context.initialMessage = formatInitialMessage(context);

            // Execute LLM processing
            executeLLMProcessing(context);

            System.debug(LoggingLevel.INFO, logPrefix + 'Successfully processed execution: ' + executionId);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing execution: ' + e.getMessage() + '\nStack Trace: ' + e.getStackTraceString());

            // Mark execution as failed
            markExecutionAsFailed(executionId, triggerSource, e.getMessage());
            throw new LLMProcessingException('Failed to process ' + triggerSource + ' execution: ' + e.getMessage());
        }
    }

    /**
     * Loads the execution context from the database and trigger data.
     *
     * @param executionId The execution ID
     * @param triggerSource The trigger source
     * @param triggerData The trigger-specific data
     * @return ProcessingContext populated context
     */
    private static ProcessingContext loadExecutionContext(Id executionId, String triggerSource, Map<String, Object> triggerData) {
        // Load the existing execution record
        AgentExecution__c execution = [
            SELECT Id, CurrentTurnIdentifier__c, AIAgentDefinition__c,
                   AIAgentDefinition__r.LLMConfiguration__c, User__c, TriggerPayload__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];

        ProcessingContext context = new ProcessingContext();
        context.executionId = executionId;
        context.agentDefinitionId = execution.AIAgentDefinition__c;
        context.triggerSource = triggerSource;
        context.turnIdentifier = execution.CurrentTurnIdentifier__c;
        context.userId = execution.User__c;
        context.triggerData = triggerData;

        return context;
    }

    /**
     * Formats the initial message for LLM processing based on the trigger source.
     *
     * @param context The processing context
     * @return String formatted message for LLM
     */
    private static String formatInitialMessage(ProcessingContext context) {
        switch on context.triggerSource {
            when 'Email' {
                return formatEmailMessage(context.triggerData);
            }
            when 'Schedule' {
                return formatScheduledMessage(context.triggerData);
            }
            when 'DataChange' {
                return formatDataChangeMessage(context.triggerData);
            }
            when 'BatchJob' {
                return formatBatchMessage(context.triggerData);
            }
            when 'API' {
                return formatAPIMessage(context.triggerData);
            }
            when else {
                return formatGenericMessage(context.triggerSource, context.triggerData);
            }
        }
    }

    /**
     * Formats email trigger data for LLM processing.
     */
    private static String formatEmailMessage(Map<String, Object> triggerData) {
        List<String> messageParts = new List<String>();

        messageParts.add('I received an email that needs processing:');
        messageParts.add('');
        messageParts.add('From: ' + (String) triggerData.get('fromAddress'));
        messageParts.add('To: ' + (String) triggerData.get('toAddress'));
        messageParts.add('Subject: ' + (String) triggerData.get('emailSubject'));

        Integer attachmentCount = (Integer) triggerData.get('attachmentCount');
        if (attachmentCount != null && attachmentCount > 0) {
            messageParts.add('Attachments: ' + attachmentCount + ' file(s)');
        }

        messageParts.add('');
        messageParts.add('Email Content:');
        messageParts.add((String) triggerData.get('emailBody') ?? 'No content');
        messageParts.add('');
        messageParts.add('Please analyze this email and determine the appropriate response or action to take.');

        return String.join(messageParts, '\n');
    }

    /**
     * Formats scheduled task trigger data for LLM processing.
     */
    private static String formatScheduledMessage(Map<String, Object> triggerData) {
        List<String> messageParts = new List<String>();

        messageParts.add('A scheduled task has been triggered:');
        messageParts.add('');
        messageParts.add('Schedule Name: ' + (String) triggerData.get('scheduleName'));
        messageParts.add('Scheduled Time: ' + (String) triggerData.get('scheduledTime'));

        String taskDescription = (String) triggerData.get('taskDescription');
        if (String.isNotBlank(taskDescription)) {
            messageParts.add('Task Description: ' + taskDescription);
        }

        messageParts.add('');
        messageParts.add('Please execute the scheduled task and provide a summary of actions taken.');

        return String.join(messageParts, '\n');
    }

    /**
     * Formats data change trigger data for LLM processing.
     */
    private static String formatDataChangeMessage(Map<String, Object> triggerData) {
        List<String> messageParts = new List<String>();

        messageParts.add('A data change event has occurred:');
        messageParts.add('');
        messageParts.add('Record ID: ' + (String) triggerData.get('triggerRecordId'));
        messageParts.add('Change Type: ' + (String) triggerData.get('changeType'));

        Map<String, Object> recordData = (Map<String, Object>) triggerData.get('recordData');
        if (recordData != null && !recordData.isEmpty()) {
            messageParts.add('');
            messageParts.add('Record Data:');
            messageParts.add(JSON.serializePretty(recordData));
        }

        messageParts.add('');
        messageParts.add('Please analyze this data change and determine if any actions are required.');

        return String.join(messageParts, '\n');
    }

    /**
     * Formats batch job trigger data for LLM processing.
     */
    private static String formatBatchMessage(Map<String, Object> triggerData) {
        List<String> messageParts = new List<String>();

        String processingMode = (String) triggerData.get('processingMode');
        String batchJobName = (String) triggerData.get('batchJobName');

        messageParts.add('A batch processing job has been initiated:');
        messageParts.add('');
        messageParts.add('Batch Job Name: ' + batchJobName);
        messageParts.add('Processing Mode: ' + processingMode);

        // Format message based on processing mode
        if ('Individual'.equals(processingMode)) {
            messageParts.add('Record ID: ' + (String) triggerData.get('recordId'));
            messageParts.add('Record Type: ' + (String) triggerData.get('recordType'));

            Map<String, Object> recordData = (Map<String, Object>) triggerData.get('recordData');
            if (recordData != null && !recordData.isEmpty()) {
                messageParts.add('');
                messageParts.add('Record Data:');
                messageParts.add(JSON.serializePretty(recordData));
            }

            messageParts.add('');
            messageParts.add('Please analyze this individual record and determine the appropriate processing actions.');

        } else if ('Grouped'.equals(processingMode)) {
            Integer recordCount = (Integer) triggerData.get('recordCount');
            List<Object> recordIds = (List<Object>) triggerData.get('recordIds');

            messageParts.add('Record Count: ' + recordCount);
            messageParts.add('Record IDs: ' + String.join((List<String>) recordIds, ', '));

            List<Object> recordsData = (List<Object>) triggerData.get('recordsData');
            if (recordsData != null && !recordsData.isEmpty()) {
                messageParts.add('');
                messageParts.add('Records Data:');
                messageParts.add(JSON.serializePretty(recordsData));
            }

            messageParts.add('');
            messageParts.add('Please analyze this group of records and determine batch processing actions.');

        } else if ('Summary'.equals(processingMode)) {
            Map<String, Object> summaryData = (Map<String, Object>) triggerData.get('summaryData');

            messageParts.add('');
            messageParts.add('Batch Summary:');
            if (summaryData != null) {
                messageParts.add(JSON.serializePretty(summaryData));
            }

            messageParts.add('');
            messageParts.add('Please analyze this batch summary and provide insights or recommendations.');

        } else {
            // Generic batch processing
            Integer totalItems = (Integer) triggerData.get('totalItems');
            Integer batchSize = (Integer) triggerData.get('batchSize');

            if (totalItems != null) {
                messageParts.add('Total Items: ' + totalItems);
            }
            if (batchSize != null) {
                messageParts.add('Batch Size: ' + batchSize);
            }

            messageParts.add('');
            messageParts.add('Please process this batch job and provide status updates.');
        }

        return String.join(messageParts, '\n');
    }

    /**
     * Formats API trigger data for LLM processing.
     */
    private static String formatAPIMessage(Map<String, Object> triggerData) {
        List<String> messageParts = new List<String>();

        messageParts.add('An API request has been received:');
        messageParts.add('');

        String message = (String) triggerData.get('message');
        if (String.isNotBlank(message)) {
            messageParts.add('Request Message: ' + message);
        }

        String endpoint = (String) triggerData.get('endpoint');
        if (String.isNotBlank(endpoint)) {
            messageParts.add('Endpoint: ' + endpoint);
        }

        messageParts.add('');
        messageParts.add('Please process this API request and provide an appropriate response.');

        return String.join(messageParts, '\n');
    }

    /**
     * Formats generic trigger data for unknown trigger sources.
     */
    private static String formatGenericMessage(String triggerSource, Map<String, Object> triggerData) {
        List<String> messageParts = new List<String>();

        messageParts.add('A ' + triggerSource + ' trigger has been activated:');
        messageParts.add('');

        if (triggerData != null && !triggerData.isEmpty()) {
            messageParts.add('Trigger Data:');
            messageParts.add(JSON.serializePretty(triggerData));
        }

        messageParts.add('');
        messageParts.add('Please analyze this trigger and determine the appropriate actions to take.');

        return String.join(messageParts, '\n');
    }

    /**
     * Executes the LLM processing pipeline.
     *
     * @param context The processing context
     */
    private static void executeLLMProcessing(ProcessingContext context) {
        String logPrefix = '[InitialLLMProcessor.executeLLMProcessing] ';

        // Initialize decision logger
        AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(
            context.executionId,
            context.turnIdentifier,
            context.userId
        );

        // Create user message data for LLM processing
        LLMInteractionService.MessageData userMessageData = new LLMInteractionService.MessageData();
        userMessageData.role = AIAgentConstants.ROLE_USER;
        userMessageData.content = context.initialMessage;

        // Load agent configuration
        AIAgentDefinition__c agentConfig = [
            SELECT Id, LLMConfiguration__c
            FROM AIAgentDefinition__c
            WHERE Id = :context.agentDefinitionId
            LIMIT 1
        ];

        // Create LLM interaction service
        LLMInteractionService interactionService = new LLMInteractionService(
            context.executionId,
            context.userId,
            context.agentDefinitionId,
            agentConfig.LLMConfiguration__c,
            context.turnIdentifier,
            1, // Turn count
            null, // currentPageRecordId
            false, // isFinalErrorTurn
            decisionLogger
        );

        // Execute LLM interaction (callouts are allowed in this async context)
        LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(userMessageData);

        if (llmResult == null) {
            throw new LLMProcessingException('LLM interaction returned null result');
        }

        // Process the LLM result through orchestration service
        OrchestrationService orchestrationService = new OrchestrationService();
        String outcome = orchestrationService.processLlmResult(
            llmResult,
            context.executionId,
            context.userId,
            context.userId, // executionUserId
            context.agentDefinitionId,
            context.turnIdentifier,
            1, // currentTurnCount
            userMessageData,
            null, // currentPageRecordId
            decisionLogger
        );

        System.debug(LoggingLevel.INFO, logPrefix + 'LLM processing completed. Outcome: ' + outcome);
    }

    /**
     * Marks an execution as failed with appropriate error information.
     *
     * @param executionId The execution ID
     * @param triggerSource The trigger source
     * @param errorMessage The error message
     */
    private static void markExecutionAsFailed(Id executionId, String triggerSource, String errorMessage) {
        try {
            ExecutionContextService executionContextService = new ExecutionContextService();
            executionContextService.updateStatus(
                executionId,
                'Failed',
                AIAgentConstants.STATUS_FAILED,
                null,
                triggerSource + ' processing failed: ' + errorMessage
            );
        } catch (Exception updateEx) {
            System.debug(LoggingLevel.ERROR, '[InitialLLMProcessor] Failed to update execution status: ' + updateEx.getMessage());
        }
    }
}
