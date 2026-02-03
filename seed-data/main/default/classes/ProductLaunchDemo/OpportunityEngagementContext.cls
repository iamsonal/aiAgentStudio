/**
 * @description Context provider for Product Launch Orchestrator demo
 *              Fetches Opportunity and pipeline data for engagement analysis
 *
 * This provider returns opportunity context for engagement analysis:
 * - Open opportunities (Stage, Amount, CloseDate, Probability)
 * - Historical opportunities (won/lost patterns)
 * - Pipeline value and opportunity count
 *
 * @implements IAgentContextProvider
 * @author Sonal
 * @since January 2026
 */
public class OpportunityEngagementContext implements IAgentContextProvider {
    /**
     * @description Retrieves Opportunity context for engagement analysis
     * @param anchorIds Set of Account IDs to retrieve opportunities for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map with 'Opportunities' key containing Opportunity records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query recent opportunities (last 12 months)
            Date cutoffDate = Date.today().addMonths(-12);

            List<Opportunity> opportunities = [
                SELECT
                    Id,
                    Name,
                    AccountId,
                    Account.Name,
                    StageName,
                    Amount,
                    Probability,
                    CloseDate,
                    Type,
                    LeadSource,
                    Description,
                    IsClosed,
                    IsWon,
                    CreatedDate,
                    LastModifiedDate
                FROM Opportunity
                WHERE AccountId IN :anchorIds AND (IsClosed = FALSE OR CloseDate >= :cutoffDate)
                WITH USER_MODE
                ORDER BY IsClosed ASC, CloseDate ASC
                LIMIT 200
            ];

            if (!opportunities.isEmpty()) {
                result.put('Opportunities', opportunities);
            }

            System.debug('[OpportunityEngagementContext] Retrieved ' + opportunities.size() + ' opportunity/ies');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[OpportunityEngagementContext] Error: ' + e.getMessage());
        }

        return result;
    }
}
