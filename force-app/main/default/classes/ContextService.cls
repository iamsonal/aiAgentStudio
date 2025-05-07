/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Service responsible for orchestrating context retrieval for AI Agents.
 *              It queries AgentContextConfig__c records, invokes configured Apex providers
 *              (implementing IAgentContextProvider), aggregates the results, formats them into
 *              a structured string, and applies truncation based on framework settings.
 */
public inherited sharing class ContextService {
    private static final String LOG_CTX_SERVICE = '[ContextService] ';
    private static final String ERROR_PREFIX = 'ContextService Error: ';
    private static final String PROVIDER_INVOCATION_ERROR = 'Failed invoking Context Provider';

    public virtual class ContextServiceException extends AIAgentException {
    }
    public class ContextConfigurationException extends ContextServiceException {
    }
    public class ContextProviderExecutionException extends ContextServiceException {
    }

    /**
     * @description Aggregates context data from configured Apex providers for a given agent and context.
     * @param agentDefinitionId ID of the AIAgentDefinition__c.
     * @param userId ID of the user initiating the request.
     * @param recordId Optional ID of the record providing primary context.
     * @return String A formatted, potentially truncated string containing all aggregated context, or null if no context gathered.
     * @throws ContextConfigurationException if the framework configuration (AgentContextConfig__c) is invalid.
     * @throws ContextProviderExecutionException if a specific provider fails critically during instantiation or execution.
     *         (Note: Minor provider errors might be logged & skipped based on implementation).
     */
    public static String aggregateContext(Id agentDefinitionId, Id userId, Id recordId) {
        if (agentDefinitionId == null || userId == null) {
            String errorMsg = ERROR_PREFIX + 'Agent Definition ID and User ID are required.';

            throw new ContextServiceException(errorMsg);
        }

        String logPrefix = LOG_CTX_SERVICE + 'Agent:' + agentDefinitionId + ' User:' + userId + ' Record:' + recordId + ' - ';

        String currentSObjectType = (recordId != null) ? String.valueOf(recordId.getSObjectType()) : null;
        List<AgentContextConfig__c> applicableConfigs = queryApplicableConfigs(agentDefinitionId, logPrefix);

        if (applicableConfigs.isEmpty()) {
            return null;
        }

        List<String> formattedContextBlocks = new List<String>();
        Map<String, String> providerErrors = new Map<String, String>();

        for (AgentContextConfig__c config : applicableConfigs) {
            if (!shouldProviderRun(config, recordId, currentSObjectType, userId, logPrefix)) {
                continue;
            }

            Map<String, List<SObject>> providerResult = invokeSingleProvider(config, recordId, userId, logPrefix, providerErrors);

            if (providerResult == null || providerResult.isEmpty()) {
                continue;
            }

            Integer blockCounter = 0;
            for (String subLabel : providerResult.keySet()) {
                List<SObject> sObjects = providerResult.get(subLabel);
                if (sObjects != null && !sObjects.isEmpty()) {
                    String formattedBlock = formatSObjectList(config.ContextLabel__c, subLabel, sObjects, logPrefix);
                    if (String.isNotBlank(formattedBlock)) {
                        formattedContextBlocks.add(formattedBlock);
                        blockCounter++;
                    }
                }
            }
        }

        if (formattedContextBlocks.isEmpty()) {
            logProviderErrorsIfExist(providerErrors, logPrefix);
            return null;
        }

        logProviderErrorsIfExist(providerErrors, logPrefix);

        String combinedContext = String.join(formattedContextBlocks, '\n\n');
        String finalContextString = addGlobalContext(combinedContext);

        Integer truncationLimit = AIAgentFrameworkSettings.getDefaultContextTruncationLength();
        if (finalContextString.length() > truncationLimit) {
            finalContextString = finalContextString.abbreviate(truncationLimit);
        }

        return finalContextString;
    }

    /**
     * Queries active AgentContextConfig__c records for the specified Agent Definition.
     */
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
                    RequiresRecordContext__c
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

    /**
     * Determines if a specific provider configuration should run based on the current context.
     */
    private static Boolean shouldProviderRun(AgentContextConfig__c config, Id recordId, String currentSObjectType, Id userId, String logPrefix) {
        if (recordId == null) {
            return !config.RequiresRecordContext__c;
        } else {
            if (config.RequiresRecordContext__c == true && String.isBlank(config.ApplicableSObjectTypes__c)) {
                return true;
            } else if (String.isNotBlank(config.ApplicableSObjectTypes__c)) {
                Set<String> allowedTypes = new Set<String>(config.ApplicableSObjectTypes__c.toLowerCase().split(','));
                Boolean typeMatches = allowedTypes.contains(currentSObjectType.toLowerCase());

                if (typeMatches) {
                    return true;
                } else if (config.RequiresRecordContext__c == false && allowedTypes.isEmpty()) {
                    return true;
                } else {
                    return false;
                }
            } else {
                return !config.RequiresRecordContext__c;
            }
        }
    }

    /**
     * Instantiates and invokes a single context provider, handling errors gracefully.
     * Returns null if invocation fails non-critically (error logged).
     * Throws exceptions for critical config errors.
     * Adds non-critical errors to the providerErrors map.
     */
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
                throw new ContextConfigurationException(ERROR_PREFIX + 'Apex Provider class name is blank for Config ID ' + config.Id);
            }

            IAgentContextProvider providerInstance;
            try {
                Type providerType = Type.forName(config.ImplementationName__c);
                if (providerType == null) {
                    throw new ContextConfigurationException(ERROR_PREFIX + 'Apex class not found: ' + config.ImplementationName__c);
                }
                Object instanceObj = providerType.newInstance();
                if (!(instanceObj instanceof IAgentContextProvider)) {
                    throw new ContextConfigurationException(
                        ERROR_PREFIX + 'Class ' + config.ImplementationName__c + ' does not implement IAgentContextProvider.'
                    );
                }
                providerInstance = (IAgentContextProvider) instanceObj;
            } catch (Exception instantiationEx) {
                throw new ContextConfigurationException(
                    ERROR_PREFIX + 'Failed to instantiate provider ' + config.ImplementationName__c,
                    instantiationEx
                );
            }

            Id anchorId = (recordId != null && (config.RequiresRecordContext__c || String.isNotBlank(config.ApplicableSObjectTypes__c)))
                ? recordId
                : userId;

            try {
                Long startTime = System.currentTimeMillis();
                Map<String, List<SObject>> result = providerInstance.getContext(anchorId, userId, config.ImplementationConfigJson__c);
                Long duration = System.currentTimeMillis() - startTime;

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

    /**
     * Formats a list of SObjects into a structured text block for the LLM.
     */
    private static String formatSObjectList(String mainLabel, String subLabel, List<SObject> records, String logPrefix) {
        if (records == null || records.isEmpty()) {
            return '';
        }

        String blockLabel = String.isNotBlank(subLabel) ? subLabel : mainLabel;

        List<String> formattedRecords = new List<String>();
        SObjectType objType = records[0].getSObjectType();

        Map<String, Schema.SObjectField> objFieldsMap = SchemaUtils.getObjectFields(objType);

        for (SObject record : records) {
            Map<String, Object> fields = record.getPopulatedFieldsAsMap();
            List<String> fieldEntries = new List<String>();

            for (String fieldName : fields.keySet()) {
                Schema.SObjectField fieldToken = objFieldsMap.get(fieldName.toLowerCase());

                if (fieldToken != null && fieldToken.getDescribe().isAccessible()) {
                    Object value = fields.get(fieldName);
                    String displayValue = (value == null || (value instanceof String && String.isBlank((String) value)))
                        ? '[Not Set]'
                        : String.valueOf(value);

                    fieldEntries.add(fieldToken.getDescribe().getName() + ': ' + displayValue);
                } else {
                    continue;
                }
            }

            if (!fieldEntries.isEmpty()) {
                String recordString;
                String nameValue = findAccessibleFieldValue(fieldEntries, 'Name: ');
                String subjectValue = findAccessibleFieldValue(fieldEntries, 'Subject: ');
                String caseNumValue = findAccessibleFieldValue(fieldEntries, 'CaseNumber: ');

                String displayPrefix = '';
                if (nameValue != null)
                    displayPrefix = nameValue;
                else if (subjectValue != null)
                    displayPrefix = subjectValue;
                else if (caseNumValue != null)
                    displayPrefix = caseNumValue;

                List<String> otherFields = new List<String>();
                for (String entry : fieldEntries) {
                    if (!entry.startsWith('Name: ') && !entry.startsWith('Subject: ') && !entry.startsWith('CaseNumber: ')) {
                        otherFields.add(entry);
                    }
                }

                recordString = String.isNotBlank(displayPrefix) ? displayPrefix : 'Record';
                if (!otherFields.isEmpty()) {
                    recordString += ' (' + String.join(otherFields, ' | ') + ')';
                }

                formattedRecords.add('- ' + recordString);
            } else {
            }
        }

        if (formattedRecords.isEmpty()) {
            return '';
        }

        return '** ' + blockLabel + ' (' + formattedRecords.size() + ' Records Shown) **\n' + String.join(formattedRecords, '\n');
    }

    /** Helper to extract value from formatted field entries for prioritization */
    private static String findAccessibleFieldValue(List<String> fieldEntries, String prefix) {
        for (String entry : fieldEntries) {
            if (entry.startsWithIgnoreCase(prefix)) {
                return entry.substring(prefix.length()).trim();
            }
        }
        return null;
    }

    /**
     * Adds global information like date/time to the combined context string.
     */
    private static String addGlobalContext(String existingContext) {
        List<String> parts = new List<String>();
        parts.add('*** Context Data Start ***');
        parts.add('Current Date: ' + System.today().format());

        if (String.isNotBlank(existingContext)) {
            parts.add('\n' + existingContext);
        }

        parts.add('\n*** Context Data End ***');

        return String.join(parts, '\n');
    }

    /**
     * Logs any non-critical provider errors that were stored.
     */
    private static void logProviderErrorsIfExist(Map<String, String> providerErrors, String logPrefix) {
        if (providerErrors != null && !providerErrors.isEmpty()) {
            for (String providerId : providerErrors.keySet()) {
            }
        }
    }
}
