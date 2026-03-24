/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Central registry for agent execution strategy, interaction channel,
 * and runtime traits. RuntimeStrategy__c is the canonical strategy field for agent runtimes,
 * while pipeline composition is handled outside this registry.
 */
public inherited sharing class RuntimeRegistryService {
    public static final String CHANNEL_EMAIL = 'Email';
    public static final String CHANNEL_CHAT = 'Chat';
    public static final String CHANNEL_DIRECT = 'Direct';
    public static final String CHANNEL_WHATSAPP = 'WhatsApp';
    public static final String CHANNEL_SLACK = 'Slack';
    public static final String CHANNEL_TEAMS = 'Teams';

    public static String getExecutionStrategyKey(AIAgentDefinition__c agentDefinition) {
        if (agentDefinition == null) {
            return String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational);
        }
        String strategyKey = (String) agentDefinition.getPopulatedFieldsAsMap().get('RuntimeStrategy__c');
        if (String.isBlank(strategyKey) && agentDefinition.Id != null) {
            try {
                strategyKey = AIAgentConfigService.getAgentDefinition(agentDefinition.Id).RuntimeStrategy__c;
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.WARN,
                    '[RuntimeRegistryService] Failed to hydrate RuntimeStrategy__c for ' + agentDefinition.Id + ': ' + e.getMessage()
                );
            }
        }
        return String.isNotBlank(strategyKey) ? strategyKey : String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational);
    }

    public static String getExecutionStrategyKey(Id executionId) {
        if (executionId == null) {
            return String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational);
        }

        List<AgentExecution__c> executions = [
            SELECT ExecutionType__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];
        if (executions.isEmpty()) {
            return String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational);
        }

        String strategyKey = executions[0].ExecutionType__c;
        return String.isNotBlank(strategyKey) ? strategyKey : String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational);
    }

    public static String getInteractionChannel(AIAgentDefinition__c agentDefinition, Id executionId) {
        if (executionId != null) {
            List<AgentExecution__c> executions = [
                SELECT InteractionChannel__c, PipelineDefinition__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];
            if (!executions.isEmpty() && String.isNotBlank(executions[0].InteractionChannel__c)) {
                return executions[0].InteractionChannel__c;
            }
            if (!executions.isEmpty() && executions[0].PipelineDefinition__c != null) {
                return null;
            }
        }

        if (agentDefinition != null) {
            String strategyKey = getExecutionStrategyKey(agentDefinition);
            return InteractionChannelRegistryService.resolveDefaultChannelForStrategy(strategyKey);
        }

        return InteractionChannelRegistryService.resolveDefaultChannelForStrategy(
            String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational)
        );
    }

    public static InteractionRuntimeModels.TraitSet getTraits(AIAgentDefinition__c agentDefinition, String channel) {
        ExecutionStrategyRegistryService.IExecutionStrategyDescriptor descriptor = ExecutionStrategyRegistryService.resolveDescriptor(agentDefinition);
        return descriptor != null ? descriptor.getTraits(channel) : new InteractionRuntimeModels.TraitSet();
    }

    public static InteractionRuntimeModels.TraitSet getTraits(Id executionId) {
        List<AgentExecution__c> executions = [
            SELECT ExecutionType__c, InteractionChannel__c, PipelineDefinition__c
            FROM AgentExecution__c
            WHERE Id = :executionId
            LIMIT 1
        ];
        if (executions.isEmpty()) {
            return new InteractionRuntimeModels.TraitSet();
        }
        if (executions[0].PipelineDefinition__c != null) {
            return new InteractionRuntimeModels.TraitSet();
        }
        String strategyKey = String.isNotBlank(executions[0].ExecutionType__c)
            ? executions[0].ExecutionType__c
            : String.valueOf(InteractionRuntimeModels.ExecutionStrategyType.Conversational);
        ExecutionStrategyRegistryService.IExecutionStrategyDescriptor descriptor = ExecutionStrategyRegistryService.resolveDescriptor(strategyKey);
        if (descriptor == null) {
            return new InteractionRuntimeModels.TraitSet();
        }
        String channel = String.isNotBlank(executions[0].InteractionChannel__c)
            ? executions[0].InteractionChannel__c
            : InteractionChannelRegistryService.resolveDefaultChannelForStrategy(strategyKey);
        return descriptor.getTraits(channel);
    }

    public static InteractionRuntimeModels.IInteractionChannel getChannelAdapter(AIAgentDefinition__c agentDefinition, Id executionId) {
        return InteractionChannelRegistryService.resolveAdapter(agentDefinition, executionId, null);
    }
}
