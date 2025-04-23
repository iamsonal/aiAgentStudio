
public with sharing class AgentTestDataFactory {

    private static final String DEF_CREATE_OPP = 'StdAction_CreateOpportunity';
    private static final String DEF_CREATE_TASK = 'StdAction_CreateTask';
    private static final String DEF_POST_CHATTER = 'StdAction_PostChatter';
    private static final String DEF_UPDATE_OPP = 'StdAction_UpdateOpportunity';

    // Handler Class Names (Ensure these are correct)
    private static final String HNDLR_CREATE_RECORD = ActionCreateRecord.class.getName();
    private static final String HNDLR_POST_CHATTER = ActionPostChatter.class.getName();
    private static final String HNDLR_UPDATE_RECORD = ActionUpdateRecord.class.getName();

    public static void setupSalesCopilotData() {
        LLMConfiguration__c llmConfig = createLLMConfiguration(
            'SalesCopilotOpenAIConfig',
            OpenAIProviderAdapter.class.getName(),
            'OpenAI_API',
            'gpt-4o-mini',
            0.1
        );

        AIAgentDefinition__c salesAgent = createSalesCopilotAgentDefinition(llmConfig.Id);

        setupStandardActionsAndBindings(salesAgent.Id);

        seedSalesData();
    }

    public static void setupStandardActionsAndBindings(Id agentDefId) {
        // 1. Prepare Action Definitions in Memory
        List<ActionDefinition__c> actionDefs = prepareActionDefinitions();

        // 2. Upsert Action Definitions (Idempotent based on DeveloperName__c)
        insert actionDefs;

        // 3. Get Action Definition IDs (Querying ensures we have IDs for existing & new)
        Map<String, Id> actionDefIdMap = getActionDefinitionIds(new Set<String>{
                DEF_CREATE_OPP, DEF_CREATE_TASK, DEF_POST_CHATTER, DEF_UPDATE_OPP
        });

        // 4. Prepare Agent Capability Bindings
        List<AgentCapabilityBinding__c> bindings = prepareCapabilityBindings(agentDefId, actionDefIdMap);

        // 5. Insert Agent Capability Bindings (Checking for existing bindings first)
        insertNewCapabilityBindings(bindings);

        System.debug(LoggingLevel.INFO, 'Standard Action Definition and Binding setup completed for Agent ID: ' + agentDefId);
    }

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
            throw e; // Rethrow as this is critical for binding
        }
        System.debug(LoggingLevel.DEBUG, 'Retrieved ' + idMap.size() + ' Action Definition IDs.');
        return idMap;
    }

    private static List<AgentCapabilityBinding__c> prepareCapabilityBindings(Id agentDefId, Map<String, Id> actionDefIdMap) {
        System.debug(LoggingLevel.DEBUG, 'Preparing AgentCapabilityBinding objects in memory for Agent ID: ' + agentDefId);
        List<AgentCapabilityBinding__c> bindings = new List<AgentCapabilityBinding__c>();
        Integer order = 10;

        // Capability Binding Developer Names (Unique PER AGENT)
        String BINDING_NAME_CREATE_OPP = 'Capability_CreateOpportunity';
        String BINDING_NAME_CREATE_TASK = 'Capability_CreateTask';
        String BINDING_NAME_POST_CHATTER = 'Capability_PostToChatter';
        String BINDING_NAME_UPDATE_OPP = 'Capability_UpdateOpportunity';

        // Binding Configs
        String createOppConfigJson = '{"objectApiName": "Opportunity"}';
        String createTaskConfigJson = '{"objectApiName": "Task"}';
        String updateOppConfigJson = '{"objectApiName": "Opportunity"}';

        // ** Create Binding for Create Opportunity **
        Id createOppDefId = actionDefIdMap.get(DEF_CREATE_OPP);
        if (createOppDefId != null) {
            bindings.add(createAgentCapabilityBindingInMemory(
                    agentDefId, createOppDefId, BINDING_NAME_CREATE_OPP, order,
                    'Creates a new Opportunity record. You MUST provide Name, AccountId, StageName, and CloseDate. Amount is recommended.',
                    getActionInputSchema(actionDefIdMap, DEF_CREATE_OPP), // Copy schema from Action Def
                    createOppConfigJson
            ));
            order += 10;
        } else { System.debug(LoggingLevel.WARN, 'Could not create binding for CreateOpportunity - ActionDefinition not found.'); }

        // ** Create Binding for Create Task **
        Id createTaskDefId = actionDefIdMap.get(DEF_CREATE_TASK);
        if (createTaskDefId != null) {
            bindings.add(createAgentCapabilityBindingInMemory(
                    agentDefId, createTaskDefId, BINDING_NAME_CREATE_TASK, order,
                    'Creates a new Task record for follow-up. Requires at least a Subject. Optionally relate it to an Opportunity, Account, Contact or Lead.',
                    getActionInputSchema(actionDefIdMap, DEF_CREATE_TASK), // Copy schema from Action Def
                    createTaskConfigJson
            ));
            order += 10;
        } else { System.debug(LoggingLevel.WARN, 'Could not create binding for CreateTask - ActionDefinition not found.'); }

        // ** Create Binding for Post Chatter **
        Id postChatterDefId = actionDefIdMap.get(DEF_POST_CHATTER);
        if (postChatterDefId != null) {
            bindings.add(createAgentCapabilityBindingInMemory(
                    agentDefId, postChatterDefId, BINDING_NAME_POST_CHATTER, order,
                    'Posts a message to a specific Chatter feed (Record, User, or Group). Requires feed type, target ID, and text.',
                    getActionInputSchema(actionDefIdMap, DEF_POST_CHATTER), // Copy schema from Action Def
                    null // No action config needed for PostChatter handler
            ));
            order += 10;
        } else { System.debug(LoggingLevel.WARN, 'Could not create binding for PostChatter - ActionDefinition not found.'); }

        // ** Create Binding for Update Opportunity **
        Id updateOppDefId = actionDefIdMap.get(DEF_UPDATE_OPP);
        if (updateOppDefId != null) {
            bindings.add(createAgentCapabilityBindingInMemory(
                    agentDefId, updateOppDefId, BINDING_NAME_UPDATE_OPP, order,
                    'Updates one or more fields on an existing Opportunity. Requires the 18-character Opportunity ID (recordId) and the fields/values to update.',
                    getActionInputSchema(actionDefIdMap, DEF_UPDATE_OPP), // Copy schema from Action Def
                    updateOppConfigJson
            ));
            order += 10;
        } else { System.debug(LoggingLevel.WARN, 'Could not create binding for UpdateOpportunity - ActionDefinition not found.'); }

        System.debug(LoggingLevel.DEBUG, 'Prepared ' + bindings.size() + ' AgentCapabilityBinding objects.');
        return bindings;
    }

    private static AgentCapabilityBinding__c createAgentCapabilityBindingInMemory(
            Id agentDefId, Id actionDefId, String bindingDevName, Integer execOrder,
            String descriptionForLlm, String inputSchemaForLlm, String actionConfigJson)
    {
        return new AgentCapabilityBinding__c(
                AIAgentDefinition__c = agentDefId,
                ActionDefinition__c = actionDefId,
                DeveloperName__c = bindingDevName, // Unique name for the *binding* per agent
                ExecutionOrder__c = execOrder,
                Description__c = descriptionForLlm, // Description for LLM's use
                InputSchema__c = inputSchemaForLlm, // Input structure for LLM
                ActionConfiguration__c = actionConfigJson, // Backend config for Action Handler
                IsActive__c = true
        );
    }

    private static String getActionInputSchema(Map<String, Id> actionDefIdMap, String actionDefDevName) {
        // This relies on querying the ActionDefinition object again or caching the full object
        // For simplicity in setup script, query it directly. Optimize if performance is critical.
        Id actionId = actionDefIdMap.get(actionDefDevName);
        if (actionId == null) return '{}'; // Default empty schema if action def wasn't found/created

        List<ActionDefinition__c> defs = [SELECT InputParameterSchema__c
        FROM ActionDefinition__c
        WHERE Id = :actionId];
        return defs.isEmpty() ? '{}' : defs[0].InputParameterSchema__c;
    }

    private static List<ActionDefinition__c> prepareActionDefinitions() {
        System.debug(LoggingLevel.DEBUG, 'Preparing ActionDefinition objects in memory...');
        List<ActionDefinition__c> definitions = new List<ActionDefinition__c>();

        // --- JSON Schemas (as defined previously) ---
        String createOppSchema = '{"type":"object","description":"Field data for the new Opportunity record.","properties":{"Name":{"type":"string","description":"Required. The name for the new Opportunity."},"AccountId":{"type":"string","description":"Required. The 18-character Salesforce ID of the Account this Opportunity belongs to."},"StageName":{"type":"string","description":"Required. The API name of the initial sales stage (e.g., \'Prospecting\', \'Needs Analysis\'). Must be a valid, active stage name."},"CloseDate":{"type":"string","format":"date","description":"Required. The estimated close date for the Opportunity (YYYY-MM-DD)."},"Amount":{"type":"number","description":"Optional. The estimated value or amount of the Opportunity."},"Description":{"type":"string","description":"Optional. A brief description or notes about the Opportunity."}},"required":["Name","AccountId","StageName","CloseDate"]}';
        String createTaskSchema = '{"type":"object","description":"Field data for the new Task record.","properties":{"Subject":{"type":"string","description":"Required. The subject line summarizing the task."},"WhatId":{"type":"string","description":"Optional. The 18-character Salesforce ID of a related record (e.g., Opportunity, Account, Case)."},"WhoId":{"type":"string","description":"Optional. The 18-character Salesforce ID of a related Contact or Lead."},"ActivityDate":{"type":"string","format":"date","description":"Optional. The due date for the task (YYYY-MM-DD). Defaults to today if not provided."},"Status":{"type":"string","description":"Optional. The status of the task (e.g., \'Not Started\', \'In Progress\'). Defaults based on system setup."},"Priority":{"type":"string","description":"Optional. The priority of the task (e.g., \'Normal\', \'High\'). Defaults based on system setup."},"Description":{"type":"string","description":"Optional. Detailed description or notes for the task."}},"required":["Subject"]}';
        String postChatterSchema = '{"type":"object","description":"Parameters for posting to a Chatter feed.","properties":{"feedType":{"type":"string","enum":["Record","User","Group"],"description":"Required. Specifies the type of feed to post to. Use \'Record\' to post to an Opportunity feed."},"targetId":{"type":"string","description":"Required. The 18-character Salesforce ID of the target Record, User, or Group."},"text":{"type":"string","description":"Required. The content of the message to post."}},"required":["feedType","targetId","text"]}';
        String updateOppSchema = '{"type":"object","description":"Specifies the Opportunity record to update and the fields to change.","properties":{"recordId":{"type":"string","description":"Required. The 18-character Salesforce ID of the Opportunity to update."}},"required":["recordId"],"additionalProperties":{"description":"Provide additional key-value pairs where the key is the Field API Name to update (e.g., \'Description\', \'NextStep\') and the value is the new field value."}}';

        // --- Binding Config Schemas (Ensure objectApiName is required) ---
        String oppBindingSchema = '{"type":"object","properties":{"objectApiName":{"type":"string","description":"Binding Configuration: MUST be \'Opportunity\' for this specific Action Definition."}},"required":["objectApiName"]}';
        String taskBindingSchema = '{"type":"object","properties":{"objectApiName":{"type":"string","description":"Binding Configuration: MUST be \'Task\' for this specific Action Definition."}},"required":["objectApiName"]}';


        // --- Create Action Definition SObjects ---
        definitions.add(createActionDefinitionInMemory(
                'Create Opportunity Record', DEF_CREATE_OPP, 'Standard', 'CreateRecord', HNDLR_CREATE_RECORD,
                '(Standard Action) Creates a new Opportunity record based on provided field data. Requires Name, AccountId, StageName, and CloseDate. Optionally accepts Amount and Description. Returns the ID of the newly created Opportunity.',
                createOppSchema, oppBindingSchema
        ));
        definitions.add(createActionDefinitionInMemory(
                'Create Task Record', DEF_CREATE_TASK, 'Standard', 'CreateRecord', HNDLR_CREATE_RECORD,
                '(Standard Action) Creates a new Task record, typically for follow-up. Can be related to other records like Opportunity (WhatId) or Contact (WhoId). Returns the ID of the new Task.',
                createTaskSchema, taskBindingSchema
        ));
        definitions.add(createActionDefinitionInMemory(
                'Post Message to Chatter Feed', DEF_POST_CHATTER, 'Standard', 'PostChatter', HNDLR_POST_CHATTER,
                '(Standard Action) Posts a message to a Salesforce Chatter feed. Supports posting to a Record, User, or Group feed.',
                postChatterSchema, null // No specific binding config needed for this standard action
        ));
        definitions.add(createActionDefinitionInMemory(
                'Update Opportunity Record', DEF_UPDATE_OPP, 'Standard', 'UpdateRecord', HNDLR_UPDATE_RECORD,
                '(Standard Action) Updates fields on an existing Opportunity record. Requires the record ID and a map of fields to update.',
                updateOppSchema, oppBindingSchema
        ));

        System.debug(LoggingLevel.DEBUG, 'Prepared ' + definitions.size() + ' ActionDefinition objects.');
        return definitions;
    }

    private static ActionDefinition__c createActionDefinitionInMemory(
            String label, String devName, String implType, String stdActionType, String implName,
            String description, String inputSchemaJson, String bindingSchemaJson)
    {
        ActionDefinition__c actionDef = new ActionDefinition__c(
                Name = label,
                DeveloperName__c = devName,
                ImplementationType__c = implType,
                StandardActionType__c = (implType == 'Standard' ? stdActionType : null),
                ImplementationName__c = (implType == 'Standard' ? implName : null), // Store handler for Standard
                Description__c = description,
                InputParameterSchema__c = inputSchemaJson,
                ConfigurationSchema__c = bindingSchemaJson,
                IsActive__c = true
        );
        return actionDef;
    }

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
            desiredBindingMap.put(binding.DeveloperName__c.toLowerCase(), binding); // Lowercase for lookup
        }

        // Query existing bindings for this specific agent by DeveloperName
        Set<String> existingBindingDevNames = new Set<String>();
        for (AgentCapabilityBinding__c existing : [
                SELECT DeveloperName__c FROM AgentCapabilityBinding__c
                WHERE AIAgentDefinition__c = :agentDefId
                AND DeveloperName__c IN :desiredBindingDevNames
        ]) {
            existingBindingDevNames.add(existing.DeveloperName__c.toLowerCase());
        }

        // Filter out bindings that already exist
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

        // Insert the truly new bindings
        System.debug(LoggingLevel.INFO, 'Inserting ' + bindingsToInsert.size() + ' NEW Agent Capability Bindings for Agent ID: ' + agentDefId);
        List<Database.SaveResult> results = Database.insert(bindingsToInsert, false);
    }

    private static LLMConfiguration__c createLLMConfiguration(
        String devName,
        String adapterClass,
        String namedCred,
        String modelId,
        Decimal temperature
    ) {
        LLMConfiguration__c config = new LLMConfiguration__c(
            Name = 'Sales Copilot OpenAI Config',
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
                '- Refer to the available actions (tools) list provided to understand your capabilities.';

        AIAgentDefinition__c agentDef = new AIAgentDefinition__c(
                Name = 'Sales Copilot Agent',
                DeveloperName__c = 'SalesCopilot',
                LLMConfiguration__c = llmConfigId,
                SystemPrompt__c = systemPrompt,
                IncludeSystemPromptInHistory__c = true,
                IsActive__c = true,
                Description__c = 'AI assistant focused on supporting Sales Reps within Sales Cloud.',
                CombineRecordAndUserContext__c = true
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