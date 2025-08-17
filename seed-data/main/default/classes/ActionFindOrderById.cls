/**
 * @description (Graph Primitive) A specific action to find a single Order and its items by ID.
 *              This simplifies the data contract for the graph execution service.
 * @extends BaseAgentAction
 */
public class ActionFindOrderById extends BaseAgentAction {
    public override Object executeAction(Map<String, Object> params) {
        Id orderId = (Id) params.get('orderId');

        // Use the powerful QueryService under the hood
        QueryService queryService = new QueryService(Order.SObjectType, '[ActionFindOrderById]')
            .withDefaultFields(new List<String>{ 'Id', 'OrderNumber', 'AccountId', 'BillToContactId', 'EffectiveDate', 'Pricebook2Id' })
            .withAdditionalFields(new List<String>{ '(SELECT PricebookEntryId, Quantity, UnitPrice FROM OrderItems)' })
            .withFilters(new Map<String, Object>{ 'Id' => orderId });

        List<Order> results = queryService.executeQuery();

        return new Map<String, Object>{ 'records' => results };
    }
}
