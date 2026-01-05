/**
 * @description Comprehensive context provider for Case records with hierarchical related data.
 *
 * This provider demonstrates best practices for AI agent context:
 * - Uses SOQL subqueries to preserve parent-child relationships
 * - Returns hierarchical data that ContextFormattingService can render as nested structures
 * - Filters low-value data (e.g., 'created' history events with null values)
 * - Limits related records to prevent token bloat
 *
 * Provides AI agents with full case context including:
 * - Case Details: Core case fields, account, contact, and owner information
 * - Case Comments: Internal notes and customer communications (nested)
 * - Email Messages: Email thread history - incoming/outgoing (nested)
 * - Case History: Meaningful field changes and audit trail (nested, filtered)
 *
 * Example Output Structure (when formatted as JSON):
 * {
 *   "cases": [{
 *     "caseNumber": "00001044",
 *     "subject": "API Rate Limits Question",
 *     "account": { "name": "Acme Corp" },
 *     "history": [
 *       { "field": "Priority", "oldValue": "Low", "newValue": "Medium" }
 *     ],
 *     "comments": [...],
 *     "emails": [...]
 *   }]
 * }
 *
 * Used by AgentTestDataFactory for showcasing agents with realistic case data.
 *
 * @implements IAgentContextProvider
 */
public class CaseContext implements IAgentContextProvider {
    // Configuration constants - can be overridden via configurationJson
    private static final Integer DEFAULT_HISTORY_LIMIT = 20;
    private static final Integer DEFAULT_COMMENTS_LIMIT = 20;
    private static final Integer DEFAULT_EMAILS_LIMIT = 10;

    /**
     * @description Retrieves Case context for the given anchor IDs with hierarchical related data.
     * Uses SOQL subqueries to embed child records (History, Comments, Emails) directly within
     * the Case record, preserving the natural parent-child relationship for LLM consumption.
     *
     * @param anchorIds Set of Case IDs to retrieve context for
     * @param userId Current user ID (not used in this provider but required by interface)
     * @param configurationJson Optional JSON to configure limits: {"historyLimit": 20, "commentsLimit": 20, "emailsLimit": 10}
     * @return Map with single 'Cases' key containing Case records with nested children
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        // Parse configuration if provided
        Integer historyLimit = DEFAULT_HISTORY_LIMIT;
        Integer commentsLimit = DEFAULT_COMMENTS_LIMIT;
        Integer emailsLimit = DEFAULT_EMAILS_LIMIT;

        if (String.isNotBlank(configurationJson)) {
            try {
                Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(configurationJson);
                if (config.containsKey('historyLimit')) {
                    historyLimit = (Integer) config.get('historyLimit');
                }
                if (config.containsKey('commentsLimit')) {
                    commentsLimit = (Integer) config.get('commentsLimit');
                }
                if (config.containsKey('emailsLimit')) {
                    emailsLimit = (Integer) config.get('emailsLimit');
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[CaseContext] Failed to parse configurationJson: ' + e.getMessage());
            }
        }

        try {
            // Query Case records with ALL related data using subqueries
            // This preserves hierarchical relationships - children are embedded in parent
            List<Case> cases = [
                SELECT
                    // Core Case fields
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
                    // Parent lookups - ContextFormattingService will flatten these with path notation
                    Account.Name,
                    Contact.Name,
                    Contact.Email,
                    Owner.Name,
                    // Child relationship: Case History (filtered to meaningful changes)
                    // Note: 'created' events are filtered out for token efficiency
                    // OldValue/NewValue cannot be filtered in SOQL (polymorphic fields)
                    (
                        SELECT Id, Field, OldValue, NewValue, CreatedDate, CreatedBy.Name
                        FROM Histories
                        WHERE Field != 'created'
                        ORDER BY CreatedDate DESC
                        LIMIT :historyLimit
                    ),
                    // Child relationship: Case Comments
                    (
                        SELECT Id, CommentBody, IsPublished, CreatedDate, CreatedBy.Name
                        FROM CaseComments
                        ORDER BY CreatedDate DESC
                        LIMIT :commentsLimit
                    ),
                    // Child relationship: Email Messages (text body only, no HTML for token efficiency)
                    (
                        SELECT Id, Subject, TextBody, FromAddress, FromName, ToAddress, Incoming, MessageDate, Status
                        FROM EmailMessages
                        ORDER BY MessageDate DESC
                        LIMIT :emailsLimit
                    )
                FROM Case
                WHERE Id IN :anchorIds
                WITH USER_MODE
                LIMIT 200
            ];

            if (!cases.isEmpty()) {
                // Single key with hierarchical data - ContextFormattingService handles child relationships
                result.put('Cases', cases);
            }

            System.debug('[CaseContext] Retrieved ' + cases.size() + ' case(s) with nested related records for ' + anchorIds.size() + ' anchor(s)');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[CaseContext] Error retrieving cases: ' + e.getMessage());
        }

        return result;
    }
}
