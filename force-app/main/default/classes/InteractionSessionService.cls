/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Manages the durable InteractionSession__c anchor used by
 * channel adapters to correlate transport conversations independently of
 * execution records.
 */
public inherited sharing class InteractionSessionService {
    public static String buildHash(String rawValue) {
        if (String.isBlank(rawValue)) {
            return null;
        }
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(rawValue)));
    }

    public InteractionRuntimeModels.InteractionSessionContext resolveOrCreateSession(
        String channel,
        String conversationKey,
        String replyRouteKey,
        String participantKey,
        String provider,
        Id sourceRecordId,
        String endpointIdentifier,
        String logPrefix
    ) {
        if (String.isBlank(conversationKey)) {
            InteractionRuntimeModels.InteractionSessionContext statelessContext = new InteractionRuntimeModels.InteractionSessionContext();
            statelessContext.channel = channel;
            statelessContext.provider = provider;
            statelessContext.replyRouteKey = replyRouteKey;
            statelessContext.sourceRecordId = sourceRecordId;
            return statelessContext;
        }

        String keyHash = buildHash(channel + '|' + conversationKey);
        List<InteractionSession__c> sessions = String.isNotBlank(keyHash)
            ? [
                  SELECT
                      Id,
                      Channel__c,
                      ConversationKey__c,
                      ReplyRouteKey__c,
                      ParticipantExternalKey__c,
                      ParentRecordId__c,
                      LastInboundAt__c,
                      SessionStatus__c,
                      LastExecution__c
                  FROM InteractionSession__c
                  WHERE ConversationKeyHash__c = :keyHash
                  LIMIT 1
                  FOR UPDATE
              ]
            : new List<InteractionSession__c>();

        InteractionSession__c session;
        if (sessions.isEmpty()) {
            session = new InteractionSession__c(
                Channel__c = channel,
                ConversationKey__c = conversationKey,
                ConversationKeyHash__c = keyHash,
                ReplyRouteKey__c = replyRouteKey,
                RouteEndpoint__c = endpointIdentifier,
                ParticipantExternalKey__c = participantKey,
                ParticipantHash__c = buildHash(participantKey),
                ParentRecordId__c = sourceRecordId != null ? String.valueOf(sourceRecordId) : null,
                SessionStatus__c = 'Active',
                LastInboundAt__c = Datetime.now()
            );
            insert session;
        } else {
            session = sessions[0];
            session.ReplyRouteKey__c = String.isNotBlank(replyRouteKey) ? replyRouteKey : session.ReplyRouteKey__c;
            session.RouteEndpoint__c = String.isNotBlank(endpointIdentifier) ? endpointIdentifier : session.RouteEndpoint__c;
            session.ParticipantExternalKey__c = String.isNotBlank(participantKey) ? participantKey : session.ParticipantExternalKey__c;
            session.ParticipantHash__c = String.isNotBlank(participantKey) ? buildHash(participantKey) : session.ParticipantHash__c;
            session.ParentRecordId__c = sourceRecordId != null ? String.valueOf(sourceRecordId) : session.ParentRecordId__c;
            session.SessionStatus__c = 'Active';
            session.LastInboundAt__c = Datetime.now();
            update session;
        }

        InteractionRuntimeModels.InteractionSessionContext context = toContext(session, provider);
        context.sourceRecordId = sourceRecordId;
        return context;
    }

    public InteractionRuntimeModels.InteractionSessionContext getSessionContext(Id sessionId) {
        if (sessionId == null) {
            return null;
        }

        List<InteractionSession__c> sessions = [
            SELECT
                Id,
                Channel__c,
                ConversationKey__c,
                ReplyRouteKey__c,
                ParticipantExternalKey__c,
                ParentRecordId__c,
                LastInboundAt__c,
                SessionStatus__c,
                LastExecution__c
            FROM InteractionSession__c
            WHERE Id = :sessionId
            LIMIT 1
        ];
        if (sessions.isEmpty()) {
            return null;
        }

        return toContext(sessions[0], null);
    }

    public InteractionRuntimeModels.InteractionSessionContext getSessionContextForExecution(Id executionId) {
        if (executionId == null) {
            return null;
        }

        List<AgentExecution__c> executions = [
            SELECT InteractionSession__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];
        if (executions.isEmpty() || executions[0].InteractionSession__c == null) {
            return null;
        }

        return getSessionContext(executions[0].InteractionSession__c);
    }

    public void stampExecution(Id sessionId, Id executionId) {
        if (sessionId == null || executionId == null) {
            return;
        }
        update new InteractionSession__c(Id = sessionId, LastExecution__c = executionId, SessionStatus__c = 'Active');
    }

    public void markOutbound(Id sessionId) {
        if (sessionId == null) {
            return;
        }
        update new InteractionSession__c(Id = sessionId, LastOutboundAt__c = Datetime.now());
    }

    private InteractionRuntimeModels.InteractionSessionContext toContext(InteractionSession__c session, String provider) {
        InteractionRuntimeModels.InteractionSessionContext context = new InteractionRuntimeModels.InteractionSessionContext();
        context.sessionId = session.Id;
        context.channel = session.Channel__c;
        context.provider = provider;
        context.conversationKey = session.ConversationKey__c;
        context.replyRouteKey = session.ReplyRouteKey__c;
        context.participantKey = session.ParticipantExternalKey__c;
        context.sourceRecordId = String.isNotBlank(session.ParentRecordId__c) ? Id.valueOf(session.ParentRecordId__c) : null;
        context.lastExecutionId = session.LastExecution__c;
        context.lastInboundAt = session.LastInboundAt__c;
        context.sessionStatus = session.SessionStatus__c;
        return context;
    }
}
