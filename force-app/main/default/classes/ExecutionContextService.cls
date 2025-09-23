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
 * Replaces ChatSessionStateService to support all execution types: conversational, batch, scheduled, email, and triggered.
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
     * Retrieves an AgentExecution__c record with all relevant fields.
     *
     * @param executionId The execution ID to retrieve
     * @return AgentExecution__c record or null if not found
     */
    public AgentExecution__c getExecution(Id executionId) {
        String logPrefix = LOG_PREFIX + '[getExecution] ';

        try {
            List<AgentExecution__c> executions = [
                SELECT
                    Id,
                    ExecutionType__c,
                    AIAgentDefinition__c,
                    TriggerSource__c,
                    TriggerPayload__c,
                    ExecutionStatus__c,
                    StartTime__c,
                    EndTime__c,
                    LastActivityTime__c,
                    CurrentTurnIdentifier__c,
                    ProcessingStatus__c,
                    ContextHistoryJson__c,
                    ConversationSummary__c,
                    ParentExecution__c,
                    SourceRecordId__c,
                    ExecutionMetadata__c,
                    User__c,
                    ServiceUser__c,
                    AIAgentDefinition__r.Name,
                    AIAgentDefinition__r.DeveloperName__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            if (executions.isEmpty()) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Execution not found: ' + executionId);
                return null;
            }

            return executions[0];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve execution: ' + e.getMessage());
            throw new ExecutionContextException('Failed to retrieve execution: ' + e.getMessage());
        }
    }

    /**
     * Locks an execution for atomic updates to prevent concurrent modifications.
     *
     * @param executionId The execution to lock
     * @param expectedTurnIdentifier Expected turn identifier for stale check
     * @return AgentExecution__c record with FOR UPDATE lock
     * @throws ExecutionContextException if execution is stale or not found
     */
    public AgentExecution__c lockExecution(Id executionId, String expectedTurnIdentifier) {
        String logPrefix = LOG_PREFIX + '[lockExecution] ';

        try {
            List<AgentExecution__c> executions = [
                SELECT Id, ExecutionStatus__c, ProcessingStatus__c, CurrentTurnIdentifier__c, LastActivityTime__c, ExecutionType__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
                FOR UPDATE
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

            System.debug(LoggingLevel.INFO, logPrefix + 'Locked execution: ' + executionId);
            return execution;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to lock execution: ' + e.getMessage());
            throw new ExecutionContextException('Failed to lock execution: ' + e.getMessage());
        }
    }

    /**
     * Completes an execution successfully.
     *
     * @param executionId The execution to complete
     * @param finalMessage Optional final message or result
     */
    public void completeExecution(Id executionId, String finalMessage) {
        String logPrefix = LOG_PREFIX + '[completeExecution] ';

        try {
            AgentExecution__c execution = new AgentExecution__c(
                Id = executionId,
                ExecutionStatus__c = 'Completed',
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                EndTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now()
            );

            if (String.isNotBlank(finalMessage)) {
                execution.ConversationSummary__c = finalMessage;
            }

            update execution;

            System.debug(LoggingLevel.INFO, logPrefix + 'Completed execution: ' + executionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to complete execution: ' + e.getMessage());
            throw new ExecutionContextException('Failed to complete execution: ' + e.getMessage());
        }
    }

    /**
     * Marks an execution as failed with error details.
     *
     * @param executionId The execution to fail
     * @param errorMessage The error message
     * @param errorCode Optional error code
     */
    public void failExecution(Id executionId, String errorMessage, String errorCode) {
        String logPrefix = LOG_PREFIX + '[failExecution] ';

        try {
            Map<String, Object> errorMetadata = new Map<String, Object>{
                'errorMessage' => errorMessage,
                'errorCode' => errorCode,
                'failureTime' => Datetime.now()
            };

            AgentExecution__c execution = new AgentExecution__c(
                Id = executionId,
                ExecutionStatus__c = 'Failed',
                ProcessingStatus__c = AIAgentConstants.STATUS_FAILED,
                EndTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                ExecutionMetadata__c = JSON.serialize(errorMetadata)
            );

            update execution;

            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed execution: ' + executionId + ' Error: ' + errorMessage);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to mark execution as failed: ' + e.getMessage());
            throw new ExecutionContextException('Failed to mark execution as failed: ' + e.getMessage());
        }
    }

    /**
     * Updates the context history for an execution.
     *
     * @param executionId The execution to update
     * @param contextHistoryJson The new context history JSON
     */
    public void updateContextHistory(Id executionId, String contextHistoryJson) {
        String logPrefix = LOG_PREFIX + '[updateContextHistory] ';

        try {
            AgentExecution__c execution = new AgentExecution__c(
                Id = executionId,
                ContextHistoryJson__c = contextHistoryJson,
                LastActivityTime__c = Datetime.now()
            );

            update execution;

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Updated context history for execution: ' + executionId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update context history: ' + e.getMessage());
            throw new ExecutionContextException('Failed to update context history: ' + e.getMessage());
        }
    }

    /**
     * Finds the most recent execution for a user and agent.
     * Used for conversational executions to resume sessions.
     *
     * @param userId The user ID
     * @param agentDefinitionId The agent definition ID
     * @param sourceRecordId Optional source record ID for context
     * @return Most recent AgentExecution__c or null if none found
     */
    public AgentExecution__c getMostRecentExecution(Id userId, Id agentDefinitionId, Id sourceRecordId) {
        String logPrefix = LOG_PREFIX + '[getMostRecentExecution] ';

        try {
            String query =
                'SELECT Id, ExecutionType__c, ExecutionStatus__c, LastActivityTime__c, ' +
                'ContextHistoryJson__c, ConversationSummary__c, SourceRecordId__c ' +
                'FROM AgentExecution__c ' +
                'WHERE User__c = :userId AND AIAgentDefinition__c = :agentDefinitionId ' +
                'AND ExecutionType__c = \'Conversational\' ';

            if (sourceRecordId != null) {
                query += 'AND SourceRecordId__c = :sourceRecordId ';
            }

            query += 'ORDER BY LastActivityTime__c DESC LIMIT 1';

            List<AgentExecution__c> executions = Database.query(query);

            if (executions.isEmpty()) {
                System.debug(LoggingLevel.INFO, logPrefix + 'No recent execution found for user: ' + userId);
                return null;
            }

            return executions[0];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to find recent execution: ' + e.getMessage());
            throw new ExecutionContextException('Failed to find recent execution: ' + e.getMessage());
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
