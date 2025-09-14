/**
 * @description (Graph Primitive) Clones OrderItems from a source Order to a destination Order.
 * @extends BaseAgentAction
 */
public class ActionCloneOrderItems extends BaseAgentAction {
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Id sourceOrderId = (Id) params.get('sourceOrderId');
        Id destinationOrderId = (Id) params.get('destinationOrderId');

        try {
            List<OrderItem> sourceItems = [
                SELECT PricebookEntryId, Quantity, UnitPrice
                FROM OrderItem
                WHERE OrderId = :sourceOrderId
                WITH USER_MODE
            ];

            if (sourceItems.isEmpty()) {
                return ActionOutcome.success(new Map<String, Object>{ 'status' => 'No items to clone', 'itemsCloned' => 0 });
            }

            List<OrderItem> newItems = new List<OrderItem>();
            for (OrderItem item : sourceItems) {
                newItems.add(
                    new OrderItem(
                        OrderId = destinationOrderId,
                        PricebookEntryId = item.PricebookEntryId,
                        Quantity = item.Quantity,
                        UnitPrice = item.UnitPrice
                    )
                );
            }

            insert newItems;

            return ActionOutcome.success(
                new Map<String, Object>{
                    'status' => 'success',
                    'itemsCloned' => newItems.size(),
                    'message' => 'Successfully cloned ' +
                    newItems.size() +
                    ' items from source order to destination order.'
                }
            );
        } catch (DmlException dmlEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_DML_ERROR, 'Failed to clone order items: ' + dmlEx.getMessage());
        } catch (QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to query source order items: ' + qEx.getMessage());
        } catch (Exception ex) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                'Unexpected error during order item cloning: ' + ex.getMessage()
            );
        }
    }
}
