/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Unified entry point for all agent execution initiations.
 * Handles service user context switching and delegates to appropriate orchestrators.
 *
 * @example
 * // Simple execution
 * ExecutionPayload payload = new ExecutionPayload(recordId);
 * ExecutionResult result = AgentExecutionService.startExecution('Case_Summarizer', payload);
 *
 * // Conversational with message
 * ExecutionPayload payload = new ExecutionPayload(recordId, 'Summarize this case');
 * ExecutionResult result = AgentExecutionService.startExecution('Customer_Support_Copilot', payload);
 */
public class AgentExecutionService {
    private static final String LOG_PREFIX = '[AgentExecutionService] ';
    private static final String NAMED_CREDENTIAL_NAME = 'AgentStudioInternalAPI';

    @TestVisible
    private static Map<String, AgentOrchestratorMapping__mdt> orchestratorMappingCache;
    @TestVisible
    private static Boolean isMappingCacheInitialized = false;

    /**
     * Initiates agent execution with service user context switching when required.
     */
    public static ExecutionResult startExecution(String agentDeveloperName, ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[' + agentDeveloperName + '] ';

        try {
            if (String.isBlank(agentDeveloperName)) {
                throw new AIAgentException.OrchestrationException('Agent developer name is required');
            }
            if (payload == null) {
                throw new AIAgentException.OrchestrationException('Execution payload is required');
            }
            payload.validate();

            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);

            if (agentDef.RequiresServiceUserContext__c && payload.isInServiceUserContext != true) {
                return routeThroughRestApi(agentDef, payload, logPrefix);
            }

            IAgentOrchestrator orchestrator = getOrchestrator(agentDef);
            return orchestrator.start(agentDeveloperName, payload);
        } catch (AIAgentException.OrchestrationException e) {
            throw e;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AIAgentException.OrchestrationException('Failed to start execution: ' + e.getMessage());
        }
    }

    /**
     * @description Flow-compatible entry point for agent execution.
     */
    @InvocableMethod(Label='Start Agent Execution' Description='Starts agent execution for single or multiple records' category='AI Agent')
    public static List<ExecutionResult> startExecutionFromFlow(List<InvocableRequest> requests) {
        List<ExecutionResult> results = new List<ExecutionResult>();

        for (InvocableRequest request : requests) {
            try {
                ExecutionPayload payload = new ExecutionPayload();
                payload.userId = UserInfo.getUserId();
                payload.sourceRecordIds = request.recordIds;
                payload.userMessage = request.userMessage;
                payload.triggerSource = request.triggerSource;
                payload.turnIdentifier = UUID.randomUUID().toString();

                results.add(startExecution(request.agentName, payload));
            } catch (Exception e) {
                results.add(new ExecutionResult('Failed to start execution: ' + e.getMessage()));
            }
        }

        return results;
    }

    /**
     * Routes execution through REST API for service user context switching.
     */
    private static ExecutionResult routeThroughRestApi(AIAgentDefinition__c agentDef, ExecutionPayload payload, String logPrefix) {
        try {
            HttpRequest httpReq = buildLoopbackHttpRequest(agentDef, payload);
            HttpCalloutService.CalloutConfig config = HttpCalloutService.createConfig(logPrefix);
            HttpCalloutService.CalloutResult result = HttpCalloutService.execute(httpReq, config);

            HttpResponse httpRes = result.response;
            Integer statusCode = httpRes.getStatusCode();
            String responseBody = httpRes.getBody();

            if (statusCode == 200) {
                AIAgentRestService.AIAgentResponse restResponse = (AIAgentRestService.AIAgentResponse) JSON.deserialize(
                    responseBody,
                    AIAgentRestService.AIAgentResponse.class
                );
                if (restResponse.success) {
                    return new ExecutionResult(
                        null,
                        restResponse.outcome ?? AIAgentConstants.STATUS_PROCESSING,
                        restResponse.outcome ?? 'Processing in service user context'
                    );
                }
                throw new AIAgentException.OrchestrationException('REST API routing failed: ' + restResponse.error);
            }

            String errorMessage = extractErrorMessage(responseBody, statusCode);
            throw new AIAgentException.OrchestrationException(errorMessage);
        } catch (AIAgentException.OrchestrationException e) {
            throw e;
        } catch (Exception e) {
            throw new AIAgentException.OrchestrationException('Failed to switch to service user context: ' + e.getMessage());
        }
    }

    private static String extractErrorMessage(String responseBody, Integer statusCode) {
        if (String.isBlank(responseBody)) {
            return 'HTTP ' + statusCode;
        }
        try {
            AIAgentRestService.AIAgentResponse errorResponse = (AIAgentRestService.AIAgentResponse) JSON.deserialize(
                responseBody,
                AIAgentRestService.AIAgentResponse.class
            );
            return errorResponse.error ?? 'HTTP ' + statusCode;
        } catch (Exception e) {
            return responseBody.length() > 200 ? responseBody.substring(0, 200) + '...' : responseBody;
        }
    }

    private static HttpRequest buildLoopbackHttpRequest(AIAgentDefinition__c agentDef, ExecutionPayload payload) {
        HttpRequest httpReq = new HttpRequest();
        httpReq.setEndpoint('callout:' + NAMED_CREDENTIAL_NAME + '/services/apexrest/ai/agent/process/');
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');

        httpReq.setBody(
            JSON.serialize(
                new Map<String, Object>{
                    'sessionId' => payload.existingExecutionId != null ? String.valueOf(payload.existingExecutionId) : null,
                    'originalUserId' => String.valueOf(payload.userId),
                    'agentDefinitionId' => String.valueOf(agentDef.Id),
                    'turnIdentifier' => payload.turnIdentifier,
                    'userMessage' => payload.userMessage,
                    'currentRecordId' => payload.currentRecordId != null ? String.valueOf(payload.currentRecordId) : null
                }
            )
        );

        return httpReq;
    }

    // ===================================================================================
    // FLOW INTEGRATION
    // ===================================================================================

    /**
     * @description Flow-friendly request wrapper for @InvocableMethod.
     * Simplified for Flow admins - internal flags handled automatically.
     */
    public class InvocableRequest {
        @InvocableVariable(Label='Agent Name' Description='Developer name of the agent to execute' Required=true)
        public String agentName;

        @InvocableVariable(Label='Record IDs' Description='Record IDs to process' Required=true)
        public List<Id> recordIds;

        @InvocableVariable(Label='User Message' Description='Message for conversational agents')
        public String userMessage;

        @InvocableVariable(Label='Trigger Source' Description='Source identifier (defaults to Flow)')
        public String triggerSource;
    }

    // ===================================================================================
    // EXECUTION PAYLOAD AND RESULT
    // ===================================================================================

    /**
     * Execution payload containing all data needed for agent execution.
     */
    public class ExecutionPayload {
        @AuraEnabled
        public Id userId { get; set; }
        @AuraEnabled
        public Id serviceUserId { get; set; }
        @AuraEnabled
        public String triggerSource { get; set; }
        @AuraEnabled
        public Id sourceRecordId { get; set; }
        @AuraEnabled
        public Boolean isInServiceUserContext { get; set; }
        @AuraEnabled
        public String userMessage { get; set; }
        @AuraEnabled
        public Id currentRecordId { get; set; }
        @AuraEnabled
        public String turnIdentifier { get; set; }
        @AuraEnabled
        public Id existingExecutionId { get; set; }
        @AuraEnabled
        public List<Id> sourceRecordIds { get; set; }
        @AuraEnabled
        public Id bulkExecutionId { get; set; }

        public ExecutionPayload() {
        }

        public ExecutionPayload(Id recordId) {
            this.sourceRecordId = recordId;
        }

        public ExecutionPayload(Id recordId, String message) {
            this.sourceRecordId = recordId;
            this.currentRecordId = recordId;
            this.userMessage = message;
        }

        public void validate() {
            if (userId == null) {
                userId = UserInfo.getUserId();
            }
        }
    }

    /**
     * ExecutionResult encapsulates the result of an execution initiation.
     */
    public class ExecutionResult {
        @AuraEnabled
        @InvocableVariable(Label='Execution ID' Description='ID of created execution record')
        public Id executionId;

        @AuraEnabled
        @InvocableVariable(Label='Status' Description='Execution status')
        public String status;

        @AuraEnabled
        @InvocableVariable(Label='Message' Description='Status message')
        public String message;

        @AuraEnabled
        @InvocableVariable(Label='Success' Description='Whether execution started successfully')
        public Boolean success;

        @AuraEnabled
        @InvocableVariable(Label='Error Message' Description='Error details if failed')
        public String errorMessage;

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
    // ORCHESTRATOR FACTORY
    // ===================================================================================

    private static void ensureOrchestratorMappingCacheInitialized() {
        if (isMappingCacheInitialized) {
            return;
        }

        orchestratorMappingCache = new Map<String, AgentOrchestratorMapping__mdt>();

        try {
            for (AgentOrchestratorMapping__mdt mapping : [
                SELECT DeveloperName, AgentType__c, OrchestratorClassName__c
                FROM AgentOrchestratorMapping__mdt
                WHERE IsActive__c = TRUE
            ]) {
                if (String.isNotBlank(mapping.AgentType__c) && String.isNotBlank(mapping.OrchestratorClassName__c)) {
                    orchestratorMappingCache.put(mapping.AgentType__c.toLowerCase(), mapping);
                }
            }
        } catch (Exception e) {
            throw new AIAgentException.OrchestrationException('Failed to load Orchestrator Mappings from Custom Metadata.', e);
        }

        isMappingCacheInitialized = true;
    }

    /**
     * Creates the appropriate orchestrator for the given agent definition.
     */
    public static IAgentOrchestrator getOrchestrator(AIAgentDefinition__c agentDef) {
        ensureOrchestratorMappingCacheInitialized();

        if (String.isBlank(agentDef.AgentType__c)) {
            throw new AIAgentException.OrchestrationException('AgentType__c is required on agent definition: ' + agentDef.DeveloperName__c);
        }

        AgentOrchestratorMapping__mdt mapping = orchestratorMappingCache.get(agentDef.AgentType__c.toLowerCase());
        if (mapping == null) {
            throw new AIAgentException.OrchestrationException('No active orchestrator mapping found for agent type: "' + agentDef.AgentType__c + '"');
        }

        try {
            Type orchestratorType = Type.forName(mapping.OrchestratorClassName__c);
            if (orchestratorType == null) {
                throw new AIAgentException.OrchestrationException('Orchestrator class not found: "' + mapping.OrchestratorClassName__c + '"');
            }

            Object instanceObj = orchestratorType.newInstance();
            if (!(instanceObj instanceof IAgentOrchestrator)) {
                throw new AIAgentException.OrchestrationException('Class "' + mapping.OrchestratorClassName__c + '" must implement IAgentOrchestrator');
            }

            IAgentOrchestrator orchestrator = (IAgentOrchestrator) instanceObj;
            orchestrator.configure(agentDef);
            return orchestrator;
        } catch (AIAgentException.OrchestrationException e) {
            throw e;
        } catch (Exception e) {
            throw new AIAgentException.OrchestrationException(
                'Failed to instantiate orchestrator "' + mapping.OrchestratorClassName__c + '": ' + e.getMessage(),
                e
            );
        }
    }

    @TestVisible
    private static void clearOrchestratorCache_TestOnly() {
        orchestratorMappingCache = null;
        isMappingCacheInitialized = false;
    }
}
