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
global inherited sharing class AgentExecutionService {
    private static final String LOG_PREFIX = '[AgentExecutionService] ';

    @TestVisible
    private static Map<String, AgentOrchestratorMapping__mdt> orchestratorMappingCache;
    @TestVisible
    private static Boolean isMappingCacheInitialized = false;

    public static ExecutionResult startExecution(String agentDeveloperName, ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[' + agentDeveloperName + '] ';

        // Reset TransactionContext at entry to ensure clean state for this execution
        // Prevents state pollution if multiple executions occur in same transaction
        TransactionContext.getInstance().reset();

        try {
            if (String.isBlank(agentDeveloperName)) {
                throw new AIAgentException.OrchestrationException('Agent developer name is required');
            }
            if (payload == null) {
                throw new AIAgentException.OrchestrationException('Execution payload is required');
            }

            // Lightweight validation BEFORE service user routing (only validates ID formats, not record access)
            // Full validation happens AFTER routing when we have proper context
            payload.validateIdFormats();

            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);

            // Generate turnIdentifier if not provided (needed for service user routing)
            if (String.isBlank(payload.turnIdentifier)) {
                payload.turnIdentifier = UUID.randomUUID().toString();
            }

            // Service user context routing
            if (agentDef.RequiresServiceUserContext__c && payload.isInServiceUserContext != true) {
                // Check if DML has already occurred in this transaction
                // If so, we cannot make HTTP callout - must defer to Queueable
                if (hasPriorDML()) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'Prior DML detected, routing through Queueable');
                    return routeThroughQueueable(agentDef, payload, logPrefix);
                } else {
                    System.debug(LoggingLevel.INFO, logPrefix + 'No prior DML, routing through REST API');
                    return routeThroughRestApi(agentDef, payload, logPrefix);
                }
            }

            // Full validation now that we're in the correct user context
            payload.validate();

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
     * @description Checks if operations that prevent HTTP callouts have already occurred.
     * Used to determine if we can make an HTTP callout or must defer to Queueable.
     *
     * Salesforce prevents HTTP callouts after:
     * - DML operations
     * - Email sends (Messaging.sendEmail)
     * - Any other operation that creates "uncommitted work"
     */
    private static Boolean hasPriorDML() {
        return Limits.getDMLStatements() > 0 || Limits.getDMLRows() > 0 || Limits.getEmailInvocations() > 0;
    }

    /**
     * @description Routes execution through a Queueable when HTTP callout is not possible (DML already occurred).
     * Creates a stub execution record (if possible) and enqueues the work for service user context.
     *
     * For MULTI-RECORD payloads (sourceRecordIds.size() > 1):
     * - Does NOT create stub records - lets service user create all AgentExecution__c records via DLQ dispatch
     * - This preserves the DLQ dispatch pattern from AgentExecutionDispatcher
     *
     * For SINGLE record payloads:
     * - Tries to create stub AgentExecution__c for immediate tracking
     * - Falls back gracefully if caller doesn't have permission
     */
    private static ExecutionResult routeThroughQueueable(AIAgentDefinition__c agentDef, ExecutionPayload payload, String logPrefix) {
        Id stubExecutionId = null;
        Boolean isMultiRecordExecution = payload.sourceRecordIds != null && payload.sourceRecordIds.size() > 1;

        if (isMultiRecordExecution) {
            // MULTI-RECORD: Don't create stub - let service user create all AgentExecution__c records via DLQ dispatch
            // This preserves the proper DLQ dispatch pattern with BatchId correlation
            System.debug(
                LoggingLevel.INFO,
                logPrefix +
                    'Multi-record execution detected (' +
                    payload.sourceRecordIds.size() +
                    ' records). ' +
                    'Skipping stub creation - AgentExecution__c records will be created in service user context via DLQ dispatch.'
            );
        } else {
            // SINGLE RECORD: Try to create stub execution record for immediate tracking
            try {
                AgentStateService stateService = new AgentStateService();
                stubExecutionId = stateService.createExecution(
                    agentDef.AgentType__c, // executionType
                    agentDef.Id, // agentDefinitionId
                    payload.triggerSource ??
                        'API', // triggerSource (API for service user routing)
                    'Stub execution for service user routing', // triggerPayload
                    payload.sourceRecordId, // sourceRecordId
                    payload.userId, // userId
                    null // serviceUserId (will be set in service user context)
                );
                System.debug(LoggingLevel.INFO, logPrefix + 'Created stub execution for tracking: ' + stubExecutionId);
            } catch (Exception e) {
                // Fallback: Caller might not have permission to create execution records
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not create stub execution (will create in service user context): ' + e.getMessage());
            }
        }

        // Enqueue the work to be processed in service user context
        System.enqueueJob(new ServiceUserContextQueueable(stubExecutionId, agentDef.Id, payload));

        if (isMultiRecordExecution) {
            return new ExecutionResult(
                null,
                AIAgentConstants.STATUS_PROCESSING,
                'Multi-record execution queued for service user context (' +
                    payload.sourceRecordIds.size() +
                    ' records). ' +
                    'AgentExecution__c records will be created via DLQ dispatch with BatchId correlation.'
            );
        } else if (stubExecutionId != null) {
            return new ExecutionResult(stubExecutionId, AIAgentConstants.STATUS_PROCESSING, 'Queued for service user context');
        } else {
            return new ExecutionResult(
                null,
                AIAgentConstants.STATUS_PROCESSING,
                'Queued for service user context (tracking ID will be created by service user)'
            );
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
    global static List<ExecutionResult> startExecutionFromFlow(List<InvocableRequest> requests) {
        if (requests.isEmpty()) {
            return new List<ExecutionResult>();
        }

        // Track the original position of every request so results are placed back in the
        // same order as inputs. Flow's @InvocableMethod contract requires a strict 1:1
        // positional mapping — results[i] must correspond to requests[i].
        Map<String, List<Integer>> agentToIndices = new Map<String, List<Integer>>();
        for (Integer i = 0; i < requests.size(); i++) {
            InvocableRequest request = requests[i];
            if (!agentToIndices.containsKey(request.agentName)) {
                agentToIndices.put(request.agentName, new List<Integer>());
            }
            agentToIndices.get(request.agentName).add(i);
        }

        // Pre-fill with nulls so we can assign by index position, not by append order.
        List<ExecutionResult> results = new List<ExecutionResult>();
        for (Integer i = 0; i < requests.size(); i++) {
            results.add(null);
        }

        for (String agentName : agentToIndices.keySet()) {
            List<Integer> indices = agentToIndices.get(agentName);
            InvocableRequest sampleRequest = requests[indices[0]];

            try {
                List<Id> recordIds = new List<Id>();
                for (Integer idx : indices) {
                    recordIds.add(requests[idx].recordId);
                }

                ExecutionPayload payload = new ExecutionPayload();
                payload.userId = UserInfo.getUserId();
                payload.sourceRecordIds = recordIds;
                payload.userMessage = sampleRequest.userMessage;
                payload.triggerSource = sampleRequest.triggerSource;
                payload.turnIdentifier = UUID.randomUUID().toString();

                ExecutionResult batchResult = startExecution(agentName, payload);

                // For single-record groups the executionId is populated on batchResult.
                // For multi-record groups, execution records are created asynchronously via
                // DLQ dispatch; callers needing per-record IDs should query
                // AgentExecution__c WHERE BatchId__c = batchResult.message after processing.
                for (Integer idx : indices) {
                    results[idx] = batchResult;
                }
            } catch (Exception e) {
                ExecutionResult errorResult = new ExecutionResult(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Failed to start execution: ' + e.getMessage());
                for (Integer idx : indices) {
                    results[idx] = errorResult;
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
            String responseBody = httpRes.getBody();

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
        } catch (AIAgentException.OrchestrationException e) {
            throw e;
        } catch (Exception e) {
            throw new AIAgentException.OrchestrationException('Failed to switch to service user context: ' + e.getMessage());
        }
    }

    private static HttpRequest buildLoopbackHttpRequest(AIAgentDefinition__c agentDef, ExecutionPayload payload) {
        HttpRequest httpReq = new HttpRequest();

        // Get Named Credential from agent definition (required)
        if (String.isBlank(agentDef.ServiceUserNamedCredential__c)) {
            throw new AIAgentException.OrchestrationException(
                'ServiceUserNamedCredential__c is not configured on AIAgentDefinition__c: ' +
                    agentDef.DeveloperName__c +
                    '. ' +
                    'This field is REQUIRED when RequiresServiceUserContext__c is enabled. ' +
                    'Please configure a Named Credential for this agent.'
            );
        }

        httpReq.setEndpoint('callout:' + agentDef.ServiceUserNamedCredential__c + '/services/apexrest/ai/agent/process/');
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');

        // Build full payload map with all context fields
        Map<String, Object> requestBody = new Map<String, Object>{
            'sessionId' => payload.existingExecutionId != null ? String.valueOf(payload.existingExecutionId) : null,
            'originalUserId' => String.valueOf(payload.userId),
            'agentDefinitionId' => String.valueOf(agentDef.Id),
            'turnIdentifier' => payload.turnIdentifier,
            'userMessage' => payload.userMessage,
            'currentRecordId' => payload.currentRecordId != null ? String.valueOf(payload.currentRecordId) : null,
            // Additional context fields for full payload support
            'sourceRecordId' => payload.sourceRecordId != null ? String.valueOf(payload.sourceRecordId) : null,
            'triggerSource' => payload.triggerSource,
            'triggerPayload' => payload.triggerPayload,
            'batchId' => payload.batchId,
            'priority' => payload.priority
        };

        // Convert sourceRecordIds to string list
        if (payload.sourceRecordIds != null && !payload.sourceRecordIds.isEmpty()) {
            List<String> sourceRecordIdStrings = new List<String>();
            for (Id recordId : payload.sourceRecordIds) {
                sourceRecordIdStrings.add(String.valueOf(recordId));
            }
            requestBody.put('sourceRecordIds', sourceRecordIdStrings);
        }

        httpReq.setBody(JSON.serialize(requestBody));

        return httpReq;
    }

    /**
     * @description Flow-friendly request wrapper for @InvocableMethod.
     */
    global class InvocableRequest {
        @InvocableVariable(Label='Agent Name' Description='The developer name of the AI agent to execute (e.g., Case_Processing_Workflow)' Required=true)
        global String agentName;

        @InvocableVariable(
            Label='Record ID'
            Description='The record to process. In record-triggered flows, use $Record.Id. Flow automatically bulkifies multiple records.'
            Required=true
        )
        global Id recordId;

        @InvocableVariable(Label='User Message' Description='Optional message for conversational agents. Leave blank for autonomous agents.')
        global String userMessage;

        @InvocableVariable(Label='Trigger Source' Description='Optional identifier for tracking where the execution originated (e.g., "Case Creation Flow")')
        global String triggerSource;
    }

    /**
     * Execution payload containing all data needed for agent execution.
     */
    @SuppressWarnings('PMD.ApexSharingViolations')
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

        /**
         * Batch correlation ID for grouping related executions.
         * Generated automatically by dispatcher. Used for progress tracking and retry operations.
         */
        @AuraEnabled
        public String batchId { get; set; }

        /**
         * Priority for DLQ processing. Higher values = higher priority.
         * Workers process records ordered by Priority DESC, CreatedDate ASC.
         */
        @AuraEnabled
        public Integer priority { get; set; }

        /**
         * Optional trigger payload data to pass to the execution.
         */
        @AuraEnabled
        public String triggerPayload { get; set; }

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

        /**
         * @description Lightweight validation that only checks ID formats, not record accessibility.
         * Use before service user context routing when the current user may not have access to records.
         */
        public void validateIdFormats() {
            if (userId == null) {
                userId = UserInfo.getUserId();
            }

            // Validate ID formats only (no SOQL queries)
            if (sourceRecordId != null) {
                validateIdFormat(sourceRecordId, 'sourceRecordId');
            }
            if (currentRecordId != null) {
                validateIdFormat(currentRecordId, 'currentRecordId');
            }
            if (existingExecutionId != null) {
                validateIdFormat(existingExecutionId, 'existingExecutionId');
            }
            if (sourceRecordIds != null) {
                for (Integer i = 0; i < sourceRecordIds.size(); i++) {
                    if (sourceRecordIds[i] != null) {
                        validateIdFormat(sourceRecordIds[i], 'sourceRecordIds[' + i + ']');
                    }
                }
            }
        }

        private void validateIdFormat(Id idValue, String fieldName) {
            // Id type already validated by Apex type system
            // This method exists for consistency and future format validation if needed
            if (idValue == null) {
                throw new AIAgentException.OrchestrationException(fieldName + ' cannot be null');
            }
        }

        /**
         * @description Full validation including record accessibility.
         * Use after service user context routing when we have proper permissions.
         */
        public void validate() {
            if (userId == null) {
                userId = UserInfo.getUserId();
            }
            Set<Id> recordIds = new Set<Id>();

            if (sourceRecordId != null) {
                recordIds.add(sourceRecordId);
            }

            if (currentRecordId != null && currentRecordId != sourceRecordId) {
                recordIds.add(currentRecordId);
            }

            if (sourceRecordIds != null && !sourceRecordIds.isEmpty()) {
                recordIds.addAll(sourceRecordIds);
            }

            if (!recordIds.isEmpty()) {
                validateRecordsExist(new List<Id>(recordIds), 'Record');
            }
        }

        @SuppressWarnings('PMD.ApexSOQLInjection')
        private void validateRecordsExist(List<Id> recordIds, String recordType) {
            if (recordIds.isEmpty())
                return;

            Map<String, List<Id>> recordsByType = new Map<String, List<Id>>();
            for (Id recordId : recordIds) {
                Schema.SObjectType sobjectType = recordId.getSObjectType();
                String objectType = sobjectType.getDescribe().getName();
                if (!recordsByType.containsKey(objectType)) {
                    recordsByType.put(objectType, new List<Id>());
                }
                recordsByType.get(objectType).add(recordId);
            }
            for (String objectType : recordsByType.keySet()) {
                if (!Schema.getGlobalDescribe().containsKey(objectType)) {
                    throw new AIAgentException.OrchestrationException(recordType + ' validation failed: Unsupported object type ' + objectType);
                }
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

    global class ExecutionResult {
        @AuraEnabled
        @InvocableVariable(Label='Execution ID' Description='The ID of the created AgentExecution__c record. Use this to track execution progress.')
        global Id executionId;

        @AuraEnabled
        @InvocableVariable(Label='Status' Description='Current execution status (e.g., Processing, Completed, Failed)')
        global String status;

        @AuraEnabled
        @InvocableVariable(Label='Message' Description='Human-readable status message describing the execution state')
        global String message;

        @AuraEnabled
        @InvocableVariable(Label='Success' Description='True if execution started successfully, false if there was an error')
        global Boolean success;

        @AuraEnabled
        @InvocableVariable(Label='Error Message' Description='Detailed error information if the execution failed to start')
        global String errorMessage;

        @AuraEnabled
        @InvocableVariable(Label='Error Code' Description='Machine-readable error code for programmatic error handling')
        global String errorCode;

        public ExecutionResult(Id executionId, String status, String message) {
            this.executionId = executionId;
            this.status = status;
            this.message = message;
            this.success = true;
        }

        public ExecutionResult(String errorCode, String errorMessage) {
            this.success = false;
            this.errorCode = errorCode;
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
}
