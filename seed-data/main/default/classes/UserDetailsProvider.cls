/**
 * @description Provides basic user details, role, manager, and timezone information.
 *              Designed to run in user-anchored context (RequiresRecordContext__c=false).
 * @implements IAgentContextProvider
 */
public inherited sharing class UserDetailsProvider implements IAgentContextProvider {

    private static final String LOG_PREFIX = '[UserDetailsProvider] ';

    // Context Block Labels
    private static final String LABEL_USER_DETAILS = 'Current User Details';
    private static final String LABEL_MANAGER_INFO = 'User Manager Information';
    private static final String LABEL_DELEGATED_APPROVER = 'User Delegated Approver';

    public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson) {
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Getting details for User: ' + userId);
        Map<String, List<SObject>> contextBlocks = new Map<String, List<SObject>>();

        if (userId == null) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'User ID is null.');
            return contextBlocks;
        }

        // --- 1. Get Core User Details including Profile, Role, Manager, Delegated Approver ---
        try {
            // Add fields as needed by the LLM context
            List<User> users = [
                    SELECT
                            Id, Name, Email, Title, Department, Phone, TimeZoneSidKey,
                            Profile.Name,
                            UserRole.Name,
                            ManagerId, Manager.Name, Manager.Email
                    FROM User
                    WHERE Id = :userId
                    WITH USER_MODE
                    LIMIT 1
            ];

            if (!users.isEmpty()) {
                User currentUser = users[0];
                // We return the main user object under LABEL_USER_DETAILS
                // The manager and delegated approver info is contained within it
                // If we wanted separate blocks, we'd extract them.
                contextBlocks.put(LABEL_USER_DETAILS, users);
                System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Fetched core user details. Profile: ' + currentUser.Profile?.Name + ', Role: ' + currentUser.UserRole?.Name);

                // Example of optionally creating separate blocks if desired:
                // if(currentUser.ManagerId != null && currentUser.Manager != null){
                //     contextBlocks.put(LABEL_MANAGER_INFO, new List<User>{currentUser.Manager});
                // }
                // if(currentUser.DelegatedApproverId != null && currentUser.DelegatedApprover != null){
                //     contextBlocks.put(LABEL_DELEGATED_APPROVER, new List<User>{currentUser.DelegatedApprover});
                // }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error fetching User details: ' + e.getMessage());
            // Log & Continue
        }

        // Example: Getting User Queue Memberships (can be limit intensive)
        /* try {
            List<Group> userQueues = [SELECT Id, Name, DeveloperName
                                      FROM Group
                                      WHERE Type = 'Queue'
                                      AND Id IN (SELECT GroupId FROM GroupMember WHERE UserOrGroupId = :userId)
                                      WITH USER_MODE LIMIT 10]; // Limit queue results
            if(!userQueues.isEmpty()){
                 contextBlocks.put('User Queue Memberships', userQueues);
                 System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Fetched ' + userQueues.size() + ' queues.');
            }
        } catch(Exception e){
             System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error fetching User Queues: ' + e.getMessage());
        }*/


        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Finished. Returning ' + contextBlocks.size() + ' blocks.');
        return contextBlocks;
    }
}