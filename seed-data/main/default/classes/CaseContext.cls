/**
 * @description Comprehensive context provider for Case records with complete case history.
 * Provides AI agents with full case context including:
 * - Case Details: Core case fields, account, contact, and owner information
 * - Case Comments: Internal notes and customer communications
 * - Email Messages: Email thread history (incoming/outgoing)
 * - Case History: Field changes and audit trail
 *
 * Used by AgentTestDataFactory for showcasing agents with realistic case data.
 *
 * @implements IAgentContextProvider
 */
public class CaseContext implements IAgentContextProvider {
    /**
     * @description Retrieves Case context for the given anchor IDs
     * @param anchorIds Set of Case IDs to retrieve context for
     * @param userId Current user ID
     * @param configurationJson Optional configuration JSON
     * @return Map of context labels to lists of Case records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // Query Case records with key fields
            List<Case> cases = [
                SELECT
                    Id,
                    CaseNumber,
                    Subject,
                    Description,
                    Status,
                    Priority,
                    Origin,
                    Type,
                    Reason,
                    CreatedDate,
                    ClosedDate,
                    AccountId,
                    ContactId,
                    OwnerId,
                    Account.Name,
                    Contact.Name,
                    Contact.Email,
                    Owner.Name
                FROM Case
                WHERE Id IN :anchorIds
                WITH USER_MODE
                LIMIT 200
            ];

            if (!cases.isEmpty()) {
                result.put('Case Details', cases);

                // Query Case Comments (internal notes and customer communications)
                List<CaseComment> caseComments = [
                    SELECT Id, ParentId, CommentBody, IsPublished, CreatedDate, CreatedBy.Name
                    FROM CaseComment
                    WHERE ParentId IN :anchorIds
                    WITH USER_MODE
                    ORDER BY CreatedDate ASC
                    LIMIT 100
                ];

                if (!caseComments.isEmpty()) {
                    result.put('Case Comments', caseComments);
                }

                // Query Email Messages (email threads related to the case)
                List<EmailMessage> emailMessages = [
                    SELECT Id, ParentId, Subject, TextBody, HtmlBody, FromAddress, FromName, ToAddress, CcAddress, Incoming, MessageDate, Status
                    FROM EmailMessage
                    WHERE ParentId IN :anchorIds
                    WITH USER_MODE
                    ORDER BY MessageDate ASC
                    LIMIT 50
                ];

                if (!emailMessages.isEmpty()) {
                    result.put('Email Messages', emailMessages);
                }

                // Query Case History (field changes and updates)
                List<CaseHistory> caseHistory = [
                    SELECT Id, CaseId, Field, OldValue, NewValue, CreatedDate, CreatedBy.Name
                    FROM CaseHistory
                    WHERE CaseId IN :anchorIds
                    WITH USER_MODE
                    ORDER BY CreatedDate ASC
                    LIMIT 100
                ];

                if (!caseHistory.isEmpty()) {
                    result.put('Case History', caseHistory);
                }
            }

            System.debug('[CaseContext] Retrieved ' + cases.size() + ' case(s) with related records for ' + anchorIds.size() + ' anchor(s)');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[CaseContext] Error retrieving cases: ' + e.getMessage());
        }

        return result;
    }
}
