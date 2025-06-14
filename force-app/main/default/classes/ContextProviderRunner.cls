/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Orchestrates context retrieval by running configured IAgentContextProviders.
 *              Constructs a hybrid context string with both human-readable and structured JSON formats.
 */
public inherited sharing class ContextProviderRunner {
    private static final String LOG_CTX_RUNNER = '[CtxProviderRunner] ';
    private static final String ERROR_PREFIX = 'ContextProviderRunner Error: ';
    private static final String PROVIDER_INVOCATION_ERROR = 'Failed invoking Context Provider';

    public virtual class ContextRunnerException extends AIAgentException {
    }
    public class ContextConfigurationException extends ContextRunnerException {
    }
    public class ContextProviderExecutionException extends ContextRunnerException {
    }

    /**
     * @description Aggregates context data from configured Apex providers into a single hybrid string.
     * @return String A formatted string containing human-readable and/or structured JSON context.
     */
    public static String aggregateContext(Id agentDefinitionId, Id userId, Id recordId) {
        if (agentDefinitionId == null || userId == null) {
            throw new ContextRunnerException('Agent Definition ID and User ID are required.');
        }

        String logPrefix = '[CtxProviderRunner] ';

        List<AgentContextConfig__c> applicableConfigs = queryApplicableConfigs(agentDefinitionId, logPrefix);
        if (applicableConfigs.isEmpty()) {
            return null;
        }

        List<String> allReadableContextBlocks = new List<String>();
        Map<String, Object> finalStructuredContext = new Map<String, Object>();
        Map<String, String> providerErrors = new Map<String, String>();

        String currentSObjectType = (recordId != null) ? String.valueOf(recordId.getSObjectType()) : null;

        for (AgentContextConfig__c config : applicableConfigs) {
            if (!shouldProviderRun(config, recordId, currentSObjectType, userId, logPrefix)) {
                continue;
            }

            Map<String, List<SObject>> providerResult = invokeSingleProvider(config, recordId, userId, logPrefix, providerErrors);
            if (providerResult == null || providerResult.isEmpty()) {
                continue;
            }

            String formatOption = String.isNotBlank(config.ContextFormat__c) ? config.ContextFormat__c : 'TextAndData';

            Map<String, Object> structuredDataForThisProvider = new Map<String, Object>();

            for (String header : providerResult.keySet()) {
                List<SObject> sObjects = providerResult.get(header);
                if (sObjects == null || sObjects.isEmpty())
                    continue;

                if (formatOption == 'TextAndData' || formatOption == 'TextOnly') {
                    String readableBlock = SObjectContextFormatter.formatSObjectListAsHumanReadable(
                        config.ContextLabel__c,
                        header,
                        sObjects,
                        logPrefix
                    );
                    if (String.isNotBlank(readableBlock)) {
                        allReadableContextBlocks.add(readableBlock);
                    }
                }

                if (formatOption == 'TextAndData' || formatOption == 'DataOnly') {
                    List<Map<String, Object>> sObjectMaps = SObjectContextFormatter.formatSObjectListAsMaps(sObjects, logPrefix);
                    if (!sObjectMaps.isEmpty()) {
                        structuredDataForThisProvider.put(header, sObjectMaps);
                    }

                    SObjectType sObjType = sObjects[0].getSObjectType();
                    String schemaKey = sObjType.getDescribe().getName() + '_Schema';

                    if (!finalStructuredContext.containsKey(schemaKey)) {
                        Map<String, Object> schemaMap = SObjectContextFormatter.formatSObjectSchema(sObjects, logPrefix);

                        if (!schemaMap.isEmpty()) {
                            finalStructuredContext.put(schemaKey, schemaMap);
                        }
                    }
                }
            }

            if (!structuredDataForThisProvider.isEmpty()) {
                finalStructuredContext.put(config.ContextLabel__c, structuredDataForThisProvider);
            }
        }

        logProviderErrorsIfExist(providerErrors, logPrefix);
        return assembleFinalContextString(allReadableContextBlocks, finalStructuredContext, logPrefix);
    }

    /**
     * @description NEW: Assembles the final context string from readable and structured parts.
     */
    private static String assembleFinalContextString(List<String> readableBlocks, Map<String, Object> structuredData, String logPrefix) {
        if (readableBlocks.isEmpty() && structuredData.isEmpty()) {
            return null;
        }

        List<String> finalParts = new List<String>();

        if (!readableBlocks.isEmpty()) {
            finalParts.add('--- HUMAN-READABLE CONTEXT ---\n' + String.join(readableBlocks, '\n\n'));
        }

        if (!structuredData.isEmpty()) {
            String jsonString = JSON.serialize(structuredData, true);
            finalParts.add('--- STRUCTURED CONTEXT DATA (FOR TOOL USE) ---\n```json\n' + jsonString + '\n```');
        }

        String combinedContext = String.join(finalParts, '\n\n');
        String finalContextString = addGlobalContext(combinedContext);

        Integer truncationLimit = AIAgentFrameworkSettings.getDefaultContextTruncationLength();
        if (finalContextString.length() > truncationLimit) {
            finalContextString = finalContextString.abbreviate(truncationLimit);
        }

        return finalContextString;
    }

    private static List<AgentContextConfig__c> queryApplicableConfigs(Id agentDefinitionId, String logPrefix) {
        try {
            return [
                SELECT
                    Id,
                    Name,
                    ContextLabel__c,
                    ImplementationType__c,
                    ImplementationName__c,
                    ImplementationConfigJson__c,
                    ExecutionOrder__c,
                    ApplicableSObjectTypes__c,
                    RequiresRecordContext__c,
                    ContextFormat__c
                FROM AgentContextConfig__c
                WHERE AIAgentDefinition__c = :agentDefinitionId AND IsActive__c = TRUE
                WITH USER_MODE
                ORDER BY ExecutionOrder__c ASC
                LIMIT 20
            ];
        } catch (Exception e) {
            throw new ContextConfigurationException(ERROR_PREFIX + 'Query for configuration failed.', e);
        }
    }

    private static Boolean shouldProviderRun(AgentContextConfig__c config, Id recordId, String currentSObjectType, Id userId, String logPrefix) {
        String providerName = config.ImplementationName__c;

        if (config.RequiresRecordContext__c == true) {
            if (recordId == null) {
                return false;
            }

            if (String.isNotBlank(config.ApplicableSObjectTypes__c)) {
                Set<String> allowedTypes = new Set<String>(config.ApplicableSObjectTypes__c.toLowerCase().split(','));
                if (allowedTypes.contains(currentSObjectType.toLowerCase())) {
                    return true;
                } else {
                    return false;
                }
            } else {
                return true;
            }
        } else {
            return true;
        }
    }

    private static Map<String, List<SObject>> invokeSingleProvider(
        AgentContextConfig__c config,
        Id recordId,
        Id userId,
        String logPrefix,
        Map<String, String> providerErrors
    ) {
        String providerId = config.ImplementationName__c + ' (Config:' + config.Id + ')';
        logPrefix += ' Provider:' + config.ImplementationName__c + ' - ';

        try {
            if (config.ImplementationType__c != 'Apex') {
                providerErrors.put(providerId, 'Skipped non-Apex type: ' + config.ImplementationType__c);
                return null;
            }
            if (String.isBlank(config.ImplementationName__c)) {
                throw new ContextConfigurationException(ERROR_PREFIX + 'Apex Provider class name blank for Config ID ' + config.Id);
            }

            IAgentContextProvider providerInstance;
            try {
                Type providerType = Type.forName(config.ImplementationName__c);
                if (providerType == null)
                    throw new ContextConfigurationException(ERROR_PREFIX + 'Apex class not found: ' + config.ImplementationName__c);
                Object instanceObj = providerType.newInstance();
                if (!(instanceObj instanceof IAgentContextProvider))
                    throw new ContextConfigurationException(ERROR_PREFIX + 'Class ' + config.ImplementationName__c + ' not IAgentContextProvider.');
                providerInstance = (IAgentContextProvider) instanceObj;
            } catch (Exception instantiationEx) {
                throw new ContextConfigurationException(ERROR_PREFIX + 'Failed to instantiate ' + config.ImplementationName__c, instantiationEx);
            }

            Id anchorId = (recordId != null && (config.RequiresRecordContext__c || String.isNotBlank(config.ApplicableSObjectTypes__c)))
                ? recordId
                : userId;
            try {
                Long startTime = System.currentTimeMillis();
                Map<String, List<SObject>> result = providerInstance.getContext(anchorId, userId, config.ImplementationConfigJson__c);

                return result;
            } catch (Exception providerEx) {
                String errorMsg = PROVIDER_INVOCATION_ERROR + ': ' + providerEx.getMessage();

                providerErrors.put(providerId, errorMsg);
                return null;
            }
        } catch (ContextConfigurationException cce) {
            throw cce;
        } catch (Exception e) {
            String errorMsg = 'Unexpected error processing provider config ' + config.Id + ': ' + e.getMessage();

            providerErrors.put(providerId, errorMsg);
            return null;
        }
    }

    private static String addGlobalContext(String existingContext) {
        List<String> parts = new List<String>();
        parts.add('*** Context Data Start ***');
        parts.add('Current Date: ' + System.today().format());
        if (String.isNotBlank(existingContext))
            parts.add('\n' + existingContext);
        parts.add('\n*** Context Data End ***');
        return String.join(parts, '\n');
    }

    private static void logProviderErrorsIfExist(Map<String, String> providerErrors, String logPrefix) {
        if (providerErrors != null && !providerErrors.isEmpty()) {
            for (String providerId : providerErrors.keySet()) {
            }
        }
    }
}
