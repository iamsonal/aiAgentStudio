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
    public interface IChannelDescriptor {
        String getKey();
        String getAdapterClassName();
        String getIterativeRuntimeClassName();
    }

    public class EmailChannelDescriptor implements IChannelDescriptor {
        public String getKey() {
            return RuntimeRegistryService.CHANNEL_EMAIL;
        }
        public String getAdapterClassName() {
            return 'EmailChannelAdapter';
        }
        public String getIterativeRuntimeClassName() {
            return 'EmailIterativeRuntimeService';
        }
    }

    public class ChatChannelDescriptor implements IChannelDescriptor {
        public String getKey() {
            return RuntimeRegistryService.CHANNEL_CHAT;
        }
        public String getAdapterClassName() {
            return 'ChatChannelAdapter';
        }
        public String getIterativeRuntimeClassName() {
            return 'ChatIterativeRuntimeService';
        }
    }

    public class ApiChannelDescriptor implements IChannelDescriptor {
        public String getKey() {
            return RuntimeRegistryService.CHANNEL_API;
        }
        public String getAdapterClassName() {
            return 'ApiInteractionChannel';
        }
        public String getIterativeRuntimeClassName() {
            return 'ChatIterativeRuntimeService';
        }
    }

    public static String resolveChannel(AIAgentDefinition__c agentDefinition, Id executionId, String explicitInteractionChannel) {
        return String.isNotBlank(explicitInteractionChannel)
            ? explicitInteractionChannel
            : RuntimeRegistryService.getInteractionChannel(agentDefinition, executionId);
    }

    public static String resolveDefaultChannelForStrategy(String strategyKey) {
        if (String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.SingleShot).equalsIgnoreCase(strategyKey)) {
            return RuntimeRegistryService.CHANNEL_API;
        }
        if (String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Iterative).equalsIgnoreCase(strategyKey)) {
            return RuntimeRegistryService.CHANNEL_CHAT;
        }
        return null;
    }

    public static IChannelDescriptor resolveDescriptor(String interactionChannel) {
        if (RuntimeRegistryService.CHANNEL_EMAIL.equalsIgnoreCase(interactionChannel)) {
            return new EmailChannelDescriptor();
        }
        if (RuntimeRegistryService.CHANNEL_API.equalsIgnoreCase(interactionChannel)) {
            return new ApiChannelDescriptor();
        }
        if (RuntimeRegistryService.CHANNEL_CHAT.equalsIgnoreCase(interactionChannel)) {
            return new ChatChannelDescriptor();
        }
        throw new AIAgentException.OrchestrationException('Unsupported interaction channel: ' + interactionChannel);
    }

    public static InteractionRuntimeModels.IInteractionChannel resolveAdapter(
        AIAgentDefinition__c agentDefinition,
        Id executionId,
        String explicitInteractionChannel
    ) {
        String interactionChannel = resolveChannel(agentDefinition, executionId, explicitInteractionChannel);
        IChannelDescriptor descriptor = resolveDescriptor(interactionChannel);
        Type adapterType = Type.forName(descriptor.getAdapterClassName());
        if (adapterType == null) {
            throw new AIAgentException.OrchestrationException('Interaction channel adapter class not found: ' + descriptor.getAdapterClassName());
        }
        Object instanceObj = adapterType.newInstance();
        if (!(instanceObj instanceof InteractionRuntimeModels.IInteractionChannel)) {
            throw new AIAgentException.OrchestrationException(
                'Interaction channel adapter must implement IInteractionChannel: ' + descriptor.getAdapterClassName()
            );
        }
        return (InteractionRuntimeModels.IInteractionChannel) instanceObj;
    }

    public static IAgentRuntime resolveIterativeRuntime(AIAgentDefinition__c agentDefinition, String interactionChannel) {
        IChannelDescriptor descriptor = resolveDescriptor(interactionChannel);
        Type runtimeType = Type.forName(descriptor.getIterativeRuntimeClassName());
        if (runtimeType == null) {
            throw new AIAgentException.OrchestrationException('Iterative runtime class not found: ' + descriptor.getIterativeRuntimeClassName());
        }
        Object instanceObj = runtimeType.newInstance();
        if (!(instanceObj instanceof IAgentRuntime)) {
            throw new AIAgentException.OrchestrationException('Iterative runtime must implement IAgentRuntime: ' + descriptor.getIterativeRuntimeClassName());
        }
        IAgentRuntime runtime = (IAgentRuntime) instanceObj;
        runtime.configure(agentDefinition);
        return runtime;
    }
}
