/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/** @description Provides cached access to AIAgentFrameworkSettings__c */
public inherited sharing class AIAgentFrameworkSettings {
    private static AIAgentFrameworkSettings__c settings;
    private static final Integer FINAL_DEFAULT_MAX_CONVERSATION_TURNS = 5;
    private static final Integer FINAL_DEFAULT_HISTORY_LIMIT = 20;
    private static final Integer FINAL_DEFAULT_CONTEXT_TRUNCATION_LENGTH = 1500;
    private static final Integer FINAL_DEFAULT_MAX_RETRY_ATTEMPTS = 1;
    private static final Integer FINAL_DEFAULT_INITIAL_RETRY_DELAY = 1000;
    private static final String FINAL_DEFAULT_RETRYABLE_STATUS_CODES = '408,429,500,502,503,504';

    /** @description Gets the singleton instance of the settings. */
    public static AIAgentFrameworkSettings__c getInstance() {
        if (settings == null) {
            settings = AIAgentFrameworkSettings__c.getOrgDefaults();

            if (settings == null || settings.Id == null) {
                settings = new AIAgentFrameworkSettings__c(
                    DefaultMaxConversationTurns__c = FINAL_DEFAULT_MAX_CONVERSATION_TURNS,
                    DefaultMaxRetryAttempts__c = FINAL_DEFAULT_MAX_RETRY_ATTEMPTS,
                    DefaultInitialRetryDelayMillis__c = FINAL_DEFAULT_INITIAL_RETRY_DELAY,
                    DefaultRetryableHttpStatusCodes__c = FINAL_DEFAULT_RETRYABLE_STATUS_CODES,
                    DefaultContextTruncationLength__c = FINAL_DEFAULT_CONTEXT_TRUNCATION_LENGTH,
                    DefaultHistoryLimit__c = FINAL_DEFAULT_HISTORY_LIMIT
                );
            }

            settings.DefaultMaxConversationTurns__c = settings.DefaultMaxConversationTurns__c != null
                ? settings.DefaultMaxConversationTurns__c
                : FINAL_DEFAULT_MAX_CONVERSATION_TURNS;
            settings.DefaultMaxRetryAttempts__c = settings.DefaultMaxRetryAttempts__c != null
                ? settings.DefaultMaxRetryAttempts__c
                : FINAL_DEFAULT_MAX_RETRY_ATTEMPTS;
            settings.DefaultInitialRetryDelayMillis__c = settings.DefaultInitialRetryDelayMillis__c != null
                ? settings.DefaultInitialRetryDelayMillis__c
                : FINAL_DEFAULT_INITIAL_RETRY_DELAY;
            settings.DefaultRetryableHttpStatusCodes__c = String.isNotBlank(settings.DefaultRetryableHttpStatusCodes__c)
                ? settings.DefaultRetryableHttpStatusCodes__c
                : FINAL_DEFAULT_RETRYABLE_STATUS_CODES;
            settings.DefaultContextTruncationLength__c = settings.DefaultContextTruncationLength__c != null
                ? settings.DefaultContextTruncationLength__c
                : FINAL_DEFAULT_CONTEXT_TRUNCATION_LENGTH;
            settings.DefaultHistoryLimit__c = settings.DefaultHistoryLimit__c != null
                ? settings.DefaultHistoryLimit__c
                : FINAL_DEFAULT_HISTORY_LIMIT;
        }
        return settings;
    }

    /** @description Gets the configured default max turns, falling back to default. */
    /** @description Gets the configured default max turns, falling back to internal default. */
    public static Integer getDefaultMaxConversationTurns() {
        return Integer.valueOf(getInstance().DefaultMaxConversationTurns__c);
    }

    /** @description Gets the configured default max retries, falling back to default. */
    public static Integer getDefaultMaxRetryAttempts() {
        AIAgentFrameworkSettings__c s = getInstance();
        return (s.DefaultMaxRetryAttempts__c != null &&
            s.DefaultMaxRetryAttempts__c >= 0)
            ? Integer.valueOf(s.DefaultMaxRetryAttempts__c)
            : FINAL_DEFAULT_MAX_RETRY_ATTEMPTS;
    }

    /** @description Gets the configured default initial retry delay, falling back to default. */
    public static Integer getDefaultInitialRetryDelayMillis() {
        AIAgentFrameworkSettings__c s = getInstance();
        return (s.DefaultInitialRetryDelayMillis__c != null &&
            s.DefaultInitialRetryDelayMillis__c > 0)
            ? Integer.valueOf(s.DefaultInitialRetryDelayMillis__c)
            : FINAL_DEFAULT_INITIAL_RETRY_DELAY;
    }

    /** @description Gets the configured default retryable codes, falling back to default. Returns a Set.*/
    public static Set<Integer> getDefaultRetryableStatusCodes() {
        AIAgentFrameworkSettings__c s = getInstance();
        String codesString = String.isNotBlank(s.DefaultRetryableHttpStatusCodes__c)
            ? s.DefaultRetryableHttpStatusCodes__c
            : FINAL_DEFAULT_RETRYABLE_STATUS_CODES;
        return parseRetryableCodes(codesString);
    }

    public static Set<Integer> parseRetryableCodes(String codesString) {
        Set<Integer> codes = new Set<Integer>();
        if (String.isNotBlank(codesString)) {
            for (String codeStr : codesString.split(',')) {
                codeStr = codeStr.trim();
                if (String.isNotBlank(codeStr)) {
                    try {
                        codes.add(Integer.valueOf(codeStr));
                    } catch (Exception e) {
                    }
                }
            }
        }
        return codes;
    }

    /** @description Gets the configured default history message limit, falling back to internal default. */
    public static Integer getDefaultHistoryLimit() {
        AIAgentFrameworkSettings__c s = getInstance();

        return Integer.valueOf(s.DefaultHistoryLimit__c);
    }

    /** @description Gets the configured default context truncation length, falling back to internal default. */
    public static Integer getDefaultContextTruncationLength() {
        AIAgentFrameworkSettings__c s = getInstance();

        return Integer.valueOf(s.DefaultContextTruncationLength__c);
    }

    @TestVisible
    private static void clearCache() {
        settings = null;
    }
}
