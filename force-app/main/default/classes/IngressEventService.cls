/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * @description Persistence helper for the normalized ingress staging boundary.
 */
public inherited sharing class IngressEventService {
    public static final String STATUS_RECEIVED = 'Received';
    public static final String STATUS_VERIFIED = 'Verified';
    public static final String STATUS_DUPLICATE = 'Duplicate';
    public static final String STATUS_READY = 'Ready';
    public static final String STATUS_PROCESSING = 'Processing';
    public static final String STATUS_PROCESSED = 'Processed';
    public static final String STATUS_FAILED = 'Failed';

    public IngressEvent__c createEvent(NormalizedIngressModels.Request request) {
        List<IngressEvent__c> created = createEvents(
            request == null ? new List<NormalizedIngressModels.Request>() : new List<NormalizedIngressModels.Request>{ request }
        );
        return created.isEmpty() ? null : created[0];
    }

    public List<IngressEvent__c> createEvents(List<NormalizedIngressModels.Request> requests) {
        List<IngressEvent__c> eventsToInsert = new List<IngressEvent__c>();
        if (requests == null) {
            return eventsToInsert;
        }

        for (NormalizedIngressModels.Request request : requests) {
            if (request == null) {
                continue;
            }
            IngressEvent__c eventRecord = new IngressEvent__c();
            eventRecord.IngressType__c = request.ingressType;
            eventRecord.Channel__c = request.channel;
            eventRecord.Provider__c = request.provider;
            eventRecord.EventType__c = request.eventType;
            eventRecord.ProcessingMode__c = request.processingMode;
            eventRecord.SubmissionOrigin__c = request.submissionOrigin;
            eventRecord.EndpointDeveloperName__c = request.endpointDeveloperName;
            eventRecord.EndpointIdentifier__c = request.endpointIdentifier;
            eventRecord.RouteKey__c = request.routeKey;
            eventRecord.ParticipantExternalKey__c = request.participantExternalKey;
            eventRecord.ConversationKey__c = request.conversationKey;
            eventRecord.ProviderMessageId__c = request.providerMessageId;
            eventRecord.OccurredAt__c = request.occurredAt;
            eventRecord.ReceivedAt__c = Datetime.now();
            eventRecord.ProcessingAttempts__c = 0;
            eventRecord.VerificationStatus__c = String.isNotBlank(request.verificationStatus) ? request.verificationStatus : 'NotRequired';
            eventRecord.ProcessingStatus__c = eventRecord.VerificationStatus__c == 'Verified' ? STATUS_VERIFIED : STATUS_RECEIVED;
            eventRecord.RawPayloadJson__c = request.rawPayloadJson;
            eventRecord.NormalizedPayloadJson__c = request.normalizedPayloadJson;
            eventRecord.ErrorCode__c = request.errorCode;
            eventRecord.ErrorMessage__c = request.errorMessage;
            eventRecord.MatchedRecordId__c = request.matchedRecordId;
            eventsToInsert.add(eventRecord);
        }

        if (!eventsToInsert.isEmpty()) {
            insert eventsToInsert;
        }
        return eventsToInsert;
    }

    public IngressEvent__c claim(Id ingressEventId) {
        if (ingressEventId == null) {
            return null;
        }

        List<IngressEvent__c> rows = [
            SELECT
                Id,
                IngressType__c,
                Channel__c,
                Provider__c,
                EventType__c,
                ProcessingStatus__c,
                VerificationStatus__c,
                ProcessingMode__c,
                SubmissionOrigin__c,
                EndpointDeveloperName__c,
                EndpointIdentifier__c,
                RouteKey__c,
                ParticipantExternalKey__c,
                ConversationKey__c,
                ProviderMessageId__c,
                InboundDedupKey__c,
                OccurredAt__c,
                ReceivedAt__c,
                ProcessingAttempts__c,
                LastProcessedAt__c,
                ErrorCode__c,
                ErrorMessage__c,
                RawPayloadJson__c,
                NormalizedPayloadJson__c,
                InteractionSession__c,
                InteractionMessage__c,
                AgentExecution__c,
                MatchedRecordId__c
            FROM IngressEvent__c
            WHERE Id = :ingressEventId
            LIMIT 1
            FOR UPDATE
        ];
        if (rows.isEmpty()) {
            return null;
        }

        IngressEvent__c row = rows[0];
        if (row.ProcessingStatus__c == STATUS_PROCESSED || row.ProcessingStatus__c == STATUS_DUPLICATE) {
            return row;
        }

        row.ProcessingStatus__c = STATUS_PROCESSING;
        row.ProcessingAttempts__c = row.ProcessingAttempts__c == null ? 1 : row.ProcessingAttempts__c + 1;
        row.LastProcessedAt__c = Datetime.now();
        update row;
        return row;
    }

    public void markDuplicate(Id ingressEventId, String dedupKey, Id interactionSessionId, Id interactionMessageId) {
        if (ingressEventId == null) {
            return;
        }
        update new IngressEvent__c(
            Id = ingressEventId,
            ProcessingStatus__c = STATUS_DUPLICATE,
            InboundDedupKey__c = dedupKey,
            InteractionSession__c = interactionSessionId,
            InteractionMessage__c = interactionMessageId,
            LastProcessedAt__c = Datetime.now()
        );
    }

    public void markProcessed(Id ingressEventId, NormalizedIngressModels.ProcessingResult result) {
        if (ingressEventId == null) {
            return;
        }
        update new IngressEvent__c(
            Id = ingressEventId,
            ProcessingStatus__c = STATUS_PROCESSED,
            InboundDedupKey__c = result != null ? result.inboundDedupKey : null,
            InteractionSession__c = result != null ? result.interactionSessionId : null,
            InteractionMessage__c = result != null ? result.interactionMessageId : null,
            AgentExecution__c = result != null ? result.executionId : null,
            ErrorCode__c = null,
            ErrorMessage__c = null,
            LastProcessedAt__c = Datetime.now()
        );
    }

    public void markFailed(Id ingressEventId, String dedupKey, String errorCode, String errorMessage) {
        if (ingressEventId == null) {
            return;
        }
        update new IngressEvent__c(
            Id = ingressEventId,
            ProcessingStatus__c = STATUS_FAILED,
            InboundDedupKey__c = dedupKey,
            ErrorCode__c = errorCode,
            ErrorMessage__c = abbreviate(errorMessage),
            LastProcessedAt__c = Datetime.now()
        );
    }

    private String abbreviate(String value) {
        if (String.isBlank(value) || value.length() <= 255) {
            return value;
        }
        return value.left(255);
    }
}
