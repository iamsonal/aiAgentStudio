/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Specialized sequential pipeline subsystem. Pipelines are standalone utilities driven by PipelineDefinition__c /
 * PipelineStep__c metadata and tracked on AgentExecution__c with ExecutionType__c = 'Pipeline'.
 *
 * Provides the sequential pipeline engine behind the explicit composition subsystem.
 * Owns step-by-step pipeline state management (PipelineRunStep__c) and resume logic.
 *
 * **Execution Pattern:**
 * 1. startPipeline() creates parent execution, initialises run-step records, enqueues first child
 * 2. Child agent executes in separate transaction
 * 3. AgentExecutionTriggerHandler detects child completion -> onChildComplete()
 * 4. onChildComplete() advances state, enqueues next child
 * 5. Repeat until all steps complete or pipeline fails (fail-fast by default)
 *
 * @author Sonal
 * @since 2025
 */
global inherited sharing class SequentialPipelineOrchestrator {
    private static final String LOG_PREFIX = '[PipelineOrch] ';
    private static final Integer MAX_CONTEXT_CHARS = 8000;
    private static final Integer MAX_OLDER_STEP_CHARS = 800;

    private Id pipelineDefinitionId;
    private PipelineDefinition__c pipelineDef;
    private List<PipelineStepConfig> pipelineSteps;
    private Map<Id, String> userNameCache = new Map<Id, String>();

    // ==================================================================================
    // INNER CLASSES
    // ==================================================================================

    private class PipelineStepConfig {
        public Integer stepOrder;
        public String agentName;
        public String agentDisplayName;
        public Id agentDefinitionId;
        public String strategyKey;
    }

    public class PipelineStateException extends Exception {
    }

    /**
     * @description Flow-friendly request wrapper for @InvocableMethod.
     */
    global class InvocableRequest {
        @InvocableVariable(
            Label='Pipeline Name'
            Description='Developer name of the PipelineDefinition__c to execute (e.g., Case_Processing_Pipeline)'
            Required=true
        )
        global String pipelineName;

        @InvocableVariable(Label='Record ID' Description='The record to process. In record-triggered flows, use $Record.Id.' Required=true)
        global Id recordId;

        @InvocableVariable(Label='Trigger Source' Description='Optional identifier for tracking where the execution originated (e.g., "Case Creation Flow")')
        global String triggerSource;
    }

    /**
     * @description Result returned from pipeline execution. Mirrors AgentExecutionService.ExecutionResult.
     */
    global class ExecutionResult {
        @AuraEnabled
        @InvocableVariable(Label='Execution ID' Description='The ID of the parent AgentExecution__c record tracking this pipeline run.')
        global Id executionId;

        @AuraEnabled
        @InvocableVariable(Label='Status' Description='Current execution status (Processing or Failed)')
        global String status;

        @AuraEnabled
        @InvocableVariable(Label='Message' Description='Human-readable status message')
        global String message;

        @AuraEnabled
        @InvocableVariable(Label='Success' Description='True if pipeline started successfully, false if there was an error')
        global Boolean success;

        @AuraEnabled
        @InvocableVariable(Label='Error Message' Description='Detailed error information if the pipeline failed to start')
        global String errorMessage;

        @AuraEnabled
        @InvocableVariable(Label='Error Code' Description='Machine-readable error code for programmatic error handling')
        global String errorCode;

        @AuraEnabled
        @InvocableVariable(
            Label='Batch ID'
            Description='Batch identifier for bulk pipeline dispatches. Query AgentExecution__c WHERE BatchId__c = this value to find all executions.'
        )
        global String batchId;

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

    /**
     * @description Internal result from bulk dispatch. Not part of the public API.
     */
    private class DispatchResult {
        public String batchId;
        public List<Id> executionIds;
        public Integer enqueuedWorkerCount;
    }

    /**
     * @description In-memory representation of a single run step.
     */
    public class StepInfo {
        public String status;
        public String executionId;
        public String startTime;
        public String endTime;
        public String response;
        public Integer stepOrder;

        public StepInfo() {
            this.status = 'pending';
        }
    }

    /**
     * @description In-memory pipeline state.
     */
    private class PipelineState {
        public String currentStep;
        public Map<String, StepInfo> steps;
        public Map<String, Integer> retryCounts;

        public PipelineState() {
            this.steps = new Map<String, StepInfo>();
            this.retryCounts = new Map<String, Integer>();
        }
    }

    // ==================================================================================
    // KEY HELPERS — step order is the canonical state key (unique per pipeline)
    // ==================================================================================

    private static String stepKey(Integer stepOrder) {
        return String.valueOf(stepOrder);
    }

    private String agentNameForKey(String key) {
        PipelineStepConfig cfg = findStepConfig(key);
        return cfg != null ? cfg.agentName : key;
    }

    // ==================================================================================
    // CONSTRUCTORS
    // ==================================================================================

    public SequentialPipelineOrchestrator() {
    }

    // ==================================================================================
    // CONFIGURATION
    // ==================================================================================

    /**
     * @description Loads the pipeline definition and its ordered steps.
     * @param pipelineDefId The PipelineDefinition__c record Id
     */
    public void configurePipeline(Id pipelineDefId) {
        if (pipelineDefId == null) {
            throw new PipelineStateException('PipelineDefinition Id is required');
        }
        this.pipelineDefinitionId = pipelineDefId;

        List<PipelineDefinition__c> defs = [
            SELECT Id, Name, DeveloperName__c, Description__c, ErrorHandlingMode__c, IsActive__c
            FROM PipelineDefinition__c
            WHERE Id = :pipelineDefId
            LIMIT 1
        ];
        if (defs.isEmpty()) {
            throw new PipelineStateException('PipelineDefinition not found: ' + pipelineDefId);
        }
        this.pipelineDef = defs[0];

        if (this.pipelineDef.IsActive__c != true) {
            throw new PipelineStateException('Pipeline is not active: ' + this.pipelineDef.DeveloperName__c);
        }

        List<PipelineStep__c> steps = [
            SELECT ChildAgent__c, ChildAgent__r.Name, ChildAgent__r.DeveloperName__c, ChildAgent__r.RuntimeStrategy__c, ExecutionOrder__c
            FROM PipelineStep__c
            WHERE PipelineDefinition__c = :pipelineDefId AND IsActive__c = TRUE
            ORDER BY ExecutionOrder__c ASC
        ];

        if (steps.isEmpty()) {
            throw new PipelineStateException('No active steps found for pipeline: ' + this.pipelineDef.DeveloperName__c);
        }

        this.pipelineSteps = new List<PipelineStepConfig>();
        for (PipelineStep__c s : steps) {
            if (s.ChildAgent__c == null || String.isBlank(s.ChildAgent__r.DeveloperName__c)) {
                throw new PipelineStateException('Pipeline step at order ' + s.ExecutionOrder__c + ' has invalid child agent');
            }
            PipelineStepConfig cfg = new PipelineStepConfig();
            cfg.stepOrder = Integer.valueOf(s.ExecutionOrder__c);
            cfg.agentName = s.ChildAgent__r.DeveloperName__c;
            cfg.agentDisplayName = String.isNotBlank(s.ChildAgent__r.Name) ? s.ChildAgent__r.Name : s.ChildAgent__r.DeveloperName__c;
            cfg.agentDefinitionId = s.ChildAgent__c;
            cfg.strategyKey = s.ChildAgent__r.RuntimeStrategy__c;
            this.pipelineSteps.add(cfg);
        }

        System.debug(
            LoggingLevel.INFO,
            LOG_PREFIX + 'Configured pipeline: ' + this.pipelineDef.DeveloperName__c + ' with ' + this.pipelineSteps.size() + ' steps'
        );
    }

    // ==================================================================================
    // PUBLIC API — START PIPELINE
    // ==================================================================================

    /**
     * @description Flow-compatible entry point. Handles bulkification when multiple records
     * trigger the same flow. Groups requests by pipeline name for efficiency.
     */
    @InvocableMethod(
        Label='AI Agent: Start Pipeline'
        Description='Starts a sequential pipeline execution for a record. Use in record-triggered flows to run multi-agent pipelines. Automatically handles bulkification when multiple records trigger the flow.'
        Category='AI Agent'
        IconName='slds:standard:bot'
    )
    global static List<ExecutionResult> startPipelineFromFlow(List<InvocableRequest> requests) {
        if (requests == null || requests.isEmpty()) {
            return new List<ExecutionResult>();
        }

        // Pre-fill results list for strict 1:1 positional mapping required by Flow
        List<ExecutionResult> results = new List<ExecutionResult>();
        for (Integer i = 0; i < requests.size(); i++) {
            results.add(null);
        }

        // Group by pipeline name so each pipeline definition is loaded once
        Map<String, List<Integer>> pipelineToIndices = new Map<String, List<Integer>>();
        for (Integer i = 0; i < requests.size(); i++) {
            String name = requests[i].pipelineName;
            if (!pipelineToIndices.containsKey(name)) {
                pipelineToIndices.put(name, new List<Integer>());
            }
            pipelineToIndices.get(name).add(i);
        }

        for (String pipelineName : pipelineToIndices.keySet()) {
            List<Integer> indices = pipelineToIndices.get(pipelineName);
            String triggerSource = requests[indices[0]].triggerSource;

            if (indices.size() == 1) {
                InvocableRequest req = requests[indices[0]];
                try {
                    ExecutionResult res = startPipeline(req.pipelineName, req.recordId, req.triggerSource);
                    results[indices[0]] = res;
                } catch (Exception e) {
                    results[indices[0]] = new ExecutionResult('PIPELINE_START_FAILED', 'Failed to start pipeline: ' + e.getMessage());
                }
            } else {
                try {
                    List<Id> recordIds = new List<Id>();
                    for (Integer idx : indices) {
                        recordIds.add(requests[idx].recordId);
                    }
                    DispatchResult bulkResult = dispatchBulk(pipelineName, recordIds, triggerSource);

                    for (Integer i = 0; i < indices.size(); i++) {
                        Integer idx = indices[i];
                        Id execId = (i < bulkResult.executionIds.size()) ? bulkResult.executionIds[i] : null;
                        ExecutionResult res = new ExecutionResult(execId, 'Pending', 'Pipeline dispatched (batch: ' + bulkResult.batchId + ')');
                        res.batchId = bulkResult.batchId;
                        results[idx] = res;
                    }
                } catch (Exception e) {
                    ExecutionResult errorResult = new ExecutionResult('PIPELINE_DISPATCH_FAILED', 'Bulk dispatch failed: ' + e.getMessage());
                    for (Integer idx : indices) {
                        results[idx] = errorResult;
                    }
                }
            }
        }

        return results;
    }

    /**
     * @description Starts a pipeline execution for a single record.
     * @param pipelineDeveloperName Developer name of the PipelineDefinition__c
     * @param sourceRecordId Record to process
     * @return ExecutionResult containing the parent AgentExecution__c Id
     */
    public static ExecutionResult startPipeline(String pipelineDeveloperName, Id sourceRecordId) {
        return startPipeline(pipelineDeveloperName, sourceRecordId, null);
    }

    public static ExecutionResult startPipeline(String pipelineDeveloperName, Id sourceRecordId, String triggerSource) {
        try {
            AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
            payload.sourceRecordId = sourceRecordId;
            payload.triggerSource = triggerSource;
            return PipelineCompositionService.startPipelineRun(pipelineDeveloperName, payload);
        } catch (AIAgentException.OrchestrationException e) {
            throw new PipelineStateException(e.getMessage());
        }
    }

    /**
     * @description Starts pipeline executions for one or more records. A single record runs
     * synchronously; multiple records are dispatched via the DLQ pattern for bulk safety.
     * @param pipelineDeveloperName Developer name of the PipelineDefinition__c
     * @param sourceRecordIds One or more record IDs to process
     * @return ExecutionResult (batchId is set for multi-record dispatches)
     */
    public static ExecutionResult startPipeline(String pipelineDeveloperName, List<Id> sourceRecordIds) {
        return startPipeline(pipelineDeveloperName, sourceRecordIds, null);
    }

    public static ExecutionResult startPipeline(String pipelineDeveloperName, List<Id> sourceRecordIds, String triggerSource) {
        try {
            AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
            payload.sourceRecordIds = sourceRecordIds;
            payload.sourceRecordId = sourceRecordIds != null && !sourceRecordIds.isEmpty() ? sourceRecordIds[0] : null;
            payload.triggerSource = triggerSource;
            return PipelineCompositionService.startPipelineRun(pipelineDeveloperName, payload);
        } catch (AIAgentException.OrchestrationException e) {
            throw new PipelineStateException(e.getMessage());
        }
    }

    /**
     * @description Instance-level start for a pre-configured pipeline.
     * Call configurePipeline() first, then this method.
     */
    public ExecutionResult start(Id sourceRecordId) {
        return start(sourceRecordId, null);
    }

    public ExecutionResult start(Id sourceRecordId, String triggerSource) {
        String logPrefix = LOG_PREFIX + '[startPipeline ' + (pipelineDef != null ? pipelineDef.DeveloperName__c : '?') + '] ';
        Id parentExecutionId = initiatePipeline(sourceRecordId, triggerSource, logPrefix);
        return new ExecutionResult(parentExecutionId, AIAgentConstants.STATUS_PROCESSING, 'Pipeline started');
    }

    /**
     * @description Instance-level start for one or more records. Single record runs synchronously;
     * multiple records dispatch via DLQ pattern.
     * Call configurePipeline() first, then this method.
     */
    public ExecutionResult start(List<Id> sourceRecordIds) {
        return start(sourceRecordIds, null);
    }

    public ExecutionResult start(List<Id> sourceRecordIds, String triggerSource) {
        if (sourceRecordIds == null || sourceRecordIds.isEmpty()) {
            throw new PipelineStateException('At least one source record ID is required');
        }
        if (sourceRecordIds.size() == 1) {
            return start(sourceRecordIds[0], triggerSource);
        }
        if (pipelineDef == null) {
            throw new PipelineStateException('Pipeline not configured. Call configurePipeline() first.');
        }
        DispatchResult dispatched = dispatchBulk(pipelineDef.DeveloperName__c, sourceRecordIds, triggerSource);
        ExecutionResult result = new ExecutionResult(
            dispatched.executionIds.isEmpty() ? null : dispatched.executionIds[0],
            'Pending',
            'Pipeline dispatched for ' + sourceRecordIds.size() + ' records. BatchId: ' + dispatched.batchId
        );
        result.batchId = dispatched.batchId;
        return result;
    }

    // ==================================================================================
    // BULK DISPATCH — INTERNAL (DLQ pattern)
    // ==================================================================================

    private static DispatchResult dispatchBulk(String pipelineDeveloperName, List<Id> sourceRecordIds, String triggerSource) {
        String logPrefix = LOG_PREFIX + '[dispatchBulk ' + pipelineDeveloperName + '] ';

        if (String.isBlank(pipelineDeveloperName)) {
            throw new PipelineStateException('Pipeline developer name is required');
        }
        if (sourceRecordIds == null || sourceRecordIds.isEmpty()) {
            throw new PipelineStateException('At least one source record ID is required');
        }

        List<PipelineDefinition__c> defs = [
            SELECT Id
            FROM PipelineDefinition__c
            WHERE DeveloperName__c = :pipelineDeveloperName AND IsActive__c = TRUE
            LIMIT 1
        ];
        if (defs.isEmpty()) {
            throw new PipelineStateException('Active pipeline not found: ' + pipelineDeveloperName);
        }
        Id pipelineDefId = defs[0].Id;

        String effectiveTriggerSource = String.isNotBlank(triggerSource) ? triggerSource : 'Pipeline';
        String batchId = 'PBATCH-' + UUID.randomUUID().toString();
        Id userId = UserInfo.getUserId();

        List<AgentExecution__c> executions = new List<AgentExecution__c>();
        for (Id recordId : sourceRecordIds) {
            executions.add(
                new AgentExecution__c(
                    SourceRecordId__c = recordId,
                    ExecutionStatus__c = 'Pending',
                    ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                    ExecutionType__c = 'Pipeline',
                    PipelineDefinition__c = pipelineDefId,
                    User__c = userId,
                    TriggerSource__c = effectiveTriggerSource,
                    CurrentTurnIdentifier__c = UUID.randomUUID().toString(),
                    StartTime__c = Datetime.now(),
                    LastActivityTime__c = Datetime.now(),
                    BatchId__c = batchId,
                    RetryCount__c = 0,
                    MaxRetries__c = 3
                )
            );
        }
        insert executions;

        System.debug(LoggingLevel.INFO, logPrefix + 'Created ' + executions.size() + ' pipeline executions. BatchId: ' + batchId);

        Integer workerCount = Math.min(AIAgentFrameworkSettings.calculateOptimalWorkerCount(executions.size()), executions.size());

        for (Integer i = 0; i < workerCount; i++) {
            enqueueQueueable(new PipelineExecutionWorker(pipelineDefId, executions[i].Id), logPrefix, null);
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued ' + workerCount + ' PipelineExecutionWorker(s) for ' + executions.size() + ' records');

        DispatchResult result = new DispatchResult();
        result.batchId = batchId;
        result.executionIds = new List<Id>();
        for (AgentExecution__c exec : executions) {
            result.executionIds.add(exec.Id);
        }
        result.enqueuedWorkerCount = workerCount;
        return result;
    }

    // ==================================================================================
    // PIPELINE INITIATION (instance)
    // ==================================================================================

    private Id initiatePipeline(Id sourceRecordId, String triggerSource, String logPrefix) {
        Id userId = UserInfo.getUserId();
        String effectiveTriggerSource = String.isNotBlank(triggerSource) ? triggerSource : 'Pipeline';

        AgentStateService execSvc = new AgentStateService();
        Id parentExecutionId = execSvc.createExecution(
            AIAgentConstants.EXECUTION_MODE_PIPELINE,
            null,
            effectiveTriggerSource,
            null,
            sourceRecordId,
            userId,
            null
        );

        // Set PipelineDefinition lookup on execution
        update new AgentExecution__c(Id = parentExecutionId, PipelineDefinition__c = this.pipelineDefinitionId);

        System.debug(logPrefix + 'Created parent execution: ' + parentExecutionId);

        // 2. Bootstrap: create PipelineRunStep__c records and enqueue first child
        bootstrapExecution(parentExecutionId);

        return parentExecutionId;
    }

    /**
     * @description Initialises a pre-existing pipeline execution: creates PipelineRunStep__c
     * state records and enqueues the first child agent. All context (sourceRecordId, userId,
     * turnIdentifier) is read from the AgentExecution__c record.
     *
     * Called from two paths:
     * - Synchronous: initiatePipeline() after creating the parent execution
     * - Async DLQ: PipelineExecutionWorker after claiming a Pending pipeline execution
     *
     * Requires configurePipeline() to be called first.
     */
    public void bootstrapExecution(Id parentExecutionId) {
        String logPrefix = LOG_PREFIX + '[bootstrap Exec:' + parentExecutionId + '] ';

        AgentExecution__c exec = [
            SELECT SourceRecordId__c, User__c, CurrentTurnIdentifier__c, TriggerSource__c
            FROM AgentExecution__c
            WHERE Id = :parentExecutionId
            LIMIT 1
        ];

        String turnIdentifier = exec.CurrentTurnIdentifier__c;
        Id userId = exec.User__c;
        Id sourceRecordId = exec.SourceRecordId__c;
        String effectiveTriggerSource = String.isNotBlank(exec.TriggerSource__c) ? exec.TriggerSource__c : 'Pipeline';

        IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(parentExecutionId, turnIdentifier, userId);

        PipelineState state = new PipelineState();
        initializeState(state, pipelineSteps);

        PipelineStepConfig firstStep = pipelineSteps[0];
        String firstStepKey = stepKey(firstStep.stepOrder);
        setCurrentStep(state, firstStepKey);

        System.debug(logPrefix + 'Initialised pipeline state with ' + pipelineSteps.size() + ' steps');

        // Log pipeline initiation
        List<String> stepNames = new List<String>();
        for (PipelineStepConfig s : pipelineSteps) {
            stepNames.add(s.agentName);
        }
        String initMessage =
            'Starting pipeline: ' +
            pipelineDef.DeveloperName__c +
            ' with ' +
            pipelineSteps.size() +
            ' steps: ' +
            String.join(stepNames, ' → ');
        String userName = getUserName(userId);
        decisionLogger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ initMessage, userName, pipelineDef.Name });

        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.sourceRecordId = sourceRecordId;
        payload.userId = userId;
        payload.turnIdentifier = turnIdentifier;
        payload.triggerSource = effectiveTriggerSource;

        Id childExecutionId = enqueueChildAgent(firstStep, parentExecutionId, payload, logPrefix, null, false);

        // Persist child execution ID in state so onChildComplete can validate
        state.steps.get(firstStepKey).executionId = String.valueOf(childExecutionId);
        Map<String, Id> stepRecordIds = new Map<String, Id>();
        saveState(parentExecutionId, state, stepRecordIds);

        decisionLogger.log(IDecisionStepLogger.EventType.CONTEXT_GATHERED, new List<Object>{ firstStep, pipelineSteps, childExecutionId });
        decisionLogger.commitSteps();

        System.debug(logPrefix + 'Pipeline bootstrap complete');
    }

    // ==================================================================================
    // CHILD COMPLETION CALLBACK
    // ==================================================================================

    /**
     * @description Called by AgentExecutionTriggerHandler when a child execution completes.
     * @param parentExecutionId The pipeline parent execution Id
     * @param asyncPayload Payload containing completedAgent, childExecutionId, success, response, etc.
     */
    public void onChildComplete(Id parentExecutionId, Map<String, Object> asyncPayload) {
        String logPrefix = LOG_PREFIX + '[onChildComplete Exec:' + parentExecutionId + '] ';

        if (parentExecutionId == null || asyncPayload == null) {
            throw new PipelineStateException('parentExecutionId and asyncPayload are required');
        }

        String completedAgent = (String) asyncPayload.get('completedAgent');
        Id childExecutionId = parseIdFromPayload(asyncPayload, 'childExecutionId');
        Boolean success = (Boolean) asyncPayload.get('success');
        String response = (String) asyncPayload.get('response');

        if (String.isBlank(completedAgent) || success == null) {
            throw new PipelineStateException('completedAgent and success flag are required in asyncPayload');
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Child completed: ' + completedAgent + ', success=' + success);

        try {
            AgentExecution__c execution = [
                SELECT CurrentTurnIdentifier__c, User__c, SourceRecordId__c
                FROM AgentExecution__c
                WHERE Id = :parentExecutionId
                LIMIT 1
            ];

            IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(parentExecutionId, execution.CurrentTurnIdentifier__c, execution.User__c);

            // Load persisted state
            PipelineState state = new PipelineState();
            Map<String, Id> stepRecordIds = new Map<String, Id>();
            loadState(parentExecutionId, state, stepRecordIds);

            // Resolve which step should be completing — use the canonical step key,
            // not completedAgent (agent name), to handle duplicate-agent pipelines.
            String currentStepKey = state.currentStep;
            if (String.isBlank(currentStepKey) || !state.steps.containsKey(currentStepKey)) {
                throw new PipelineStateException('No current step set in pipeline state');
            }

            StepInfo currentStepInfo = state.steps.get(currentStepKey);

            // Issue #10 — stale callback guard: verify the completing child execution
            // matches what we enqueued for this step. After a pipeline resume, the old
            // child may still complete and fire this callback — reject it.
            if (
                currentStepInfo != null &&
                String.isNotBlank(currentStepInfo.executionId) &&
                !String.valueOf(childExecutionId).equals(currentStepInfo.executionId)
            ) {
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix +
                        'Stale child completion rejected. Expected execution ' +
                        currentStepInfo.executionId +
                        ' for step ' +
                        currentStepKey +
                        ', received ' +
                        childExecutionId +
                        '. Ignoring.'
                );
                return;
            }

            // Sanity-check: verify the completing agent matches the expected agent for this step
            PipelineStepConfig expectedConfig = findStepConfig(currentStepKey);
            if (expectedConfig != null && !expectedConfig.agentName.equals(completedAgent)) {
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix +
                        'Unexpected agent completion. Expected ' +
                        expectedConfig.agentName +
                        ' for step ' +
                        currentStepKey +
                        ', received ' +
                        completedAgent +
                        '. Ignoring.'
                );
                return;
            }

            if (!success) {
                handleChildFailure(parentExecutionId, completedAgent, childExecutionId, asyncPayload, state, stepRecordIds, decisionLogger, logPrefix);
                return;
            }

            List<ContextManagerService.ContextDeltaItem> propagatedDeltaItems = new ContextManagerService()
                .deserializePayloadContextEffects(asyncPayload.get('contextEffects'));
            if (!propagatedDeltaItems.isEmpty()) {
                try {
                    new ContextManagerService().commitContextDelta(parentExecutionId, 0, propagatedDeltaItems);
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Failed to propagate child context anchors to pipeline parent: ' + e.getMessage());
                }
            }

            // Mark step complete
            markStepComplete(state, currentStepKey, childExecutionId, response);
            System.debug(LoggingLevel.INFO, logPrefix + 'Step completed: ' + completedAgent + '. ' + getProgressSummary(state));

            decisionLogger.log(IDecisionStepLogger.EventType.TOOL_RESULT, new List<Object>{ completedAgent, childExecutionId, response, null });

            // Find next step
            PipelineStepConfig nextStep = getNextStep(currentStepKey);

            if (nextStep == null) {
                if (!areAllStepsComplete(state)) {
                    throw new PipelineStateException('Pipeline reached end of steps but not all steps are complete. ' + getProgressSummary(state));
                }
                completePipeline(parentExecutionId, state, stepRecordIds, decisionLogger, logPrefix);
            } else {
                String nextStepKey = stepKey(nextStep.stepOrder);
                setCurrentStep(state, nextStepKey);

                System.debug(logPrefix + 'Advancing to: ' + nextStep.agentName);

                AgentExecutionService.ExecutionPayload nextPayload = buildPayloadForNextStep(parentExecutionId, nextStepKey, state, execution);
                Id nextChildExecId = enqueueChildAgent(nextStep, parentExecutionId, nextPayload, logPrefix, null, true);

                // Persist next child execution ID in state for stale-callback validation
                state.steps.get(nextStepKey).executionId = String.valueOf(nextChildExecId);
                saveState(parentExecutionId, state, stepRecordIds);

                decisionLogger.log(IDecisionStepLogger.EventType.CONTEXT_GATHERED, new List<Object>{ nextStep, pipelineSteps, nextChildExecId });
                decisionLogger.commitSteps();
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            failPipeline(parentExecutionId, 'Error processing pipeline step: ' + e.getMessage(), logPrefix);
        }
    }

    // ==================================================================================
    // CHILD AGENT EXECUTION
    // ==================================================================================

    /**
     * @description Executes a child agent within a pipeline (called from UnifiedAgentQueueable).
     */
    public void runChildAgent(Map<String, Object> payload, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing pipeline child agent');
        Long startTime = System.currentTimeMillis();

        Id childExecutionId = (Id) payload.get('childExecutionId');
        Id parentExecutionId = (Id) payload.get('parentExecutionId');
        String agentType = (String) payload.get('agentType');
        Id agentDefinitionId = (Id) payload.get('agentDefinitionId');
        Id userId = (Id) payload.get('userId');
        String turnIdentifier = (String) payload.get('turnIdentifier');
        Id sourceRecordId = (Id) payload.get('sourceRecordId');
        String userMessage = (String) payload.get('userMessage');

        Boolean success = false;
        String errorMessage = null;

        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefinitionId);
            if (agentDef == null) {
                throw new PipelineStateException('Agent definition not found: ' + agentDefinitionId);
            }

            AgentExecution__c childExec = [
                SELECT Id, ExecutionStatus__c, CurrentTurnIdentifier__c
                FROM AgentExecution__c
                WHERE Id = :childExecutionId
                LIMIT 1
            ];

            List<ExecutionStep__c> existingSteps = [SELECT Id FROM ExecutionStep__c WHERE AgentExecution__c = :childExecutionId LIMIT 1];
            Boolean hasSteps = !existingSteps.isEmpty();
            String childStatus = childExec.ExecutionStatus__c;

            if (childStatus == 'Completed' || childStatus == 'Processing') {
                System.debug(logPrefix + 'Child already ' + childStatus + ' — skipping');
                return;
            }

            Boolean shouldResume = (childStatus == 'Failed') || (childStatus == 'Pending' && hasSteps);
            AgentExecutionService.ExecutionResult result;

            if (shouldResume) {
                String interactionChannel = RuntimeRegistryService.getInteractionChannel(agentDef, childExecutionId);
                IExecutionStrategy childStrategy = ExecutionStrategyRegistryService.resolveStrategy(agentDef, interactionChannel);
                ExecutionResumeModels.ResumeOptions opts = new ExecutionResumeModels.ResumeOptions().withReason('Pipeline child agent resume');
                result = childStrategy.resumeExecution(childExecutionId, opts, agentDef);
            } else {
                AgentExecutionService.ExecutionPayload execPayload = new AgentExecutionService.ExecutionPayload();
                execPayload.userId = userId;
                execPayload.userMessage = userMessage;
                execPayload.sourceRecordId = sourceRecordId;
                execPayload.currentRecordId = sourceRecordId;
                execPayload.turnIdentifier = turnIdentifier;
                execPayload.existingExecutionId = childExecutionId;
                execPayload.triggerSource = 'Pipeline';
                execPayload.interactionChannel = RuntimeRegistryService.getInteractionChannel(agentDef, childExecutionId);
                result = AgentExecutionService.startExecution(agentDef.DeveloperName__c, execPayload);
            }

            success = result.success;
            if (!result.success) {
                errorMessage = result.errorMessage;
            }

            if (result.status == 'Processing') {
                System.debug(logPrefix + 'Child is async (Processing) — waiting for trigger callback');
                return;
            }

            updateChildExecution(childExecutionId, success, logPrefix, errorMessage);
        } catch (Exception e) {
            success = false;
            errorMessage = e.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + 'Exception: ' + e.getMessage() + '\n' + e.getStackTraceString());

            try {
                update new AgentExecution__c(
                    Id = childExecutionId,
                    ExecutionStatus__c = 'Failed',
                    ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                    EndTime__c = Datetime.now(),
                    ErrorMessage__c = errorMessage
                );
            } catch (Exception updateEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update child execution: ' + updateEx.getMessage());
            }
        }
    }

    // ==================================================================================
    // RESUME
    // ==================================================================================

    /**
     * @description Whether a pipeline execution can be resumed.
     */
    public Boolean canResume(Id executionId) {
        List<AgentExecution__c> execs = [
            SELECT ExecutionStatus__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];
        if (execs.isEmpty()) {
            return false;
        }
        String status = execs[0].ExecutionStatus__c;
        return status == 'Failed' || status == 'Pending';
    }

    /**
     * @description Resumes a failed pipeline execution from the failed/in-progress step.
     */
    public void resume(Id executionId) {
        String logPrefix = LOG_PREFIX + '[resume Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Resuming pipeline');

        AgentExecution__c execution = [
            SELECT Id, ExecutionStatus__c, CurrentTurnIdentifier__c, User__c, SourceRecordId__c, PipelineDefinition__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];

        if (this.pipelineDef == null && execution.PipelineDefinition__c != null) {
            configurePipeline(execution.PipelineDefinition__c);
        }

        PipelineState state = new PipelineState();
        Map<String, Id> stepRecordIds = new Map<String, Id>();
        loadState(executionId, state, stepRecordIds);

        String stepToResumeName = findStepToResume(state);
        if (String.isBlank(stepToResumeName)) {
            throw new PipelineStateException('No resumable step found. ' + getProgressSummary(state));
        }

        StepInfo stepInfo = state.steps.get(stepToResumeName);

        // Capture the child execution ID before resetting (needed for resume context)
        String failedChildExecutionId = stepInfo.executionId;

        // Increment retry count for the step being resumed
        Integer currentRetry = state.retryCounts.get(stepToResumeName) ?? 0;
        state.retryCounts.put(stepToResumeName, currentRetry + 1);
        String stepDisplayName = agentNameForKey(stepToResumeName);
        System.debug(LoggingLevel.INFO, logPrefix + 'Retry count for step ' + stepDisplayName + ': ' + (currentRetry + 1));

        // Reset step
        stepInfo.status = 'pending';
        stepInfo.startTime = null;
        stepInfo.endTime = null;

        setCurrentStep(state, stepToResumeName);
        saveState(executionId, state, stepRecordIds);

        // Generate a new turn identifier
        String newTurnIdentifier = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(32);
        update new AgentExecution__c(Id = executionId, CurrentTurnIdentifier__c = newTurnIdentifier);

        AgentStateService execSvc = new AgentStateService();
        execSvc.updateStatus(
            executionId,
            'Processing',
            AIAgentConstants.STATUS_PROCESSING,
            newTurnIdentifier,
            'Pipeline resumed from step: ' + stepDisplayName
        );

        // Log resume
        IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(executionId, newTurnIdentifier, execution.User__c);
        decisionLogger.log(IDecisionStepLogger.EventType.AGENT_RESUMED, new List<Object>{ 'pipeline', stepDisplayName });
        decisionLogger.commitSteps();

        // Find step config and resume child
        PipelineStepConfig stepConfig = findStepConfig(stepToResumeName);
        if (stepConfig == null) {
            throw new PipelineStateException('Step configuration not found: ' + stepToResumeName);
        }

        if (String.isNotBlank(failedChildExecutionId)) {
            AIAgentDefinition__c childAgentDef = AIAgentConfigService.getAgentDefinition(stepConfig.agentDefinitionId);
            if (childAgentDef == null) {
                throw new PipelineStateException('Agent definition not found: ' + stepConfig.agentDefinitionId);
            }

            String interactionChannel = RuntimeRegistryService.getInteractionChannel(childAgentDef, Id.valueOf(failedChildExecutionId));
            IExecutionStrategy childStrategy = ExecutionStrategyRegistryService.resolveStrategy(childAgentDef, interactionChannel);
            ExecutionResumeModels.ResumeOptions opts = new ExecutionResumeModels.ResumeOptions().withReason('Pipeline child agent resume');
            childStrategy.resumeExecution(Id.valueOf(failedChildExecutionId), opts, childAgentDef);
        } else {
            AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
            payload.userId = execution.User__c;
            payload.turnIdentifier = newTurnIdentifier;
            payload.sourceRecordId = execution.SourceRecordId__c;
            payload.triggerSource = 'Pipeline';

            // Fallback path only when no child execution exists to resume.
            String baseMessage = '';
            String previousOutput = getPreviousStepOutput(state, stepToResumeName);
            if (String.isNotBlank(previousOutput)) {
                baseMessage = 'Previous step output: ' + previousOutput + '\n\n';
            }

            String resumeContext = buildResumeContext(failedChildExecutionId, logPrefix);
            if (String.isNotBlank(resumeContext)) {
                payload.userMessage = resumeContext + '\n\n' + baseMessage + 'Resuming pipeline from step: ' + stepDisplayName;
            } else {
                payload.userMessage = baseMessage + 'Resuming pipeline from step: ' + stepDisplayName;
            }

            Id resumedChildExecId = enqueueChildAgent(stepConfig, executionId, payload, logPrefix, null, false);

            // Persist child execution ID in state for stale-callback validation
            stepInfo.executionId = String.valueOf(resumedChildExecId);
            saveState(executionId, state, stepRecordIds);
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Pipeline resumed from step: ' + stepDisplayName);
    }

    // ==================================================================================
    // STATE MANAGEMENT (PipelineRunStep__c)
    // ==================================================================================

    private void initializeState(PipelineState state, List<PipelineStepConfig> steps) {
        if (steps == null || steps.isEmpty()) {
            throw new PipelineStateException('Steps required to initialise pipeline');
        }
        state.steps.clear();
        state.retryCounts.clear();
        for (PipelineStepConfig cfg : steps) {
            if (String.isBlank(cfg.agentName)) {
                continue;
            }
            StepInfo si = new StepInfo();
            si.stepOrder = cfg.stepOrder;
            String key = stepKey(cfg.stepOrder);
            state.steps.put(key, si);
            state.retryCounts.put(key, 0);
        }
    }

    private void loadState(Id executionId, PipelineState state, Map<String, Id> stepRecordIds) {
        AgentExecution__c exec = [
            SELECT CurrentPipelineStep__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];
        state.currentStep = exec.CurrentPipelineStep__c;

        List<PipelineRunStep__c> records = [
            SELECT Id, StepName__c, StepOrder__c, Status__c, StartTime__c, EndTime__c, ChildExecution__c, RetryCount__c, Response__c, ErrorMessage__c
            FROM PipelineRunStep__c
            WHERE AgentExecution__c = :executionId
            ORDER BY StepOrder__c ASC
        ];

        if (!records.isEmpty()) {
            state.steps.clear();
            state.retryCounts.clear();
            stepRecordIds.clear();
            for (PipelineRunStep__c rec : records) {
                String key = stepKey(Integer.valueOf(rec.StepOrder__c));
                stepRecordIds.put(key, rec.Id);
                StepInfo si = new StepInfo();
                si.status = rec.Status__c;
                si.stepOrder = Integer.valueOf(rec.StepOrder__c);
                if (rec.ChildExecution__c != null) {
                    si.executionId = String.valueOf(rec.ChildExecution__c);
                }
                if (rec.StartTime__c != null) {
                    si.startTime = rec.StartTime__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
                }
                if (rec.EndTime__c != null) {
                    si.endTime = rec.EndTime__c.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
                }
                si.response = rec.Response__c;
                state.steps.put(key, si);
                state.retryCounts.put(key, Integer.valueOf(rec.RetryCount__c ?? 0));
            }
        }
    }

    private void saveState(Id executionId, PipelineState state, Map<String, Id> stepRecordIds) {
        Savepoint sp = Database.setSavepoint();
        try {
            Set<String> stepKeys = state.steps.keySet();
            Set<Decimal> stepOrders = new Set<Decimal>();
            for (String key : stepKeys) {
                stepOrders.add(Decimal.valueOf(key));
            }

            Map<String, Id> existingIds = new Map<String, Id>();
            for (PipelineRunStep__c existing : [
                SELECT Id, StepOrder__c
                FROM PipelineRunStep__c
                WHERE AgentExecution__c = :executionId AND StepOrder__c IN :stepOrders
            ]) {
                existingIds.put(stepKey(Integer.valueOf(existing.StepOrder__c)), existing.Id);
            }

            List<PipelineRunStep__c> toInsert = new List<PipelineRunStep__c>();
            List<PipelineRunStep__c> toUpdate = new List<PipelineRunStep__c>();

            for (String key : stepKeys) {
                StepInfo si = state.steps.get(key);
                Integer retryCount = state.retryCounts.get(key) ?? 0;
                PipelineRunStep__c rec = new PipelineRunStep__c();

                if (stepRecordIds.containsKey(key)) {
                    rec.Id = stepRecordIds.get(key);
                } else if (existingIds.containsKey(key)) {
                    rec.Id = existingIds.get(key);
                    stepRecordIds.put(key, rec.Id);
                } else {
                    rec.AgentExecution__c = executionId;
                    rec.StepName__c = agentNameForKey(key);
                    rec.StepOrder__c = si.stepOrder;
                }

                rec.Status__c = si.status;
                rec.RetryCount__c = retryCount;
                rec.IsCurrentStep__c = (key == state.currentStep);
                if (String.isNotBlank(si.startTime)) {
                    rec.StartTime__c = parseIso8601(si.startTime);
                }
                if (String.isNotBlank(si.endTime)) {
                    rec.EndTime__c = parseIso8601(si.endTime);
                }
                if (rec.StartTime__c != null && rec.EndTime__c != null) {
                    rec.DurationMs__c = rec.EndTime__c.getTime() - rec.StartTime__c.getTime();
                }
                if (String.isNotBlank(si.executionId)) {
                    rec.ChildExecution__c = Id.valueOf(si.executionId);
                }
                if (String.isNotBlank(si.response)) {
                    rec.Response__c = si.response.length() > 131072 ? si.response.substring(0, 131072) : si.response;
                }

                if (rec.Id != null) {
                    toUpdate.add(rec);
                } else {
                    toInsert.add(rec);
                }
            }

            if (!toInsert.isEmpty()) {
                insert toInsert;
                for (PipelineRunStep__c ins : toInsert) {
                    stepRecordIds.put(stepKey(Integer.valueOf(ins.StepOrder__c)), ins.Id);
                }
            }
            if (!toUpdate.isEmpty()) {
                update toUpdate;
            }

            // Store step key on execution — loadState reads it back as state.currentStep.
            // PipelineRunStep__c.IsCurrentStep__c provides the display-friendly marker.
            update new AgentExecution__c(Id = executionId, CurrentPipelineStep__c = state.currentStep);
        } catch (Exception e) {
            Database.rollback(sp);
            throw new PipelineStateException('Failed to save pipeline state: ' + e.getMessage());
        }
    }

    private void setCurrentStep(PipelineState state, String stepName) {
        if (!state.steps.containsKey(stepName)) {
            throw new PipelineStateException('Step not found: ' + stepName);
        }
        state.currentStep = stepName;
        StepInfo si = state.steps.get(stepName);
        si.status = 'in_progress';
        si.startTime = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }

    private void markStepComplete(PipelineState state, String stepName, Id childExecutionId, String response) {
        if (!state.steps.containsKey(stepName)) {
            throw new PipelineStateException('Step not found: ' + stepName);
        }
        StepInfo si = state.steps.get(stepName);
        si.status = 'completed';
        si.executionId = String.valueOf(childExecutionId);
        si.endTime = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        si.response = response;
    }

    private void markStepFailed(PipelineState state, String stepName, Id childExecutionId) {
        if (!state.steps.containsKey(stepName)) {
            throw new PipelineStateException('Step not found: ' + stepName);
        }
        StepInfo si = state.steps.get(stepName);
        si.status = 'failed';
        si.endTime = Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        if (childExecutionId != null) {
            si.executionId = String.valueOf(childExecutionId);
        }
    }

    private Boolean areAllStepsComplete(PipelineState state) {
        if (state.steps.isEmpty()) {
            return false;
        }
        for (StepInfo si : state.steps.values()) {
            if (si.status != 'completed') {
                return false;
            }
        }
        return true;
    }

    private String getProgressSummary(PipelineState state) {
        Integer total = state.steps.size();
        Integer completed = 0, failed = 0, inProgress = 0, pending = 0;
        for (StepInfo si : state.steps.values()) {
            if (si.status == 'completed') {
                completed++;
            } else if (si.status == 'failed') {
                failed++;
            } else if (si.status == 'in_progress') {
                inProgress++;
            } else {
                pending++;
            }
        }
        return 'Pipeline: ' +
            completed +
            '/' +
            total +
            ' completed, ' +
            inProgress +
            ' in-progress, ' +
            pending +
            ' pending, ' +
            failed +
            ' failed. Current: ' +
            (state.currentStep ?? 'none');
    }

    // ==================================================================================
    // CHILD ENQUEUE
    // ==================================================================================

    private Id enqueueChildAgent(
        PipelineStepConfig step,
        Id parentExecutionId,
        AgentExecutionService.ExecutionPayload payload,
        String logPrefix,
        Id existingChildExecId,
        Boolean treatAsFreshRoot
    ) {
        try {
            String baseTurn = String.isNotBlank(payload.turnIdentifier)
                ? payload.turnIdentifier
                : EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(32);
            String stepScopedTurn = baseTurn + '-ps-' + step.stepOrder;

            Id childExecutionId;
            if (existingChildExecId != null) {
                childExecutionId = existingChildExecId;
                update new AgentExecution__c(
                    Id = childExecutionId,
                    ExecutionStatus__c = 'Pending',
                    ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                    CurrentTurnIdentifier__c = stepScopedTurn,
                    LastActivityTime__c = Datetime.now()
                );
            } else {
                childExecutionId = getOrCreateChildExecution(step, parentExecutionId, payload, stepScopedTurn);
            }

            Map<String, Object> jobPayload = new Map<String, Object>{
                'childExecutionId' => childExecutionId,
                'parentExecutionId' => parentExecutionId,
                'agentType' => step.agentName,
                'agentDefinitionId' => step.agentDefinitionId,
                'sourceRecordId' => payload.sourceRecordId,
                'userId' => payload.userId,
                'userMessage' => buildUserMessageForStep(step, payload),
                'turnIdentifier' => stepScopedTurn,
                'jobType' => 'PipelineChild'
            };

            enqueueQueueable(
                new AgentExecutionWorker(step.agentName, buildWorkerPayload(step, childExecutionId, parentExecutionId, payload, stepScopedTurn)),
                logPrefix,
                step.agentDefinitionId,
                treatAsFreshRoot
            );
            System.debug(logPrefix + 'Enqueued child agent for step ' + step.stepOrder + ' (' + step.agentName + ')');
            return childExecutionId;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to enqueue child agent: ' + e.getMessage());
            throw new PipelineStateException('Failed to enqueue child agent: ' + e.getMessage());
        }
    }

    private static Id enqueueQueueable(Queueable job, String logPrefix, Id agentDefinitionId) {
        return enqueueQueueable(job, logPrefix, agentDefinitionId, false);
    }

    private static Id enqueueQueueable(Queueable job, String logPrefix, Id agentDefinitionId, Boolean treatAsFreshRoot) {
        return new AgentJobEnqueuer().enqueueQueueable(job, logPrefix, agentDefinitionId, treatAsFreshRoot);
    }

    private AgentExecutionService.ExecutionPayload buildWorkerPayload(
        PipelineStepConfig step,
        Id childExecId,
        Id parentExecId,
        AgentExecutionService.ExecutionPayload source,
        String turn
    ) {
        AgentExecutionService.ExecutionPayload p = new AgentExecutionService.ExecutionPayload();
        p.existingExecutionId = childExecId;
        p.userId = source.userId;
        p.userMessage = buildUserMessageForStep(step, source);
        p.sourceRecordId = source.sourceRecordId;
        p.currentRecordId = source.sourceRecordId;
        p.turnIdentifier = turn;
        p.triggerSource = 'Pipeline';
        return p;
    }

    private Id getOrCreateChildExecution(PipelineStepConfig step, Id parentExecutionId, AgentExecutionService.ExecutionPayload payload, String stepScopedTurn) {
        List<AgentExecution__c> existing = [
            SELECT Id
            FROM AgentExecution__c
            WHERE ParentExecution__c = :parentExecutionId AND CurrentTurnIdentifier__c = :stepScopedTurn
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }

        AgentStateService execSvc = new AgentStateService();
        AIAgentConfigService.ResolvedExecutionIdentity executionIdentity = new AIAgentConfigService.ResolvedExecutionIdentity();
        if (step.agentDefinitionId != null) {
            executionIdentity = AIAgentConfigService.resolveExecutionIdentityForAgent(AIAgentConfigService.getAgentDefinition(step.agentDefinitionId));
        }
        return execSvc.createExecution(
            step.strategyKey,
            step.agentDefinitionId,
            'Pipeline',
            'Pipeline Step: ' + step.agentName,
            payload.sourceRecordId,
            payload.userId,
            null,
            parentExecutionId,
            stepScopedTurn,
            executionIdentity.profileDeveloperName,
            executionIdentity.namedCredentialDeveloperName
        );
    }

    // ==================================================================================
    // COMPLETION AND FAILURE
    // ==================================================================================

    private void completePipeline(
        Id executionId,
        PipelineState state,
        Map<String, Id> stepRecordIds,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        state.currentStep = null;
        saveState(executionId, state, stepRecordIds);

        decisionLogger.log(IDecisionStepLogger.EventType.FINAL_RESPONSE, new List<Object>{ null });
        decisionLogger.commitSteps();

        AgentStateService execSvc = new AgentStateService();
        execSvc.updateStatus(executionId, 'Completed', AIAgentConstants.STATUS_IDLE, null, 'All pipeline steps completed. ' + getProgressSummary(state));

        System.debug(LoggingLevel.INFO, logPrefix + 'Pipeline completed: ' + executionId);
    }

    private void failPipeline(Id executionId, String failureMessage, String logPrefix) {
        try {
            List<AgentExecution__c> execs = [SELECT CurrentTurnIdentifier__c, User__c FROM AgentExecution__c WHERE Id = :executionId LIMIT 1];
            if (!execs.isEmpty()) {
                IDecisionStepLogger.ILogger dl = IDecisionStepLogger.create(executionId, execs[0].CurrentTurnIdentifier__c, execs[0].User__c);
                dl.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ executionId, failureMessage });
                dl.commitSteps();
            }
            AgentStateService execSvc = new AgentStateService();
            execSvc.updateStatus(executionId, 'Failed', AIAgentConstants.STATUS_IDLE, null, failureMessage);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update pipeline status: ' + e.getMessage());
        }
    }

    private void handleChildFailure(
        Id executionId,
        String failedAgent,
        Id childExecutionId,
        Map<String, Object> asyncPayload,
        PipelineState state,
        Map<String, Id> stepRecordIds,
        IDecisionStepLogger.ILogger decisionLogger,
        String logPrefix
    ) {
        String errorMessage = (String) asyncPayload.get('errorMessage');
        System.debug(LoggingLevel.ERROR, logPrefix + 'Child failed: ' + failedAgent + ', Error: ' + errorMessage);

        Map<String, Object> errorDetails = new Map<String, Object>{
            'childAgent' => failedAgent,
            'childExecutionId' => childExecutionId,
            'progress' => getProgressSummary(state),
            'errorMessage' => errorMessage
        };
        decisionLogger.log(IDecisionStepLogger.EventType.ERROR, new List<Object>{ failedAgent, childExecutionId, errorDetails });
        decisionLogger.commitSteps();

        String currentStepKey = state.currentStep;
        markStepFailed(state, currentStepKey, childExecutionId);
        saveState(executionId, state, stepRecordIds);

        Boolean continueOnError = this.pipelineDef != null && this.pipelineDef.ErrorHandlingMode__c == 'ContinueOnError';
        if (continueOnError) {
            PipelineStepConfig nextStep = getNextStep(currentStepKey);
            if (nextStep != null) {
                System.debug(logPrefix + 'ContinueOnError: skipping failed step, advancing to ' + nextStep.agentName);
                String nextStepKey = stepKey(nextStep.stepOrder);
                setCurrentStep(state, nextStepKey);

                AgentExecution__c exec = [SELECT SourceRecordId__c, User__c, CurrentTurnIdentifier__c FROM AgentExecution__c WHERE Id = :executionId LIMIT 1];
                AgentExecutionService.ExecutionPayload nextPayload = buildPayloadForNextStep(executionId, nextStepKey, state, exec);
                Id nextChildExecId = enqueueChildAgent(nextStep, executionId, nextPayload, logPrefix, null, false);

                state.steps.get(nextStepKey).executionId = String.valueOf(nextChildExecId);
                saveState(executionId, state, stepRecordIds);
                return;
            }
        }

        failPipeline(executionId, 'Pipeline failed: Agent "' + failedAgent + '" failed. Error: ' + errorMessage, logPrefix);
    }

    // ==================================================================================
    // STEP NAVIGATION
    // ==================================================================================

    private PipelineStepConfig getNextStep(String completedStepKey) {
        if (String.isBlank(completedStepKey) || pipelineSteps == null) {
            return null;
        }
        Integer completedOrder;
        try {
            completedOrder = Integer.valueOf(completedStepKey);
        } catch (Exception e) {
            return null;
        }
        for (Integer i = 0; i < pipelineSteps.size(); i++) {
            if (pipelineSteps[i].stepOrder == completedOrder) {
                return (i + 1 < pipelineSteps.size()) ? pipelineSteps[i + 1] : null;
            }
        }
        return null;
    }

    private PipelineStepConfig findStepConfig(String stepKeyStr) {
        Integer order;
        try {
            order = Integer.valueOf(stepKeyStr);
        } catch (Exception e) {
            return null;
        }
        for (PipelineStepConfig cfg : pipelineSteps) {
            if (cfg.stepOrder == order) {
                return cfg;
            }
        }
        return null;
    }

    private String findStepToResume(PipelineState state) {
        for (String name : state.steps.keySet()) {
            StepInfo si = state.steps.get(name);
            if (si != null && si.status == 'failed') {
                return name;
            }
        }
        for (String name : state.steps.keySet()) {
            StepInfo si = state.steps.get(name);
            if (si != null && si.status == 'in_progress') {
                return name;
            }
        }
        if (String.isNotBlank(state.currentStep)) {
            StepInfo si = state.steps.get(state.currentStep);
            if (si != null && si.status == 'pending') {
                return state.currentStep;
            }
        }
        return null;
    }

    // ==================================================================================
    // CONTEXT / PAYLOAD BUILDING
    // ==================================================================================

    private AgentExecutionService.ExecutionPayload buildPayloadForNextStep(
        Id executionId,
        String nextStepKey,
        PipelineState state,
        AgentExecution__c parentExec
    ) {
        AgentExecutionService.ExecutionPayload p = new AgentExecutionService.ExecutionPayload();
        p.sourceRecordId = parentExec.SourceRecordId__c;
        p.userId = parentExec.User__c;
        p.turnIdentifier = parentExec.CurrentTurnIdentifier__c;
        p.triggerSource = 'Pipeline';
        p.userMessage = buildContextAwareMessage(nextStepKey, state, parentExec.SourceRecordId__c);
        return p;
    }

    @TestVisible
    private String buildContextAwareMessage(String nextStepKey, PipelineState state, Id sourceRecordId) {
        List<String> parts = new List<String>();
        String displayName = getStepDisplayName(nextStepKey);
        parts.add('Execute pipeline step: ' + displayName);

        if (sourceRecordId != null) {
            try {
                String objType = sourceRecordId.getSObjectType().getDescribe().getLabel();
                parts.add(objType + ' ID: ' + sourceRecordId);
            } catch (Exception e) {
                parts.add('Record ID: ' + sourceRecordId);
            }
        }

        Integer nextOrder;
        try {
            nextOrder = Integer.valueOf(nextStepKey);
        } catch (Exception e) {
            nextOrder = 2147483647;
        }

        List<String> previousOutputs = new List<String>();
        for (PipelineStepConfig step : pipelineSteps) {
            if (step.stepOrder >= nextOrder) {
                break;
            }
            String key = stepKey(step.stepOrder);
            StepInfo si = state.steps.get(key);
            if (si != null && si.status == 'completed' && String.isNotBlank(si.response)) {
                previousOutputs.add('**' + step.agentDisplayName + ' (Step ' + step.stepOrder + ') completed with:**\n' + si.response);
            }
        }

        if (!previousOutputs.isEmpty()) {
            parts.add('\n\n**Previous pipeline steps have provided the following context:**\n');
            String mostRecent = previousOutputs[previousOutputs.size() - 1];
            List<String> older = new List<String>();
            for (Integer i = 0; i < previousOutputs.size() - 1; i++) {
                older.add(truncate(previousOutputs[i], MAX_OLDER_STEP_CHARS));
            }
            String ctx = '';
            String olderBlock = String.join(older, '\n\n');
            if (String.isNotBlank(olderBlock)) {
                ctx += '**Earlier step summaries:**\n' + olderBlock + '\n\n';
            }
            ctx += '**Most recent step output:**\n' + mostRecent;
            if (ctx.length() > MAX_CONTEXT_CHARS) {
                ctx = truncate(ctx, MAX_CONTEXT_CHARS);
            }
            parts.add(ctx);
            parts.add('\n**Please use this context to inform your response.**\n');
        }

        return String.join(parts, '\n');
    }

    private String buildUserMessageForStep(PipelineStepConfig step, AgentExecutionService.ExecutionPayload payload) {
        if (String.isNotBlank(payload.userMessage)) {
            return payload.userMessage;
        }
        if (step != null && step.stepOrder == 1) {
            return null;
        }
        String msg = 'Execute pipeline step: ' + step.agentDisplayName;
        if (payload.sourceRecordId != null) {
            try {
                msg += ' for ' + payload.sourceRecordId.getSObjectType().getDescribe().getLabel() + ': ' + payload.sourceRecordId;
            } catch (Exception e) {
                msg += ' for Record: ' + payload.sourceRecordId;
            }
        }
        return msg;
    }

    private String getPreviousStepOutput(PipelineState state, String currentStepKey) {
        Integer currentOrder;
        try {
            currentOrder = Integer.valueOf(currentStepKey);
        } catch (Exception e) {
            return null;
        }
        Integer currentIndex = -1;
        for (Integer i = 0; i < pipelineSteps.size(); i++) {
            if (pipelineSteps[i].stepOrder == currentOrder) {
                currentIndex = i;
                break;
            }
        }
        if (currentIndex <= 0) {
            return null;
        }
        String prevKey = stepKey(pipelineSteps[currentIndex - 1].stepOrder);
        StepInfo prevInfo = state.steps.get(prevKey);
        return (prevInfo != null && prevInfo.status == 'completed' && String.isNotBlank(prevInfo.response)) ? prevInfo.response : null;
    }

    // ==================================================================================
    // UTILITIES
    // ==================================================================================

    private String truncate(String input, Integer maxChars) {
        if (String.isBlank(input) || maxChars == null || maxChars <= 0) {
            return '';
        }
        if (input.length() <= maxChars) {
            return input;
        }
        return input.substring(0, Math.max(0, maxChars - 16)) + '\n...[truncated]';
    }

    private String getStepDisplayName(String stepKeyStr) {
        PipelineStepConfig cfg = findStepConfig(stepKeyStr);
        if (cfg != null) {
            return cfg.agentDisplayName;
        }
        return stepKeyStr;
    }

    private String getUserName(Id userId) {
        if (userId == null) {
            return 'User';
        }
        if (userNameCache.containsKey(userId)) {
            return userNameCache.get(userId);
        }
        try {
            User u = [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
            userNameCache.put(userId, u.Name);
            return u.Name;
        } catch (Exception e) {
            return 'User';
        }
    }

    private Datetime parseIso8601(String iso) {
        if (String.isBlank(iso)) {
            return null;
        }
        try {
            return Datetime.valueOfGmt(iso.replace('Z', '').replace('T', ' '));
        } catch (Exception e) {
            return null;
        }
    }

    private Id parseIdFromPayload(Map<String, Object> payload, String key) {
        Object val = payload.get(key);
        if (val instanceof Id) {
            return (Id) val;
        }
        if (val instanceof String && String.isNotBlank((String) val)) {
            try {
                return (Id) val;
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    private void updateChildExecution(Id childExecutionId, Boolean success, String logPrefix, String errorMessage) {
        try {
            AgentExecution__c childExec = new AgentExecution__c(
                Id = childExecutionId,
                ExecutionStatus__c = success ? 'Completed' : 'Failed',
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                EndTime__c = Datetime.now()
            );
            if (!success && String.isNotBlank(errorMessage)) {
                childExec.ErrorMessage__c = errorMessage;
            }
            update childExec;
        } catch (DMLException de) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update child execution: ' + de.getMessage());
        }
    }

    // ==================================================================================
    // RESUME CONTEXT — completed capability awareness
    // ==================================================================================

    /**
     * @description Builds resume context from completed capabilities in a partially-failed
     * child execution. Queries ExecutionStep__c records for successfully completed tool calls
     * and formats them into a context block that instructs the LLM to skip already-executed
     * capabilities when retrying.
     *
     * @param childExecutionId The child execution ID that may have partial completion
     * @param logPrefix Logging prefix for debug output
     * @return Resume context message, or empty string if no completed capabilities found
     */
    @TestVisible
    private String buildResumeContext(String childExecutionId, String logPrefix) {
        if (String.isBlank(childExecutionId)) {
            return '';
        }

        try {
            Id executionId = Id.valueOf(childExecutionId);

            List<ExecutionStep__c> completedSteps = [
                SELECT ToolName__c, ToolCallId__c, ToolResult__c, ToolArguments__c, Timestamp__c, ProcessingDuration__c
                FROM ExecutionStep__c
                WHERE AgentExecution__c = :executionId AND StepType__c = 'ToolResult' AND HasResult__c = TRUE
                ORDER BY Timestamp__c ASC
            ];

            if (completedSteps.isEmpty()) {
                System.debug(logPrefix + 'No completed capabilities found in execution: ' + childExecutionId);
                return '';
            }

            List<String> contextParts = new List<String>();
            contextParts.add('=== RESUME CONTEXT: CAPABILITIES ALREADY EXECUTED ===');
            contextParts.add('The following capabilities were successfully executed in a previous attempt.');
            contextParts.add('DO NOT re-execute these capabilities. Continue from where the pipeline step failed.');
            contextParts.add('');

            Integer includedCount = 0;
            for (Integer i = 0; i < completedSteps.size(); i++) {
                ExecutionStep__c step = completedSteps[i];

                Map<String, Object> resultData = null;
                try {
                    resultData = (Map<String, Object>) JSON.deserializeUntyped(step.ToolResult__c);
                } catch (Exception jsonEx) {
                    continue;
                }

                Boolean isSuccess = false;
                if (resultData != null && resultData.containsKey('isSuccess')) {
                    isSuccess = (Boolean) resultData.get('isSuccess');
                } else {
                    continue;
                }

                if (isSuccess == true) {
                    includedCount++;
                    contextParts.add('Capability ' + includedCount + ': ' + step.ToolName__c);

                    if (String.isNotBlank(step.ToolArguments__c)) {
                        String args = step.ToolArguments__c.length() > 200 ? step.ToolArguments__c.substring(0, 200) + '...' : step.ToolArguments__c;
                        contextParts.add('  Arguments: ' + args);
                    }

                    String resultSummary = extractResultSummary(resultData, step.ToolResult__c);
                    if (String.isNotBlank(resultSummary)) {
                        if (resultSummary.length() > 500) {
                            resultSummary = resultSummary.substring(0, 500) + '... (truncated)';
                        }
                        contextParts.add('  Result: ' + resultSummary);
                    }

                    if (step.ProcessingDuration__c != null) {
                        contextParts.add('  Execution time: ' + step.ProcessingDuration__c + 'ms');
                    }

                    contextParts.add('');
                }
            }

            if (includedCount == 0) {
                return '';
            }

            contextParts.add('=== END RESUME CONTEXT ===');
            contextParts.add('');

            String resumeContext = String.join(contextParts, '\n');
            System.debug(logPrefix + 'Built resume context with ' + includedCount + ' completed capabilities');
            return resumeContext;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to build resume context: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return '';
        }
    }

    /**
     * @description Extracts a human-readable summary from a tool result.
     * Prioritises llmFriendlyMessage, then data, then falls back to raw JSON.
     */
    private String extractResultSummary(Map<String, Object> resultData, String rawResult) {
        if (resultData != null) {
            if (resultData.containsKey('llmFriendlyMessage')) {
                Object msg = resultData.get('llmFriendlyMessage');
                if (msg != null) {
                    return String.valueOf(msg);
                }
            }
            if (resultData.containsKey('data')) {
                Object data = resultData.get('data');
                if (data != null) {
                    return String.valueOf(data);
                }
            }
        }
        if (String.isNotBlank(rawResult)) {
            return rawResult.length() > 500 ? rawResult.substring(0, 500) + '...' : rawResult;
        }
        return 'Success (no detailed output)';
    }
}
