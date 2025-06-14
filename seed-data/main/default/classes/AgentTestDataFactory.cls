/**
 * @description Test data factory for creating a sample AI Agent ("Sales Copilot") with all its related configurations,
 *              including Action Definitions and Agent Capability Bindings for standard sales-related tasks.
 *              Also seeds sample sales data (Accounts, Contacts, Opportunities, Tasks).
 */
public with sharing class AgentTestDataFactory {

    // --- Action Definition Developer Names (Internal Keys) ---
    private static final String DEF_CREATE_OPP = 'StdAction_CreateRecord_Opportunity';
    private static final String DEF_CREATE_TASK = 'StdAction_CreateRecord_Task';
    private static final String DEF_POST_CHATTER = 'StdAction_PostChatter';
    private static final String DEF_UPDATE_OPP = 'StdAction_UpdateRecord_Opportunity';
    private static final String DEF_FIND_ENTITIES = 'StdAction_FindEntities'; // New Action

    // --- Handler Class Names (Must match the actual Apex class names) ---
    private static final String HNDLR_CREATE_RECORD = ActionCreateRecord.class.getName();
    private static final String HNDLR_POST_CHATTER = ActionPostChatter.class.getName();
    private static final String HNDLR_UPDATE_RECORD = ActionUpdateRecord.class.getName();
    private static final String HNDLR_FIND_ENTITIES = ActionFindEntities.class.getName(); // New Handler

    public static void setupSalesCopilotData() {
        LLMConfiguration__c llmConfig = createLLMConfiguration(
                'OpenAI',
                OpenAIProviderAdapter.class.getName(),
                'OpenAI_API',
                'gpt-4o-mini',
                0.1
        );

        AIAgentDefinition__c salesAgent = createSalesCopilotAgentDefinition(llmConfig.Id);

        createContextConfigs(salesAgent.Id);

        setupStandardActionsAndBindings(salesAgent.Id);

        seedSalesData();
    }

    public static void createContextConfigs(Id agentDefinitionId) {
        List<AgentContextConfig__c> contextConfigsToInsert = new List<AgentContextConfig__c>();

        // --- 1. User Details Provider ---
        contextConfigsToInsert.add(new AgentContextConfig__c(
                AIAgentDefinition__c = agentDefinitionId,
                ContextLabel__c = 'User & Role Information',      // Label shown to LLM
                ImplementationType__c = 'Apex',                   // Required
                ImplementationName__c = 'UserDetailsProvider',    // Apex Class Name
                ExecutionOrder__c = 10,                           // Runs first
                IsActive__c = true,
                RequiresRecordContext__c = false,                 // Runs for User Context primarily
                ApplicableSObjectTypes__c = null                  // Applies regardless of record context
        ));

        // --- 2. Account Specific Context Builder (Example: Cases) ---
        contextConfigsToInsert.add(new AgentContextConfig__c(
                AIAgentDefinition__c = agentDefinitionId,
                ContextLabel__c = 'Account Information Context',
                ImplementationType__c = 'Apex',
                ImplementationName__c = 'AccountSpecificContextBuilder', // SAME provider class
                ExecutionOrder__c = 50,                           // Runs after Opps
                IsActive__c = true,
                RequiresRecordContext__c = true,                  // Requires Account Record
                ApplicableSObjectTypes__c = 'Account'             // Only on Accounts
        ));

        insert contextConfigsToInsert;
    }

    /**
     * @description Main setup method for Actions. Prepares, upserts, and binds standard actions.
     * @param agentDefId The ID of the AIAgentDefinition__c to bind the capabilities to.
     */
    public static void setupStandardActionsAndBindings(Id agentDefId) {
        // 1. Prepare Action Definitions in Memory
        List<ActionDefinition__c> actionDefs = prepareActionDefinitions();

        // 2. Upsert Action Definitions (Idempotent based on DeveloperName__c)
        insert actionDefs;

        // 3. Get Action Definition IDs (Querying ensures we have IDs for existing & new)
        Map<String, Id> actionDefIdMap = getActionDefinitionIds(new Set<String>{
                DEF_CREATE_OPP, DEF_CREATE_TASK, DEF_POST_CHATTER, DEF_UPDATE_OPP, DEF_FIND_ENTITIES
        });

        // 4. Prepare Agent Capability Bindings with LLM-friendly names and descriptions
        List<AgentCapabilityBinding__c> bindings = prepareCapabilityBindings(agentDefId, actionDefIdMap);

        // 5. Insert Agent Capability Bindings (Checking for existing bindings first)
        insertNewCapabilityBindings(bindings);

        System.debug(LoggingLevel.INFO, 'Standard Action Definition and Binding setup completed for Agent ID: ' + agentDefId);
    }

    /**
     * @description Prepares SObjects for all standard Action Definitions.
     * @return List of ActionDefinition__c to be inserted.
     */
    private static List<ActionDefinition__c> prepareActionDefinitions() {
        System.debug(LoggingLevel.DEBUG, 'Preparing ActionDefinition objects in memory...');
        List<ActionDefinition__c> definitions = new List<ActionDefinition__c>();

        // --- JSON Schemas for Action Inputs ---
        String createOppSchema = '{"type":"object","description":"Field data for the new Opportunity record.","properties":{"Name":{"type":"string","description":"Required. The name for the new Opportunity."},"AccountId":{"type":"string","description":"Required. The 18-character Salesforce ID of the Account this Opportunity belongs to."},"StageName":{"type":"string","description":"Required. The API name of the initial sales stage (e.g., \'Prospecting\', \'Needs Analysis\'). Must be a valid, active stage name."},"CloseDate":{"type":"string","format":"date","description":"Required. The estimated close date for the Opportunity (YYYY-MM-DD)."},"Amount":{"type":"number","description":"Optional. The estimated value or amount of the Opportunity."},"Description":{"type":"string","description":"Optional. A brief description or notes about the Opportunity."}},"required":["Name","AccountId","StageName","CloseDate"]}';
        String createTaskSchema = '{"type":"object","description":"Field data for the new Task record.","properties":{"Subject":{"type":"string","description":"Required. The subject line summarizing the task."},"WhatId":{"type":"string","description":"Optional. The 18-character Salesforce ID of a related record (e.g., Opportunity, Account, Case)."},"WhoId":{"type":"string","description":"Optional. The 18-character Salesforce ID of a related Contact or Lead."},"ActivityDate":{"type":"string","format":"date","description":"Optional. The due date for the task (YYYY-MM-DD). Defaults to today if not provided."},"Status":{"type":"string","description":"Optional. The status of the task (e.g., \'Not Started\', \'In Progress\'). Defaults based on system setup."},"Priority":{"type":"string","description":"Optional. The priority of the task (e.g., \'Normal\', \'High\'). Defaults based on system setup."},"Description":{"type":"string","description":"Optional. Detailed description or notes for the task."}},"required":["Subject"]}';
        String postChatterSchema = '{"type":"object","description":"Parameters for posting to a Chatter feed.","properties":{"feedType":{"type":"string","enum":["Record","User","Group"],"description":"Required. Specifies the type of feed to post to. Use \'Record\' to post to an Opportunity feed."},"targetId":{"type":"string","description":"Required. The 18-character Salesforce ID of the target Record, User, or Group."},"text":{"type":"string","description":"Required. The content of the message to post."}},"required":["feedType","targetId","text"]}';
        String updateOppSchema = '{"type":"object","description":"Specifies the Opportunity record to update and the fields to change.","properties":{"recordId":{"type":"string","description":"Required. The 18-character Salesforce ID of the Opportunity to update."}},"required":["recordId"],"additionalProperties":{"description":"Provide additional key-value pairs where the key is the Field API Name to update (e.g., \'Description\', \'NextStep\') and the value is the new field value."}}';
        String findEntitiesSchema = '{"type":"object","properties":{"searchQuery":{"type":"string","description":"The text to search for (e.g., a company name, contact name, or opportunity title)."},"sObjectTypes":{"type":"array","items":{"type":"string"},"description":"Optional. A list of specific object types to search (e.g., [\\"Account\\", \\"Contact\\"]). If omitted, all configured objects will be searched."}},"required":["searchQuery"]}';


        // --- JSON Schemas for Binding Configurations (validates the ActionConfiguration__c field) ---
        String oppBindingSchema = '{"type":"object","properties":{"objectApiName":{"type":"string","description":"Binding Configuration: MUST be \'Opportunity\' for this specific Action Definition."}},"required":["objectApiName"]}';
        String taskBindingSchema = '{"type":"object","properties":{"objectApiName":{"type":"string","description":"Binding Configuration: MUST be \'Task\' for this specific Action Definition."}},"required":["objectApiName"]}';
        // ActionFindEntities binding schema can be null now, but defining it is harmless and good for documentation.
        String findEntitiesBindingSchema = '{"type":"object","properties":{"searchableObjects":{"type":"object","description":"(Not currently used; logic is hard-coded in Apex) A map where keys are SObject API names and values are lists of fields to return."},"maxAmbiguousResults":{"type":"integer","description":"(Optional) Override the default maximum number of choices to present to the user if the search is ambiguous."}},"required":[]}';


        // --- Create Action Definition SObjects in memory ---
        definitions.add(createActionDefinitionInMemory('Create Opportunity Record', DEF_CREATE_OPP, 'Standard', 'CreateRecord', HNDLR_CREATE_RECORD, '(Standard Action) Creates a new Opportunity record.', createOppSchema, oppBindingSchema));
        definitions.add(createActionDefinitionInMemory('Create Task Record', DEF_CREATE_TASK, 'Standard', 'CreateRecord', HNDLR_CREATE_RECORD, '(Standard Action) Creates a new Task record.', createTaskSchema, taskBindingSchema));
        definitions.add(createActionDefinitionInMemory('Post Message to Chatter Feed', DEF_POST_CHATTER, 'Standard', 'PostChatter', HNDLR_POST_CHATTER, '(Standard Action) Posts a message to a Salesforce Chatter feed.', postChatterSchema, null));
        definitions.add(createActionDefinitionInMemory('Update Opportunity Record', DEF_UPDATE_OPP, 'Standard', 'UpdateRecord', HNDLR_UPDATE_RECORD, '(Standard Action) Updates fields on an existing Opportunity record.', updateOppSchema, oppBindingSchema));
        definitions.add(createActionDefinitionInMemory('Find Salesforce Records', DEF_FIND_ENTITIES, 'Standard', 'FindEntities', HNDLR_FIND_ENTITIES, '(Standard Action) Performs a fuzzy search for records using SOSL.', findEntitiesSchema, findEntitiesBindingSchema));

        System.debug(LoggingLevel.DEBUG, 'Prepared ' + definitions.size() + ' ActionDefinition objects.');
        return definitions;
    }

    /**
     * @description Prepares the AgentCapabilityBinding SObjects that link the agent to the actions.
     * @param agentDefId The ID of the AIAgentDefinition__c.
     * @param actionDefIdMap Map of Action Definition Developer Names to their IDs.
     * @return List of AgentCapabilityBinding__c to be inserted.
     */
    private static List<AgentCapabilityBinding__c> prepareCapabilityBindings(Id agentDefId, Map<String, Id> actionDefIdMap) {
        System.debug(LoggingLevel.DEBUG, 'Preparing AgentCapabilityBinding objects in memory for Agent ID: ' + agentDefId);
        List<AgentCapabilityBinding__c> bindings = new List<AgentCapabilityBinding__c>();
        Integer order = 10;

        // --- Capability Binding Developer Names (LLM-friendly function names, unique PER AGENT) ---
        String BINDING_NAME_FIND_RECORDS = 'find_sales_records';
        String BINDING_NAME_CREATE_OPP = 'create_opportunity';
        String BINDING_NAME_UPDATE_OPP = 'update_opportunity';
        String BINDING_NAME_CREATE_TASK = 'create_task';
        String BINDING_NAME_POST_CHATTER = 'post_to_chatter';

        // --- Binding Configs JSON (provides backend settings for reusable standard actions) ---
        String createOppConfigJson = '{"objectApiName": "Opportunity"}';
        String createTaskConfigJson = '{"objectApiName": "Task"}';
        String updateOppConfigJson = '{"objectApiName": "Opportunity"}';
        // ** UPDATED **: findEntitiesConfigJson is now null, as requested.
        String findEntitiesConfigJson = null;


        // ** Capability to Find Records **
        Id findEntitiesDefId = actionDefIdMap.get(DEF_FIND_ENTITIES);
        if (findEntitiesDefId != null) {
            bindings.add(createAgentCapabilityBindingInMemory(agentDefId, findEntitiesDefId, BINDING_NAME_FIND_RECORDS, order,
                    'Searches for Salesforce records like Accounts, Contacts, or Opportunities using a text query. Use this to locate a specific record before taking further action, such as summarizing or updating it. The user\'s query can be a name, part of a name, or another identifier like an email address.',
                    getActionInputSchema(actionDefIdMap, DEF_FIND_ENTITIES), findEntitiesConfigJson));
            order += 10;
        } else { System.debug(LoggingLevel.WARN, 'Could not create binding for FindEntities - ActionDefinition not found.'); }

        // ** Capability to Create Opportunity **
        Id createOppDefId = actionDefIdMap.get(DEF_CREATE_OPP);
        if (createOppDefId != null) {
            bindings.add(createAgentCapabilityBindingInMemory(agentDefId, createOppDefId, BINDING_NAME_CREATE_OPP, order,
                    'Creates a new sales Opportunity record. This is the primary tool for adding a potential deal to the pipeline. You MUST provide the opportunity \'Name\', the 18-character \'AccountId\' of the associated Account, the \'StageName\' (e.g., \'Prospecting\'), and the estimated \'CloseDate\' (YYYY-MM-DD). You can optionally provide an \'Amount\'.',
                    getActionInputSchema(actionDefIdMap, DEF_CREATE_OPP), createOppConfigJson));
            order += 10;
        } else { System.debug(LoggingLevel.WARN, 'Could not create binding for CreateOpportunity - ActionDefinition not found.'); }

        // ** Capability to Update Opportunity **
        Id updateOppDefId = actionDefIdMap.get(DEF_UPDATE_OPP);
        if (updateOppDefId != null) {
            bindings.add(createAgentCapabilityBindingInMemory(agentDefId, updateOppDefId, BINDING_NAME_UPDATE_OPP, order,
                    'Updates one or more fields on an existing Opportunity record. Use this to change the StageName, Amount, CloseDate, or add a Description. You MUST provide the 18-character \'recordId\' of the Opportunity to update, along with the fields and their new values.',
                    getActionInputSchema(actionDefIdMap, DEF_UPDATE_OPP), updateOppConfigJson));
            order += 10;
        } else { System.debug(LoggingLevel.WARN, 'Could not create binding for UpdateOpportunity - ActionDefinition not found.'); }

        // ** Capability to Create Task **
        Id createTaskDefId = actionDefIdMap.get(DEF_CREATE_TASK);
        if (createTaskDefId != null) {
            bindings.add(createAgentCapabilityBindingInMemory(agentDefId, createTaskDefId, BINDING_NAME_CREATE_TASK, order,
                    'Creates a new Task record for follow-up, such as scheduling a call or sending an email. Requires at least a \'Subject\'. Can optionally be related to a sales record like an Opportunity or Account by providing its 18-character ID in the \'WhatId\' parameter.',
                    getActionInputSchema(actionDefIdMap, DEF_CREATE_TASK), createTaskConfigJson));
            order += 10;
        } else { System.debug(LoggingLevel.WARN, 'Could not create binding for CreateTask - ActionDefinition not found.'); }

        // ** Capability to Post Chatter **
        Id postChatterDefId = actionDefIdMap.get(DEF_POST_CHATTER);
        if (postChatterDefId != null) {
            bindings.add(createAgentCapabilityBindingInMemory(agentDefId, postChatterDefId, BINDING_NAME_POST_CHATTER, order,
                    'Posts a message to a specific Chatter feed to collaborate with team members. Specify the \'feedType\' as \'Record\' to post on an Opportunity, Account, etc. Provide the 18-character \'targetId\' of the record and the \'text\' to post.',
                    getActionInputSchema(actionDefIdMap, DEF_POST_CHATTER), null));
            order += 10;
        } else { System.debug(LoggingLevel.WARN, 'Could not create binding for PostChatter - ActionDefinition not found.'); }

        System.debug(LoggingLevel.DEBUG, 'Prepared ' + bindings.size() + ' AgentCapabilityBinding objects.');
        return bindings;
    }


    // --- Helper Methods to create SObjects in memory ---
    private static ActionDefinition__c createActionDefinitionInMemory(
            String label, String devName, String implType, String stdActionType, String implName,
            String description, String inputSchemaJson, String bindingSchemaJson)
    {
        ActionDefinition__c actionDef = new ActionDefinition__c(
                Name = label,
                DeveloperName__c = devName,
                ImplementationType__c = implType,
                StandardActionType__c = (implType == 'Standard' ? stdActionType : null),
                ImplementationName__c = (implType == 'Standard' ? implName : null),
                Description__c = description,
                InputParameterSchema__c = inputSchemaJson,
                ConfigurationSchema__c = bindingSchemaJson,
                IsActive__c = true
        );
        return actionDef;
    }

    private static AgentCapabilityBinding__c createAgentCapabilityBindingInMemory(
            Id agentDefId, Id actionDefId, String bindingDevName, Integer execOrder,
            String descriptionForLlm, String inputSchemaForLlm, String actionConfigJson)
    {
        return new AgentCapabilityBinding__c(
                AIAgentDefinition__c = agentDefId,
                ActionDefinition__c = actionDefId,
                DeveloperName__c = bindingDevName,
                ExecutionOrder__c = execOrder,
                Description__c = descriptionForLlm,
                InputSchema__c = inputSchemaForLlm,
                ActionConfiguration__c = actionConfigJson,
                IsActive__c = true
        );
    }


    // --- Helper Methods for Data Retrieval and Insertion ---

    /**
     * @description Queries for Action Definition IDs based on a set of Developer Names.
     * @param devNames Set of DeveloperName__c values to query.
     * @return Map of DeveloperName__c to Salesforce Record ID.
     */
    private static Map<String, Id> getActionDefinitionIds(Set<String> devNames) {
        Map<String, Id> idMap = new Map<String, Id>();
        if (devNames == null || devNames.isEmpty()) return idMap;

        System.debug(LoggingLevel.DEBUG, 'Querying IDs for Action Definitions: ' + String.join(new List<String>(devNames), ', '));
        try {
            for (ActionDefinition__c ad : [SELECT Id, DeveloperName__c FROM ActionDefinition__c WHERE DeveloperName__c IN :devNames]) {
                idMap.put(ad.DeveloperName__c, ad.Id);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to query Action Definition IDs: ' + e.getMessage());
            throw e;
        }
        System.debug(LoggingLevel.DEBUG, 'Retrieved ' + idMap.size() + ' Action Definition IDs.');
        return idMap;
    }

    /**
     * @description Helper to get the input schema from an already queried Action Definition.
     * @param actionDefIdMap Map of Developer Names to IDs.
     * @param actionDefDevName The specific Developer Name to get the schema for.
     * @return The InputParameterSchema__c string, or an empty JSON object '{}' if not found.
     */
    private static String getActionInputSchema(Map<String, Id> actionDefIdMap, String actionDefDevName) {
        Id actionId = actionDefIdMap.get(actionDefDevName);
        if (actionId == null) return '{}';

        List<ActionDefinition__c> defs = [SELECT InputParameterSchema__c FROM ActionDefinition__c WHERE Id = :actionId];
        return defs.isEmpty() ? '{}' : defs[0].InputParameterSchema__c;
    }

    /**
     * @description Inserts only the capability bindings that do not already exist for the agent.
     * @param bindingsToConsider A list of bindings to potentially insert.
     */
    private static void insertNewCapabilityBindings(List<AgentCapabilityBinding__c> bindingsToConsider) {
        if (bindingsToConsider == null || bindingsToConsider.isEmpty()) {
            System.debug(LoggingLevel.INFO, 'No Capability Bindings provided to insert.');
            return;
        }

        Id agentDefId = bindingsToConsider[0].AIAgentDefinition__c;
        Set<String> desiredBindingDevNames = new Set<String>();
        Map<String, AgentCapabilityBinding__c> desiredBindingMap = new Map<String, AgentCapabilityBinding__c>();
        for (AgentCapabilityBinding__c binding : bindingsToConsider) {
            desiredBindingDevNames.add(binding.DeveloperName__c);
            desiredBindingMap.put(binding.DeveloperName__c.toLowerCase(), binding);
        }

        Set<String> existingBindingDevNames = new Set<String>();
        for (AgentCapabilityBinding__c existing : [
                SELECT DeveloperName__c FROM AgentCapabilityBinding__c
                WHERE AIAgentDefinition__c = :agentDefId AND DeveloperName__c IN :desiredBindingDevNames
        ]) {
            existingBindingDevNames.add(existing.DeveloperName__c.toLowerCase());
        }

        List<AgentCapabilityBinding__c> bindingsToInsert = new List<AgentCapabilityBinding__c>();
        for (String desiredDevName : desiredBindingMap.keySet()) {
            if (!existingBindingDevNames.contains(desiredDevName)) {
                bindingsToInsert.add(desiredBindingMap.get(desiredDevName));
            }
        }

        if (bindingsToInsert.isEmpty()) {
            System.debug(LoggingLevel.INFO, 'All required Agent Capability Bindings already exist for Agent ID: ' + agentDefId);
            return;
        }

        System.debug(LoggingLevel.INFO, 'Inserting ' + bindingsToInsert.size() + ' NEW Agent Capability Bindings for Agent ID: ' + agentDefId);
        Database.insert(bindingsToInsert, false);
    }


    // --- Core Configuration and Data Seeding Methods ---

    private static LLMConfiguration__c createLLMConfiguration(
            String devName,
            String adapterClass,
            String namedCred,
            String modelId,
            Decimal temperature
    ) {
        LLMConfiguration__c config = new LLMConfiguration__c(
                Name = 'OpenAI',
                DeveloperName__c = devName,
                ProviderAdapterClass__c = adapterClass,
                NamedCredential__c = namedCred,
                DefaultModelIdentifier__c = modelId,
                DefaultTemperature__c = temperature,
                IsActive__c = true,
                MaxRetryAttempts__c = 2,
                InitialRetryDelayMillis__c = 750,
                RetryableHttpStatusCodes__c = '408,429,500,502,503,504'
        );
        insert config;
        return config;
    }

    private static AIAgentDefinition__c createSalesCopilotAgentDefinition(Id llmConfigId) {
        String systemPrompt = 'You are Sales Copilot, a helpful and knowledgeable AI assistant embedded within Salesforce Sales Cloud. Your primary goal is to assist sales representatives in managing their pipeline, understanding their customers, and executing sales tasks efficiently. ' +
                'Your persona is professional, proactive, concise, and action-oriented. \n' +
                'Key Responsibilities:\n' +
                '- Provide summaries of Accounts, Opportunities, Contacts, and Leads based on the context data provided.\n' +
                '- Answer questions about the records presented in the context.\n' +
                '- Help create and update records like Tasks, Events, Opportunities, Contacts.\n' +
                '- Assist with communication by drafting emails or Chatter posts.\n' +
                '- Find specific records based on names or criteria provided by the user.\n' +
                '- Update Opportunity stages when requested, ensuring stages are valid.\n' +
                '- Log interactions like calls or meetings.\n' +
                'Interaction Guidelines:\n' +
                '- Always use the available tools (actions) when appropriate to interact with Salesforce data or perform tasks. Do not hallucinate data or actions.\n' +
                '- When asked to summarize, use the provided context data.\n' +
                '- When creating records (Tasks, Events), clarify necessary details if missing (like due dates, required fields).\n' +
                '- When updating records, confirm the record ID and the fields/values to change.\n' +
                '- When searching, indicate if multiple or no records are found.\n' +
                '- If unsure or lacking context, clearly state what information is needed.\n' +
                '- Do not perform actions that are destructive (like Delete) unless explicitly confirmed.\n' +
                '- Keep responses focused on sales productivity.\n' +
                '- Refer to the available actions (tools) list provided to understand your capabilities.\n' +
                '- Before you ask the user for information (like a record ID), first consider if you can find it yourself using one of your tools. Only ask the user for an ID as a last resort if your search fails or returns multiple ambiguous results.';

        AIAgentDefinition__c agentDef = new AIAgentDefinition__c(
                Name = 'Sales Copilot Agent',
                DeveloperName__c = 'SalesCopilot',
                LLMConfiguration__c = llmConfigId,
                SystemPrompt__c = systemPrompt,
                IsActive__c = true,
                Description__c = 'AI assistant focused on supporting Sales Reps within Sales Cloud.'
        );
        insert agentDef;
        return agentDef;
    }

    public static Map<String, Id> seedSalesData() {
        System.debug(LoggingLevel.INFO, 'Starting seedSalesData generation...');
        Map<String, Id> resultMap = new Map<String, Id>();
        List<Account> accountsToInsert = new List<Account>();
        List<Contact> contactsToInsert = new List<Contact>();
        List<Opportunity> oppsToInsert = new List<Opportunity>();
        List<Task> tasksToInsert = new List<Task>();

        // --- 1. Prepare Accounts ---
        Account accGlobal = new Account(Name = 'GlobalCorp Dynamics', Industry = 'Technology', BillingState = 'NY', AnnualRevenue = 50000000, NumberOfEmployees = 1500, Type = 'Customer - Direct', Description = 'Major enterprise technology provider. Long-term customer.');
        Account accInnovate = new Account(Name = 'Innovate Solutions Inc', Industry = 'Consulting', BillingState = 'CA', AnnualRevenue = 25000000, NumberOfEmployees = 500, Type = 'Customer - Channel', Description = 'Strategic consulting partner focused on digital transformation.');
        Account accSummit = new Account(Name = 'Summit Enterprises Ltd', Industry = 'Manufacturing', BillingState = 'TX', AnnualRevenue = 10000000, NumberOfEmployees = 300, Type = 'Prospect', Description = 'Leading manufacturer exploring new automation solutions.');
        Account accQuantum = new Account(Name = 'Quantum Leap Tech', Industry = 'Technology', BillingState = 'WA', AnnualRevenue = 5000000, NumberOfEmployees = 75, Type = 'Prospect', Description = 'Startup in quantum computing space.');
        Account accAlphaMed = new Account(Name = 'Alpha Medical Devices', Industry = 'Healthcare', BillingState = 'MA', AnnualRevenue = 75000000, NumberOfEmployees = 2000, Type = 'Customer - Direct', Description = 'Develops cutting-edge medical imaging equipment.');

        accountsToInsert.addAll(new List<Account>{ accGlobal, accInnovate, accSummit, accQuantum, accAlphaMed });

        // --- 2. Insert Accounts ---
        Map<String, Account> insertedAccountsMap = new Map<String, Account>();
        try {
            List<Database.SaveResult> accountResults = Database.insert(accountsToInsert, false);
            // Populate map with successfully inserted accounts for linking
            for(Integer i=0; i<accountResults.size(); i++){
                if(accountResults[i].isSuccess()){
                    Account acc = accountsToInsert[i];
                    acc.Id = accountResults[i].getId(); // Assign returned ID
                    insertedAccountsMap.put(acc.Name, acc);
                    resultMap.put('Account:' + acc.Name, acc.Id); // Add to result map
                } else {
                    // Log error for accounts that failed insert
                    logDmlErrors('Account Insert', accountResults[i].getErrors());
                }
            }
            System.debug(LoggingLevel.INFO, 'Inserted ' + insertedAccountsMap.size() + ' Account records.');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Critical error inserting Accounts: ' + e.getMessage());
            // If accounts fail, we likely can't proceed meaningfully
            return resultMap; // Return whatever might have been added before failure
        }
        if (insertedAccountsMap.isEmpty()) {
            System.debug(LoggingLevel.ERROR, 'No Accounts were successfully inserted. Aborting further data seeding.');
            return resultMap;
        }


        // --- 3. Prepare Contacts ---
        // Add contacts only if the related account was successfully inserted
        if(insertedAccountsMap.containsKey('GlobalCorp Dynamics')){
            Id accId = insertedAccountsMap.get('GlobalCorp Dynamics').Id;
            contactsToInsert.add(new Contact(AccountId = accId, LastName = 'Evans', FirstName = 'Sarah', Email = 's.evans@globalcorp.example.com', Phone='212-555-1001', Title='VP of IT'));
            contactsToInsert.add(new Contact(AccountId = accId, LastName = 'Chen', FirstName = 'Michael', Email = 'm.chen@globalcorp.example.com', Phone='212-555-1002', Title='Director of Operations'));
        }
        if(insertedAccountsMap.containsKey('Innovate Solutions Inc')){
            Id accId = insertedAccountsMap.get('Innovate Solutions Inc').Id;
            contactsToInsert.add(new Contact(AccountId = accId, LastName = 'Patel', FirstName = 'Priya', Email = 'priya.patel@innovate.example.com', Phone='415-555-2001', Title='Senior Consultant'));
            contactsToInsert.add(new Contact(AccountId = accId, LastName = 'Jones', FirstName = 'David', Email = 'david.jones@innovate.example.com', Phone='415-555-2005', Title='Project Manager'));
        }
        if(insertedAccountsMap.containsKey('Summit Enterprises Ltd')){
            Id accId = insertedAccountsMap.get('Summit Enterprises Ltd').Id;
            contactsToInsert.add(new Contact(AccountId = accId, LastName = 'Martinez', FirstName = 'Carlos', Email = 'carlos.martinez@summitent.example.com', Phone='713-555-3003', Title='Plant Manager'));
        }
        if(insertedAccountsMap.containsKey('Alpha Medical Devices')){
            Id accId = insertedAccountsMap.get('Alpha Medical Devices').Id;
            contactsToInsert.add(new Contact(AccountId = accId, LastName = 'Gupta', FirstName = 'Anya', Email = 'a.gupta@alphamed.example.com', Phone='617-555-4010', Title='Chief Medical Officer'));
        }

        // --- 4. Insert Contacts ---
        Map<String, Contact> insertedContactsMap = new Map<String, Contact>(); // Use Email as a unique key assumption for test
        if(!contactsToInsert.isEmpty()){
            try {
                List<Database.SaveResult> contactResults = Database.insert(contactsToInsert, false);
                for(Integer i=0; i<contactResults.size(); i++){
                    if(contactResults[i].isSuccess()){
                        Contact c = contactsToInsert[i];
                        c.Id = contactResults[i].getId(); // Assign returned ID
                        if(String.isNotBlank(c.Email)) insertedContactsMap.put(c.Email, c); // Use Email as key
                        resultMap.put('Contact:' + c.LastName, c.Id);
                    } else {
                        logDmlErrors('Contact Insert', contactResults[i].getErrors());
                    }
                }
                System.debug(LoggingLevel.INFO, 'Inserted ' + insertedContactsMap.size() + ' Contact records.');
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Critical error inserting Contacts: ' + e.getMessage());
                // Continue processing Opps/Tasks even if contacts fail
            }
        }


        // --- 5. Prepare Opportunities ---
        Date today = System.today();
        // Opportunities for inserted accounts
        if(insertedAccountsMap.containsKey('GlobalCorp Dynamics')){
            Id accId = insertedAccountsMap.get('GlobalCorp Dynamics').Id;
            oppsToInsert.add(new Opportunity(AccountId = accId, Name = 'GlobalCorp - Cloud Platform Upgrade Q4', StageName = 'Needs Analysis', CloseDate = today.addDays(45), Amount = 120000, Type = 'New Business', LeadSource = 'Web', Description = 'Evaluate migration to new cloud infrastructure.'));
            oppsToInsert.add(new Opportunity(AccountId = accId, Name = 'GlobalCorp - AI Integration Services', StageName = 'Prospecting', CloseDate = today.addDays(75), Amount = 85000, Type = 'New Business', LeadSource = 'Partner Referral', Description = 'Potential project for integrating AI into customer support workflows.'));
        }
        if(insertedAccountsMap.containsKey('Innovate Solutions Inc')){
            Id accId = insertedAccountsMap.get('Innovate Solutions Inc').Id;
            oppsToInsert.add(new Opportunity(AccountId = accId, Name = 'Innovate Inc - Analytics Suite Expansion', StageName = 'Proposal/Price Quote', CloseDate = today.addDays(20), Amount = 75000, Type = 'Existing Business', Probability = 75, Description = 'Expand existing analytics implementation with advanced modules.'));
            // Closed Won Opportunity Example
            oppsToInsert.add(new Opportunity(AccountId = accId, Name = 'Innovate Inc - Phase 1 Deployment (Completed)', StageName = 'Closed Won', CloseDate = today.addDays(-90), Amount = 50000, Type = 'Existing Business', Probability = 100));
        }
        if(insertedAccountsMap.containsKey('Summit Enterprises Ltd')){
            Id accId = insertedAccountsMap.get('Summit Enterprises Ltd').Id;
            oppsToInsert.add(new Opportunity(AccountId = accId, Name = 'Summit Ent - Legacy System Migration Assessment', StageName = 'Prospecting', CloseDate = today.addDays(90), Amount = 200000, Type = 'New Business', Description = 'Initial assessment phase for migrating off outdated manufacturing system.'));
            // Closed Lost Opportunity Example
            oppsToInsert.add(new Opportunity(AccountId = accId, Name = 'Summit Ent - IoT Sensor Trial (Lost)', StageName = 'Closed Lost', CloseDate = today.addDays(-60), Amount = 30000, Type = 'New Business'));
        }
        if(insertedAccountsMap.containsKey('Alpha Medical Devices')){
            Id accId = insertedAccountsMap.get('Alpha Medical Devices').Id;
            oppsToInsert.add(new Opportunity(AccountId = accId, Name = 'Alpha Medical - Imaging Software Upgrade', StageName = 'Value Proposition', CloseDate = today.addDays(60), Amount = 250000, Type = 'Existing Business', Probability = 50, Description='Upgrade MRI software across 5 hospital systems.'));
        }


        // --- 6. Insert Opportunities ---
        Map<String, Opportunity> insertedOppsMap = new Map<String, Opportunity>();
        if(!oppsToInsert.isEmpty()){
            try {
                List<Database.SaveResult> oppResults = Database.insert(oppsToInsert, false);
                for(Integer i=0; i<oppResults.size(); i++){
                    if(oppResults[i].isSuccess()){
                        Opportunity opp = oppsToInsert[i];
                        opp.Id = oppResults[i].getId(); // Assign returned ID
                        insertedOppsMap.put(opp.Name, opp);
                        resultMap.put('Opportunity:' + opp.Name, opp.Id);
                    } else {
                        logDmlErrors('Opportunity Insert', oppResults[i].getErrors());
                    }
                }
                System.debug(LoggingLevel.INFO, 'Inserted ' + insertedOppsMap.size() + ' Opportunity records.');
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Critical error inserting Opportunities: ' + e.getMessage());
                // Continue processing Tasks
            }
        }


        // --- 7. Prepare Tasks ---
        Id globalOpp1Id = insertedOppsMap.get('GlobalCorp - Cloud Platform Upgrade Q4')?.Id;
        Id innovateOpp1Id = insertedOppsMap.get('Innovate Inc - Analytics Suite Expansion')?.Id;
        Id sarahEvansId = insertedContactsMap.get('s.evans@globalcorp.example.com')?.Id;
        Id priyaPatelId = insertedContactsMap.get('priya.patel@innovate.example.com')?.Id;
        Id davidJonesId = insertedContactsMap.get('david.jones@innovate.example.com')?.Id;
        Id summitAccId = insertedAccountsMap.get('Summit Enterprises Ltd')?.Id; // Task linked directly to Account


        // Task 1: Future task for an Opportunity and Contact
        if(globalOpp1Id != null && sarahEvansId != null){
            tasksToInsert.add(new Task(Subject = 'Follow up with Sarah Evans re: Cloud Platform', Status = 'Not Started', Priority='High', ActivityDate = today.addDays(3), WhatId = globalOpp1Id, WhoId = sarahEvansId, Description='Discuss technical requirements gathered during initial call.'));
        }
        // Task 2: In progress task for another Opportunity/Contact
        if(innovateOpp1Id != null && priyaPatelId != null){
            tasksToInsert.add(new Task(Subject = 'Prepare Analytics Suite Proposal', Status = 'In Progress', Priority='Normal', ActivityDate = today.addDays(7), WhatId = innovateOpp1Id, WhoId = priyaPatelId, Description='Draft proposal document based on revised scope. Include pricing options.'));
        }
        // Task 3: Completed Task
        if(innovateOpp1Id != null && priyaPatelId != null){
            tasksToInsert.add(new Task(Subject = '[Past] Call with Priya Patel - Discussed Pricing', Status = 'Completed', Priority='Normal', ActivityDate = today.addDays(-5), WhatId = innovateOpp1Id, WhoId = priyaPatelId, Description='Agreed on initial pricing structure. Sent follow-up email.'));
        }
        // Task 4: Task linked only to Account (Prospect)
        if(summitAccId != null) {
            tasksToInsert.add(new Task(Subject = 'Research Summit Enterprises existing systems', Status = 'Not Started', Priority = 'Low', ActivityDate = today.addDays(10), WhatId = summitAccId, Description = 'Understand their current manufacturing tech stack before the assessment call.'));
        }
        // Task 5: Task linked to another contact at Innovate
        if (innovateOpp1Id != null && davidJonesId != null) {
            tasksToInsert.add(new Task(Subject = 'Coordinate demo schedule with David Jones', Status = 'Waiting on someone else', Priority='Normal', ActivityDate = today.addDays(2), WhatId = innovateOpp1Id, WhoId = davidJonesId));
        }

        // --- 8. Insert Tasks ---
        if(!tasksToInsert.isEmpty()){
            try {
                List<Database.SaveResult> taskResults = Database.insert(tasksToInsert, false);
                Integer successCount = 0;
                for(Integer i=0; i<taskResults.size(); i++){
                    if(taskResults[i].isSuccess()){
                        successCount++;
                    } else {
                        logDmlErrors('Task Insert', taskResults[i].getErrors());
                    }
                }
                System.debug(LoggingLevel.INFO, 'Inserted ' + successCount + ' Task records.');
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Critical error inserting Tasks: ' + e.getMessage());
            }
        }

        System.debug(LoggingLevel.INFO, 'Finished seedSalesData generation.');
        return resultMap;
    }


    /**
     * @description Helper to log DML errors from SaveResult/UpsertResult lists.
     * @param operation Name of the operation (e.g., "Account Insert").
     * @param errors List of Database.Error objects.
     */
    private static void logDmlErrors(String operation, List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) return;

        for (Database.Error err : errors) {
            String fieldString = err.getFields() == null ? '' : ' Fields: ' + String.join(err.getFields(), ', ');
            System.debug(LoggingLevel.ERROR, 'Error during DML Operation "' + operation +
                    '": StatusCode=' + err.getStatusCode() +
                    fieldString +
                    ' | Message=' + err.getMessage());
        }
    }
}