/**
 * @description Simulates an asynchronous callout to an external shipping provider to expedite an order.
 *              This action demonstrates handling user confirmation and long-running processes.
 * @extends BaseAgentAction
 */
public class ActionExpediteShipping extends BaseAgentAction {
    /**
     * @description The framework automatically extracts and validates the 'orderId' parameter.
     *              This method simulates a delay and returns a mock tracking number.
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Id orderId = (Id) params.get('orderId');

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
}
