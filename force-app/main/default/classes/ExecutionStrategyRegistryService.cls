/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Registry for execution-strategy descriptors and runtime implementations.
 * This is the strategy-native seam between agent configuration and concrete strategy classes.
 */
public inherited sharing class ExecutionStrategyRegistryService {
    public interface IExecutionStrategyDescriptor {
        String getKey();
        InteractionRuntimeModels.TraitSet getTraits(String channel);
    }

    public class DirectStrategyDescriptor implements IExecutionStrategyDescriptor {
        public String getKey() {
            return String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Direct);
        }

        public InteractionRuntimeModels.TraitSet getTraits(String channel) {
            InteractionRuntimeModels.TraitSet traits = new InteractionRuntimeModels.TraitSet();
            traits.requiresCleanPreCalloutTransaction = true;
            return traits;
        }
    }

    public class ConversationalStrategyDescriptor implements IExecutionStrategyDescriptor {
        public String getKey() {
            return String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational);
        }

        public InteractionRuntimeModels.TraitSet getTraits(String channel) {
            InteractionRuntimeModels.TraitSet traits = new InteractionRuntimeModels.TraitSet();
            traits.supportsContextLedger = true;
            traits.routesFailuresBackToUser = true;
            traits.supportsSameExecutionResume = true;
            if (RuntimeRegistryService.CHANNEL_CHAT.equalsIgnoreCase(channel)) {
                traits.publishesUiEvents = true;
                traits.supportsConfirmationHitl = true;
            }
            return traits;
        }
    }

    public static IExecutionStrategyDescriptor resolveDescriptor(AIAgentDefinition__c agentDefinition) {
        return resolveDescriptor(RuntimeRegistryService.getExecutionStrategyKey(agentDefinition));
    }

    public static IExecutionStrategyDescriptor resolveDescriptor(Id executionId) {
        return resolveDescriptor(RuntimeRegistryService.getExecutionStrategyKey(executionId));
    }

    public static IExecutionStrategyDescriptor resolveDescriptor(String key) {
        String normalizedKey = String.isNotBlank(key) ? key : String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational);
        if (String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Direct).equalsIgnoreCase(normalizedKey)) {
            return new DirectStrategyDescriptor();
        }
        if (String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational).equalsIgnoreCase(normalizedKey)) {
            return new ConversationalStrategyDescriptor();
        }
        return null;
    }

    public static Boolean isKnownStrategyKey(String key) {
        return resolveDescriptor(key) != null;
    }

    public static IExecutionStrategy resolveStrategy(AIAgentDefinition__c agentDefinition, String interactionChannel) {
        return instantiateStrategy(RuntimeRegistryService.getExecutionStrategyKey(agentDefinition));
    }

    public static IExecutionStrategy resolveStrategy(Id executionId) {
        return instantiateStrategy(RuntimeRegistryService.getExecutionStrategyKey(executionId));
    }

    private static IExecutionStrategy instantiateStrategy(String key) {
        String normalizedKey = String.isNotBlank(key) ? key : String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational);
        if (String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Direct).equalsIgnoreCase(normalizedKey)) {
            return new DirectRuntimeService();
        }
        return new ConversationalExecutionStrategy();
    }
}
