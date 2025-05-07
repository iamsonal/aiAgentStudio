/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Service responsible for all DML operations related to ChatMessage__c records.
 *              It ensures consistent saving logic and uses ChatMessageService for actual DML.
 */
public inherited sharing class MessagePersistenceService {
    public class PersistenceException extends AIAgentException {
    }

    private ChatMessageService chatMessageSvc;

    public MessagePersistenceService() {
        this.chatMessageSvc = new ChatMessageService();
    }

    @TestVisible
    private MessagePersistenceService(ChatMessageService mockChatMessageService) {
        this.chatMessageSvc = mockChatMessageService;
    }

    /**
     * @description Saves a user message if provided.
     *              The externalId for the first user message in a turn is the turnIdentifier.
     * @return ID of the saved ChatMessage__c or null if no data provided.
     */
    public Id saveUserMessage(Id sessionId, String turnIdentifier, LLMInteractionService.MessageData userMessageData, String logPrefix) {
        if (userMessageData != null) {
            return saveMessageInternal(userMessageData, null, sessionId, logPrefix, turnIdentifier, true);
        }
        return null;
    }

    /**
     * @description Saves an assistant message.
     * @return ID of the saved ChatMessage__c.
     */
    public Id saveAssistantMessage(Id sessionId, Id parentUserMessageId, LLMInteractionService.MessageData assistantMessageData, String logPrefix) {
        return saveMessageInternal(assistantMessageData, parentUserMessageId, sessionId, logPrefix, UuidUtils.generateUUID(), false);
    }

    /**
     * @description Saves an assistant message, storing pending tool call details for confirmation.
     * @param pendingToolCallsListJson The raw JSON LIST string of the tool_calls that are pending confirmation.
     * @return ID of the saved ChatMessage__c.
     */
    public Id saveAssistantMessageWithPendingAction(
        Id sessionId,
        Id parentUserMessageId,
        LLMInteractionService.MessageData assistantMessageData,
        String pendingToolCallsListJson,
        String logPrefix
    ) {
        ChatMessage__c msg = createMessageSObject(assistantMessageData, parentUserMessageId, sessionId, logPrefix, UuidUtils.generateUUID(), false);

        msg.PendingConfirmationActionDetails__c = pendingToolCallsListJson;

        return insertMessage(msg, logPrefix);
    }

    /**
     * @description Saves a tool result message.
     * @return ID of the saved ChatMessage__c.
     */
    public Id saveToolResultMessage(
        Id sessionId,
        Id parentAssistantMessageId,
        String toolCallId,
        String toolResultContentJson,
        String internalDetails,
        String errorCode,
        Long actionDuration,
        String logPrefix
    ) {
        if (String.isBlank(toolCallId) || parentAssistantMessageId == null) {
            throw new PersistenceException('ToolCallId and Parent Assistant Message ID are required to save tool result.');
        }

        LLMInteractionService.MessageData toolData = new LLMInteractionService.MessageData();
        toolData.role = AIAgentConstants.ROLE_TOOL;
        toolData.content = toolResultContentJson;
        toolData.processingTimeMs = actionDuration;

        ChatMessage__c msg = createMessageSObject(toolData, parentAssistantMessageId, sessionId, logPrefix, UuidUtils.generateUUID(), false);
        msg.ToolCallId__c = toolCallId;

        return insertMessage(msg, logPrefix);
    }

    private ChatMessage__c createMessageSObject(
        LLMInteractionService.MessageData msgData,
        Id parentMsgId,
        Id sessionId,
        String logPrefix,
        String externalIdToUse,
        Boolean isUserMessageForTurn
    ) {
        if (msgData == null) {
            throw new PersistenceException('MessageData cannot be null for SObject creation.');
        }
        if (sessionId == null) {
            throw new PersistenceException('SessionID is required to create ChatMessage SObject.');
        }

        String finalExternalId = (isUserMessageForTurn && msgData.role == AIAgentConstants.ROLE_USER) ? externalIdToUse : UuidUtils.generateUUID();

        return new ChatMessage__c(
            ChatSession__c = sessionId,
            Role__c = msgData.role,
            Content__c = msgData.content,
            AssistantToolCalls__c = msgData.assistantToolCallsJson,
            Timestamp__c = Datetime.now(),
            ExternalId__c = finalExternalId,
            TokensUsed__c = msgData.tokensUsed,
            ProcessingTimeMillis__c = msgData.processingTimeMs,
            ParentMessage__c = parentMsgId
        );
    }

    private Id saveMessageInternal(
        LLMInteractionService.MessageData msgData,
        Id parentMsgId,
        Id sessionId,
        String logPrefix,
        String externalIdToUse,
        Boolean isUserMessageForTurn
    ) {
        ChatMessage__c msgSobj = createMessageSObject(msgData, parentMsgId, sessionId, logPrefix, externalIdToUse, isUserMessageForTurn);

        return insertMessage(msgSobj, logPrefix);
    }

    private Id insertMessage(ChatMessage__c msgToInsert, String logPrefix) {
        try {
            List<Database.SaveResult> results = ChatMessageService.saveMessages(new List<ChatMessage__c>{ msgToInsert });
            if (results != null && !results.isEmpty() && results[0].isSuccess()) {
                Id savedId = results[0].getId();

                return savedId;
            } else {
                String errorDetail = 'Unknown DML Error saving message.';
                if (results != null && !results.isEmpty() && results[0].getErrors().size() > 0) {
                    errorDetail = results[0].getErrors()[0].getMessage();
                }
                throw new DmlException('Failed to save ChatMessage (' + msgToInsert.Role__c + '). Error: ' + errorDetail);
            }
        } catch (Exception e) {
            throw new PersistenceException('Error saving ChatMessage (' + msgToInsert.Role__c + '): ' + e.getMessage(), e);
        }
    }
}
