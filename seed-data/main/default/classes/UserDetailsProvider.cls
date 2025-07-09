/**
 * @description Provides details about the current user for the AI Agent Framework.
 *              This is a non-record-context provider, meaning it's triggered by the
 *              user's context rather than a specific record's context.
 * @implements IAgentContextProvider
 */
public with sharing class UserDetailsProvider implements IAgentContextProvider {
    /**
     * @description Retrieves details for the current user.
     * @param anchorIds A Set containing the ID of the current user. This is passed by the
     *                  framework for non-record-context providers.
     * @param userId The ID of the user initiating the request (redundant in this provider but part of the interface).
     * @param configurationJson Optional JSON string for custom configuration (not used by this provider).
     * @return A map containing the user's details under the key 'Current User Details'.
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();

        // --- 1. Validate Input ---
        // Best practice for bulk-safe providers is to always check for empty input.
        if (anchorIds == null || anchorIds.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[UserDetailsProvider] Anchor ID set is null or empty. Aborting.');
            return results;
        }

        try {
            // --- 2. Query for User Details (Securely and in Bulk) ---
            // The query now uses 'IN :anchorIds' to adhere to the bulk-safe contract.
            // For this provider, anchorIds will typically contain only the current user's ID.
            List<User> users = [
                SELECT Name, FirstName, Title, Department, Email
                FROM User
                WHERE Id IN :anchorIds
                WITH USER_MODE
                LIMIT 1
            ];

            if (!users.isEmpty()) {
                results.put('Current User Details', users);
            }
        } catch (Exception e) {
            // Log the error but do not throw, allowing the agent to proceed gracefully without this context.
            System.debug(LoggingLevel.ERROR, '[UserDetailsProvider] Failed to query user details. Error: ' + e.getMessage());
        }

        // --- 3. Return the populated map ---
        return results;
    }
}
