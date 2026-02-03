/**
 * @description Context provider for Product Launch Orchestrator demo
 *              Fetches Activity timeline (Tasks and Events) for engagement analysis
 *
 * This provider returns activity context:
 * - Recent tasks (last 90 days)
 * - Recent events/meetings
 * - Engagement frequency and recency
 *
 * @implements IAgentContextProvider
 * @author Sonal
 * @since January 2026
 */
public class ActivityTimelineContext implements IAgentContextProvider {
    /**
     * @description Retrieves Activity context (Tasks and Events) for engagement analysis
     * @param anchorIds Set of Account IDs to retrieve activities for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map with 'Activities' key containing Task and Event records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query recent tasks (last 90 days)
            Date cutoffDate = Date.today().addDays(-90);

            List<Task> tasks = [
                SELECT Id, Subject, Description, Status, Priority, ActivityDate, WhatId, What.Name, WhoId, Who.Name, CreatedDate
                FROM Task
                WHERE WhatId IN :anchorIds AND CreatedDate >= :cutoffDate
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 100
            ];

            // Query recent events (last 90 days and future)
            List<Event> events = [
                SELECT Id, Subject, Description, StartDateTime, EndDateTime, WhatId, What.Name, WhoId, Who.Name, CreatedDate
                FROM Event
                WHERE WhatId IN :anchorIds AND (CreatedDate >= :cutoffDate OR StartDateTime >= :Date.today())
                WITH USER_MODE
                ORDER BY StartDateTime DESC
                LIMIT 100
            ];

            // Combine tasks and events into activity list
            List<SObject> activities = new List<SObject>();
            activities.addAll(tasks);
            activities.addAll(events);

            if (!activities.isEmpty()) {
                result.put('Activities', activities);
            }

            System.debug('[ActivityTimelineContext] Retrieved ' + tasks.size() + ' task(s) and ' + events.size() + ' event(s)');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActivityTimelineContext] Error: ' + e.getMessage());
        }

        return result;
    }
}
