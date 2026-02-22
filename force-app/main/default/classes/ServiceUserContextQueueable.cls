/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queueable job that routes agent execution to the service user context by making
 * a loopback REST callout to this org's own REST API endpoint.
 *
 * ── ARCHITECTURAL CONSTRAINT: WHY THIS USES A SELF-CALLOUT ──────────────────────────────────
 * Salesforce Apex has no native "run as <user>" API. To execute agent logic under the service
 * user identity (RequiresServiceUserContext__c = true on the agent definition), the only
 * supported mechanism is a callout to the org's own REST API using a Named Credential whose
 * authentication is bound to the service user account.
 *
 * This class also solves a secondary platform constraint: Apex prohibits HTTP callouts after
 * DML in the same transaction ("callout after DML" error). By enqueueing this Queueable the
 * callout is deferred to a fresh transaction where no prior DML exists.
 *
 * Pre-requisites:
 *   1. A Connected App with JWT Bearer flow or equivalent for the service user.
 *   2. ServiceUserNamedCredential__c populated on AIAgentDefinition__c.
 *   3. The /services/apexrest/ai/agent/process/ endpoint allowed in Remote Site Settings.
 *   4. This class declared `without sharing` — it only builds and fires the HTTP request;
 *      all privileged DML happens inside the REST handler running as the service user.
 *
 * Trade-offs:
 *   + Isolates privileged record access to the service user without a separate managed package.
 *   + Decouples the calling context (any user triggering an agent) from execution identity.
 *   - Consumes one HTTP callout limit per agent invocation that requires service-user context.
 *   - Adds latency (~200–500 ms loopback) on every such invocation.
 *   - A stub AgentExecution__c record may be created before the REST call succeeds; if the
 *     call fails, the stub must be marked Failed (see handleFailure).
 *   - Requires Named Credential maintenance per agent definition.
 *
 * If Salesforce ever provides a first-class "run-as" Apex API this pattern should be removed.
 * ────────────────────────────────────────────────────────────────────────────────────────────
 */
public without sharing class ServiceUserContextQueueable implements Queueable, Database.AllowsCallouts {
    private static final String LOG_PREFIX = '[ServiceUserCtxQueue] ';

    private Id stubExecutionId; // May be null if caller couldn't create
    private Id agentDefinitionId;
    private AgentExecutionService.ExecutionPayload payload;

    /**
     * @description Constructor
     * @param stubExecutionId Optional ID of stub execution created by caller (may be null)
     * @param agentDefinitionId The agent definition ID
     * @param payload The execution payload with all context
     */
    public ServiceUserContextQueueable(Id stubExecutionId, Id agentDefinitionId, AgentExecutionService.ExecutionPayload payload) {
        this.stubExecutionId = stubExecutionId;
        this.agentDefinitionId = agentDefinitionId;
        this.payload = payload;
    }

    public void execute(QueueableContext context) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDefinitionId + '] ';

        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Executing service user context routing via REST API');

            HttpRequest httpReq = buildHttpRequest();
            HttpCalloutService.CalloutConfig config = HttpCalloutService.createConfig(logPrefix);
            HttpCalloutService.CalloutResult result = HttpCalloutService.execute(httpReq, config);

            HttpResponse httpRes = result.response;
            String responseBody = httpRes.getBody();

            AIAgentRestService.AIAgentResponse restResponse = (AIAgentRestService.AIAgentResponse) JSON.deserialize(
                responseBody,
                AIAgentRestService.AIAgentResponse.class
            );
            if (restResponse.success) {
                System.debug(LoggingLevel.INFO, logPrefix + 'Service user context routing successful. Outcome: ' + restResponse.outcome);
            } else {
                handleFailure(logPrefix, 'REST API returned failure: ' + restResponse.error);
            }
        } catch (Exception e) {
            handleFailure(logPrefix, 'Exception during service user context routing: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    private HttpRequest buildHttpRequest() {
        HttpRequest httpReq = new HttpRequest();

        // Query agent definition for named credential (required field)
        AIAgentDefinition__c agentDef = [
            SELECT ServiceUserNamedCredential__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE Id = :agentDefinitionId
            LIMIT 1
        ];

        if (String.isBlank(agentDef.ServiceUserNamedCredential__c)) {
            throw new AIAgentException.OrchestrationException(
                'ServiceUserNamedCredential__c is not configured on AIAgentDefinition__c: ' +
                    agentDef.DeveloperName__c +
                    '. ' +
                    'This field is REQUIRED when RequiresServiceUserContext__c is enabled.'
            );
        }

        httpReq.setEndpoint('callout:' + agentDef.ServiceUserNamedCredential__c + '/services/apexrest/ai/agent/process/');
        httpReq.setMethod('POST');
        httpReq.setHeader('Content-Type', 'application/json');

        // Build full payload map
        Map<String, Object> requestBody = new Map<String, Object>{
            // Use stub execution ID if we created one, otherwise let service user create new
            'sessionId' => stubExecutionId != null
                ? String.valueOf(stubExecutionId)
                : (payload.existingExecutionId != null ? String.valueOf(payload.existingExecutionId) : null),
            'originalUserId' => String.valueOf(payload.userId),
            'agentDefinitionId' => String.valueOf(agentDefinitionId),
            'turnIdentifier' => payload.turnIdentifier,
            'userMessage' => payload.userMessage,
            'currentRecordId' => payload.currentRecordId != null ? String.valueOf(payload.currentRecordId) : null,
            'sourceRecordId' => payload.sourceRecordId != null ? String.valueOf(payload.sourceRecordId) : null,
            'triggerSource' => payload.triggerSource,
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

    private void handleFailure(String logPrefix, String errorMessage) {
        System.debug(LoggingLevel.ERROR, logPrefix + 'FAILURE: ' + errorMessage);

        // If we have a stub execution (single-record case), mark it as failed
        if (stubExecutionId != null) {
            try {
                AgentStateService stateService = new AgentStateService();
                stateService.failTurn(
                    stubExecutionId,
                    payload.turnIdentifier,
                    'Service user context routing failed: ' + errorMessage,
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'CRITICAL: Could not update stub execution with failure: ' + e.getMessage());
            }
        } else {
            // No tracking record available - error only visible in logs
            System.debug(
                LoggingLevel.ERROR,
                logPrefix +
                    'No tracking record to update. ' +
                    'Original user: ' +
                    payload.userId +
                    ', Agent: ' +
                    agentDefinitionId +
                    '. Error will only be visible in logs.'
            );
        }
    }
}
