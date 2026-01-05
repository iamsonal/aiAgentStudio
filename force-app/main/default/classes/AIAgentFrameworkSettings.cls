/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Centralized configuration management service for the AI Agent Framework.
 * Provides cached access to custom settings with intelligent fallback to defaults.
 */
public inherited sharing class AIAgentFrameworkSettings {
    private static AIAgentFrameworkSettings__c settings;

    // Define hardcoded final defaults directly here. Names reflect settings field names.
    private static final Integer FINAL_DEFAULT_MaxConversationTurns = 5;
    private static final Integer FINAL_DEFAULT_MaxQueueableStackDepth = 0; // 0 means use Salesforce defaults
    private static final Integer FINAL_DEFAULT_MaxToolRetries = 2;
    private static final String FINAL_DEFAULT_HITLApprovalNamedCredential = 'AgentStudioInternalAPI';

    /**
     * Gets the singleton instance of the framework settings, applying hardcoded defaults for any missing or invalid values.
     *
     * @return The singleton AIAgentFrameworkSettings__c instance with all fields populated (never null).
     */
    public static AIAgentFrameworkSettings__c getInstance() {
        if (settings == null) {
            settings = AIAgentFrameworkSettings__c.getOrgDefaults();

            // If NO custom setting record exists AT ALL, create an in-memory default
            if (settings == null || settings.Id == null) {
                settings = new AIAgentFrameworkSettings__c(); // Create empty instance
                // Explicitly set all values from FINAL defaults if no record exists
                settings.DefaultMaxConversationTurns__c = FINAL_DEFAULT_MaxConversationTurns;
                settings.MaxQueueableStackDepth__c = FINAL_DEFAULT_MaxQueueableStackDepth;
                settings.HITLApprovalNamedCredential__c = FINAL_DEFAULT_HITLApprovalNamedCredential;
                System.debug(LoggingLevel.WARN, '[AIAgentFrameworkSettings] No Custom Setting record found - using hardcoded default values for all settings');
            } else {
                // Record exists, fill in missing individual fields with FINAL defaults
                if (settings.DefaultMaxConversationTurns__c == null || settings.DefaultMaxConversationTurns__c < 0) {
                    settings.DefaultMaxConversationTurns__c = FINAL_DEFAULT_MaxConversationTurns;
                }
                if (settings.MaxQueueableStackDepth__c == null || settings.MaxQueueableStackDepth__c < 0) {
                    settings.MaxQueueableStackDepth__c = FINAL_DEFAULT_MaxQueueableStackDepth;
                }
                if (String.isBlank(settings.HITLApprovalNamedCredential__c)) {
                    settings.HITLApprovalNamedCredential__c = FINAL_DEFAULT_HITLApprovalNamedCredential;
                }
            }
            System.debug(LoggingLevel.INFO, '[AIAgentFrameworkSettings] Framework settings successfully initialized and cached');
        }
        return settings;
    }

    /**
     * Gets the configured default max conversation turns, falling back to the internal default if not set.
     *
     * @return The default maximum number of conversation turns.
     */
    public static Integer getDefaultMaxConversationTurns() {
        return Integer.valueOf(getInstance().DefaultMaxConversationTurns__c);
    }

    /**
     * Gets the maximum processing cycles for an agent, using per-agent override from AIAgentSettings__c if set,
     * otherwise falling back to the org-wide default.
     *
     * @param agentDeveloperName The developer name of the agent (used to lookup AIAgentSettings__c record)
     * @return The maximum number of processing cycles for the agent, or org-wide default if agent override is not set.
     */
    public static Integer getMaxProcessingCycles(String agentDeveloperName) {
        // Check if agent has per-agent override in custom setting
        if (String.isNotBlank(agentDeveloperName)) {
            AIAgentSettings__c agentSettings = AIAgentSettings__c.getInstance(agentDeveloperName);
            if (agentSettings != null && agentSettings.MaxProcessingCycles__c != null && agentSettings.MaxProcessingCycles__c > 0) {
                return Integer.valueOf(agentSettings.MaxProcessingCycles__c);
            }
        }
        // Fall back to org-wide default
        return getDefaultMaxConversationTurns();
    }

    /**
     * Gets the configured maximum queueable stack depth for chained jobs.
     * Returns 0 to use Salesforce defaults (recommended for production/sandbox).
     * Set to 50+ for scratch/developer orgs to override the 5-job limit.
     *
     * @return The maximum queueable stack depth (0 = use defaults).
     */
    public static Integer getMaxQueueableStackDepth() {
        return Integer.valueOf(getInstance().MaxQueueableStackDepth__c);
    }

    /**
     * Gets the Named Credential API name to use for HITL-approved tool execution.
     * The Named Credential's authentication determines the execution context.
     *
     * @return The Named Credential API name for HITL approval executions.
     */
    public static String getHITLApprovalNamedCredential() {
        return getInstance().HITLApprovalNamedCredential__c;
    }

    /**
     * Gets the maximum number of successive failures allowed for a tool before the execution
     * is automatically failed. Only applies to non-Conversational agents when using autonomous recovery.
     * Conversational agents let the LLM decide how to handle errors.
     *
     * @return The maximum tool retries (defaults to 2 if not set).
     */
    public static Integer getMaxToolRetries() {
        AIAgentFrameworkSettings__c instance = getInstance();
        if (instance.MaxToolRetries__c != null && instance.MaxToolRetries__c > 0) {
            return Integer.valueOf(instance.MaxToolRetries__c);
        }
        return FINAL_DEFAULT_MaxToolRetries;
    }

    /**
     * Clears the cached settings instance. Intended for use in test methods only.
     */
    @TestVisible
    private static void clearCache() {
        settings = null;
    }
}
