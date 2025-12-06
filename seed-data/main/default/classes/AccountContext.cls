/**
 * @description Context provider for Account records. Used by AgentTestDataFactory for showcasing agents.
 * Returns Account details including key fields for AI agent context.
 * 
 * @implements IAgentContextProvider
 */
public class AccountContext implements IAgentContextProvider {
    /**
     * @description Retrieves Account context for the given anchor IDs
     * @param anchorIds Set of Account IDs to retrieve context for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map of context labels to lists of Account records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query Account records with key fields
            List<Account> accounts = [
                SELECT 
                    Id, 
                    Name, 
                    AccountNumber,
                    Type,
                    Industry, 
                    AnnualRevenue,
                    NumberOfEmployees,
                    BillingStreet,
                    BillingCity, 
                    BillingState,
                    BillingPostalCode,
                    BillingCountry,
                    Phone,
                    Website,
                    Description,
                    OwnerId,
                    CreatedDate
                FROM Account 
                WHERE Id IN :anchorIds 
                WITH USER_MODE
                LIMIT 200
            ];

            if (!accounts.isEmpty()) {
                result.put('Account Details', accounts);
            }

            System.debug('[AccountContext] Retrieved ' + accounts.size() + ' account(s) for ' + anchorIds.size() + ' anchor(s)');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AccountContext] Error retrieving accounts: ' + e.getMessage());
        }

        return result;
    }
}


