/**
 * @description Provides comprehensive details about the current user, adapting its context
 *              gathering based on whether the user is internal or an external community member.
 *              For community users, it fetches associated Contact, Account, recent Orders, open Cases, and Assets.
 * @implements IAgentContextProvider
 */
public with sharing class UserDetailsProvider implements IAgentContextProvider {
    private static final Integer RELATED_RECORD_LIMIT = 3;
    private static final Integer ASSET_LIMIT = 25; // Limit for assets to prevent excessive data

    /**
     * @description Retrieves context for a set of User IDs.
     * @param anchorIds A Set containing the ID of the current user.
     * @param userId The ID of the user initiating the request.
     * @param configurationJson Optional JSON string for custom configuration (not used).
     * @return A map containing a rich set of user-related data.
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> results = new Map<String, List<SObject>>();
        if (anchorIds == null || anchorIds.isEmpty()) {
            return results;
        }

        Id targetUserId = anchorIds.iterator().next();

        try {
            // --- 1. Query the User record to get core details and determine user type ---
            List<User> users = [
                SELECT Name, FirstName, Title, Department, Email, UserType, ContactId, AccountId
                FROM User
                WHERE Id = :targetUserId
                WITH USER_MODE
                LIMIT 1
            ];

            if (users.isEmpty()) {
                System.debug(LoggingLevel.WARN, '[UserDetailsProvider] Could not find User record for ID: ' + targetUserId);
                return results;
            }
            User currentUser = users[0];
            results.put('Current User Details', users);

            // --- 2. If it's a Community User, fetch their rich context ---
            if (currentUser.UserType == 'CSPLitePortal' && currentUser.ContactId != null) {
                // --- 2a. Fetch associated Contact ---
                List<Contact> contacts = [SELECT Id, Name, AccountId FROM Contact WHERE Id = :currentUser.ContactId WITH USER_MODE];
                if (!contacts.isEmpty()) {
                    results.put('User Contact Record', contacts);

                    // --- 2b. Use the Contact's AccountId to fetch deeper context ---
                    Id accountId = contacts[0].AccountId;
                    if (accountId != null) {
                        // --- Fetch Account Details ---
                        List<Account> accounts = [SELECT Id, Name, Industry FROM Account WHERE Id = :accountId WITH USER_MODE];
                        if (!accounts.isEmpty()) {
                            results.put('User Account Record', accounts);
                        }

                        // === START OF THE CRITICAL ADDITION ===
                        // --- Fetch Customer Assets for the Account ---
                        List<Asset> assets = [
                            SELECT Id, Name, SerialNumber, Status, InstallDate, Product2.Name
                            FROM Asset
                            WHERE AccountId = :accountId
                            WITH USER_MODE
                            ORDER BY CreatedDate DESC
                            LIMIT :ASSET_LIMIT
                        ];
                        if (!assets.isEmpty()) {
                            results.put('Customer Assets', assets);
                        }
                        // === END OF THE CRITICAL ADDITION ===

                        // --- Fetch Recent Orders for the Account ---
                        List<Order> recentOrders = [
                            SELECT
                                Id,
                                OrderNumber,
                                Status,
                                TotalAmount,
                                EffectiveDate,
                                (
                                    SELECT Quantity, UnitPrice, PricebookEntry.Product2.Name, PricebookEntry.Product2.ProductCode
                                    FROM OrderItems
                                )
                            FROM Order
                            WHERE AccountId = :accountId
                            WITH USER_MODE
                            ORDER BY EffectiveDate DESC
                            LIMIT 3 // Keep the limit reasonable for context size
                        ];
                        if (!recentOrders.isEmpty()) {
                            results.put('Recent Orders', recentOrders);
                        }

                        // --- Fetch Open Cases for the Account ---
                        List<Case> openCases = [
                            SELECT Id, CaseNumber, Subject, Status, Priority
                            FROM Case
                            WHERE AccountId = :accountId AND IsClosed = FALSE
                            WITH USER_MODE
                            ORDER BY CreatedDate DESC
                            LIMIT :RELATED_RECORD_LIMIT
                        ];
                        if (!openCases.isEmpty()) {
                            results.put('Open Support Cases', openCases);
                        }
                    }
                }
            } else {
                System.debug(LoggingLevel.INFO, '[UserDetailsProvider] User is internal or has no associated Contact. Providing User details only.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[UserDetailsProvider] Failed to query full user context. Error: ' + e.getMessage());
        }

        return results;
    }
}
