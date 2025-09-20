/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIAgentFrameworkSettings is the centralized configuration management service for the AI Agent Framework.
 * Responsibilities:
 *   - Provides cached, read-optimized access to AIAgentFrameworkSettings__c custom settings
 *   - Implements intelligent fallback to hardcoded defaults when settings are missing or invalid
 *   - Ensures framework stability and predictable behavior regardless of configuration state
 *   - Surfaces configuration issues clearly via debug output for maintainability
 *
 * This class is not intended to be instantiated or extended.
 */
public inherited sharing class AIAgentFrameworkSettings {
    private static AIAgentFrameworkSettings__c settings;

    // Define hardcoded final defaults directly here. Names reflect settings field names.
    private static final Integer FINAL_DEFAULT_MaxConversationTurns = 5;
    private static final Integer FINAL_DEFAULT_HistoryLimit = 20;
    private static final Integer FINAL_DEFAULT_ContextTruncationLength = 1500;
    private static final Integer FINAL_DEFAULT_MaxRetryAttempts = 1;
    private static final Integer FINAL_DEFAULT_InitialRetryDelayMillis = 1000;
    private static final String FINAL_DEFAULT_RetryableHttpStatusCodes = '408,429,500,502,503,504';

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
                settings.DefaultHistoryTurnLimit__c = FINAL_DEFAULT_HistoryLimit;
                settings.DefaultContextTruncationLength__c = FINAL_DEFAULT_ContextTruncationLength;
                settings.DefaultMaxRetryAttempts__c = FINAL_DEFAULT_MaxRetryAttempts;
                settings.DefaultInitialRetryDelayMillis__c = FINAL_DEFAULT_InitialRetryDelayMillis;
                settings.DefaultRetryableHttpStatusCodes__c = FINAL_DEFAULT_RetryableHttpStatusCodes;
                System.debug(
                    LoggingLevel.WARN,
                    '[AIAgentFrameworkSettings] No Custom Setting record found - using hardcoded default values for all settings'
                );
            } else {
                // Record exists, fill in missing individual fields with FINAL defaults
                if (settings.DefaultMaxConversationTurns__c == null || settings.DefaultMaxConversationTurns__c < 0) {
                    settings.DefaultMaxConversationTurns__c = FINAL_DEFAULT_MaxConversationTurns;
                }
                if (settings.DefaultHistoryTurnLimit__c == null || settings.DefaultHistoryTurnLimit__c < 0) {
                    settings.DefaultHistoryTurnLimit__c = FINAL_DEFAULT_HistoryLimit;
                }
                if (settings.DefaultContextTruncationLength__c == null || settings.DefaultContextTruncationLength__c <= 0) {
                    settings.DefaultContextTruncationLength__c = FINAL_DEFAULT_ContextTruncationLength;
                }
                if (settings.DefaultMaxRetryAttempts__c == null || settings.DefaultMaxRetryAttempts__c < 0) {
                    settings.DefaultMaxRetryAttempts__c = FINAL_DEFAULT_MaxRetryAttempts;
                }
                if (settings.DefaultInitialRetryDelayMillis__c == null || settings.DefaultInitialRetryDelayMillis__c <= 0) {
                    settings.DefaultInitialRetryDelayMillis__c = FINAL_DEFAULT_InitialRetryDelayMillis;
                }
                if (String.isBlank(settings.DefaultRetryableHttpStatusCodes__c)) {
                    settings.DefaultRetryableHttpStatusCodes__c = FINAL_DEFAULT_RetryableHttpStatusCodes;
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
     * Gets the configured default max history messages, falling back to the internal default if not set.
     *
     * @return The default maximum number of history messages.
     */
    public static Integer getDefaultHistoryLimit() {
        return Integer.valueOf(getInstance().DefaultHistoryTurnLimit__c);
    }

    /**
     * Gets the configured default context truncation length, falling back to the internal default if not set.
     *
     * @return The default context truncation length (in characters).
     */
    public static Integer getDefaultContextTruncationLength() {
        return Integer.valueOf(getInstance().DefaultContextTruncationLength__c);
    }

    /**
     * Gets the configured default max retry attempts, falling back to the internal default if not set.
     *
     * @return The default maximum number of retry attempts.
     */
    public static Integer getDefaultMaxRetryAttempts() {
        return Integer.valueOf(getInstance().DefaultMaxRetryAttempts__c);
    }

    /**
     * Gets the configured default initial retry delay (in milliseconds), falling back to the internal default if not set.
     *
     * @return The default initial retry delay in milliseconds.
     */
    public static Integer getDefaultInitialRetryDelayMillis() {
        return Integer.valueOf(getInstance().DefaultInitialRetryDelayMillis__c);
    }

    /**
     * Gets the configured default retryable HTTP status codes as a Set<Integer>, falling back to the internal default if not set.
     *
     * @return The set of default retryable HTTP status codes.
     */
    public static Set<Integer> getDefaultRetryableStatusCodes() {
        return parseRetryableCodes(getInstance().DefaultRetryableHttpStatusCodes__c);
    }

    /**
     * Parses a comma-separated string of HTTP status codes into a Set<Integer>.
     *
     * @param codesString The comma-separated string of HTTP status codes.
     * @return            The set of parsed HTTP status codes (never null).
     */
    public static Set<Integer> parseRetryableCodes(String codesString) {
        Set<Integer> codes = new Set<Integer>();
        // Use final default if input is blank
        String codesToParse = String.isNotBlank(codesString) ? codesString : FINAL_DEFAULT_RetryableHttpStatusCodes;

        if (String.isNotBlank(codesToParse)) {
            for (String codeStr : codesToParse.split(',')) {
                String trimmedCode = codeStr.trim();
                if (String.isNotBlank(trimmedCode)) {
                    try {
                        codes.add(Integer.valueOf(trimmedCode));
                    } catch (Exception e) {
                        System.debug(
                            LoggingLevel.WARN,
                            '[AIAgentFrameworkSettings] Invalid HTTP status code in configuration, skipping: ' + trimmedCode
                        );
                    }
                }
            }
        }
        return codes;
    }

    /**
     * Clears the cached settings instance. Intended for use in test methods only.
     */
    @TestVisible
    private static void clearCache() {
        settings = null;
    }
}
