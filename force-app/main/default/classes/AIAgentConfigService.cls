/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Provides cached access to AI Agent Framework configurations using Salesforce RECORD IDs and Developer Names.
 *              Handles AIAgentDefinition__c and LLMConfiguration__c lookups.
 */
public inherited sharing class AIAgentConfigService {
    private static Map<Id, AIAgentDefinition__c> agentDefIdCache = new Map<Id, AIAgentDefinition__c>();
    private static Map<String, AIAgentDefinition__c> agentDefNameCache = new Map<String, AIAgentDefinition__c>();

    private static Map<Id, LLMConfiguration__c> llmConfigIdCache = new Map<Id, LLMConfiguration__c>();
    private static Map<String, LLMConfiguration__c> llmConfigNameCache = new Map<String, LLMConfiguration__c>();

    private static final List<String> AGENT_DEFINITION_FIELDS = new List<String>{
        'Id',
        'Name',
        'DeveloperName__c',
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
        'DeveloperName__c',
        'ProviderAdapterClass__c',
        'NamedCredential__c',
        'DefaultModelIdentifier__c',
        'DefaultTemperature__c',
        'IsActive__c',
        'MaxRetryAttempts__c',
        'InitialRetryDelayMillis__c',
        'RetryableHttpStatusCodes__c'
    };

    /**
     * @description Retrieves a complete, active Agent Capability record.
     * @param agentDefId The ID of the AIAgentDefinition__c.
     * @param capabilityName The CapabilityName__c of the AgentCapability__c record.
     * @return AgentCapability__c record, or null if not found/inactive.
     * @throws ConfigurationException on query errors.
     */
    public static AgentCapability__c getCapability(Id agentDefId, String capabilityName) {
        String logPrefix = '[AIAgentCfgSvc] ';
        if (agentDefId == null || String.isBlank(capabilityName)) {
            return null;
        }

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
                return null;
            }
            return capabilities[0];
        } catch (Exception e) {
            String errorMsg = 'Error querying AgentCapability "' + capabilityName + '" on Agent ' + agentDefId;

            throw new ConfigurationException(errorMsg, e);
        }
    }

    /**
     * @description Retrieves an active AI Agent Definition by its Salesforce Record ID.
     *              Ensures required related fields are queried and caches the result.
     * @param agentDefId The 18-character Salesforce ID of the AIAgentDefinition__c record.
     * @return The corresponding AIAgentDefinition__c record.
     * @throws ConfigurationException if the ID is null, record not found, or record is not active.
     */
    public static AIAgentDefinition__c getAgentDefinition(Id agentDefId) {
        if (agentDefId == null) {
            throw new ConfigurationException('Agent Definition ID cannot be null.');
        }

        if (!agentDefIdCache.containsKey(agentDefId)) {
            String queryString = buildQuery('AIAgentDefinition__c', AGENT_DEFINITION_FIELDS, 'Id = :agentDefId AND IsActive__c = TRUE');

            List<AIAgentDefinition__c> results = Database.query(queryString);

            if (results.isEmpty()) {
                throw new ConfigurationException('Active AI Agent Definition not found for ID: ' + agentDefId);
            }

            AIAgentDefinition__c agentDef = results[0];
            cacheAgentDefinition(agentDef);

            if (agentDef.LLMConfiguration__c != null && !llmConfigIdCache.containsKey(agentDef.LLMConfiguration__c)) {
                try {
                    getLLMConfiguration(agentDef.LLMConfiguration__c);
                } catch (ConfigurationException e) {
                }
            }
        } else {
        }
        return agentDefIdCache.get(agentDefId);
    }

    /**
     * @description Retrieves an active AI Agent Definition by its unique Developer Name (case-insensitive).
     *              Ensures required related fields are queried and caches the result.
     * @param developerName The DeveloperName__c of the AIAgentDefinition__c record.
     * @return The corresponding AIAgentDefinition__c record.
     * @throws ConfigurationException if the name is blank, record not found, or record is not active.
     */
    public static AIAgentDefinition__c getAgentDefinitionByDeveloperName(String developerName) {
        if (String.isBlank(developerName)) {
            throw new ConfigurationException('Agent Definition Developer Name cannot be blank.');
        }
        String cacheKey = developerName.toLowerCase();

        if (!agentDefNameCache.containsKey(cacheKey)) {
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
            }

            AIAgentDefinition__c agentDef = results[0];
            cacheAgentDefinition(agentDef);

            if (agentDef.LLMConfiguration__c != null && !llmConfigIdCache.containsKey(agentDef.LLMConfiguration__c)) {
                try {
                    getLLMConfiguration(agentDef.LLMConfiguration__c);
                } catch (ConfigurationException e) {
                }
            }
        } else {
        }
        return agentDefNameCache.get(cacheKey);
    }

    /**
     * @description Retrieves an active LLM Configuration by its Salesforce Record ID.
     *              Queries consistent fields and caches the result.
     * @param llmConfigId The 18-character Salesforce ID of the LLMConfiguration__c record.
     * @return The corresponding LLMConfiguration__c record.
     * @throws ConfigurationException if the ID is null, record not found, or record is not active.
     */
    public static LLMConfiguration__c getLLMConfiguration(Id llmConfigId) {
        if (llmConfigId == null) {
            throw new ConfigurationException('LLM Configuration ID cannot be null.');
        }

        if (!llmConfigIdCache.containsKey(llmConfigId)) {
            String queryString = buildQuery('LLMConfiguration__c', LLM_CONFIGURATION_FIELDS, 'Id = :llmConfigId AND IsActive__c = TRUE');
            List<LLMConfiguration__c> results = Database.query(queryString);

            if (results.isEmpty()) {
                throw new ConfigurationException('Active LLM Configuration not found for ID: ' + llmConfigId);
            }
            cacheLLMConfiguration(results[0]);
        } else {
        }
        return llmConfigIdCache.get(llmConfigId);
    }

    /**
     * @description Retrieves an active LLM Configuration by its unique Developer Name (case-insensitive).
     *              Queries consistent fields and caches the result.
     * @param developerName The DeveloperName__c of the LLMConfiguration__c record.
     * @return The corresponding LLMConfiguration__c record.
     * @throws ConfigurationException if the name is blank, record not found, or record is not active.
     */
    public static LLMConfiguration__c getLLMConfigurationByDeveloperName(String developerName) {
        if (String.isBlank(developerName)) {
            throw new ConfigurationException('LLM Configuration Developer Name cannot be blank.');
        }
        String cacheKey = developerName.toLowerCase();

        if (!llmConfigNameCache.containsKey(cacheKey)) {
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
            }
            cacheLLMConfiguration(results[0]);
        } else {
        }
        return llmConfigNameCache.get(cacheKey);
    }

    /**
     * @description Retrieves the active LLM Configuration linked to a specific Agent Definition ID.
     *              Uses cached lookups for both Agent Definition and LLM Configuration.
     * @param agentDefId ID of the AIAgentDefinition__c
     * @return Corresponding active LLMConfiguration__c record, or null if Agent/LLM not found, inactive, or link missing.
     * @throws ConfigurationException only for unexpected query/system errors during lookup, not for 'not found'.
     */
    public static LLMConfiguration__c getLLMConfigurationByAgentDefinitionId(Id agentDefId) {
        if (agentDefId == null) {
            return null;
        }

        AIAgentDefinition__c agentDef = null;
        try {
            agentDef = getAgentDefinition(agentDefId);

            if (agentDef == null) {
                return null;
            }
        } catch (AIAgentConfigService.ConfigurationException configEx) {
            return null;
        } catch (Exception e) {
            throw new ConfigurationException('System error during Agent lookup: ' + e.getMessage(), e);
        }

        Id llmConfigId = agentDef.LLMConfiguration__c;
        if (llmConfigId == null) {
            return null;
        }

        LLMConfiguration__c llmConfig = null;
        try {
            llmConfig = getLLMConfiguration(llmConfigId);

            if (llmConfig == null) {
                return null;
            }
        } catch (AIAgentConfigService.ConfigurationException configEx) {
            return null;
        } catch (Exception e) {
            throw new ConfigurationException('System error during LLM lookup: ' + e.getMessage(), e);
        }

        return llmConfig;
    }

    private static String buildQuery(String objectApiName, List<String> fields, String whereClause) {
        return 'SELECT ' + String.join(fields, ', ') + ' FROM ' + objectApiName + ' WHERE ' + whereClause + ' LIMIT 1';
    }

    private static void cacheAgentDefinition(AIAgentDefinition__c agentDef) {
        if (agentDef?.Id == null)
            return;
        agentDefIdCache.put(agentDef.Id, agentDef);
        if (String.isNotBlank(agentDef.DeveloperName__c)) {
            agentDefNameCache.put(agentDef.DeveloperName__c.toLowerCase(), agentDef);
        }
    }

    private static void cacheLLMConfiguration(LLMConfiguration__c llmConfig) {
        if (llmConfig?.Id == null)
            return;
        llmConfigIdCache.put(llmConfig.Id, llmConfig);
        if (String.isNotBlank(llmConfig.DeveloperName__c)) {
            llmConfigNameCache.put(llmConfig.DeveloperName__c.toLowerCase(), llmConfig);
        }
    }

    @TestVisible
    private static void clearCache() {
        agentDefIdCache.clear();
        agentDefNameCache.clear();
        llmConfigIdCache.clear();
        llmConfigNameCache.clear();
    }

    public class ConfigurationException extends AIAgentException {
    }
}
