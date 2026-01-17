/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Unified entry point for agent execution. Handles service user context switching and delegates to orchestrators.
 */
public class AgentExecutionService {
    private static final String LOG_PREFIX = '[AgentExecutionService] ';
    private static final String NAMED_CREDENTIAL_NAME = 'AgentStudioInternalAPI';

    @TestVisible
    private static Map<String, AgentOrchestratorMapping__mdt> orchestratorMappingCache;
    @TestVisible
    private static Boolean isMappingCacheInitialized = false;

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
     * @description Flow-compatible entry point. Groups requests by agent and calls startExecution.
     */
    @InvocableMethod(
        Label='AI Agent: Start Execution'
        Description='Initiates AI agent execution for a record. Use in record-triggered flows to process records with AI agents. Automatically handles bulkification when multiple records trigger the flow.'
        Category='AI Agent'
        IconName='slds:standard:bot'
    )
    public static List<ExecutionResult> startExecutionFromFlow(List<InvocableRequest> requests) {
        if (requests.isEmpty()) {
            return new List<ExecutionResult>();
        }

        Map<String, List<Id>> agentToRecordIds = new Map<String, List<Id>>();
        Map<String, InvocableRequest> agentToSampleRequest = new Map<String, InvocableRequest>();

        for (InvocableRequest request : requests) {
            if (!agentToRecordIds.containsKey(request.agentName)) {
                agentToRecordIds.put(request.agentName, new List<Id>());
                agentToSampleRequest.put(request.agentName, request);
            }
            agentToRecordIds.get(request.agentName).add(request.recordId);
        }

        List<ExecutionResult> results = new List<ExecutionResult>();
        for (String agentName : agentToRecordIds.keySet()) {
            try {
                InvocableRequest sampleRequest = agentToSampleRequest.get(agentName);
                List<Id> recordIds = agentToRecordIds.get(agentName);

                ExecutionPayload payload = new ExecutionPayload();
                payload.userId = UserInfo.getUserId();
                payload.sourceRecordIds = recordIds;
                payload.userMessage = sampleRequest.userMessage;
                payload.triggerSource = sampleRequest.triggerSource;
                payload.turnIdentifier = UUID.randomUUID().toString();

                ExecutionResult result = startExecution(agentName, payload);
                for (Integer i = 0; i < recordIds.size(); i++) {
                    results.add(result);
                }
            } catch (Exception e) {
                List<Id> recordIds = agentToRecordIds.get(agentName);
                for (Integer i = 0; i < recordIds.size(); i++) {
                    results.add(new ExecutionResult('Failed to start execution: ' + e.getMessage()));
                }
            }
        }

        return results;
    }

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

    /**
     * @description Flow-friendly request wrapper for @InvocableMethod.
     */
    public class InvocableRequest {
        @InvocableVariable(Label='Agent Name' Description='The developer name of the AI agent to execute (e.g., Case_Processing_Workflow)' Required=true)
        public String agentName;

        @InvocableVariable(
            Label='Record ID'
            Description='The record to process. In record-triggered flows, use $Record.Id. Flow automatically bulkifies multiple records.'
            Required=true
        )
        public Id recordId;

        @InvocableVariable(Label='User Message' Description='Optional message for conversational agents. Leave blank for autonomous agents.')
        public String userMessage;

        @InvocableVariable(Label='Trigger Source' Description='Optional identifier for tracking where the execution originated (e.g., "Case Creation Flow")')
        public String triggerSource;
    }

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

            if (sourceRecordId != null) {
                validateRecordExists(sourceRecordId, 'Source record');
            }

            if (currentRecordId != null && currentRecordId != sourceRecordId) {
                validateRecordExists(currentRecordId, 'Current record');
            }

            if (sourceRecordIds != null && !sourceRecordIds.isEmpty()) {
                validateRecordsExist(sourceRecordIds, 'Source records');
            }
        }

        private void validateRecordExists(Id recordId, String recordType) {
            try {
                List<SObject> records = Database.query('SELECT Id FROM ' + recordId.getSObjectType() + ' WHERE Id = :recordId LIMIT 1');
                if (records.isEmpty()) {
                    throw new AIAgentException.OrchestrationException(recordType + ' with ID ' + recordId + ' does not exist or is not accessible');
                }
            } catch (QueryException e) {
                throw new AIAgentException.OrchestrationException(
                    recordType + ' with ID ' + recordId + ' does not exist or is not accessible: ' + e.getMessage()
                );
            }
        }

        private void validateRecordsExist(List<Id> recordIds, String recordType) {
            if (recordIds.isEmpty())
                return;

            Map<String, List<Id>> recordsByType = new Map<String, List<Id>>();
            for (Id recordId : recordIds) {
                String objectType = String.valueOf(recordId.getSObjectType());
                if (!recordsByType.containsKey(objectType)) {
                    recordsByType.put(objectType, new List<Id>());
                }
                recordsByType.get(objectType).add(recordId);
            }
            for (String objectType : recordsByType.keySet()) {
                List<Id> typeRecordIds = recordsByType.get(objectType);
                try {
                    List<SObject> existingRecords = Database.query('SELECT Id FROM ' + objectType + ' WHERE Id IN :typeRecordIds');
                    if (existingRecords.size() != typeRecordIds.size()) {
                        Set<Id> existingIds = new Set<Id>();
                        for (SObject record : existingRecords) {
                            existingIds.add(record.Id);
                        }
                        List<Id> missingIds = new List<Id>();
                        for (Id recordId : typeRecordIds) {
                            if (!existingIds.contains(recordId)) {
                                missingIds.add(recordId);
                            }
                        }
                        throw new AIAgentException.OrchestrationException(recordType + ' with IDs ' + missingIds + ' do not exist or are not accessible');
                    }
                } catch (QueryException e) {
                    throw new AIAgentException.OrchestrationException(recordType + ' validation failed: ' + e.getMessage());
                }
            }
        }
    }

    public class ExecutionResult {
        @AuraEnabled
        @InvocableVariable(Label='Execution ID' Description='The ID of the created AgentExecution__c record. Use this to track execution progress.')
        public Id executionId;

        @AuraEnabled
        @InvocableVariable(Label='Status' Description='Current execution status (e.g., Processing, Completed, Failed)')
        public String status;

        @AuraEnabled
        @InvocableVariable(Label='Message' Description='Human-readable status message describing the execution state')
        public String message;

        @AuraEnabled
        @InvocableVariable(Label='Success' Description='True if execution started successfully, false if there was an error')
        public Boolean success;

        @AuraEnabled
        @InvocableVariable(Label='Error Message' Description='Detailed error information if the execution failed to start')
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
