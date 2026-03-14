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
    private static final Map<String, String> STRATEGY_CLASSES = new Map<String, String>{
        String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.SingleShot) => 'SingleShotExecutionStrategy',
        String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Iterative) => 'IterativeExecutionStrategy'
    };

    public interface IExecutionStrategyDescriptor {
        String getKey();
        InteractionRuntimeModels.TraitSet getTraits(String channel);
    }

    public class SingleShotStrategyDescriptor implements IExecutionStrategyDescriptor {
        public String getKey() {
            return String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.SingleShot);
        }

        public InteractionRuntimeModels.TraitSet getTraits(String channel) {
            InteractionRuntimeModels.TraitSet traits = new InteractionRuntimeModels.TraitSet();
            traits.requiresCleanPreCalloutTransaction = true;
            return traits;
        }
    }

    public class IterativeStrategyDescriptor implements IExecutionStrategyDescriptor {
        public String getKey() {
            return String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Iterative);
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
        String normalizedKey = String.isNotBlank(key) ? key : String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Iterative);
        if (String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.SingleShot).equalsIgnoreCase(normalizedKey)) {
            return new SingleShotStrategyDescriptor();
        }
        if (String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Iterative).equalsIgnoreCase(normalizedKey)) {
            return new IterativeStrategyDescriptor();
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
        String normalizedKey = String.isNotBlank(key) ? key : String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Iterative);
        String className = STRATEGY_CLASSES.containsKey(normalizedKey)
            ? STRATEGY_CLASSES.get(normalizedKey)
            : STRATEGY_CLASSES.get(String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Iterative));
        Type strategyType = Type.forName(className);
        if (strategyType == null) {
            throw new AIAgentException.OrchestrationException('Strategy class not found: ' + className);
        }
        return (IExecutionStrategy) strategyType.newInstance();
    }
}
