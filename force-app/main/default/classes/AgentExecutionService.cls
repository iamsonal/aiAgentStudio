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
 *
 * @usage Simple Function Agent Execution:
 * ```apex
 * // Minimal usage - just provide a record ID
 * AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload('500Dl00000AMoWV');
 * AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution('Case_Summarizer', payload);
 *
 * // Or even simpler with default constructor
 * AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
 * payload.sourceRecordId = caseId;
 * AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution('Case_Summarizer', payload);
 *
 * // All optional fields have sensible defaults:
 * // - userId: defaults to UserInfo.getUserId()
 * // - triggerSource: defaults to 'Apex'
 * // - userMessage: optional (not required for function agents)
 * ```
 *
 * @usage Conversational Agent with User Message:
 * ```apex
 * AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload(caseId, 'Summarize this case');
 * AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution('Customer_Support_Copilot', payload);
 * ```
 */
public class AgentExecutionService {
    private static final String LOG_PREFIX = '[AgentExecutionService] ';
    private static final String NAMED_CREDENTIAL_NAME = 'AgentStudioInternalAPI';

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
                throw new AIAgentException.OrchestrationException('Agent developer name is required');
            }
            if (payload == null) {
                throw new AIAgentException.OrchestrationException('Execution payload is required');
            }
            payload.validate();

            // Query the agent definition to make context switching decision
            // Use AIAgentConfigService to ensure all fields are queried
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);

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
        } catch (AIAgentException.OrchestrationException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Orchestration error: ' + e.getMessage());
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString());
            throw new AIAgentException.OrchestrationException('Failed to start execution: ' + e.getMessage());
        }
    }

    /**
     * @description Flow-compatible entry point for agent execution (single or bulk)
     * Note: Bulk execution support depends on the orchestrator implementation.
     * Workflow agents (addon) support bulk execution for multiple records.
     *
     * @param requests List of invocable requests from Flow
     * @return List of execution results
     */
    @InvocableMethod(label='Start Agent Execution' description='Starts agent execution for single or multiple records' category='AI Agent')
    public static List<ExecutionResult> startExecutionFromFlow(List<InvocableRequest> requests) {
        List<ExecutionResult> results = new List<ExecutionResult>();

        for (InvocableRequest request : requests) {
            try {
                // Build ExecutionPayload from Flow-friendly request
                ExecutionPayload payload = new ExecutionPayload();
                payload.userId = request.userId; // Will default to current user in validate() if null
                payload.sourceRecordIds = request.recordIds; // Could be 1 or many - orchestrator handles bulk logic
                payload.userMessage = request.userMessage; // Optional
                payload.triggerSource = 'Flow';
                payload.turnIdentifier = UUID.randomUUID().toString();

                // Delegate to orchestrator (which may handle bulk execution internally)
                ExecutionResult result = startExecution(request.agentName, payload);
                results.add(result);
            } catch (Exception e) {
                // Return error result for this request
                ExecutionResult errorResult = new ExecutionResult('Failed to start execution: ' + e.getMessage());
                results.add(errorResult);
            }
        }

        return results;
    }

    /**
     * Routes execution through REST API for service user context switching.
     */
    private static ExecutionResult routeThroughRestApi(AIAgentDefinition__c agentDef, ExecutionPayload payload, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting REST callout for service user context switch');

        try {
            HttpRequest httpReq = buildLoopbackHttpRequest(agentDef, payload, logPrefix);

            // Configure and execute callout
            HttpCalloutService.CalloutConfig config = HttpCalloutService.createConfig(logPrefix);
            HttpCalloutService.CalloutResult result = HttpCalloutService.execute(httpReq, config);

            // Parse response
            LoopbackResponse response = parseLoopbackResponse(result.response, logPrefix);

            if (response.success) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Successfully routed through REST API for service user context');
                return new ExecutionResult(
                    null, // Execution ID will be created in service user context
                    response.outcome != null ? response.outcome : AIAgentConstants.STATUS_PROCESSING,
                    response.outcome != null ? response.outcome : 'Processing in service user context'
                );
            } else {
                throw new AIAgentException.OrchestrationException('REST API routing failed: ' + response.error);
            }
        } catch (AIAgentException.OrchestrationException e) {
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error routing through REST API: ' + e.getMessage());
            throw new AIAgentException.OrchestrationException('Failed to switch to service user context: ' + e.getMessage());
        }
    }

    /**
     * Builds an authenticated HttpRequest for the internal loopback REST API.
     */
    private static HttpRequest buildLoopbackHttpRequest(AIAgentDefinition__c agentDef, ExecutionPayload payload, String logPrefix) {
        String endpoint = 'callout:' + NAMED_CREDENTIAL_NAME + '/services/apexrest/ai/agent/process/';

        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint(endpoint);
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');

        Map<String, Object> requestBody = new Map<String, Object>{
            'sessionId' => payload.existingExecutionId != null ? String.valueOf(payload.existingExecutionId) : null,
            'originalUserId' => String.valueOf(payload.userId),
            'agentDefinitionId' => String.valueOf(agentDef.Id),
            'turnIdentifier' => payload.turnIdentifier,
            'userMessage' => payload.userMessage,
            'currentRecordId' => payload.currentRecordId != null ? String.valueOf(payload.currentRecordId) : null
        };

        httpReq.setBody(JSON.serialize(requestBody));

        System.debug(LoggingLevel.INFO, logPrefix + 'HTTP request built for Named Credential: ' + NAMED_CREDENTIAL_NAME);
        return httpReq;
    }

    /**
     * Parses the HTTP response from the loopback API.
     */
    private static LoopbackResponse parseLoopbackResponse(HttpResponse httpRes, String logPrefix) {
        Integer statusCode = httpRes.getStatusCode();
        String responseBody = httpRes.getBody();

        System.debug(LoggingLevel.INFO, logPrefix + 'HTTP response received. Status=' + statusCode + ', BodyLength=' + (responseBody?.length() ?? 0));

        try {
            if (statusCode == 200) {
                AIAgentRestService.AIAgentResponse restResponse = (AIAgentRestService.AIAgentResponse) JSON.deserialize(
                    responseBody,
                    AIAgentRestService.AIAgentResponse.class
                );
                return new LoopbackResponse(restResponse.success, restResponse.outcome, restResponse.error);
            } else {
                String errorMessage = 'HTTP ' + statusCode;

                if (String.isNotBlank(responseBody)) {
                    try {
                        AIAgentRestService.AIAgentResponse errorResponse = (AIAgentRestService.AIAgentResponse) JSON.deserialize(
                            responseBody,
                            AIAgentRestService.AIAgentResponse.class
                        );
                        errorMessage = errorResponse.error ?? errorMessage;
                    } catch (Exception parseEx) {
                        errorMessage = responseBody.length() > 200 ? responseBody.substring(0, 200) + '...' : responseBody;
                    }
                }

                System.debug(LoggingLevel.ERROR, logPrefix + 'HTTP error response: ' + errorMessage);
                return new LoopbackResponse(false, null, errorMessage);
            }
        } catch (JSONException e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to parse JSON response: ' + e.getMessage());
            return new LoopbackResponse(false, null, 'Response parsing error: ' + e.getMessage());
        }
    }

    /**
     * Internal response wrapper for loopback API responses.
     */
    private class LoopbackResponse {
        public Boolean success;
        public String outcome;
        public String error;

        public LoopbackResponse(Boolean success, String outcome, String error) {
            this.success = success;
            this.outcome = outcome;
            this.error = error;
        }
    }

    // ===================================================================================
    // FLOW INTEGRATION - INVOCABLE REQUEST/RESULT WRAPPERS
    // ===================================================================================

    /**
     * @description Flow-friendly request wrapper for @InvocableMethod
     */
    public class InvocableRequest {
        @InvocableVariable(label='Agent Name' description='Developer name of the agent to execute' required=true)
        public String agentName;

        @InvocableVariable(
            label='Record IDs'
            description='One or more record IDs to process (1 = single execution, 2+ = bulk execution)'
            required=true
        )
        public List<Id> recordIds;

        @InvocableVariable(label='User Message' description='Optional message for the agent (for conversational agents)')
        public String userMessage;

        @InvocableVariable(label='User ID' description='ID of the user initiating the execution (defaults to current user)')
        public Id userId;
    }

    // ===================================================================================
    // EXECUTION PAYLOAD AND RESULT CLASSES
    // ===================================================================================

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

        // Bulk execution fields
        @AuraEnabled
        public List<Id> sourceRecordIds { get; set; } // Multiple records for bulk execution
        @AuraEnabled
        public Id bulkExecutionId { get; set; } // Parent bulk execution ID (set by framework)

        /**
         * Default constructor - all fields will use defaults in validate()
         */
        public ExecutionPayload() {
        }

        /**
         * Convenience constructor for simple function agent executions with just a record ID.
         * @param recordId The record ID to process
         */
        public ExecutionPayload(Id recordId) {
            this.sourceRecordId = recordId;
        }

        /**
         * Convenience constructor for conversational agents with user message.
         * @param recordId The record ID context
         * @param message The user's message
         */
        public ExecutionPayload(Id recordId, String message) {
            this.sourceRecordId = recordId;
            this.currentRecordId = recordId;
            this.userMessage = message;
        }

        /**
         * Validates and applies sensible defaults to required fields.
         * @throws AIAgentException.OrchestrationException if validation fails
         */
        public void validate() {
            // Apply sensible defaults
            if (userId == null) {
                userId = UserInfo.getUserId(); // Default to current user
            }
            if (String.isBlank(triggerSource)) {
                triggerSource = 'Apex'; // Default to Apex execution
            }
            // userMessage is optional - no validation needed
        }
    }

    /**
     * ExecutionResult encapsulates the result of an execution initiation.
     * Used by both Apex callers and Flow (via @InvocableMethod).
     */
    public class ExecutionResult {
        @AuraEnabled
        @InvocableVariable(label='Execution ID' description='ID of created AgentExecution__c or BulkExecution__c')
        public Id executionId; // The created AgentExecution__c ID (or BulkExecution__c for bulk)

        @AuraEnabled
        @InvocableVariable(label='Status' description='Execution status (Processing, Queued, etc.)')
        public String status; // Execution status (e.g., 'Processing', 'Queued')

        @AuraEnabled
        @InvocableVariable(label='Message' description='Human-readable status message')
        public String message; // Human-readable status message

        @AuraEnabled
        @InvocableVariable(label='Success' description='Whether execution started successfully')
        public Boolean success; // Whether initiation succeeded

        @AuraEnabled
        @InvocableVariable(label='Error Message' description='Error details if failed')
        public String errorMessage; // Error message if failed

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
            throw new AIAgentException.OrchestrationException(
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
     * @throws         AIAgentException.OrchestrationException if agent type is invalid or orchestrator cannot be created
     */
    private static IAgentOrchestrator getOrchestrator(AIAgentDefinition__c agentDef) {
        // Ensure orchestrator mappings are loaded
        ensureOrchestratorMappingCacheInitialized();

        // Validate agent type
        if (String.isBlank(agentDef.AgentType__c)) {
            throw new AIAgentException.OrchestrationException('AgentType__c is required on agent definition: ' + agentDef.DeveloperName__c);
        }

        // Look up orchestrator mapping for this agent type
        String agentType = agentDef.AgentType__c;
        AgentOrchestratorMapping__mdt mapping = orchestratorMappingCache.get(agentType.toLowerCase());

        if (mapping == null) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'No orchestrator mapping found for agent type: "' + agentType + '"');
            throw new AIAgentException.OrchestrationException(
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
                throw new AIAgentException.OrchestrationException(
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
                throw new AIAgentException.OrchestrationException(
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
        } catch (AIAgentException.OrchestrationException e) {
            throw e; // Re-throw our custom exceptions
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                LOG_PREFIX + 'Failed to instantiate orchestrator "' + mapping.OrchestratorClassName__c + '": ' + e.getMessage()
            );
            throw new AIAgentException.OrchestrationException(
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
