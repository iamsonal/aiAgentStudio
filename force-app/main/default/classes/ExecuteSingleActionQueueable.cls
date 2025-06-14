/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queueable Job: Executes a single designated agent action asynchronously.
 *              Used when an action is flagged with RunAsynchronously__c=true.
 *              After execution, it saves the tool result message and enqueues FollowUpLLMQueueable.
 */
public class ExecuteSingleActionQueueable implements Queueable {
    private final Id chatSessionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final Id parentAssistantMessageId;
    private final String toolCallId;
    private final String llmArgumentsJson;
    private final String bindingConfigJson;
    private final Id actionDefinitionId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Id relatedRecordId;

    public class AsyncActionException extends AIAgentException {
    }
    public class IllegalArgumentException extends AIAgentException {
    }

    public ExecuteSingleActionQueueable(
        Id sessId,
        Id usrId,
        Id agentDefId,
        Id parentMsgId,
        String toolCallId,
        String llmArgs,
        String bindingCfg,
        Id actionDefId,
        Id relId,
        String turnId,
        Integer turnCount
    ) {
        if (
            sessId == null ||
            usrId == null ||
            agentDefId == null ||
            parentMsgId == null ||
            String.isBlank(toolCallId) ||
            actionDefId == null ||
            String.isBlank(turnId) ||
            turnCount == null
        ) {
            throw new IllegalArgumentException('Required arguments missing for ExecuteSingleActionQueueable.');
        }
        this.chatSessionId = sessId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.parentAssistantMessageId = parentMsgId;
        this.toolCallId = toolCallId;
        this.llmArgumentsJson = llmArgs;
        this.bindingConfigJson = bindingCfg;
        this.actionDefinitionId = actionDefId;
        this.relatedRecordId = relId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
    }

    public void execute(QueueableContext context) {
        String logPrefix = '[ExecAsyncAct:' + this.turnIdentifier?.left(8) + ' Turn:' + this.currentTurnCount + ' Job:' + context.getJobId() + '] ';

        ActionResult actionResult = null;
        Exception processingException = null;
        Long actionDuration = 0L;

        ActionExecutionService actionService = new ActionExecutionService();
        TurnLifecycleService turnLifecycleSvc = new TurnLifecycleService();
        MessagePersistenceService msgPersistenceSvc = new MessagePersistenceService();

        OrchestrationDispatchService orchestrationDispatchSvc = new OrchestrationDispatchService(turnLifecycleSvc);

        ChatSession__c session = null;
        try {
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c
                FROM ChatSession__c
                WHERE Id = :this.chatSessionId
                LIMIT 1
                FOR UPDATE
            ];
            if (sessions.isEmpty()) {
                return;
            }
            session = sessions[0];
            if (!String.escapeSingleQuotes(session.CurrentTurnIdentifier__c).equals(String.escapeSingleQuotes(this.turnIdentifier))) {
                return;
            }
            if (session.ProcessingStatus__c != AIAgentConstants.STATUS_AWAITING_ACTION) {
                return;
            }

            turnLifecycleSvc.startTurnProcessing(this.chatSessionId, this.turnIdentifier, context.getJobId(), logPrefix);

            Long actionStartTime = System.currentTimeMillis();
            try {
                ActionContext actionContext = new ActionContext(
                    this.chatSessionId,
                    this.userId,
                    this.relatedRecordId,
                    this.agentDefinitionId,
                    null /* Capability ID not directly passed/needed here */,
                    this.actionDefinitionId
                );
                actionResult = actionService.executeSingleAction(
                    this.actionDefinitionId,
                    this.bindingConfigJson,
                    this.llmArgumentsJson,
                    actionContext
                );
            } catch (Exception ex) {
                processingException = ex;
                actionResult = new ActionResult(
                    'Async Action execution failed: ' + ex.getMessage(),
                    ex.getStackTraceString(),
                    AIAgentConstants.ERR_CODE_ACTION_EXECUTION
                );
            } finally {
                actionDuration = System.currentTimeMillis() - actionStartTime;
            }
            if (actionResult == null) {
                actionResult = new ActionResult(
                    'Action handler failed to return a result.',
                    'Handler returned null.',
                    AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT
                );
            }

            String resultJsonForStorage = OrchestrationService.serializeActionResult(actionResult, logPrefix);
            Boolean isActionSuccess = actionResult.isSuccess;

            Id newRecordContextId = OrchestrationService.extractRecordIdFromResult(actionResult);
            String newRecordContextData = (newRecordContextId != null) ? resultJsonForStorage : null;

            Id savedToolMessageId = msgPersistenceSvc.saveToolResultMessage(
                this.chatSessionId,
                this.parentAssistantMessageId,
                this.toolCallId,
                resultJsonForStorage,
                actionResult.internalDetails,
                actionResult.errorCode,
                actionDuration,
                newRecordContextId,
                newRecordContextData,
                logPrefix
            );

            if (isActionSuccess) {
                Integer maxTurns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();

                if ((this.currentTurnCount + 1) > maxTurns) {
                    String limitError = 'Maximum processing cycles (' + maxTurns + ') reached after async action. Turn cannot continue.';

                    turnLifecycleSvc.failTurn(
                        this.chatSessionId,
                        this.turnIdentifier,
                        limitError,
                        AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED,
                        logPrefix
                    );
                } else {
                    turnLifecycleSvc.resumeForFollowUpLlmCall(
                        this.chatSessionId,
                        this.turnIdentifier,
                        null /* Next job ID set by dispatcher*/,
                        logPrefix
                    );
                    orchestrationDispatchSvc.enqueueFollowUp(
                        this.chatSessionId,
                        this.userId,
                        this.agentDefinitionId,
                        this.turnIdentifier,
                        this.currentTurnCount + 1,
                        logPrefix
                    );
                }
            } else {
                String failureMsg = ('Async Action Failed: ' +
                    (actionResult.internalDetails ?? processingException?.getMessage() ?? 'Unknown failure'))
                    .abbreviate(131072);

                turnLifecycleSvc.failTurn(
                    this.chatSessionId,
                    this.turnIdentifier,
                    failureMsg,
                    actionResult.errorCode ?? AIAgentConstants.ERR_CODE_ACTION_EXECUTION,
                    logPrefix
                );
            }
        } catch (Exception ex) {
            processingException = ex;

            try {
                ChatSession__c currentStateCheck = [SELECT ProcessingStatus__c FROM ChatSession__c WHERE Id = :this.chatSessionId LIMIT 1];
                if (currentStateCheck.ProcessingStatus__c != AIAgentConstants.STATUS_FAILED) {
                    String errorDetail = ('Queueable Internal Error: ' + ex.getMessage()).abbreviate(131072);
                    turnLifecycleSvc.failTurn(
                        this.chatSessionId,
                        this.turnIdentifier,
                        errorDetail,
                        AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                        logPrefix
                    );
                } else {
                }
            } catch (Exception finalFailEx) {
            }
        } finally {
            OrchestrationLogger.commitLogs();
        }
    }
}
