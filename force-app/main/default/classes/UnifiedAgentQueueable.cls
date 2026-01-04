/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * UnifiedAgentQueueable is a "dumb" dispatcher that delegates all async agent execution
 * to the appropriate IAgentOrchestrator implementation. This class contains no agent-type-specific
 * logic - it simply loads the orchestrator and calls runAsync().
 *
 * **Supported Job Types:**
 * - Function: Executes deferred function agents (when DML has occurred before invocation)
 * - WorkflowChild: Executes child agents within workflow orchestration
 * - Conversational: Executes conversational agent LLM processing
 *
 * **Architecture Pattern:**
 * - Dispatcher Pattern: Routes to orchestrator based on job type
 * - Clean Transaction: All executions start with no prior DML (allows LLM callouts)
 * - Standardized Error Handling: Consistent error logging across all job types
 *
 * **Benefits:**
 * - Single source of truth for async agent execution dispatch
 * - All agent-type-specific logic lives in orchestrators (not here)
 * - Easy to add new async execution patterns by adding new orchestrators
 * - Centralized queueable job management
 *
 * @author Sonal
 * @since 2025
 */
public class UnifiedAgentQueueable implements Queueable, Database.AllowsCallouts {
    private final String jobType;
    private final Map<String, Object> payload;

    // Job type constants
    public static final String JOB_TYPE_FUNCTION = 'Function';
    public static final String JOB_TYPE_WORKFLOW_CHILD = 'WorkflowChild';
    public static final String JOB_TYPE_CONVERSATIONAL = 'Conversational';

    /**
     * @description Constructor for UnifiedAgentQueueable
     * @param jobType The type of job to execute (Function, WorkflowChild, or Conversational)
     * @param payload Map containing job-specific execution parameters
     * @throws UnifiedQueueableException if jobType or payload is invalid
     */
    public UnifiedAgentQueueable(String jobType, Map<String, Object> payload) {
        if (String.isBlank(jobType)) {
            throw new UnifiedQueueableException('Job type is required for UnifiedAgentQueueable');
        }

        if (payload == null) {
            throw new UnifiedQueueableException('Payload is required for UnifiedAgentQueueable');
        }

        // Validate job type
        Set<String> validJobTypes = new Set<String>{ JOB_TYPE_FUNCTION, JOB_TYPE_WORKFLOW_CHILD, JOB_TYPE_CONVERSATIONAL };
        if (!validJobTypes.contains(jobType)) {
            throw new UnifiedQueueableException('Invalid job type: ' + jobType + '. Must be one of: ' + String.join(new List<String>(validJobTypes), ', '));
        }

        this.jobType = jobType;
        this.payload = payload;
    }

    /**
     * @description Main execution method invoked by the Queueable framework.
     * Loads the appropriate orchestrator and delegates execution entirely to it.
     * @param context The QueueableContext provided by Salesforce
     */
    public void execute(QueueableContext context) {
        String logPrefix = '[UnifiedQueueable JobId:' + context.getJobId() + ' Type:' + jobType + '] ';
        Long startTime = System.currentTimeMillis();

        System.debug(LoggingLevel.INFO, logPrefix + 'Starting execution');

        try {
            // Load orchestrator based on job type and delegate execution
            IAgentOrchestrator orchestrator = loadOrchestrator(logPrefix);
            orchestrator.runAsync(payload, logPrefix);

            Long duration = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, logPrefix + 'Completed successfully in ' + duration + 'ms');
        } catch (Exception e) {
            Long duration = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed after ' + duration + 'ms: ' + e.getMessage() + '\n' + e.getStackTraceString());

            // Handle error by updating execution status if possible
            handleExecutionError(e, logPrefix);
        }
    }

    /**
     * @description Handles execution errors by updating the relevant execution record.
     * Different job types have different execution records to update.
     * @param e The exception that occurred
     * @param logPrefix Logging prefix for debug output
     */
    private void handleExecutionError(Exception e, String logPrefix) {
        try {
            Id executionIdToUpdate = null;
            String errorMessage = e.getMessage();

            if (jobType == JOB_TYPE_WORKFLOW_CHILD) {
                // For workflow child jobs, update the child execution
                executionIdToUpdate = (Id) payload.get('childExecutionId');
            } else if (jobType == JOB_TYPE_CONVERSATIONAL) {
                // For conversational jobs, update the execution
                executionIdToUpdate = (Id) payload.get('executionId');
            }
            // Function jobs don't have a pre-existing execution to update

            if (executionIdToUpdate != null) {
                AgentExecution__c execUpdate = new AgentExecution__c(
                    Id = executionIdToUpdate,
                    ExecutionStatus__c = 'Failed',
                    ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                    EndTime__c = Datetime.now(),
                    ErrorMessage__c = errorMessage?.abbreviate(255)
                );
                update execUpdate;
                System.debug(LoggingLevel.INFO, logPrefix + 'Updated execution ' + executionIdToUpdate + ' to Failed status');
            }
        } catch (Exception updateEx) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update execution status: ' + updateEx.getMessage());
        }
    }

    /**
     * @description Loads the appropriate orchestrator based on job type.
     * Uses AgentExecutionService.getOrchestrator() for metadata-driven loading.
     * @param logPrefix Logging prefix for debug output
     * @return IAgentOrchestrator The loaded and initialized orchestrator
     * @throws UnifiedQueueableException if orchestrator cannot be loaded
     */
    private IAgentOrchestrator loadOrchestrator(String logPrefix) {
        try {
            // Get agent definition ID from payload
            Id agentDefinitionId = getAgentDefinitionId(logPrefix);

            // Load agent definition
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefinitionId);
            if (agentDef == null) {
                throw new UnifiedQueueableException('Agent definition not found: ' + agentDefinitionId);
            }

            // Get orchestrator via AgentExecutionService (metadata-driven)
            // The orchestrator is loaded based on the agent's AgentType__c field
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

    /**
     * @description Extracts agent definition ID from payload based on job type.
     * Different job types store the agent definition ID in different payload fields.
     * @param logPrefix Logging prefix for debug output
     * @return Id The agent definition ID
     * @throws UnifiedQueueableException if agent definition ID cannot be found
     */
    private Id getAgentDefinitionId(String logPrefix) {
        Id agentDefinitionId = null;

        if (jobType == JOB_TYPE_CONVERSATIONAL) {
            // Conversational jobs use 'agentDefinitionId' field
            agentDefinitionId = (Id) payload.get('agentDefinitionId');
        } else if (jobType == JOB_TYPE_WORKFLOW_CHILD) {
            // Workflow child jobs need the PARENT workflow's agent definition
            // to load the WorkflowOrchestrator (not the child agent's definition)
            Id parentExecutionId = (Id) payload.get('parentExecutionId');
            if (parentExecutionId == null) {
                throw new UnifiedQueueableException('parentExecutionId is required for WorkflowChild job type');
            }

            // Query parent execution to get workflow agent definition
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
        } else if (jobType == JOB_TYPE_FUNCTION) {
            // Function jobs use 'agentDeveloperName' - need to look up the definition
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

    /**
     * @description Exception thrown by UnifiedAgentQueueable
     */
    public class UnifiedQueueableException extends Exception {
    }
}
