/**
 * @description Context provider for User details. Used by AgentTestDataFactory for showcasing agents.
 * Returns User details for AI agent context.
 *
 * @implements IAgentContextProvider
 */
public class UserDetailsProvider implements IAgentContextProvider {
    /**
     * @description Retrieves User context for the given anchor IDs (typically the current user)
     * @param anchorIds Set of User IDs to retrieve context for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map of context labels to lists of User records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query User records with key fields
            List<User> users = [
                SELECT
                    Id,
                    Name,
                    Username,
                    Email,
                    Phone,
                    Title,
                    Department,
                    Division,
                    CompanyName,
                    UserRole.Name,
                    Profile.Name,
                    TimeZoneSidKey,
                    LocaleSidKey,
                    LanguageLocaleKey,
                    IsActive
                FROM User
                WHERE Id IN :anchorIds
                WITH USER_MODE
                LIMIT 50
            ];

            if (!users.isEmpty()) {
                result.put('User Details', users);
            }

            System.debug('[UserDetailsProvider] Retrieved ' + users.size() + ' user(s) for ' + anchorIds.size() + ' anchor(s)');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[UserDetailsProvider] Error retrieving users: ' + e.getMessage());
        }

        return result;
    }
}
