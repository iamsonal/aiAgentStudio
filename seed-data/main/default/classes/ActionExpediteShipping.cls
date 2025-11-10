/**
 * @description Simulates an asynchronous callout to an external shipping provider to expedite an order.
 *              This action demonstrates handling user confirmation and long-running processes.
 * @extends BaseAgentAction
 */
public class ActionExpediteShipping extends BaseAgentAction {
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
        public String orderId;
    }

    /**
     * Returns field descriptors for ArgumentsDTO
     */
    private static List<FieldDescriptor> describeArguments() {
        return new List<FieldDescriptor>{
            FieldDescriptor.salesforceId('orderId')
                .required()
                .help('The Salesforce ID of the order to expedite shipping for')
                .setPlaceholder('801000000000000AAA')
        };
    }

    /**
     * @description The framework automatically extracts and validates the 'orderId' parameter.
     *              This method simulates a delay and returns a mock tracking number.
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();
        args.orderId = (String) params.get('orderId');

        if (String.isBlank(args.orderId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'orderId parameter is required');
        }

        Id orderId;
        try {
            orderId = Id.valueOf(args.orderId);
        } catch (Exception e) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid orderId format: ' + args.orderId);
        }

        try {
            // Simulate the API Callout and long-running process
            Long startTime = System.currentTimeMillis();
            while (System.currentTimeMillis() - startTime < 3000) {
                // Simulate 3-second delay for the external API call
            }

            String trackingNumber = 'EXP-' + String.valueOf(Math.rint(Math.random() * 90000) + 10000).substring(0, 5);

            return ActionOutcome.success(
                new ShippingResult(
                    trackingNumber,
                    'I have successfully submitted the request to expedite shipping. The new tracking number is ' + trackingNumber + '.'
                )
            );
        } catch (Exception ex) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'Failed to expedite shipping: ' + ex.getMessage());
        }
    }

    // Simple result class. The framework automatically uses the 'message' field for the user-facing response.
    public class ShippingResult {
        @AuraEnabled
        public String trackingNumber;
        @AuraEnabled
        public String message;

        public ShippingResult(String trackingNum, String msg) {
            this.trackingNumber = trackingNum;
            this.message = msg;
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
            .loadFromMetadata('ActionExpediteShipping')  // Loads label, description, guidance from metadata
            .setConfigFields(new List<FieldDescriptor>()) // No config needed
            .setParameterFields(describeArguments())
            .toActionDescription();
    }
}
