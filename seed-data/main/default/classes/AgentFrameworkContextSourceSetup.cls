/**
 * @description Creates sample ContextGraphSource__c records for testing the AI Agent Framework.
 *              These records utilize Field Sets created by AgentFrameworkFieldSetSetup and demonstrate
 *              various configurations (Declarative, Apex, Record/User Anchored, Links, Filters, Orders).
 *
 */
public class AgentFrameworkContextSourceSetup {

    public static void runContextSourceSetup() {
        System.debug('Starting ContextGraphSource__c sample data creation...');

        List<ContextGraphSource__c> sourcesToCreate = new List<ContextGraphSource__c>();

// --- Field Set Names (Ensure these match AgentFrameworkFieldSetSetup) ---
        String fsAccSalesHeader = 'FsAccountSalesHeader';
        String fsOppListItem = 'FsOpportunityListItem';
        String fsOppDetail = 'FsOpportunityDetail';
        String fsOppLineItemDetail = 'FsOpportunityLineItemDetail';
        String fsConListItem = 'FsContactListItem';
        String fsConDetail = 'FsContactDetail';
        String fsCaseListItem = 'FsCaseListItem';
        String fsTaskListItem = 'FsTaskListItem';
        String fsEventUpcoming = 'FsEventUpcomingSummary';
        String fsUserSales = 'FsUserSales';


        // === SCENARIO 1: Opportunity Record - Direct Details ===
        // Type: Declarative, Record Anchored (Opportunity), Direct Link
        // Use Case: Show core details of the current Opportunity being viewed.
        sourcesToCreate.add(new ContextGraphSource__c(
                ContextLabel__c = 'Opportunity Core Details (Current)',
                SourceDeveloperName__c = 'Opp_Detail_Direct',
                IsActive__c = true,
                Description__c = 'Displays key fields from the current Opportunity record.',
                ImplementationType__c = 'Declarative',
                SourceType__c = 'Record Anchored',
                StartingSObjectApiName__c = 'Opportunity',
                TargetSObjectApiName__c = 'Opportunity',     // Target is the Opportunity itself
                TargetFieldSetName__c = fsOppDetail,        // Use the detailed Field Set
                LinkType__c = 'Direct',                     // Direct link to the anchor record
                LinkDetailApiName__c = null,                // Link Detail must be null for Direct
                ExecutionOrder__c = 10
        ));

        // === SCENARIO 2: Opportunity Record - Parent Account Header ===
        // Type: Declarative, Record Anchored (Opportunity), Parent Lookup Link
        // Use Case: When viewing an Opportunity, show key details of its parent Account.
        sourcesToCreate.add(new ContextGraphSource__c(
                ContextLabel__c = 'Parent Account Header (Opp Context)',
                SourceDeveloperName__c = 'Opp_ParentAccount_Header',
                IsActive__c = true,
                Description__c = 'From an Opportunity, displays header info for the parent Account.',
                ImplementationType__c = 'Declarative',
                SourceType__c = 'Record Anchored',
                StartingSObjectApiName__c = 'Opportunity',
                TargetSObjectApiName__c = 'Account',         // Target is Account
                TargetFieldSetName__c = fsAccSalesHeader,   // Use Account header Field Set
                LinkType__c = 'Parent Lookup',               // Link via parent lookup
                LinkDetailApiName__c = 'AccountId',         // The API name of the lookup field on Opportunity
                ExecutionOrder__c = 20,
                RecordLimit__c = 1 // Only one parent account
        ));

        // === SCENARIO 3: Account Record - Open Related Cases (Filtered & Ordered) ===
        // Type: Declarative, Record Anchored (Account), Child Relationship Link
        // Use Case: When viewing an Account, show recent, open, high/medium priority related Cases.
        sourcesToCreate.add(new ContextGraphSource__c(
                ContextLabel__c = 'Account Open Cases (Filtered/Ordered)',
                SourceDeveloperName__c = 'Account_OpenCases_FilteredOrdered',
                IsActive__c = true,
                Description__c = 'Displays open Cases related to the current Account, ordered by Priority then Date.',
                ImplementationType__c = 'Declarative',
                SourceType__c = 'Record Anchored',
                StartingSObjectApiName__c = 'Account',
                TargetSObjectApiName__c = 'Case',            // Target is Case
                TargetFieldSetName__c = fsCaseListItem,     // Use Case list Field Set
                LinkType__c = 'Child Relationship',          // Link via child relationship
                LinkDetailApiName__c = 'Cases',             // Standard relationship name Account -> Cases
                ExecutionOrder__c = 30,
                RecordLimit__c = 5,                         // Limit results
                FilterBy__c = '[{"field":"IsClosed","operator":"=","value":false}, {"field":"Priority","operator":"IN","value":["High","Medium"]}]', // JSON Filter: Open and High/Medium Prio
                OrderBy__c = '[{"field":"Priority", "direction":"DESC", "nulls":"LAST"},{"field":"CreatedDate","direction":"DESC"}]' // JSON Order: Priority desc, then Date desc
        ));

        // === SCENARIO 4: User Anchor - My Open Tasks (Filtered & Ordered) ===
        // Type: Declarative, User Anchored
        // Use Case: Show tasks assigned to the current user that aren't completed, ordered by due date.
        // Assumes ContextService logic handles User Anchored by filtering Target Object OwnerId = current user.
        sourcesToCreate.add(new ContextGraphSource__c(
                ContextLabel__c = 'User My Open Tasks',
                SourceDeveloperName__c = 'User_MyOpenTasks',
                IsActive__c = true,
                Description__c = 'Displays Tasks owned by the current user that are not Complete.',
                ImplementationType__c = 'Declarative',
                SourceType__c = 'User Anchored',             // Starts from the User
                StartingSObjectApiName__c = null,           // Null for User Anchored
                TargetSObjectApiName__c = 'Task',            // Target is Task
                TargetFieldSetName__c = fsTaskListItem,     // Use Task list Field Set
                // LinkType/LinkDetail not strictly applicable for UserAnchor->Tasks owned by user in this design.
                // Assumes service adds implicit OwnerId filter. Add explicit filter if needed.
                ExecutionOrder__c = 40,
                RecordLimit__c = 10,
                // Filter to exclude completed Tasks.
                // Note: This relies on ContextService *also* implicitly adding OwnerId = userId filter
                FilterBy__c = '[{"field":"Status", "operator":"!=","value":"Completed"}]',
                OrderBy__c = '[{"field":"ActivityDate","direction":"ASC", "nulls": "LAST"},{"field":"Priority","direction":"DESC"}]' // Due Date Asc, then Prio Desc
        ));

        // === SCENARIO 5: Opportunity Record - Apex Provider ===
        sourcesToCreate.add(new ContextGraphSource__c(
                ContextLabel__c = 'My Pipeline Summary (Auto)',
                SourceDeveloperName__c = 'User_Pipeline_Summary_Apex',
                IsActive__c = true,
                Description__c = 'Provides a configurable pipeline summary for the current user via Apex.',
                ImplementationType__c = 'Apex',
                ProviderClassName__c = 'UserPipelineSummaryProvider',
                ProviderConfiguration__c = '{ "timePeriodType": "CurrentFQ", "highValueThreshold": 75000, "stalledActivityDays": 21 }', // Example configuration JSON for the provider
                SourceType__c = 'User Anchored',
                ExecutionOrder__c = 50
        ));

        // === SCENARIO 6: Opportunity Record - Related Line Items (Child Relationship) ===
        // Type: Declarative, Record Anchored (Opportunity), Child Relationship Link
        // Use Case: Show the products (line items) associated with the current Opportunity.
        sourcesToCreate.add(new ContextGraphSource__c(
                ContextLabel__c = 'Opportunity Products List',
                SourceDeveloperName__c = 'Opp_LineItems_Sorted',
                IsActive__c = true,
                Description__c = 'Displays Opportunity Line Items associated with the current Opportunity.',
                ImplementationType__c = 'Declarative',
                SourceType__c = 'Record Anchored',
                StartingSObjectApiName__c = 'Opportunity',
                TargetSObjectApiName__c = 'OpportunityLineItem',   // Target is the junction/line item
                TargetFieldSetName__c = fsOppLineItemDetail,    // Use the Line Item Field Set
                LinkType__c = 'Child Relationship',              // Standard relationship Opp -> OLI
                LinkDetailApiName__c = 'OpportunityLineItems',  // The relationship name
                ExecutionOrder__c = 60,
                RecordLimit__c = 20,                            // Allow more products potentially
                OrderBy__c = '[{"field":"Product2.Name", "direction":"ASC"}]' // Order by product name
        ));

        // === SCENARIO 7: User Anchor - My Upcoming Events ===
        // Type: Declarative, User Anchored
        // Use Case: Show Events owned by the current user happening today or later.
        sourcesToCreate.add(new ContextGraphSource__c(
                ContextLabel__c = 'User My Upcoming Events',
                SourceDeveloperName__c = 'User_MyUpcomingEvents',
                IsActive__c = true,
                Description__c = 'Displays future Events owned by the current user.',
                ImplementationType__c = 'Declarative',
                SourceType__c = 'User Anchored',
                TargetSObjectApiName__c = 'Event',            // Target is Event
                TargetFieldSetName__c = fsEventUpcoming,      // Use Event Field Set
                ExecutionOrder__c = 70,
                RecordLimit__c = 5,
                FilterBy__c = '[{"field":"EndDateTime", "operator":">=","value":"TODAY"}]', // Events ending today or later
                OrderBy__c = '[{"field":"StartDateTime","direction":"ASC"}]' // Order by start time
                // Assumes service adds implicit OwnerId filter for User Anchored
        ));

        // === SCENARIO 8: Account Record - Related Contacts (Child Relationship) ===
        // Type: Declarative, Record Anchored (Account), Child Relationship Link
        // Use Case: Show Contacts associated with the current Account.
        sourcesToCreate.add(new ContextGraphSource__c(
                ContextLabel__c = 'Account Related Contacts',
                SourceDeveloperName__c = 'Account_RelatedContacts',
                IsActive__c = true,
                Description__c = 'Displays Contacts related to the current Account.',
                ImplementationType__c = 'Declarative',
                SourceType__c = 'Record Anchored',
                StartingSObjectApiName__c = 'Account',
                TargetSObjectApiName__c = 'Contact',            // Target is Contact
                TargetFieldSetName__c = fsConListItem,          // Use Contact List Item Field Set
                LinkType__c = 'Child Relationship',              // Standard relationship Account -> Contacts
                LinkDetailApiName__c = 'Contacts',              // The relationship name
                ExecutionOrder__c = 80,
                RecordLimit__c = 10,
                OrderBy__c = '[{"field":"LastName", "direction":"ASC"},{"field":"FirstName", "direction":"ASC"}]' // Order by name
        ));


        // --- Attempt to Insert the Records ---
        if (!sourcesToCreate.isEmpty()) {
            List<Database.SaveResult> results = Database.insert(sourcesToCreate, false); // Allow partial success

            Integer successCount = 0;
            Integer failCount = 0;
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    successCount++;
                } else {
                    failCount++;
                    // Log first error for the failed record
                    Database.Error err = results[i].getErrors()[0];
                    // Get corresponding source record (handle potential size mismatch though unlikely with allOrNone=false)
                    ContextGraphSource__c failedSource = (i < sourcesToCreate.size()) ? sourcesToCreate[i] : new ContextGraphSource__c(SourceDeveloperName__c = 'Unknown');
                    System.debug('ERROR inserting ContextGraphSource__c (' + failedSource.SourceDeveloperName__c + '): ' +
                            err.getStatusCode() + ' - ' + err.getMessage() +
                            ' Fields: ' + String.join(err.getFields(), ','));
                }
            }
            System.debug('ContextGraphSource__c data creation finished. SUCCESS: ' + successCount + ', FAILED: ' + failCount);

        } else {
            System.debug('No ContextGraphSource__c records were generated to insert.');
        }

        System.debug('--- ContextGraphSource__c Sample Data Creation Complete ---');
    }
}