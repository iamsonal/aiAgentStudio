/**
 * @description Context provider for Product Launch Orchestrator demo
 *              Fetches Account profile and product fit data
 *
 * This provider returns comprehensive account context for product fit analysis:
 * - Account core fields (Name, Industry, NumberOfEmployees, AnnualRevenue)
 * - Company profile and description
 * - Geographic and contact information
 *
 * @implements IAgentContextProvider
 * @author Sonal
 * @since January 2026
 */
public class AccountProductFitContext implements IAgentContextProvider {
    /**
     * @description Retrieves Account profile context for product fit scoring
     * @param anchorIds Set of Account IDs to retrieve context for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map with 'Account Profile' key containing Account records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query Account with fields needed for product fit analysis
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
                    CreatedDate,
                    // Contact count (subquery)
                    (
                        SELECT Id, Name, Title, Email
                        FROM Contacts
                        WHERE Email != NULL
                        ORDER BY CreatedDate DESC
                        LIMIT 5
                    )
                FROM Account
                WHERE Id IN :anchorIds
                WITH USER_MODE
                LIMIT 50
            ];

            if (!accounts.isEmpty()) {
                result.put('Account Profile', accounts);
            }

            System.debug('[AccountProductFitContext] Retrieved ' + accounts.size() + ' account(s) with profile data');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AccountProductFitContext] Error: ' + e.getMessage());
        }

        return result;
    }
}
