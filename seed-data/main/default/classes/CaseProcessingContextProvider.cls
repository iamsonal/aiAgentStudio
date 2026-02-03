/**
 * @description Consolidated context provider for Case Processing Workflow agents.
 *
 * Provides all necessary context for case triage, assignment, and escalation in a single provider:
 * - Case: Full case details with related history, comments, emails
 * - Account: Customer information including revenue, industry, employee count
 * - Contact: Primary contact details
 * - Entitlement: Active support contracts and SLA tiers
 *
 * This replaces the need for separate "enrichment" agents or multiple context providers.
 * All child agents in the workflow receive this consolidated context automatically.
 *
 * Example Output Structure (formatted as JSON):
 * {
 *   "cases": [{ "caseNumber": "00001234", "subject": "...", "account": {...}, ... }],
 *   "accounts": [{ "name": "Acme Corp", "annualRevenue": 5000000, ... }],
 *   "contacts": [{ "name": "John Smith", "email": "...", "title": "..." }],
 *   "entitlements": [{ "name": "Premium Support - 4hr SLA", "type": "Premium", ... }]
 * }
 *
 * @implements IAgentContextProvider
 */
public class CaseProcessingContextProvider implements IAgentContextProvider {
    /**
     * @description Retrieves comprehensive case processing context for given Case IDs.
     *
     * @param anchorIds Set of Case IDs to retrieve context for
     * @param userId Current user ID (unused but required by interface)
     * @param configurationJson Optional JSON configuration (unused currently)
     * @return Map with keys: 'Cases', 'Accounts', 'Contacts', 'Entitlements'
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        try {
            // 1. Query Case records with nested history/comments
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
                    Owner.Name,
                    // Nested case comments (last 10)
                    (
                        SELECT Id, CommentBody, IsPublished, CreatedDate, CreatedBy.Name
                        FROM CaseComments
                        ORDER BY CreatedDate DESC
                        LIMIT 10
                    ),
                    // Nested case history (last 15 changes, excluding 'created' events)
                    (
                        SELECT Id, Field, OldValue, NewValue, CreatedDate, CreatedBy.Name
                        FROM Histories
                        WHERE Field != 'created'
                        ORDER BY CreatedDate DESC
                        LIMIT 15
                    )
                FROM Case
                WHERE Id IN :anchorIds
                WITH USER_MODE
                LIMIT 200
            ];

            if (!cases.isEmpty()) {
                result.put('Cases', cases);

                // Extract Account IDs and Contact IDs from cases
                Set<Id> accountIds = new Set<Id>();
                Set<Id> contactIds = new Set<Id>();

                for (Case c : cases) {
                    if (c.AccountId != null) {
                        accountIds.add(c.AccountId);
                    }
                    if (c.ContactId != null) {
                        contactIds.add(c.ContactId);
                    }
                }

                // 2. Query Account records (customer intelligence)
                if (!accountIds.isEmpty()) {
                    List<Account> accounts = [
                        SELECT
                            Id,
                            Name,
                            Industry,
                            Type,
                            AccountNumber,
                            Phone,
                            BillingCity,
                            BillingState,
                            BillingCountry,
                            NumberOfEmployees,
                            AnnualRevenue,
                            Website,
                            Description,
                            OwnerId,
                            Owner.Name
                        FROM Account
                        WHERE Id IN :accountIds
                        WITH USER_MODE
                        LIMIT 200
                    ];

                    if (!accounts.isEmpty()) {
                        result.put('Accounts', accounts);
                    }

                    // 3. Query Entitlements (SLA tiers) for these accounts
                    List<Entitlement> entitlements = [
                        SELECT Id, Name, AccountId, Status, StartDate, EndDate, Type, Account.Name
                        FROM Entitlement
                        WHERE AccountId IN :accountIds AND Status = 'Active'
                        WITH USER_MODE
                        LIMIT 200
                    ];

                    if (!entitlements.isEmpty()) {
                        result.put('Entitlements', entitlements);
                    }
                }

                // 4. Query Contact records
                if (!contactIds.isEmpty()) {
                    List<Contact> contacts = [
                        SELECT Id, Name, FirstName, LastName, Email, Phone, MobilePhone, Title, Department, AccountId, Account.Name
                        FROM Contact
                        WHERE Id IN :contactIds
                        WITH USER_MODE
                        LIMIT 200
                    ];

                    if (!contacts.isEmpty()) {
                        result.put('Contacts', contacts);
                    }
                }
            }

            System.debug(
                '[CaseProcessingContextProvider] Retrieved context for ' +
                    anchorIds.size() +
                    ' case(s): ' +
                    result.get('Cases')?.size() +
                    ' cases, ' +
                    result.get('Accounts')?.size() +
                    ' accounts, ' +
                    result.get('Contacts')?.size() +
                    ' contacts, ' +
                    result.get('Entitlements')?.size() +
                    ' entitlements'
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[CaseProcessingContextProvider] Error retrieving context: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, '[CaseProcessingContextProvider] Stack trace: ' + e.getStackTraceString());
        }

        return result;
    }
}
