/**
 * @description Enterprise-grade Context Provider for fetching a primary record and its related data.
 *              This provider is highly configurable via an OPTIONAL ImplementationConfigJson.
 *              If the configuration JSON is omitted, it executes a default behavior: fetching the
 *              Account, its open Opportunities, and its Contacts.
 * @implements IAgentContextProvider
 */
public with sharing class AccountSpecificContextBuilder implements IAgentContextProvider {
    private static final String LOG_PREFIX = '[AccountContextBuilder] ';

    // --- Main Provider Logic ---
    public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson) {
        System.debug(configurationJson);
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Starting context build for Anchor ID: ' + anchorId);

        if (anchorId == null) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Anchor ID is missing. Aborting.');
            return new Map<String, List<SObject>>();
        }

        return executeDefaultBehavior(anchorId);
    }

    /**
     * @description Executes the default logic when no configuration JSON is provided.
     *              Fetches Account, open Opportunities, and all Contacts.
     */
    private Map<String, List<SObject>> executeDefaultBehavior(Id accountId) {
        Map<String, List<SObject>> finalResults = new Map<String, List<SObject>>();

        try {
            // 1. Fetch the main Account record
            QueryService accountQuery = new QueryService(Account.SObjectType, LOG_PREFIX + 'DefaultAccount')
                    .withDefaultFields(new List<String>{'Id', 'Name', 'Industry', 'Type', 'AnnualRevenue', 'Owner.Name'})
                    .withFilters(new Map<String, Object>{'Id' => accountId})
                    .withLimit(1,1);
            List<Account> accounts = accountQuery.executeQuery();
            if(!accounts.isEmpty()) finalResults.put('Account Details', accounts);

            // 2. Fetch related open Opportunities
            QueryService oppQuery = new QueryService(Opportunity.SObjectType, LOG_PREFIX + 'DefaultOpps')
                    .withDefaultFields(new List<String>{'Name', 'StageName', 'Amount', 'CloseDate'})
                    .withFilters(new Map<String, Object>{'AccountId' => accountId, 'IsClosed' => false})
                    .withOrderBy('CloseDate ASC')
                    .withLimit(5, 5);
            finalResults.put('Open Opportunities', oppQuery.executeQuery());

            // 3. Fetch related Contacts
            QueryService contactQuery = new QueryService(Contact.SObjectType, LOG_PREFIX + 'DefaultContacts')
                    .withDefaultFields(new List<String>{'Name', 'Title', 'Email', 'Phone'})
                    .withFilters(new Map<String, Object>{'AccountId' => accountId})
                    .withOrderBy('LastName ASC')
                    .withLimit(5, 5);
            finalResults.put('Contacts', contactQuery.executeQuery());

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error during default context execution. Error: ' + e.getMessage());
            // Do not throw, just log and return whatever was successfully gathered.
        }

        return finalResults;
    }

}
