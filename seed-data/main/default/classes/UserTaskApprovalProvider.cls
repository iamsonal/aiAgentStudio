// File: classes/UserTaskApprovalProvider.cls
/**
 * @description Provides context related to user's actionable items: open high-priority tasks
 *              and items pending their approval. Designed for user-anchored context.
 * @implements IAgentContextProvider
 */
public inherited sharing class UserTaskApprovalProvider implements IAgentContextProvider {
    private static final String LOG_PREFIX = '[UserTaskApprovalCtx] ';
    private static final Integer TASK_LIMIT = 5;
    private static final Integer APPROVAL_LIMIT = 5;
    private static final String HIGH_PRIORITY_TASK = 'High'; // Align with actual picklist API name
    private static final String TASK_NOT_COMPLETED_STATUS = 'Completed'; // Align if different

    // Context Block Labels
    private static final String LABEL_HIGH_PRI_TASKS = 'My High Priority Tasks';
    private static final String LABEL_PENDING_APPROVALS = 'Items Pending My Approval';

    public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson) {
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Getting tasks & approvals for User: ' + userId);
        Map<String, List<SObject>> contextBlocks = new Map<String, List<SObject>>();

        if (userId == null) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'User ID is null.');
            return contextBlocks;
        }

        // --- 1. Get High Priority Tasks ---
        try {
            // Reusing Task query logic, consider creating a shared Task utility if needed often
            List<Task> highPriTasks = [
                SELECT Id, Subject, Status, Priority, ActivityDate, Who.Name, What.Name
                FROM Task
                WHERE OwnerId = :userId AND Priority = :HIGH_PRIORITY_TASK AND Status != :TASK_NOT_COMPLETED_STATUS
                WITH USER_MODE
                ORDER BY ActivityDate ASC NULLS FIRST, Subject ASC
                LIMIT :TASK_LIMIT
            ];
            if (!highPriTasks.isEmpty()) {
                contextBlocks.put(LABEL_HIGH_PRI_TASKS, highPriTasks);
                System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Fetched ' + highPriTasks.size() + ' high priority tasks.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error fetching Tasks: ' + e.getMessage());
        }

        // --- 2. Get Items Pending User's Approval ---
        try {
            // Find work items assigned directly to the user
            List<ProcessInstanceWorkitem> pendingApprovals = [
                SELECT
                    Id,
                    ProcessInstanceId,
                    ProcessInstance.TargetObject.Name,
                    ProcessInstance.TargetObject.Type, // Get SObject type name
                    CreatedDate,
                    ActorId // ActorId should match userId here
                FROM ProcessInstanceWorkitem
                WHERE ActorId = :userId
                WITH // No implicit Status field, rely on it being an open workitem
                USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT :APPROVAL_LIMIT
            ];

            if (!pendingApprovals.isEmpty()) {
                // Return the ProcessInstanceWorkitem records directly
                // The formatting service will need to extract relevant info like TargetObject Name/Type
                contextBlocks.put(LABEL_PENDING_APPROVALS, pendingApprovals);
                System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Fetched ' + pendingApprovals.size() + ' pending approvals.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error fetching Pending Approvals: ' + e.getMessage());
        }

        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Finished. Returning ' + contextBlocks.size() + ' blocks.');
        return contextBlocks;
    }
}
