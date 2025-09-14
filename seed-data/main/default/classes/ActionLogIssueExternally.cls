/**
 * @description Simulates logging a case in an external system like Jira.
 *              This is designed to be an ASYNCHRONOUS action to showcase the framework's ability
 *              to handle long-running processes that involve API callouts.
 * @extends BaseAgentAction
 */
public class ActionLogIssueExternally extends BaseAgentAction {
    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically:
     *              - Extracts 'caseId' parameter and validates it's a valid ID
     *              - Checks user has READ access to Case object
     *              - Handles all errors and wraps results in Result format
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        // Framework automatically validates caseId parameter and checks security
        Id caseId = (Id) params.get('caseId');

        try {
            // Get Case details
            Case caseToLog = [SELECT Id, CaseNumber, Subject FROM Case WHERE Id = :caseId WITH USER_MODE LIMIT 1];

            // Simulate the API Callout and long-running process
            Long startTime = System.currentTimeMillis();
            while (System.currentTimeMillis() - startTime < 4000) {
                // Simulate 4-second delay
            }

            // Generate external ticket ID
            String externalTicketId = 'JIRA-' + String.valueOf(Math.rint(Math.random() * 9000) + 1000).substring(0, 4);

            // Return simple result - framework wraps it automatically
            return ActionOutcome.success(
                new ExternalLogResult(
                    externalTicketId,
                    'I have successfully logged this issue in our external tracking system as ticket ' +
                        externalTicketId +
                        '. Our engineering team will be notified.'
                )
            );
        } catch (QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to query case details: ' + qEx.getMessage());
        } catch (Exception ex) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Failed to log issue externally: ' + ex.getMessage());
        }
    }

    // Simple result class - framework extracts 'message' field automatically
    public class ExternalLogResult {
        public String externalTicketId;
        public String message; // Framework uses this for user display

        public ExternalLogResult(String ticketId, String msg) {
            this.externalTicketId = ticketId;
            this.message = msg;
        }
    }
}
