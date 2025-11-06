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

        // Clean slate
        deleteExistingData();

        // 1. Core foundational data
        seedFoundationalData();

        // 2. LLM Configuration (shared by all agents)
        LLMConfiguration__c llmConfig = createLLMConfiguration();

        // 3. Create agents for different use cases
        createConversationalAgent(llmConfig.Id);
        createFunctionAgents(llmConfig.Id);
        createWorkflowAgent(llmConfig.Id);

        System.debug('========================================');
        System.debug('SHOWCASE COMPLETE! Key Record IDs:');
        System.debug(JSON.serializePretty(idMap));
        System.debug('========================================');
        return idMap;
    }

    // ===================================================================================
    // DATA CLEANUP
    // ===================================================================================

    private static void deleteExistingData() {
        System.debug('[Cleanup] Removing existing data...');
        try {
            // Deactivate orders first (required before deletion)
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

            // Delete framework data (must respect dependencies)
            delete [SELECT Id FROM AgentDecisionStep__c];
            delete [SELECT Id FROM ExecutionStep__c];
            delete [SELECT Id FROM AgentExecution__c];
            delete [SELECT Id FROM AgentWorkflowStep__c];
            delete [SELECT Id FROM AgentCapability__c];
            delete [SELECT Id FROM AgentContextConfig__c];
            delete [SELECT Id FROM AIAgentDefinition__c];
            delete [SELECT Id FROM LLMConfiguration__c];

            // Delete business data
            delete [SELECT Id FROM Task WHERE Subject LIKE '%AI Generated%'];
            delete [
                SELECT Id
                FROM Case
                WHERE Subject LIKE '%Test%' OR Account.Name IN ('Acme Corporation', 'Global Logistics Ltd', 'TechStart Innovations')
            ];
            delete [SELECT Id FROM Opportunity WHERE Account.Name IN ('Acme Corporation', 'Global Logistics Ltd', 'TechStart Innovations')];
            delete [SELECT Id FROM Lead WHERE Company IN ('Beta Industries', 'Startup Co')];
            delete [SELECT Id FROM OrderItem];
            delete [SELECT Id FROM Order WHERE Account.Name IN ('Acme Corporation', 'Global Logistics Ltd', 'TechStart Innovations')];
            delete [SELECT Id FROM Contact WHERE Account.Name IN ('Acme Corporation', 'Global Logistics Ltd', 'TechStart Innovations')];
            delete [SELECT Id FROM Account WHERE Name IN ('Acme Corporation', 'Global Logistics Ltd', 'TechStart Innovations')];
            delete [SELECT Id FROM CollaborationGroup WHERE Name = 'Support Team'];

            System.debug('[Cleanup] ✓ Existing data removed');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[Cleanup] Could not fully clean (may be first run): ' + e.getMessage());
        }
    }

    // ===================================================================================
    // FOUNDATIONAL DATA
    // ===================================================================================

    private static void seedFoundationalData() {
        System.debug('[Foundation] Creating core business data...');

        // Accounts & Contacts
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
            new Contact(
                FirstName = 'Sarah',
                LastName = 'Johnson',
                AccountId = accounts[0].Id,
                Email = 'sarah.johnson@acme.com',
                Title = 'IT Director'
            ),
            new Contact(
                FirstName = 'Michael',
                LastName = 'Chen',
                AccountId = accounts[0].Id,
                Email = 'michael.chen@acme.com',
                Title = 'Support Manager'
            ),
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

        // Products & Pricebook
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

        // Cases (various statuses for testing)
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

        // Opportunities (for opportunity assistant testing)
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

        // Leads (for lead qualifier testing)
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

        // Chatter Group for notifications
        CollaborationGroup supportGroup = new CollaborationGroup(Name = 'Support Team', CollaborationType = 'Public');
        insert supportGroup;
        idMap.put('Support Chatter Group', supportGroup.Id);

        // Knowledge Articles
        seedKnowledgeArticles();

        System.debug('[Foundation] ✓ Core business data created');
    }

    private static void seedKnowledgeArticles() {
        try {
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

            // Publish articles
            for (Knowledge__kav article : articles) {
                KbManagement.PublishingService.publishArticle(article.Id, true);
            }
            System.debug('[Foundation] ✓ Knowledge articles published');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[Foundation] Could not create Knowledge (ensure Knowledge is enabled): ' + e.getMessage());
        }
    }

    // ===================================================================================
    // LLM CONFIGURATION
    // ===================================================================================

    private static LLMConfiguration__c createLLMConfiguration() {
        System.debug('[LLM] Creating configuration...');
        LLMConfiguration__c config = new LLMConfiguration__c(
            Name = 'OpenAI GPT-4',
            DeveloperName__c = 'OpenAI_GPT4',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-4o-mini',
            DefaultTemperature__c = 0.1,
            IsActive__c = true
        );
        insert config;
        idMap.put('LLM Config', config.Id);
        System.debug('[LLM] ✓ Configuration created');
        return config;
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
                'Search the knowledge base for troubleshooting articles',
                '{"type":"object","properties":{"searchQuery":{"type":"string","description":"The search term or keywords"},"maxResults":{"type":"integer","description":"Maximum number of results to return (default 5, max 20)"}},"required":["searchQuery"]}',
                'Apex',
                null,
                'ActionSearchKnowledge',
                null,
                false,
                false,
                10,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_case_details',
                'Get details of a specific case by ID',
                '{"type":"object","properties":{"caseId":{"type":"string","description":"The Salesforce Case ID (18-character ID starting with 500)"}},"required":["caseId"]}',
                'Apex',
                null,
                'ActionCase',
                '{"operation":"GET_BY_ID","defaultFields":["Id","CaseNumber","Subject","Description","Status","Priority","CreatedDate"],"maxResults":1}',
                false,
                false,
                20,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'create_case',
                'Create a new support case',
                '{"type":"object","properties":{"recordData":{"type":"object","description":"SObject field values to set on the new record. Property names should be valid field API names.","additionalProperties":true}},"required":[]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Case","defaultFieldValues":{"Status":"New","Origin":"AI Agent"}}',
                true,
                false,
                30,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'update_case',
                'Update an existing case',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Case ID to update."},"recordData":{"type":"object","properties":{"Status":{"type":"string","description":"Case Status"},"Priority":{"type":"string","enum":["High","Medium","Low"]}},"additionalProperties":true}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{}',
                true,
                false,
                40,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_order_status',
                'Get order status and details by ID',
                '{"type":"object","properties":{"orderId":{"type":"string","description":"The Salesforce Order ID (18-character ID starting with 801)"}},"required":["orderId"]}',
                'Apex',
                null,
                'ActionOrder',
                '{"operation":"GET_BY_ID","defaultFields":["Id","OrderNumber","Status","TotalAmount","EffectiveDate"],"maxResults":1}',
                false,
                false,
                50,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'notify_support_team',
                'Post a message to the Support Team Chatter group',
                '{"type":"object","properties":{"messageText":{"type":"string","description":"Message to post"},"topics":{"type":"array","description":"Optional topics","items":{"type":"string"}}},"required":["messageText"]}',
                'Standard',
                'PostChatter',
                null,
                '{"feedType":"Group","targetId":"' + idMap.get('Support Chatter Group') + '"}',
                true,
                false,
                60,
                true,
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
            IdentityPrompt__c = 'You are an expert at summarizing technical support cases into concise, actionable summaries.',
            InstructionsPrompt__c = 'Analyze the case description and create a 2-3 sentence summary that captures: 1) The core issue, 2) Business impact, 3) Urgency level. Be clear and concise.',
            PromptFooter__c = 'Format: Start with issue type, then impact, then recommended action.'
        );
        insert agent;
        idMap.put('Case Summarizer Agent', agent.Id);

        // NO capabilities - pure LLM text generation
        // This demonstrates the tool-terminating pattern with 0 tools

        System.debug('[Agent:Function] ✓ Case Summarizer (0 tools - pure LLM)');
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
            InstructionsPrompt__c = 'Analyze the lead data provided in context. Consider: company size (larger is better), title seniority (C-level/VP = higher quality), industry fit (Technology/Manufacturing = good fit), engagement (downloads/referrals = positive). Use the update_lead_rating tool to set the rating, then explain your reasoning.',
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
            'Updates the rating field on a lead record',
            '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Lead ID to update."},"recordData":{"type":"object","properties":{"Rating":{"type":"string","enum":["Hot","Warm","Cold"],"description":"Lead qualification rating"}},"additionalProperties":true}},"required":["recordId","recordData"]}',
            'Standard',
            'UpdateRecord',
            null,
            '{}',
            false, // no confirmation needed
            false, // no approval needed
            10,
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
                'Search for opportunities for a specific account',
                '{"type":"object","properties":{"accountId":{"type":"string","description":"The Salesforce Account ID to search opportunities for"}},"required":["accountId"]}',
                'Apex',
                null,
                'ActionOpportunity',
                '{"operation":"SEARCH_BY_ACCOUNT","defaultFields":["Id","Name","StageName","Amount","CloseDate","Probability","AccountId"],"maxResults":10}',
                false,
                false,
                10,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'update_opportunity_stage',
                'Update the stage of an opportunity',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Opportunity ID to update."},"recordData":{"type":"object","properties":{"StageName":{"type":"string","description":"Opportunity stage"},"Probability":{"type":"number","description":"Win probability (0-100)"}},"additionalProperties":true}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{}',
                true,
                false,
                20,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'create_followup_task',
                'Create a follow-up task related to an opportunity',
                '{"type":"object","properties":{"recordData":{"type":"object","description":"SObject field values to set on the new record. Property names should be valid field API names.","additionalProperties":true}},"required":[]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Task","defaultFieldValues":{"Status":"Not Started","Priority":"Normal"}}',
                false,
                false,
                30,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_account_info',
                'Get account information by ID',
                '{"type":"object","properties":{"accountId":{"type":"string","description":"The Salesforce Account ID (18-character ID starting with 001)"}},"required":["accountId"]}',
                'Apex',
                null,
                'ActionAccount',
                '{"operation":"GET_BY_ID","defaultFields":["Id","Name","Industry","AnnualRevenue","BillingCity","BillingState"],"maxResults":1}',
                false,
                false,
                40,
                false,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Agent:Function] ✓ Opportunity Assistant (4 tools - iterative agentic)');
    }

    // ===================================================================================
    // WORKFLOW AGENT
    // ===================================================================================

    /**
     * @description Creates a workflow agent that orchestrates 2 function agents with multiple capabilities
     * Demonstrates: Analyze & Triage → Resolve & Notify workflow for case processing
     */
    private static void createWorkflowAgent(Id llmConfigId) {
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

        System.debug(
            '[Agent:Workflow] ✓ Case Processing Workflow created with ' + steps.size() + ' steps (2 function agents with multiple capabilities)'
        );
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
            AuditLevel__c = 'Minimal',
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
                'Get account information by ID',
                '{"type":"object","properties":{"accountId":{"type":"string","description":"The Salesforce Account ID (18-character ID starting with 001)"}},"required":["accountId"]}',
                'Apex',
                null,
                'ActionAccount',
                '{"operation":"GET_BY_ID","defaultFields":["Id","Name","Industry","Type","AccountNumber","Phone","BillingCity","AnnualRevenue"],"maxResults":1}',
                false,
                false,
                10,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_orders',
                'Get orders for a specific account',
                '{"type":"object","properties":{"accountId":{"type":"string","description":"The Salesforce Account ID to get orders for"}},"required":["accountId"]}',
                'Apex',
                null,
                'ActionOrder',
                '{"operation":"SEARCH_BY_ACCOUNT","defaultFields":["Id","OrderNumber","Status","TotalAmount","EffectiveDate","Type"],"maxResults":10}',
                false,
                false,
                20,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'update_case_priority',
                'Update case priority based on analysis',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Case ID of the record to update."},"recordData":{"type":"object","properties":{"Priority":{"type":"string","enum":["High","Medium","Low"],"description":"Priority"}},"additionalProperties":true}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{}',
                false,
                false,
                10,
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
            AuditLevel__c = 'Minimal',
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
                'Search knowledge base for relevant solutions',
                '{"type":"object","properties":{"searchQuery":{"type":"string","description":"Search keywords from case subject/description"},"maxResults":{"type":"integer"}},"required":["searchQuery"]}',
                'Apex',
                null,
                'ActionSearchKnowledge',
                null,
                false,
                false,
                10,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'create_follow_up_task',
                'Create follow-up task for case actions',
                '{"type":"object","properties":{"recordData":{"type":"object","description":"SObject field values to set on the new record. Property names should be valid field API names.","additionalProperties":true}},"required":[]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Task","defaultFieldValues":{"Status":"Not Started","Priority":"Normal"}}',
                false,
                false,
                10,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'post_to_chatter',
                'Post summary notification to support team',
                '{"type":"object","properties":{"messageText":{"type":"string","description":"The content of the message to post to Chatter."},"topics":{"type":"array","description":"An optional list of topics to associate with the post.","items":{"type":"string"}}},"required":["messageText"]}',
                'Standard',
                'PostChatter',
                null,
                '{"feedType":"Group","targetId":"' + idMap.get('Support Chatter Group') + '"}',
                false,
                false,
                10,
                true,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Agent:Function] ✓ Case Resolution & Notification Agent created with ' + capabilities.size() + ' capabilities (max 3)');
        return agent.Id;
    }

    // ===================================================================================
    // HELPER METHODS
    // ===================================================================================

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
        Integer priority,
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
            RequiresConfirmation__c = requiresConfirmation,
            RequiresApproval__c = requiresApproval,
            ExecutionPriority__c = priority,
            RunAsynchronously__c = runAsync,
            ExposureLevel__c = exposure
        );
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
