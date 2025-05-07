// File: classes/UserServiceContextProvider.cls
/**
 * @description Provides service-related context for a user: recent cases, queues they belong to.
 *              Designed for user-anchored context.
 * @implements IAgentContextProvider
 */
public inherited sharing class UserServiceContextProvider implements IAgentContextProvider {
    private static final String LOG_PREFIX = '[UserServiceContext] ';
    private static final Integer CASE_LIMIT = 5;
    private static final Integer QUEUE_LIMIT = 10;

    // Context Block Labels
    private static final String LABEL_MY_CASES = 'My Recently Modified Cases';
    private static final String LABEL_MY_QUEUES = 'My Queues';

    public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson) {
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Getting service context for User: ' + userId);
        Map<String, List<SObject>> contextBlocks = new Map<String, List<SObject>>();

        if (userId == null) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'User ID is null.');
            return contextBlocks;
        }

        // --- 1. Get Recent Cases Assigned to User ---
        try {
            // Cases owned by the user, not closed, ordered by last modification
            List<Case> recentCases = [
                SELECT Id, CaseNumber, Subject, Status, Priority, Account.Name, LastModifiedDate
                FROM Case
                WHERE OwnerId = :userId AND IsClosed = FALSE
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :CASE_LIMIT
            ];
            if (!recentCases.isEmpty()) {
                contextBlocks.put(LABEL_MY_CASES, recentCases);
                System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Fetched ' + recentCases.size() + ' recent cases.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error fetching User Cases: ' + e.getMessage());
        }

        // --- 2. Get Queues User Belongs To ---
        try {
            // Efficiently query GroupMember then Group
            List<Id> queueIds = new List<Id>();
            for (GroupMember member : [SELECT GroupId FROM GroupMember WHERE UserOrGroupId = :userId]) {
                queueIds.add(member.GroupId);
            }

            if (!queueIds.isEmpty()) {
                List<Group> userQueues = [
                    SELECT Id, Name, DeveloperName
                    FROM Group
                    WHERE Type = 'Queue' AND Id IN :queueIds
                    WITH USER_MODE // Ensure user can see the queues they are in
                    LIMIT :QUEUE_LIMIT
                ];
                if (!userQueues.isEmpty()) {
                    contextBlocks.put(LABEL_MY_QUEUES, userQueues);
                    System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Fetched ' + userQueues.size() + ' user queues.');
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error fetching User Queues: ' + e.getMessage());
        }

        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Finished. Returning ' + contextBlocks.size() + ' blocks.');
        return contextBlocks;
    }
}
