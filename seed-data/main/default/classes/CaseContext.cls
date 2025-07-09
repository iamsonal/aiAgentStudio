/**
 * @description (BULK-SAFE) Provides the core details for a set of Case records.
 *              This is typically used when the user is viewing a specific Case page.
 * @implements IAgentContextProvider
 */
public with sharing class CaseContext implements IAgentContextProvider {
    /**
     * @description Retrieves context data for a set of Case records.
     * @param anchorIds A Set of record IDs. This provider will filter for and process only the Case IDs.
     * @param userId The ID of the user initiating the request.
     * @param configurationJson Optional JSON string for custom configuration (not used).
     * @return A map containing the Case details under the key 'Current Case Details'.
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();

        // --- 1. Validate and filter for Case IDs ---
        if (anchorIds == null || anchorIds.isEmpty()) {
            return results;
        }

        Set<Id> caseIds = new Set<Id>();
        for (Id currentId : anchorIds) {
            if (currentId.getSObjectType() == Case.SObjectType) {
                caseIds.add(currentId);
            }
        }

        if (caseIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[CaseContext] Anchor IDs contained no Case records.');
            return results;
        }

        try {
            // --- 2. Query for Case Details (Securely and in Bulk) ---
            // This query fetches rich context about the case, its contact, and the related asset.
            List<Case> cases = [
                SELECT
                    Id,
                    CaseNumber,
                    Subject,
                    Status,
                    Priority,
                    Type,
                    Description,
                    Contact.Name,
                    Contact.Email,
                    Contact.Title,
                    Account.Name,
                    Asset.Name,
                    Asset.SerialNumber,
                    Asset.Product2.Name
                FROM Case
                WHERE Id IN :caseIds
                WITH USER_MODE
                LIMIT 50 // Safeguard against excessively large context sets
            ];

            if (!cases.isEmpty()) {
                results.put('Current Case Details', cases);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[CaseContext] Failed to query Case details. Error: ' + e.getMessage());
            // Do not re-throw; allow the agent to function without this specific context.
        }

        return results;
    }
}
