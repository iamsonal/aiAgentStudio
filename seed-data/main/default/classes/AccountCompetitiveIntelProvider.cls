/**
 * @description Apex Context Provider for Accounts.
 *              Provides a HARDCODED summary of competitive intelligence
 *              related to the Account. In a real scenario, this would involve
 *              complex queries, logic, or external callouts.
 * @implements IAgentContextProvider
 */
public class AccountCompetitiveIntelProvider implements IAgentContextProvider {
    /**
     * @description Retrieves context data based on the Account anchor.
     *              Returns a hardcoded competitive summary packaged in a Note SObject.
     *
     * @param anchorId The Salesforce ID of the anchor Account record.
     * @param userId The Salesforce ID of the user initiating the request.
     * @param configurationJson Optional JSON configuration (ignored in this example).
     *
     * @return Map containing a List with one Note SObject holding the summary.
     *         Returns an empty map if the anchor is not a valid Account.
     */
    public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson) {
        final String logPrefix = '[AccountCompetitiveIntelProvider Anchor:' + anchorId + '] ';
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();

        // --- 1. Validate Anchor is an Account ---
        if (anchorId == null || anchorId.getSObjectType() != Account.SObjectType) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Anchor ID is null or not an Account. Skipping.');
            return results; // Return empty map
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Generating hardcoded competitive intelligence context.');

        // --- 2. Prepare Hardcoded Data ---
        // In a real scenario, query data sources and apply logic here.
        String competitorSummary = 'Key Competitors Identified: Quantum Dynamics, Synergy Solutions.';
        String winLossNotes = 'Recent Activity: Lost Q2 server deal to Quantum (pricing). Won Q3 integration project vs Synergy (features/support).';
        String differentiators = 'Key Differentiators vs Competitors: Emphasize platform scalability, dedicated support model, and strong integration ecosystem.';
        String intelSource = '(Intelligence based on internal QBR notes and competitive tracker - Simulated Data)';

        String combinedContent = competitorSummary + '\n' + winLossNotes + '\n' + differentiators + '\n\n' + intelSource;

        // --- 3. Package data into a standard SObject (Note) ---
        // The IAgentContextProvider interface requires returning a List<SObject>.
        // We use a Note record here as a simple container. It's not saved to the database.
        Note intelNote = new Note(
            // Do NOT set an Id or ParentId. This is just a data container.
            Title = 'Account Competitive Intelligence Summary (Simulated)', // Title for clarity
            Body = combinedContent // The hardcoded summary
        );

        List<SObject> notesList = new List<SObject>{ intelNote };

        // --- 4. Populate Return Map ---
        // Use a descriptive label for the context block presented to the agent.
        results.put('Competitive Intelligence Summary', notesList);

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Returning hardcoded context: ' + combinedContent.abbreviate(200));
        return results;
    }
}
