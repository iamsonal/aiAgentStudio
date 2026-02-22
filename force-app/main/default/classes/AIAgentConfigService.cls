/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Central configuration service providing cached access to AIAgentDefinition__c, LLMConfiguration__c, and AgentCapability__c records.
 */
public inherited sharing class AIAgentConfigService {
    public class ConfigurationException extends AIAgentException {
    }

    private static Map<Id, AIAgentDefinition__c> agentDefIdCache = new Map<Id, AIAgentDefinition__c>();
    private static Map<String, AIAgentDefinition__c> agentDefNameCache = new Map<String, AIAgentDefinition__c>();
    private static Map<Id, LLMConfiguration__c> llmConfigIdCache = new Map<Id, LLMConfiguration__c>();
    private static Map<String, LLMConfiguration__c> llmConfigNameCache = new Map<String, LLMConfiguration__c>();
    private static Map<Id, AgentCapability__c> agentCapabilityIdCache = new Map<Id, AgentCapability__c>();
    private static Map<String, AgentCapability__c> agentCapabilityNameCache = new Map<String, AgentCapability__c>();

    // LLM Model Pricing Cache
    private static Map<String, LLMModelPricing__mdt> pricingCache;
    private static Boolean isPricingCacheInitialized = false;

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
        'ServiceUserNamedCredential__c',
        'EnableDependencyValidation__c',
        'ToolDependencyGraph__c',
        'ToolDependencyGraphWarnings__c',
        'AsyncDispatchType__c',
        'SummarizerAgent__c',
        'EnableNextStepSuggestion__c',
        'MaxProcessingCycles__c',
        'SummarizerAgent__r.DeveloperName__c',
        'SummarizerAgent__r.LLMConfiguration__c',
        'SummarizerAgent__r.InstructionsPrompt__c',
        // Trust Layer presets (simplified configuration)
        'PIIMaskingPreset__c',
        'PromptSafetyPreset__c',
        // Error handling
        'ErrorRecoveryMode__c'
    };

    private static final List<String> LLM_CONFIGURATION_FIELDS = new List<String>{
        'Id',
        'Name',
        'DeveloperName__c',
        'ProviderAdapterClass__c',
        'NamedCredential__c',
        'DefaultModelIdentifier__c',
        'DefaultTemperature__c',
        'ApiVersion__c',
        'MaxResponseTokens__c',
        'TimeoutMs__c',
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
        'HITLMode__c', // Unified HITL mode field (blank=no HITL, Confirmation, Approval, ConfirmationThenApproval)
        'HITLNotificationPreference__c', // Controls when to send notifications for HITL actions
        'TrackConfidence__c', // Enable AI confidence score tracking (0-100) for this capability
        'ExposureLevel__c'
    };

    public static AgentCapability__c getCapabilityById(Id capabilityId) {
        String logPrefix = '[AIAgentCfgSvc] ';
        if (capabilityId == null) {
            throw new ConfigurationException('AgentCapability ID cannot be null.');
        }

        if (!agentCapabilityIdCache.containsKey(capabilityId)) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Loading capability from database: ' + capabilityId);

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

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Loading capability "' + capabilityName + '" from database for Agent: ' + agentDefId);

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
     * Retrieves all AgentCapability__c records for a given agent definition with caching.
     * Useful for scenarios where all capabilities need to be accessed, such as formatting tools for LLM API.
     *
     * @param agentDefId The ID of the AIAgentDefinition__c.
     * @return           List of all AgentCapability__c records for the agent (includes all exposure levels).
     * @throws ConfigurationException if agentDefId is null or on query errors.
     */
    public static List<AgentCapability__c> getCapabilitiesByAgentId(Id agentDefId) {
        String logPrefix = '[AIAgentCfgSvc] ';

        if (agentDefId == null) {
            throw new ConfigurationException('Agent Definition ID cannot be null.');
        }

        // First, query all capability names for this agent (lightweight query)
        List<AgentCapability__c> capabilityStubs = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE AIAgentDefinition__c = :agentDefId AND ExposureLevel__c != 'Disabled'
        ];

        if (capabilityStubs.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'No capabilities found for Agent: ' + agentDefId);
            return new List<AgentCapability__c>();
        }

        // Build set of capability names
        Set<String> capabilityNames = new Set<String>();
        for (AgentCapability__c stub : capabilityStubs) {
            capabilityNames.add(stub.CapabilityName__c);
        }

        // Use bulk cache lookup to get full capability records
        Map<String, AgentCapability__c> capMap = getCapabilitiesByNames(agentDefId, capabilityNames);

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Retrieved ' + capMap.size() + ' capabilities for Agent: ' + agentDefId);
        return capMap.values();
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
    @SuppressWarnings('PMD.ApexSOQLInjection')
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
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Loading ' + uncachedNames.size() + ' capabilities from database for Agent: ' + agentDefId);

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
            System.debug(LoggingLevel.DEBUG, '[AIAgentConfigService] Loading Agent Definition from database: ' + agentDefId);

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
            System.debug(LoggingLevel.DEBUG, '[AIAgentConfigService] Loading Agent Definition by name from database: ' + developerName);

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
            System.debug(LoggingLevel.DEBUG, '[AIAgentConfigService] Loading LLM Configuration from database: ' + llmConfigId);

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
     * Retrieves the display name for an AI Agent Definition, preferring the actual Name over DeveloperName__c.
     * Uses cached lookups for optimal performance.
     *
     * @param agentDefinitionId The ID of the AIAgentDefinition__c record.
     * @return                  The agent's display name (Name field if available, otherwise DeveloperName__c), or 'AI Agent' as fallback.
     */
    public static String getAgentName(Id agentDefinitionId) {
        try {
            if (agentDefinitionId != null) {
                AIAgentDefinition__c agent = getAgentDefinition(agentDefinitionId);
                // Prefer the actual Name over DeveloperName
                return String.isNotBlank(agent.Name) ? agent.Name : agent.DeveloperName__c;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not retrieve agent name for ID: ' + agentDefinitionId + '. Error: ' + e.getMessage());
        }
        return 'AI Agent';
    }

    // ========================================================================
    // LLM MODEL PRICING METHODS
    // ========================================================================

    /**
     * Calculate estimated cost based on LLM model pricing and token usage.
     * Pricing is retrieved from LLMModelPricing__mdt custom metadata with transaction-level caching.
     *
     * This method provides centralized pricing calculation to avoid duplicate queries
     * across ExecutionStepService and AgentDecisionStepLogger.
     *
     * @param modelIdentifier  The model identifier (e.g., gpt-4o, gpt-4o-mini, gpt-5-nano)
     * @param promptTokens     Number of tokens in the prompt
     * @param completionTokens Number of tokens in the completion
     * @return                 The estimated cost in USD, or null if model is unknown or pricing not configured
     */
    public static Decimal calculateLLMCost(String modelIdentifier, Integer promptTokens, Integer completionTokens) {
        if (String.isBlank(modelIdentifier) || promptTokens == null || completionTokens == null) {
            return null;
        }

        ensurePricingCacheInitialized();

        // Normalize model identifier to lowercase for matching
        String normalizedModel = modelIdentifier.toLowerCase();

        if (pricingCache.containsKey(normalizedModel)) {
            LLMModelPricing__mdt pricing = pricingCache.get(normalizedModel);
            Decimal promptCost = (Decimal.valueOf(promptTokens) / 1000000.0) * pricing.PromptPricePer1MTokens__c;
            Decimal completionCost = (Decimal.valueOf(completionTokens) / 1000000.0) * pricing.CompletionPricePer1MTokens__c;
            return promptCost + completionCost;
        }

        System.debug(LoggingLevel.WARN, '[AIAgentConfigService] No pricing found for model: ' + modelIdentifier);
        return null;
    }

    /**
     * Retrieves the pricing metadata for a specific LLM model.
     * Useful for displaying pricing information in UI or detailed cost breakdowns.
     *
     * @param modelIdentifier The model identifier (case-insensitive)
     * @return                The LLMModelPricing__mdt record, or null if not found
     */
    public static LLMModelPricing__mdt getLLMPricing(String modelIdentifier) {
        if (String.isBlank(modelIdentifier)) {
            return null;
        }

        ensurePricingCacheInitialized();
        return pricingCache.get(modelIdentifier.toLowerCase());
    }

    /**
     * Ensures the LLM pricing cache is initialized with active model pricing records.
     * Uses a static flag to prevent repeated queries within the same transaction.
     *
     * This method is called automatically by calculateLLMCost() and getLLMPricing().
     */
    private static void ensurePricingCacheInitialized() {
        if (isPricingCacheInitialized) {
            return;
        }

        pricingCache = new Map<String, LLMModelPricing__mdt>();

        try {
            List<LLMModelPricing__mdt> pricingRecords = [
                SELECT ModelIdentifier__c, PromptPricePer1MTokens__c, CompletionPricePer1MTokens__c
                FROM LLMModelPricing__mdt
                WHERE IsActive__c = TRUE
            ];

            if (pricingRecords.isEmpty()) {
                System.debug(LoggingLevel.WARN, '[AIAgentConfigService] No active LLM pricing metadata found. Cost calculation will be unavailable.');
            }

            for (LLMModelPricing__mdt pricing : pricingRecords) {
                if (String.isNotBlank(pricing.ModelIdentifier__c)) {
                    pricingCache.put(pricing.ModelIdentifier__c.toLowerCase(), pricing);
                }
            }

            isPricingCacheInitialized = true;
            System.debug(LoggingLevel.DEBUG, '[AIAgentConfigService] Initialized LLM pricing cache with ' + pricingCache.size() + ' models');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AIAgentConfigService] Failed to initialize LLM pricing cache: ' + e.getMessage());
            // Do NOT set isPricingCacheInitialized = true on failure to allow retry
            throw new ConfigurationException('LLM pricing cache initialization failed: ' + e.getMessage(), e);
        }
    }

    /**
     * Returns the current size of the LLM pricing cache.
     * Useful for monitoring and diagnostics.
     *
     * @return Number of models in the pricing cache
     */
    @TestVisible
    private static Integer getLLMPricingCacheSize() {
        ensurePricingCacheInitialized();
        return pricingCache.size();
    }
}
