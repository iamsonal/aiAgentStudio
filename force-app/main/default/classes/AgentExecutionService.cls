/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Unified entry point for all agent execution initiations in the AI Agent Framework.
 * Handles service user context switching and delegates to appropriate orchestrators.
 */
public class AgentExecutionService {
    private static final String LOG_PREFIX = '[AgentExecutionService] ';

    // Orchestrator mapping cache
    @TestVisible
    private static Map<String, AgentOrchestratorMapping__mdt> orchestratorMappingCache;
    @TestVisible
    private static Boolean isMappingCacheInitialized = false;

    /**
     * Initiates agent execution with service user context switching when required.
     *
     * @param agentDeveloperName Agent developer name
     * @param payload            Execution payload
     * @return                   Execution result
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

            // Check if service user context switch is required
            // We query the agent definition here to make the decision before delegating to orchestrator
            AIAgentDefinition__c agentDef = getAgentDefinitionForContextCheck(agentDeveloperName);

            if (agentDef.RequiresServiceUserContext__c && payload.isInServiceUserContext != true) {
                // Service user context required but we're not in it yet - route through REST API
                System.debug(LoggingLevel.INFO, logPrefix + 'Service user context required - routing through REST API');
                return routeThroughRestApi(agentDef, payload, logPrefix);
            }

            // Either service user context not required, or we're already in it - proceed directly
            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    'Processing in current context (ServiceUserRequired=' +
                    agentDef.RequiresServiceUserContext__c +
                    ', InServiceContext=' +
                    (payload.isInServiceUserContext == true) +
                    ')'
            );

            // Get the appropriate orchestrator for this agent type
            IAgentOrchestrator orchestrator = getOrchestrator(agentDef);

            // Delegate to orchestrator for type-specific execution logic
            ExecutionResult result = orchestrator.initiate(agentDeveloperName, payload);

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Execution initiated successfully. ExecutionId=' + result.executionId + ', Status=' + result.status
            );
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
     * Retrieves agent definition with minimal fields needed for context switching decision.
     * This is a separate query to avoid coupling with orchestrator creation logic.
     */
    private static AIAgentDefinition__c getAgentDefinitionForContextCheck(String agentDeveloperName) {
        List<AIAgentDefinition__c> agentDefs = [
            SELECT Id, DeveloperName__c, RequiresServiceUserContext__c, IsActive__c, AgentType__c, LLMConfiguration__c, AsyncDispatchType__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c = :agentDeveloperName AND IsActive__c = TRUE
            LIMIT 1
        ];

        if (agentDefs.isEmpty()) {
            throw new AgentOrchestratorException('Agent definition not found or inactive: ' + agentDeveloperName);
        }

        return agentDefs[0];
    }

    /**
     * Routes execution through REST API for service user context switching.
     */
    private static ExecutionResult routeThroughRestApi(AIAgentDefinition__c agentDef, ExecutionPayload payload, String logPrefix) {
        try {
            // Build HTTP request for context switch
            AIAgentHttpClient.AIAgentMessageRequest httpRequest = new AIAgentHttpClient.AIAgentMessageRequest(
                payload.existingExecutionId != null ? String.valueOf(payload.existingExecutionId) : null,
                String.valueOf(payload.userId),
                String.valueOf(agentDef.Id),
                payload.turnIdentifier,
                payload.userMessage,
                payload.currentRecordId != null ? String.valueOf(payload.currentRecordId) : null
            );

            // Make REST callout to switch to service user context
            AIAgentHttpClient.AIAgentHttpResponse httpResponse = AIAgentHttpClient.processMessage(httpRequest);

            if (httpResponse.success) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Successfully routed through REST API for service user context');
                return new ExecutionResult(
                    null, // Execution ID will be created in service user context
                    httpResponse.outcome != null ? httpResponse.outcome : AIAgentConstants.STATUS_PROCESSING,
                    httpResponse.outcome != null ? httpResponse.outcome : 'Processing in service user context'
                );
            } else {
                throw new AgentOrchestratorException('REST API routing failed: ' + httpResponse.error);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error routing through REST API: ' + e.getMessage());
            throw new AgentOrchestratorException('Failed to switch to service user context: ' + e.getMessage());
        }
    }

    /**
     * Execution payload containing all data needed for agent execution.
     */
    public class ExecutionPayload {
        // Common fields for all agent types
        @AuraEnabled
        public Id userId { get; set; } // The user initiating the execution
        @AuraEnabled
        public Id serviceUserId { get; set; } // Optional service user for elevated permissions
        @AuraEnabled
        public String triggerSource { get; set; } // Source that triggered this execution (e.g., 'Chat', 'Email', 'API')
        @AuraEnabled
        public Id sourceRecordId { get; set; } // Optional source record context
        @AuraEnabled
        public Boolean isInServiceUserContext { get; set; } // Flag to indicate we're already in service user context (prevents infinite recursion)

        // Conversational-specific fields
        @AuraEnabled
        public String userMessage { get; set; } // User's message content (for conversational)
        @AuraEnabled
        public Id currentRecordId { get; set; } // Current page record context (for conversational)
        @AuraEnabled
        public String turnIdentifier { get; set; } // Turn identifier (for conversational)
        @AuraEnabled
        public Id existingExecutionId { get; set; } // For continuing existing execution (conversational)

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
     * ExecutionResult encapsulates the result of an execution initiation.
     */
    public class ExecutionResult {
        @AuraEnabled
        public Id executionId { get; set; } // The created AgentExecution__c ID
        @AuraEnabled
        public String status { get; set; } // Execution status (e.g., 'Processing', 'Queued')
        @AuraEnabled
        public String message { get; set; } // Human-readable status message
        @AuraEnabled
        public Boolean success { get; set; } // Whether initiation succeeded
        @AuraEnabled
        public String errorMessage { get; set; } // Error message if failed

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

    // ===================================================================================
    // ORCHESTRATOR CREATION - PRIVATE METHODS
    // ===================================================================================

    /**
     * Ensures the orchestrator mapping cache is initialized from AgentOrchestratorMapping__mdt records.
     * Loads active mappings and validates configuration.
     */
    private static void ensureOrchestratorMappingCacheInitialized() {
        if (isMappingCacheInitialized) {
            return;
        }

        orchestratorMappingCache = new Map<String, AgentOrchestratorMapping__mdt>();

        try {
            List<AgentOrchestratorMapping__mdt> mappings = [
                SELECT DeveloperName, MasterLabel, AgentType__c, OrchestratorClassName__c, IsActive__c, Description__c
                FROM AgentOrchestratorMapping__mdt
                WHERE IsActive__c = TRUE
            ];

            for (AgentOrchestratorMapping__mdt mapping : mappings) {
                if (String.isNotBlank(mapping.AgentType__c) && String.isNotBlank(mapping.OrchestratorClassName__c)) {
                    orchestratorMappingCache.put(mapping.AgentType__c.toLowerCase(), mapping);
                } else {
                    System.debug(
                        LoggingLevel.ERROR,
                        LOG_PREFIX +
                            'Skipped AgentOrchestratorMapping__mdt record (DeveloperName=' +
                            mapping.DeveloperName +
                            '): missing AgentType__c or OrchestratorClassName__c.'
                    );
                }
            }

            System.debug(
                LoggingLevel.INFO,
                LOG_PREFIX + 'Orchestrator mapping cache initialized: ' + orchestratorMappingCache.size() + ' active mappings loaded.'
            );
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                LOG_PREFIX + 'CRITICAL: Unable to load Orchestrator Mappings from Custom Metadata. Exception: ' + e.getMessage()
            );
            throw new AgentOrchestratorException(
                'Failed to load Orchestrator Mappings from Custom Metadata. Check AgentOrchestratorMapping__mdt configuration.',
                e
            );
        }

        isMappingCacheInitialized = true;
    }

    /**
     * Creates and returns the appropriate orchestrator for the given agent definition.
     * Uses custom metadata mappings to dynamically instantiate the correct orchestrator implementation.
     *
     * @param agentDef The agent definition containing the AgentType__c
     * @return         IAgentOrchestrator implementation for the agent's type
     * @throws         AgentOrchestratorException if agent type is invalid or orchestrator cannot be created
     */
    private static IAgentOrchestrator getOrchestrator(AIAgentDefinition__c agentDef) {
        // Ensure orchestrator mappings are loaded
        ensureOrchestratorMappingCacheInitialized();

        // Validate agent type
        if (String.isBlank(agentDef.AgentType__c)) {
            throw new AgentOrchestratorException('AgentType__c is required on agent definition: ' + agentDef.DeveloperName__c);
        }

        // Look up orchestrator mapping for this agent type
        String agentType = agentDef.AgentType__c;
        AgentOrchestratorMapping__mdt mapping = orchestratorMappingCache.get(agentType.toLowerCase());

        if (mapping == null) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'No orchestrator mapping found for agent type: "' + agentType + '"');
            throw new AgentOrchestratorException(
                'No active orchestrator mapping found for agent type: "' + agentType + '". ' + 'Check AgentOrchestratorMapping__mdt configuration.'
            );
        }

        // Instantiate orchestrator using reflection
        try {
            System.debug(
                LoggingLevel.INFO,
                LOG_PREFIX + 'Instantiating orchestrator: ' + mapping.OrchestratorClassName__c + ' for agent type: ' + agentType
            );

            Type orchestratorType = Type.forName(mapping.OrchestratorClassName__c);
            if (orchestratorType == null) {
                throw new AgentOrchestratorException(
                    'Orchestrator class not found: "' + mapping.OrchestratorClassName__c + '". ' + 'Verify the class exists and is accessible.'
                );
            }

            // Create instance using no-argument constructor
            Object instanceObj = orchestratorType.newInstance();

            // Validate interface implementation
            if (!(instanceObj instanceof IAgentOrchestrator)) {
                System.debug(
                    LoggingLevel.ERROR,
                    LOG_PREFIX + 'Class "' + mapping.OrchestratorClassName__c + '" does not implement IAgentOrchestrator.'
                );
                throw new AgentOrchestratorException(
                    'Class "' + mapping.OrchestratorClassName__c + '" must implement the IAgentOrchestrator interface.'
                );
            }

            // Initialize orchestrator with agent definition
            IAgentOrchestrator orchestrator = (IAgentOrchestrator) instanceObj;
            orchestrator.initialize(agentDef);

            System.debug(
                LoggingLevel.INFO,
                LOG_PREFIX + 'Successfully instantiated and initialized orchestrator: ' + mapping.OrchestratorClassName__c
            );

            return orchestrator;
        } catch (AgentOrchestratorException e) {
            throw e; // Re-throw our custom exceptions
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                LOG_PREFIX + 'Failed to instantiate orchestrator "' + mapping.OrchestratorClassName__c + '": ' + e.getMessage()
            );
            throw new AgentOrchestratorException(
                'Failed to instantiate orchestrator "' + mapping.OrchestratorClassName__c + '": ' + e.getMessage(),
                e
            );
        }
    }

    /**
     * Clears the orchestrator mapping cache. Intended for use in test contexts only.
     */
    @TestVisible
    private static void clearOrchestratorCache_TestOnly() {
        orchestratorMappingCache = null;
        isMappingCacheInitialized = false;
    }
}
