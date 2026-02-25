/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Dispatcher that delegates all async agent execution to the appropriate IAgentOrchestrator implementation.
 */
public without sharing class UnifiedAgentQueueable implements Queueable, Database.AllowsCallouts {
    private final String jobType;
    private final Map<String, Object> payload;

    public static final String JOB_TYPE_FUNCTION = 'Function';
    public static final String JOB_TYPE_WORKFLOW_CHILD = 'WorkflowChild';
    public static final String JOB_TYPE_WORKFLOW_SUPERVISOR = 'WorkflowSupervisor';
    public static final String JOB_TYPE_CONVERSATIONAL = 'Conversational';
    public static final String JOB_TYPE_EMAIL = 'Email';
    public UnifiedAgentQueueable(String jobType, Map<String, Object> payload) {
        if (String.isBlank(jobType)) {
            throw new UnifiedQueueableException('Job type is required for UnifiedAgentQueueable');
        }

        if (payload == null) {
            throw new UnifiedQueueableException('Payload is required for UnifiedAgentQueueable');
        }

        Set<String> validJobTypes = new Set<String>{
            JOB_TYPE_FUNCTION,
            JOB_TYPE_WORKFLOW_CHILD,
            JOB_TYPE_WORKFLOW_SUPERVISOR,
            JOB_TYPE_CONVERSATIONAL,
            JOB_TYPE_EMAIL
        };
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
            IAgentOrchestrator orchestrator = loadOrchestrator(logPrefix);
            // Inject jobType into payload so orchestrators can branch on it
            Map<String, Object> enrichedPayload = new Map<String, Object>(payload);
            enrichedPayload.put('jobType', jobType);
            orchestrator.runAsync(enrichedPayload, logPrefix);

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

            if (jobType == JOB_TYPE_WORKFLOW_CHILD) {
                executionIdToUpdate = (Id) payload.get('childExecutionId');
            } else if (jobType == JOB_TYPE_WORKFLOW_SUPERVISOR) {
                // Supervisor failures fail the parent execution
                executionIdToUpdate = (Id) payload.get('parentExecutionId');
            } else if (jobType == JOB_TYPE_CONVERSATIONAL || jobType == JOB_TYPE_EMAIL) {
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

    private IAgentOrchestrator loadOrchestrator(String logPrefix) {
        try {
            Id agentDefinitionId = getAgentDefinitionId(logPrefix);

            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefinitionId);
            if (agentDef == null) {
                throw new UnifiedQueueableException('Agent definition not found: ' + agentDefinitionId);
            }

            IAgentOrchestrator orchestrator = AgentExecutionService.getOrchestrator(agentDef);

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Loaded orchestrator for agent: ' + agentDef.DeveloperName__c + ' (type: ' + agentDef.AgentType__c + ')'
            );
            return orchestrator;
        } catch (Exception e) {
            throw new UnifiedQueueableException('Failed to load orchestrator: ' + e.getMessage());
        }
    }

    private Id getAgentDefinitionId(String logPrefix) {
        Id agentDefinitionId = null;

        if (jobType == JOB_TYPE_CONVERSATIONAL || jobType == JOB_TYPE_EMAIL) {
            agentDefinitionId = (Id) payload.get('agentDefinitionId');
        } else if (jobType == JOB_TYPE_WORKFLOW_CHILD || jobType == JOB_TYPE_WORKFLOW_SUPERVISOR) {
            // For supervisor jobs, agentDefinitionId may be directly in the payload
            if (payload.containsKey('agentDefinitionId') && payload.get('agentDefinitionId') != null) {
                agentDefinitionId = (Id) payload.get('agentDefinitionId');
            } else {
                Id parentExecutionId = (Id) payload.get('parentExecutionId');
                if (parentExecutionId == null) {
                    throw new UnifiedQueueableException('parentExecutionId is required for ' + jobType + ' job type');
                }

                List<AgentExecution__c> parentExecs = [
                    SELECT AIAgentDefinition__c
                    FROM AgentExecution__c
                    WHERE Id = :parentExecutionId
                    LIMIT 1
                ];

                if (parentExecs.isEmpty()) {
                    throw new UnifiedQueueableException('Parent execution not found: ' + parentExecutionId);
                }

                agentDefinitionId = parentExecs[0].AIAgentDefinition__c;
            }
        } else if (jobType == JOB_TYPE_FUNCTION) {
            String agentDeveloperName = (String) payload.get('agentDeveloperName');
            if (String.isBlank(agentDeveloperName)) {
                throw new UnifiedQueueableException('agentDeveloperName is required for Function job type');
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
