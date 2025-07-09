/**
 * @description Custom Action: Simulates logging a case in an external system like Jira.
 *              This is designed to be an ASYNCHRONOUS action to showcase the framework's ability
 *              to handle long-running processes that involve API callouts.
 * @extends BaseAgentAction
 */
public class ActionLogIssueExternally extends BaseAgentAction {
    protected override String getLogPrefixName() {
        return 'ActionLogIssueExternally';
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        // No specific configuration is needed for this action.
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
    }

    /**
     * @description Inner class to hold parsed arguments.
     */
    private class LogIssueArgs extends BaseAgentAction.ParsedArguments {
        Id caseId;
        public LogIssueArgs(String jsonArguments) {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonArguments);
            this.caseId = ParameterExtractionUtils.getRequiredId(parsed, 'caseId', Case.SObjectType);
        }
    }

    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        try {
            // *** FIXED: Use the correct parameter name 'argumentsJson' ***
            return new LogIssueArgs(argumentsJson);
        } catch (Exception e) {
            throw new ValidationException('Failed to parse arguments for External Logging: ' + e.getMessage(), null, e);
        }
    }

    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        // The framework runs this method inside a Queueable job because the capability
        // is marked as "Run Asynchronously". This means we can perform callouts here.

        LogIssueArgs args = (LogIssueArgs) validatedArgs;

        // 1. Get Case details to include in the simulated external log.
        Case caseToLog = [SELECT Id, CaseNumber, Subject FROM Case WHERE Id = :args.caseId WITH USER_MODE LIMIT 1];
        if (caseToLog == null) {
            return this.runtimeError('Case ' + args.caseId + ' not found or inaccessible.', AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, null);
        }

        // 2. Simulate the API Callout and long-running process.
        System.debug(LoggingLevel.INFO, logPrefix + 'Simulating API callout to external system for Case: ' + caseToLog.CaseNumber);

        // Use a "busy wait" to simulate a 4-second network delay.
        // WARNING: This consumes CPU time and is only for demonstration purposes.
        Long startTime = System.currentTimeMillis();
        while (System.currentTimeMillis() - startTime < 4000) {
            // Looping to simulate work
        }

        // 3. Construct a successful result.
        // In a real scenario, this would come from the external API's response.
        String externalTicketId = 'JIRA-' + String.valueOf(Math.rint(Math.random() * 9000) + 1000).substring(0, 4);

        Map<String, Object> outputPayload = new Map<String, Object>{
            'status' => 'SUCCESS',
            'externalTicketId' => externalTicketId,
            'message' => 'Successfully logged case ' +
            caseToLog.CaseNumber +
            ' in external system.'
        };

        String messageForUser =
            'I have successfully logged this issue in our external tracking system as ticket ' +
            externalTicketId +
            '. Our engineering team will be notified.';
        String internalDetails = 'Simulated callout to Jira for Case ' + caseToLog.CaseNumber + ' succeeded. External ID: ' + externalTicketId;

        return this.success(outputPayload, messageForUser, internalDetails);
    }
}
