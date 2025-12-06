/**
 * @description Context provider for Case records. Used by AgentTestDataFactory for showcasing agents.
 * Returns Case details including key fields for AI agent context.
 * 
 * @implements IAgentContextProvider
 */
public class CaseContext implements IAgentContextProvider {
    /**
     * @description Retrieves Case context for the given anchor IDs
     * @param anchorIds Set of Case IDs to retrieve context for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map of context labels to lists of Case records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query Case records with key fields
            List<Case> cases = [
                SELECT 
                    Id, 
                    CaseNumber, 
                    Subject, 
                    Description, 
                    Status, 
                    Priority, 
                    Origin,
                    Type,
                    Reason,
                    CreatedDate,
                    ClosedDate,
                    AccountId,
                    ContactId,
                    OwnerId
                FROM Case 
                WHERE Id IN :anchorIds 
                WITH USER_MODE
                LIMIT 200
            ];

            if (!cases.isEmpty()) {
                result.put('Case Details', cases);
            }

            System.debug('[CaseContext] Retrieved ' + cases.size() + ' case(s) for ' + anchorIds.size() + ' anchor(s)');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[CaseContext] Error retrieving cases: ' + e.getMessage());
        }

        return result;
    }
}


