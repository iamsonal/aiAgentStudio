/**
 * @description (BULK-SAFE) Provides the core details for a set of Order records, including line items.
 *              This is typically used when the user is viewing a specific Order page.
 * @implements IAgentContextProvider
 */
public with sharing class OrderContext implements IAgentContextProvider {
    /**
     * @description Retrieves context data for a set of Order records.
     * @param anchorIds A Set of record IDs. This provider will filter for and process only the Order IDs.
     * @param userId The ID of the user initiating the request.
     * @param configurationJson Optional JSON string for custom configuration (not used).
     * @return A map containing the Order details and its line items.
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return results;
        }

        Set<Id> orderIds = new Set<Id>();
        for (Id currentId : anchorIds) {
            if (currentId.getSObjectType() == Order.SObjectType) {
                orderIds.add(currentId);
            }
        }

        if (orderIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[OrderContext] Anchor IDs contained no Order records.');
            return results;
        }

        try {
            List<Order> orders = [
                SELECT
                    Id,
                    OrderNumber,
                    Status,
                    TotalAmount,
                    EffectiveDate,
                    (
                        SELECT OrderItemNumber, Product2.Name, Quantity, UnitPrice
                        FROM OrderItems
                    )
                FROM Order
                WHERE Id IN :orderIds
                WITH USER_MODE
                LIMIT 10
            ];

            if (!orders.isEmpty()) {
                results.put('Current Order Details', orders);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[OrderContext] Failed to query Order details. Error: ' + e.getMessage());
        }

        return results;
    }
}
