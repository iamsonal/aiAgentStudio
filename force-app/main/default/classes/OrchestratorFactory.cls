/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * OrchestratorFactory creates and returns the appropriate IAgentOrchestrator implementation
 * based on the agent's AgentType__c field. This factory enables the Strategy pattern for
 * agent orchestration, ensuring each agent type uses the correct execution flow and async strategy.
 *
 * Responsibilities:
 *   - Validates agent configuration and type
 *   - Instantiates the correct orchestrator implementation
 *   - Provides clear error messages for invalid configurations
 */
public class OrchestratorFactory {
    /**
     * Creates and returns the appropriate orchestrator for the given agent definition.
     *
     * @param agentDeveloperName The developer name of the agent
     * @return                   IAgentOrchestrator implementation for the agent's type
     * @throws                   AgentOrchestratorException if agent not found, inactive, or has invalid type
     */
    public static IAgentOrchestrator getOrchestrator(String agentDeveloperName) {
        if (String.isBlank(agentDeveloperName)) {
            throw new AgentOrchestratorException('Agent developer name is required');
        }

        // Retrieve the agent definition with AgentType__c field
        List<AIAgentDefinition__c> agentDefs = [
            SELECT
                Id,
                DeveloperName__c,
                AgentType__c,
                Concurrency__c,
                IsActive__c,
                LLMConfiguration__c,
                RequiresServiceUserContext__c,
                WelcomeMessageTemplate__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c = :agentDeveloperName
            LIMIT 1
        ];

        AIAgentDefinition__c agentDef = agentDefs.isEmpty() ? null : agentDefs[0];

        if (agentDef == null) {
            throw new AgentOrchestratorException('Agent definition not found: ' + agentDeveloperName);
        }

        if (!agentDef.IsActive__c) {
            throw new AgentOrchestratorException('Agent is not active: ' + agentDeveloperName);
        }

        // Validate required fields
        if (String.isBlank(agentDef.AgentType__c)) {
            throw new AgentOrchestratorException('AgentType__c is required on agent definition: ' + agentDeveloperName);
        }

        // Return appropriate orchestrator based on agent type
        String agentType = agentDef.AgentType__c;

        if ('Conversational'.equalsIgnoreCase(agentType)) {
            return new ConversationalOrchestrator(agentDef);
        } else if ('Batch'.equalsIgnoreCase(agentType)) {
            return new BatchOrchestrator(agentDef);
        } else if ('Email'.equalsIgnoreCase(agentType)) {
            return new EmailOrchestrator(agentDef);
        } else if ('Autonomous'.equalsIgnoreCase(agentType)) {
            return new AutonomousOrchestrator(agentDef);
        } else {
            throw new AgentOrchestratorException('Unsupported agent type: ' + agentType + ' for agent: ' + agentDeveloperName);
        }
    }
}
