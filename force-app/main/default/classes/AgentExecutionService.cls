/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AgentExecutionService is the single, unified entry point for all agent execution initiations in the AI Agent Framework.
 * This service replaces the scattered initialization logic across AIAssistantController, AIAgentRestService, and
 * InboundEmailHandler with a centralized, type-aware execution flow.
 *
 * Responsibilities:
 *   - Provides the single startExecution() method for all agent types
 *   - Uses OrchestratorFactory to delegate to the appropriate agent-type-specific orchestrator
 *   - Standardizes execution initiation across conversational, batch, email, and autonomous agents
 *   - Enforces DML-before-callout pattern through orchestrator delegation
 *   - Provides clear error handling and operational transparency
 *
 * Design:
 *   - All execution types flow through startExecution(agentDeveloperName, ExecutionPayload)
 *   - Agent's AgentType__c determines which orchestrator handles the execution
 *   - Each orchestrator implements IAgentOrchestrator.initiate() to create records and enqueue async work
 *   - Async work is processed via orchestrator's processAsyncResult() method
 */
public class AgentExecutionService {
    private static final String LOG_PREFIX = '[AgentExecutionService] ';

    /**
     * Unified entry point for initiating any agent execution.
     * This method delegates to the appropriate orchestrator based on the agent's AgentType__c field.
     *
     * @param agentDeveloperName The developer name of the agent to execute
     * @param payload            ExecutionPayload containing all context and input data
     * @return                   ExecutionResult containing the execution ID and status
     * @throws                   AgentOrchestratorException for validation or configuration errors
     */
    public static ExecutionResult startExecution(String agentDeveloperName, ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting unified agent execution');

        try {
            // Validate inputs
            if (String.isBlank(agentDeveloperName)) {
                throw new AgentOrchestratorException('Agent developer name is required');
            }
            if (payload == null) {
                throw new AgentOrchestratorException('Execution payload is required');
            }
            payload.validate();

            // Get the appropriate orchestrator for this agent type
            IAgentOrchestrator orchestrator = OrchestratorFactory.getOrchestrator(agentDeveloperName);

            // Delegate to orchestrator for type-specific execution logic
            ExecutionResult result = orchestrator.initiate(agentDeveloperName, payload);

            System.debug(LoggingLevel.INFO, logPrefix + 'Execution initiated successfully. ExecutionId=' + result.executionId + ', Status=' + result.status);
            return result;

        } catch (AgentOrchestratorException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Orchestration error: ' + e.getMessage());
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString());
            throw new AgentOrchestratorException('Failed to start execution: ' + e.getMessage());
        }
    }

    /**
     * ExecutionPayload encapsulates all data needed to initiate an agent execution.
     * Different agent types may use different subsets of these fields.
     */
    public class ExecutionPayload {
        // Common fields for all agent types
        @AuraEnabled public Id userId { get; set; }                // The user initiating the execution
        @AuraEnabled public Id serviceUserId { get; set; }         // Optional service user for elevated permissions
        @AuraEnabled public String triggerSource { get; set; }     // Source that triggered this execution (e.g., 'Chat', 'Email', 'API')
        @AuraEnabled public Id sourceRecordId { get; set; }        // Optional source record context

        // Conversational-specific fields
        @AuraEnabled public String userMessage { get; set; }       // User's message content (for conversational)
        @AuraEnabled public Id currentRecordId { get; set; }       // Current page record context (for conversational)
        @AuraEnabled public String turnIdentifier { get; set; }    // Turn identifier (for conversational)
        @AuraEnabled public Id existingExecutionId { get; set; }   // For continuing existing execution (conversational)

        // Email-specific fields
        @AuraEnabled public String emailSubject { get; set; }
        @AuraEnabled public String emailBody { get; set; }
        @AuraEnabled public String emailFromAddress { get; set; }
        @AuraEnabled public String emailToAddress { get; set; }
        @AuraEnabled public List<String> emailCcAddresses { get; set; }
        @AuraEnabled public Map<String, Object> emailHeaders { get; set; }
        @AuraEnabled public List<EmailAttachment> emailAttachments { get; set; }

        // Batch-specific fields
        @AuraEnabled public List<Id> batchRecordIds { get; set; }  // Records to process in batch
        @AuraEnabled public String batchQuery { get; set; }        // SOQL query for batch processing
        @AuraEnabled public Map<String, Object> batchParameters { get; set; } // Additional batch parameters

        // Autonomous-specific fields
        @AuraEnabled public Map<String, Object> autonomousContext { get; set; } // Context for autonomous execution
        @AuraEnabled public String autonomousGoal { get; set; }    // Goal or objective for autonomous agent

        // Generic trigger payload (for non-standard triggers)
        @AuraEnabled public Map<String, Object> customPayload { get; set; }

        /**
         * Validates that required fields are present based on the payload type.
         * @throws AgentOrchestratorException if validation fails
         */
        public void validate() {
            if (userId == null) {
                throw new AgentOrchestratorException('UserId is required in execution payload');
            }
            if (String.isBlank(triggerSource)) {
                throw new AgentOrchestratorException('TriggerSource is required in execution payload');
            }
        }
    }

    /**
     * EmailAttachment encapsulates email attachment data for email-triggered agents.
     */
    public class EmailAttachment {
        @AuraEnabled public String fileName { get; set; }
        @AuraEnabled public String contentType { get; set; }
        @AuraEnabled public Integer fileSize { get; set; }
        @AuraEnabled public Blob fileContent { get; set; }
        @AuraEnabled public String description { get; set; }
    }

    /**
     * ExecutionResult encapsulates the result of an execution initiation.
     */
    public class ExecutionResult {
        @AuraEnabled public Id executionId { get; set; }          // The created AgentExecution__c ID
        @AuraEnabled public String status { get; set; }           // Execution status (e.g., 'Processing', 'Queued')
        @AuraEnabled public String message { get; set; }          // Human-readable status message
        @AuraEnabled public Boolean success { get; set; }         // Whether initiation succeeded
        @AuraEnabled public String errorMessage { get; set; }     // Error message if failed

        public ExecutionResult(Id executionId, String status, String message) {
            this.executionId = executionId;
            this.status = status;
            this.message = message;
            this.success = true;
        }

        public ExecutionResult(String errorMessage) {
            this.success = false;
            this.errorMessage = errorMessage;
        }
    }
}
