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
 *   - Providing cached, read-optimized access to AIAgentDefinition__c, LLMConfiguration__c, and AgentCapability__c records
 *   - Supporting lookups by both Salesforce Record IDs and Developer Names (case-insensitive)
 *   - Implementing intelligent, testable caching strategies for optimal performance (eliminates SOQL per action execution)
 *   - Ensuring robust error handling with clear differentiation between 'not found' and 'system error'
 *   - Serving as the single source of truth for agent, LLM, and capability configuration retrieval
 *
 * This service is designed for extensibility, reliability, and operational transparency.
 */
public inherited sharing class AIAgentConfigService {
    public class ConfigurationException extends AIAgentException {
    }

    // Cache Keys: Use separate caches for ID and DeveloperName lookups
    private static Map<Id, AIAgentDefinition__c> agentDefIdCache = new Map<Id, AIAgentDefinition__c>();
    private static Map<String, AIAgentDefinition__c> agentDefNameCache = new Map<String, AIAgentDefinition__c>(); // Key: DeveloperName (lower case)

    private static Map<Id, LLMConfiguration__c> llmConfigIdCache = new Map<Id, LLMConfiguration__c>();
    private static Map<String, LLMConfiguration__c> llmConfigNameCache = new Map<String, LLMConfiguration__c>(); // Key: DeveloperName (lower case)

    // Cache for AgentCapability records by ID for schema-driven parameter processing
    private static Map<Id, AgentCapability__c> agentCapabilityIdCache = new Map<Id, AgentCapability__c>();

    // Cache for AgentCapability records by composite key (agentDefId + capabilityName) to prevent redundant queries
    private static Map<String, AgentCapability__c> agentCapabilityNameCache = new Map<String, AgentCapability__c>();

    // Common field lists for queries to ensure consistency
    private static final List<String> AGENT_DEFINITION_FIELDS = new List<String>{
        'Id',
        'Name',
        'DeveloperName__c',
        'LLMConfiguration__c',
        'IsActive__c',
        'AgentType__c',
        'MemoryStrategy__c',
        'ContextFormatStrategy__c',
        'Description__c',
        'HistoryTurnLimit__c',
        'SummarizationTriggerTurnCount__c',
        'SummarizationChunkTurnCount__c',
        'WelcomeMessageTemplate__c',
        'IdentityPrompt__c',
        'AuditLevel__c',
        'InstructionsPrompt__c',
        'ExamplesPrompt__c',
        'PromptFooter__c',
        'EnableParallelToolCalling__c',
        'EnableToolReasoning__c',
        'RequiresServiceUserContext__c',
        'AsyncDispatchType__c',
        'ErrorHandlingPolicy__c',
        'SummarizerAgent__c',
        'SummarizerAgent__r.DeveloperName__c',
        'SummarizerAgent__r.LLMConfiguration__c',
        'SummarizerAgent__r.InstructionsPrompt__c'
    };

    private static final List<String> LLM_CONFIGURATION_FIELDS = new List<String>{
        'Id',
        'Name',
        'DeveloperName__c',
        'ProviderAdapterClass__c',
        'NamedCredential__c',
        'DefaultModelIdentifier__c',
        'DefaultTemperature__c',
        'IsActive__c'
    };

    private static final List<String> AGENT_CAPABILITY_FIELDS = new List<String>{
        'Id',
        'CapabilityName__c',
        'Description__c',
        'Parameters__c', // Critical for schema-driven parameter processing
        'ImplementationType__c',
        'ImplementationDetail__c',
        'StandardActionType__c',
        'BackendConfiguration__c',
        'RunAsynchronously__c',
        'RequiresConfirmation__c',
        'RequiresApproval__c',
        'FailFastOnError__c',
        'ExposureLevel__c'
    };

    /**
     * Retrieves an AgentCapability__c record by its Salesforce Record ID with caching.
     * Optimized for schema-driven parameter processing in BaseAgentAction.
     *
     * @param capabilityId The ID of the AgentCapability__c record.
     * @return             The AgentCapability__c record.
     * @throws ConfigurationException if the ID is null, record not found, or record is inactive.
     * @throws ConfigurationException on query errors.
     */
    public static AgentCapability__c getCapabilityById(Id capabilityId) {
        String logPrefix = '[AIAgentCfgSvc] ';
        if (capabilityId == null) {
            throw new ConfigurationException('AgentCapability ID cannot be null.');
        }

        if (!agentCapabilityIdCache.containsKey(capabilityId)) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Cache MISS for Capability ID: ' + capabilityId + ' - querying database');

            try {
                String queryString = buildQuery('AgentCapability__c', AGENT_CAPABILITY_FIELDS, 'Id = :capabilityId');
                List<AgentCapability__c> results = Database.query(queryString);

                if (results.isEmpty()) {
                    throw new ConfigurationException('AgentCapability not found for ID: ' + capabilityId);
                }

                AgentCapability__c capability = results[0];
                agentCapabilityIdCache.put(capabilityId, capability);
                System.debug(LoggingLevel.DEBUG, logPrefix + 'Cached AgentCapability: ' + capability.CapabilityName__c);
                return capability;
            } catch (Exception e) {
                String errorMsg = 'System error querying AgentCapability by ID: ' + capabilityId;
                System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + ': ' + e.getMessage());
                throw new ConfigurationException(errorMsg, e); // Throw for system errors
            }
        } else {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Cache HIT for Capability ID: ' + capabilityId);
        }

        return agentCapabilityIdCache.get(capabilityId);
    }

    /**
     * Retrieves a complete, active AgentCapability__c record for a given agent definition and capability name.
     * Uses a composite cache key (agentDefId + capabilityName) to prevent redundant queries in the same transaction.
     *
     * @param agentDefId     The ID of the AIAgentDefinition__c.
     * @param capabilityName The CapabilityName__c of the AgentCapability__c record.
     * @return               The AgentCapability__c record.
     * @throws ConfigurationException if parameters are null/blank, record not found, or record is inactive.
     * @throws ConfigurationException on query errors.
     */
    public static AgentCapability__c getCapability(Id agentDefId, String capabilityName) {
        String logPrefix = '[AIAgentCfgSvc] ';
        if (agentDefId == null) {
            throw new ConfigurationException('Agent Definition ID cannot be null.');
        }
        if (String.isBlank(capabilityName)) {
            throw new ConfigurationException('Capability Name cannot be blank.');
        }

        // Create composite cache key: agentDefId + capabilityName
        String cacheKey = String.valueOf(agentDefId) + '::' + capabilityName.toLowerCase();

        // Check composite cache first
        if (agentCapabilityNameCache.containsKey(cacheKey)) {
            AgentCapability__c cachedCapability = agentCapabilityNameCache.get(cacheKey);
            if (cachedCapability == null) {
                throw new ConfigurationException('Active AgentCapability not found for Name: "' + capabilityName + '" on Agent: ' + agentDefId);
            }
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Cache HIT for capability "' + capabilityName + '" on Agent: ' + agentDefId);
            return cachedCapability;
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Cache MISS - Querying capability "' + capabilityName + '" for Agent: ' + agentDefId);

        try {
            String queryString = buildQuery(
                'AgentCapability__c',
                AGENT_CAPABILITY_FIELDS,
                'AIAgentDefinition__c = :agentDefId AND CapabilityName__c = :capabilityName AND ExposureLevel__c != \'Disabled\''
            );
            List<AgentCapability__c> capabilities = Database.query(queryString);

            if (capabilities.isEmpty()) {
                // Cache null result to prevent repeated queries for non-existent capabilities
                agentCapabilityNameCache.put(cacheKey, null);
                throw new ConfigurationException('Active AgentCapability not found for Name: "' + capabilityName + '" on Agent: ' + agentDefId);
            }

            AgentCapability__c capability = capabilities[0];

            // Cache the result in both caches
            agentCapabilityIdCache.put(capability.Id, capability);
            agentCapabilityNameCache.put(cacheKey, capability);

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Cached capability "' + capabilityName + '" for Agent: ' + agentDefId);
            return capability;
        } catch (Exception e) {
            String errorMsg = 'System error querying AgentCapability "' + capabilityName + '" on Agent ' + agentDefId;
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + ': ' + e.getMessage());
            throw new ConfigurationException(errorMsg, e);
        }
    }

    /**
     * Bulk retrieves multiple AgentCapability__c records by their names for a given agent definition.
     * Optimized for scenarios where multiple capabilities need to be looked up in a single transaction,
     * such as fail-fast policy checks after parallel tool execution.
     *
     * This method performs a single SOQL query for all requested capabilities, preventing N+1 query patterns
     * and governor limit issues when processing multiple tool results.
     *
     * @param agentDefId      The ID of the AIAgentDefinition__c.
     * @param capabilityNames Set of CapabilityName__c values to retrieve.
     * @return                Map of capability name (case-preserved) to AgentCapability__c record.
     *                        Missing capabilities are not included in the map (no null values).
     * @throws ConfigurationException if agentDefId is null or on query errors.
     */
    public static Map<String, AgentCapability__c> getCapabilitiesByNames(Id agentDefId, Set<String> capabilityNames) {
        String logPrefix = '[AIAgentCfgSvc] ';

        if (agentDefId == null) {
            throw new ConfigurationException('Agent Definition ID cannot be null.');
        }

        Map<String, AgentCapability__c> result = new Map<String, AgentCapability__c>();

        if (capabilityNames == null || capabilityNames.isEmpty()) {
            return result;
        }

        // Separate cached vs uncached capabilities
        Set<String> uncachedNames = new Set<String>();
        for (String capName : capabilityNames) {
            if (String.isBlank(capName)) {
                continue;
            }

            String cacheKey = String.valueOf(agentDefId) + '::' + capName.toLowerCase();
            if (agentCapabilityNameCache.containsKey(cacheKey)) {
                AgentCapability__c cached = agentCapabilityNameCache.get(cacheKey);
                if (cached != null) {
                    result.put(capName, cached);
                    System.debug(LoggingLevel.DEBUG, logPrefix + 'Bulk cache HIT for capability: ' + capName);
                }
                // If cached as null, capability doesn't exist - skip it
            } else {
                uncachedNames.add(capName);
            }
        }

        // Query for uncached capabilities in a single SOQL
        if (!uncachedNames.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Bulk querying ' + uncachedNames.size() + ' uncached capabilities for Agent: ' + agentDefId);

            try {
                String fieldList = String.join(AGENT_CAPABILITY_FIELDS, ', ');
                List<AgentCapability__c> capabilities = Database.query(
                    'SELECT ' +
                        fieldList +
                        ' FROM AgentCapability__c ' +
                        'WHERE AIAgentDefinition__c = :agentDefId ' +
                        'AND CapabilityName__c IN :uncachedNames ' +
                        'AND ExposureLevel__c != \'Disabled\''
                );

                // Cache and add to result
                Set<String> foundNames = new Set<String>();
                for (AgentCapability__c cap : capabilities) {
                    String cacheKey = String.valueOf(agentDefId) + '::' + cap.CapabilityName__c.toLowerCase();
                    agentCapabilityIdCache.put(cap.Id, cap);
                    agentCapabilityNameCache.put(cacheKey, cap);
                    result.put(cap.CapabilityName__c, cap);
                    foundNames.add(cap.CapabilityName__c.toLowerCase());
                }

                // Cache null for capabilities that weren't found to prevent future queries
                for (String capName : uncachedNames) {
                    if (!foundNames.contains(capName.toLowerCase())) {
                        String cacheKey = String.valueOf(agentDefId) + '::' + capName.toLowerCase();
                        agentCapabilityNameCache.put(cacheKey, null);
                        System.debug(LoggingLevel.DEBUG, logPrefix + 'Capability not found, cached as null: ' + capName);
                    }
                }

                System.debug(LoggingLevel.INFO, logPrefix + 'Bulk query returned ' + capabilities.size() + ' capabilities');
            } catch (Exception e) {
                String errorMsg = 'System error bulk querying AgentCapabilities on Agent ' + agentDefId;
                System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + ': ' + e.getMessage());
                throw new ConfigurationException(errorMsg, e);
            }
        }

        return result;
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
                } catch (ConfigurationException e) {
                    System.debug(LoggingLevel.WARN, 'Could not pre-warm LLM cache for linked LLM ID ' + agentDef.LLMConfiguration__c + ': ' + e.getMessage());
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
            String queryString = buildQuery('AIAgentDefinition__c', AGENT_DEFINITION_FIELDS, 'DeveloperName__c = :developerName AND IsActive__c = TRUE');

            List<AIAgentDefinition__c> results = Database.query(queryString);

            if (results.isEmpty()) {
                throw new ConfigurationException('Active AI Agent Definition not found for Developer Name: "' + developerName + '"');
            }
            if (results.size() > 1) {
                throw new ConfigurationException(
                    'CRITICAL CONFIG ERROR: Multiple active Agent Definitions found for Developer Name: "' +
                        developerName +
                        '". Ensure developer names are unique.'
                );
            }

            AIAgentDefinition__c agentDef = results[0];
            cacheAgentDefinition(agentDef); // Use helper to cache by ID and Name

            // Pre-warm LLM cache if not already cached
            if (agentDef.LLMConfiguration__c != null && !llmConfigIdCache.containsKey(agentDef.LLMConfiguration__c)) {
                try {
                    getLLMConfiguration(agentDef.LLMConfiguration__c);
                } catch (ConfigurationException e) {
                    System.debug(LoggingLevel.WARN, 'Could not pre-warm LLM cache for linked LLM ID ' + agentDef.LLMConfiguration__c + ': ' + e.getMessage());
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
     * Retrieves the active LLMConfiguration__c linked to a specific Agent Definition ID.
     * Uses cached lookups for both Agent Definition and LLM Configuration.
     *
     * @param agentDefId The ID of the AIAgentDefinition__c.
     * @return           The corresponding active LLMConfiguration__c record, or null if the lookup field is blank.
     * @throws ConfigurationException if the agent or LLM configuration is not found or inactive.
     * @throws ConfigurationException for unexpected query/system errors during lookup.
     */
    public static LLMConfiguration__c getLLMConfigurationByAgentDefinitionId(Id agentDefId) {
        if (agentDefId == null) {
            throw new ConfigurationException('Agent Definition ID cannot be null.');
        }

        // Get the Agent Definition - this will throw ConfigurationException if not found
        AIAgentDefinition__c agentDef = getAgentDefinition(agentDefId);

        // Check if the LLM Configuration lookup field is blank
        Id llmConfigId = agentDef.LLMConfiguration__c;
        if (llmConfigId == null) {
            System.debug(
                LoggingLevel.WARN,
                '[AIAgentConfigService.getLLMConfigByAgentId] Agent Definition ' + agentDefId + ' has no LLM Configuration linked.'
            );
            return null; // Return null only if the lookup field is blank
        }

        // Get the LLM Configuration - this will throw ConfigurationException if not found
        return getLLMConfiguration(llmConfigId);
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
}
