/**
 * @description Test data factory for the "Order Management Copilot" showcase.
 *              Creates a complete dataset of Accounts, Contacts, Orders, Cases, Knowledge,
 *              and configures the AI Agent with all necessary capabilities, including a multi-step graph.
 *
 * @important Manual Setup Prerequisites before running:
 * 1. A Named Credential with the API Name 'OpenAI_API' must exist.
 * 2. The current user must have permissions to create/publish Knowledge Articles.
 * 3. A Queue named 'HITL Queue' must exist and be assigned to the HumanApprovalRequest__c object.
 * 4. An active Approval Process for HumanApprovalRequest__c must exist.
 */
public with sharing class AgentTestDataFactory {
    // A map to hold key record IDs for interlinking data
    private static Map<String, Id> idMap = new Map<String, Id>();

    /**
     * @description Main entry point. Deletes previous data and creates the entire showcase setup.
     * @return Map<String, Id> A map of key record names to their newly created Ids for easy reference.
     */
    public static Map<String, Id> createSupportShowcaseData() {
        System.debug('Starting Order Management Copilot showcase data setup...');

        // Clean up previous data to ensure a fresh start
        deleteExistingData();

        // 1. Seed the foundational data (Account, Contacts, Products, etc.)
        seedCoreData();
        seedKnowledgeArticles();

        // 2. Setup the LLM and Agent configurations
        LLMConfiguration__c llmConfig = createLLMConfiguration();
        setupOrderManagementCopilot(llmConfig.Id);

        System.debug(LoggingLevel.INFO, 'Order Management Copilot showcase data created successfully.');
        System.debug('Key Record IDs: ' + JSON.serializePretty(idMap));
        return idMap;
    }

    private static void deleteExistingData() {
        System.debug('Deleting existing framework and showcase data...');
        try {
            System.debug('Deactivating existing Orders to allow deletion...');
            List<Order> ordersToDeactivate = new List<Order>();
            for (Order o : [SELECT Id FROM Order WHERE Account.Name = 'Global Tech Inc.' AND Status = 'Activated']) {
                ordersToDeactivate.add(new Order(Id = o.Id, Status = 'Draft'));
            }
            if (!ordersToDeactivate.isEmpty()) {
                update ordersToDeactivate;
                System.debug('Deactivated ' + ordersToDeactivate.size() + ' orders.');
            }

            // Delete in order to avoid dependency errors
            delete [SELECT Id FROM AgentDecisionStep__c];
            delete [SELECT Id FROM HumanApprovalRequest__c];
            delete [SELECT Id FROM ChatMessage__c];
            delete [SELECT Id FROM ChatSession__c];
            delete [SELECT Id FROM AgentCapability__c];
            delete [SELECT Id FROM AgentContextConfig__c];
            delete [SELECT Id FROM AIAgentDefinition__c];
            delete [SELECT Id FROM LLMConfiguration__c];

            // Delete showcase data
            delete [SELECT Id FROM Case];
            delete [SELECT Id FROM OrderItem];
            delete [SELECT Id FROM Order];
            delete [SELECT Id FROM Contact WHERE Account.Name = 'Global Tech Inc.'];
            delete [SELECT Id FROM Account WHERE Name = 'Global Tech Inc.'];
            delete [SELECT Id FROM CollaborationGroup WHERE Name = 'Sales Operations'];
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not fully clean previous data. This may be the first run. Error: ' + e.getMessage());
        }
    }

    public static LLMConfiguration__c createLLMConfiguration() {
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

    private static void setupOrderManagementCopilot(Id llmConfigId) {
        System.debug('Setting up Order Management Copilot Agent...');

        String identityPrompt = 'You are an expert Order Management assistant for FinServe Resellers Inc., a premier reseller of financial software and hardware. Your primary goal is to help customers resolve issues with their orders efficiently and professionally. You must always verify the specific order or product in question before taking action.';

        List<String> instructionParts = new List<String>{
            '**Interaction Guidelines:**',
            '- Always address the user politely and professionally.',
            '**CRITICAL TROUBLESHOOTING PROTOCOL:** When a user reports any problem or issue with a product, you MUST follow these steps in order:\n1. First, use `get_order_status` or `find_support_record` to verify the exact order and product the user is referring to.\n2. Second, you MUST use the `search_knowledge_base` tool to look for troubleshooting guides or articles related to the user\'s issue. Present any relevant findings to the user.\n3. Only if the knowledge base does not solve the issue or is not applicable, you may then suggest further actions.',
            '- For issues with delivered items, guide the user toward either creating a support case or initiating a return.',
            '- **CRITICAL VERIFICATION RULE:** Your primary role is to verify user requests against the factual data provided in the <CONTEXT> block. If a user\'s statement about an order number, product, or case contradicts the provided context, you MUST politely point out the discrepancy and ask for clarification. **DO NOT proceed with an action based on incorrect user information.**'
        };
        String instructionsPrompt = String.join(instructionParts, '\n\n');

        List<String> promptFooterLines = new List<String>{
            '# FINAL INSTRUCTIONS: Verification Protocol',
            'Before responding to the user, you MUST complete the following verification steps in your internal monologue:',
            '1. **Analyze User\'s Query:** Identify all key entities mentioned by the user (e.g., order numbers, product names, case numbers).',
            '2. **Scan Provided Context:** Systematically check the entire <CONTEXT> block for these entities.',
            '3. **Verify or Contradict:**',
            '* **If the user\'s statement MATCHES the data in the <CONTEXT> block**, proceed with their request.',
            '* **If the user\'s statement CONTRADICTS the data in the <CONTEXT> block**, your immediate next response MUST be to politely point out the discrepancy and ask for clarification. Do not proceed with the user\'s incorrect assumption.',
            '* **Example of Correct Contradiction:** "I see you\'re asking about product X on order Y. My records show that order Y contained product Z, while product X was on order W. Could we be talking about order W?"',
            '4. **Final Check:** Reread your planned response to ensure it is factually consistent with the provided <CONTEXT>.'
        };
        String promptFooter = String.join(promptFooterLines, '\n');

        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Order Management Copilot',
            DeveloperName__c = 'Order_Management_Copilot',
            IsActive__c = true,
            MemoryStrategy__c = 'Buffer Window',
            LLMConfiguration__c = llmConfigId,
            HistoryTurnLimit__c = 10,
            RequiresServiceUserContext__c = true, // Critical for community user scenario
            EnableReasoningMode__c = true,
            WelcomeMessageTemplate__c = 'Hi {User.FirstName}! I am the Order Management Copilot. How can I help you with your orders today?',
            IdentityPrompt__c = identityPrompt,
            InstructionsPrompt__c = instructionsPrompt,
            PromptFooter__c = promptFooter
        );
        insert agent;
        idMap.put('Order Management Copilot Agent', agent.Id);

        // --- Context Providers ---
        System.debug('Creating context providers...');
        List<AgentContextConfig__c> contexts = new List<AgentContextConfig__c>();
        contexts.add(createContextConfig(agent.Id, 'User Details', 'UserDetailsProvider', null, false, 10, null));
        contexts.add(createContextConfig(agent.Id, 'Order Details', 'OrderContext', 'Order', true, 20, null));
        contexts.add(createContextConfig(agent.Id, 'Account Purchase History', 'AccountPurchaseHistory', 'Account', true, 30, null));
        insert contexts;

        // --- Primitive Capabilities (used by graph) ---
        System.debug('Creating internal primitive capabilities for graph...');
        List<AgentCapability__c> primitiveCaps = new List<AgentCapability__c>();
        primitiveCaps.add(
            createCapability(
                agent.Id,
                'find_order_by_id',
                'Internal: Finds a single Order and its items by its ID.',
                '{"type":"object", "properties":{"orderId":{"type":"string"}}, "required":["orderId"]}', // Simple parameter
                'Apex',
                null,
                'ActionFindOrderById',
                null,
                false,
                false,
                99,
                false,
                'Internal'
            )
        );
        primitiveCaps.add(
            createCapability(
                agent.Id,
                'create_draft_order',
                'Internal: Creates a new draft order.',
                '{"type":"object", "properties":{"AccountId":{"type":"string"}, "ContactId":{"type":"string"}}}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Order", "defaultFieldValues": {"Status":"Draft"}}',
                false,
                false,
                99,
                false,
                'Internal'
            )
        );
        primitiveCaps.add(
            createCapability(
                agent.Id,
                'clone_order_items',
                'Internal: Clones items to a new order.',
                '{"type":"object", "properties":{"sourceOrderId":{"type":"string"}, "destinationOrderId":{"type":"string"}}}',
                'Apex',
                null,
                'ActionCloneOrderItems',
                null,
                false,
                false,
                99,
                false,
                'Internal'
            )
        );
        primitiveCaps.add(
            createCapability(
                agent.Id,
                'notify_sales_ops',
                'Internal: Notifies the sales ops team.',
                '{"type":"object", "properties":{"text":{"type":"string"}}}',
                'Standard',
                'PostChatter',
                null,
                '{"feedType":"Group","targetId":"' + idMap.get('Chatter Group ID') + '"}',
                false,
                false,
                99,
                true,
                'Internal'
            )
        );
        insert primitiveCaps;

        Map<String, Id> primitiveCapsMap = new Map<String, Id>();
        for (AgentCapability__c cap : primitiveCaps) {
            primitiveCapsMap.put(cap.CapabilityName__c, cap.Id);
        }

        // --- External (LLM-Visible) Capabilities ---
        List<AgentCapability__c> externalCaps = new List<AgentCapability__c>();
        externalCaps.add(
            createCapability(
                agent.Id,
                'get_order_status',
                'Retrieves the status for an order.',
                '{"type":"object", "properties":{"filters":{"type":"object", "properties":{"OrderNumber":{"type":"string"}}}}}',
                'Standard',
                'GetRecords',
                null,
                '{"objectApiName":"Order"}',
                false,
                false,
                10,
                false,
                'External'
            )
        );
        externalCaps.add(
            createCapability(
                agent.Id,
                'search_knowledge_base',
                'Searches the knowledge base.',
                '{"type":"object", "properties":{"searchQuery":{"type":"string"}}}',
                'Standard',
                'SearchKnowledge',
                null,
                '{"defaultLanguage":"en_US"}',
                false,
                false,
                20,
                false,
                'External'
            )
        );
        externalCaps.add(
            createCapability(
                agent.Id,
                'create_support_case',
                'Creates a new support case.',
                '{"type":"object", "properties":{"AccountId":{"type":"string"}, "ContactId":{"type":"string"}, "Subject":{"type":"string"}, "Description":{"type":"string"}}}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Case", "defaultFieldValues":{"Status":"New", "Origin":"Web"}}',
                false,
                false,
                30,
                false,
                'External'
            )
        );
        externalCaps.add(
            createCapability(
                agent.Id,
                'expedite_shipping',
                'Requests expedited shipping for an order\'s replacement part. This action incurs an additional fee for the customer. When suggesting this tool, you must clearly inform the user about the potential extra cost and ask for their confirmation before proceeding.',
                '{"type":"object", "properties":{"orderId":{"type":"string"}}}',
                'Apex',
                null,
                'ActionExpediteShipping',
                null,
                true,
                false,
                40,
                true,
                'External'
            )
        );
        externalCaps.add(
            createCapability(
                agent.Id,
                'initiate_return_request',
                'Initiates a return request. Requires manager approval.',
                '{"type":"object", "properties":{"AccountId":{"type":"string"}, "ContactId":{"type":"string"}, "Subject":{"type":"string"}}}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Case", "defaultFieldValues":{"Status":"New", "Origin":"AI Return Request"}}',
                false,
                true,
                50,
                false,
                'External'
            )
        );

        String graphDescription = 'Creates a new draft order, optionally using a previous order as a template. It gathers all necessary details, clones the items, and notifies the Sales Operations team for review.';
        String graphParams = JSON.serialize(
            new Map<String, Object>{
                'type' => 'object',
                'properties' => new Map<String, Object>{
                    'sourceOrderId' => new Map<String, Object>{
                        'type' => 'string',
                        'description' => '(Optional) The ID of a previous order to use as a template for items and details.'
                    },
                    'accountId' => new Map<String, Object>{ 'type' => 'string', 'description' => 'The ID of the Account for the new order.' },
                    'billToContactId' => new Map<String, Object>{
                        'type' => 'string',
                        'description' => 'The ID of the Contact to bill for the new order.'
                    },
                    'effectiveDate' => new Map<String, Object>{
                        'type' => 'string',
                        'format' => 'date',
                        'description' => 'The start date for the new order, in YYYY-MM-DD format.'
                    },
                    'pricebook2Id' => new Map<String, Object>{ 'type' => 'string', 'description' => 'The ID of the Pricebook for the new order.' }
                },
                // Note: We don't make them all "required" here, as the graph can fetch them
                // from the sourceOrderId if provided.
                'required' => new List<String>{ 'accountId' }
            }
        );
        insert externalCaps;
    }

    private static void seedCoreData() {
        System.debug('Seeding core data...');
        Profile p = [SELECT Id FROM Profile WHERE Name = 'System Administrator'];
        User serviceUser = new User(
            Alias = 'srvusr',
            Email = 'service.user@finserve-reseller.example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'User',
            FirstName = 'Service',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            UserName = 'service.user' + System.currentTimeMillis() + '@finserve.com'
        );
        insert serviceUser;
        idMap.put('Support Manager User', serviceUser.Id);

        // Account & Contacts
        Account acc = new Account(Name = 'Global Tech Inc.', Industry = 'Technology', BillingState = 'CA');
        insert acc;
        idMap.put(acc.Name, acc.Id);

        Contact contact = new Contact(
            FirstName = 'Lena',
            LastName = 'Rose',
            AccountId = acc.Id,
            Email = 'lena.rose@globaltech.example.com',
            Title = 'Procurement Specialist'
        );
        insert contact;
        idMap.put(contact.LastName, contact.Id);

        // Products & Pricebook
        Pricebook2 stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1];
        Product2[] products = new List<Product2>{
            new Product2(Name = 'ProTrade Analytics Suite (Annual License)', ProductCode = 'PTS-AL-1Y', IsActive = true, Family = 'Software'),
            new Product2(Name = 'SecureKey Hardware Fob', ProductCode = 'SK-HF-G2', IsActive = true, Family = 'Hardware')
        };
        insert products;
        idMap.put(products[0].Name, products[0].Id);
        idMap.put(products[1].Name, products[1].Id);

        PricebookEntry[] pbes = new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = products[0].Id, UnitPrice = 5000, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = products[1].Id, UnitPrice = 150, IsActive = true)
        };
        insert pbes;

        // Orders - Step 1: Create as 'Draft'
        Order order1 = new Order(
            AccountId = acc.Id,
            BillToContactId = contact.Id,
            EffectiveDate = Date.today().addDays(-10),
            Status = 'Draft', // CORRECTED: Must be 'Draft' on insert
            Pricebook2Id = stdPb.Id
        );
        insert order1;
        idMap.put('Recent Order', order1.Id);
        OrderItem[] items1 = new List<OrderItem>{
            new OrderItem(OrderId = order1.Id, PricebookEntryId = pbes[0].Id, Quantity = 1, UnitPrice = 5000),
            new OrderItem(OrderId = order1.Id, PricebookEntryId = pbes[1].Id, Quantity = 1, UnitPrice = 150)
        };
        insert items1;

        Order order2 = new Order(
            AccountId = acc.Id,
            BillToContactId = contact.Id,
            EffectiveDate = Date.today().addMonths(-6),
            Status = 'Draft',
            Pricebook2Id = stdPb.Id
        );
        insert order2;

        // Query back for the auto-generated OrderNumber to use in the Case Subject
        order2 = [SELECT OrderNumber FROM Order WHERE Id = :order2.Id];
        OrderItem[] items2 = new List<OrderItem>{ new OrderItem(OrderId = order2.Id, PricebookEntryId = pbes[0].Id, Quantity = 1, UnitPrice = 4500) };
        insert items2;

        // Orders - Step 2: Activate the orders
        List<Order> ordersToActivate = new List<Order>();
        order1.Status = 'Activated';
        order2.Status = 'Activated';
        ordersToActivate.add(order1);
        ordersToActivate.add(order2);
        update ordersToActivate;

        // Cases
        Case closedCase = new Case(
            AccountId = acc.Id,
            ContactId = contact.Id,
            Status = 'Closed',
            Subject = 'License key activation issue for Order #' + order2.OrderNumber
        );
        insert closedCase;

        // Chatter Group
        CollaborationGroup chatterGroup = new CollaborationGroup(Name = 'Sales Operations', CollaborationType = 'Private');
        insert chatterGroup;
        idMap.put('Chatter Group ID', chatterGroup.Id);
    }

    private static void seedKnowledgeArticles() {
        System.debug('Seeding Knowledge Articles...');
        try {
            // UPDATED: Added more realistic, detailed article content.
            Knowledge__kav article1 = new Knowledge__kav(
                Title = 'Return Policy for Hardware Devices',
                UrlName = 'Hardware-Return-Policy',
                Summary = 'All hardware devices can be returned within 30 days of the delivery date, provided they are defective or were damaged upon arrival. To initiate a return, a support case must be created with a "Return Request" type. The request must include a description of the damage and a photo if possible. All return requests are subject to manager approval. Once approved, an RMA (Return Merchandise Authorization) number will be issued. The customer is responsible for shipping the defective unit back using the provided RMA label.'
            );

            Knowledge__kav article2 = new Knowledge__kav(
                Title = 'Software License Activation Guide',
                UrlName = 'Software-License-Activation',
                Summary = 'To activate your software license for products like the ProTrade Analytics Suite, please follow these steps: 1. Log in to your customer portal. 2. Navigate to the "My Orders" section and locate the relevant order. 3. Click the "Activate License" button next to the product. 4. Your license key will be automatically applied to your account. If the button is not visible or you encounter an error, please create a support case with the subject "License Activation Failure".'
            );

            Knowledge__kav article3 = new Knowledge__kav(
                Title = 'Reporting Damaged Shipments',
                UrlName = 'Reporting-Damaged-Shipments',
                Summary = 'If you receive a shipment with visible damage to the packaging or contents, please do the following within 48 hours of delivery: 1. Take clear photos of the damaged box and the damaged item(s). 2. Do not discard any packaging materials. 3. Contact our support team by creating a case and mention that the item was "Damaged in Transit". 4. A support agent will then initiate a return request on your behalf to start the replacement process.'
            );

            Knowledge__kav article4 = new Knowledge__kav(
                Title = 'Troubleshooting Damaged SecureKey Hardware Fob',
                UrlName = 'Troubleshooting-Damaged-SecureKey-Fob',
                Summary = 'If a customer reports a damaged SecureKey Hardware Fob, first verify the order. For cracked casings or bent ports, the standard procedure is to initiate a return request for manager approval. A replacement unit will be shipped upon approval. This process is handled by the "initiate_return_request" tool.'
            );

            Knowledge__kav article5 = new Knowledge__kav(
                Title = 'SecureKey Hardware Fob Not Responding',
                UrlName = 'SecureKey-Fob-Not-Working',
                Summary = 'If a SecureKey Hardware Fob is not being detected by the system, first ask the user to try a different USB port. If the issue persists, a software driver update may be required. If the device still does not work, create a support case using the "create_support_case" tool for further diagnostics.'
            );

            insert new List<Knowledge__kav>{ article1, article2, article3, article4, article5 };

            KbManagement.PublishingService.publishArticle(article1.Id, true);
            KbManagement.PublishingService.publishArticle(article2.Id, true);
            KbManagement.PublishingService.publishArticle(article3.Id, true);
            KbManagement.PublishingService.publishArticle(article4.Id, true);
            KbManagement.PublishingService.publishArticle(article5.Id, true);
            System.debug('Knowledge Articles published.');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not create Knowledge Articles. Ensure Knowledge is enabled. Error: ' + e.getMessage());
        }
    }

    // Helper to reduce boilerplate
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
        Boolean runAsynchronously,
        String exposure
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
            RunAsynchronously__c = runAsynchronously,
            ExposureLevel__c = exposure
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
}
