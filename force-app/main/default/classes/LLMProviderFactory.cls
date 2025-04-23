/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

/** @description Factory for retrieving instances of LLM Provider Adapters. */
public inherited sharing class LLMProviderFactory {
    @TestVisible
    private static Map<String, ILLMProviderAdapter> adapterInstanceCache = new Map<String, ILLMProviderAdapter>();

    /**
     * @description Retrieves an instance of the ILLMProviderAdapter implementation.
     * @param llmConfig The LLMConfiguration__c record.
     * @return An instance of the specified ILLMProviderAdapter class.
     * @throws ConfigurationException if the adapter class is not found or invalid.
     */
    public static ILLMProviderAdapter getAdapter(LLMConfiguration__c llmConfig) {
        if (llmConfig == null) {
            throw new ConfigurationException('LLM Configuration cannot be null for getting adapter.');
        }
        String adapterClassName = llmConfig.ProviderAdapterClass__c;
        if (String.isBlank(adapterClassName)) {
            throw new ConfigurationException(
                'ProviderAdapterClass__c is not defined for LLM Configuration: ' + llmConfig.DeveloperName__c
            );
        }

        if (adapterInstanceCache.containsKey(adapterClassName)) {
            return adapterInstanceCache.get(adapterClassName);
        }

        try {
            Type adapterType = Type.forName(adapterClassName);
            if (adapterType == null) {
                throw new ConfigurationException(
                    'Adapter class not found: ' + adapterClassName + ' for LLM Config ' + llmConfig.DeveloperName__c
                );
            }
            Object adapterObject = adapterType.newInstance();
            if (!(adapterObject instanceof ILLMProviderAdapter)) {
                throw new ConfigurationException(
                    'Class ' +
                        adapterClassName +
                        ' does not implement ILLMProviderAdapter for LLM Config ' +
                        llmConfig.DeveloperName__c
                );
            }
            ILLMProviderAdapter adapterInstance = (ILLMProviderAdapter) adapterObject;
            adapterInstanceCache.put(adapterClassName, adapterInstance);
            return adapterInstance;
        } catch (Exception e) {
            throw new ConfigurationException(
                'Error instantiating adapter ' +
                    adapterClassName +
                    ' for LLM ' +
                    llmConfig.DeveloperName__c +
                    ': ' +
                    e.getMessage(),
                e
            );
        }
    }

    @TestVisible
    private static void clearCache() {
        adapterInstanceCache = new Map<String, ILLMProviderAdapter>();
    }

    public class ConfigurationException extends AIAgentException {
    }
}
