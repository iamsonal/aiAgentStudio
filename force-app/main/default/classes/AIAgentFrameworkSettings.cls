/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Centralized configuration management service. Provides cached access to custom settings with intelligent fallback to defaults.
 */
public inherited sharing class AIAgentFrameworkSettings {
    private static AIAgentFrameworkSettings__c settings;
    private static final Integer FINAL_DEFAULT_MaxConversationTurns = 10;
    private static final Integer FINAL_DEFAULT_MaxToolRetries = 2;
    private static final Integer FINAL_DEFAULT_BulkConcurrencyLimit = 5;
    private static final Integer FINAL_DEFAULT_BulkFailureThreshold = 5;
    private static final Integer FINAL_DEFAULT_MaxLLMCallsPerTransaction = 2;
    private static final Integer FINAL_DEFAULT_MaxDependencyViolations = 3;
    private static final Boolean FINAL_DEFAULT_EnableDecisionStepLogging = true;
    private static final Boolean FINAL_DEFAULT_ExtendQueueableChainLimit = false;
    public static AIAgentFrameworkSettings__c getInstance() {
        if (settings == null) {
            settings = AIAgentFrameworkSettings__c.getOrgDefaults();

            if (settings == null || settings.Id == null) {
                settings = new AIAgentFrameworkSettings__c();
                settings.DefaultMaxConversationTurns__c = FINAL_DEFAULT_MaxConversationTurns;
                settings.MaxToolRetries__c = FINAL_DEFAULT_MaxToolRetries;
                settings.BulkConcurrencyLimit__c = FINAL_DEFAULT_BulkConcurrencyLimit;
                settings.BulkFailureThreshold__c = FINAL_DEFAULT_BulkFailureThreshold;
                settings.EnableDecisionStepLogging__c = FINAL_DEFAULT_EnableDecisionStepLogging;
                settings.ExtendQueueableChainLimit__c = FINAL_DEFAULT_ExtendQueueableChainLimit;
                System.debug(LoggingLevel.WARN, '[AIAgentFrameworkSettings] No Custom Setting record found - using hardcoded default values for all settings');
            } else {
                // Record exists, fill in missing individual fields with FINAL defaults
                if (settings.DefaultMaxConversationTurns__c == null || settings.DefaultMaxConversationTurns__c < 0) {
                    settings.DefaultMaxConversationTurns__c = FINAL_DEFAULT_MaxConversationTurns;
                }
                if (settings.MaxToolRetries__c == null || settings.MaxToolRetries__c < 0) {
                    settings.MaxToolRetries__c = FINAL_DEFAULT_MaxToolRetries;
                }
                if (settings.BulkConcurrencyLimit__c == null || settings.BulkConcurrencyLimit__c < 1) {
                    settings.BulkConcurrencyLimit__c = FINAL_DEFAULT_BulkConcurrencyLimit;
                }
                if (settings.BulkFailureThreshold__c == null || settings.BulkFailureThreshold__c < 0) {
                    settings.BulkFailureThreshold__c = FINAL_DEFAULT_BulkFailureThreshold;
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
     * Gets the maximum processing cycles for an agent, using per-agent override from AIAgentDefinition__c if set,
     * otherwise falling back to the org-wide default.
     *
     * @param agentDeveloperName The developer name of the agent (used to lookup AIAgentDefinition__c record)
     * @return The maximum number of processing cycles for the agent, or org-wide default if agent override is not set.
     */
    public static Integer getMaxProcessingCycles(String agentDeveloperName) {
        // Check if agent has per-agent override in agent definition
        if (String.isNotBlank(agentDeveloperName)) {
            List<AIAgentDefinition__c> agents = [
                SELECT MaxProcessingCycles__c
                FROM AIAgentDefinition__c
                WHERE DeveloperName__c = :agentDeveloperName
                LIMIT 1
            ];
            if (!agents.isEmpty() && agents[0].MaxProcessingCycles__c != null && agents[0].MaxProcessingCycles__c > 0) {
                return Integer.valueOf(agents[0].MaxProcessingCycles__c);
            }
        }
        // Fall back to org-wide default
        return getDefaultMaxConversationTurns();
    }

    /**
     * Gets the maximum processing cycles using an already-loaded AIAgentDefinition__c record.
     * Prefer this overload when the agent definition is already in memory to avoid an extra SOQL.
     *
     * @param agentDef The already-loaded agent definition record (must include MaxProcessingCycles__c)
     * @return The maximum number of processing cycles for the agent
     */
    public static Integer getMaxProcessingCycles(AIAgentDefinition__c agentDef) {
        if (agentDef != null && agentDef.MaxProcessingCycles__c != null && agentDef.MaxProcessingCycles__c > 0) {
            return Integer.valueOf(agentDef.MaxProcessingCycles__c);
        }
        return getDefaultMaxConversationTurns();
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
     * Gets the configured bulk concurrency limit for parallel worker execution.
     * This soft limit prevents database row-locking contention and API rate limiting
     * while allowing administrators to control concurrency safely.
     *
     * @return The bulk concurrency limit (defaults to 5 if not set or invalid).
     */
    public static Integer getBulkConcurrencyLimit() {
        AIAgentFrameworkSettings__c instance = getInstance();
        if (instance.BulkConcurrencyLimit__c != null && instance.BulkConcurrencyLimit__c >= 1) {
            return Integer.valueOf(instance.BulkConcurrencyLimit__c);
        }
        return FINAL_DEFAULT_BulkConcurrencyLimit;
    }

    /**
     * Gets the configured bulk failure threshold - maximum number of failed records
     * allowed before stopping further processing in a bulk execution.
     * Set to 0 to disable failure threshold (process all records regardless of failures).
     *
     * @return The bulk failure threshold (defaults to 10 if not set).
     */
    public static Integer getBulkFailureThreshold() {
        AIAgentFrameworkSettings__c instance = getInstance();
        if (instance.BulkFailureThreshold__c != null && instance.BulkFailureThreshold__c >= 0) {
            return Integer.valueOf(instance.BulkFailureThreshold__c);
        }
        return FINAL_DEFAULT_BulkFailureThreshold;
    }

    /**
     * Calculates the optimal worker count using the Hybrid Cap algorithm.
     * Takes the minimum of: admin-configured soft limit, available queueable slots, and actual records to process.
     * This ensures maximum throughput without exceeding transactional safety boundaries or wasting resources.
     *
     * @param recordCount The number of records that need to be processed
     * @return The optimal number of workers to enqueue
     */
    public static Integer calculateOptimalWorkerCount(Integer recordCount) {
        if (recordCount == null || recordCount <= 0) {
            return 0;
        }

        // Get admin-configured soft limit
        Integer softLimit = getBulkConcurrencyLimit();

        // Get available queueable slots in current transaction
        Integer availableSlots = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();

        // Hybrid Cap: min(soft limit, available slots, actual records)
        Integer optimalCount = Math.min(Math.min(softLimit, availableSlots), recordCount);

        System.debug(
            LoggingLevel.DEBUG,
            '[AIAgentFrameworkSettings] Hybrid Cap calculation: ' +
                'SoftLimit=' +
                softLimit +
                ', AvailableSlots=' +
                availableSlots +
                ', RecordCount=' +
                recordCount +
                ', OptimalCount=' +
                optimalCount
        );

        return Math.max(0, optimalCount); // Ensure non-negative
    }

    /**
     * Gets whether Decision Step Logging is enabled at the org level.
     * When enabled, agent decision steps are logged for visualization in the
     * storyboard UI. This feature requires the AI Agent Studio Addons package
     * to be deployed. When disabled or when addons is not deployed, logging
     * is skipped (no-op).
     *
     * @return True if decision step logging is enabled org-wide.
     */
    public static Boolean isDecisionStepLoggingEnabled() {
        AIAgentFrameworkSettings__c instance = getInstance();
        // Default to true if the field is null (for backward compatibility)
        return instance.EnableDecisionStepLogging__c != false;
    }

    /**
     * Gets the maximum number of LLM calls allowed per transaction for multi-turn optimization.
     * When a sync tool doesn't perform DML or callouts, the framework can call the LLM again
     * in the same transaction instead of queueing a follow-up job. This reduces queueable
     * usage and improves response latency.
     *
     * Set to 1 to disable multi-LLM optimization (use single call per transaction).
     * Default is 2, allowing one additional LLM call when the first tool is safe.
     *
     * @return The maximum number of LLM calls allowed per transaction.
     */
    public static Integer getMaxLLMCallsPerTransaction() {
        AIAgentFrameworkSettings__c instance = getInstance();
        if (instance.MaxLLMCallsPerTransaction__c != null && instance.MaxLLMCallsPerTransaction__c >= 1) {
            return Integer.valueOf(instance.MaxLLMCallsPerTransaction__c);
        }
        return FINAL_DEFAULT_MaxLLMCallsPerTransaction;
    }

    /**
     * Gets the maximum number of dependency validation failures allowed per execution
     * before the agent is stopped with an error. Acts as a circuit breaker to prevent
     * infinite loops when the LLM repeatedly violates tool dependencies.
     *
     * Default is 3 - if the LLM violates dependencies 3 times, execution fails.
     *
     * @return The maximum dependency violations allowed before execution fails.
     */
    public static Integer getMaxDependencyViolations() {
        // Currently using hardcoded default - could be added to custom setting if needed
        return FINAL_DEFAULT_MaxDependencyViolations;
    }

    /**
     * Determines if AsyncOptions should be used to extend queueable chain limits.
     * Enable this setting in orgs with 5-chain limits (scratch/developer/trial orgs).
     * Disable in orgs with 50-chain limits (production/sandbox orgs).
     *
     * Default is FALSE (assumes production/sandbox with 50-chain limit).
     *
     * @return TRUE if AsyncOptions should be configured, FALSE otherwise.
     */
    public static Boolean shouldExtendQueueableChainLimit() {
        return getInstance().ExtendQueueableChainLimit__c == true;
    }

    /**
     * Clears the cached settings instance. Intended for use in test methods only.
     */
    @TestVisible
    private static void clearCache() {
        settings = null;
    }
}
