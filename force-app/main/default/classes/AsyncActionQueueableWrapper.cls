/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queueable Job WRAPPER: Executes a single agent action asynchronously.
 *              This class simply instantiates and delegates to AsyncActionProcessor.
 */
public class AsyncActionQueueableWrapper implements Queueable {
    private final Id chatSessionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final Id parentAssistantMessageId;
    private final String toolCallId;
    private final String llmArgumentsJson;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Id relatedRecordId;
    private final AgentCapability__c capability;

    public AsyncActionQueueableWrapper(
        Id sessId,
        Id usrId,
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
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.parentAssistantMessageId = parentMsgId;
        this.toolCallId = toolCallId;
        this.llmArgumentsJson = llmArgs;
        this.capability = cap;
        this.relatedRecordId = relId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
    }

    public void execute(QueueableContext context) {
        AsyncActionProcessor processor = new AsyncActionProcessor(
            this.chatSessionId,
            this.userId,
            this.agentDefinitionId,
            this.parentAssistantMessageId,
            this.toolCallId,
            this.llmArgumentsJson,
            this.capability,
            this.relatedRecordId,
            this.turnIdentifier,
            this.currentTurnCount
        );

        processor.process(context.getJobId());
    }
}
