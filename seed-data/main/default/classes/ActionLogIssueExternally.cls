/**
 * @description Simulates logging a case in an external system like Jira.
 *              This is designed to be an ASYNCHRONOUS action to showcase the framework's ability
 *              to handle long-running processes that involve API callouts.
 * @extends BaseAgentAction
 */
public class ActionLogIssueExternally extends BaseAgentAction {
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
        public String caseId;
    }

    /**
     * Returns field descriptors for ArgumentsDTO
     */
    private static List<FieldDescriptor> describeArguments() {
        return new List<FieldDescriptor>{
            FieldDescriptor.salesforceId('caseId')
                .required()
                .help('The Salesforce ID of the case to log in the external system')
                .setPlaceholder('500000000000000AAA')
        };
    }

    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically:
     *              - Extracts 'caseId' parameter and validates it's a valid ID
     *              - Checks user has READ access to Case object
     *              - Handles all errors and wraps results in Result format
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();
        args.caseId = (String) params.get('caseId');

        if (String.isBlank(args.caseId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'caseId parameter is required');
        }

        Id caseId;
        try {
            caseId = Id.valueOf(args.caseId);
        } catch (Exception e) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid caseId format: ' + args.caseId);
        }

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

    /**
     * @description
     * Provides self-description with JSON schemas and field descriptors for dynamic UI generation.
     * Uses AutoDescriptor for simplified schema generation from DTO metadata.
     *
     * @return ActionDescription with complete configuration and parameter schemas
     */
    public override ActionDescription describe() {
        return new AutoDescriptor()
            .loadFromMetadata('ActionLogIssueExternally')  // Loads label, description, guidance from metadata
            .setConfigFields(new List<FieldDescriptor>()) // No config needed
            .setParameterFields(describeArguments())
            .toActionDescription();
    }
}
