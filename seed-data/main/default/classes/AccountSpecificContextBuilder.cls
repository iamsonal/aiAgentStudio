/**
 * @description Context Provider: Fetches specified fields for the current Account record.
 *              Requires ImplementationConfigJson to specify 'fieldsToInclude'.
 */
public with sharing class AccountSpecificContextBuilder implements IAgentContextProvider {
    private static final String LOG_PREFIX = '[AccountSpecificCtx] ';

    // Inner class for parsing the configuration JSON
    private class Config {
        @AuraEnabled
        public String objectApiName; // Expected to be "Account"
        @AuraEnabled
        public List<String> fieldsToInclude;
    }

    public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson) {
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Starting context build for Anchor (Account ID): ' + anchorId + ', User: ' + userId);
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();

        // 1. Validate Inputs
        if (anchorId == null || anchorId.getSObjectType() != Account.SObjectType) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Invalid anchorId. Expected Account ID, received: ' + anchorId);
            results.put('Error', new List<SObject>{ (SObject) new Account(Name = 'Error: Invalid Account ID provided to context builder.') });
            return results;
        }

        if (String.isBlank(configurationJson)) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Configuration JSON is required for AccountSpecificContextBuilder.');
            results.put(
                'Configuration Error',
                new List<SObject>{ (SObject) new Account(Name = 'Error: Missing ImplementationConfigJson specifying fieldsToInclude.') }
            );
            return results;
        }

        // 2. Parse Configuration JSON
        Config parsedConfig;
        List<String> fieldsToQuery;
        try {
            parsedConfig = (Config) JSON.deserialize(configurationJson, Config.class);
            if (parsedConfig == null || String.isBlank(parsedConfig.objectApiName) || parsedConfig.objectApiName.toLowerCase() != 'account') {
                throw new ContextConfigurationException('Configuration JSON must specify "objectApiName" as "Account".');
            }
            if (parsedConfig.fieldsToInclude == null || parsedConfig.fieldsToInclude.isEmpty()) {
                throw new ContextConfigurationException('Configuration JSON must specify a non-empty list of "fieldsToInclude".');
            }
            fieldsToQuery = new List<String>(parsedConfig.fieldsToInclude); // Make a mutable copy
            // Always include Id if not present, as it's good practice
            if (!fieldsToQuery.contains('Id') && !fieldsToQuery.contains('id') && !fieldsToQuery.contains('ID')) {
                fieldsToQuery.add('Id');
            }
            System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Parsed config. Fields to query: ' + String.join(fieldsToQuery, ', '));
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Failed to parse Configuration JSON: ' + e.getMessage());
            results.put(
                'Configuration Error',
                new List<SObject>{ (SObject) new Account(Name = 'Error: Invalid Configuration JSON. Details: ' + e.getMessage()) }
            );
            return results;
        }

        // 3. Build and Execute SOQL Query using QueryService
        // We could use QueryService for advanced FLS on relationships, but for direct fields a simple SOQL is fine.
        // For simplicity, let's construct a simple SOQL query with FLS check here.
        // For production with more complex needs, integrating QueryService would be more robust for relationship fields.

        String soqlQuery;
        List<String> accessibleFields = new List<String>();
        try {
            // FLS Check before constructing query
            Map<String, Schema.SObjectField> accountFieldsMap = Schema.SObjectType.Account.fields.getMap();
            for (String fieldPath : fieldsToQuery) {
                // Handle simple relationship fields (e.g., Owner.Name) for FLS on the relationship itself
                String baseFieldForFls = fieldPath.contains('.') ? fieldPath.substringBefore('.') : fieldPath;
                Schema.SObjectField fieldToken = accountFieldsMap.get(baseFieldForFls.toLowerCase());

                if (fieldToken != null && fieldToken.getDescribe().isAccessible()) {
                    accessibleFields.add(fieldPath); // Add original path for query
                } else {
                    System.debug(
                        LoggingLevel.WARN,
                        LOG_PREFIX +
                            'FLS Check: Field or relationship "' +
                            fieldPath +
                            '" (base: "' +
                            baseFieldForFls +
                            '") is not accessible. Skipping.'
                    );
                }
            }

            if (accessibleFields.isEmpty()) {
                System.debug(LoggingLevel.WARN, LOG_PREFIX + 'No accessible fields found to query based on configuration and FLS.');
                results.put(
                    'Access Error',
                    new List<SObject>{
                        (SObject) new Account(Name = 'Error: No configured fields are accessible for the current user on this Account.')
                    }
                );
                return results;
            }

            soqlQuery = 'SELECT ' + String.join(accessibleFields, ', ') + ' FROM Account WHERE Id = :accountId LIMIT 1';
            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Executing Query: ' + soqlQuery + ' || Bind: accountId=' + anchorId);

            // Execute query WITH USER_MODE to enforce record-level sharing and FLS on queried fields
            List<Account> accountList = Database.queryWithBinds(soqlQuery, new Map<String, Object>{ 'accountId' => anchorId }, AccessLevel.USER_MODE);

            if (accountList.isEmpty()) {
                System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Account record not found or not accessible: ' + anchorId);
                results.put('Current Account Details', new List<SObject>{ (SObject) new Account(Name = 'Account not found or inaccessible.') });
            } else {
                results.put('Current Account Details', accountList); // ContextService uses "ContextLabel__c" from config
                System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Successfully fetched Account details.');
            }
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                LOG_PREFIX + 'Error querying Account details: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString()
            );
            results.put('Error', new List<SObject>{ (SObject) new Account(Name = 'Error retrieving Account details: ' + e.getMessage()) });
        }

        System.debug(
            LoggingLevel.INFO,
            LOG_PREFIX + 'Context build complete for Account: ' + anchorId + '. Returning ' + results.size() + ' blocks.'
        );
        return results;
    }

    // Custom exception for configuration issues specific to this provider
    public class ContextConfigurationException extends Exception {
    }
}
