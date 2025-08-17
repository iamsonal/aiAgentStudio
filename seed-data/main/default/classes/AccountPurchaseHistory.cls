/**
 * @description (BULK-SAFE) Provides a 360-degree support view for a set of Account records.
 *              It retrieves the most recent open/closed cases and recent orders to give
 *              the agent a complete picture of the customer's history.
 * @implements IAgentContextProvider
 */
public with sharing class AccountPurchaseHistory implements IAgentContextProvider {
    private static final Integer RELATED_RECORD_LIMIT = 3;

    /**
     * @description Retrieves related order history and open cases for a given set of Account IDs.
     * @param anchorIds A Set of IDs, from which this provider will only process Account IDs.
     * @param userId The ID of the user initiating the request.
     * @param configurationJson Custom configuration JSON (unused).
     * @return Map containing lists of recent orders and open support cases.
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> contextResults = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return contextResults;
        }

        Set<Id> accountIds = new Set<Id>();
        for (Id currentId : anchorIds) {
            if (currentId.getSObjectType() == Account.SObjectType) {
                accountIds.add(currentId);
            }
        }

        if (accountIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[AccountPurchaseHistory] Anchor IDs contained no Account records.');
            return contextResults;
        }

        // --- Fetch Recent Orders ---
        try {
            List<Order> recentOrders = [
                SELECT Id, OrderNumber, Status, TotalAmount, EffectiveDate
                FROM Order
                WHERE AccountId IN :accountIds
                WITH USER_MODE
                ORDER BY EffectiveDate DESC
                LIMIT :RELATED_RECORD_LIMIT
            ];

            if (!recentOrders.isEmpty()) {
                contextResults.put('Recent Orders', recentOrders);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AccountPurchaseHistory] Error querying orders: ' + e.getMessage());
        }

        // --- Fetch Open Cases ---
        try {
            List<Case> openCases = [
                SELECT Id, CaseNumber, Subject, Status, Priority, CreatedDate
                FROM Case
                WHERE AccountId IN :accountIds AND IsClosed = FALSE
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT :RELATED_RECORD_LIMIT
            ];

            if (!openCases.isEmpty()) {
                contextResults.put('Open Support Cases', openCases);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AccountPurchaseHistory] Error querying open cases: ' + e.getMessage());
        }

        return contextResults;
    }
}
