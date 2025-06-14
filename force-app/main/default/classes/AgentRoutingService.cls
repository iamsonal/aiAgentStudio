/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Service responsible for selecting the appropriate AI Agent Definition
 *              based on an explicit request or a system-wide fallback mechanism.
 *              This service provides a predictable, multi-tiered routing strategy.
 *
 * @see AIAgentController
 * @see AIAgentConfigService
 */
public inherited sharing class AgentRoutingService {
    private static final String LOG_PREFIX = '[AgentRoutingService] ';

    /** @description Custom Exception for unrecoverable routing failures. */
    public virtual class RoutingException extends AIAgentException {
    }

    /** @description Custom Exception for configuration issues found during routing. */
    public class ConfigurationException extends RoutingException {
    }

    /**
     * @description Selects an active Agent Definition Developer Name based on a tiered evaluation strategy.
     * @strategy
     *  1.  **Explicit Request:** Uses the agent specified by the client (e.g., LWC property), if valid. Fails fast if the requested agent is invalid or inactive.
     *  2.  **System Fallback:** If no agent is explicitly requested, falls back to the first active agent found, ordered alphabetically by Developer Name for predictability.
     *
     * @param userId The ID of the user initiating the request. (Reserved for future rule evaluation).
     * @param recordId The ID of the current record context, if applicable. (Reserved for future rule evaluation).
     * @param requestedAgentDevName The Developer Name of the agent specifically requested by the client. Can be null.
     * @return String The validated Developer Name of the selected active AIAgentDefinition__c.
     * @throws RoutingException if no valid, active, or usable agent can be selected.
     */
    public static String selectAgent(Id userId, Id recordId, String requestedAgentDevName) {
        if (userId == null) {
            throw new RoutingException('User ID is required for agent selection.');
        }

        if (String.isNotBlank(requestedAgentDevName)) {
            return selectExplicitlyRequestedAgent(requestedAgentDevName);
        }

        return selectFallbackAgent();
    }

    /**
     * @description Attempts to validate and return an explicitly requested agent.
     *              This method fails fast if the requested agent is not found or is inactive.
     * @param requestedAgentDevName The developer name to validate.
     * @return The validated developer name.
     * @throws ConfigurationException if the agent is not found or inactive.
     */
    @TestVisible
    private static String selectExplicitlyRequestedAgent(String requestedAgentDevName) {
        try {
            AIAgentDefinition__c requestedAgent = AIAgentConfigService.getAgentDefinitionByDeveloperName(requestedAgentDevName);

            return requestedAgent.DeveloperName__c;
        } catch (AIAgentConfigService.ConfigurationException e) {
            String errorMsg =
                'The AI Agent "' +
                requestedAgentDevName +
                '" specified in the component configuration could not be found or is not active.';

            throw new ConfigurationException(errorMsg, e);
        }
    }

    /**
     * @description Selects a fallback agent by finding the first active agent alphabetically.
     * @return The developer name of the selected fallback agent.
     * @throws ConfigurationException if no usable fallback agent can be found in the org.
     */
    @TestVisible
    private static String selectFallbackAgent() {
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
                String errorMsg = 'No active AI agents are configured in the system. An administrator must create and activate at least one agent.';

                throw new ConfigurationException(errorMsg);
            }
        } catch (Exception e) {
            String errorMsg = 'A critical error occurred while trying to select a default AI agent.';

            throw new ConfigurationException(errorMsg, e);
        }
    }
}
