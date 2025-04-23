/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Queueable Job: Step 1 or 3b (after actions). Validates session state, checks turn limit,
 *              updates session status, and queues ExecuteLLMCallQueueable.
 *              Does NOT fetch history/context or format payloads.
 */
public class PrepareLLMCallQueueable implements Queueable {
    private static final String CURRENT_JOB_EXPECTED_STATUS_1 = AIAgentConstants.STATUS_QUEUED_FOR_PROCESSING;
    private static final String CURRENT_JOB_EXPECTED_STATUS_2 = AIAgentConstants.STATUS_AWAITING_ACTION_RESULT_LLM;
    private static final String NEXT_JOB_STATUS = AIAgentConstants.STATUS_AWAITING_LLM_RESPONSE;
    private static final String NEXT_JOB_EXPECTED_HINT = AIAgentConstants.NEXT_EXPECTED_EXECUTE_LLM;
    private static final String FAILURE_STATUS = AIAgentConstants.STATUS_FAILED;

    private Id chatSessionId;
    private Id userId;
    private Id agentDefinitionId;
    private String turnIdentifier;
    private Integer currentTurnCount;

    /**
     * Constructor for PrepareLLMCallQueueable.
     * @param sessionId ID of the ChatSession__c.
     * @param requestUserId ID of the User initiating the request.
     * @param agentDefId ID of the AIAgentDefinition__c.
     * @param turnId Unique identifier for the current processing turn.
     * @param turnCount The current cycle number within the turn (starts at 1).
     */
    public PrepareLLMCallQueueable(Id sessionId, Id requestUserId, Id agentDefId, String turnId, Integer turnCount) {
        if (
            sessionId == null ||
            requestUserId == null ||
            agentDefId == null ||
            String.isBlank(turnId) ||
            turnCount == null ||
            turnCount < 1
        ) {
            String errorMsg =
                '[PrepareLLMCallQueueable] Constructor ERROR: Required IDs/TurnId/TurnCount missing or invalid. Received TurnCount: ' +
                turnCount;

            throw new IllegalArgumentException(errorMsg);
        }
        this.chatSessionId = sessionId;
        this.userId = requestUserId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
    }

    public void execute(QueueableContext context) {
        Integer seq = 0;
        String logPrefix = '[PrepareLLM:' + this.turnIdentifier?.left(8) + ' Cycle:' + this.currentTurnCount + '] ';

        AIAgentDefinition__c agentConfig = null;
        LLMConfiguration__c llmConfig = null;
        Exception processingException = null;
        Id llmConfigId;

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c, AIAgentDefinition__c
                FROM ChatSession__c
                WHERE Id = :this.chatSessionId
                LIMIT 1
                FOR UPDATE
            ];
            if (sessions.isEmpty()) {
                throw new PrepareLLMCallQueueableException('Session ' + this.chatSessionId + ' not found.');
            }
            ChatSession__c session = sessions[0];

            if (session.CurrentTurnIdentifier__c != this.turnIdentifier) {
                return;
            }

            if (session.AIAgentDefinition__c != this.agentDefinitionId) {
                throw new PrepareLLMCallQueueableException(
                    'Agent Definition mismatch between Job (' +
                        this.agentDefinitionId +
                        ') and Session (' +
                        session.AIAgentDefinition__c +
                        '). Turn: ' +
                        this.turnIdentifier
                );
            }

            String currentStatus = session.ProcessingStatus__c;
            if (currentStatus == FAILURE_STATUS) {
                return;
            }

            if (currentStatus != CURRENT_JOB_EXPECTED_STATUS_1 && currentStatus != CURRENT_JOB_EXPECTED_STATUS_2) {
                String errorMsg =
                    'Session in unexpected state: ' +
                    currentStatus +
                    '. Expected ' +
                    CURRENT_JOB_EXPECTED_STATUS_1 +
                    ' or ' +
                    CURRENT_JOB_EXPECTED_STATUS_2 +
                    '.';
                throw new PrepareLLMCallQueueableException(errorMsg);
            }

            agentConfig = AIAgentConfigService.getAgentDefinition(this.agentDefinitionId);
            if (agentConfig.LLMConfiguration__c == null) {
                throw new ConfigurationException('Missing LLM Config link on Agent Def: ' + agentConfig.Id);
            }

            llmConfigId = agentConfig.LLMConfiguration__c;

            try {
                llmConfig = AIAgentConfigService.getLLMConfiguration(llmConfigId);
            } catch (AIAgentConfigService.ConfigurationException llmEx) {
                throw new ConfigurationException(
                    'Linked LLM Configuration (' + llmConfigId + ') not found or inactive: ' + llmEx.getMessage(),
                    llmEx
                );
            }

            Integer maxTurns = loadMaxTurnsConfig(agentConfig);
            if (this.currentTurnCount > maxTurns) {
                String limitError =
                    'Processing stopped: Max interaction cycles (' +
                    maxTurns +
                    ') reached for Turn: ' +
                    this.turnIdentifier;
                throw new PrepareLLMCallQueueableException(limitError);
            }

            ChatSessionStateService.updateStatus(
                this.chatSessionId,
                NEXT_JOB_STATUS,
                NEXT_JOB_EXPECTED_HINT,
                null,
                null,
                this.turnIdentifier
            );

            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                seq++,
                OrchestrationLogger.TYPE_DISPATCH,
                OrchestrationLogger.STATUS_SUCCESS,
                'Dispatching ExecuteLLMCallQueueable Job.',
                new Map<String, Object>{
                    'jobClass' => 'ExecuteLLMCallQueueable',
                    'targetTurnCycle' => this.currentTurnCount
                },
                null,
                null,
                null,
                0L,
                null,
                null,
                null,
                llmConfigId,
                null
            );
            ExecuteLLMCallQueueable calloutJob = new ExecuteLLMCallQueueable(
                this.chatSessionId,
                this.userId,
                this.agentDefinitionId,
                llmConfigId,
                this.turnIdentifier,
                this.currentTurnCount
            );
            Id nextJobId = System.enqueueJob(calloutJob);

            try {
                ChatSessionStateService.updateStatus(
                    this.chatSessionId,
                    NEXT_JOB_STATUS,
                    NEXT_JOB_EXPECTED_HINT,
                    nextJobId,
                    null,
                    this.turnIdentifier
                );
            } catch (Exception jobDmlEx) {
            }
        } catch (Exception ex) {
            processingException = ex;
            String errorDetails = 'Exception caught during PrepareLLMCall: ' + ex.getMessage();

            OrchestrationLogger.logStep(
                this.chatSessionId,
                this.turnIdentifier,
                999,
                OrchestrationLogger.TYPE_LLM_PREP,
                OrchestrationLogger.STATUS_FAILURE,
                'Failure preparing for LLM Call.',
                null,
                null,
                errorDetails,
                ex.getTypeName(),
                null,
                null,
                null,
                null,
                llmConfigId,
                null
            );
        } finally {
            OrchestrationLogger.commitLogs();
            if (processingException != null) {
                String errorMsg = processingException.getMessage();

                String abbreviatedError = errorMsg.abbreviate(131072);

                try {
                    ChatSessionStateService.updateFinalStatus(
                        this.chatSessionId,
                        false,
                        abbreviatedError,
                        this.turnIdentifier
                    );
                } catch (Exception serviceEx) {
                }

                FinalizeTurnQueueable finalizeJob = new FinalizeTurnQueueable(
                    this.chatSessionId,
                    false,
                    null,
                    errorMsg,
                    this.turnIdentifier
                );
                try {
                    Id finalizeJobId = System.enqueueJob(finalizeJob);
                } catch (Exception finalizeQueueEx) {
                }
            }

            String finalOutcome = (processingException == null) ? 'Dispatched ExecuteLLMCall' : 'Failure';
        }
    }

    /** Loads Max Turns from Agent Config or Framework Settings */
    private Integer loadMaxTurnsConfig(AIAgentDefinition__c agentConfig) {
        return AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
    }

    public class PrepareLLMCallQueueableException extends AIAgentException {
    }
    public class ConfigurationException extends AIAgentException {
    }
    public class IllegalArgumentException extends AIAgentException {
    }
}
