/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIAgentConfigService is the central, high-performance configuration service for the AI Agent Framework.
 * Responsibilities include:
 *   - Providing cached, read-optimized access to AIAgentDefinition__c and LLMConfiguration__c records
 *   - Supporting lookups by both Salesforce Record IDs and Developer Names (case-insensitive)
 *   - Implementing intelligent, testable caching strategies for optimal performance
 *   - Ensuring robust error handling and clear debug output for maintainability
 *   - Serving as the single source of truth for agent and LLM configuration retrieval
 *
 * This service is designed for extensibility, reliability, and operational transparency.
 */
public inherited sharing class AIAgentConfigService {
    // Cache Keys: Use separate caches for ID and DeveloperName lookups
    private static Map<Id, AIAgentDefinition__c> agentDefIdCache = new Map<Id, AIAgentDefinition__c>();
    private static Map<String, AIAgentDefinition__c> agentDefNameCache = new Map<String, AIAgentDefinition__c>(); // Key: DeveloperName (lower case)

    private static Map<Id, LLMConfiguration__c> llmConfigIdCache = new Map<Id, LLMConfiguration__c>();
    private static Map<String, LLMConfiguration__c> llmConfigNameCache = new Map<String, LLMConfiguration__c>(); // Key: DeveloperName (lower case)

    // Common field lists for queries to ensure consistency
    private static final List<String> AGENT_DEFINITION_FIELDS = new List<String>{
        'Id',
        'Name',
        'DeveloperName__c', // Key fields
        'LLMConfiguration__c',
        'IsActive__c',
        'MemoryStrategy__c',
        'ContextFormatStrategy__c',
        'Description__c',
        'HistoryLimit__c',
        'SummarizationTriggerSize__c',
        'SummarizationChunkSize__c',
        'WelcomeMessageTemplate__c',
        'IdentityPrompt__c',
        'InstructionsPrompt__c',
        'ExamplesPrompt__c',
        'PromptFooter__c',
        'EnableReasoningMode__c',
        'RequiresServiceUserContext__c'
    };

    private static final List<String> LLM_CONFIGURATION_FIELDS = new List<String>{
        'Id',
        'Name',
        'DeveloperName__c', // Key fields
        'ProviderAdapterClass__c',
        'NamedCredential__c',
        'DefaultModelIdentifier__c',
        'DefaultTemperature__c',
        'IsActive__c',
        'MaxRetryAttempts__c',
        'InitialRetryDelayMillis__c',
        'RetryableHttpStatusCodes__c'
        // Add other fields like MaxContextTokens__c, Retry settings if added
    };

    /**
     * Retrieves a complete, active AgentCapability__c record for a given agent definition and capability name.
     *
     * @param agentDefId     The ID of the AIAgentDefinition__c.
     * @param capabilityName The CapabilityName__c of the AgentCapability__c record.
     * @return               The AgentCapability__c record, or null if not found or inactive.
     * @throws ConfigurationException on query errors (not for 'not found').
     */
    public static AgentCapability__c getCapability(Id agentDefId, String capabilityName) {
        String logPrefix = '[AIAgentCfgSvc] ';
        if (agentDefId == null || String.isBlank(capabilityName)) {
            System.debug(LoggingLevel.WARN, logPrefix + 'getCapability: agentDefId or capabilityName is null/blank.');
            return null;
        }

        // Start without cache for capabilities, as they are less frequently accessed than agent defs.
        // Can be added later if performance profiling shows a need.
        System.debug(LoggingLevel.INFO, logPrefix + 'Querying capability "' + capabilityName + '" for Agent: ' + agentDefId);

        try {
            List<AgentCapability__c> capabilities = [
                SELECT
                    Id,
                    CapabilityName__c,
                    Description__c,
                    Parameters__c,
                    ImplementationType__c,
                    ImplementationDetail__c,
                    StandardActionType__c,
                    BackendConfiguration__c,
                    RunAsynchronously__c,
                    RequiresConfirmation__c,
                    RequiresApproval__c,
                    HaltAndReportError__c
                FROM AgentCapability__c
                WHERE AIAgentDefinition__c = :agentDefId AND CapabilityName__c = :capabilityName AND ExposureLevel__c != 'Disabled'
                LIMIT 1
            ];

            if (capabilities.isEmpty()) {
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix + 'No active AgentCapability found for Name: "' + capabilityName + '" on Agent: ' + agentDefId
                );
                return null;
            }
            return capabilities[0];
        } catch (Exception e) {
            String errorMsg = 'Error querying AgentCapability "' + capabilityName + '" on Agent ' + agentDefId;
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + ': ' + e.getMessage());
            throw new ConfigurationException(errorMsg, e);
        }
    }

    /**
     * Retrieves an active AIAgentDefinition__c by its Salesforce Record ID.
     * Ensures required related fields are queried and caches the result for future lookups.
     *
     * @param agentDefId The 18-character Salesforce ID of the AIAgentDefinition__c record.
     * @return           The corresponding AIAgentDefinition__c record.
     * @throws ConfigurationException if the ID is null, record not found, or record is not active.
     */
    public static AIAgentDefinition__c getAgentDefinition(Id agentDefId) {
        if (agentDefId == null) {
            throw new ConfigurationException('Agent Definition ID cannot be null.');
        }

        if (!agentDefIdCache.containsKey(agentDefId)) {
            System.debug(LoggingLevel.INFO, '[AIAgentConfigService] Cache MISS for Agent ID: ' + agentDefId + ' - querying database');

            String queryString = buildQuery('AIAgentDefinition__c', AGENT_DEFINITION_FIELDS, 'Id = :agentDefId AND IsActive__c = TRUE');

            List<AIAgentDefinition__c> results = Database.query(queryString);

            if (results.isEmpty()) {
                throw new ConfigurationException('Active AI Agent Definition not found for ID: ' + agentDefId);
            }

            AIAgentDefinition__c agentDef = results[0];
            cacheAgentDefinition(agentDef); // Use helper to cache by ID and Name

            // Pre-warm LLM cache if not already cached
            if (agentDef.LLMConfiguration__c != null && !llmConfigIdCache.containsKey(agentDef.LLMConfiguration__c)) {
                try {
                    getLLMConfiguration(agentDef.LLMConfiguration__c);
                } // Load/Cache LLM config
                catch (ConfigurationException e) {
                    System.debug(
                        LoggingLevel.WARN,
                        'Could not pre-warm LLM cache for linked LLM ID ' + agentDef.LLMConfiguration__c + ': ' + e.getMessage()
                    );
                }
            }
        } else {
            System.debug(LoggingLevel.DEBUG, '[AIAgentConfigService] Cache HIT for Agent ID: ' + agentDefId);
        }
        return agentDefIdCache.get(agentDefId);
    }

    /**
     * Retrieves an active AIAgentDefinition__c by its unique Developer Name (case-insensitive).
     * Ensures required related fields are queried and caches the result for future lookups.
     *
     * @param developerName The DeveloperName__c of the AIAgentDefinition__c record.
     * @return              The corresponding AIAgentDefinition__c record.
     * @throws ConfigurationException if the name is blank, record not found, or record is not active.
     */
    public static AIAgentDefinition__c getAgentDefinitionByDeveloperName(String developerName) {
        if (String.isBlank(developerName)) {
            throw new ConfigurationException('Agent Definition Developer Name cannot be blank.');
        }
        String cacheKey = developerName.toLowerCase();

        if (!agentDefNameCache.containsKey(cacheKey)) {
            System.debug(LoggingLevel.INFO, '[AIAgentConfigService] Cache MISS for Agent Name: ' + developerName + ' - querying database');

            // Ensure DeveloperName field exists and is filterable/indexed for performance
            String queryString = buildQuery(
                'AIAgentDefinition__c',
                AGENT_DEFINITION_FIELDS,
                'DeveloperName__c = :developerName AND IsActive__c = TRUE'
            );

            List<AIAgentDefinition__c> results = Database.query(queryString);

            if (results.isEmpty()) {
                throw new ConfigurationException('Active AI Agent Definition not found for Developer Name: "' + developerName + '"');
            }
            if (results.size() > 1) {
                // Should not happen if DeveloperName is unique
                System.debug(
                    LoggingLevel.ERROR,
                    'CRITICAL CONFIG WARNING: Multiple active Agent Definitions found for Developer Name: "' +
                        developerName +
                        '". Using the first one found.'
                );
                // Consider throwing an exception here instead for stricter enforcement.
            }

            AIAgentDefinition__c agentDef = results[0];
            cacheAgentDefinition(agentDef); // Use helper to cache by ID and Name

            // Pre-warm LLM cache if not already cached
            if (agentDef.LLMConfiguration__c != null && !llmConfigIdCache.containsKey(agentDef.LLMConfiguration__c)) {
                try {
                    getLLMConfiguration(agentDef.LLMConfiguration__c);
                } catch (ConfigurationException e) {
                    System.debug(
                        LoggingLevel.WARN,
                        'Could not pre-warm LLM cache for linked LLM ID ' + agentDef.LLMConfiguration__c + ': ' + e.getMessage()
                    );
                }
            }
        } else {
            System.debug(LoggingLevel.DEBUG, '[AIAgentConfigService] Cache HIT for Agent Name: ' + developerName);
        }
        return agentDefNameCache.get(cacheKey);
    }

    /**
     * Retrieves an active LLMConfiguration__c by its Salesforce Record ID.
     * Queries consistent fields and caches the result for future lookups.
     *
     * @param llmConfigId The 18-character Salesforce ID of the LLMConfiguration__c record.
     * @return            The corresponding LLMConfiguration__c record.
     * @throws ConfigurationException if the ID is null, record not found, or record is not active.
     */
    public static LLMConfiguration__c getLLMConfiguration(Id llmConfigId) {
        if (llmConfigId == null) {
            throw new ConfigurationException('LLM Configuration ID cannot be null.');
        }

        if (!llmConfigIdCache.containsKey(llmConfigId)) {
            System.debug(LoggingLevel.INFO, '[AIAgentConfigService] Cache MISS for LLM ID: ' + llmConfigId + ' - querying database');

            String queryString = buildQuery('LLMConfiguration__c', LLM_CONFIGURATION_FIELDS, 'Id = :llmConfigId AND IsActive__c = TRUE');
            List<LLMConfiguration__c> results = Database.query(queryString);

            if (results.isEmpty()) {
                throw new ConfigurationException('Active LLM Configuration not found for ID: ' + llmConfigId);
            }
            cacheLLMConfiguration(results[0]); // Use helper
        } else {
            System.debug(LoggingLevel.DEBUG, '[AIAgentConfigService] Cache HIT for LLM ID: ' + llmConfigId);
        }
        return llmConfigIdCache.get(llmConfigId);
    }

    /**
     * Retrieves an active LLMConfiguration__c by its unique Developer Name (case-insensitive).
     * Queries consistent fields and caches the result for future lookups.
     *
     * @param developerName The DeveloperName__c of the LLMConfiguration__c record.
     * @return              The corresponding LLMConfiguration__c record.
     * @throws ConfigurationException if the name is blank, record not found, or record is not active.
     */
    public static LLMConfiguration__c getLLMConfigurationByDeveloperName(String developerName) {
        if (String.isBlank(developerName)) {
            throw new ConfigurationException('LLM Configuration Developer Name cannot be blank.');
        }
        String cacheKey = developerName.toLowerCase();

        if (!llmConfigNameCache.containsKey(cacheKey)) {
            System.debug(LoggingLevel.INFO, '[AIAgentConfigService] Cache MISS for LLM Name: ' + developerName + ' - querying database');

            String queryString = buildQuery(
                'LLMConfiguration__c',
                LLM_CONFIGURATION_FIELDS,
                'DeveloperName__c = :developerName AND IsActive__c = TRUE'
            );
            List<LLMConfiguration__c> results = Database.query(queryString);

            if (results.isEmpty()) {
                throw new ConfigurationException('Active LLM Configuration not found for Developer Name: "' + developerName + '"');
            }
            if (results.size() > 1) {
                System.debug(
                    LoggingLevel.ERROR,
                    'CRITICAL CONFIG WARNING: Multiple active LLM Configurations found for Developer Name: "' +
                        developerName +
                        '". Using the first one found.'
                );
            }
            cacheLLMConfiguration(results[0]); // Use helper
        } else {
            System.debug(LoggingLevel.DEBUG, '[AIAgentConfigService] Cache HIT for LLM Name: ' + developerName);
        }
        return llmConfigNameCache.get(cacheKey);
    }

    /**
     * Retrieves the active LLMConfiguration__c linked to a specific Agent Definition ID.
     * Uses cached lookups for both Agent Definition and LLM Configuration.
     *
     * @param agentDefId The ID of the AIAgentDefinition__c.
     * @return           The corresponding active LLMConfiguration__c record, or null if Agent/LLM not found, inactive, or link missing.
     * @throws ConfigurationException only for unexpected query/system errors during lookup, not for 'not found'.
     */
    public static LLMConfiguration__c getLLMConfigurationByAgentDefinitionId(Id agentDefId) {
        if (agentDefId == null) {
            System.debug(LoggingLevel.WARN, '[AIAgentConfigService.getLLMConfigByAgentId] Agent Definition ID is null.');
            return null;
        }

        AIAgentDefinition__c agentDef = null;
        try {
            // Use the existing cached method to get the Agent Definition
            agentDef = getAgentDefinition(agentDefId); // This handles caching and throws if *query* fails

            // If agentDef is null (e.g., not found/inactive), getAgentDefinition should handle logging/exceptions based on its implementation
            // However, defensively check again. If getAgentDefinition throws for 'not found', it will be caught below.
            if (agentDef == null) {
                System.debug(
                    LoggingLevel.WARN,
                    '[AIAgentConfigService.getLLMConfigByAgentId] Agent Definition not found or inactive for ID: ' + agentDefId
                );
                return null; // Return null explicitly if getAgentDefinition doesn't throw for 'not found'
            }
        } catch (AIAgentConfigService.ConfigurationException configEx) {
            // Catch if getAgentDefinition *throws* for 'not found' or other errors
            System.debug(
                LoggingLevel.ERROR,
                '[AIAgentConfigService.getLLMConfigByAgentId] Error retrieving Agent Definition ' + agentDefId + ': ' + configEx.getMessage()
            );
            return null; // Return null if agent lookup failed critically
        } catch (Exception e) {
            // Catch unexpected system errors during agent lookup
            System.debug(
                LoggingLevel.ERROR,
                '[AIAgentConfigService.getLLMConfigByAgentId] Unexpected error retrieving Agent Definition ' + agentDefId + ': ' + e.getMessage()
            );
            throw new ConfigurationException('System error during Agent lookup: ' + e.getMessage(), e); // Re-throw unexpected errors
        }

        // Agent Definition was found, now get the linked LLM Config ID
        Id llmConfigId = agentDef.LLMConfiguration__c;
        if (llmConfigId == null) {
            System.debug(
                LoggingLevel.ERROR,
                '[AIAgentConfigService.getLLMConfigByAgentId] Agent Definition ' + agentDefId + ' has no LLM Configuration linked.'
            );
            return null; // Link is missing
        }

        LLMConfiguration__c llmConfig = null;
        try {
            // Use the existing cached method to get the actual LLM Configuration record
            llmConfig = getLLMConfiguration(llmConfigId); // Handles caching and checks for active/found

            // If llmConfig is null (e.g., LLM not found or inactive), getLLMConfiguration should handle logging/exceptions
            // If getLLMConfiguration throws for 'not found', it will be caught below. Return null if it doesn't throw.
            if (llmConfig == null) {
                System.debug(
                    LoggingLevel.ERROR,
                    '[AIAgentConfigService.getLLMConfigByAgentId] Linked LLM Configuration ' +
                        llmConfigId +
                        ' not found or inactive for Agent ' +
                        agentDefId
                );
                return null;
            }
        } catch (AIAgentConfigService.ConfigurationException configEx) {
            // Catch if getLLMConfiguration *throws* for 'not found' or other errors
            System.debug(
                LoggingLevel.ERROR,
                '[AIAgentConfigService.getLLMConfigByAgentId] Error retrieving linked LLM Configuration ' + llmConfigId + ': ' + configEx.getMessage()
            );
            return null; // Return null if LLM lookup failed critically
        } catch (Exception e) {
            // Catch unexpected system errors during LLM lookup
            System.debug(
                LoggingLevel.ERROR,
                '[AIAgentConfigService.getLLMConfigByAgentId] Unexpected error retrieving LLM Configuration ' + llmConfigId + ': ' + e.getMessage()
            );
            throw new ConfigurationException('System error during LLM lookup: ' + e.getMessage(), e); // Re-throw unexpected errors
        }

        return llmConfig; // Return the successfully found, active LLM configuration
    }

    // --- Helper Methods ---

    /**
     * Helper to build a SOQL query string for a given object, field list, and where clause.
     *
     * @param objectApiName The API name of the SObject.
     * @param fields        The list of fields to select.
     * @param whereClause   The SOQL WHERE clause.
     * @return              The complete SOQL query string.
     */
    private static String buildQuery(String objectApiName, List<String> fields, String whereClause) {
        return 'SELECT ' + String.join(fields, ', ') + ' FROM ' + objectApiName + ' WHERE ' + whereClause + ' LIMIT 1';
    }

    /**
     * Helper to cache an Agent Definition by both ID and Developer Name (lowercase).
     *
     * @param agentDef The AIAgentDefinition__c record to cache.
     */
    private static void cacheAgentDefinition(AIAgentDefinition__c agentDef) {
        if (agentDef?.Id == null)
            return;
        agentDefIdCache.put(agentDef.Id, agentDef);
        if (String.isNotBlank(agentDef.DeveloperName__c)) {
            agentDefNameCache.put(agentDef.DeveloperName__c.toLowerCase(), agentDef);
        }
    }

    /**
     * Helper to cache an LLM Configuration by both ID and Developer Name (lowercase).
     *
     * @param llmConfig The LLMConfiguration__c record to cache.
     */
    private static void cacheLLMConfiguration(LLMConfiguration__c llmConfig) {
        if (llmConfig?.Id == null)
            return;
        llmConfigIdCache.put(llmConfig.Id, llmConfig);
        if (String.isNotBlank(llmConfig.DeveloperName__c)) {
            llmConfigNameCache.put(llmConfig.DeveloperName__c.toLowerCase(), llmConfig);
        }
    }

    /**
     * Clears all configuration caches. Intended for use in test methods only.
     */
    @TestVisible
    private static void clearCache() {
        agentDefIdCache.clear();
        agentDefNameCache.clear();
        llmConfigIdCache.clear();
        llmConfigNameCache.clear();
        System.debug(LoggingLevel.INFO, '[AIAgentConfigService] All caches cleared for testing purposes');
    }

    /**
     * Exception for configuration errors (e.g., not found, inactive, or query/system errors).
     */
    public class ConfigurationException extends AIAgentException {
    }
}
