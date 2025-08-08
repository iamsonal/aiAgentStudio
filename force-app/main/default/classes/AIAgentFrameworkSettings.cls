/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Provides cached access to AIAgentFrameworkSettings__c Custom Settings.
 *              Handles default values if settings record or individual fields are missing.
 */
public inherited sharing class AIAgentFrameworkSettings {
    private static AIAgentFrameworkSettings__c settings;

    private static final Integer FINAL_DEFAULT_MaxConversationTurns = 5;
    private static final Integer FINAL_DEFAULT_HistoryLimit = 20;
    private static final Integer FINAL_DEFAULT_ContextTruncationLength = 1500;
    private static final Integer FINAL_DEFAULT_MaxRetryAttempts = 1;
    private static final Integer FINAL_DEFAULT_InitialRetryDelayMillis = 1000;
    private static final String FINAL_DEFAULT_RetryableHttpStatusCodes = '408,429,500,502,503,504';

    /** @description Gets the singleton instance of the settings, applying defaults for missing values. */
    public static AIAgentFrameworkSettings__c getInstance() {
        if (settings == null) {
            settings = AIAgentFrameworkSettings__c.getOrgDefaults();

            if (settings == null || settings.Id == null) {
                settings = new AIAgentFrameworkSettings__c();

                settings.DefaultMaxConversationTurns__c = FINAL_DEFAULT_MaxConversationTurns;
                settings.DefaultHistoryLimit__c = FINAL_DEFAULT_HistoryLimit;
                settings.DefaultContextTruncationLength__c = FINAL_DEFAULT_ContextTruncationLength;
                settings.DefaultMaxRetryAttempts__c = FINAL_DEFAULT_MaxRetryAttempts;
                settings.DefaultInitialRetryDelayMillis__c = FINAL_DEFAULT_InitialRetryDelayMillis;
                settings.DefaultRetryableHttpStatusCodes__c = FINAL_DEFAULT_RetryableHttpStatusCodes;
            } else {
                if (settings.DefaultMaxConversationTurns__c == null || settings.DefaultMaxConversationTurns__c < 0) {
                    settings.DefaultMaxConversationTurns__c = FINAL_DEFAULT_MaxConversationTurns;
                }
                if (settings.DefaultHistoryLimit__c == null || settings.DefaultHistoryLimit__c < 0) {
                    settings.DefaultHistoryLimit__c = FINAL_DEFAULT_HistoryLimit;
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
        }
        return settings;
    }

    /** @description Gets the configured default max conversation turns, falling back to internal default. */
    public static Integer getDefaultMaxConversationTurns() {
        return Integer.valueOf(getInstance().DefaultMaxConversationTurns__c);
    }

    /** @description Gets the configured default max history messages, falling back to internal default. */
    public static Integer getDefaultHistoryLimit() {
        return Integer.valueOf(getInstance().DefaultHistoryLimit__c);
    }

    /** @description Gets the configured default context truncation length, falling back to internal default. */
    public static Integer getDefaultContextTruncationLength() {
        return Integer.valueOf(getInstance().DefaultContextTruncationLength__c);
    }

    /** @description Gets the configured default max retry attempts, falling back to internal default. */
    public static Integer getDefaultMaxRetryAttempts() {
        return Integer.valueOf(getInstance().DefaultMaxRetryAttempts__c);
    }

    /** @description Gets the configured default initial retry delay (ms), falling back to internal default. */
    public static Integer getDefaultInitialRetryDelayMillis() {
        return Integer.valueOf(getInstance().DefaultInitialRetryDelayMillis__c);
    }

    /** @description Gets the configured default retryable HTTP status codes as a Set, falling back to internal default. */
    public static Set<Integer> getDefaultRetryableStatusCodes() {
        return parseRetryableCodes(getInstance().DefaultRetryableHttpStatusCodes__c);
    }

    /** Parses a comma-separated string of HTTP codes into a Set of Integers */
    public static Set<Integer> parseRetryableCodes(String codesString) {
        Set<Integer> codes = new Set<Integer>();

        String codesToParse = String.isNotBlank(codesString) ? codesString : FINAL_DEFAULT_RetryableHttpStatusCodes;

        if (String.isNotBlank(codesToParse)) {
            for (String codeStr : codesToParse.split(',')) {
                String trimmedCode = codeStr.trim();
                if (String.isNotBlank(trimmedCode)) {
                    try {
                        codes.add(Integer.valueOf(trimmedCode));
                    } catch (Exception e) {
                    }
                }
            }
        }
        return codes;
    }

    @TestVisible
    private static void clearCache() {
        settings = null;
    }
}
