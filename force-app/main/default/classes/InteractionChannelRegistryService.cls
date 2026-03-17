/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Registry facade for resolving interaction channels and their adapters.
 */
public inherited sharing class InteractionChannelRegistryService {
    @TestVisible
    private static Map<String, InteractionChannelType__mdt> testChannelTypesByKey;
    @TestVisible
    private static Map<String, InteractionRuntimeModels.IInteractionChannel> testAdaptersByClassName = new Map<String, InteractionRuntimeModels.IInteractionChannel>();

    public class ChannelDescriptor {
        public String key { get; set; }
        public String adapterClassName { get; set; }
        public String iterativeRuntimeClassName { get; set; }
        public String participantResolverClassName { get; set; }
    }

    @TestVisible
    static void setTestChannelTypes(List<InteractionChannelType__mdt> channelTypes) {
        testChannelTypesByKey = new Map<String, InteractionChannelType__mdt>();
        if (channelTypes == null) {
            return;
        }
        for (InteractionChannelType__mdt channelType : channelTypes) {
            if (channelType != null && String.isNotBlank(channelType.ChannelKey__c)) {
                testChannelTypesByKey.put(channelType.ChannelKey__c.toLowerCase(), channelType);
            }
        }
    }

    @TestVisible
    static void clearTestChannelTypes() {
        testChannelTypesByKey = null;
    }

    @TestVisible
    static void setTestAdapter(String adapterClassName, InteractionRuntimeModels.IInteractionChannel adapter) {
        if (String.isBlank(adapterClassName)) {
            return;
        }
        if (adapter == null) {
            testAdaptersByClassName.remove(adapterClassName);
            return;
        }
        testAdaptersByClassName.put(adapterClassName, adapter);
    }

    @TestVisible
    static void clearTestAdapters() {
        testAdaptersByClassName.clear();
    }

    public static String resolveChannel(AIAgentDefinition__c agentDefinition, Id executionId, String explicitInteractionChannel) {
        return String.isNotBlank(explicitInteractionChannel)
            ? explicitInteractionChannel
            : RuntimeRegistryService.getInteractionChannel(agentDefinition, executionId);
    }

    public static String resolveDefaultChannelForStrategy(String strategyKey) {
        if (String.isBlank(strategyKey)) {
            return null;
        }
        String fieldName = String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Direct).equalsIgnoreCase(strategyKey)
            ? 'DefaultForDirect__c'
            : (String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational).equalsIgnoreCase(strategyKey)
                  ? 'DefaultForConversational__c'
                  : null);
        if (String.isBlank(fieldName)) {
            return null;
        }

        List<InteractionChannelType__mdt> channelTypes = queryActiveChannelTypes();
        for (InteractionChannelType__mdt channelType : channelTypes) {
            Object rawValue = channelType.get(fieldName);
            if (rawValue instanceof Boolean && (Boolean) rawValue == true) {
                return channelType.ChannelKey__c;
            }
        }
        return null;
    }

    public static ChannelDescriptor resolveDescriptor(String interactionChannel) {
        if (String.isBlank(interactionChannel)) {
            throw new AIAgentException.OrchestrationException('Interaction channel is required.');
        }
        InteractionChannelType__mdt record = queryChannelType(interactionChannel);
        if (record == null) {
            throw new AIAgentException.OrchestrationException('Unsupported interaction channel: ' + interactionChannel);
        }
        ChannelDescriptor descriptor = new ChannelDescriptor();
        descriptor.key = record.ChannelKey__c;
        descriptor.adapterClassName = record.InteractionAdapterClass__c;
        descriptor.iterativeRuntimeClassName = record.ConversationalRuntimeClass__c;
        descriptor.participantResolverClassName = record.ParticipantResolverClass__c;
        return descriptor;
    }

    public static InteractionRuntimeModels.IInteractionChannel resolveAdapter(
        AIAgentDefinition__c agentDefinition,
        Id executionId,
        String explicitInteractionChannel
    ) {
        String interactionChannel = resolveChannel(agentDefinition, executionId, explicitInteractionChannel);
        ChannelDescriptor descriptor = resolveDescriptor(interactionChannel);
        if (testAdaptersByClassName.containsKey(descriptor.adapterClassName)) {
            return testAdaptersByClassName.get(descriptor.adapterClassName);
        }
        Type adapterType = Type.forName(descriptor.adapterClassName);
        if (adapterType == null) {
            throw new AIAgentException.OrchestrationException('Interaction channel adapter class not found: ' + descriptor.adapterClassName);
        }
        Object instanceObj = adapterType.newInstance();
        if (!(instanceObj instanceof InteractionRuntimeModels.IInteractionChannel)) {
            throw new AIAgentException.OrchestrationException('Interaction channel adapter must implement IInteractionChannel: ' + descriptor.adapterClassName);
        }
        return (InteractionRuntimeModels.IInteractionChannel) instanceObj;
    }

    public static IAgentRuntime resolveIterativeRuntime(AIAgentDefinition__c agentDefinition, String interactionChannel) {
        ChannelDescriptor descriptor = resolveDescriptor(interactionChannel);
        Type runtimeType = Type.forName(descriptor.iterativeRuntimeClassName);
        if (runtimeType == null) {
            throw new AIAgentException.OrchestrationException('Conversational runtime class not found: ' + descriptor.iterativeRuntimeClassName);
        }
        Object instanceObj = runtimeType.newInstance();
        if (!(instanceObj instanceof IAgentRuntime)) {
            throw new AIAgentException.OrchestrationException('Conversational runtime must implement IAgentRuntime: ' + descriptor.iterativeRuntimeClassName);
        }
        IAgentRuntime runtime = (IAgentRuntime) instanceObj;
        runtime.configure(agentDefinition);
        return runtime;
    }

    public static String resolveParticipantResolverClassName(String interactionChannel) {
        ChannelDescriptor descriptor = resolveDescriptor(interactionChannel);
        return descriptor.participantResolverClassName;
    }

    private static InteractionChannelType__mdt queryChannelType(String interactionChannel) {
        if (Test.isRunningTest() && testChannelTypesByKey != null) {
            return testChannelTypesByKey.get(interactionChannel != null ? interactionChannel.toLowerCase() : null);
        }
        List<InteractionChannelType__mdt> records = [
            SELECT ChannelKey__c, InteractionAdapterClass__c, ConversationalRuntimeClass__c, ParticipantResolverClass__c, IsActive__c
            FROM InteractionChannelType__mdt
            WHERE ChannelKey__c = :interactionChannel AND IsActive__c = TRUE
            LIMIT 1
        ];
        return records.isEmpty() ? null : records[0];
    }

    private static List<InteractionChannelType__mdt> queryActiveChannelTypes() {
        if (Test.isRunningTest() && testChannelTypesByKey != null) {
            return new List<InteractionChannelType__mdt>(testChannelTypesByKey.values());
        }
        return [
            SELECT
                ChannelKey__c,
                InteractionAdapterClass__c,
                ConversationalRuntimeClass__c,
                ParticipantResolverClass__c,
                DefaultForConversational__c,
                DefaultForDirect__c,
                IsActive__c
            FROM InteractionChannelType__mdt
            WHERE IsActive__c = TRUE
        ];
    }
}
