/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Applies session policy rules when deciding whether a durable
 * interaction session should reuse its last execution or begin a new one.
 */
public inherited sharing class InteractionSessionPolicyService {
    @SuppressWarnings('PMD.ApexSOQLInjection')
    public Id resolveReusableExecutionId(
        InteractionRuntimeModels.InteractionSessionContext sessionContext,
        Id currentRecordId,
        ChannelRoutingService.ResolvedRoute route,
        String logPrefix
    ) {
        if (sessionContext == null || sessionContext.lastExecutionId == null) {
            return null;
        }
        List<AgentExecution__c> executions = [
            SELECT Id, ProcessingStatus__c, ExecutionStatus__c, LastActivityTime__c, SourceRecordId__c
            FROM AgentExecution__c
            WHERE Id = :sessionContext.lastExecutionId
            LIMIT 1
        ];
        if (executions.isEmpty()) {
            return null;
        }

        AgentExecution__c execution = executions[0];
        if (execution.ProcessingStatus__c == AIAgentConstants.STATUS_PROCESSING) {
            throw new AIAgentException.OrchestrationException('Interaction execution is currently processing. Please wait for the current turn to complete.');
        }
        if (String.isNotBlank(newConversationCycleReason(execution, currentRecordId, route, logPrefix))) {
            return null;
        }
        return execution.Id;
    }

    @SuppressWarnings('PMD.ApexSOQLInjection')
    private String newConversationCycleReason(AgentExecution__c execution, Id currentRecordId, ChannelRoutingService.ResolvedRoute route, String logPrefix) {
        if (execution.SourceRecordId__c != null && currentRecordId != null && execution.SourceRecordId__c != currentRecordId) {
            return 'Source record changed';
        }
        if (execution.ExecutionStatus__c == 'Failed') {
            return 'Prior execution failed';
        }
        if (route != null && route.inactivityTtlHours != null && execution.LastActivityTime__c != null) {
            Integer ttlHours = Integer.valueOf(route.inactivityTtlHours);
            if (execution.LastActivityTime__c < Datetime.now().addHours(-ttlHours)) {
                return 'Session TTL exceeded';
            }
        }

        if (
            route != null &&
            route.startNewSessionOnTerminalParent == true &&
            currentRecordId != null &&
            String.isNotBlank(route.terminalFieldApiName) &&
            String.isNotBlank(route.terminalFieldValues)
        ) {
            Schema.DescribeSObjectResult describeResult = currentRecordId.getSObjectType().getDescribe();
            String objectApiName = describeResult.getName();
            String statusField = route.terminalFieldApiName;
            Map<String, Schema.SObjectField> fieldMap = describeResult.fields.getMap();
            if (fieldMap.containsKey(statusField)) {
                try {
                    List<SObject> records = Database.query('SELECT ' + statusField + ' FROM ' + objectApiName + ' WHERE Id = :currentRecordId LIMIT 1');
                    if (!records.isEmpty()) {
                        String currentStatus = String.valueOf(records[0].get(statusField));
                        Set<String> terminals = new Set<String>(route.terminalFieldValues.replaceAll('\\s', '').split(','));
                        if (terminals.contains(currentStatus)) {
                            return 'Parent record is terminal';
                        }
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, logPrefix + '[InteractionSessionPolicyService] Terminal parent check skipped: ' + e.getMessage());
                }
            }
        }
        return null;
    }
}
