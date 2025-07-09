/**
 * @description (BULK-SAFE) Provides a 360-degree support view for a set of Account records.
 *              It retrieves the most recent open/closed cases and all associated assets to give
 *              the agent a complete picture of the customer's history and installed products.
 * @implements IAgentContextProvider
 */
public with sharing class AccountSupportContext implements IAgentContextProvider {
    private static final Integer RELATED_CASE_LIMIT = 5;
    private static final Integer RELATED_ASSET_LIMIT = 25; // Limit to prevent excessive data for very large customers
    private static final Integer MAX_ACCOUNTS_TO_PROCESS = 25;

    /**
     * @description Retrieves related case history and all assets for a given set of Account IDs.
     * @param anchorIds A Set of IDs, from which this provider will only process Account IDs.
     * @param userId The ID of the user initiating the request.
     * @param configurationJson Custom configuration JSON (unused).
     * @return Map containing lists of recent cases and all customer assets.
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> contextResults = new Map<String, List<SObject>>();

        // --- 1. Validate and filter for Account IDs ---
        if (anchorIds == null || anchorIds.isEmpty()) {
            return contextResults;
        }

        Set<Id> accountIds = new Set<Id>();
        for (Id currentId : anchorIds) {
            if (currentId.getSObjectType() == Account.SObjectType) {
                accountIds.add(currentId);
            }
        }

        // Add accounts from any cases in the anchorIds
        Set<Id> caseIdsForAccountLookup = new Set<Id>();
        for (Id currentId : anchorIds) {
            if (currentId.getSObjectType() == Case.SObjectType) {
                caseIdsForAccountLookup.add(currentId);
            }
        }

        if (!caseIdsForAccountLookup.isEmpty()) {
            for (Case c : [SELECT AccountId FROM Case WHERE Id IN :caseIdsForAccountLookup AND AccountId != NULL]) {
                accountIds.add(c.AccountId);
            }
        }

        if (accountIds.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[AccountSupportContext] Anchor IDs resolved to no Account records.');
            return contextResults;
        }

        // --- 2. Fetch All Customer Assets ---
        try {
            List<Asset> assets = [
                SELECT Id, Name, SerialNumber, Status, InstallDate, Product2.Name, Product2.ProductCode
                FROM Asset
                WHERE AccountId IN :accountIds
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT :RELATED_ASSET_LIMIT
            ];

            if (!assets.isEmpty()) {
                contextResults.put('Customer Assets', assets);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AccountSupportContext] Error querying assets: ' + e.getMessage());
        }

        // --- 3. Fetch Recent Open Cases ---
        try {
            List<Case> openCases = [
                SELECT Id, CaseNumber, Subject, Status, Priority, CreatedDate
                FROM Case
                WHERE AccountId IN :accountIds AND IsClosed = FALSE
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT :RELATED_CASE_LIMIT
            ];

            if (!openCases.isEmpty()) {
                contextResults.put('Other Open Support Cases', openCases);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AccountSupportContext] Error querying open cases: ' + e.getMessage());
        }

        // --- 4. Fetch Recently Closed Cases ---
        try {
            List<Case> closedCases = [
                SELECT Id, CaseNumber, Subject, Status, Priority, ClosedDate
                FROM Case
                WHERE AccountId IN :accountIds AND IsClosed = TRUE
                WITH USER_MODE
                ORDER BY ClosedDate DESC
                LIMIT :RELATED_CASE_LIMIT
            ];

            if (!closedCases.isEmpty()) {
                contextResults.put('Recently Closed Support Cases', closedCases);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AccountSupportContext] Error querying closed cases: ' + e.getMessage());
        }

        return contextResults;
    }
}
