/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * @description Converts normalized ingress requests into the existing
 * interaction/session/message/execution runtime flow.
 */
public inherited sharing class IngressProcessingService {
    @TestVisible
    private static Map<String, IChannelParticipantResolver> testParticipantResolversByClassName = new Map<String, IChannelParticipantResolver>();

    public List<NormalizedIngressModels.ProcessingResult> processStagedEvents(List<Id> ingressEventIds, String logPrefix) {
        List<NormalizedIngressModels.ProcessingResult> results = new List<NormalizedIngressModels.ProcessingResult>();
        if (ingressEventIds == null) {
            return results;
        }

        for (Id ingressEventId : ingressEventIds) {
            results.add(processStagedEvent(ingressEventId, logPrefix));
        }
        return results;
    }

    public List<NormalizedIngressModels.AcceptResult> accept(List<NormalizedIngressModels.Request> requests, String logPrefix) {
        List<NormalizedIngressModels.AcceptResult> results = new List<NormalizedIngressModels.AcceptResult>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }

        IngressEventService eventService = new IngressEventService();
        List<Id> stagedEventIds = new List<Id>();

        for (NormalizedIngressModels.Request request : requests) {
            if (request == null) {
                continue;
            }

            request.processingMode = determineProcessingMode(request);
            NormalizedIngressModels.AcceptResult result = new NormalizedIngressModels.AcceptResult();
            result.accepted = true;
            result.processingMode = request.processingMode;

            if (NormalizedIngressModels.MODE_STAGED == request.processingMode) {
                IngressEvent__c stagedEvent = eventService.createEvent(request);
                stagedEventIds.add(stagedEvent.Id);
                result.ingressEventId = stagedEvent.Id;
                result.processingStatus = stagedEvent.ProcessingStatus__c;
                results.add(result);
                continue;
            }

            NormalizedIngressModels.ProcessingResult processingResult = processRequest(request, logPrefix);
            result.processingStatus = processingResult.processingStatus;
            result.interactionSessionId = processingResult.interactionSessionId;
            result.interactionMessageId = processingResult.interactionMessageId;
            result.executionId = processingResult.executionId;
            result.errorCode = processingResult.errorCode;
            result.errorMessage = processingResult.errorMessage;
            result.accepted = processingResult != null && (processingResult.success == true || processingResult.duplicateSuppressed == true);
            results.add(result);
        }

        if (!stagedEventIds.isEmpty()) {
            publishIngressRequestedEvents(stagedEventIds, logPrefix);
        }
        return results;
    }

    public NormalizedIngressModels.AcceptResult accept(NormalizedIngressModels.Request request, String logPrefix) {
        List<NormalizedIngressModels.AcceptResult> results = accept(
            request == null ? new List<NormalizedIngressModels.Request>() : new List<NormalizedIngressModels.Request>{ request },
            logPrefix
        );
        return results.isEmpty() ? null : results[0];
    }

    public NormalizedIngressModels.ProcessingResult processStagedEvent(Id ingressEventId, String logPrefix) {
        IngressEventService eventService = new IngressEventService();
        IngressEvent__c ingressEvent = eventService.claim(ingressEventId);
        if (ingressEvent == null) {
            return failureResult('NOT_FOUND', 'Ingress event not found.');
        }
        if (ingressEvent.ProcessingStatus__c == IngressEventService.STATUS_PROCESSED) {
            NormalizedIngressModels.ProcessingResult alreadyProcessed = new NormalizedIngressModels.ProcessingResult();
            alreadyProcessed.success = true;
            alreadyProcessed.processingStatus = IngressEventService.STATUS_PROCESSED;
            alreadyProcessed.interactionSessionId = ingressEvent.InteractionSession__c;
            alreadyProcessed.interactionMessageId = ingressEvent.InteractionMessage__c;
            alreadyProcessed.executionId = ingressEvent.AgentExecution__c;
            alreadyProcessed.inboundDedupKey = ingressEvent.InboundDedupKey__c;
            return alreadyProcessed;
        }
        if (ingressEvent.ProcessingStatus__c == IngressEventService.STATUS_DUPLICATE) {
            NormalizedIngressModels.ProcessingResult duplicate = new NormalizedIngressModels.ProcessingResult();
            duplicate.success = true;
            duplicate.duplicateSuppressed = true;
            duplicate.processingStatus = IngressEventService.STATUS_DUPLICATE;
            duplicate.interactionSessionId = ingressEvent.InteractionSession__c;
            duplicate.interactionMessageId = ingressEvent.InteractionMessage__c;
            duplicate.inboundDedupKey = ingressEvent.InboundDedupKey__c;
            return duplicate;
        }

        NormalizedIngressModels.Request request = toRequest(ingressEvent);
        try {
            NormalizedIngressModels.ProcessingResult result = processRequestInternal(request, logPrefix);
            if (result.duplicateSuppressed == true) {
                eventService.markDuplicate(ingressEvent.Id, result.inboundDedupKey, result.interactionSessionId, result.interactionMessageId);
            } else if (result.success == true) {
                eventService.markProcessed(ingressEvent.Id, result);
            } else {
                eventService.markFailed(ingressEvent.Id, result.inboundDedupKey, result.errorCode, result.errorMessage);
            }
            return result;
        } catch (Exception e) {
            eventService.markFailed(ingressEvent.Id, ingressEvent.InboundDedupKey__c, 'UNEXPECTED_ERROR', e.getMessage());
            throw e;
        }
    }

    public NormalizedIngressModels.ProcessingResult processRequest(NormalizedIngressModels.Request request, String logPrefix) {
        return processRequestInternal(request, logPrefix);
    }

    private String determineProcessingMode(NormalizedIngressModels.Request request) {
        if (request != null && NormalizedIngressModels.EVENT_TYPE_DELIVERY_STATUS == request.eventType) {
            return NormalizedIngressModels.MODE_DIRECT;
        }
        if (String.isNotBlank(request.processingMode)) {
            return request.processingMode;
        }
        if (NormalizedIngressModels.ORIGIN_DIRECT_EXTERNAL == request.submissionOrigin) {
            return NormalizedIngressModels.MODE_STAGED;
        }
        if ('Webhook'.equalsIgnoreCase(request.ingressType)) {
            return NormalizedIngressModels.MODE_STAGED;
        }
        return NormalizedIngressModels.MODE_DIRECT;
    }

    private void publishIngressRequestedEvents(List<Id> ingressEventIds, String logPrefix) {
        List<IngressRequested__e> events = new List<IngressRequested__e>();
        for (Id ingressEventId : ingressEventIds) {
            if (ingressEventId != null) {
                events.add(new IngressRequested__e(IngressEventId__c = String.valueOf(ingressEventId)));
            }
        }
        if (events.isEmpty()) {
            return;
        }

        List<Database.SaveResult> saveResults = EventBus.publish(events);
        for (Integer i = 0; i < saveResults.size(); i++) {
            if (saveResults[i].isSuccess()) {
                continue;
            }
            String errorJson = JSON.serialize(saveResults[i].getErrors());
            System.debug(LoggingLevel.ERROR, logPrefix + '[IngressProcessingService] Failed to publish IngressRequested__e: ' + errorJson);
            throw new AIAgentException.OrchestrationException('Failed to publish staged ingress processing event: ' + errorJson);
        }
    }

    private NormalizedIngressModels.ProcessingResult processRequestInternal(NormalizedIngressModels.Request request, String logPrefix) {
        if (request == null) {
            return failureResult(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Normalized ingress request is required.');
        }
        if (String.isBlank(request.channel)) {
            return failureResult(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Normalized ingress channel is required.');
        }
        if (String.isBlank(request.eventType)) {
            return failureResult(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Normalized ingress event type is required.');
        }

        if (NormalizedIngressModels.EVENT_TYPE_DELIVERY_STATUS == request.eventType) {
            return processDeliveryStatus(request);
        }
        if (NormalizedIngressModels.EVENT_TYPE_VERIFICATION == request.eventType) {
            NormalizedIngressModels.ProcessingResult verification = new NormalizedIngressModels.ProcessingResult();
            verification.success = true;
            verification.processingStatus = IngressEventService.STATUS_PROCESSED;
            return verification;
        }
        return processInboundMessage(request, logPrefix);
    }

    private NormalizedIngressModels.ProcessingResult processDeliveryStatus(NormalizedIngressModels.Request request) {
        Map<String, Object> normalizedPayload = parseJsonMap(request.normalizedPayloadJson);
        new InteractionMessageService()
            .updateProviderMessageStatus(
                request.providerMessageId,
                stringValue(normalizedPayload.get('providerStatus')),
                stringValue(normalizedPayload.get('normalizedStatus')),
                firstNonBlank(request.errorCode, stringValue(normalizedPayload.get('errorCode'))),
                firstNonBlank(request.errorMessage, stringValue(normalizedPayload.get('errorMessage')))
            );
        NormalizedIngressModels.ProcessingResult result = new NormalizedIngressModels.ProcessingResult();
        result.success = true;
        result.processingStatus = IngressEventService.STATUS_PROCESSED;
        return result;
    }

    private NormalizedIngressModels.ProcessingResult processInboundMessage(NormalizedIngressModels.Request request, String logPrefix) {
        InteractionRuntimeModels.IInteractionChannel channelAdapter = InteractionChannelRegistryService.resolveAdapter(null, null, request.channel);
        Map<String, Object> triggerMetadata = buildTriggerMetadata(request);
        Id sourceRecordId = resolveSourceRecordId(request);
        InboundInteractionPipelineService pipelineService = new InboundInteractionPipelineService();
        InboundInteractionPipelineService.ResolvedInbound resolvedInbound = pipelineService.prepare(
            channelAdapter,
            sourceRecordId,
            request.messageContent,
            triggerMetadata,
            logPrefix
        );

        NormalizedIngressModels.ProcessingResult result = new NormalizedIngressModels.ProcessingResult();
        result.inboundDedupKey = resolvedInbound.inboundDedupKey;

        InteractionMessageService messageService = new InteractionMessageService();
        InteractionMessageService.InboundMessageRef existingInbound = messageService.getInboundMessageRefByDedupKey(resolvedInbound.inboundDedupKey);
        if (existingInbound != null) {
            result.success = true;
            result.duplicateSuppressed = true;
            result.processingStatus = IngressEventService.STATUS_DUPLICATE;
            result.interactionMessageId = existingInbound.messageId;
            result.interactionSessionId = existingInbound.sessionId;
            result.executionId = existingInbound.executionId;
            return result;
        }

        pipelineService.resolveSession(null, channelAdapter, resolvedInbound, logPrefix);
        result.interactionSessionId = resolvedInbound.sessionContext != null ? resolvedInbound.sessionContext.sessionId : null;
        triggerMetadata.put('inboundDedupKey', resolvedInbound.inboundDedupKey);
        if (result.interactionSessionId != null) {
            triggerMetadata.put('interactionSessionId', result.interactionSessionId);
        }
        addFrameworkRelatedRecordIds(triggerMetadata, resolvedInbound.frameworkRelatedRecordIds);

        if (resolvedInbound.route == null) {
            Id interactionMessageId = messageService.recordInboundProcessing(
                result.interactionSessionId,
                null,
                request.channel,
                request.provider,
                request.providerMessageId,
                resolvedInbound.inboundDedupKey,
                buildTurnIdentifier(request.providerMessageId),
                JSON.serialize(triggerMetadata)
            );
            messageService.updateInboundStatus(
                resolvedInbound.inboundDedupKey,
                'Failed',
                null,
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'No active inbound route matched this endpoint.'
            );
            result.success = false;
            result.processingStatus = IngressEventService.STATUS_FAILED;
            result.interactionMessageId = interactionMessageId;
            result.errorCode = AIAgentConstants.ERR_CODE_CONFIG_ERROR;
            result.errorMessage = 'No active inbound route matched this endpoint.';
            return result;
        }

        AIAgentDefinition__c agentDefinition = AIAgentConfigService.getAgentDefinitionByDeveloperName(resolvedInbound.route.agentDeveloperName);
        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.userId = UserInfo.getUserId();
        payload.serviceUserId = null;
        payload.triggerSource = String.isNotBlank(request.triggerSource) ? request.triggerSource : 'API';
        payload.userMessage = request.messageContent;
        payload.sourceRecordId = resolvedInbound.sessionContext != null ? resolvedInbound.sessionContext.sourceRecordId : sourceRecordId;
        payload.turnIdentifier = buildTurnIdentifier(request.providerMessageId);
        payload.existingExecutionId = new InteractionSessionPolicyService()
            .resolveReusableExecutionId(resolvedInbound.sessionContext, payload.sourceRecordId, resolvedInbound.route, logPrefix);
        payload.interactionChannel = request.channel;
        payload.conversationKey = resolvedInbound.envelope != null ? resolvedInbound.envelope.conversationKey : request.conversationKey;
        payload.interactionSessionId = result.interactionSessionId;
        payload.triggerPayload = JSON.serialize(triggerMetadata);

        String deliveryMode = new ChannelRoutingService().resolveCompletionMode(agentDefinition, resolvedInbound.route);
        AgentExecutionService.ExecutionResult executionResult = AgentExecutionService.startExecution(agentDefinition.DeveloperName__c, payload);
        if (executionResult.success != true || executionResult.executionId == null) {
            throw new AIAgentException.OrchestrationException('Failed to start inbound execution: ' + executionResult.errorMessage);
        }

        update new AgentExecution__c(Id = executionResult.executionId, CompletionMode__c = deliveryMode);
        result.executionId = executionResult.executionId;

        try {
            result.interactionMessageId = messageService.recordInboundProcessing(
                result.interactionSessionId,
                result.executionId,
                request.channel,
                request.provider,
                request.providerMessageId,
                resolvedInbound.inboundDedupKey,
                payload.turnIdentifier,
                JSON.serialize(triggerMetadata)
            );
        } catch (DmlException e) {
            if (e.getDmlType(0) == StatusCode.DUPLICATE_VALUE) {
                InteractionMessageService.InboundMessageRef duplicateAfterInsert = messageService.getInboundMessageRefByDedupKey(
                    resolvedInbound.inboundDedupKey
                );
                result.success = true;
                result.duplicateSuppressed = true;
                result.processingStatus = IngressEventService.STATUS_DUPLICATE;
                result.interactionMessageId = duplicateAfterInsert != null ? duplicateAfterInsert.messageId : null;
                result.interactionSessionId = duplicateAfterInsert != null ? duplicateAfterInsert.sessionId : result.interactionSessionId;
                result.executionId = duplicateAfterInsert != null ? duplicateAfterInsert.executionId : result.executionId;
                return result;
            }
            throw e;
        }

        result.success = true;
        result.processingStatus = IngressEventService.STATUS_PROCESSED;
        return result;
    }

    private NormalizedIngressModels.Request toRequest(IngressEvent__c ingressEvent) {
        NormalizedIngressModels.Request request = new NormalizedIngressModels.Request();
        request.ingressType = ingressEvent.IngressType__c;
        request.channel = ingressEvent.Channel__c;
        request.provider = ingressEvent.Provider__c;
        request.eventType = ingressEvent.EventType__c;
        request.processingMode = ingressEvent.ProcessingMode__c;
        request.submissionOrigin = ingressEvent.SubmissionOrigin__c;
        request.endpointDeveloperName = ingressEvent.EndpointDeveloperName__c;
        request.endpointIdentifier = ingressEvent.EndpointIdentifier__c;
        request.routeKey = ingressEvent.RouteKey__c;
        request.participantExternalKey = ingressEvent.ParticipantExternalKey__c;
        request.conversationKey = ingressEvent.ConversationKey__c;
        request.providerMessageId = ingressEvent.ProviderMessageId__c;
        request.occurredAt = ingressEvent.OccurredAt__c;
        request.verificationStatus = ingressEvent.VerificationStatus__c;
        request.errorCode = ingressEvent.ErrorCode__c;
        request.errorMessage = ingressEvent.ErrorMessage__c;
        request.rawPayloadJson = ingressEvent.RawPayloadJson__c;
        request.normalizedPayloadJson = ingressEvent.NormalizedPayloadJson__c;
        request.matchedRecordId = ingressEvent.MatchedRecordId__c;

        Map<String, Object> normalizedPayload = parseJsonMap(ingressEvent.NormalizedPayloadJson__c);
        request.messageContent = stringValue(normalizedPayload.get('messageContent'));
        request.triggerSource = firstNonBlank(stringValue(normalizedPayload.get('triggerSource')), 'API');
        return request;
    }

    private Map<String, Object> buildTriggerMetadata(NormalizedIngressModels.Request request) {
        Map<String, Object> metadata = parseJsonMap(request.normalizedPayloadJson);
        metadata.put('provider', request.provider);
        metadata.put('endpointIdentifier', request.endpointIdentifier);
        metadata.put('routeKey', request.routeKey);
        metadata.put('participantExternalKey', request.participantExternalKey);
        metadata.put('providerMessageId', request.providerMessageId);
        metadata.put('endpointDeveloperName', request.endpointDeveloperName);
        metadata.put('displayPhoneNumber', request.endpointIdentifier);
        metadata.put('phoneNumberId', request.routeKey);
        metadata.put('conversationKey', request.conversationKey);
        metadata.put('fromPhoneNumber', request.participantExternalKey);
        metadata.put('messageId', request.providerMessageId);
        metadata.put('providerEventType', stringValue(metadata.get('providerEventType')));
        metadata.put('timestamp', stringValue(metadata.get('timestamp')));
        return metadata;
    }

    private void addFrameworkRelatedRecordIds(Map<String, Object> metadata, Set<Id> relatedRecordIds) {
        if (metadata == null || relatedRecordIds == null || relatedRecordIds.isEmpty()) {
            return;
        }

        List<String> serializedIds = new List<String>();
        for (Id relatedRecordId : relatedRecordIds) {
            if (relatedRecordId != null) {
                serializedIds.add(String.valueOf(relatedRecordId));
            }
        }
        if (!serializedIds.isEmpty()) {
            metadata.put('relatedRecordIds', serializedIds);
        }
    }

    private Id resolveSourceRecordId(NormalizedIngressModels.Request request) {
        Id explicitRecordId = tryParseId(request.matchedRecordId);
        return resolveSourceRecordId(request.channel, request.participantExternalKey, explicitRecordId);
    }

    @TestVisible
    static Id resolveSourceRecordId(String channel, String participantKey, Id explicitSourceRecordId) {
        if (explicitSourceRecordId != null || String.isBlank(participantKey)) {
            return explicitSourceRecordId;
        }

        String resolverClassName = null;
        try {
            resolverClassName = InteractionChannelRegistryService.resolveParticipantResolverClassName(channel);
        } catch (Exception e) {
            return null;
        }

        if (String.isBlank(resolverClassName)) {
            return null;
        }

        if (testParticipantResolversByClassName.containsKey(resolverClassName)) {
            return testParticipantResolversByClassName.get(resolverClassName).resolveSourceRecordId(participantKey, explicitSourceRecordId);
        }

        Type resolverType = Type.forName(resolverClassName);
        if (resolverType == null) {
            throw new AIAgentException.OrchestrationException('Participant resolver class not found: ' + resolverClassName);
        }
        Object instanceObj = resolverType.newInstance();
        if (!(instanceObj instanceof IChannelParticipantResolver)) {
            throw new AIAgentException.OrchestrationException('Participant resolver must implement IChannelParticipantResolver: ' + resolverClassName);
        }
        return ((IChannelParticipantResolver) instanceObj).resolveSourceRecordId(participantKey, explicitSourceRecordId);
    }

    @TestVisible
    static void setTestParticipantResolver(String resolverClassName, IChannelParticipantResolver resolver) {
        if (String.isBlank(resolverClassName)) {
            return;
        }
        if (resolver == null) {
            testParticipantResolversByClassName.remove(resolverClassName);
            return;
        }
        testParticipantResolversByClassName.put(resolverClassName, resolver);
    }

    @TestVisible
    static void clearTestParticipantResolvers() {
        testParticipantResolversByClassName.clear();
    }

    private Map<String, Object> parseJsonMap(String jsonValue) {
        return String.isNotBlank(jsonValue) ? (Map<String, Object>) JSON.deserializeUntyped(jsonValue) : new Map<String, Object>();
    }

    private String buildTurnIdentifier(String providerMessageId) {
        return String.isNotBlank(providerMessageId) ? providerMessageId.abbreviate(80) : UUID.randomUUID().toString();
    }

    private Id tryParseId(String rawValue) {
        if (String.isBlank(rawValue)) {
            return null;
        }
        try {
            return Id.valueOf(rawValue);
        } catch (Exception e) {
            return null;
        }
    }

    private String stringValue(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private String firstNonBlank(String firstValue, String secondValue) {
        return String.isNotBlank(firstValue) ? firstValue : secondValue;
    }

    private NormalizedIngressModels.ProcessingResult failureResult(String errorCode, String errorMessage) {
        NormalizedIngressModels.ProcessingResult result = new NormalizedIngressModels.ProcessingResult();
        result.success = false;
        result.processingStatus = IngressEventService.STATUS_FAILED;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        return result;
    }
}
