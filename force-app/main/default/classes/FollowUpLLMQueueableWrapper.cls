/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queueable Job WRAPPER: Handles subsequent LLM interactions.
 *              This class simply instantiates and delegates to FollowUpLLMProcessor.
 */
public class FollowUpLLMQueueableWrapper implements Queueable, Database.AllowsCallouts {
    private final Id chatSessionId;
    private final Id userId;
    private final Id agentDefinitionId;
    private final String turnIdentifier;
    private final Integer currentTurnCount;
    private final Boolean isFinalErrorTurn;

    public FollowUpLLMQueueableWrapper(Id sessId, Id usrId, Id agentDefId, String turnId, Integer turnCount, Boolean isFinalError) {
        this.chatSessionId = sessId;
        this.userId = usrId;
        this.agentDefinitionId = agentDefId;
        this.turnIdentifier = turnId;
        this.currentTurnCount = turnCount;
        this.isFinalErrorTurn = isFinalError;
    }

    public void execute(QueueableContext context) {
        FollowUpLLMProcessor processor = new FollowUpLLMProcessor(
            this.chatSessionId,
            this.userId,
            this.agentDefinitionId,
            this.turnIdentifier,
            this.currentTurnCount,
            this.isFinalErrorTurn
        );

        processor.process(context.getJobId());
    }
}
