/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AutonomousQueueable handles autonomous agent processing for self-directed executions.
 * This queueable is enqueued by AutonomousOrchestrator to execute goal-driven agent behavior.
 */
public class AutonomousQueueable implements Queueable, Database.AllowsCallouts {
    private final Id executionId;
    private final Id agentDefinitionId;
    private final Id llmConfigurationId;
    private final String turnIdentifier;
    private final Id userId;
    private final String goal;
    private final Map<String, Object> context;

    public AutonomousQueueable(
        Id executionId,
        Id agentDefinitionId,
        Id llmConfigurationId,
        String turnIdentifier,
        Id userId,
        String goal,
        Map<String, Object> context
    ) {
        this.executionId = executionId;
        this.agentDefinitionId = agentDefinitionId;
        this.llmConfigurationId = llmConfigurationId;
        this.turnIdentifier = turnIdentifier;
        this.userId = userId;
        this.goal = goal;
        this.context = context;
    }

    public void execute(QueueableContext qContext) {
        String logPrefix = '[AutonomousQueueable Turn:' + turnIdentifier + ' Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting autonomous processing in queueable context');

        try {
            // Initialize decision logger
            AgentDecisionStepLogger decisionLogger = new AgentDecisionStepLogger(executionId, turnIdentifier, userId);

            // Build autonomous context message
            String autonomousContext = buildAutonomousContext();
            decisionLogger.logUserInput('Autonomous Execution Started', autonomousContext, null);

            // Prepare autonomous message data
            LLMInteractionService.MessageData autonomousMessageData = new LLMInteractionService.MessageData();
            autonomousMessageData.role = AIAgentConstants.ROLE_USER;
            autonomousMessageData.content = autonomousContext;

            // Instantiate LLM interaction service
            LLMInteractionService interactionService = new LLMInteractionService(
                executionId,
                userId,
                agentDefinitionId,
                llmConfigurationId,
                turnIdentifier,
                1,
                null,
                false,
                decisionLogger
            );

            // Execute LLM interaction
            LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(autonomousMessageData);

            if (llmResult == null) {
                throw new AutonomousQueueableException('LLMInteractionService returned a null result');
            }

            // Process LLM result using orchestration service
            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome = orchestrationSvc.processLlmResult(
                llmResult,
                executionId,
                userId,
                userId,
                agentDefinitionId,
                turnIdentifier,
                1,
                autonomousMessageData,
                null,
                decisionLogger
            );

            System.debug(LoggingLevel.INFO, logPrefix + 'Autonomous processing completed successfully. Outcome: ' + outcome);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'ERROR: Autonomous processing failed. Exception: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString());

            // Mark turn as failed
            try {
                TurnLifecycleService tls = new TurnLifecycleService();
                tls.failTurn(
                    executionId,
                    turnIdentifier,
                    'Autonomous processing failed: ' + e.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception failEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'CRITICAL: Failed to update execution state after processing failure: ' + failEx.getMessage());
            }
        }
    }

    /**
     * Builds autonomous context message for LLM processing.
     */
    private String buildAutonomousContext() {
        List<String> contextParts = new List<String>();

        contextParts.add('Autonomous Execution Request');

        if (String.isNotBlank(goal)) {
            contextParts.add('Goal: ' + goal);
        }

        if (context != null && !context.isEmpty()) {
            contextParts.add('Context: ' + JSON.serialize(context));
        }

        contextParts.add('You are operating autonomously. Use available tools to achieve the goal.');

        return String.join(contextParts, '\n');
    }

    public class AutonomousQueueableException extends Exception {
    }
}
