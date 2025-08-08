/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Core logic handler for executing a single agent action asynchronously.
 *              This class is agnostic of its invocation context (Queueable, Platform Event, etc.).
 */
public class AsyncActionProcessor {
    private final Id chatSessionId;
    private final Id originalUserId;
    private final Id agentDefinitionId;
    private final Id parentAssistantMessageId;
    private final String toolCallId;
    private final String llmArgumentsJson;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Id relatedRecordId;
    private final AgentCapability__c capability;

    public AsyncActionProcessor(
        Id sessId,
        Id origUserId,
        Id agentDefId,
        Id parentMsgId,
        String toolCallId,
        String llmArgs,
        AgentCapability__c cap,
        Id relId,
        String turnId,
        Integer turnCount
    ) {
        this.chatSessionId = sessId;
        this.originalUserId = origUserId;
        this.agentDefinitionId = agentDefId;
        this.parentAssistantMessageId = parentMsgId;
        this.toolCallId = toolCallId;
        this.llmArgumentsJson = llmArgs;
        this.capability = cap;
        this.relatedRecordId = relId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
    }

    /**
     * @description Main processing method containing the logic from the old Queueable's execute method.
     * @param jobIdForLogging The Apex Job ID or other identifier for logging purposes. Can be null.
     */
    public void process(String jobIdForLogging) {
        Id executionUserId = UserInfo.getUserId();

        String logPrefix =
            '[AsyncActionProcessor:' +
            this.turnIdentifier?.left(8) +
            ' Turn:' +
            this.currentTurnCount +
            ' InvokedBy:' +
            jobIdForLogging +
            '] ';

        TurnLifecycleService turnLifecycleSvc = new TurnLifecycleService();
        ActionExecutionService actionService = new ActionExecutionService();
        AgentJobEnqueuer orchestrationDispatchSvc = new AgentJobEnqueuer(turnLifecycleSvc);

        try {
            List<ChatSession__c> sessions = [
                SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c
                FROM ChatSession__c
                WHERE Id = :this.chatSessionId
                LIMIT 1
                FOR UPDATE
            ];
            if (
                sessions.isEmpty() ||
                !this.turnIdentifier.equals(sessions[0].CurrentTurnIdentifier__c) ||
                sessions[0].ProcessingStatus__c != AIAgentConstants.STATUS_AWAITING_ACTION
            ) {
                return;
            }

            turnLifecycleSvc.startTurnProcessing(this.chatSessionId, this.turnIdentifier, jobIdForLogging, logPrefix);

            Long actionDuration = 0L;
            ActionResult actionResult;
            Long actionStartTime = System.currentTimeMillis();
            try {
                ActionContext actionContext = new ActionContext(
                    this.chatSessionId,
                    this.originalUserId,
                    executionUserId,
                    this.relatedRecordId,
                    this.agentDefinitionId,
                    this.capability.Id,
                    this.capability.ImplementationDetail__c,
                    this.turnIdentifier,
                    this.currentTurnCount
                );
                actionResult = actionService.executeSingleAction(this.capability, this.llmArgumentsJson, actionContext);
            } catch (Exception ex) {
                actionResult = new ActionResult(
                    'Async Action failed internally: ' + ex.getMessage(),
                    ex.getStackTraceString(),
                    AIAgentConstants.ERR_CODE_ACTION_EXECUTION
                );
            } finally {
                actionDuration = System.currentTimeMillis() - actionStartTime;
            }

            String resultJsonForStorage = OrchestrationService.serializeActionResult(actionResult, logPrefix);
            Id newRecordContextId = OrchestrationService.extractRecordIdFromResult(actionResult);

            ChatMessageService.saveToolResultMessage(
                this.chatSessionId,
                this.turnIdentifier,
                this.parentAssistantMessageId,
                this.toolCallId,
                resultJsonForStorage,
                actionResult.internalDetails,
                actionResult.errorCode,
                actionDuration,
                newRecordContextId,
                resultJsonForStorage,
                this.capability.CapabilityName__c,
                logPrefix
            );

            Integer maxTurns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();
            if ((this.currentTurnCount + 1) > maxTurns) {
                turnLifecycleSvc.failTurn(
                    this.chatSessionId,
                    this.turnIdentifier,
                    'Maximum processing cycles reached.',
                    AIAgentConstants.ERR_CODE_MAX_TURNS_EXCEEDED,
                    logPrefix
                );
            } else {
                turnLifecycleSvc.resumeForFollowUpLlmCall(this.chatSessionId, this.turnIdentifier, null, logPrefix);
                orchestrationDispatchSvc.enqueueFollowUp(
                    this.chatSessionId,
                    this.originalUserId,
                    this.agentDefinitionId,
                    this.turnIdentifier,
                    this.currentTurnCount + 1,
                    logPrefix,
                    false
                );
            }
        } catch (Exception ex) {
            try {
                turnLifecycleSvc.failTurn(
                    this.chatSessionId,
                    this.turnIdentifier,
                    'Processor Internal Error: ' + ex.getMessage(),
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
            } catch (Exception finalFailEx) {
                /* Log and swallow */
            }
        } finally {
            OrchestrationLogger.commitLogs();
        }
    }
}
