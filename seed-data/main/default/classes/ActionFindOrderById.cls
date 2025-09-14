/**
 * @description (Graph Primitive) A specific action to find a single Order and its items by ID.
 *              This simplifies the data contract for the graph execution service.
 * @extends BaseAgentAction
 */
public class ActionFindOrderById extends BaseAgentAction {
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Id orderId = (Id) params.get('orderId');

        try {
            // Build dynamic SOQL query for Order with OrderItems
            String query = 'SELECT Id, OrderNumber, AccountId, BillToContactId, EffectiveDate, Pricebook2Id';

            // Check if OrderItems relationship exists by checking child relationships
            Boolean hasOrderItems = false;
            Schema.DescribeSObjectResult orderDescribe = Order.SObjectType.getDescribe();
            for (Schema.ChildRelationship relationship : orderDescribe.getChildRelationships()) {
                if ('OrderItems'.equals(relationship.getRelationshipName())) {
                    hasOrderItems = true;
                    break;
                }
            }

            if (hasOrderItems) {
                query += ', (SELECT Id, PricebookEntryId, Quantity, UnitPrice, Product2.Name FROM OrderItems)';
            }

            query += ' FROM Order WHERE Id = :orderId';

            List<Order> results = Database.query(query);

            if (results.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, 'Order not found with ID: ' + orderId);
            }

            return ActionOutcome.success(
                new Map<String, Object>{
                    'records' => results,
                    'message' => 'Successfully found order ' +
                    results[0].OrderNumber +
                    ' with ' +
                    (results[0].OrderItems != null ? results[0].OrderItems.size() : 0) +
                    ' items.'
                }
            );
        } catch (System.QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to query order: ' + qEx.getMessage());
        } catch (Exception ex) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Unexpected error finding order: ' + ex.getMessage());
        }
    }
}
