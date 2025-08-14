/**
 * @description Test data factory for creating the complete "Support Copilot" showcase.
 *              This includes a highly capable support agent and a rich, interconnected dataset
 *              of Accounts, Contacts, Products, Assets, Cases, and a Chatter Group.
 *              This factory is designed to be executed once to set up a demo environment.
 *
 * @important See class comments for critical manual setup prerequisites before running.
 */
public with sharing class AgentTestDataFactory {
    // A map to hold key record IDs for interlinking data
    private static Map<String, Id> idMap = new Map<String, Id>();

    /**
     * @description Main entry point. Deletes previous data and creates the entire showcase setup.
     * @return Map<String, Id> A map of key record names to their newly created Ids for easy reference.
     */
    public static Map<String, Id> createSupportShowcaseData() {
        System.debug('Starting Support Copilot showcase data setup...');

        // Clean up previous data to ensure a fresh start
        deleteExistingData();

        // 1. Seed the foundational data (Account, Contacts, Products, etc.)
        seedCoreData();
        seedKnowledgeArticles();

        // 2. Setup the LLM and Agent configurations
        LLMConfiguration__c llmConfig = createLLMConfiguration();
        setupSupportCopilotAgent(llmConfig.Id);

        System.debug(LoggingLevel.INFO, 'Support Copilot showcase data created successfully.');
        System.debug('Key Record IDs: ' + JSON.serializePretty(idMap));
        return idMap;
    }

    private static void deleteExistingData() {
        System.debug('Deleting existing framework and showcase data...');
        try {
            // Delete in order to avoid dependency errors
            delete [SELECT Id FROM OrchestrationLog__c];
            delete [SELECT Id FROM HumanApprovalRequest__c];
            delete [SELECT Id FROM ChatMessage__c];
            delete [SELECT Id FROM ChatSession__c];
            delete [SELECT Id FROM AgentCapability__c];
            delete [SELECT Id FROM AgentContextConfig__c];
            delete [SELECT Id FROM AIAgentDefinition__c];
            delete [SELECT Id FROM LLMConfiguration__c];

            delete [SELECT Id FROM Contract];
            delete [SELECT Id FROM Case];
            delete [SELECT Id FROM Asset];
            delete [SELECT Id FROM Contact WHERE Account.Name LIKE 'Momentum Motors%'];
            delete [SELECT Id FROM Account WHERE Name != 'Sample Account for Entitlements'];
            delete [SELECT Id FROM CollaborationGroup WHERE Name = 'Tier 3 Engineering Support'];
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not fully clean previous data. This may be the first run. Error: ' + e.getMessage());
        }
    }

    // =========================================================================
    // == AGENT AND CAPABILITY SETUP
    // =========================================================================

    public static LLMConfiguration__c createLLMConfiguration() {
        LLMConfiguration__c[] existing = [SELECT Id FROM LLMConfiguration__c WHERE DeveloperName__c = 'OpenAI' LIMIT 1];
        if (!existing.isEmpty()) {
            System.debug('Found existing LLM Configuration.');
            return existing[0];
        }

        System.debug('Creating new LLM Configuration...');
        LLMConfiguration__c config = new LLMConfiguration__c(
            Name = 'OpenAI',
            DeveloperName__c = 'OpenAI',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API', // Make sure a Named Credential with this name exists
            DefaultModelIdentifier__c = 'gpt-4o-mini',
            DefaultTemperature__c = 0.1,
            IsActive__c = true,
            MaxRetryAttempts__c = 2,
            InitialRetryDelayMillis__c = 750,
            RetryableHttpStatusCodes__c = '408,429,500,502,503,504'
        );
        insert config;
        return config;
    }

    private static void setupSupportCopilotAgent(Id llmConfigId) {
        System.debug('Setting up Support Copilot Agent...');

        String identityPrompt =
            'You are a helpful, empathetic technical support expert at Apex Industrial Manufacturing. ' +
            'You specialize in resolving issues with automation products like robotic arms and conveyor systems. ' +
            'Use internal tools and knowledge to solve problems step-by-step.';

        List<String> instructionParts = new List<String>{
            '**Interaction Guidelines:**',
            '- Always address the user politely and professionally.',
            '- When a new chat starts, first understand the user\'s issue. Use the provided context to see their case details and asset information.',
            '- Before suggesting complex actions, first use the `search_knowledge_base` tool to see if a standard troubleshooting guide exists.',
            '- Do not use the \'escalate_to_engineering\' or \'dispatch_technician\' tools unless the user explicitly asks for an escalation or a technician, or agrees to your suggestion to use one.',
            '- CRITICAL RULE: If the user\'s request could refer to more than one Asset or Case in the provided context, you MUST use the find_support_record tool first. DO NOT make assumptions.',
            '- Adhere strictly to the confirmation and approval protocols described in the tool descriptions. If a tool requires confirmation, your first response MUST be a simple confirmation question.'
        };
        String instructionsPrompt = String.join(instructionParts, '\n\n');

        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Support Copilot',
            DeveloperName__c = 'Support_Copilot',
            IsActive__c = true,
            MemoryStrategy__c = 'Buffer Window',
            LLMConfiguration__c = llmConfigId,
            HistoryLimit__c = 12,
            WelcomeMessageTemplate__c = 'Hi {User.FirstName}, I am the Support Copilot. I see you have an open case. How can I help you with it today?',
            IdentityPrompt__c = identityPrompt,
            InstructionsPrompt__c = instructionsPrompt
        );
        insert agent;
        idMap.put('Support Copilot Agent', agent.Id);

        // --- Capabilities ---
        System.debug('Creating capabilities for Support Copilot...');
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>();

        capabilities.add(
                createCapability(
                        agent.Id,
                        'get_case_details',
                        'Retrieves the current status, priority, and subject of a specific case by its Case Number.',
                        '{"type":"object","properties":{"filters":{"type":"object","properties":{"CaseNumber":{"type":"string"}}}}}',
                        'Standard',
                        'GetRecords',
                        null,
                        '{"objectApiName":"Case"}',
                        false,
                        false,
                        10,
                        false
                )
        );
        capabilities.add(
                createCapability(
                        agent.Id,
                        'find_support_record',
                        'Performs a fuzzy search for a specific Asset (by serial number) or a Case (by subject). Use this if the user\'s request is ambiguous.',
                        '{"type":"object","properties":{"searchQuery":{"type":"string"}},"required":["searchQuery"]}',
                        'Standard',
                        'FindEntities',
                        null,
                        null,
                        false,
                        false,
                        20,
                        false
                )
        );
        capabilities.add(
                createCapability(
                        agent.Id,
                        'search_knowledge_base',
                        'Searches the internal knowledge base for troubleshooting guides and articles. Can filter by category (e.g., {"dataCategory": {"Robotic_Arms":"Troubleshooting"}}).',
                        '{"type":"object","properties":{"searchQuery":{"type":"string"},"dataCategory":{"type":"object"}},"required":["searchQuery"]}',
                        'Standard',
                        'SearchKnowledge',
                        null,
                        null,
                        false,
                        false,
                        30,
                        false
                )
        );
        capabilities.add(
                createCapability(
                        agent.Id,
                        'add_internal_comment',
                        'Adds an internal-only comment to the case feed for documentation.',
                        '{"type":"object","properties":{"parentId":{"type":"string"}, "commentBody":{"type":"string"}},"required":["parentId","commentBody"]}',
                        'Standard',
                        'CreateRecord',
                        null,
                        '{"objectApiName":"CaseComment"}',
                        false,
                        false,
                        40,
                        false
                )
        );
        // This capability is now INTERNAL, used by the graph.
        capabilities.add(
                new AgentCapability__c(
                        AIAgentDefinition__c = agent.Id,
                        CapabilityName__c = 'escalate_to_engineering',
                        Description__c = 'Posts a message to the internal engineering team\'s Chatter group.',
                        Parameters__c = '{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}',
                        ImplementationType__c = 'Standard',
                        StandardActionType__c = 'PostChatter',
                        BackendConfiguration__c = '{"feedType":"Group","targetId":"' + idMap.get('Chatter Group ID') + '"}',
                        ExposureLevel__c = 'Internal' // Make this internal-only
                )
        );
        // This capability is now INTERNAL, used by the graph.
        capabilities.add(
                new AgentCapability__c(
                        AIAgentDefinition__c = agent.Id,
                        CapabilityName__c = 'log_issue_externally',
                        Description__c = 'Logs the case details in an external system (Jira).',
                        Parameters__c = '{"type":"object","properties":{"caseId":{"type":"string"}},"required":["caseId"]}',
                        ImplementationType__c = 'Apex',
                        ImplementationDetail__c = 'ActionLogIssueExternally',
                        RunAsynchronously__c = true,
                        ExposureLevel__c = 'Internal' // Make this internal-only
                )
        );
        capabilities.add(
                createCapability(
                        agent.Id,
                        'close_the_case',
                        'Updates the case status to "Closed." IMPORTANT: You must ask the user for confirmation before using this tool.',
                        '{"type":"object","properties":{"recordId":{"type":"string"},"Status":{"type":"string","enum":["Closed"]}},"required":["recordId","Status"]}',
                        'Standard',
                        'UpdateRecord',
                        null,
                        '{"objectApiName":"Case"}',
                        true,
                        false,
                        70,
                        false
                )
        );

        String creditDescription = 'Creates a formal service credit request as a draft contract for manager approval.';
        String creditParams = '{"type":"object","properties":{"AccountId":{"type":"string", "description": "The ID of the customer Account to associate the credit with."}, "StartDate":{"type":"string", "format":"date", "description":"The effective date for the credit, usually today."}, "Description":{"type":"string", "description":"A clear justification for the service credit explaining why it is being offered."}},"required":["AccountId", "StartDate", "Description"]}';
        String creditBackendConfig = '{"objectApiName":"Contract", "defaultFieldValues": {"Status":"Draft", "ContractTerm": 1}}';
        capabilities.add(
                createCapability(
                        agent.Id,
                        'issue_service_credit',
                        creditDescription,
                        creditParams,
                        'Standard',
                        'CreateRecord',
                        null,
                        creditBackendConfig,
                        false,
                        true,
                        80,
                        false
                )
        );

        insert capabilities;

        Map<String, Id> primitiveCapsMap = new Map<String, Id>();
        for (AgentCapability__c cap : capabilities) {
            primitiveCapsMap.put(cap.CapabilityName__c, cap.Id);
        }
        AgentCapability__c graphCap = setupEscalationGraph(agent.Id, primitiveCapsMap);

        // --- Context Providers ---
        System.debug('Creating context providers for Support Copilot...');
        List<AgentContextConfig__c> contexts = new List<AgentContextConfig__c>();
        contexts.add(createContextConfig(agent.Id, 'User Details', 'UserDetailsProvider', null, false, 10, null));
        contexts.add(createContextConfig(agent.Id, 'Case Details', 'CaseContext', 'Case', true, 20, null));
        contexts.add(createContextConfig(agent.Id, 'Account Support History', 'AccountSupportContext', 'Account', true, 30, null));
        insert contexts;
    }

    private static void seedCoreData() {
        System.debug('Seeding core data...');
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator'];
        User supportManager = new User(
            Alias = 'srvusr',
            Email = 'service.user@apex-industrial.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'User',
            FirstName = 'Service',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'service.user' + System.currentTimeMillis() + '@apex-industrial.com'
        );
        insert supportManager;
        idMap.put('Support Manager User', supportManager.Id);

        // Account & Contacts
        Account acc = new Account(
            Name = 'Momentum Motors',
            Industry = 'Manufacturing',
            BillingState = 'CA',
            AnnualRevenue = 950000000,
            NumberOfEmployees = 15000,
            Description = 'A key customer specializing in high-performance electric vehicle components.'
        );
        insert acc;
        idMap.put(acc.Name, acc.Id);

        Contact[] contacts = new List<Contact>{
            new Contact(
                FirstName = 'Lena',
                LastName = 'Rose',
                AccountId = acc.Id,
                Email = 'lena.rose@momentum.example.com',
                Title = 'Lead Engineer, Robotics Division'
            ),
            new Contact(
                FirstName = 'David',
                LastName = 'Chen',
                AccountId = acc.Id,
                Email = 'david.chen@momentum.example.com',
                Title = 'Director of Operations'
            )
        };
        insert contacts;
        idMap.put(contacts[0].LastName, contacts[0].Id);
        idMap.put(contacts[1].LastName, contacts[1].Id);

        // Products & Pricebook
        Pricebook2 stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1];
        Product2[] products = new List<Product2>{
            new Product2(
                Name = 'IND-ARM-v4 Robotic Arm',
                ProductCode = 'AIM-RA-V4',
                IsActive = true,
                Description = '4th generation industrial robotic arm.'
            ),
            new Product2(Name = 'CONVEYOR-BELT-S5', ProductCode = 'AIM-CB-S5', IsActive = true, Description = 'Series 5 high-speed conveyor belt.'),
            new Product2(Name = 'CNC-LATHE-X1', ProductCode = 'AIM-CNC-X1', IsActive = true, Description = 'High-precision CNC lathe.')
        };
        insert products;

        PricebookEntry[] pbes = new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = products[0].Id, UnitPrice = 75000, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = products[1].Id, UnitPrice = 22000, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = products[2].Id, UnitPrice = 120000, IsActive = true)
        };
        insert pbes;

        // Assets
        Asset[] assets = new List<Asset>{
            new Asset(
                Name = 'Robotic Arm V4 - Bay 1',
                AccountId = acc.Id,
                Product2Id = products[0].Id,
                SerialNumber = 'AIM-V4-0087',
                Status = 'Installed',
                InstallDate = Date.today().addMonths(-6)
            ),
            new Asset(
                Name = 'Robotic Arm V4 - Bay 2',
                AccountId = acc.Id,
                Product2Id = products[0].Id,
                SerialNumber = 'AIM-V4-0051',
                Status = 'Installed',
                InstallDate = Date.today().addMonths(-8)
            ),
            new Asset(
                Name = 'Main Conveyor S5',
                AccountId = acc.Id,
                Product2Id = products[1].Id,
                SerialNumber = 'AIM-CB-0112',
                Status = 'Installed',
                InstallDate = Date.today().addMonths(-18)
            )
        };
        insert assets;
        idMap.put(assets[0].SerialNumber, assets[0].Id);
        idMap.put(assets[1].SerialNumber, assets[1].Id);

        // Cases (Current & Historical)
        Case[] cases = new List<Case>{
            new Case( // The current open case
                ContactId = contacts[0].Id,
                AssetId = assets[0].Id,
                AccountId = acc.Id,
                Status = 'New',
                Priority = 'High',
                Type = 'Mechanical Failure',
                Subject = 'Actuator fault on Robotic Arm in Bay 1',
                Description = 'The main actuator on arm AIM-V4-0087 is failing under load and making a grinding noise. This is halting our production line.'
            ),
            new Case( // A previous closed case
                ContactId = contacts[0].Id,
                AssetId = assets[1].Id,
                AccountId = acc.Id,
                Status = 'Closed',
                Priority = 'Medium',
                Type = 'Software Glitch',
                Subject = 'Robotic arm in Bay 2 has intermittent software freezes',
                Description = 'The arm control software would become unresponsive. A patch was applied.'
            ),
            new Case( // Another closed case
                ContactId = contacts[0].Id,
                AssetId = assets[2].Id,
                AccountId = acc.Id,
                Status = 'Closed',
                Priority = 'Low',
                Type = 'Routine Maintenance',
                Subject = 'Question about conveyor belt lubrication schedule'
            )
        };
        insert cases;
        idMap.put('Current Open Case', cases[0].Id);

        // Chatter Group
        CollaborationGroup chatterGroup = new CollaborationGroup(Name = 'Tier 3 Engineering Support', CollaborationType = 'Private');
        insert chatterGroup;
        idMap.put('Chatter Group ID', chatterGroup.Id);
    }

    private static AgentCapability__c createCapability(
        Id agentId,
        String capName,
        String description,
        String params,
        String implType,
        String stdType,
        String implDetail,
        String backendConfig,
        Boolean requiresConfirmation,
        Boolean requiresApproval,
        Integer priority,
        Boolean runAsynchronously
    ) {
        return new AgentCapability__c(
            AIAgentDefinition__c = agentId,
            CapabilityName__c = capName,
            Description__c = description,
            Parameters__c = params,
            ImplementationType__c = implType,
            StandardActionType__c = stdType,
            ImplementationDetail__c = implDetail,
            BackendConfiguration__c = backendConfig,
            RequiresConfirmation__c = requiresConfirmation,
            RequiresApproval__c = requiresApproval,
            ExecutionPriority__c = priority,
            RunAsynchronously__c = runAsynchronously
        );
    }

    private static AgentContextConfig__c createContextConfig(
        Id agentId,
        String label,
        String implName,
        String applicableSObjects,
        Boolean requiresRecord,
        Integer order,
        String configJson
    ) {
        return new AgentContextConfig__c(
            AIAgentDefinition__c = agentId,
            ContextLabel__c = label,
            ImplementationType__c = 'Apex',
            ImplementationName__c = implName,
            ApplicableSObjectTypes__c = applicableSObjects,
            RequiresRecordContext__c = requiresRecord,
            ExecutionOrder__c = order,
            ImplementationConfigJson__c = configJson,
            IsActive__c = true
        );
    }

    private static void seedKnowledgeArticles() {
        System.debug('Seeding Knowledge Articles...');
        try {
            // 1. Create the article drafts
            Knowledge__kav article1 = new Knowledge__kav(
                Title = 'Troubleshooting the IND-ARM-v4 Actuator',
                UrlName = 'Troubleshooting-IND-ARM-v4-Actuator',
                Summary = 'This guide covers common actuator faults for the v4 robotic arm. A persistent amber light indicates a power fluctuation, while a blinking red light signifies a logic fault that may require a software reset.'
            );

            Knowledge__kav article2 = new Knowledge__kav(
                Title = 'Guide to IND-ARM-v4 Software Resets',
                UrlName = 'Guide-to-IND-ARM-v4-Software-Resets',
                Summary = 'A software reset can resolve intermittent freezes and logic faults. To perform a reset, access the main control panel, navigate to System > Diagnostics, and select "Reboot Controller". This process takes approximately 90 seconds.'
            );

            Knowledge__kav article3 = new Knowledge__kav(
                Title = 'Routine Maintenance for Conveyor Belts',
                UrlName = 'Routine-Maintenance-for-Conveyor-Belts',
                Summary = 'To ensure optimal performance, the S5 series conveyor belts require lubrication every 500 operational hours. Use only Apex-certified lubricant AIM-LUBE-G2.'
            );

            insert new List<Knowledge__kav>{ article1, article2, article3 };
            System.debug('Knowledge Article drafts created.');

            // 2. Publish the articles to make them visible
            KbManagement.PublishingService.publishArticle(article1.Id, true);
            KbManagement.PublishingService.publishArticle(article2.Id, true);
            KbManagement.PublishingService.publishArticle(article3.Id, true);
            System.debug('3 Knowledge Articles created, categorized, and published.');
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                'Could not create Knowledge Articles. Ensure Knowledge is enabled and the "Product_Categories" data category group exists. Error: ' +
                e.getMessage()
            );
        }
    }

    private static AgentCapability__c setupEscalationGraph(Id agentId, Map<String, Id> primitiveCapsMap) {
        System.debug('Setting up Escalation Graph capability...');

        // 1. Define the main "Graph" capability that the LLM will see and call.
        String graphDescription = 'Initiates a full Tier 2 escalation process. This involves adding an initial case comment, posting to the engineering team for immediate help, and logging a ticket in an external system for tracking. This is a comprehensive action.';
        String graphParams = '{"type":"object","properties":{"caseId":{"type":"string", "description": "The ID of the case to be escalated."}, "escalationReason":{"type":"string", "description": "A concise reason for the escalation to be posted to the engineering team."}},"required":["caseId", "escalationReason"]}';

        AgentCapability__c graphCapability = createCapability(
                agentId,
                'escalate_to_tier_2',
                graphDescription,
                graphParams,
                'Graph', // ImplementationType
                null,    // StandardActionType
                null,    // ImplementationDetail
                null,    // BackendConfiguration
                false,   // RequiresConfirmation
                false,   // RequiresApproval
                45,      // ExecutionPriority
                false    // RunAsynchronously (the graph itself starts sync)
        );
        insert graphCapability;

        // 2. Define the individual nodes (steps) of the graph.
        List<GraphNode__c> graphNodes = new List<GraphNode__c>();

        // Node 1: Add initial comment (Entry Point)
        graphNodes.add(
                GraphNodeBuilder.create('node_add_internal_comment')
                        .forCapability(graphCapability.Id)
                        .runCapability('add_internal_comment') // Assumes primitive capability exists
                        .asEntryPoint()
                        .mapInput('parentId', '{!input.caseId}')
                        .mapInput('commentBody', 'Escalation to Tier 2 process initiated by agent.')
                        .routeWhenSuccess('node_escalate_to_engineering')
                        .build()
        );

        // Node 2: Post to engineering team
        graphNodes.add(
                GraphNodeBuilder.create('node_escalate_to_engineering')
                        .forCapability(graphCapability.Id)
                        .runCapability('escalate_to_engineering')
                        .mapInput('text', '{!input.escalationReason}')
                        .routeWhenSuccess('node_log_issue_externally')
                        .build()
        );

        // Node 3: Log in external system (Async)
        graphNodes.add(
                GraphNodeBuilder.create('node_log_issue_externally')
                        .forCapability(graphCapability.Id)
                        .runCapability('log_issue_externally')
                        .startAsync()
                        .mapInput('caseId', '{!input.caseId}')
                        .routeWhenSuccess('node_add_internal_comment_1')
                        .build()
        );

        // Node 4: Add final comment with ticket reference (Exit Node)
        graphNodes.add(
                GraphNodeBuilder.create('node_add_internal_comment_1')
                        .forCapability(graphCapability.Id)
                        .runCapability('add_internal_comment')
                        .mapInput('parentId', '{!input.caseId}')
                        .mapInput('commentBody', 'Escalation complete. External Reference: {!node.node_log_issue_externally.output.data.externalTicketId}')
                        .build()
        );

        insert graphNodes;
        System.debug(graphNodes.size() + ' graph nodes created for ' + graphCapability.CapabilityName__c);

        return graphCapability;
    }
}
