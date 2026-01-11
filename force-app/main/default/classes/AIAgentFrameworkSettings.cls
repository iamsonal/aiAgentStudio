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
    private static final Integer FINAL_DEFAULT_BulkConcurrencyLimit = 5; // Safe default for row locking
    private static final Integer FINAL_DEFAULT_BulkFailureThreshold = 5; // Stop after 5 failures
    private static final String FINAL_DEFAULT_HITLApprovalNamedCredential = 'AgentStudioInternalAPI';
    private static final Boolean FINAL_DEFAULT_EnablePIIMasking = false;
    private static final Boolean FINAL_DEFAULT_EnablePromptSafety = false;
    private static final Boolean FINAL_DEFAULT_PIIAuditLogging = false;
    private static final Boolean FINAL_DEFAULT_PromptSafetyAuditLogging = false;
    private static final Boolean FINAL_DEFAULT_EnableDecisionStepLogging = true;

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
                settings.MaxToolRetries__c = FINAL_DEFAULT_MaxToolRetries;
                settings.BulkConcurrencyLimit__c = FINAL_DEFAULT_BulkConcurrencyLimit;
                settings.BulkFailureThreshold__c = FINAL_DEFAULT_BulkFailureThreshold;
                settings.HITLApprovalNamedCredential__c = FINAL_DEFAULT_HITLApprovalNamedCredential;
                settings.EnablePIIMasking__c = FINAL_DEFAULT_EnablePIIMasking;
                settings.EnablePromptSafety__c = FINAL_DEFAULT_EnablePromptSafety;
                settings.PIIAuditLogging__c = FINAL_DEFAULT_PIIAuditLogging;
                settings.PromptSafetyAuditLogging__c = FINAL_DEFAULT_PromptSafetyAuditLogging;
                settings.EnableDecisionStepLogging__c = FINAL_DEFAULT_EnableDecisionStepLogging;
                System.debug(LoggingLevel.WARN, '[AIAgentFrameworkSettings] No Custom Setting record found - using hardcoded default values for all settings');
            } else {
                // Record exists, fill in missing individual fields with FINAL defaults
                if (settings.DefaultMaxConversationTurns__c == null || settings.DefaultMaxConversationTurns__c < 0) {
                    settings.DefaultMaxConversationTurns__c = FINAL_DEFAULT_MaxConversationTurns;
                }
                if (settings.MaxQueueableStackDepth__c == null || settings.MaxQueueableStackDepth__c < 0) {
                    settings.MaxQueueableStackDepth__c = FINAL_DEFAULT_MaxQueueableStackDepth;
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
     * Gets whether PII Masking is enabled at the org level.
     * When enabled, sensitive data (PII) is automatically masked before being sent to external LLM providers.
     * Part of the PII Masking Trust Layer.
     *
     * @return True if PII masking is enabled org-wide.
     */
    public static Boolean isPIIMaskingEnabled() {
        return getInstance().EnablePIIMasking__c == true;
    }

    /**
     * Gets whether Prompt Safety is enabled at the org level.
     * When enabled, user messages are analyzed for jailbreak attempts and prompt injection attacks.
     * Part of the Prompt Safety Trust Layer.
     *
     * @return True if prompt safety is enabled org-wide.
     */
    public static Boolean isPromptSafetyEnabled() {
        return getInstance().EnablePromptSafety__c == true;
    }

    /**
     * Gets whether PII Audit Logging is enabled at the org level.
     * When enabled, PII masking events are logged to decision steps.
     * Logs only pattern types detected, never actual PII values.
     *
     * @return True if PII audit logging is enabled org-wide.
     */
    public static Boolean isPIIAuditLoggingEnabled() {
        return getInstance().PIIAuditLogging__c == true;
    }

    /**
     * Gets whether Prompt Safety Audit Logging is enabled at the org level.
     * When enabled, all prompt safety checks are logged to decision steps.
     *
     * @return True if prompt safety audit logging is enabled org-wide.
     */
    public static Boolean isPromptSafetyAuditLoggingEnabled() {
        return getInstance().PromptSafetyAuditLogging__c == true;
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
     * Clears the cached settings instance. Intended for use in test methods only.
     */
    @TestVisible
    private static void clearCache() {
        settings = null;
    }
}
