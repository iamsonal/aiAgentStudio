/**
 * @description Comprehensive test data factory for AI Agent Studio showcasing all agent types.
 *              Creates realistic business scenarios using standard Salesforce objects.
 *
 * **Agent Types Created:**
 * 1. Conversational Agent - Customer Support Copilot (multi-turn conversations)
 * 2. Function Agents:
 *    - Case Summarizer (tool-terminating: 0 tools, pure LLM text generation)
 *    - Lead Qualifier (tool-terminating: 1 tool, LLM as router)
 *    - Opportunity Assistant (iterative: 2+ tools, multi-turn agentic)
 * 3. Workflow Agent - Case Processing Workflow (orchestrates 2 Function agents with max 3 capabilities each):
 *    - Step 1: Case Analysis Agent (3 capabilities: get_account, get_orders, update_case_priority)
 *    - Step 2: Case Resolution & Notification Agent (3 capabilities: search_knowledge, create_task, post_to_chatter)
 *
 * **Prerequisites:**
 * 1. Named Credential 'OpenAI_API' must exist
 * 2. User must have permissions for Knowledge Articles
 * 3. Chatter must be enabled
 *
 * @usage
 * Execute in Anonymous Apex:
 * Map<String, Id> data = AgentTestDataFactory.createComprehensiveShowcase();
 * System.debug('Created records: ' + data);
 *
 * @author Sonal
 * @since 2025
 */
public with sharing class AgentTestDataFactory {
    private static Map<String, Id> idMap = new Map<String, Id>();

    /**
     * @description Main entry point - creates complete showcase with all agent types
     * @return Map<String, Id> Key record IDs for reference
     */
    public static Map<String, Id> createComprehensiveShowcase() {
        System.debug('========================================');
        System.debug('AI AGENT STUDIO - COMPREHENSIVE SHOWCASE');
        System.debug('========================================');

        // 0. Create Service User asynchronously (setup object - handled via @future to avoid mixed DML)
        createServiceUserAsync();

        deleteExistingData();

        seedFoundationalData();

        LLMConfiguration__c llmConfig = createLLMConfiguration();

        createConversationalAgent(llmConfig.Id);
        createFunctionAgents(llmConfig.Id);
        createWorkflowOrchestrator(llmConfig.Id);

        createFinancialOnboardingWorkflow(llmConfig.Id);

        System.debug('========================================');
        System.debug('SHOWCASE COMPLETE! Key Record IDs:');
        System.debug(JSON.serializePretty(idMap));
        System.debug('Note: Service User creation is running asynchronously');
        System.debug('========================================');
        return idMap;
    }

    // ===================================================================================
    // DATA CLEANUP
    // ===================================================================================

    public static void deleteExistingData() {
        System.debug('[Cleanup] Removing existing data...');

        List<Order> ordersToDeactivate = [
            SELECT Id
            FROM Order
            WHERE Account.Name IN ('Acme Corporation', 'Global Logistics Ltd', 'TechStart Innovations') AND Status = 'Activated'
        ];
        for (Order o : ordersToDeactivate) {
            o.Status = 'Draft';
        }
        if (!ordersToDeactivate.isEmpty()) {
            update ordersToDeactivate;
        }

//        delete [SELECT Id FROM BulkExecution__c];
        delete [SELECT Id FROM AgentDecisionStep__c];
        delete [SELECT Id FROM ExecutionStep__c];
        delete [SELECT Id FROM AgentExecution__c];
        delete [SELECT Id FROM AgentWorkflowStep__c];
        delete [SELECT Id FROM AgentCapability__c];
        delete [SELECT Id FROM AgentContextConfig__c];
        delete [SELECT Id FROM AIAgentDefinition__c];
        delete [SELECT Id FROM LLMConfiguration__c];

        delete [SELECT Id FROM Task];
        delete [SELECT Id FROM Case];
        delete [SELECT Id FROM Opportunity];
        delete [SELECT Id FROM Lead];
        delete [SELECT Id FROM OrderItem];
        delete [SELECT Id FROM Order];
        delete [SELECT Id FROM Contact];
        delete [SELECT Id FROM Account WHERE Name IN ('Acme Corporation', 'Global Logistics Ltd', 'TechStart Innovations')];
        delete [SELECT Id FROM CollaborationGroup WHERE Name IN ('Support Team', 'Relationship Management Team')];

        List<String> knowledgeUrlNames = new List<String>{
            'Troubleshooting-Platform-Performance',
            'Reports-Module-Access',
            'Legacy-Integration-Best-Practices',
            'Adding-User-Licenses',
            'Conservative-Income-Portfolio-Guidelines',
            'Aggressive-Growth-Portfolio-Guidelines',
            'Balanced-Moderate-Portfolio-Guidelines',
            'Business-Owner-Wealth-Management',
            'Client-Risk-Assessment-Methodology'
        };

        List<Knowledge__kav> articles = [
            SELECT Id, KnowledgeArticleId, PublishStatus
            FROM Knowledge__kav
            WHERE UrlName IN :knowledgeUrlNames
        ];

        if (!articles.isEmpty()) {
            Set<Id> masterArticleIds = new Set<Id>();
            for (Knowledge__kav article : articles) {
                masterArticleIds.add(article.KnowledgeArticleId);
            }

            List<Knowledge__ka> masterArticles = [
                SELECT Id
                FROM Knowledge__ka
                WHERE Id IN :masterArticleIds
            ];

            if (!masterArticles.isEmpty()) {
                delete masterArticles;
                System.debug('[Cleanup] ✓ Deleted ' + masterArticles.size() + ' Knowledge articles');
            }
        }

        List<User> serviceUsers = [SELECT Id FROM User WHERE Name = 'Service User' AND IsActive = true];
        if (!serviceUsers.isEmpty()) {
            for (User u : serviceUsers) {
                u.IsActive = false;
            }
            update serviceUsers;
        }

        System.debug('[Cleanup] ✓ Existing data removed');
    }

    // ===================================================================================
    // SERVICE USER CREATION
    // ===================================================================================

    /**
     * @description Async wrapper to create Service User (avoids MIXED_DML_OPERATION)
     * Call this method to create the Service User asynchronously
     */
    @future
    public static void createServiceUserAsync() {
        createServiceUser();
    }

    /**
     * @description Creates the Service User required by CreateAgentStudioConnectedApp
     * This user is used for JWT authentication and agent context switching
     */
    private static void createServiceUser() {
        System.debug('[Service User] Creating Service User for connected app...');

        // Check if Service User already exists
        List<User> existingUsers = [
            SELECT Id, Username, IsActive
            FROM User
            WHERE Name = 'Service User'
            LIMIT 1
        ];

        if (!existingUsers.isEmpty() && existingUsers[0].IsActive) {
            System.debug('[Service User] ✓ Service User already exists and is active: ' + existingUsers[0].Username);
            return;
        }

        if (!existingUsers.isEmpty() && !existingUsers[0].IsActive) {
            // Reactivate existing user
            existingUsers[0].IsActive = true;
            update existingUsers[0];
            System.debug('[Service User] ✓ Service User reactivated: ' + existingUsers[0].Username);
            return;
        }

        // Get Standard User profile
        Profile standardUserProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];

        // Create new Service User
        String orgId = UserInfo.getOrganizationId();
        String uniqueUsername = 'aiagentservice@' + orgId + '.sfdcinternal';

        User serviceUser = new User(
            Username = uniqueUsername,
            LastName = 'Service User',
            FirstName = 'AI Agent',
            Email = 'aiagent.service@example.com',
            Alias = 'aiagent',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = standardUserProfile.Id,
            LanguageLocaleKey = 'en_US',
            IsActive = true
        );

        insert serviceUser;

        // Assign "AI Agent Studio Service User" permission set if it exists
        List<PermissionSet> permSets = [
            SELECT Id, Label
            FROM PermissionSet
            WHERE Label = 'AI Agent Studio Service User'
            LIMIT 1
        ];

        if (!permSets.isEmpty()) {
            PermissionSetAssignment psa = new PermissionSetAssignment(
                AssigneeId = serviceUser.Id,
                PermissionSetId = permSets[0].Id
            );
            insert psa;
            System.debug('[Service User] ✓ Service User created and permission set assigned: ' + serviceUser.Username);
        } else {
            System.debug(LoggingLevel.WARN, '[Service User] ⚠ Service User created but permission set "AI Agent Studio Service User" not found. Assign it manually: ' + serviceUser.Username);
        }
    }

    // ===================================================================================
    // FOUNDATIONAL DATA
    // ===================================================================================

    private static void seedFoundationalData() {
        System.debug('[Foundation] Creating core business data...');

        List<Account> accounts = new List<Account>{
            new Account(Name = 'Acme Corporation', Industry = 'Technology', BillingCountry = 'USA', AnnualRevenue = 5000000),
            new Account(Name = 'Global Logistics Ltd', Industry = 'Transportation', BillingCountry = 'UK', AnnualRevenue = 2000000),
            new Account(Name = 'TechStart Innovations', Industry = 'Technology', BillingCountry = 'Canada', AnnualRevenue = 500000)
        };
        insert accounts;
        idMap.put('Acme Account', accounts[0].Id);
        idMap.put('Global Logistics Account', accounts[1].Id);
        idMap.put('TechStart Account', accounts[2].Id);

        List<Contact> contacts = new List<Contact>{
            new Contact(FirstName = 'Sarah', LastName = 'Johnson', AccountId = accounts[0].Id, Email = 'sarah.johnson@acme.com', Title = 'IT Director'),
            new Contact(FirstName = 'Michael', LastName = 'Chen', AccountId = accounts[0].Id, Email = 'michael.chen@acme.com', Title = 'Support Manager'),
            new Contact(
                FirstName = 'Emma',
                LastName = 'Williams',
                AccountId = accounts[1].Id,
                Email = 'emma.williams@globallogistics.com',
                Title = 'Operations Lead'
            ),
            new Contact(FirstName = 'David', LastName = 'Martinez', AccountId = accounts[2].Id, Email = 'david.martinez@techstart.com', Title = 'CTO')
        };
        insert contacts;
        idMap.put('Sarah Contact', contacts[0].Id);
        idMap.put('Michael Contact', contacts[1].Id);

        Pricebook2 stdPb = [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1];
        idMap.put('Standard Pricebook', stdPb.Id);

        List<Product2> products = new List<Product2>{
            new Product2(Name = 'Enterprise Cloud Platform License', ProductCode = 'ECP-001', IsActive = true, Family = 'Software'),
            new Product2(Name = 'Professional Services - Implementation', ProductCode = 'PS-IMPL-01', IsActive = true, Family = 'Services'),
            new Product2(Name = 'Premium Support Package (Annual)', ProductCode = 'SUP-PREM-YR', IsActive = true, Family = 'Support')
        };
        insert products;

        List<PricebookEntry> pbes = new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = products[0].Id, UnitPrice = 50000, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = products[1].Id, UnitPrice = 25000, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPb.Id, Product2Id = products[2].Id, UnitPrice = 10000, IsActive = true)
        };
        insert pbes;

        // Orders with items
        List<Order> orders = new List<Order>{
            new Order(
                AccountId = accounts[0].Id,
                BillToContactId = contacts[0].Id,
                EffectiveDate = Date.today().addDays(-30),
                Status = 'Draft',
                Pricebook2Id = stdPb.Id
            ),
            new Order(
                AccountId = accounts[1].Id,
                BillToContactId = contacts[2].Id,
                EffectiveDate = Date.today().addDays(-60),
                Status = 'Draft',
                Pricebook2Id = stdPb.Id
            )
        };
        insert orders;

        List<OrderItem> orderItems = new List<OrderItem>{
            new OrderItem(OrderId = orders[0].Id, PricebookEntryId = pbes[0].Id, Quantity = 1, UnitPrice = 50000),
            new OrderItem(OrderId = orders[0].Id, PricebookEntryId = pbes[2].Id, Quantity = 1, UnitPrice = 10000),
            new OrderItem(OrderId = orders[1].Id, PricebookEntryId = pbes[1].Id, Quantity = 1, UnitPrice = 25000)
        };
        insert orderItems;

        // Activate orders
        orders[0].Status = 'Activated';
        orders[1].Status = 'Activated';
        update orders;
        idMap.put('Acme Order', orders[0].Id);

        List<Case> cases = new List<Case>{
            new Case(
                AccountId = accounts[0].Id,
                ContactId = contacts[0].Id,
                Subject = 'Platform Performance Issues',
                Description = 'Our enterprise cloud platform has been experiencing significant slowdowns during peak hours. Dashboard load times have increased from 2 seconds to over 30 seconds. This is impacting our entire organization and we need urgent assistance.',
                Status = 'New',
                Priority = 'High',
                Origin = 'Email'
            ),
            new Case(
                AccountId = accounts[0].Id,
                ContactId = contacts[1].Id,
                Subject = 'Unable to Access Reports Module',
                Description = 'Since yesterday, our team cannot access the reports module. When clicking on the Reports tab, we receive an error: "Module not available". This is blocking our end-of-quarter analysis.',
                Status = 'Working',
                Priority = 'Medium',
                Origin = 'Web'
            ),
            new Case(
                AccountId = accounts[1].Id,
                ContactId = contacts[2].Id,
                Subject = 'Integration with Legacy System Failed',
                Description = 'We completed the implementation services last week, but the integration with our legacy inventory system is not working. Orders are not syncing correctly.',
                Status = 'Escalated',
                Priority = 'High',
                Origin = 'Phone'
            ),
            new Case(
                AccountId = accounts[2].Id,
                ContactId = contacts[3].Id,
                Subject = 'Request for Additional User Licenses',
                Description = 'Our team has grown and we need to add 10 more user licenses to our current subscription.',
                Status = 'Closed',
                Priority = 'Low',
                Origin = 'Web'
            )
        };
        insert cases;
        idMap.put('Performance Case', cases[0].Id);
        idMap.put('Reports Case', cases[1].Id);
        idMap.put('Integration Case', cases[2].Id);

        List<Opportunity> opportunities = new List<Opportunity>{
            new Opportunity(
                AccountId = accounts[0].Id,
                Name = 'Acme Corp - Expansion Deal',
                StageName = 'Prospecting',
                CloseDate = Date.today().addDays(60),
                Amount = 75000,
                Probability = 20,
                Description = 'Expand to 50 additional users'
            ),
            new Opportunity(
                AccountId = accounts[2].Id,
                Name = 'TechStart - New Customer',
                StageName = 'Qualification',
                CloseDate = Date.today().addDays(90),
                Amount = 120000,
                Probability = 40,
                Description = 'New enterprise deal with professional services'
            )
        };
        insert opportunities;
        idMap.put('Acme Opportunity', opportunities[0].Id);

        List<Lead> leads = new List<Lead>{
            new Lead(
                FirstName = 'Jennifer',
                LastName = 'Smith',
                Company = 'Beta Industries',
                Title = 'VP of Operations',
                Email = 'jsmith@betaindustries.com',
                Phone = '555-0101',
                Status = 'Open - Not Contacted',
                LeadSource = 'Web',
                Industry = 'Manufacturing',
                Rating = null,
                Description = 'Downloaded whitepaper on cloud migration strategies. Company has 200+ employees.'
            ),
            new Lead(
                FirstName = 'Robert',
                LastName = 'Taylor',
                Company = 'Startup Co',
                Title = 'Founder',
                Email = 'robert@startupco.com',
                Phone = '555-0102',
                Status = 'Open - Not Contacted',
                LeadSource = 'Referral',
                Industry = 'Technology',
                Rating = null,
                Description = 'Small startup, looking for affordable solutions. Limited budget.'
            )
        };
        insert leads;
        idMap.put('Beta Lead', leads[0].Id);
        idMap.put('Startup Lead', leads[1].Id);

        CollaborationGroup supportGroup = new CollaborationGroup(Name = 'Support Team', CollaborationType = 'Public');
        insert supportGroup;
        idMap.put('Support Chatter Group', supportGroup.Id);

        seedKnowledgeArticles();

        System.debug('[Foundation] ✓ Core business data created');
    }

    private static void seedKnowledgeArticles() {
        List<Knowledge__kav> articles = new List<Knowledge__kav>{
            new Knowledge__kav(
                Title = 'Troubleshooting Platform Performance Issues',
                UrlName = 'Troubleshooting-Platform-Performance',
                Summary = 'If experiencing slow performance: 1) Check browser cache and clear if needed. 2) Verify network connection stability. 3) Disable browser extensions temporarily. 4) Check the Status Page for any ongoing incidents. 5) Review concurrent user limits on your license. Common causes include browser cache buildup (clear cache), network latency (test connection speed), or hitting concurrent user limits (upgrade license tier if needed).'
            ),
            new Knowledge__kav(
                Title = 'Reports Module Access Requirements',
                UrlName = 'Reports-Module-Access',
                Summary = 'The Reports module requires: 1) User must have "Reports Viewer" permission enabled. 2) Valid Premium Support Package subscription. 3) Browser must allow third-party cookies. To resolve access issues: Have admin verify user permissions, confirm active support subscription, check browser cookie settings, or try accessing from incognito mode to rule out extension conflicts.'
            ),
            new Knowledge__kav(
                Title = 'Legacy System Integration Best Practices',
                UrlName = 'Legacy-Integration-Best-Practices',
                Summary = 'When integrating with legacy systems: 1) Ensure API credentials are current and have correct permissions. 2) Verify firewall rules allow outbound connections to legacy system. 3) Check data mapping configuration in Integration Settings. 4) Review sync logs in Setup > Integrations > Sync History. Common issues: expired credentials, firewall blocking, incorrect field mappings, or data format mismatches.'
            ),
            new Knowledge__kav(
                Title = 'Adding Additional User Licenses',
                UrlName = 'Adding-User-Licenses',
                Summary = 'To add user licenses: Contact your Account Executive or submit a request through the Customer Portal. License additions typically process within 1-2 business days. Pricing is prorated based on your subscription anniversary date. Bulk discounts available for 20+ licenses.'
            )
        };
        insert articles;

        // Query to get the KnowledgeArticleId (master article ID) for publishing
        List<Knowledge__kav> insertedArticles = [
            SELECT Id, KnowledgeArticleId
            FROM Knowledge__kav
            WHERE Id IN :articles
        ];

        // Publish articles using the master article ID
        for (Knowledge__kav article : insertedArticles) {
            KbManagement.PublishingService.publishArticle(article.KnowledgeArticleId, true);
        }
        System.debug('[Foundation] ✓ Knowledge articles created and published');
    }

    // ===================================================================================
    // LLM CONFIGURATION
    // ===================================================================================

    private static LLMConfiguration__c createLLMConfiguration() {
        System.debug('[LLM] Creating configurations...');

        List<LLMConfiguration__c> configs = new List<LLMConfiguration__c>();

        // GPT-4 (existing default)
        LLMConfiguration__c gpt4Config = new LLMConfiguration__c(
            Name = 'OpenAI GPT-4',
            DeveloperName__c = 'OpenAI_GPT4',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-4o-mini',
            DefaultTemperature__c = 0.1,
            IsActive__c = true
        );
        configs.add(gpt4Config);

        // GPT-5 Mini
        LLMConfiguration__c gpt5MiniConfig = new LLMConfiguration__c(
            Name = 'OpenAI GPT-5 Mini',
            DeveloperName__c = 'OpenAI_GPT5_Mini',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-5-mini',
            DefaultTemperature__c = 0.1,
            IsActive__c = true
        );
        configs.add(gpt5MiniConfig);

        // GPT-5 Nano
        LLMConfiguration__c gpt5NanoConfig = new LLMConfiguration__c(
            Name = 'OpenAI GPT-5 Nano',
            DeveloperName__c = 'OpenAI_GPT5_Nano',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-5-nano',
            DefaultTemperature__c = 0.2,
            IsActive__c = true
        );
        configs.add(gpt5NanoConfig);

        insert configs;

        // Store all configs in idMap for reference
        idMap.put('LLM Config', gpt4Config.Id);
        idMap.put('LLM Config GPT4', gpt4Config.Id);
        idMap.put('LLM Config GPT5 Mini', gpt5MiniConfig.Id);
        idMap.put('LLM Config GPT5 Nano', gpt5NanoConfig.Id);

        System.debug('[LLM] ✓ Created ' + configs.size() + ' LLM configurations');
        return gpt4Config; // Return default for backward compatibility
    }

    // ===================================================================================
    // CONVERSATIONAL AGENT
    // ===================================================================================

    /**
     * @description Creates a full-featured conversational agent for customer support
     * Demonstrates multi-turn conversations with context, tools, and memory
     */
    private static void createConversationalAgent(Id llmConfigId) {
        System.debug('[Agent:Conversational] Creating Customer Support Copilot...');

        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Customer Support Copilot',
            DeveloperName__c = 'Customer_Support_Copilot',
            AgentType__c = 'Conversational',
            IsActive__c = true,
            MemoryStrategy__c = 'Buffer Window',
            ContextFormatStrategy__c = 'Structured Text',
            LLMConfiguration__c = llmConfigId,
            HistoryTurnLimit__c = 10,
            AuditLevel__c = 'Full',
            EnableParallelToolCalling__c = true,
            RequiresServiceUserContext__c = false,
            WelcomeMessageTemplate__c = 'Hello {User.FirstName}! I\'m your Customer Support Copilot. I can help you with cases, orders, and knowledge base searches. How can I assist you today?',
            IdentityPrompt__c = 'You are an expert customer support assistant for a B2B cloud software company. You help support agents resolve customer issues efficiently by searching knowledge, retrieving records, and creating cases.',
            InstructionsPrompt__c = 'Always be professional and helpful. When users ask about issues, search the knowledge base first. When creating cases, gather all necessary details. Always confirm important actions before executing them.',
            PromptFooter__c = '**Important:** Always verify record IDs and data before taking actions. If information is unclear, ask clarifying questions.'
        );
        insert agent;
        idMap.put('Conversational Agent', agent.Id);

        // Context providers
        List<AgentContextConfig__c> contexts = new List<AgentContextConfig__c>{
            createContext(agent.Id, 'User Details', 'UserDetailsProvider', null, false, 10),
            createContext(agent.Id, 'Case Context', 'CaseContext', 'Case', true, 20),
            createContext(agent.Id, 'Account Context', 'AccountContext', 'Account', true, 30),
            createContext(agent.Id, 'Order Context', 'OrderContext', 'Order', true, 40)
        };
        insert contexts;

        // Capabilities
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            createCapability(
                agent.Id,
                'search_knowledge',
                'Searches the Salesforce Knowledge Base for troubleshooting articles and solutions. Returns articles with `title`, `summary`, and `url`. Use this to:\n- Find documented solutions to customer issues\n- Locate troubleshooting guides\n- Search for product documentation',
                '{"type":"object","properties":{"searchQuery":{"type":"string","description":"The search term or keywords"},"maxResults":{"type":"integer","description":"Maximum number of results to return (default 5, max 20)"}},"required":["searchQuery"]}',
                'Apex',
                null,
                'ActionSearchKnowledge',
                null,
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_case_details',
                'Retrieves detailed information about a specific case by case number. Returns `CaseNumber`, `Subject`, `Description`, `Status`, `Priority`, and `CreatedDate`. Use this to:\n- View current case status and priority\n- Get case history and description\n- Check case ownership and timestamps',
                '{"type":"object","properties":{"CaseNumber":{"type":"string","description":"The case number (e.g., 00001234)"}},"required":["CaseNumber"]}',
                'Standard',
                'GetRecordDetails',
                null,
                '{"objectApiName":"Case","defaultFields":["Id","CaseNumber","Subject","Description","Status","Priority","CreatedDate"]}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'create_case',
                'Creates a new support case in Salesforce. Automatically sets `Status` to `"New"` and `Origin` to `"Web"`. Use this to:\n- Log new customer issues\n- Escalate problems to support team\n- Create tickets for tracking\n\nRequires user confirmation before execution.',
                '{"type":"object","properties":{"recordData":{"type":"object","description":"SObject field values. Must include Subject, Description, and Priority.","properties":{"Subject":{"type":"string","description":"Case subject"},"Description":{"type":"string","description":"Case description"},"Priority":{"type":"string","description":"","enum":["High","Medium","Low"]}},"required":["Subject","Description","Priority"]}},"required":["recordData"]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Case","defaultFieldValues":{"Status":"New","Origin":"Web"}}',
                true,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'update_case',
                'Updates an existing case with new information. Valid `Priority` values: `"High"`, `"Medium"`, `"Low"`. Use this to:\n- Change case status or priority\n- Update case description or comments\n- Modify case fields based on analysis\n\nRequires user confirmation before execution.',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Case ID to update."},"recordData":{"type":"object","properties":{"Status":{"type":"string","description":"Case Status"},"Priority":{"type":"string","enum":["High","Medium","Low"]}},"additionalProperties":true}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{"objectApiName":"Case"}',
                true,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_order_status',
                'Retrieves order information by order ID. Returns `OrderNumber`, `Status`, `TotalAmount`, and `EffectiveDate`. Use this to:\n- Check order fulfillment status\n- View order totals and dates\n- Help customers with order-related inquiries',
                '{"type":"object","properties":{"Id":{"type":"string","description":"The Salesforce Order ID (18-character ID starting with 801)"}},"required":["Id"]}',
                'Standard',
                'GetRecordDetails',
                null,
                '{"objectApiName":"Order","defaultFields":["Id","OrderNumber","Status","TotalAmount","EffectiveDate"]}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'notify_support_team',
                'Posts a message to the Support Team Chatter group. Use this to:\n- Alert team about critical issues\n- Share case updates and resolutions\n- Request team assistance\n\nRuns asynchronously.',
                '{"type":"object","properties":{"messageText":{"type":"string","description":"Message to post"},"topics":{"type":"array","description":"Optional topics","items":{"type":"string"}}},"required":["messageText"]}',
                'Standard',
                'PostChatter',
                null,
                '{"feedType":"Group","targetId":"' + idMap.get('Support Chatter Group') + '"}',
                false,  // No confirmation for async tools
                false,
                true,   // Runs asynchronously
                'External'
            )
        };
        insert capabilities;

        System.debug('[Agent:Conversational] ✓ Customer Support Copilot created with ' + capabilities.size() + ' capabilities');
    }

    // ===================================================================================
    // FUNCTION AGENTS
    // ===================================================================================

    /**
     * @description Creates multiple function agents demonstrating different execution patterns
     */
    private static void createFunctionAgents(Id llmConfigId) {
        System.debug('[Agent:Function] Creating function agents...');

        // 1. TOOL-TERMINATING PATTERN: 0 tools (pure LLM text generation)
        createCaseSummarizerAgent(llmConfigId);

        // 2. TOOL-TERMINATING PATTERN: 1 tool (LLM as router)
        createLeadQualifierAgent(llmConfigId);

        // 3. ITERATIVE AGENTIC PATTERN: 2+ tools (multi-turn execution)
        createOpportunityAssistantAgent(llmConfigId);

        // 4. COMPOSITE OPERATION PATTERN: 1 tool with complex nested JSON
        createOpportunityCreatorAgent(llmConfigId);

        System.debug('[Agent:Function] ✓ All function agents created');
    }

    /**
     * @description Case Summarizer - Tool-Terminating (0 tools)
     * Pure LLM text generation for summarizing case descriptions
     */
    private static void createCaseSummarizerAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Case Summarizer',
            DeveloperName__c = 'Case_Summarizer',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Standard',
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You are an expert at summarizing technical support cases into concise, actionable summaries.',
            InstructionsPrompt__c = 'Analyze the case description and create a 2-3 sentence summary that captures: 1) The core issue, 2) Business impact, 3) Urgency level. Be clear and concise.',
            PromptFooter__c = 'Format: Start with issue type, then impact, then recommended action.'
        );
        insert agent;
        idMap.put('Case Summarizer Agent', agent.Id);

        // Context provider to retrieve Case details
        AgentContextConfig__c caseContext = createContext(agent.Id, 'Case Context', 'CaseContext', 'Case', true, 10);
        insert caseContext;

        // NO capabilities - pure LLM text generation
        // This demonstrates the tool-terminating pattern with 0 tools

        System.debug('[Agent:Function] ✓ Case Summarizer (0 tools - pure LLM with case context)');
    }

    /**
     * @description Lead Qualifier - Tool-Terminating (1 tool)
     * LLM analyzes lead data and decides to update the rating
     */
    private static void createLeadQualifierAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Lead Qualifier',
            DeveloperName__c = 'Lead_Qualifier',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Standard',
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You are a lead qualification specialist. You analyze lead information and assign appropriate ratings (Hot, Warm, Cold) based on company size, title seniority, and engagement signals.',
            InstructionsPrompt__c = 'Analyze the lead data provided in context. Do not provide a text analysis or explanation. If you have enough information to determine a rating, call the update_lead_rating tool immediately. Your ONLY output should be the tool call.',
            PromptFooter__c = 'Hot = Enterprise, senior title, strong engagement. Warm = Mid-market, manager title, some engagement. Cold = Small company, junior title, passive.'
        );
        insert agent;
        idMap.put('Lead Qualifier Agent', agent.Id);

        // Context provider for lead data
        AgentContextConfig__c leadContext = createContext(agent.Id, 'Lead Data', 'LeadContext', 'Lead', true, 10);
        insert leadContext;

        // Single capability - LLM decides whether and how to call it
        AgentCapability__c updateLeadCap = createCapability(
            agent.Id,
            'update_lead_rating',
            'Updates the lead rating field based on qualification analysis. Valid `Rating` values:\n- `"Hot"` - Enterprise company, senior title, strong engagement\n- `"Warm"` - Mid-market company, manager title, some engagement\n- `"Cold"` - Small company, junior title, passive engagement\n\nUse this after analyzing lead data to prioritize for the sales team.',
            '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Lead ID to update."},"recordData":{"type":"object","properties":{"Rating":{"type":"string","enum":["Hot","Warm","Cold"],"description":"Lead qualification rating"}},"additionalProperties":true}},"required":["recordId","recordData"]}',
            'Standard',
            'UpdateRecord',
            null,
            '{"objectApiName":"Lead"}',
            false, // no confirmation needed
            false, // no approval needed
            false, // synchronous
            'External'
        );
        insert updateLeadCap;

        System.debug('[Agent:Function] ✓ Lead Qualifier (1 tool - LLM as router)');
    }

    /**
     * @description Opportunity Assistant - Iterative Agentic (2+ tools)
     * Multi-turn execution with multiple tools for opportunity management
     */
    private static void createOpportunityAssistantAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Opportunity Assistant',
            DeveloperName__c = 'Opportunity_Assistant',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            ContextFormatStrategy__c = 'Structured Text',
            EnableParallelToolCalling__c = false, // Sequential execution
            IdentityPrompt__c = 'You are an intelligent opportunity management assistant. You help sales teams by retrieving opportunity data, updating stages, calculating pricing, and creating follow-up tasks.',
            InstructionsPrompt__c = 'When asked to help with opportunities: 1) First use find_opportunities to locate the relevant opportunity, 2) Then take appropriate actions based on user request (update stage, create task, etc.), 3) Always confirm the opportunity details before making changes.',
            PromptFooter__c = 'Be thorough and confirm all changes. Ask for clarification if the opportunity is ambiguous.'
        );
        insert agent;
        idMap.put('Opportunity Assistant Agent', agent.Id);

        // Context provider
        AgentContextConfig__c oppContext = createContext(agent.Id, 'Opportunity Context', 'OpportunityContext', 'Opportunity', true, 10);
        insert oppContext;

        // Multiple capabilities for iterative agentic pattern
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            createCapability(
                agent.Id,
                'find_opportunities',
                'Searches for opportunities associated with a specific account. Returns up to 10 opportunities with `Name`, `StageName`, `Amount`, `CloseDate`, and `Probability`. Use this to:\n- List opportunities for an account\n- Analyze sales pipeline\n- Review opportunity status and stages',
                '{"type":"object","properties":{"accountId":{"type":"string","description":"The Salesforce Account ID to search opportunities for"}},"required":["accountId"]}',
                'Apex',
                null,
                'ActionOpportunity',
                '{"operation":"SEARCH_BY_ACCOUNT","defaultFields":["Id","Name","StageName","Amount","CloseDate","Probability","AccountId"],"maxResults":10}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'update_opportunity_stage',
                'Updates the opportunity stage and win probability. Common `StageName` values: `"Prospecting"`, `"Qualification"`, `"Proposal"`, `"Negotiation"`, `"Closed Won"`. Use this to:\n- Move opportunities through sales pipeline\n- Update win probability percentage\n- Progress deals based on customer engagement',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Opportunity ID to update."},"recordData":{"type":"object","properties":{"StageName":{"type":"string","description":"Opportunity stage"},"Probability":{"type":"number","description":"Win probability (0-100)"}},"additionalProperties":true}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{"objectApiName":"Opportunity"}',
                false,  // No confirmation for Function agents - use Approval if needed
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'create_followup_task',
                'Creates a new task to track follow-up actions. Automatically sets `Status` to `"Not Started"` and `Priority` to `"Normal"`. Use this to:\n- Schedule follow-up calls or meetings\n- Track action items from customer conversations\n- Assign next steps to team members',
                '{"type":"object","properties":{"recordData":{"type":"object","description":"SObject field values to set on the new record. Property names should be valid field API names.","additionalProperties":true}},"required":[]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Task","defaultFieldValues":{"Status":"Not Started","Priority":"Normal"}}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_account_info',
                'Retrieves account information by account ID. Returns `Name`, `Industry`, `AnnualRevenue`, `BillingCity`, and `BillingState`. Use this to:\n- Understand customer background\n- Check account details and location\n- Assess account value and importance',
                '{"type":"object","properties":{"Id":{"type":"string","description":"The Salesforce Account ID (18-character ID starting with 001)"}},"required":["Id"]}',
                'Standard',
                'GetRecordDetails',
                null,
                '{"objectApiName":"Account","defaultFields":["Id","Name","Industry","AnnualRevenue","BillingCity","BillingState"]}',
                false,
                false,
                false,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Agent:Function] ✓ Opportunity Assistant (4 tools - iterative agentic)');
    }

    /**
     * @description Opportunity Creator - Composite Operation (1 tool with complex nested JSON)
     * Creates complete opportunity package (opportunity + products + task) in one tool call
     */
    private static void createOpportunityCreatorAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Opportunity Creator',
            DeveloperName__c = 'Opportunity_Creator',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Standard',
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You are a sales automation assistant who creates complete opportunity packages including products and follow-up tasks. You work from account information and product requirements to build comprehensive opportunities.',
            InstructionsPrompt__c = 'Based on the provided information, create a complete opportunity package:\n\n1. **Opportunity**: Set name, account, amount (sum of products), stage (Prospecting for new, Proposal/Negotiation for existing customers)\n2. **Products**: List all products with quantities and unit prices from the conversation\n3. **Follow-up Task**: Create a task for the next action (demo, call, proposal review)\n\nUse the create_opportunity_package tool with properly structured nested JSON.',
            PromptFooter__c = 'Always confirm the total amount equals the sum of all products. Stage should reflect customer engagement level.'
        );
        insert agent;
        idMap.put('Opportunity Creator Agent', agent.Id);

        // Context provider for account data
        AgentContextConfig__c accountContext = createContext(agent.Id, 'Account Context', 'AccountContext', 'Account', true, 10);
        insert accountContext;

        // Single capability with complex nested JSON structure
        AgentCapability__c createOpportunityCap = createCapability(
            agent.Id,
            'create_opportunity_package',
            'Creates a complete opportunity with products and follow-up task in one operation. This is a composite action that:\n\n1. Creates the Opportunity record\n2. Adds OpportunityLineItems (products) from the pricebook\n3. Creates a follow-up Task linked to the opportunity\n\nAll operations succeed or fail together (transactional). Products are looked up by Product Code or Product2 ID from the standard pricebook.}',
            '{"type":"object","properties":{"opportunity":{"type":"object","required":["name","accountId"],"properties":{"name":{"type":"string","description":"Opportunity name"},"accountId":{"type":"string","format":"salesforce-id","description":"Account ID"},"amount":{"type":"number","description":"Total opportunity amount"},"stageName":{"type":"string","description":"Sales stage"},"closeDate":{"type":"string","format":"date","description":"Expected close date"},"description":{"type":"string"},"type":{"type":"string","enum":["New Business","Existing Business"]},"leadSource":{"type":"string"}}},"products":{"type":"array","items":{"type":"object","properties":{"productCode":{"type":"string","description":"Product code for lookup"},"product2Id":{"type":"string","format":"salesforce-id","description":"Direct Product2 ID"},"quantity":{"type":"number","default":1},"unitPrice":{"type":"number","description":"Unit price"},"description":{"type":"string"}}}},"followUpTask":{"type":"object","properties":{"subject":{"type":"string","description":"Task subject"},"description":{"type":"string"},"priority":{"type":"string","enum":["High","Normal","Low"]},"status":{"type":"string","default":"Not Started"},"activityDate":{"type":"string","format":"date"}}}},"required":["opportunity"]}',
            'Apex',
            null,
            'ActionOpportunityWithProducts',
            '{"allOrNone":true,"defaultStage":"Prospecting","taskPriority":"Normal","taskStatus":"Not Started","taskDueDays":7,"autoSetCloseDate":true,"closeDateDays":30}',
            false,
            false,
            false,
            'External'
        );
        insert createOpportunityCap;

        System.debug('[Agent:Function] ✓ Opportunity Creator (1 tool - composite operation with nested JSON)');
    }

    // ===================================================================================
    // WORKFLOW AGENT
    // ===================================================================================

    /**
     * @description Creates a workflow agent that orchestrates 2 function agents with multiple capabilities
     * Demonstrates: Analyze & Triage → Resolve & Notify workflow for case processing
     */
    private static void createWorkflowOrchestrator(Id llmConfigId) {
        System.debug('[Agent:Workflow] Creating Case Processing Workflow...');

        // Create the workflow orchestrator
        AIAgentDefinition__c workflow = new AIAgentDefinition__c(
            Name = 'Case Processing Workflow',
            DeveloperName__c = 'Case_Processing_Workflow',
            AgentType__c = 'Workflow',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            Description__c = 'Automated case processing: analyze & triage → resolve & notify',
            AuditLevel__c = 'Full'
        );
        insert workflow;
        idMap.put('Workflow Agent', workflow.Id);

        // Create 2 child function agents with multiple capabilities each
        Id analysisAgent = createCaseAnalysisAgent(llmConfigId);
        Id resolutionAgent = createCaseResolutionAndNotificationAgent(llmConfigId);

        // Define workflow steps (only 2 steps now)
        List<AgentWorkflowStep__c> steps = new List<AgentWorkflowStep__c>{
            new AgentWorkflowStep__c(
                WorkflowAgent__c = workflow.Id,
                ChildAgent__c = analysisAgent,
                ExecutionOrder__c = 1,
                IsActive__c = true,
                Description__c = 'Step 1: Case Analysis - Enrich with account data, analyze orders, set priority, and search knowledge'
            ),
            new AgentWorkflowStep__c(
                WorkflowAgent__c = workflow.Id,
                ChildAgent__c = resolutionAgent,
                ExecutionOrder__c = 2,
                IsActive__c = true,
                Description__c = 'Step 2: Resolution & Notification - Create follow-up tasks, update case status, and notify support team'
            )
        };
        insert steps;

        System.debug('[Agent:Workflow] ✓ Case Processing Workflow created with ' + steps.size() + ' steps (2 function agents with multiple capabilities)');
    }

    /**
     * @description Step 1: Case Analysis Agent (Multi-capability function agent)
     * Capabilities: get_account, get_orders, update_case_priority (MAX 3)
     */
    private static Id createCaseAnalysisAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Case Analysis Agent',
            DeveloperName__c = 'Case_Analysis_Agent',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            EnableParallelToolCalling__c = true,
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You are an expert case analyst who enriches cases with customer data and sets appropriate priorities.',
            InstructionsPrompt__c = 'For the given case: 1) Retrieve account information to understand customer context. 2) Get recent orders to see purchase history. 3) Analyze severity and set appropriate priority (High if urgent/critical/blocking, Medium if issue/problem, Low otherwise). Provide a comprehensive customer context summary.'
        );
        insert agent;

        AgentContextConfig__c caseContext = createContext(agent.Id, 'Case Context', 'CaseContext', 'Case', true, 10);
        insert caseContext;

        // Limited to 3 capabilities to avoid queueable depth issues
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            createCapability(
                agent.Id,
                'get_account',
                'Retrieves comprehensive account information by account ID. Returns `Name`, `Industry`, `Type`, `AccountNumber`, `Phone`, `BillingCity`, and `AnnualRevenue`. Use this to:\n- Enrich case context with customer data\n- Assess account value and importance\n- Understand customer profile\n\n**Example:** For a case with AccountId "001XX000004ABCD", retrieve account details to determine if this is a high-value customer requiring priority handling.',
                '{"type":"object","properties":{"Id":{"type":"string","format":"salesforce-id","description":"The 18-character Salesforce Account ID (starts with 001). Extract this from the case\'s AccountId field.","examples":["001XX000004ABCDEF"]}},"required":["Id"]}',
                'Standard',
                'GetRecordDetails',
                null,
                '{"objectApiName":"Account","defaultFields":["Id","Name","Industry","Type","AccountNumber","Phone","BillingCity","AnnualRevenue"]}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_orders',
                'Retrieves orders for a specific account. Returns up to 10 orders with `OrderNumber`, `Status`, `TotalAmount`, `EffectiveDate`, and `Type`. Use this to:\n- Review customer purchase history\n- Identify recent transactions\n- Understand order volume and patterns\n\n**Example:** After retrieving account information, get recent orders to assess if the case is related to a recent purchase or ongoing customer relationship.',
                '{"type":"object","properties":{"accountId":{"type":"string","format":"salesforce-id","description":"The 18-character Salesforce Account ID (starts with 001). Use the same AccountId from the case or from the get_account call.","examples":["001XX000004ABCDEF"]}},"required":["accountId"]}',
                'Apex',
                null,
                'ActionOrder',
                '{"operation":"SEARCH_BY_ACCOUNT","defaultFields":["Id","OrderNumber","Status","TotalAmount","EffectiveDate","Type"],"maxResults":10}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'update_case_priority',
                'Updates the case priority field. Valid `Priority` values:\n- `"High"` - Urgent/critical/blocking issues, system outages, high-value customer escalations\n- `"Medium"` - Standard problems or issues requiring timely resolution\n- `"Low"` - Minor questions or requests, informational inquiries\n\nUse this after analyzing case urgency, customer value (from account revenue), and business impact. Consider:\n- Account annual revenue (High priority for accounts > $1M)\n- Case subject/description urgency keywords\n- Recent order activity and customer relationship value',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Case ID to update. Extract from the case context provided.","examples":["500XX000004ABCDEF"]},"recordData":{"type":"object","properties":{"Priority":{"type":"string","enum":["High","Medium","Low"],"description":"Case priority level based on urgency and customer value analysis","examples":["High"]}},"additionalProperties":true}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{"objectApiName":"Case","defaultFieldValues":{"Origin":"Web"}}',
                false,
                false,
                false,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Agent:Function] ✓ Case Analysis Agent created with ' + capabilities.size() + ' capabilities (max 3)');
        return agent.Id;
    }

    /**
     * @description Step 2: Case Resolution & Notification Agent (Multi-capability function agent)
     * Capabilities: search_knowledge, create_task, post_to_chatter (MAX 3)
     */
    private static Id createCaseResolutionAndNotificationAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Case Resolution & Notification Agent',
            DeveloperName__c = 'Case_Resolution_Notification_Agent',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You finalize case processing by finding solutions, creating follow-up tasks, and notifying the support team.',
            InstructionsPrompt__c = 'Based on the case analysis: 1) Search knowledge base for relevant solutions and troubleshooting steps. 2) Create a follow-up task for the support team with key actions. 3) Post a concise summary to the support team Chatter with case number, priority, and recommended solution. Keep notification under 100 words.'
        );
        insert agent;

        AgentContextConfig__c caseContext = createContext(agent.Id, 'Case Context', 'CaseContext', 'Case', true, 10);
        insert caseContext;

        // Limited to 3 capabilities to avoid queueable depth issues
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            createCapability(
                agent.Id,
                'search_knowledge',
                'Searches the knowledge base for relevant solution articles. Returns matching articles with `title`, `summary`, and `url`. Use this to:\n- Find documented solutions\n- Locate troubleshooting procedures\n- Access product documentation for case resolution\n\n**Example:** For a case about "Login error after password reset", search for keywords like "login error", "password reset", or "authentication issue" to find relevant KB articles.',
                '{"type":"object","properties":{"searchQuery":{"type":"string","description":"Search keywords extracted from case subject and description. Use 2-4 key terms that describe the issue.","examples":["login error password reset","system outage troubleshooting","payment processing failed"]},"maxResults":{"type":"integer","description":"Maximum number of articles to return (default: 5, recommended: 3-5)","default":5,"minimum":1,"maximum":10}},"required":["searchQuery"]}',
                'Apex',
                null,
                'ActionSearchKnowledge',
                null,
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'create_follow_up_task',
                'Creates a task for case-related follow-up actions. Automatically sets `Status` to `"Not Started"` and `Priority` to `"Normal"`. Use this to:\n- Schedule customer callbacks\n- Assign action items to support team\n- Track resolution steps\n\n**Important:** The task must be linked to the related Case using `WhatId` field, and must include a `Subject` describing the follow-up action and an `ActivityDate` (due date).',
                '{"type":"object","properties":{"recordData":{"type":"object","description":"SObject field values to set on the new Task record. Must include `Subject` (required), `WhatId` (to link to the Case), and `ActivityDate` (due date). May also include `Description`, `OwnerId`, etc.","properties":{"Subject":{"type":"string","description":"Task subject describing the follow-up action (required). Be specific about what needs to be done.","examples":["Follow up with customer on case resolution","Verify system fix is working","Schedule callback for case #00001067"]},"WhatId":{"type":"string","format":"salesforce-id","description":"The Case ID to link this task to (required). Extract from the case context.","examples":["500XX000004ABCDEF"]},"ActivityDate":{"type":"string","format":"date","description":"Due date for the task in YYYY-MM-DD format (required). Set based on case urgency: High priority = today or tomorrow, Medium = 2-3 days, Low = 5-7 days.","examples":["2025-01-15","2025-01-20"]},"Description":{"type":"string","description":"Detailed description of the follow-up task, including context from the case and any relevant notes.","examples":["Customer reported login issues after password reset. Verify that the password reset process is working correctly and follow up with customer to confirm resolution."]},"OwnerId":{"type":"string","format":"salesforce-id","description":"User ID to assign the task to (defaults to current user if not specified). Use if a specific support team member should handle this."}},"required":["Subject","WhatId","ActivityDate"],"additionalProperties":true}},"required":["recordData"]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Task","defaultFieldValues":{"Status":"Not Started","Priority":"Normal"}}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'post_to_chatter',
                'Posts a message to the Support Team Chatter group. Use this to:\n- Notify team of case resolutions\n- Share important case updates\n- Communicate status changes\n\nRuns asynchronously.\n\n**Example:** Post a concise summary including case number, priority, customer name, issue summary, and recommended next steps. Keep under 100 words.',
                '{"type":"object","properties":{"messageText":{"type":"string","description":"The content of the message to post to Chatter. Include: case number, priority, customer/account name, brief issue summary, and recommended action. Keep concise (under 100 words).","examples":["Case #00001067 (High Priority) - Acme Corp: Login error after password reset. KB search found 2 relevant articles. Follow-up task created for customer callback. Recommended: Verify password reset process and test authentication flow."]},"topics":{"type":"array","description":"Optional list of topics/hashtags to associate with the post (e.g., case type, product, urgency level).","items":{"type":"string"},"examples":[["High Priority","Authentication","Customer Escalation"]]}},"required":["messageText"]}',
                'Standard',
                'PostChatter',
                null,
                '{"feedType":"Group","targetId":"' + idMap.get('Support Chatter Group') + '"}',
                false,
                false,
                true,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Agent:Function] ✓ Case Resolution & Notification Agent created with ' + capabilities.size() + ' capabilities (max 3)');
        return agent.Id;
    }

    // ===================================================================================
    // FINANCIAL CLIENT ONBOARDING WORKFLOW
    // ===================================================================================

    /**
     * @description Creates a complete Financial Client Onboarding workflow demonstrating
     * intelligent KYC assessment and account setup that cannot be achieved with standard
     * Salesforce automation.
     *
     * **Business Problem:**
     * Financial services companies must onboard clients with KYC compliance, risk assessment,
     * and suitability matching. Standard automation cannot:
     * - Interpret unstructured client goals and assess risk signals
     * - Make nuanced suitability decisions across multiple weighted factors
     * - Generate personalized onboarding communications
     * - Dynamically adjust approach based on client profile complexity
     *
     * **Workflow Structure:**
     * Step 1: KYC & Risk Assessment Agent - Analyzes client data, calculates risk tier, creates compliance tasks
     * Step 2: Account Setup & Assignment Agent - Finds suitable products, creates onboarding tasks, notifies RM team
     */
    private static void createFinancialOnboardingWorkflow(Id llmConfigId) {
        System.debug('[Financial Onboarding] Creating workflow and test data...');

        // Create test data for financial onboarding scenario
        seedFinancialOnboardingData();

        // Create the workflow orchestrator
        AIAgentDefinition__c workflow = new AIAgentDefinition__c(
            Name = 'Client Onboarding Orchestrator',
            DeveloperName__c = 'Client_Onboarding_Orchestrator',
            AgentType__c = 'Workflow',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            Description__c = 'Intelligent financial client onboarding: KYC assessment → Account setup & RM assignment',
            AuditLevel__c = 'Full'
        );
        insert workflow;
        idMap.put('Financial Onboarding Workflow', workflow.Id);

        // Create child function agents
        Id kycAgent = createKYCRiskAssessmentAgent(llmConfigId);
        Id setupAgent = createAccountSetupAssignmentAgent(llmConfigId);

        // Define workflow steps
        List<AgentWorkflowStep__c> steps = new List<AgentWorkflowStep__c>{
            new AgentWorkflowStep__c(
                WorkflowAgent__c = workflow.Id,
                ChildAgent__c = kycAgent,
                ExecutionOrder__c = 1,
                IsActive__c = true,
                Description__c = 'Step 1: KYC & Risk Assessment - Analyze client application, assess risk profile, update compliance status'
            ),
            new AgentWorkflowStep__c(
                WorkflowAgent__c = workflow.Id,
                ChildAgent__c = setupAgent,
                ExecutionOrder__c = 2,
                IsActive__c = true,
                Description__c = 'Step 2: Account Setup & Assignment - Find suitable products, create onboarding tasks, notify relationship team'
            )
        };
        insert steps;

        System.debug('[Financial Onboarding] ✓ Workflow created with ' + steps.size() + ' steps');
    }

    /**
     * @description Seeds test data specific to financial client onboarding scenario
     */
    private static void seedFinancialOnboardingData() {
        System.debug('[Financial Onboarding] Creating test data...');

        // Chatter Group for Relationship Management team
        CollaborationGroup rmGroup = new CollaborationGroup(
            Name = 'Relationship Management Team',
            CollaborationType = 'Public',
            Description = 'Team responsible for high-value client relationships and onboarding'
        );
        insert rmGroup;
        idMap.put('RM Chatter Group', rmGroup.Id);

        // Create diverse client application leads representing different risk profiles
        List<Lead> clientApplications = new List<Lead>{
            // High-net-worth conservative investor - should be Hot, low risk
            new Lead(
                FirstName = 'Margaret',
                LastName = 'Wellington',
                Company = 'Wellington Family Trust',
                Title = 'Trustee',
                Email = 'margaret.wellington@wellingtontrust.com',
                Phone = '555-0201',
                Status = 'Open - Not Contacted',
                LeadSource = 'Referral',
                Industry = 'Banking',
                AnnualRevenue = 15000000,
                NumberOfEmployees = 5,
                Description = 'Referred by existing client. Managing family trust assets of approximately $15M. Primary goal is capital preservation and steady income generation for beneficiaries. Very conservative risk tolerance - cannot afford significant drawdowns. Interested in fixed income, municipal bonds, and dividend-paying blue chips. Has 30+ years investment experience. Requires quarterly reporting and annual in-person reviews.'
            ),
            // Young aggressive growth investor - should be Warm, higher risk tolerance
            new Lead(
                FirstName = 'Marcus',
                LastName = 'Chen',
                Company = 'TechVenture Capital LLC',
                Title = 'Managing Partner',
                Email = 'marcus.chen@techventure.com',
                Phone = '555-0202',
                Status = 'Open - Not Contacted',
                LeadSource = 'Web',
                Industry = 'Technology',
                AnnualRevenue = 2500000,
                NumberOfEmployees = 8,
                Description = 'Tech entrepreneur who recently had successful exit. Looking to invest $2M in aggressive growth portfolio. Very high risk tolerance - comfortable with 30-40% drawdowns for potential high returns. Interested in emerging markets, tech sector, crypto exposure, and venture-style investments. 10 years investment experience but mostly in private markets. Wants digital-first experience with mobile app access. Time horizon 15+ years.'
            ),
            // Retiree seeking income - should be Hot, moderate-low risk
            new Lead(
                FirstName = 'Robert',
                LastName = 'Anderson',
                Company = 'Self - Retired',
                Title = 'Retired Executive',
                Email = 'robert.anderson@email.com',
                Phone = '555-0203',
                Status = 'Open - Not Contacted',
                LeadSource = 'Seminar',
                Industry = 'Other',
                AnnualRevenue = 500000,
                NumberOfEmployees = 1,
                Description = 'Recently retired Fortune 500 CFO with $3M in rollover IRA and $500K in taxable accounts. Primary need is reliable income to supplement Social Security and pension. Moderate risk tolerance but emphasizes income stability over growth. Concerned about sequence of returns risk in early retirement. Interested in bond ladders, dividend strategies, and possibly annuities for guaranteed income floor. Needs tax-efficient withdrawal strategy. Prefers in-person meetings and phone calls over digital communication.'
            ),
            // Small business owner - should be Warm, moderate risk, complex needs
            new Lead(
                FirstName = 'Sofia',
                LastName = 'Rodriguez',
                Company = 'Rodriguez Medical Group',
                Title = 'Owner/Physician',
                Email = 'sofia.rodriguez@rodriguezmedical.com',
                Phone = '555-0204',
                Status = 'Open - Not Contacted',
                LeadSource = 'Partner Referral',
                Industry = 'Healthcare',
                AnnualRevenue = 4000000,
                NumberOfEmployees = 25,
                Description = 'Physician and practice owner seeking comprehensive wealth management. Needs include: personal investment portfolio ($1.5M), practice 401k plan setup for 25 employees, buy-sell agreement funding, and disability/life insurance review. Moderate risk tolerance for personal assets, more conservative for retirement plan. Complex tax situation with practice income, real estate holdings, and deferred compensation. Looking for advisor who understands medical practice finances. Bilingual Spanish/English preferred.'
            )
        };
        insert clientApplications;
        idMap.put('HNW Conservative Lead', clientApplications[0].Id);
        idMap.put('Aggressive Growth Lead', clientApplications[1].Id);
        idMap.put('Retiree Income Lead', clientApplications[2].Id);
        idMap.put('Business Owner Lead', clientApplications[3].Id);

        // Create Knowledge Articles for product suitability guidelines
        seedFinancialKnowledgeArticles();

        System.debug('[Financial Onboarding] ✓ Test data created: 4 client applications, knowledge articles');
    }

    /**
     * @description Creates Knowledge articles for financial product suitability
     */
    private static void seedFinancialKnowledgeArticles() {
        List<Knowledge__kav> articles = new List<Knowledge__kav>{
            new Knowledge__kav(
                Title = 'Conservative Income Portfolio Suitability Guidelines',
                UrlName = 'Conservative-Income-Portfolio-Guidelines',
                Summary = 'Suitable for clients with: Low risk tolerance, income-focused objectives, capital preservation priority, shorter time horizons (under 10 years), or retirees. Recommended allocation: 70-80% fixed income (investment grade bonds, treasuries, municipal bonds), 15-25% dividend equities (blue chips, utilities, REITs), 5% cash equivalents. Key considerations: Sequence of returns risk for retirees, tax efficiency (municipal bonds for high tax brackets), inflation protection through TIPS. Minimum investment: $250,000. Annual fee: 0.75%.'
            ),
            new Knowledge__kav(
                Title = 'Aggressive Growth Portfolio Suitability Guidelines',
                UrlName = 'Aggressive-Growth-Portfolio-Guidelines',
                Summary = 'Suitable for clients with: High risk tolerance (comfortable with 30%+ drawdowns), growth-focused objectives, long time horizon (15+ years), stable income from other sources, and investment experience. Recommended allocation: 80-90% equities (growth stocks, emerging markets, sector funds), 5-15% alternatives (private equity, venture, crypto), 0-5% fixed income. Key considerations: Volatility tolerance verification required, quarterly rebalancing, tax-loss harvesting opportunities. Minimum investment: $500,000. Annual fee: 1.0%.'
            ),
            new Knowledge__kav(
                Title = 'Balanced Moderate Portfolio Suitability Guidelines',
                UrlName = 'Balanced-Moderate-Portfolio-Guidelines',
                Summary = 'Suitable for clients with: Moderate risk tolerance, balanced growth and income objectives, medium time horizon (7-15 years), some investment experience. Recommended allocation: 50-60% equities (diversified domestic and international), 35-45% fixed income (investment grade corporate and government), 5% alternatives. Key considerations: Regular rebalancing to maintain target allocation, tax-efficient fund placement, gradual de-risking as time horizon shortens. Minimum investment: $100,000. Annual fee: 0.85%.'
            ),
            new Knowledge__kav(
                Title = 'Business Owner Comprehensive Wealth Management',
                UrlName = 'Business-Owner-Wealth-Management',
                Summary = 'For business owners requiring integrated personal and business financial planning. Services include: Personal investment management, retirement plan design and administration (401k, SEP, defined benefit), business succession and buy-sell funding, key person and business insurance, tax coordination with business CPA, entity structure optimization. Key considerations: Separation of personal and business assets, liability protection, exit planning timeline, employee benefit competitiveness. Minimum relationship: $1M combined personal and business assets. Comprehensive fee: 1.0-1.25% based on complexity.'
            ),
            new Knowledge__kav(
                Title = 'Client Risk Assessment Methodology',
                UrlName = 'Client-Risk-Assessment-Methodology',
                Summary = 'Risk assessment factors and scoring: 1) Time Horizon - Under 5 years (low), 5-15 years (moderate), 15+ years (high capacity). 2) Income Stability - Fixed pension/SS (low need), variable business income (higher need for liquidity). 3) Investment Experience - Novice (lower tolerance), experienced (can handle volatility). 4) Stated Goals - Capital preservation (conservative), balanced (moderate), aggressive growth (high). 5) Loss Tolerance - Cannot afford losses (conservative), can tolerate 20% (moderate), comfortable with 30%+ (aggressive). Red flags requiring additional review: Inconsistent answers (high risk tolerance but preservation goals), unrealistic return expectations, concentrated positions, recent major life changes.'
            )
        };
        insert articles;

        // Query to get the KnowledgeArticleId (master article ID) for publishing
        List<Knowledge__kav> insertedArticles = [
            SELECT Id, KnowledgeArticleId
            FROM Knowledge__kav
            WHERE Id IN :articles
        ];

        // Publish articles using the master article ID
        for (Knowledge__kav article : insertedArticles) {
            KbManagement.PublishingService.publishArticle(article.KnowledgeArticleId, true);
        }
        System.debug('[Financial Onboarding] ✓ Knowledge articles created and published');
    }

    /**
     * @description Step 1: KYC & Risk Assessment Agent
     * Analyzes client application, assesses risk profile, creates compliance tasks
     * Capabilities: get_lead_application, assess_and_update_lead, create_compliance_task
     */
    private static Id createKYCRiskAssessmentAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'KYC Risk Assessment Agent',
            DeveloperName__c = 'KYC_Risk_Assessment_Agent',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            EnableParallelToolCalling__c = false,
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You are a compliance and risk assessment specialist at a financial services firm. You analyze new client applications to determine their risk profile, investment suitability, and compliance requirements. You have expertise in KYC (Know Your Customer) regulations and investment suitability standards.',
            InstructionsPrompt__c = 'Analyze the client application provided in context. Your tasks:\n\n1. **Risk Profile Assessment:** Based on the client description, determine their risk tier:\n   - `Hot` = High-value client (>$1M AUM potential), clear objectives, straightforward needs\n   - `Warm` = Good prospect, moderate complexity, may need additional discovery\n   - `Cold` = Complex situation requiring senior review, inconsistent information, or red flags\n\n2. **Key Factors to Analyze:**\n   - Stated risk tolerance vs. investment goals (check for inconsistencies)\n   - Time horizon appropriateness\n   - Investment experience level\n   - Income/asset level and source\n   - Special requirements or complexity factors\n\n3. **Update the Lead** with your assessment using the Rating field for risk tier.\n\n4. **Create a Compliance Task** for the KYC verification team with specific items to verify based on the client profile.\n\nProvide clear reasoning for your risk assessment.',
            PromptFooter__c = 'Flag any inconsistencies between stated risk tolerance and investment goals. High-net-worth clients (>$5M) should always be marked Hot regardless of complexity.'
        );
        insert agent;
        idMap.put('KYC Risk Assessment Agent', agent.Id);

        // Context provider for lead data
        AgentContextConfig__c leadContext = createContext(agent.Id, 'Client Application', 'LeadContext', 'Lead', true, 10);
        insert leadContext;

        // Capabilities (max 3 to avoid queueable depth issues)
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            createCapability(
                agent.Id,
                'get_lead_application',
                'Retrieves the full client application details from the Lead record. Returns comprehensive information including `Name`, `Company`, `Title`, `Industry`, `AnnualRevenue`, `NumberOfEmployees`, `Description` (contains investment goals and risk tolerance), `LeadSource`, and `Status`. Use this to gather all client information before making your assessment.',
                '{"type":"object","properties":{"Id":{"type":"string","format":"salesforce-id","description":"The 18-character Lead ID from the context. This represents the client application to analyze.","examples":["00QXX000001ABCDEF"]}},"required":["Id"]}',
                'Standard',
                'GetRecordDetails',
                null,
                '{"objectApiName":"Lead","defaultFields":["Id","FirstName","LastName","Name","Company","Title","Email","Phone","Industry","AnnualRevenue","NumberOfEmployees","Description","LeadSource","Status","Rating","CreatedDate"]}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'assess_and_update_lead',
                'Updates the Lead record with your risk assessment. Use the `Rating` field to set the risk tier:\n- `Hot` = High-value, straightforward client ready for onboarding\n- `Warm` = Good prospect requiring standard onboarding process\n- `Cold` = Complex case requiring senior advisor review\n\nAlso update `Status` to `Working - Contacted` to indicate assessment is complete.',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Lead ID to update with assessment results.","examples":["00QXX000001ABCDEF"]},"recordData":{"type":"object","properties":{"Rating":{"type":"string","enum":["Hot","Warm","Cold"],"description":"Risk tier based on your assessment: Hot (high-value/straightforward), Warm (standard process), Cold (complex/needs review)"},"Status":{"type":"string","description":"Update to Working - Contacted after assessment"}},"required":["Rating"],"additionalProperties":true}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{"objectApiName":"Lead"}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'create_compliance_task',
                'Creates a KYC compliance verification task for the compliance team. Include specific verification items based on the client profile:\n- Identity verification requirements\n- Source of funds documentation needed\n- Any enhanced due diligence requirements\n- Accredited investor verification if applicable\n\nSet `Subject` to describe the task, `Description` with detailed verification checklist, `WhoId` to link to the Lead, and `ActivityDate` for the due date.',
                '{"type":"object","properties":{"recordData":{"type":"object","properties":{"Subject":{"type":"string","description":"Task subject, e.g., KYC Verification - [Client Name]","examples":["KYC Verification - Margaret Wellington"]},"Description":{"type":"string","description":"Detailed checklist of verification items specific to this client profile"},"WhoId":{"type":"string","format":"salesforce-id","description":"Lead ID to associate this task with"},"ActivityDate":{"type":"string","format":"date","description":"Due date in YYYY-MM-DD format. Standard KYC should be 3-5 business days.","examples":["2025-01-03"]},"Priority":{"type":"string","enum":["High","Normal","Low"],"description":"High for high-value clients, Normal for standard"}},"required":["Subject","Description","WhoId","ActivityDate"],"additionalProperties":true}},"required":["recordData"]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Task","defaultFieldValues":{"Status":"Not Started","Type":"Compliance"}}',
                false,
                false,
                false,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Financial Onboarding] ✓ KYC Risk Assessment Agent created with ' + capabilities.size() + ' capabilities');
        return agent.Id;
    }

    /**
     * @description Step 2: Account Setup & Assignment Agent
     * Finds suitable products, creates onboarding tasks, notifies RM team
     * Capabilities: search_product_suitability, create_onboarding_tasks, notify_rm_team
     */
    private static Id createAccountSetupAssignmentAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Account Setup Assignment Agent',
            DeveloperName__c = 'Account_Setup_Assignment_Agent',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            EnableParallelToolCalling__c = false,
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You are a client onboarding specialist at a financial services firm. You match new clients with appropriate investment products and relationship managers based on their profile, then coordinate the onboarding process.',
            InstructionsPrompt__c = 'Based on the client application and KYC assessment from Step 1, complete the onboarding setup:\n\n1. **Search Product Suitability:** Find appropriate investment products/portfolios based on:\n   - Client risk tolerance and goals from their description\n   - Asset level (AnnualRevenue field indicates investable assets)\n   - Time horizon and income needs\n\n2. **Create Onboarding Tasks:** Create a task for the assigned relationship manager with:\n   - Recommended portfolio/product based on suitability search\n   - Key talking points for initial client meeting\n   - Any special requirements or considerations\n   - Timeline for account opening steps\n\n3. **Notify RM Team:** Post to the Relationship Management team Chatter group with:\n   - Client summary (name, asset level, profile type)\n   - Risk tier from assessment\n   - Recommended approach and products\n   - Any flags or special considerations\n\nKeep notifications concise but informative.',
            PromptFooter__c = 'Match product recommendations to the specific client needs identified in their description. High-net-worth clients (Hot rating) should be flagged for senior RM assignment.'
        );
        insert agent;
        idMap.put('Account Setup Assignment Agent', agent.Id);

        // Context provider for lead data
        AgentContextConfig__c leadContext = createContext(agent.Id, 'Client Application', 'LeadContext', 'Lead', true, 10);
        insert leadContext;

        // Capabilities (max 3)
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            createCapability(
                agent.Id,
                'search_product_suitability',
                'Searches the knowledge base for product suitability guidelines matching the client profile. Search for terms like:\n- "conservative income" for low-risk, income-focused clients\n- "aggressive growth" for high-risk-tolerance growth investors\n- "balanced moderate" for middle-ground clients\n- "business owner" for clients with business planning needs\n- "risk assessment" for methodology guidance\n\nReturns articles with suitability criteria, recommended allocations, and minimum requirements.',
                '{"type":"object","properties":{"searchQuery":{"type":"string","description":"Search terms based on client profile. Use risk tolerance + objective keywords.","examples":["conservative income portfolio","aggressive growth high risk","business owner comprehensive","balanced moderate portfolio"]},"maxResults":{"type":"integer","description":"Number of articles to return (recommend 3-5)","default":5,"minimum":1,"maximum":10}},"required":["searchQuery"]}',
                'Apex',
                null,
                'ActionSearchKnowledge',
                null,
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'create_onboarding_tasks',
                'Creates an onboarding task for the relationship manager with client-specific action items. Include:\n- Recommended products based on suitability search results\n- Key discussion points for initial meeting\n- Required documentation to collect\n- Timeline milestones\n\nLink to the Lead using `WhoId`.',
                '{"type":"object","properties":{"recordData":{"type":"object","properties":{"Subject":{"type":"string","description":"Task subject, e.g., Client Onboarding - [Name] - [Profile Type]","examples":["Client Onboarding - Margaret Wellington - Conservative HNW"]},"Description":{"type":"string","description":"Detailed onboarding checklist with recommended products, talking points, and timeline"},"WhoId":{"type":"string","format":"salesforce-id","description":"Lead ID to associate this task with"},"ActivityDate":{"type":"string","format":"date","description":"Target date for initial client meeting, typically 5-7 days out","examples":["2025-01-06"]},"Priority":{"type":"string","enum":["High","Normal","Low"],"description":"High for Hot leads, Normal for Warm, Low for Cold"}},"required":["Subject","Description","WhoId","ActivityDate"],"additionalProperties":true}},"required":["recordData"]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Task","defaultFieldValues":{"Status":"Not Started","Type":"Onboarding"}}',
                false,
                false,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'notify_rm_team',
                'Posts a summary to the Relationship Management team Chatter group. Include:\n- Client name and company\n- Asset level and risk tier (Hot/Warm/Cold)\n- Profile summary (investor type, key needs)\n- Recommended products/approach\n- Any special considerations or flags\n\nKeep under 150 words. Use this to alert the team about new client assignments.',
                '{"type":"object","properties":{"messageText":{"type":"string","description":"Concise client summary for the RM team. Include: name, assets, risk tier, profile type, recommended approach, and any flags.","examples":["New Client Assignment: Margaret Wellington (Wellington Family Trust)\\n\\nAsset Level: $15M | Risk Tier: Hot\\nProfile: Conservative HNW - Capital preservation focus\\n\\nRecommended: Conservative Income Portfolio (70% fixed income, 25% dividend equities)\\n\\nKey Notes: Referred client, requires quarterly reporting and annual in-person reviews. 30+ years experience - sophisticated investor.\\n\\nAssigned for senior RM handling."]},"topics":{"type":"array","description":"Optional hashtags for categorization","items":{"type":"string"},"examples":[["NewClient","HNW","Conservative"]]}},"required":["messageText"]}',
                'Standard',
                'PostChatter',
                null,
                '{"feedType":"Group","targetId":"' + idMap.get('RM Chatter Group') + '"}',
                false,
                false,
                true,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Financial Onboarding] ✓ Account Setup Assignment Agent created with ' + capabilities.size() + ' capabilities');
        return agent.Id;
    }

    // ===================================================================================
    // HELPER METHODS
    // ===================================================================================

    /**
     * @description Creates an AgentCapability__c record with all configuration options.
     * @param agentId Parent agent definition ID
     * @param name Capability name (tool name)
     * @param description Tool description for LLM
     * @param parameters JSON schema for parameters
     * @param implType Implementation type (Apex, Flow, Standard)
     * @param stdType Standard action type (if implType is Standard)
     * @param implDetail Implementation detail (class name or flow name)
     * @param backendConfig Backend configuration JSON
     * @param requiresConfirmation Legacy field - use hitlMode instead
     * @param requiresApproval Legacy field - use hitlMode instead
     * @param runAsync Whether to run asynchronously
     * @param exposure Exposure level (External, Internal, Disabled)
     * @return AgentCapability__c record (not inserted)
     */
    private static AgentCapability__c createCapability(
        Id agentId,
        String name,
        String description,
        String parameters,
        String implType,
        String stdType,
        String implDetail,
        String backendConfig,
        Boolean requiresConfirmation,
        Boolean requiresApproval,
        Boolean runAsync,
        String exposure
    ) {
        // Map legacy fields to new HITLMode__c
        String hitlMode;
        if (requiresApproval == true) {
            hitlMode = 'Approval';
        } else if (requiresConfirmation == true) {
            hitlMode = 'Confirmation';
        }

        return new AgentCapability__c(
            AIAgentDefinition__c = agentId,
            CapabilityName__c = name,
            Description__c = description,
            Parameters__c = parameters,
            ImplementationType__c = implType,
            StandardActionType__c = stdType,
            ImplementationDetail__c = implDetail,
            BackendConfiguration__c = backendConfig,
            HITLMode__c = hitlMode,
            RunAsynchronously__c = runAsync,
            ExposureLevel__c = exposure
        );
    }

    /**
     * @description Creates an AgentCapability__c record with explicit HITL mode.
     * Use this method for new code instead of the legacy createCapability method.
     *
     * @param agentId Parent agent definition ID
     * @param name Capability name (tool name)
     * @param description Tool description for LLM
     * @param parameters JSON schema for parameters
     * @param implType Implementation type (Apex, Flow, Standard)
     * @param stdType Standard action type (if implType is Standard)
     * @param implDetail Implementation detail (class name or flow name)
     * @param backendConfig Backend configuration JSON
     * @param hitlMode HITL mode: 'Confirmation', 'Approval', or 'ConfirmationThenApproval'
     * @param runAsync Whether to run asynchronously
     * @param exposure Exposure level (External, Internal, Disabled)
     * @return AgentCapability__c record (not inserted)
     */
    public static AgentCapability__c createCapabilityWithHITL(
        Id agentId,
        String name,
        String description,
        String parameters,
        String implType,
        String stdType,
        String implDetail,
        String backendConfig,
        String hitlMode,
        Boolean runAsync,
        String exposure
    ) {
        return new AgentCapability__c(
            AIAgentDefinition__c = agentId,
            CapabilityName__c = name,
            Description__c = description,
            Parameters__c = parameters,
            ImplementationType__c = implType,
            StandardActionType__c = stdType,
            ImplementationDetail__c = implDetail,
            BackendConfiguration__c = backendConfig,
            HITLMode__c = hitlMode,
            RunAsynchronously__c = runAsync,
            ExposureLevel__c = exposure
        );
    }

    // ===================================================================================
    // HITL TEST DATA CREATION
    // ===================================================================================

    /**
     * @description Creates a complete HITL test scenario with agent, capabilities, execution, and pending action.
     * Useful for testing the full HITL flow.
     *
     * @param hitlMode The HITL mode to test: 'Confirmation' or 'Approval'
     * @return Map<String, Id> containing IDs of created records:
     *         - 'agentId': AIAgentDefinition__c ID
     *         - 'capabilityId': AgentCapability__c ID
     *         - 'executionId': AgentExecution__c ID
     *         - 'pendingActionId': PendingHITLAction__c ID
     */
    public static Map<String, Id> createHITLTestScenario(String hitlMode) {
        Map<String, Id> result = new Map<String, Id>();

        // Create LLM Configuration if not exists
        LLMConfiguration__c llmConfig = createTestLLMConfiguration();
        result.put('llmConfigId', llmConfig.Id);

        // Create Agent Definition
        AIAgentDefinition__c agent = createTestAgentForHITL(llmConfig.Id, hitlMode);
        result.put('agentId', agent.Id);

        // Create Capability with HITL mode
        AgentCapability__c capability = createTestCapabilityForHITL(agent.Id, hitlMode);
        result.put('capabilityId', capability.Id);

        // Create Agent Execution
        AgentExecution__c execution = createTestExecution(agent.Id);
        result.put('executionId', execution.Id);

        // Create Pending HITL Action
        PendingHITLAction__c pendingAction = createTestPendingHITLAction(
            execution.Id,
            capability.Id,
            hitlMode
        );
        result.put('pendingActionId', pendingAction.Id);

        return result;
    }

    /**
     * @description Creates a test LLM configuration for HITL testing.
     * @return LLMConfiguration__c record
     */
    public static LLMConfiguration__c createTestLLMConfiguration() {
        // Check if test config already exists
        List<LLMConfiguration__c> existing = [
            SELECT Id FROM LLMConfiguration__c
            WHERE DeveloperName__c = 'Test_HITL_Config'
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0];
        }

        LLMConfiguration__c config = new LLMConfiguration__c(
            Name = 'Test HITL Config',
            DeveloperName__c = 'Test_HITL_Config',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-4o-mini',
            DefaultTemperature__c = 0.1,
            IsActive__c = true
        );
        insert config;
        return config;
    }

    /**
     * @description Creates a test agent definition configured for HITL testing.
     * @param llmConfigId LLM Configuration ID
     * @param hitlMode The HITL mode being tested
     * @return AIAgentDefinition__c record
     */
    public static AIAgentDefinition__c createTestAgentForHITL(Id llmConfigId, String hitlMode) {
        // For Confirmation mode, must be Conversational agent
        String agentType = (hitlMode == 'Confirmation') ? 'Conversational' : 'Function';

        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'HITL Test Agent - ' + hitlMode,
            DeveloperName__c = 'HITL_Test_Agent_' + hitlMode + '_' + System.currentTimeMillis(),
            AgentType__c = agentType,
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            IdentityPrompt__c = 'You are a test agent for HITL functionality.',
            InstructionsPrompt__c = 'Execute tools as requested.'
        );
        insert agent;
        return agent;
    }

    /**
     * @description Creates a test capability with specified HITL mode.
     * @param agentId Parent agent definition ID
     * @param hitlMode HITL mode: 'None', 'Confirmation', 'Approval', or 'ConfirmationThenApproval'
     * @return AgentCapability__c record
     */
    public static AgentCapability__c createTestCapabilityForHITL(Id agentId, String hitlMode) {
        String capabilityName = 'test_hitl_action_' + hitlMode.toLowerCase();

        AgentCapability__c capability = new AgentCapability__c(
            AIAgentDefinition__c = agentId,
            CapabilityName__c = capabilityName,
            Description__c = 'Test capability for HITL ' + hitlMode + ' mode testing',
            Parameters__c = '{"type":"object","properties":{"testParam":{"type":"string","description":"A test parameter"}},"required":["testParam"]}',
            ImplementationType__c = 'Apex',
            ImplementationDetail__c = 'ActionEcho',
            HITLMode__c = hitlMode,
            RunAsynchronously__c = false,
            ExposureLevel__c = 'External'
        );
        insert capability;
        return capability;
    }

    /**
     * @description Creates a test agent execution record.
     * @param agentId Parent agent definition ID
     * @return AgentExecution__c record
     */
    public static AgentExecution__c createTestExecution(Id agentId) {
        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agentId,
            User__c = UserInfo.getUserId(),
            ExecutionStatus__c = 'Running',
            ProcessingStatus__c = 'Processing',
            StartTime__c = DateTime.now(),
            CurrentTurnIdentifier__c = 'turn_' + System.currentTimeMillis()
        );
        insert execution;
        return execution;
    }

    /**
     * @description Creates a PendingHITLAction__c record for testing.
     * @param executionId Parent execution ID
     * @param capabilityId Capability ID
     * @param hitlType HITL type: 'Confirmation' or 'Approval'
     * @return PendingHITLAction__c record
     */
    public static PendingHITLAction__c createTestPendingHITLAction(
        Id executionId,
        Id capabilityId,
        String hitlType
    ) {
        return createTestPendingHITLAction(
            executionId,
            capabilityId,
            hitlType,
            'Pending',
            '{"testParam": "test value"}'
        );
    }

    /**
     * @description Creates a PendingHITLAction__c record with custom status and arguments.
     * @param executionId Parent execution ID
     * @param capabilityId Capability ID
     * @param hitlType HITL type: 'Confirmation' or 'Approval'
     * @param status Status: 'Pending', 'Confirmed', 'Declined', 'Approved', 'Rejected', 'Expired'
     * @param toolArgumentsJson JSON string of tool arguments
     * @return PendingHITLAction__c record
     */
    public static PendingHITLAction__c createTestPendingHITLAction(
        Id executionId,
        Id capabilityId,
        String hitlType,
        String status,
        String toolArgumentsJson
    ) {
        // Get capability name
        AgentCapability__c cap = [SELECT CapabilityName__c FROM AgentCapability__c WHERE Id = :capabilityId LIMIT 1];

        DateTime expiresAt = null;
        if (hitlType == 'Confirmation') {
            expiresAt = DateTime.now().addSeconds(300);
        }

        PendingHITLAction__c pendingAction = new PendingHITLAction__c(
            AgentExecution__c = executionId,
            AIAgentCapability__c = capabilityId,
            HITLType__c = hitlType,
            Status__c = status,
            TurnIdentifier__c = 'turn_' + System.currentTimeMillis(),
            TurnCount__c = 1,
            ToolCallId__c = 'call_test_' + System.currentTimeMillis(),
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = toolArgumentsJson,
            ConfirmationPrompt__c = 'Test confirmation prompt for ' + cap.CapabilityName__c,
            RequestedAt__c = DateTime.now(),
            ExpiresAt__c = expiresAt,
            RequestingUser__c = UserInfo.getUserId()
        );
        insert pendingAction;
        return pendingAction;
    }

    /**
     * @description Creates multiple pending HITL actions for batch testing.
     * @param executionId Parent execution ID
     * @param capabilityId Capability ID
     * @param hitlType HITL type
     * @param count Number of records to create
     * @return List of PendingHITLAction__c records
     */
    public static List<PendingHITLAction__c> createBulkPendingHITLActions(
        Id executionId,
        Id capabilityId,
        String hitlType,
        Integer count
    ) {
        AgentCapability__c cap = [SELECT CapabilityName__c FROM AgentCapability__c WHERE Id = :capabilityId LIMIT 1];

        List<PendingHITLAction__c> actions = new List<PendingHITLAction__c>();
        DateTime expiresAt = hitlType == 'Confirmation' ? DateTime.now().addSeconds(300) : null;

        for (Integer i = 0; i < count; i++) {
            actions.add(new PendingHITLAction__c(
                AgentExecution__c = executionId,
                AIAgentCapability__c = capabilityId,
                HITLType__c = hitlType,
                Status__c = 'Pending',
                TurnIdentifier__c = 'turn_' + System.currentTimeMillis() + '_' + i,
                TurnCount__c = i + 1,
                ToolCallId__c = 'call_test_' + System.currentTimeMillis() + '_' + i,
                ToolName__c = cap.CapabilityName__c,
                ToolArgumentsJSON__c = '{"testParam": "value_' + i + '"}',
                ConfirmationPrompt__c = 'Test confirmation prompt #' + i,
                RequestedAt__c = DateTime.now(),
                ExpiresAt__c = expiresAt,
                RequestingUser__c = UserInfo.getUserId()
            ));
        }
        insert actions;
        return actions;
    }

    /**
     * @description Creates an expired pending HITL action for testing expiration handling.
     * Note: This creates an Approval type action since Confirmation mode no longer creates PendingHITLAction records.
     * @param executionId Parent execution ID
     * @param capabilityId Capability ID
     * @return PendingHITLAction__c record with past expiration time
     */
    public static PendingHITLAction__c createExpiredPendingHITLAction(
        Id executionId,
        Id capabilityId
    ) {
        AgentCapability__c cap = [SELECT CapabilityName__c FROM AgentCapability__c WHERE Id = :capabilityId LIMIT 1];

        PendingHITLAction__c pendingAction = new PendingHITLAction__c(
            AgentExecution__c = executionId,
            AIAgentCapability__c = capabilityId,
            HITLType__c = 'Approval',
            Status__c = 'Pending',
            TurnIdentifier__c = 'turn_expired_' + System.currentTimeMillis(),
            TurnCount__c = 1,
            ToolCallId__c = 'call_expired_' + System.currentTimeMillis(),
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{"testParam": "expired_test"}',
            ConfirmationPrompt__c = 'This action has expired',
            RequestedAt__c = DateTime.now().addMinutes(-10),
            ExpiresAt__c = DateTime.now().addMinutes(-5), // Already expired
            RequestingUser__c = UserInfo.getUserId()
        );
        insert pendingAction;
        return pendingAction;
    }

    public static void replaceCapabilitiesWithHttpCallout(Set<String> capabilityNames) {
        System.debug('[Capability Replacement] Starting replacement of capabilities with HTTP callout...');

        // Find existing capabilities to update
        List<AgentCapability__c> capabilities = [
            SELECT Id, CapabilityName__c, Description__c, Parameters__c,
                   ImplementationType__c, ImplementationDetail__c, BackendConfiguration__c
            FROM AgentCapability__c
            WHERE CapabilityName__c IN :capabilityNames
        ];

        for (AgentCapability__c cap : capabilities) {
            cap.ImplementationType__c = 'Apex';
            cap.ImplementationDetail__c = 'ActionHttpCallout';
            cap.RunAsynchronously__c = true;
            cap.HITLMode__c = null;
            cap.BackendConfiguration__c = null;
        }

        update capabilities;
    }

    private static AgentContextConfig__c createContext(
        Id agentId,
        String label,
        String implName,
        String applicableSObjects,
        Boolean requiresRecord,
        Integer order
    ) {
        return new AgentContextConfig__c(
            AIAgentDefinition__c = agentId,
            ContextLabel__c = label,
            ImplementationType__c = 'Apex',
            ImplementationName__c = implName,
            ApplicableSObjectTypes__c = applicableSObjects,
            RequiresRecordContext__c = requiresRecord,
            ExecutionOrder__c = order,
            IsActive__c = true
        );
    }
}
