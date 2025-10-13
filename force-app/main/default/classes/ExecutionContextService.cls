/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ExecutionContextService manages the lifecycle and state of AgentExecution__c records in the unified agentic framework.
 * Support all execution types: conversational, batch, scheduled, email, and triggered.
 *
 * Responsibilities:
 *   - Create and manage AgentExecution__c records for all execution patterns
 *   - Update execution status and state throughout the lifecycle
 *   - Provide unified state management across different execution types
 *   - Handle execution completion, failure, and cleanup
 *   - Support both synchronous and asynchronous execution patterns
 *
 * This service abstracts execution state management from the specific execution type,
 * enabling consistent behavior across conversational, batch, scheduled, and triggered executions.
 */
public inherited sharing class ExecutionContextService {
    // --- CONSTANTS ---
    private static final String LOG_PREFIX = '[ExecutionContextService] ';

    // --- EXCEPTIONS ---
    public class ExecutionContextException extends AIAgentException {
    }

    /**
     * Creates a new AgentExecution__c record for any execution type.
     *
     * @param executionType The type of execution (Conversational, Batch, Scheduled, Email, Trigger, API)
     * @param agentDefinitionId The AI agent definition to execute
     * @param triggerSource The source that initiated this execution
     * @param triggerPayload JSON payload from the trigger source
     * @param sourceRecordId Optional record ID that is the primary context
     * @param userId The user context for this execution
     * @param serviceUserId Optional service user for elevated permissions
     * @return Id of the created AgentExecution__c record
     */
    public Id createExecution(
        String executionType,
        Id agentDefinitionId,
        String triggerSource,
        String triggerPayload,
        Id sourceRecordId,
        Id userId,
        Id serviceUserId
    ) {
        String logPrefix = LOG_PREFIX + '[createExecution] ';

        try {
            String turnIdentifier = generateTurnIdentifier();

            AgentExecution__c execution = new AgentExecution__c(
                ExecutionType__c = executionType,
                AIAgentDefinition__c = agentDefinitionId,
                TriggerSource__c = triggerSource,
                TriggerPayload__c = triggerPayload,
                ExecutionStatus__c = 'Pending',
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                SourceRecordId__c = sourceRecordId,
                CurrentTurnIdentifier__c = turnIdentifier,
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                User__c = userId,
                ServiceUser__c = serviceUserId
            );

            insert execution;

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Created AgentExecution__c: ' + execution.Id + ' Type: ' + executionType + ' Agent: ' + agentDefinitionId
            );

            return execution.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create execution: ' + e.getMessage());
            throw new ExecutionContextException('Failed to create agent execution: ' + e.getMessage());
        }
    }

    /**
     * Updates the status of an AgentExecution__c record.
     *
     * @param executionId The execution to update
     * @param executionStatus The new execution status
     * @param processingStatus The new processing status (optional)
     * @param turnIdentifier The current turn identifier (optional)
     * @param statusMessage Additional status message (optional)
     */
    public void updateStatus(Id executionId, String executionStatus, String processingStatus, String turnIdentifier, String statusMessage) {
        String logPrefix = LOG_PREFIX + '[updateStatus] ';

        try {
            AgentExecution__c execution = new AgentExecution__c(
                Id = executionId,
                ExecutionStatus__c = executionStatus,
                LastActivityTime__c = Datetime.now()
            );

            if (String.isNotBlank(processingStatus)) {
                execution.ProcessingStatus__c = processingStatus;
            }

            if (String.isNotBlank(turnIdentifier)) {
                execution.CurrentTurnIdentifier__c = turnIdentifier;
            }

            // Set end time for terminal states
            if (executionStatus == 'Completed' || executionStatus == 'Failed' || executionStatus == 'Cancelled') {
                execution.EndTime__c = Datetime.now();
            }

            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Updated execution ' + executionId + ' to status: ' + executionStatus);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution status: ' + e.getMessage());
            throw new ExecutionContextException('Failed to update execution status: ' + e.getMessage());
        }
    }

    /**
     * Validates and retrieves an execution record, checking for stale state.
     * Does NOT lock the record. Use this to validate the execution state matches the expected turn identifier
     * before processing to prevent race conditions from stale async jobs.
     *
     * @param executionId The execution to validate and retrieve
     * @param expectedTurnIdentifier Expected turn identifier for stale check
     * @return AgentExecution__c record
     * @throws ExecutionContextException if execution is stale or not found
     */
    public AgentExecution__c validateAndGetExecution(Id executionId, String expectedTurnIdentifier) {
        String logPrefix = LOG_PREFIX + '[validateAndGetExecution] ';

        try {
            List<AgentExecution__c> executions = [
                SELECT Id, ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c, LastActivityTime__c, ExecutionType__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (executions.isEmpty()) {
                throw new ExecutionContextException('Execution not found: ' + executionId);
            }

            AgentExecution__c execution = executions[0];

            // Check for stale execution if turn identifier provided
            if (String.isNotBlank(expectedTurnIdentifier) && !expectedTurnIdentifier.equals(execution.CurrentTurnIdentifier__c)) {
                throw new ExecutionContextException(
                    'Stale execution detected. Expected turn: ' + expectedTurnIdentifier + ', Actual: ' + execution.CurrentTurnIdentifier__c
                );
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Validated execution: ' + executionId);
            return execution;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to validate execution: ' + e.getMessage());
            throw new ExecutionContextException('Failed to validate execution: ' + e.getMessage());
        }
    }

    /**
     * Generates a unique turn identifier for execution tracking.
     *
     * @return String unique turn identifier
     */
    private String generateTurnIdentifier() {
        return 'turn_' + Datetime.now().getTime() + '_' + Math.round(Math.random() * 1000);
    }
}
