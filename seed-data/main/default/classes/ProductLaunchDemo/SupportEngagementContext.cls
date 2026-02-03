/**
 * @description Context provider for Product Launch Orchestrator demo
 *              Fetches Support Case history for engagement analysis
 *
 * This provider returns support case context:
 * - Recent cases (last 90 days)
 * - Case priority and type distribution
 * - Support engagement signals (demos, questions, POCs)
 *
 * @implements IAgentContextProvider
 * @author Sonal
 * @since January 2026
 */
public class SupportEngagementContext implements IAgentContextProvider {
    /**
     * @description Retrieves Case context for engagement analysis
     * @param anchorIds Set of Account IDs to retrieve cases for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map with 'Support Cases' key containing Case records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query recent cases (last 90 days)
            Date cutoffDate = Date.today().addDays(-90);

            List<Case> cases = [
                SELECT
                    Id,
                    CaseNumber,
                    AccountId,
                    Account.Name,
                    Subject,
                    Description,
                    Status,
                    Priority,
                    Origin,
                    Type,
                    Reason,
                    IsClosed,
                    IsEscalated,
                    CreatedDate,
                    ClosedDate
                FROM Case
                WHERE AccountId IN :anchorIds AND (IsClosed = FALSE OR CreatedDate >= :cutoffDate)
                WITH USER_MODE
                ORDER BY IsClosed ASC, CreatedDate DESC
                LIMIT 200
            ];

            if (!cases.isEmpty()) {
                result.put('Support Cases', cases);
            }

            System.debug('[SupportEngagementContext] Retrieved ' + cases.size() + ' case(s)');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[SupportEngagementContext] Error: ' + e.getMessage());
        }

        return result;
    }
}
