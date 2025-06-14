/**
 * @description Utility class to programmatically create Field Sets using the Metadata API.
 *              Populated with Field Set definitions required by the AI Agent Framework sample data.
 *              Run the 'runCreateFieldSets' method via Execute Anonymous.
 * @see https://developer.salesforce.com/docs/atlas.en-us.api_meta.meta/api_meta/meta_fieldset.htm
 */
public class AgentFrameworkFieldSetSetup {

    // --- Constants ---
    private static final Integer METADATA_API_BATCH_SIZE = 10; // Documented limit

    // --- Inner Class to Hold Field Set Definition ---
    private class FieldSetDefinition {
        String objectApiName;
        String fieldSetName;
        String label;
        String description;
        List<FieldDefinition> fields = new List<FieldDefinition>();

        FieldSetDefinition(String obj, String fsName, String lbl, String descriptionParam) {
            this.objectApiName = obj;
            this.fieldSetName = fsName;
            this.label = lbl;
            this.description = descriptionParam;
        }
    }

    // --- Inner Class to Hold Field Definition ---
    private class FieldDefinition {
        String apiName; // e.g., Name, Account.Name
        Boolean isRequired = false;
        Boolean isFieldManaged = false;

        FieldDefinition(String name, Boolean required) {
            this.apiName = name;
            this.isRequired = required;
        }
    }

    // --- Main Method to Call ---
    public static void runCreateFieldSets() {
        System.debug('Starting Field Set creation...');
        List<FieldSetDefinition> definitions = getAllFieldSetDefinitions();
        createFieldSetsInBatches(definitions); // Use the new batching method
        System.debug('Field Set creation process finished. Check debug logs for details.');
    }

    // --- Core Logic (Modified for Batching) ---
    private static void createFieldSetsInBatches(List<FieldSetDefinition> definitions) {
        if (definitions == null || definitions.isEmpty()) {
            System.debug('No Field Set definitions provided to create.');
            return;
        }

        // 1. Instantiate Metadata Service
        MetadataService.MetadataPort service = createService();
        if (service == null) return;

        // 2. Prepare ALL Metadata objects first
        List<MetadataService.Metadata> allFieldSetsToCreate = new List<MetadataService.Metadata>();
        for (FieldSetDefinition def : definitions) {
            MetadataService.FieldSet fs = new MetadataService.FieldSet();
            fs.fullName = def.objectApiName + '.' + def.fieldSetName;
            fs.label = def.label;
            fs.description = def.description;

            fs.displayedFields = new List<MetadataService.FieldSetItem>();
            for (FieldDefinition fieldDef : def.fields) {
                MetadataService.FieldSetItem item = new MetadataService.FieldSetItem();
                item.field = fieldDef.apiName;
                item.isRequired = fieldDef.isRequired;
                item.isFieldManaged = fieldDef.isFieldManaged;
                fs.displayedFields.add(item);
            }

            if (fs.displayedFields.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'Skipping FieldSet ' + fs.fullName + ' because it has no defined fields.');
                continue;
            }
            allFieldSetsToCreate.add(fs);
        }

        if (allFieldSetsToCreate.isEmpty()) {
            System.debug('No valid Field Sets prepared for creation after checking field lists.');
            return;
        }

        // 3. Process in Batches
        Integer totalProcessed = 0;
        for (Integer i = 0; i < allFieldSetsToCreate.size(); i += METADATA_API_BATCH_SIZE) {
            Integer endIndex = Math.min(i + METADATA_API_BATCH_SIZE, allFieldSetsToCreate.size());

            List<MetadataService.Metadata> currentBatch = new List<MetadataService.Metadata>();
            for (Integer j = i; j < endIndex; j++) {
                currentBatch.add(allFieldSetsToCreate[j]);
            }

            System.debug('--- Processing Batch: ' + (i / METADATA_API_BATCH_SIZE + 1) + ' (Items ' + (i + 1) + ' to ' + endIndex + ') ---');
            System.debug('Attempting to create batch of ' + currentBatch.size() + ' Field Sets via Metadata API...');

            try {
                // *** Call createMetadata WITH THE BATCH ***
                MetadataService.SaveResult[] batchResults = service.createMetadata(currentBatch);

                // Process results for THIS BATCH IMMEDIATELY
                processSaveResults(batchResults, currentBatch); // Pass the batch for name matching

                totalProcessed += currentBatch.size();

            } catch (Exception e) {
                System.debug('FATAL ERROR calling createMetadata for batch: ' + e.getMessage());
                System.debug('Stack Trace: ' + e.getStackTraceString());
                // Log which Field Sets were in the failing batch
                System.debug('Field Sets in this failed batch:');
                for(MetadataService.Metadata md : currentBatch) {
                    System.debug('  - ' + ((MetadataService.FieldSet)md).fullName);
                }
                // Decide if you want to stop processing or continue with next batch
                // For setup, often better to log and continue if possible
                System.debug('Continuing to next batch despite error in current batch.');
            }
            System.debug('--- Finished Processing Batch ' + (i / METADATA_API_BATCH_SIZE + 1) + ' ---');

        }
        System.debug('Finished processing all ' + totalProcessed + ' Field Sets in batches.');
    }

    // --- Helper Methods (getAllFieldSetDefinitions, createService, processSaveResults remain the same) ---

    /**
     * @description Gets all Field Set definitions needed for the framework.
     *              Data is derived from the sfdx_code_dump.txt provided previously.
     * @return List<FieldSetDefinition>
     */
    private static List<FieldSetDefinition> getAllFieldSetDefinitions() {
        List<FieldSetDefinition> definitions = new List<FieldSetDefinition>();

        // == Account Field Sets ==
        FieldSetDefinition accSalesHeader = new FieldSetDefinition('Account', 'FsAccountSalesHeader', 'Account Sales Header FS', 'Key fields for providing sales-oriented context about an Account...');
        accSalesHeader.fields.add(new FieldDefinition('Name', true));
        accSalesHeader.fields.add(new FieldDefinition('Type', false));
        accSalesHeader.fields.add(new FieldDefinition('Industry', false));
        accSalesHeader.fields.add(new FieldDefinition('AnnualRevenue', false));
        accSalesHeader.fields.add(new FieldDefinition('NumberOfEmployees', false));
        accSalesHeader.fields.add(new FieldDefinition('OwnerId', false));
        accSalesHeader.fields.add(new FieldDefinition('Phone', false));
        accSalesHeader.fields.add(new FieldDefinition('Website', false));
        accSalesHeader.fields.add(new FieldDefinition('BillingCity', false));
        accSalesHeader.fields.add(new FieldDefinition('BillingState', false));
        accSalesHeader.fields.add(new FieldDefinition('Description', false));
        accSalesHeader.fields.add(new FieldDefinition('LastActivityDate', false));
        definitions.add(accSalesHeader);

        // == Opportunity Field Sets ==
        FieldSetDefinition oppListItem = new FieldSetDefinition('Opportunity', 'FsOpportunityListItem', 'Opportunity List Item FS', 'Core fields for displaying a concise summary of an Opportunity...');
        oppListItem.fields.add(new FieldDefinition('Name', true));
        oppListItem.fields.add(new FieldDefinition('StageName', false));
        oppListItem.fields.add(new FieldDefinition('Amount', false));
        oppListItem.fields.add(new FieldDefinition('CloseDate', false));
        oppListItem.fields.add(new FieldDefinition('Probability', false));
        oppListItem.fields.add(new FieldDefinition('OwnerId', false));
        definitions.add(oppListItem);

        FieldSetDefinition oppDetail = new FieldSetDefinition('Opportunity', 'FsOpportunityDetail', 'Opportunity Detail FS', 'Detailed information about an Opportunity...');
        oppDetail.fields.add(new FieldDefinition('Name', true));
        oppDetail.fields.add(new FieldDefinition('AccountId', true));
        oppDetail.fields.add(new FieldDefinition('Account.Name', false)); // Relationship field
        oppDetail.fields.add(new FieldDefinition('StageName', false));
        oppDetail.fields.add(new FieldDefinition('Amount', false));
        oppDetail.fields.add(new FieldDefinition('CloseDate', false));
        oppDetail.fields.add(new FieldDefinition('Probability', false));
        oppDetail.fields.add(new FieldDefinition('Type', false));
        oppDetail.fields.add(new FieldDefinition('LeadSource', false));
        oppDetail.fields.add(new FieldDefinition('NextStep', false));
        oppDetail.fields.add(new FieldDefinition('Description', false));
        oppDetail.fields.add(new FieldDefinition('OwnerId', false));
        oppDetail.fields.add(new FieldDefinition('CreatedDate', false));
        oppDetail.fields.add(new FieldDefinition('LastModifiedDate', false));
        definitions.add(oppDetail);

        // == OpportunityLineItem Field Sets ==
        FieldSetDefinition oppLineItemDetail = new FieldSetDefinition('OpportunityLineItem', 'FsOpportunityLineItemDetail', 'Opportunity Line Item Detail FS', 'Detailed fields for Opportunity Line Items (Products)...');
        oppLineItemDetail.fields.add(new FieldDefinition('Product2Id', false)); // Useful for context
        oppLineItemDetail.fields.add(new FieldDefinition('Product2.Name', true)); // Essential
        oppLineItemDetail.fields.add(new FieldDefinition('Product2.ProductCode', false));
        oppLineItemDetail.fields.add(new FieldDefinition('Quantity', false));
        oppLineItemDetail.fields.add(new FieldDefinition('UnitPrice', false)); // List Price
        oppLineItemDetail.fields.add(new FieldDefinition('TotalPrice', false)); // Calculated Sales Price
        oppLineItemDetail.fields.add(new FieldDefinition('Description', false)); // Line item specific notes
        oppLineItemDetail.fields.add(new FieldDefinition('ServiceDate', false)); // Relevant for service products
        definitions.add(oppLineItemDetail);

        // == Contact Field Sets ==
        FieldSetDefinition conListItem = new FieldSetDefinition('Contact', 'FsContactListItem', 'Contact List Item FS', 'Essential fields for displaying a Contact within a list...');
        conListItem.fields.add(new FieldDefinition('Name', true));
        conListItem.fields.add(new FieldDefinition('Title', false));
        conListItem.fields.add(new FieldDefinition('Email', false));
        conListItem.fields.add(new FieldDefinition('Phone', false));
        conListItem.fields.add(new FieldDefinition('Account.Name', false)); // Show related Account Name
        definitions.add(conListItem);

        FieldSetDefinition conDetail = new FieldSetDefinition('Contact', 'FsContactDetail', 'Contact Detail FS', 'Provides detailed context about a Contact...');
        conDetail.fields.add(new FieldDefinition('Name', true));
        conDetail.fields.add(new FieldDefinition('AccountId', false));
        conDetail.fields.add(new FieldDefinition('Account.Name', false));
        conDetail.fields.add(new FieldDefinition('Title', false));
        conDetail.fields.add(new FieldDefinition('Department', false));
        conDetail.fields.add(new FieldDefinition('Email', false));
        conDetail.fields.add(new FieldDefinition('Phone', false));
        conDetail.fields.add(new FieldDefinition('MobilePhone', false));
        conDetail.fields.add(new FieldDefinition('OwnerId', false));
        conDetail.fields.add(new FieldDefinition('LastActivityDate', false));
        definitions.add(conDetail);

        // == Case Field Sets ==
        FieldSetDefinition caseListItem = new FieldSetDefinition('Case', 'FsCaseListItem', 'Case List Item FS', 'Summary fields for displaying Cases in a related list...');
        caseListItem.fields.add(new FieldDefinition('CaseNumber', true));
        caseListItem.fields.add(new FieldDefinition('Subject', false));
        caseListItem.fields.add(new FieldDefinition('Status', false));
        caseListItem.fields.add(new FieldDefinition('Priority', false));
        caseListItem.fields.add(new FieldDefinition('CreatedDate', false));
        caseListItem.fields.add(new FieldDefinition('OwnerId', false));
        definitions.add(caseListItem);

        FieldSetDefinition caseDetail = new FieldSetDefinition('Case', 'FsCaseDetail', 'Case Detail FS', 'Provides detailed context about a specific Case record...');
        caseDetail.fields.add(new FieldDefinition('CaseNumber', true));
        caseDetail.fields.add(new FieldDefinition('AccountId', false));
        caseDetail.fields.add(new FieldDefinition('ContactId', false));
        caseDetail.fields.add(new FieldDefinition('Subject', true));
        caseDetail.fields.add(new FieldDefinition('Description', false));
        caseDetail.fields.add(new FieldDefinition('Status', false));
        caseDetail.fields.add(new FieldDefinition('Priority', false));
        caseDetail.fields.add(new FieldDefinition('Origin', false));
        caseDetail.fields.add(new FieldDefinition('Type', false));
        caseDetail.fields.add(new FieldDefinition('Reason', false));
        caseDetail.fields.add(new FieldDefinition('OwnerId', false));
        caseDetail.fields.add(new FieldDefinition('CreatedDate', false));
        caseDetail.fields.add(new FieldDefinition('LastModifiedDate', false));
        caseDetail.fields.add(new FieldDefinition('IsClosed', false));
        caseDetail.fields.add(new FieldDefinition('IsEscalated', false));
        definitions.add(caseDetail);

        // == Task Field Sets ==
        FieldSetDefinition taskListItem = new FieldSetDefinition('Task', 'FsTaskListItem', 'Task List Item FS', 'Essential fields for summarizing Tasks in list views...');
        taskListItem.fields.add(new FieldDefinition('Subject', true));
        taskListItem.fields.add(new FieldDefinition('Status', false));
        taskListItem.fields.add(new FieldDefinition('Priority', false));
        taskListItem.fields.add(new FieldDefinition('ActivityDate', false));
        taskListItem.fields.add(new FieldDefinition('OwnerId', false));
        taskListItem.fields.add(new FieldDefinition('WhoId', false)); // Related Contact/Lead
        taskListItem.fields.add(new FieldDefinition('WhatId', false)); // Related Object (Opp, Account, etc.)
        taskListItem.fields.add(new FieldDefinition('Description', false));
        definitions.add(taskListItem);

        // == Event Field Sets ==
        FieldSetDefinition eventUpcoming = new FieldSetDefinition('Event', 'FsEventUpcomingSummary', 'Event Upcoming Summary FS', 'Key fields for displaying upcoming calendar Events (Meetings)...');
        eventUpcoming.fields.add(new FieldDefinition('Subject', true));
        eventUpcoming.fields.add(new FieldDefinition('StartDateTime', true));
        eventUpcoming.fields.add(new FieldDefinition('EndDateTime', true));
        eventUpcoming.fields.add(new FieldDefinition('Location', false));
        eventUpcoming.fields.add(new FieldDefinition('OwnerId', false));
        eventUpcoming.fields.add(new FieldDefinition('WhoId', false));
        eventUpcoming.fields.add(new FieldDefinition('WhatId', false));
        eventUpcoming.fields.add(new FieldDefinition('Description', false));
        definitions.add(eventUpcoming);

        // == User Field Sets ==
        FieldSetDefinition userSales = new FieldSetDefinition('User', 'FsUserSales', 'User Sales Context FS', 'Provides identifying and contextual information about the current user...');
        userSales.fields.add(new FieldDefinition('Name', true));
        userSales.fields.add(new FieldDefinition('Title', false));
        userSales.fields.add(new FieldDefinition('Email', false));
        userSales.fields.add(new FieldDefinition('Profile.Name', false));
        userSales.fields.add(new FieldDefinition('Department', false));
        userSales.fields.add(new FieldDefinition('ManagerId', false));
        definitions.add(userSales);

        System.debug('Generated ' + definitions.size() + ' Field Set definitions in memory.');
        return definitions;
    }

    /** Creates MetadataService instance and sets session */
    private static MetadataService.MetadataPort createService() {
        try {
            MetadataService.MetadataPort service = new MetadataService.MetadataPort();
            service.SessionHeader = new MetadataService.SessionHeader_element();
            service.SessionHeader.sessionId = UserInfo.getSessionId();
            service.timeout_x = 120000; // 120 seconds
            return service;
        } catch (Exception e) {
            System.debug('ERROR Creating MetadataService Port: ' + e.getMessage() + '. Ensure Metadata API WSDL generated and Remote Site Setting configured.');
            System.debug(e.getStackTraceString());
            return null;
        }
    }

    /**
     * Processes the results from a createMetadata call FOR A SINGLE BATCH.
     * Now receives the specific batch list that was submitted.
     */
    private static void processSaveResults(MetadataService.SaveResult[] results, List<MetadataService.Metadata> submittedBatch) {
        if (results == null) {
            System.debug('ERROR: createMetadata returned null results for batch.');
            return;
        }

        if (results.size() != submittedBatch.size()) {
            System.debug(LoggingLevel.ERROR, 'Mismatch between submitted FieldSets (' + submittedBatch.size() + ') and results (' + results.size() + ') in this batch.');
        }

        for (Integer i = 0; i < results.size(); i++) {
            MetadataService.SaveResult res = results[i];
            String fsName = 'Unknown (index ' + i + ')';
            if (i < submittedBatch.size() && submittedBatch[i] != null && submittedBatch[i] instanceof MetadataService.FieldSet) {
                fsName = ((MetadataService.FieldSet)submittedBatch[i]).fullName;
            }

            if (res.success) {
                System.debug('SUCCESS creating/updating Field Set: ' + fsName);
            } else {
                String errorMsg = 'FAILURE creating/updating Field Set: ' + fsName + '. Errors: ';
                List<String> messages = new List<String>();
                if (res.errors != null) {
                    for (MetadataService.Error err : res.errors) {
                        if(err != null) {
                            messages.add('(' + err.statusCode + ') ' + err.message + (err.fields != null ? ' [Fields: ' + String.join(err.fields, ',') + ']' : ''));
                        } else { messages.add('(null error object)'); }
                    }
                } else { messages.add('(results.errors list was null)'); }
                System.debug(LoggingLevel.ERROR, errorMsg + String.join(messages, '; '));
                if (messages.size() > 0 && messages[0].contains('already exists')) {
                    System.debug('(Field set likely existed already, ignoring error for ' + fsName + ')');
                }
            }
        }
    }
}