/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * LLMProviderFactory is a factory and cache for creating LLM provider adapter instances.
 *
 * Responsibilities:
 *   - Dynamically instantiates adapter classes based on LLMConfiguration__c settings
 *   - Implements a singleton pattern with caching to optimize performance and resource usage
 *   - Validates adapter class existence and interface implementation
 *   - Provides a single entry point for retrieving provider adapters throughout the framework
 *
 * This class ensures that LLM provider adapters are instantiated efficiently and consistently,
 * and that configuration errors are surfaced early and clearly.
 */
public inherited sharing class LLMProviderFactory {
    @TestVisible
    private static Map<String, ILLMProviderAdapter> adapterInstanceCache = new Map<String, ILLMProviderAdapter>();

    /**
     * Retrieves a cached or newly instantiated LLM provider adapter based on configuration.
     *
     * - Checks the cache for an existing adapter instance by class name
     * - Dynamically instantiates the adapter if not cached, validates interface implementation
     * - Caches the instance for future use
     *
     * @param llmConfig  The LLMConfiguration__c record containing the adapter class name
     * @return ILLMProviderAdapter  Configured adapter instance ready for use
     * @throws ConfigurationException if the adapter class is missing, invalid, or does not implement the required interface
     */
    public static ILLMProviderAdapter getAdapter(LLMConfiguration__c llmConfig) {
        if (llmConfig == null) {
            throw new ConfigurationException('LLM Configuration cannot be null for getting adapter.');
        }
        String adapterClassName = llmConfig.ProviderAdapterClass__c;
        if (String.isBlank(adapterClassName)) {
            throw new ConfigurationException('ProviderAdapterClass__c is not defined for LLM Configuration: ' + llmConfig.DeveloperName__c);
        }

        if (adapterInstanceCache.containsKey(adapterClassName)) {
            System.debug(LoggingLevel.DEBUG, '[LLMProviderFactory] Cache hit for adapter: ' + adapterClassName);
            return adapterInstanceCache.get(adapterClassName);
        }

        try {
            Type adapterType = Type.forName(adapterClassName);
            if (adapterType == null) {
                System.debug(
                    LoggingLevel.ERROR,
                    '[LLMProviderFactory] Adapter class not found: ' + adapterClassName + ' for LLM Config ' + llmConfig.DeveloperName__c
                );
                throw new ConfigurationException('Adapter class not found: ' + adapterClassName + ' for LLM Config ' + llmConfig.DeveloperName__c);
            }
            Object adapterObject = adapterType.newInstance();
            if (!(adapterObject instanceof ILLMProviderAdapter)) {
                System.debug(
                    LoggingLevel.ERROR,
                    '[LLMProviderFactory] Class ' +
                        adapterClassName +
                        ' does not implement ILLMProviderAdapter for LLM Config ' +
                        llmConfig.DeveloperName__c
                );
                throw new ConfigurationException(
                    'Class ' + adapterClassName + ' does not implement ILLMProviderAdapter for LLM Config ' + llmConfig.DeveloperName__c
                );
            }
            ILLMProviderAdapter adapterInstance = (ILLMProviderAdapter) adapterObject;
            adapterInstanceCache.put(adapterClassName, adapterInstance);
            System.debug(LoggingLevel.INFO, '[LLMProviderFactory] Instantiated and cached adapter: ' + adapterClassName);
            return adapterInstance;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[LLMProviderFactory] Error instantiating adapter ' +
                    adapterClassName +
                    ' for LLM ' +
                    llmConfig.DeveloperName__c +
                    ': ' +
                    e.getMessage()
            );
            throw new ConfigurationException(
                'Error instantiating adapter ' + adapterClassName + ' for LLM ' + llmConfig.DeveloperName__c + ': ' + e.getMessage(),
                e
            );
        }
    }

    /**
     * Clears the adapter instance cache. Used for testing or to force re-instantiation.
     */
    @TestVisible
    private static void clearCache() {
        adapterInstanceCache = new Map<String, ILLMProviderAdapter>();
        System.debug(LoggingLevel.DEBUG, '[LLMProviderFactory] Adapter cache cleared.');
    }

    public class ConfigurationException extends AIAgentException {
    }
}
