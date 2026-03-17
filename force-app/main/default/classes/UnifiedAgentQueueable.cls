/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Dispatcher that delegates async agent execution through the strategy runtime.
 */
public without sharing class UnifiedAgentQueueable implements Queueable, Database.AllowsCallouts {
    private final String jobType;
    private final Map<String, Object> payload;

    public static final String JOB_TYPE_SINGLE_SHOT = 'Direct';
    public static final String JOB_TYPE_ITERATIVE = 'Conversational';
    public UnifiedAgentQueueable(String jobType, Map<String, Object> payload) {
        if (String.isBlank(jobType)) {
            throw new UnifiedQueueableException('Job type is required for UnifiedAgentQueueable');
        }

        if (payload == null) {
            throw new UnifiedQueueableException('Payload is required for UnifiedAgentQueueable');
        }

        Set<String> validJobTypes = new Set<String>{ JOB_TYPE_SINGLE_SHOT, JOB_TYPE_ITERATIVE };
        if (!validJobTypes.contains(jobType)) {
            throw new UnifiedQueueableException('Invalid job type: ' + jobType + '. Must be one of: ' + String.join(new List<String>(validJobTypes), ', '));
        }

        this.jobType = jobType;
        this.payload = payload;
    }

    public void execute(QueueableContext context) {
        String logPrefix = '[UnifiedQueueable JobId:' + context.getJobId() + ' Type:' + jobType + '] ';
        Long startTime = System.currentTimeMillis();

        System.debug(LoggingLevel.INFO, logPrefix + 'Starting execution');

        try {
            AIAgentDefinition__c agentDef = loadAgentDefinition(logPrefix);
            String interactionChannel = (String) payload.get('interactionChannel');
            IExecutionStrategy strategy = ExecutionStrategyRegistryService.resolveStrategy(agentDef, interactionChannel);
            // Inject jobType into payload so compatibility seams can still inspect it where needed
            Map<String, Object> enrichedPayload = new Map<String, Object>(payload);
            enrichedPayload.put('jobType', jobType);
            strategy.runAsync(enrichedPayload, logPrefix, agentDef, interactionChannel);

            Long duration = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, logPrefix + 'Completed successfully in ' + duration + 'ms');
        } catch (Exception e) {
            Long duration = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed after ' + duration + 'ms: ' + e.getMessage() + '\n' + e.getStackTraceString());

            handleExecutionError(e, logPrefix);
        }
    }

    private void handleExecutionError(Exception e, String logPrefix) {
        try {
            Id executionIdToUpdate = null;
            String errorMessage = e.getMessage();

            if (jobType == JOB_TYPE_ITERATIVE) {
                executionIdToUpdate = (Id) payload.get('executionId');
            }

            if (executionIdToUpdate != null) {
                AgentExecution__c execUpdate = new AgentExecution__c(
                    Id = executionIdToUpdate,
                    ExecutionStatus__c = 'Failed',
                    ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                    EndTime__c = Datetime.now(),
                    ErrorMessage__c = errorMessage
                );
                update execUpdate;
                System.debug(LoggingLevel.INFO, logPrefix + 'Updated execution ' + executionIdToUpdate + ' to Failed status');
            }
        } catch (Exception updateEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution status: ' + updateEx.getMessage());
        }
    }

    private AIAgentDefinition__c loadAgentDefinition(String logPrefix) {
        try {
            Id agentDefinitionId = getAgentDefinitionId(logPrefix);

            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefinitionId);
            if (agentDef == null) {
                throw new UnifiedQueueableException('Agent definition not found: ' + agentDefinitionId);
            }

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Loaded runtime implementation for agent: ' + agentDef.DeveloperName__c + ' (strategy: ' + agentDef.RuntimeStrategy__c + ')'
            );
            return agentDef;
        } catch (Exception e) {
            throw new UnifiedQueueableException('Failed to load runtime implementation: ' + e.getMessage());
        }
    }

    private Id getAgentDefinitionId(String logPrefix) {
        Id agentDefinitionId = null;

        if (jobType == JOB_TYPE_ITERATIVE) {
            agentDefinitionId = (Id) payload.get('agentDefinitionId');
        } else if (jobType == JOB_TYPE_SINGLE_SHOT) {
            String agentDeveloperName = (String) payload.get('agentDeveloperName');
            if (String.isBlank(agentDeveloperName)) {
                throw new UnifiedQueueableException('agentDeveloperName is required for Direct job type');
            }

            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinitionByDeveloperName(agentDeveloperName);
            if (agentDef == null) {
                throw new UnifiedQueueableException('Agent definition not found for developer name: ' + agentDeveloperName);
            }
            agentDefinitionId = agentDef.Id;
        }

        if (agentDefinitionId == null) {
            throw new UnifiedQueueableException('Agent definition ID not found in payload for job type: ' + jobType);
        }

        return agentDefinitionId;
    }

    public class UnifiedQueueableException extends Exception {
    }
}
