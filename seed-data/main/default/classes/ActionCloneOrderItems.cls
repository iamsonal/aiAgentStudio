/**
 * @description (Graph Primitive) Clones OrderItems from a source Order to a destination Order.
 * @extends BaseAgentAction
 */
public class ActionCloneOrderItems extends BaseAgentAction {
    public override Object executeAction(Map<String, Object> params) {
        Id sourceOrderId = (Id) params.get('sourceOrderId');
        Id destinationOrderId = (Id) params.get('destinationOrderId');

        List<OrderItem> sourceItems = [
            SELECT PricebookEntryId, Quantity, UnitPrice
            FROM OrderItem
            WHERE OrderId = :sourceOrderId
            WITH USER_MODE
        ];

        if (sourceItems.isEmpty()) {
            return new Map<String, Object>{ 'status' => 'No items to clone' };
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

        return new Map<String, Object>{ 'status' => 'success', 'itemsCloned' => newItems.size() };
    }
}
