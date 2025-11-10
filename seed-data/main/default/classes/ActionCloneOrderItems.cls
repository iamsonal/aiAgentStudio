/**
 * @description (Graph Primitive) Clones OrderItems from a source Order to a destination Order.
 * @extends BaseAgentAction
 */
public class ActionCloneOrderItems extends BaseAgentAction {
    private ConfigDTO config;

    /**
     * DTO for strongly-typed backend configuration
     */
    public class ConfigDTO {
        // No configuration needed - reserved for future use
    }

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        public String sourceOrderId;
        public String destinationOrderId;
    }

    /**
     * Returns field descriptors for ArgumentsDTO
     */
    private static List<FieldDescriptor> describeArguments() {
        return new List<FieldDescriptor>{
            FieldDescriptor.salesforceId('sourceOrderId')
                .required()
                .help('The Salesforce ID of the order to copy items from')
                .setPlaceholder('801000000000000AAA'),
            FieldDescriptor.salesforceId('destinationOrderId')
                .required()
                .help('The Salesforce ID of the order to copy items to')
                .setPlaceholder('801000000000001AAA')
        };
    }

    public override ActionOutcome executeAction(Map<String, Object> params) {
        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();
        args.sourceOrderId = (String) params.get('sourceOrderId');
        args.destinationOrderId = (String) params.get('destinationOrderId');

        if (String.isBlank(args.sourceOrderId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'sourceOrderId parameter is required');
        }
        if (String.isBlank(args.destinationOrderId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'destinationOrderId parameter is required');
        }

        Id sourceOrderId;
        Id destinationOrderId;
        try {
            sourceOrderId = Id.valueOf(args.sourceOrderId);
            destinationOrderId = Id.valueOf(args.destinationOrderId);
        } catch (Exception e) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid order ID format');
        }

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

    /**
     * @description
     * Provides self-description with JSON schemas and field descriptors for dynamic UI generation.
     * Uses AutoDescriptor for simplified schema generation from DTO metadata.
     *
     * @return ActionDescription with complete configuration and parameter schemas
     */
    public override ActionDescription describe() {
        return new AutoDescriptor()
            .loadFromMetadata('ActionCloneOrderItems')  // Loads label, description, guidance from metadata
            .setConfigFields(new List<FieldDescriptor>()) // No config needed
            .setParameterFields(describeArguments())
            .toActionDescription();
    }
}
