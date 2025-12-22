/**
 * @description Context provider for Order records. Used by AgentTestDataFactory for showcasing agents.
 * Returns Order details including key fields for AI agent context.
 *
 * @implements IAgentContextProvider
 */
public class OrderContext implements IAgentContextProvider {
    /**
     * @description Retrieves Order context for the given anchor IDs
     * @param anchorIds Set of Order IDs to retrieve context for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map of context labels to lists of Order records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query Order records with key fields
            List<Order> orders = [
                SELECT
                    Id,
                    OrderNumber,
                    Status,
                    TotalAmount,
                    Type,
                    EffectiveDate,
                    Description,
                    AccountId,
                    BillingStreet,
                    BillingCity,
                    BillingState,
                    BillingPostalCode,
                    BillingCountry,
                    ShippingStreet,
                    ShippingCity,
                    ShippingState,
                    ShippingPostalCode,
                    ShippingCountry,
                    OwnerId,
                    CreatedDate,
                    ActivatedDate
                FROM Order
                WHERE Id IN :anchorIds
                WITH USER_MODE
                LIMIT 200
            ];

            if (!orders.isEmpty()) {
                result.put('Order Details', orders);
            }

            System.debug('[OrderContext] Retrieved ' + orders.size() + ' order(s) for ' + anchorIds.size() + ' anchor(s)');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[OrderContext] Error retrieving orders: ' + e.getMessage());
        }

        return result;
    }
}
