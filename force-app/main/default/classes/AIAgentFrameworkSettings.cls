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
                System.debug(
                    LoggingLevel.WARN,
                    '[AIAgentFrameworkSettings] No Custom Setting record found - using hardcoded default values for all settings'
                );
            } else {
                // Record exists, fill in missing individual fields with FINAL defaults
                if (settings.DefaultMaxConversationTurns__c == null || settings.DefaultMaxConversationTurns__c < 0) {
                    settings.DefaultMaxConversationTurns__c = FINAL_DEFAULT_MaxConversationTurns;
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
     * Clears the cached settings instance. Intended for use in test methods only.
     */
    @TestVisible
    private static void clearCache() {
        settings = null;
    }
}
