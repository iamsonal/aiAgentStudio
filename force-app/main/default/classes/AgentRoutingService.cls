/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AgentRoutingService is responsible for selecting the most appropriate AI Agent Definition for a given context.
 * It implements a robust, multi-tiered routing strategy that:
 *   - Prioritizes explicit agent requests from clients, validating their existence and active status
 *   - Provides a reliable, predictable fallback mechanism when no agent is explicitly requested
 *   - Ensures consistent, auditable agent selection across the platform
 *   - Surfaces configuration and routing errors clearly for maintainers and administrators
 *
 * This service is designed for extensibility and operational transparency, serving as the single point of truth
 * for agent selection logic within the AI Agent Framework.
 */
public inherited sharing class AgentRoutingService {
    private static final String LOG_PREFIX = '[AgentRoutingService] ';

    /**
     * Exception for unrecoverable routing failures.
     */
    public virtual class RoutingException extends AIAgentException {
    }

    /**
     * Exception for configuration issues found during routing (e.g., no active agents).
     */
    public class ConfigurationException extends RoutingException {
    }

    /**
     * Selects an active Agent Definition Developer Name using a tiered evaluation strategy:
     *   1. Explicit Request: Uses the agent specified by the client, if valid and active. Fails fast if invalid.
     *   2. System Fallback: If no agent is explicitly requested, selects the first active agent alphabetically.
     *
     * @param userId                The ID of the user initiating the request. (Reserved for future rule evaluation)
     * @param recordId              The ID of the current record context, if applicable. (Reserved for future rule evaluation)
     * @param requestedAgentDevName The Developer Name of the agent specifically requested by the client. Can be null.
     * @return                      The validated Developer Name of the selected active AIAgentDefinition__c.
     * @throws RoutingException     If no valid, active, or usable agent can be selected.
     */
    public static String selectAgent(Id userId, Id recordId, String requestedAgentDevName) {
        System.debug(
            LoggingLevel.INFO,
            LOG_PREFIX + 'Agent selection started. UserId=' + userId + ', RecordId=' + recordId + ', RequestedAgent=' + requestedAgentDevName
        );

        if (userId == null) {
            throw new RoutingException('User ID is required for agent selection.');
        }

        // Tier 1: Explicit Request (Highest Priority)
        if (String.isNotBlank(requestedAgentDevName)) {
            return selectExplicitlyRequestedAgent(requestedAgentDevName);
        }

        // Tier 2: System Fallback Logic
        return selectFallbackAgent();
    }

    /**
     * Attempts to validate and return an explicitly requested agent by developer name.
     * Fails fast if the requested agent is not found or is inactive.
     *
     * @param requestedAgentDevName The developer name to validate.
     * @return                      The validated developer name.
     * @throws ConfigurationException If the agent is not found or inactive.
     */
    @TestVisible
    private static String selectExplicitlyRequestedAgent(String requestedAgentDevName) {
        System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Tier 1: Validating explicit agent request: ' + requestedAgentDevName);
        try {
            // Use AIAgentConfigService as the single source of truth for active configurations.
            // This method inherently checks for active status and throws an exception if not found/inactive.
            AIAgentDefinition__c requestedAgent = AIAgentConfigService.getAgentDefinitionByDeveloperName(requestedAgentDevName);

            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Tier 1: Explicit agent validated and selected: ' + requestedAgent.DeveloperName__c);
            return requestedAgent.DeveloperName__c;
        } catch (AIAgentConfigService.ConfigurationException e) {
            String errorMsg =
                'The AI Agent "' +
                requestedAgentDevName +
                '" specified in the component configuration could not be found or is not active.';
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Tier 1: Explicit agent validation failed: ' + errorMsg);
            // Re-throw as a more user-friendly RoutingException.
            throw new ConfigurationException(errorMsg, e);
        }
    }

    /**
     * Selects a fallback agent by finding the first active agent alphabetically.
     *
     * @return                      The developer name of the selected fallback agent.
     * @throws ConfigurationException If no usable fallback agent can be found in the org.
     */
    @TestVisible
    private static String selectFallbackAgent() {
        System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Tier 2: No explicit agent requested, selecting first available active agent alphabetically.');

        try {
            // Query for any active agent definition as a last resort.
            // Ordering by DeveloperName ensures consistency if multiple fallbacks exist.
            List<AIAgentDefinition__c> fallbackAgents = [
                SELECT DeveloperName__c
                FROM AIAgentDefinition__c
                WHERE IsActive__c = TRUE
                ORDER BY DeveloperName__c ASC
                LIMIT 1
            ];

            if (!fallbackAgents.isEmpty()) {
                String fallbackAgentName = fallbackAgents[0].DeveloperName__c;
                System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Tier 2: Fallback agent selected: ' + fallbackAgentName);
                return fallbackAgentName;
            } else {
                // No active agents found - this is a configuration issue
                String errorMsg = 'No active AI agents are configured in the system. An administrator must create and activate at least one agent.';
                System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Tier 2: No fallback agent found. ' + errorMsg);
                throw new ConfigurationException(errorMsg);
            }
        } catch (Exception e) {
            // Handle unexpected errors during fallback agent selection
            String errorMsg = 'Critical system error occurred during fallback agent selection';
            System.debug(
                LoggingLevel.ERROR,
                LOG_PREFIX + 'Tier 2: ' + errorMsg + '. Exception: ' + e.getMessage() + '\nStack Trace: ' + e.getStackTraceString()
            );
            throw new ConfigurationException(errorMsg + ': ' + e.getMessage(), e);
        }
    }
}
