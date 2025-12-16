/**
 * @description Comprehensive context provider for Lead records with complete lead history.
 * Provides AI agents with full lead context including:
 * - Lead Details: Core lead fields, company info, contact details
 * - Tasks: Follow-up activities and engagement tracking
 * - Notes: Sales notes and conversation history
 * - Campaign Members: Marketing campaign engagement
 * - Lead History: Field changes and audit trail
 * 
 * Used by AgentTestDataFactory for showcasing lead qualification agents.
 * 
 * @implements IAgentContextProvider
 */
public class LeadContext implements IAgentContextProvider {
    /**
     * @description Retrieves Lead context for the given anchor IDs
     * @param anchorIds Set of Lead IDs to retrieve context for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map of context labels to lists of Lead records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query Lead records with key fields
            List<Lead> leads = [
                SELECT 
                    Id, 
                    FirstName,
                    LastName,
                    Name,
                    Company, 
                    Title,
                    Email,
                    Phone,
                    Status, 
                    Rating,
                    LeadSource,
                    Industry,
                    NumberOfEmployees,
                    AnnualRevenue,
                    Description,
                    Street,
                    City,
                    State,
                    PostalCode,
                    Country,
                    Website,
                    CreatedDate,
                    LastModifiedDate,
                    Owner.Name
                FROM Lead 
                WHERE Id IN :anchorIds 
                WITH USER_MODE
                LIMIT 200
            ];

            if (!leads.isEmpty()) {
                result.put('Lead Details', leads);
                
                // Query Tasks (calls, meetings, follow-ups)
                List<Task> tasks = [
                    SELECT 
                        Id,
                        WhoId,
                        Subject,
                        Description,
                        Status,
                        Priority,
                        ActivityDate,
                        TaskSubtype,
                        CallType,
                        CallDurationInSeconds,
                        CreatedDate,
                        CreatedBy.Name
                    FROM Task
                    WHERE WhoId IN :anchorIds
                    WITH USER_MODE
                    ORDER BY CreatedDate DESC
                    LIMIT 50
                ];
                
                if (!tasks.isEmpty()) {
                    result.put('Activities', tasks);
                }
                
                // Query Notes (sales notes and conversation history)
                // Note: ContentNote requires different approach, using Note for simplicity
                List<Note> notes = [
                    SELECT 
                        Id,
                        ParentId,
                        Title,
                        Body,
                        CreatedDate,
                        CreatedBy.Name,
                        LastModifiedDate
                    FROM Note
                    WHERE ParentId IN :anchorIds
                    WITH USER_MODE
                    ORDER BY CreatedDate DESC
                    LIMIT 50
                ];
                
                if (!notes.isEmpty()) {
                    result.put('Notes', notes);
                }
                
                // Query Campaign Members (marketing engagement)
                List<CampaignMember> campaignMembers = [
                    SELECT 
                        Id,
                        LeadId,
                        Campaign.Name,
                        Campaign.Type,
                        Status,
                        HasResponded,
                        FirstRespondedDate,
                        CreatedDate
                    FROM CampaignMember
                    WHERE LeadId IN :anchorIds
                    WITH USER_MODE
                    ORDER BY CreatedDate DESC
                    LIMIT 20
                ];
                
                if (!campaignMembers.isEmpty()) {
                    result.put('Campaign Engagement', campaignMembers);
                }
                
                // Query Lead History (field changes and updates)
                List<LeadHistory> leadHistory = [
                    SELECT 
                        Id,
                        LeadId,
                        Field,
                        OldValue,
                        NewValue,
                        CreatedDate,
                        CreatedBy.Name
                    FROM LeadHistory
                    WHERE LeadId IN :anchorIds
                    WITH USER_MODE
                    ORDER BY CreatedDate ASC
                    LIMIT 100
                ];
                
                if (!leadHistory.isEmpty()) {
                    result.put('Lead History', leadHistory);
                }
            }

            System.debug('[LeadContext] Retrieved ' + leads.size() + ' lead(s) with related records for ' + anchorIds.size() + ' anchor(s)');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[LeadContext] Error retrieving leads: ' + e.getMessage());
        }

        return result;
    }
}




