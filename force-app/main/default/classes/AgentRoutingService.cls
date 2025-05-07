/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Service responsible for selecting the appropriate AI Agent Definition
 *              based on context, user request, or fallback rules.
 *              PHASE 1 IMPLEMENTATION: Handles explicitly requested agents and a basic fallback.
 */
public inherited sharing class AgentRoutingService {
    /** Custom Exception for routing failures */
    public virtual class RoutingException extends AIAgentException {
    }
    /** Custom Exception for configuration issues found during routing */
    public class ConfigurationException extends RoutingException {
    }

    private static final String LOG_PREFIX = '[AgentRoutingService] ';

    /**
     * @description Selects an appropriate Agent Definition Developer Name.
     *              Phase 1: Prioritizes explicitly requested agent if valid, otherwise falls back to the first active agent found.
     * @param userId The ID of the user initiating the request. Required.
     * @param recordId The ID of the current record context, if applicable (can be null). Used for future context rules.
     * @param requestedAgentDevName The Developer Name of the agent specifically requested (e.g., from LWC config). Can be null.
     * @return String The validated Developer Name of the selected active AIAgentDefinition__c.
     * @throws ConfigurationException if no valid/active agent can be selected (requested or fallback).
     */
    public static String selectAgent(Id userId, Id recordId, String requestedAgentDevName) {
        if (userId == null) {
            throw new RoutingException('User ID is required for agent selection.');
        }

        if (String.isNotBlank(requestedAgentDevName)) {
            try {
                AIAgentDefinition__c requestedAgent = AIAgentConfigService.getAgentDefinitionByDeveloperName(requestedAgentDevName);

                return requestedAgent.DeveloperName__c;
            } catch (AIAgentConfigService.ConfigurationException ce) {
            } catch (Exception e) {
            }
        }

        /*
        
        
        
        
        
        
        */

        /*
        
        
        
        
        
        
        */

        try {
            List<AIAgentDefinition__c> fallbackAgents = [
                SELECT DeveloperName__c
                FROM AIAgentDefinition__c
                WHERE IsActive__c = TRUE
                ORDER BY DeveloperName__c ASC
                LIMIT 1
            ];

            if (!fallbackAgents.isEmpty()) {
                String fallbackAgentName = fallbackAgents[0].DeveloperName__c;

                return fallbackAgentName;
            } else {
                throw new ConfigurationException('No active AI Agent Definitions are configured in the system.');
            }
        } catch (Exception e) {
            throw new ConfigurationException('Failed to select a fallback agent: ' + e.getMessage(), e);
        }
    }
}
