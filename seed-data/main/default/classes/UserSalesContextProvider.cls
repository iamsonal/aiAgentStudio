// File: classes/UserSalesContextProvider.cls
/**
 * @description Provides sales-related context for a user: key accounts, open opportunities,
 *              territory information (if applicable). Designed for user-anchored context.
 * @implements IAgentContextProvider
 */
public inherited sharing class UserSalesContextProvider implements IAgentContextProvider {
    private static final String LOG_PREFIX = '[UserSalesContext] ';
    private static final Integer ACCOUNT_LIMIT = 5;
    private static final Integer OPPORTUNITY_LIMIT = 5;

    // Context Block Labels
    private static final String LABEL_MY_ACCOUNTS = 'My Top Accounts';
    private static final String LABEL_MY_OPEN_OPPS = 'My Open Opportunities';
    private static final String LABEL_MY_TERRITORIES = 'My Sales Territories'; // Example

    public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson) {
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Getting sales context for User: ' + userId);
        Map<String, List<SObject>> contextBlocks = new Map<String, List<SObject>>();

        if (userId == null) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'User ID is null.');
            return contextBlocks;
        }

        // --- 1. Get Key Accounts ---
        try {
            // Using fields assumed useful for sales context
            List<Account> keyAccounts = [
                SELECT Id, Name, Industry, Type, LastActivityDate
                FROM Account
                WHERE OwnerId = :userId /* Add more relevant filters, e.g., IsActive__c, Rating */
                WITH USER_MODE
                ORDER BY LastActivityDate DESC NULLS LAST, Name ASC
                LIMIT :ACCOUNT_LIMIT
            ];
            if (!keyAccounts.isEmpty()) {
                contextBlocks.put(LABEL_MY_ACCOUNTS, keyAccounts);
                System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Fetched ' + keyAccounts.size() + ' accounts.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error fetching Accounts: ' + e.getMessage());
        }

        // --- 2. Get Open Opportunities ---
        try {
            // Focused on actionable fields for open deals
            List<Opportunity> openOpps = [
                SELECT Id, Name, Account.Name, Amount, StageName, CloseDate, Probability
                FROM Opportunity
                WHERE OwnerId = :userId AND IsClosed = FALSE
                WITH USER_MODE
                ORDER BY CloseDate ASC, Amount DESC
                LIMIT :OPPORTUNITY_LIMIT
            ];
            if (!openOpps.isEmpty()) {
                contextBlocks.put(LABEL_MY_OPEN_OPPS, openOpps);
                System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Fetched ' + openOpps.size() + ' open opportunities.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error fetching Opportunities: ' + e.getMessage());
        }

        // --- 3. Get Sales Territories (Requires Enterprise Territory Management Setup) ---
        /* // Uncomment and adapt if ETM is used
        try {
            // Ensure object/field access before querying (or use USER_MODE if possible on setup objects)
            if (Schema.SObjectType.UserTerritory2Association.isAccessible() &&
                Schema.SObjectType.UserTerritory2Association.fields.Territory2Id.isAccessible() &&
                Schema.SObjectType.Territory2.isAccessible()) {

                List<UserTerritory2Association> associations = [
                    SELECT Territory2.Name, Territory2.DeveloperName
                    FROM UserTerritory2Association
                    WHERE UserId = :userId AND IsActive = TRUE
                    WITH USER_MODE // Preferred if API allows USER_MODE here
                    LIMIT 10 // Limit results
                ];
                if(!associations.isEmpty()){
                     // Option 1: Return Associations directly (less clear label)
                     // contextBlocks.put(LABEL_MY_TERRITORIES, associations);

                     // Option 2: Extract Territory names into a formatted list (or helper SObject)
                     List<SObject> territories = new List<SObject>();
                     Set<String> terrNames = new Set<String>(); // Avoid duplicates if user in overlapping hierarchy
                     for(UserTerritory2Association assoc : associations){
                        if(assoc.Territory2 != null && String.isNotBlank(assoc.Territory2.Name) && !terrNames.contains(assoc.Territory2.Name)){
                            territories.add(assoc.Territory2); // Add Territory2 SObject
                            terrNames.add(assoc.Territory2.Name);
                        }
                     }
                     if(!territories.isEmpty()){
                         contextBlocks.put(LABEL_MY_TERRITORIES, territories);
                          System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Fetched ' + territories.size() + ' sales territories.');
                     }
                }
            } else {
                 System.debug(LoggingLevel.INFO, LOG_PREFIX + 'User lacks access to Territory information or object is inaccessible.');
            }
        } catch (Exception e) {
             System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error fetching Territories: ' + e.getMessage());
        }
        */

        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Finished. Returning ' + contextBlocks.size() + ' blocks.');
        return contextBlocks;
    }
}
