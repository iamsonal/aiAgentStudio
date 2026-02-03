/**
 * @description Test data factory for Progressive Function Agent Demos
 *              Three progressive demos showing evolution from basic to sophisticated:
 *              Demo 1: Basic Function Agent (no capabilities) - Case Summary
 *              Demo 2: Single Capability Function Agent - Account Fit Scoring
 *              Demo 3: Multi-Capability Orchestration - Product Launch Campaign
 *
 * **Demo 1: Case Summary Agent (Basic)**
 * - No capabilities (pure LLM intelligence)
 * - Reads Case data and provides intelligent summary
 * - Shows: AI understanding, not actionable
 * - Time: 2-3 minutes
 *
 * **Demo 2: Account Scoring Agent (Intermediate)**
 * - Single capability (Flow-based scoring)
 * - Scores account fit for product (0-100)
 * - Shows: Function agent executing capabilities and interpreting results
 * - Time: 3-4 minutes
 *
 * **Demo 3: Product Launch Orchestrator (Advanced)**
 * - 7 capabilities (2 Apex, 2 Flow, 3 Standard)
 * - Multi-account campaign with AI content generation, HITL, error recovery
 * - Shows: Full orchestration power with real AI intelligence
 * - Time: 12-15 minutes
 *
 * **Key Features Demonstrated:**
 * - Progressive complexity (simple → intermediate → advanced)
 * - Real AI intelligence (scoring, engagement analysis, content generation)
 * - AgentContextConfig preventing unnecessary tool calls
 * - Human-in-the-loop approval with adaptive rejection handling
 * - Resume from failure point
 * - Mixed action types in single workflow
 *
 * @usage Execute in Anonymous Apex:
 * // Create all three demos
 * Map<String, Id> data = ProductLaunchDemoFactory.createAllDemos();
 *
 * // Or create individual demos
 * ProductLaunchDemoFactory.createDemo1_CaseSummary();
 * ProductLaunchDemoFactory.createDemo2_AccountScoring();
 * ProductLaunchDemoFactory.createDemo3_ProductLaunch();
 *
 * @author Sonal
 * @since January 2026
 */
public with sharing class ProductLaunchDemoFactory {
    private static Map<String, Id> idMap = new Map<String, Id>();

    // Demo configuration
    private static final String PRODUCT_NAME = 'AI Analytics Platform';
    private static final String CAMPAIGN_NAME = 'Q1 2026 AI Analytics Launch';
    private static final Integer HISTORICAL_DAYS = 180; // 6 months of history

    /**
     * @description Creates all three progressive demos
     * @return Map<String, Id> Key record IDs for testing
     */
    public static Map<String, Id> createAllDemos() {
        System.debug('=== PROGRESSIVE FUNCTION AGENT DEMOS ===');

        deleteExistingDemoData();

        LLMConfiguration__c llmConfig = createLLMConfiguration();
        createProductCatalog();
        Map<String, Id> accountIds = createDemoAccounts();
        createContactsForAccounts(accountIds);
        createOpportunityHistory(accountIds);
        createSupportHistory(accountIds);
        createActivityHistory(accountIds);
        createSampleCases();

        createCaseSummaryAgent(llmConfig.Id);
        createAccountScoringAgent(llmConfig.Id);
        createProductLaunchAgent(llmConfig.Id);

        System.debug('=== DEMOS COMPLETE ===');
        System.debug('Demo 1 (Case Summary): ' + idMap.get('Demo1 Agent'));
        System.debug('Demo 2 (Account Scoring): ' + idMap.get('Demo2 Agent'));
        System.debug('Demo 3 (Product Launch): ' + idMap.get('Demo3 Agent'));

        return idMap;
    }

    public static Id createDemo1_CaseSummary() {
        deleteDemo1Data();
        LLMConfiguration__c llmConfig = createLLMConfiguration();
        createSampleCases();
        Id agentId = createCaseSummaryAgent(llmConfig.Id);
        System.debug('[Demo 1] Complete. Agent ID: ' + agentId);
        return agentId;
    }

    public static Id createDemo2_AccountScoring() {
        deleteDemo2Data();
        LLMConfiguration__c llmConfig = createLLMConfiguration();
        Map<String, Id> accountIds = createDemoAccounts();
        createContactsForAccounts(accountIds);
        Id agentId = createAccountScoringAgent(llmConfig.Id);
        System.debug('[Demo 2] Complete. Agent ID: ' + agentId);
        return agentId;
    }

    public static Id createDemo3_ProductLaunch() {
        deleteDemo3Data();
        LLMConfiguration__c llmConfig = createLLMConfiguration();
        createProductCatalog();
        Map<String, Id> accountIds = createDemoAccounts();
        createContactsForAccounts(accountIds);
        createOpportunityHistory(accountIds);
        createSupportHistory(accountIds);
        createActivityHistory(accountIds);
        Id agentId = createProductLaunchAgent(llmConfig.Id);
        System.debug('[Demo 3] Complete. Agent ID: ' + agentId);
        return agentId;
    }

    public static Map<String, Id> createDemo() {
        createDemo3_ProductLaunch();
        return idMap;
    }

    // ===================================================================================
    // CLEANUP
    // ===================================================================================

    /**
     * @description Deletes all demo data (all 3 demos)
     */
    public static void deleteExistingDemoData() {
        System.debug('[Cleanup] Removing existing demo data...');

        delete [SELECT Id FROM ExecutionStep__c];
        delete [SELECT Id FROM AgentExecution__c];

        deleteDemo1Data();
        deleteDemo2Data();
        deleteDemo3Data();

        System.debug('[Cleanup] ✓ All demo data cleaned');
    }

    /**
     * @description Deletes Demo 1 data (Case Summary Agent)
     */
    private static void deleteDemo1Data() {
        // Delete agent configuration
        delete [SELECT Id FROM AgentContextConfig__c WHERE AIAgentDefinition__r.DeveloperName__c = 'Case_Summary_Agent'];
        delete [SELECT Id FROM AgentCapability__c WHERE AIAgentDefinition__r.DeveloperName__c = 'Case_Summary_Agent'];
        delete [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c = 'Case_Summary_Agent'];

        // Delete sample cases
        delete [SELECT Id FROM Case WHERE Subject LIKE '%Demo Case%'];
    }

    /**
     * @description Deletes Demo 2 data (Account Scoring Agent)
     */
    private static void deleteDemo2Data() {
        // Delete agent configuration
        delete [SELECT Id FROM AgentContextConfig__c WHERE AIAgentDefinition__r.DeveloperName__c = 'Account_Fit_Scoring_Agent'];
        delete [SELECT Id FROM AgentCapability__c WHERE AIAgentDefinition__r.DeveloperName__c = 'Account_Fit_Scoring_Agent'];
        delete [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c = 'Account_Fit_Scoring_Agent'];
    }

    /**
     * @description Deletes Demo 3 data (Product Launch Orchestrator)
     */
    private static void deleteDemo3Data() {
        // Delete agent configuration
        delete [SELECT Id FROM AgentContextConfig__c WHERE AIAgentDefinition__r.DeveloperName__c = 'Product_Launch_Orchestrator'];
        delete [SELECT Id FROM AgentCapability__c WHERE AIAgentDefinition__r.DeveloperName__c = 'Product_Launch_Orchestrator'];
        delete [SELECT Id FROM AIAgentDefinition__c WHERE DeveloperName__c = 'Product_Launch_Orchestrator'];

        // Delete LLM configuration
        delete [SELECT Id FROM LLMConfiguration__c WHERE DeveloperName__c = 'OpenAI_GPT4_ProductLaunch'];

        // Delete campaign data
        List<Campaign> campaigns = [SELECT Id FROM Campaign WHERE Name LIKE '%AI Analytics Launch%' OR Name = :CAMPAIGN_NAME];
        if (!campaigns.isEmpty()) {
            delete [SELECT Id FROM CampaignMember WHERE CampaignId IN :campaigns];
            delete campaigns;
        }

        // Delete business data for demo accounts
        List<Account> accounts = [
            SELECT Id
            FROM Account
            WHERE
                Name IN (
                    'TechCorp Innovations',
                    'FinanceHub Solutions',
                    'RetailMart Enterprises',
                    'MegaCorp Global Industries',
                    'StartupCo Labs',
                    'EnterpriseGiant Corporation',
                    'HealthTech Systems'
                )
        ];

        if (!accounts.isEmpty()) {
            delete [SELECT Id FROM Task];
            delete [SELECT Id FROM Event];
            delete [SELECT Id FROM Case WHERE AccountId IN :accounts];
            delete [SELECT Id FROM Opportunity WHERE AccountId IN :accounts];
            delete [SELECT Id FROM Contact WHERE AccountId IN :accounts];
            delete accounts;
        }

        // Delete Chatter group
        delete [SELECT Id FROM CollaborationGroup WHERE Name = 'Product Launch Team'];

        // Delete product catalog
        delete [SELECT Id FROM PricebookEntry WHERE Product2.ProductCode = 'AI-ANALYTICS-PLATFORM-2026'];
        delete [SELECT Id FROM Product2 WHERE ProductCode = 'AI-ANALYTICS-PLATFORM-2026'];
    }

    // ===================================================================================
    // SAMPLE CASES (for Demo 1 - Case Summary Agent)
    // ===================================================================================

    private static void createSampleCases() {
        System.debug('[Cases] Creating sample cases...');

        List<Case> cases = new List<Case>{
            new Case(
                Subject = 'Demo Case: Production API Timeouts Affecting 200+ Users',
                Description = 'TechCorp experiencing intermittent API timeouts (15% failure rate) on /api/v2/analytics/query endpoint affecting 200+ users. ' +
                    'Started 3 days ago after v2.4 deployment. Marketing team blocked on $2M campaign decisions.\n\n' +
                    'TIMELINE:\nDay 1: Initial report, L1 troubleshooting\nDay 2: Escalated to engineering, logs collected\n' +
                    'Day 3: Root cause found - rate limiter timeout too aggressive (5s vs 15s). Fix ready for staging.\n\n' +
                    'NEXT STEPS:\n1. Staging deployment (today 2pm)\n2. Customer validation (Wed)\n3. Production deploy (Thu 6am)\n\n' +
                    'RISK: $120k contract renewal at risk. Customer evaluating Looker/Domo. CTO supportive but IT team frustrated.',
                Status = 'In Progress',
                Priority = 'High',
                Origin = 'Phone',
                Type = 'Problem',
                Reason = 'Performance'
            ),
            new Case(
                Subject = 'Demo Case: Password Reset Request',
                Description = 'User unable to login. Password reset email not received. Verified spam folder and email address correct.',
                Status = 'New',
                Priority = 'Medium',
                Origin = 'Email',
                Type = 'Question',
                Reason = 'User access'
            )
        };

        insert cases;
        idMap.put('Sample Case', cases[0].Id);
        idMap.put('Simple Case', cases[1].Id);

        // Add case comments
        insert new List<CaseComment>{
            new CaseComment(
                ParentId = cases[0].Id,
                CommentBody = '[Day 1] L1 troubleshooting complete. Issue intermittent, related to query complexity. Escalating to engineering.',
                IsPublished = true
            ),
            new CaseComment(
                ParentId = cases[0].Id,
                CommentBody = '[Day 2] Root cause: v2.4 rate limiter timeout reduced from 15s to 5s. Customer queries need 8-12s. Fix in progress.',
                IsPublished = true
            ),
            new CaseComment(
                ParentId = cases[0].Id,
                CommentBody = '[Day 3] CTO engaged. Staging validation scheduled Wed. Production deploy Thu 6am. Relationship stable.',
                IsPublished = true
            )
        };

        System.debug('[Cases] ✓ Sample cases created');
    }

    private static LLMConfiguration__c createLLMConfiguration() {
        System.debug('[LLM] Creating LLM configuration...');

        LLMConfiguration__c config = new LLMConfiguration__c(
            Name = 'OpenAI GPT-4 (Product Launch)',
            DeveloperName__c = 'OpenAI_GPT4_ProductLaunch',
            IsActive__c = true,
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-4o-mini',
            DefaultTemperature__c = 0.3 // Balanced creativity for content generation
        );
        insert config;

        idMap.put('LLM Config', config.Id);
        System.debug('[LLM] ✓ LLM configuration created');
        return config;
    }

    // ===================================================================================
    // PRODUCT CATALOG
    // ===================================================================================

    private static void createProductCatalog() {
        System.debug('[Products] Creating product catalog...');

        Product2 product = new Product2(
            Name = PRODUCT_NAME,
            ProductCode = 'AI-ANALYTICS-PLATFORM-2026',
            Description = 'AI-powered analytics platform with predictive insights, automated reporting, and ML-driven recommendations. Includes natural language querying, real-time dashboards, and 50+ pre-built industry templates. Perfect for mid-market to enterprise companies looking to democratize data access.',
            Family = 'Software',
            IsActive = true
        );
        insert product;

        idMap.put('Product', product.Id);

        // Get standard pricebook
        Id standardPricebookId = Test.isRunningTest() ? Test.getStandardPricebookId() : [SELECT Id FROM Pricebook2 WHERE IsStandard = TRUE LIMIT 1].Id;

        PricebookEntry entry = new PricebookEntry(
            Pricebook2Id = standardPricebookId,
            Product2Id = product.Id,
            UnitPrice = 50000, // $50k annual license
            IsActive = true,
            UseStandardPrice = false
        );
        insert entry;

        System.debug('[Products] ✓ Product catalog created: ' + PRODUCT_NAME);
    }

    // ===================================================================================
    // DEMO ACCOUNTS
    // ===================================================================================

    private static Map<String, Id> createDemoAccounts() {
        System.debug('[Accounts] Creating demo accounts...');

        // Create Chatter group for campaign insights
        CollaborationGroup campaignGroup = new CollaborationGroup(
            Name = 'Product Launch Team',
            CollaborationType = 'Public',
            Description = 'Team responsible for AI Analytics Platform product launch campaigns and strategy'
        );
        insert campaignGroup;
        idMap.put('Campaign Chatter Group', campaignGroup.Id);
        System.debug('[Accounts] ✓ Chatter group created: Product Launch Team');

        Map<String, Id> accountIds = new Map<String, Id>();

        List<Account> accounts = new List<Account>{
            // PERFECT FIT - High score, Hot engagement
            new Account(
                Name = 'TechCorp Innovations',
                Industry = 'Technology',
                Type = 'Prospect',
                BillingCountry = 'United States',
                BillingState = 'California',
                BillingCity = 'San Francisco',
                BillingStreet = '123 Innovation Drive',
                BillingPostalCode = '94105',
                Phone = '(415) 555-0100',
                Website = 'www.techcorp-innovations.com',
                AnnualRevenue = 25000000, // $25M
                NumberOfEmployees = 200,
                Description = 'Fast-growing B2B SaaS company specializing in developer tools. Currently using basic analytics (Google Analytics, Tableau) but struggling with data silos across 15+ systems. Engineering team of 80, Sales team of 40, Customer Success team of 30. Pain points: No unified view of product usage, customer health scoring is manual, reporting takes 10+ hours/week. Recent $15M Series B funding. CTO Sarah Chen is champion of data-driven culture. Active evaluation of analytics platforms (competitors: Looker, Domo). Strong buying signals: Downloaded 3 whitepapers, attended webinar last month, requested demo 2 weeks ago. Budget approved for Q1 2026. Decision timeline: 60 days. Perfect fit for AI Analytics Platform - need predictive churn models, automated dashboards, API integrations.'
            ),
            // GOOD FIT - High score, Warm engagement
            new Account(
                Name = 'FinanceHub Solutions',
                Industry = 'Financial Services',
                Type = 'Prospect',
                BillingCountry = 'United States',
                BillingState = 'New York',
                BillingCity = 'New York',
                BillingStreet = '456 Wall Street, Floor 20',
                BillingPostalCode = '10005',
                Phone = '(212) 555-0200',
                Website = 'www.financehub-solutions.com',
                AnnualRevenue = 45000000, // $45M
                NumberOfEmployees = 180,
                Description = 'Regional financial services firm providing wealth management and investment advisory. 180 employees: 60 advisors, 40 analysts, 30 operations, 50 support staff. Current analytics: Excel hell - 200+ spreadsheets, manual consolidation, version control nightmares. CFO Michael Torres wants to modernize reporting infrastructure. Pain points: Regulatory compliance reporting takes 40 hours/month, client portfolio analytics are outdated (T+3 day lag), risk assessment is reactive not predictive. Recent engagement: Had introductory call 6 weeks ago, positive feedback. Follow-up scheduled. Moderate buying signals: exploring options, budget discussions underway ($100k-150k range). Timeline: Q2 2026 decision. Compliance requirements mean longer sales cycle. Good fit - need audit trails, security, role-based dashboards. Concern: Data sensitivity (financial records) - need strong security story.'
            ),
            // MEDIUM FIT - Medium score, Warm engagement
            new Account(
                Name = 'RetailMart Enterprises',
                Industry = 'Retail',
                Type = 'Prospect',
                BillingCountry = 'United States',
                BillingState = 'Texas',
                BillingCity = 'Dallas',
                BillingStreet = '789 Commerce Boulevard',
                BillingPostalCode = '75201',
                Phone = '(214) 555-0300',
                Website = 'www.retailmart-ent.com',
                AnnualRevenue = 15000000, // $15M
                NumberOfEmployees = 85,
                Description = 'Regional retail chain with 25 stores across Texas and Oklahoma. 85 employees: 15 corporate (HQ), 70 store managers/staff. E-commerce growing rapidly (40% YoY). COO Jennifer Martinez wants better inventory and sales analytics. Current setup: Point-of-sale system with basic reports, no predictive analytics, manual inventory management. Pain points: Stockouts costing $50k/month, markdown optimization is guesswork, no customer segmentation. Moderate opportunity size. Some engagement: Received cold email 3 months ago, opened it, clicked link, visited pricing page. No direct contact yet. Medium buying intent - exploring but not urgent. Budget constraints: $30k-50k range (lower than typical). Timeline: Q3 2026 or later. Medium fit - retail industry use case exists but smaller company, may need scaled-down version. Challenge: Price sensitivity, may need discount.'
            ),
            // POOR FIT - Low score (too large), Cold engagement
            new Account(
                Name = 'MegaCorp Global Industries',
                Industry = 'Manufacturing',
                Type = 'Prospect',
                BillingCountry = 'United States',
                BillingState = 'Michigan',
                BillingCity = 'Detroit',
                BillingStreet = '1000 Industrial Parkway',
                BillingPostalCode = '48201',
                Phone = '(313) 555-0400',
                Website = 'www.megacorp-global.com',
                AnnualRevenue = 500000000, // $500M
                NumberOfEmployees = 5000,
                Description = 'Massive manufacturing conglomerate with global operations. 5,000 employees across 12 countries. Multiple divisions: Automotive parts, industrial equipment, consumer products. Enterprise IT infrastructure: SAP, Oracle, custom data warehouse, dedicated 20-person BI team. Poor fit reasons: (1) Too large - enterprise sales process requires 12+ month cycles, multiple stakeholders, RFP process. (2) Existing infrastructure - heavily invested in Oracle Analytics, unlikely to switch. (3) No engagement signals - no inbound interest, cold lead. (4) Wrong buyer profile - need enterprise sales team, not mid-market approach. Manufacturing industry is not core strength. Only included as negative example to test agent scoring logic - should score LOW and deprioritize or exclude from campaign.'
            ),
            // POOR FIT - Low score (too small), Cold engagement
            new Account(
                Name = 'StartupCo Labs',
                Industry = 'Technology',
                Type = 'Prospect',
                BillingCountry = 'United States',
                BillingState = 'California',
                BillingCity = 'Palo Alto',
                BillingStreet = '50 University Avenue, Suite 10',
                BillingPostalCode = '94301',
                Phone = '(650) 555-0500',
                Website = 'www.startupco-labs.com',
                AnnualRevenue = 500000, // $500k
                NumberOfEmployees = 8,
                Description = 'Early-stage startup (pre-seed) building mobile app for fitness tracking. 8 employees: 2 founders, 4 engineers, 1 designer, 1 marketer. Current analytics: Google Analytics, Mixpanel free tier. Poor fit reasons: (1) Too small - only 8 employees, minimal data infrastructure. (2) Early stage - no budget for $50k+ software ($5k-10k range max). (3) Limited data volume - 5,000 app users, simple analytics needs met by free tools. (4) No engagement - added to prospect list via conference attendee list, never engaged. (5) Wrong lifecycle stage - should target in 2-3 years when they hit 50+ employees and $5M+ revenue. Technology industry is good fit but size/stage is wrong. Agent should score LOW and exclude from campaign.'
            ),
            // PERFECT FIT - High score, Hot engagement, HIGH VALUE (HITL trigger)
            new Account(
                Name = 'EnterpriseGiant Corporation',
                Industry = 'Technology',
                Type = 'Prospect',
                BillingCountry = 'United States',
                BillingState = 'Washington',
                BillingCity = 'Seattle',
                BillingStreet = '2000 Enterprise Way',
                BillingPostalCode = '98101',
                Phone = '(206) 555-0600',
                Website = 'www.enterprisegiant.com',
                AnnualRevenue = 75000000, // $75M - HIGH VALUE (triggers HITL)
                NumberOfEmployees = 450,
                Description = 'Enterprise B2B software company (HR tech platform) with 450 employees and $75M ARR. Explosive growth: 100% YoY, recently IPO-ready, 150-person engineering org, 80-person sales team, 60-person CS team. VP of Data & Analytics Lisa Kumar is executive sponsor - huge champion, attended 2 demos, introduced us to CTO and CFO. Pain points: Current solution (Tableau + custom Python) can\'t scale, 5-person BI team overwhelmed with ad-hoc requests (100+ requests/month backlog), executive dashboards are manual (updated weekly, need real-time). Recent activity: Submitted 6-month evaluation plan, requested POC with 50 users, legal review of MSA started (buying signal!). Budget: $500k+ approved for analytics modernization. Decision timeline: 45 days (urgent - board metrics needed for IPO roadshow). PERFECT FIT: Large opportunity, hot engagement, strong champion, urgent timeline. HIGH VALUE: $75M revenue triggers executive approval requirement (HITL). Risk: Competitive deal - also evaluating Looker (Google), Domo. Need to move fast. This is THE strategic deal for Q1.'
            ),
            // GOOD FIT - High score, Warm engagement (alternative for demos)
            new Account(
                Name = 'HealthTech Systems',
                Industry = 'Healthcare',
                Type = 'Prospect',
                BillingCountry = 'United States',
                BillingState = 'Massachusetts',
                BillingCity = 'Boston',
                BillingStreet = '300 Medical Plaza',
                BillingPostalCode = '02115',
                Phone = '(617) 555-0700',
                Website = 'www.healthtech-systems.com',
                AnnualRevenue = 30000000, // $30M
                NumberOfEmployees = 150,
                Description = 'Healthcare SaaS company providing patient engagement platform to hospitals and clinics. 150 employees: 50 engineers, 30 sales, 25 customer success, 20 product, 25 ops. Director of Product Analytics Rachel Green is main contact. Pain points: Healthcare data complexity (HIPAA, PHI, multiple data sources), current analytics can\'t handle healthcare-specific workflows, reporting for hospital clients is manual (20 hours/week per CSM). Recent engagement: Downloaded healthcare analytics case study, attended healthcare industry webinar, 1 discovery call completed. Positive signals but moving slowly due to compliance review process. Budget: $80k-120k range, allocated for Q2 2026. Timeline: 90 days (healthcare sales cycles are long). Good fit: Healthcare is growth vertical, HIPAA compliance is supported, strong use case. Need: Industry-specific templates, audit logging, data governance features.'
            )
        };

        insert accounts;

        accountIds.put('TechCorp', accounts[0].Id);
        accountIds.put('FinanceHub', accounts[1].Id);
        accountIds.put('RetailMart', accounts[2].Id);
        accountIds.put('MegaCorp', accounts[3].Id);
        accountIds.put('StartupCo', accounts[4].Id);
        accountIds.put('EnterpriseGiant', accounts[5].Id);
        accountIds.put('HealthTech', accounts[6].Id);

        idMap.put('TechCorp Account', accounts[0].Id);
        idMap.put('FinanceHub Account', accounts[1].Id);
        idMap.put('RetailMart Account', accounts[2].Id);
        idMap.put('MegaCorp Account', accounts[3].Id);
        idMap.put('StartupCo Account', accounts[4].Id);
        idMap.put('EnterpriseGiant Account', accounts[5].Id);
        idMap.put('HealthTech Account', accounts[6].Id);

        System.debug('[Accounts] ✓ Demo accounts created (7 accounts with varying fit profiles)');
        return accountIds;
    }

    // ===================================================================================
    // CONTACTS
    // ===================================================================================

    private static void createContactsForAccounts(Map<String, Id> accountIds) {
        System.debug('[Contacts] Creating contacts...');

        List<Contact> contacts = new List<Contact>{
            // TechCorp Innovations (Hot lead)
            new Contact(
                FirstName = 'Sarah',
                LastName = 'Chen',
                Title = 'Chief Technology Officer',
                Email = 'sarah.chen@techcorp-innovations.com',
                Phone = '(415) 555-0101',
                AccountId = accountIds.get('TechCorp'),
                Description = 'Executive sponsor and champion. Data-driven culture advocate. Decision maker.',
                LeadSource = 'Web'
            ),
            new Contact(
                FirstName = 'Marcus',
                LastName = 'Rodriguez',
                Title = 'VP of Engineering',
                Email = 'marcus.rodriguez@techcorp-innovations.com',
                Phone = '(415) 555-0102',
                AccountId = accountIds.get('TechCorp'),
                Description = 'Technical evaluator. Owns data infrastructure. Influencer.',
                LeadSource = 'Web'
            ),
            // FinanceHub Solutions (Warm lead)
            new Contact(
                FirstName = 'Michael',
                LastName = 'Torres',
                Title = 'Chief Financial Officer',
                Email = 'michael.torres@financehub-solutions.com',
                Phone = '(212) 555-0201',
                AccountId = accountIds.get('FinanceHub'),
                Description = 'Budget owner. Interested in modernizing reporting. Decision maker.',
                LeadSource = 'Phone Inquiry'
            ),
            new Contact(
                FirstName = 'Emily',
                LastName = 'Watson',
                Title = 'Director of Business Intelligence',
                Email = 'emily.watson@financehub-solutions.com',
                Phone = '(212) 555-0202',
                AccountId = accountIds.get('FinanceHub'),
                Description = 'Technical lead for analytics. Current system pain point owner. Influencer.',
                LeadSource = 'Phone Inquiry'
            ),
            // RetailMart Enterprises (Warm lead)
            new Contact(
                FirstName = 'Jennifer',
                LastName = 'Martinez',
                Title = 'Chief Operations Officer',
                Email = 'jennifer.martinez@retailmart-ent.com',
                Phone = '(214) 555-0301',
                AccountId = accountIds.get('RetailMart'),
                Description = 'Operations lead. Interested in inventory optimization. Decision maker.',
                LeadSource = 'Web'
            ),
            // MegaCorp Global Industries (Cold lead - poor fit)
            new Contact(
                FirstName = 'Robert',
                LastName = 'Johnson',
                Title = 'Senior Manager, Business Intelligence',
                Email = 'robert.johnson@megacorp-global.com',
                Phone = '(313) 555-0401',
                AccountId = accountIds.get('MegaCorp'),
                Description = 'Mid-level contact. Not decision maker. Long sales cycle.',
                LeadSource = 'Purchased List'
            ),
            // StartupCo Labs (Cold lead - poor fit)
            new Contact(
                FirstName = 'Alex',
                LastName = 'Kim',
                Title = 'Co-Founder & CEO',
                Email = 'alex.kim@startupco-labs.com',
                Phone = '(650) 555-0501',
                AccountId = accountIds.get('StartupCo'),
                Description = 'Founder. Limited budget. Too early stage.',
                LeadSource = 'Event'
            ),
            // EnterpriseGiant Corporation (Hot lead - HIGH VALUE)
            new Contact(
                FirstName = 'Lisa',
                LastName = 'Kumar',
                Title = 'VP of Data & Analytics',
                Email = 'lisa.kumar@enterprisegiant.com',
                Phone = '(206) 555-0601',
                AccountId = accountIds.get('EnterpriseGiant'),
                Description = 'Executive sponsor. STRONG CHAMPION. Introduced us to C-suite. Decision maker.',
                LeadSource = 'Referral'
            ),
            new Contact(
                FirstName = 'James',
                LastName = 'Park',
                Title = 'Chief Technology Officer',
                Email = 'james.park@enterprisegiant.com',
                Phone = '(206) 555-0602',
                AccountId = accountIds.get('EnterpriseGiant'),
                Description = 'Technical executive. Supports analytics modernization. Decision maker.',
                LeadSource = 'Referral'
            ),
            new Contact(
                FirstName = 'Amanda',
                LastName = 'Foster',
                Title = 'Chief Financial Officer',
                Email = 'amanda.foster@enterprisegiant.com',
                Phone = '(206) 555-0603',
                AccountId = accountIds.get('EnterpriseGiant'),
                Description = 'Budget approver. IPO metrics focus. Economic buyer.',
                LeadSource = 'Referral'
            ),
            // HealthTech Systems (Warm lead)
            new Contact(
                FirstName = 'Rachel',
                LastName = 'Green',
                Title = 'Director of Product Analytics',
                Email = 'rachel.green@healthtech-systems.com',
                Phone = '(617) 555-0701',
                AccountId = accountIds.get('HealthTech'),
                Description = 'Product analytics lead. Healthcare data complexity expert. Influencer.',
                LeadSource = 'Web'
            )
        };

        insert contacts;

        System.debug('[Contacts] ✓ Contacts created (12 contacts across 7 accounts)');
    }

    // ===================================================================================
    // OPPORTUNITY HISTORY
    // ===================================================================================

    private static void createOpportunityHistory(Map<String, Id> accountIds) {
        System.debug('[Opportunities] Creating opportunity history...');

        Date today = Date.today();

        List<Opportunity> opportunities = new List<Opportunity>{
            // TechCorp - HOT: Recent opportunity in late stage
            new Opportunity(
                AccountId = accountIds.get('TechCorp'),
                Name = 'TechCorp Innovations - Analytics Platform Evaluation',
                StageName = 'Proposal/Price Quote',
                CloseDate = today.addDays(45),
                Amount = 120000,
                Probability = 70,
                Type = 'New Business',
                LeadSource = 'Web',
                Description = 'Inbound lead from demo request. Strong interest in predictive analytics and ML capabilities. Demo completed 2 weeks ago, received positive feedback. Awaiting proposal review. Champion: Sarah Chen (CTO). Budget approved. Timeline: 45 days. Competition: Looker. Next steps: Executive presentation next week.'
            ),
            // TechCorp - Historical: Previous evaluation (closed lost)
            new Opportunity(
                AccountId = accountIds.get('TechCorp'),
                Name = 'TechCorp Innovations - BI Tool Evaluation 2024',
                StageName = 'Closed Lost',
                CloseDate = today.addMonths(-8),
                Amount = 80000,
                Probability = 0,
                Type = 'New Business',
                LeadSource = 'Partner Referral',
                Description = 'Previous evaluation 8 months ago. Lost to Tableau. Reasons: Product didn\'t have AI/ML features at that time, pricing was higher. Re-engaged now with new AI Analytics Platform - perfect timing as their needs have evolved beyond Tableau capabilities.'
            ),
            // FinanceHub - WARM: Early stage opportunity
            new Opportunity(
                AccountId = accountIds.get('FinanceHub'),
                Name = 'FinanceHub Solutions - Reporting Modernization',
                StageName = 'Qualification',
                CloseDate = today.addDays(90),
                Amount = 150000,
                Probability = 30,
                Type = 'New Business',
                LeadSource = 'Phone Inquiry',
                Description = 'Discovery call completed 6 weeks ago. Identified pain points: manual Excel reporting, compliance overhead, slow analytics. Budget discussions underway ($100k-150k range). Longer sales cycle due to financial services compliance requirements. Next steps: Schedule technical demo with BI Director.'
            ),
            // RetailMart - WARM: Early exploration
            new Opportunity(
                AccountId = accountIds.get('RetailMart'),
                Name = 'RetailMart Enterprises - Inventory Analytics',
                StageName = 'Needs Analysis',
                CloseDate = today.addDays(120),
                Amount = 45000,
                Probability = 25,
                Type = 'New Business',
                LeadSource = 'Web',
                Description = 'Inbound inquiry from website pricing page visit. Interested in inventory optimization and markdown analytics. Smaller opportunity, budget constraints. COO Jennifer Martinez is main contact. Moving slowly, not urgent. Next steps: Initial discovery call to understand requirements.'
            ),
            // EnterpriseGiant - HOT: Large strategic deal in late stage
            new Opportunity(
                AccountId = accountIds.get('EnterpriseGiant'),
                Name = 'EnterpriseGiant Corporation - Analytics Modernization (STRATEGIC)',
                StageName = 'Negotiation/Review',
                CloseDate = today.addDays(45),
                Amount = 500000,
                Probability = 75,
                Type = 'New Business',
                LeadSource = 'Referral',
                Description = 'STRATEGIC DEAL - $500k first year, potential $1.5M over 3 years. Executive sponsor: Lisa Kumar (VP Data & Analytics) - strong champion. Multi-stakeholder: CTO, CFO both engaged. Use case: IPO-ready analytics, executive dashboards, scale from 5-person BI team to 50+ self-service users. POC in progress (50 users, 6-week evaluation). Legal review started (MSA). Timeline: 45 days (urgent for IPO roadshow). Competition: Looker, Domo. Competitive advantage: AI/ML features, healthcare vertical expertise. Risk: Price sensitivity, need executive approval for $500k+ deal. Next steps: Executive business review with CEO/CFO.'
            ),
            // EnterpriseGiant - Historical: Previous win (good relationship)
            new Opportunity(
                AccountId = accountIds.get('EnterpriseGiant'),
                Name = 'EnterpriseGiant Corporation - Data Integration Services',
                StageName = 'Closed Won',
                CloseDate = today.addMonths(-4),
                Amount = 75000,
                Probability = 100,
                Type = 'New Business',
                LeadSource = 'Referral',
                Description = 'Professional services engagement for data pipeline migration. Completed successfully 4 months ago. Strong relationship built, led to current analytics platform opportunity. Proof of successful partnership.'
            ),
            // HealthTech - WARM: Early stage opportunity
            new Opportunity(
                AccountId = accountIds.get('HealthTech'),
                Name = 'HealthTech Systems - Patient Analytics Platform',
                StageName = 'Qualification',
                CloseDate = today.addDays(90),
                Amount = 100000,
                Probability = 35,
                Type = 'New Business',
                LeadSource = 'Web',
                Description = 'Inbound from healthcare webinar. Discovery call completed. Healthcare-specific requirements: HIPAA compliance, PHI data handling, audit trails. Product analytics lead Rachel Green is champion. Moving slowly through compliance review. Budget allocated for Q2. Next steps: HIPAA compliance review, technical demo with healthcare templates.'
            ),
            // MegaCorp - COLD: Stale opportunity (no engagement)
            new Opportunity(
                AccountId = accountIds.get('MegaCorp'),
                Name = 'MegaCorp Global Industries - BI Evaluation',
                StageName = 'Prospecting',
                CloseDate = today.addDays(180),
                Amount = 0,
                Probability = 5,
                Type = 'New Business',
                LeadSource = 'Purchased List',
                Description = 'Cold outreach from purchased list. No response to 5 emails, 3 calls. Low priority - enterprise deal requires different approach. Poor fit: too large, existing Oracle infrastructure, no champion, no engagement. Should deprioritize.'
            )

            // StartupCo - NO OPPORTUNITIES (poor fit, no engagement)
        };

        insert opportunities;

        System.debug('[Opportunities] ✓ Opportunity history created (9 opportunities)');
        System.debug('[Opportunities]   - Hot leads: TechCorp (late stage), EnterpriseGiant (strategic)');
        System.debug('[Opportunities]   - Warm leads: FinanceHub, RetailMart, HealthTech (early stage)');
        System.debug('[Opportunities]   - Cold leads: MegaCorp (no engagement)');
    }

    // ===================================================================================
    // SUPPORT HISTORY (Cases as engagement proxy)
    // ===================================================================================

    private static void createSupportHistory(Map<String, Id> accountIds) {
        System.debug('[Support] Creating support case history...');

        Date today = Date.today();

        List<Case> cases = new List<Case>{
            // TechCorp - Positive engagement (pre-sales questions resolved quickly)
            new Case(
                AccountId = accountIds.get('TechCorp'),
                Subject = 'Pre-sales: API integration questions',
                Description = 'Technical questions about REST API capabilities and webhook support for their data pipeline. Answered same day with detailed documentation and code samples. Positive experience.',
                Status = 'Closed',
                Priority = 'Medium',
                Origin = 'Email',
                Type = 'Question',
                Reason = 'Pre-sales inquiry'
            ),
            new Case(
                AccountId = accountIds.get('TechCorp'),
                Subject = 'Demo request: ML prediction features',
                Description = 'Requested demo of machine learning prediction capabilities for churn modeling. Demo scheduled and completed successfully. Strong interest expressed.',
                Status = 'Closed',
                Priority = 'Medium',
                Origin = 'Web',
                Type = 'Question',
                Reason = 'Demo request'
            ),
            // FinanceHub - Moderate engagement (compliance questions)
            new Case(
                AccountId = accountIds.get('FinanceHub'),
                Subject = 'Security: SOC 2 and data encryption inquiry',
                Description = 'CFO requesting SOC 2 Type II report and details on data encryption (at rest and in transit). Provided compliance documentation and security whitepaper. Follow-up call scheduled.',
                Status = 'Closed',
                Priority = 'High',
                Origin = 'Phone',
                Type = 'Question',
                Reason = 'Compliance inquiry'
            ),
            // RetailMart - Minimal engagement (pricing question)
            new Case(
                AccountId = accountIds.get('RetailMart'),
                Subject = 'Pricing inquiry for 85 users',
                Description = 'Inquiry about pricing for 85-user deployment. Provided standard pricing sheet. No follow-up yet. Low engagement.',
                Status = 'Closed',
                Priority = 'Low',
                Origin = 'Web',
                Type = 'Question',
                Reason = 'Pricing inquiry'
            ),
            // EnterpriseGiant - High engagement (multiple touchpoints)
            new Case(
                AccountId = accountIds.get('EnterpriseGiant'),
                Subject = 'POC setup: 50-user evaluation environment',
                Description = 'Request to set up POC environment for 50 users across 3 departments. Provisioned in 24 hours. Training session scheduled for next week. High engagement, strategic opportunity.',
                Status = 'In Progress',
                Priority = 'High',
                Origin = 'Email',
                Type = 'Other',
                Reason = 'POC setup'
            ),
            new Case(
                AccountId = accountIds.get('EnterpriseGiant'),
                Subject = 'Technical: Custom SSO integration with Okta',
                Description = 'Need SSO integration with their Okta identity provider for POC. Technical resources engaged, integration guide provided. In progress.',
                Status = 'In Progress',
                Priority = 'High',
                Origin = 'Phone',
                Type = 'Technical',
                Reason = 'Integration setup'
            ),
            new Case(
                AccountId = accountIds.get('EnterpriseGiant'),
                Subject = 'Legal: MSA contract review and security questionnaire',
                Description = 'Legal team reviewing Master Services Agreement and 50+ question security questionnaire. Sales legal supporting. Positive signal - shows serious buying intent.',
                Status = 'In Progress',
                Priority = 'High',
                Origin = 'Email',
                Type = 'Other',
                Reason = 'Legal review'
            ),
            // HealthTech - Moderate engagement (compliance focus)
            new Case(
                AccountId = accountIds.get('HealthTech'),
                Subject = 'Compliance: HIPAA BAA and PHI handling',
                Description = 'Request for Business Associate Agreement (HIPAA) and documentation on PHI data handling procedures. Provided HIPAA compliance package. Compliance review in progress.',
                Status = 'Open',
                Priority = 'High',
                Origin = 'Email',
                Type = 'Question',
                Reason = 'HIPAA compliance'
            )

            // MegaCorp - NO CASES (cold, no engagement)
            // StartupCo - NO CASES (cold, no engagement)
        };

        insert cases;

        System.debug('[Support] ✓ Support case history created (8 cases)');
        System.debug('[Support]   - High engagement: EnterpriseGiant (3 active cases, POC in progress)');
        System.debug('[Support]   - Moderate engagement: TechCorp, FinanceHub, HealthTech');
        System.debug('[Support]   - Low engagement: RetailMart, MegaCorp, StartupCo');
    }

    // ===================================================================================
    // ACTIVITY HISTORY (Tasks & Events)
    // ===================================================================================

    private static void createActivityHistory(Map<String, Id> accountIds) {
        System.debug('[Activities] Creating activity history...');

        Date today = Date.today();
        Id currentUserId = UserInfo.getUserId();

        List<Task> tasks = new List<Task>();
        List<Event> events = new List<Event>();

        // TechCorp - High activity (hot lead)
        tasks.addAll(
            new List<Task>{
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('TechCorp') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('TechCorp'),
                    Subject = 'Email: Product demo invitation',
                    Status = 'Completed',
                    Priority = 'Normal',
                    ActivityDate = today.addDays(-14),
                    Description = 'Sent demo invitation email to Sarah Chen (CTO). Email opened 3 times, clicked demo link.',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('TechCorp') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('TechCorp'),
                    Subject = 'Call: Demo completed - positive feedback',
                    Status = 'Completed',
                    Priority = 'High',
                    ActivityDate = today.addDays(-7),
                    Description = 'Delivered product demo to Sarah Chen (CTO) and Marcus Rodriguez (VP Engineering). 45-minute call. Very positive feedback on ML features. Next step: proposal review.',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('TechCorp') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('TechCorp'),
                    Subject = 'Follow-up: Executive presentation scheduled',
                    Status = 'Completed',
                    Priority = 'High',
                    ActivityDate = today.addDays(-3),
                    Description = 'Follow-up call with Sarah Chen. Proposal received positively. Scheduled executive presentation for next week with CTO + CFO. Strong buying signals.',
                    OwnerId = currentUserId
                )
            }
        );

        events.add(
            new Event(
                WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('TechCorp') LIMIT 1]
                .Id,
                WhatId = accountIds.get('TechCorp'),
                Subject = 'Meeting: Executive Business Review',
                StartDateTime = DateTime.now().addDays(5),
                EndDateTime = DateTime.now().addDays(5).addHours(1),
                Description = 'Executive presentation with CTO, CFO, and VP Engineering. Present ROI analysis and implementation roadmap.',
                OwnerId = currentUserId
            )
        );

        // FinanceHub - Moderate activity (warm lead)
        tasks.addAll(
            new List<Task>{
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('FinanceHub') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('FinanceHub'),
                    Subject = 'Call: Discovery call completed',
                    Status = 'Completed',
                    Priority = 'Normal',
                    ActivityDate = today.addDays(-42),
                    Description = 'Discovery call with Michael Torres (CFO) and Emily Watson (BI Director). Identified pain points: Excel hell, compliance overhead. Budget allocated: $100k-150k.',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('FinanceHub') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('FinanceHub'),
                    Subject = 'Email: Compliance documentation sent',
                    Status = 'Completed',
                    Priority = 'Normal',
                    ActivityDate = today.addDays(-21),
                    Description = 'Sent SOC 2 Type II report and security whitepaper per CFO request. Email opened. Awaiting feedback.',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('FinanceHub') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('FinanceHub'),
                    Subject = 'Follow-up: Schedule technical demo',
                    Status = 'Not Started',
                    Priority = 'Normal',
                    ActivityDate = today.addDays(7),
                    Description = 'Follow up with Emily Watson to schedule technical demo. Compliance review should be complete by now.',
                    OwnerId = currentUserId
                )
            }
        );

        // RetailMart - Low activity (warm but slow)
        tasks.add(
            new Task(
                WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('RetailMart') LIMIT 1]
                .Id,
                WhatId = accountIds.get('RetailMart'),
                Subject = 'Email: Pricing information sent',
                Status = 'Completed',
                Priority = 'Low',
                ActivityDate = today.addDays(-60),
                Description = 'Sent pricing sheet per website inquiry. Email opened once. No response yet.',
                OwnerId = currentUserId
            )
        );

        // EnterpriseGiant - Very high activity (hot strategic deal)
        tasks.addAll(
            new List<Task>{
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('EnterpriseGiant') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('EnterpriseGiant'),
                    Subject = 'Call: Initial intro call with Lisa Kumar (VP Data)',
                    Status = 'Completed',
                    Priority = 'High',
                    ActivityDate = today.addDays(-60),
                    Description = 'Warm referral intro call. Lisa is strong champion, pain points clear: current solution can\'t scale, IPO readiness concern. Budget approved $500k+.',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('EnterpriseGiant') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('EnterpriseGiant'),
                    Subject = 'Call: Demo with Lisa + CTO James Park',
                    Status = 'Completed',
                    Priority = 'High',
                    ActivityDate = today.addDays(-45),
                    Description = 'Product demo with VP Data and CTO. Excellent feedback on AI/ML features. CTO approved POC evaluation (50 users, 6 weeks).',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('EnterpriseGiant') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('EnterpriseGiant'),
                    Subject = 'Meeting: CFO intro and budget discussion',
                    Status = 'Completed',
                    Priority = 'High',
                    ActivityDate = today.addDays(-30),
                    Description = 'Meeting with Amanda Foster (CFO) - economic buyer. Budget approved, need ROI analysis for board. IPO timeline driving urgency.',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('EnterpriseGiant') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('EnterpriseGiant'),
                    Subject = 'Technical: POC environment provisioned',
                    Status = 'Completed',
                    Priority = 'High',
                    ActivityDate = today.addDays(-14),
                    Description = 'POC environment set up for 50 users. Training session delivered to 3 departments. Users onboarded successfully.',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('EnterpriseGiant') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('EnterpriseGiant'),
                    Subject = 'Check-in: POC progress and feedback',
                    Status = 'Completed',
                    Priority = 'High',
                    ActivityDate = today.addDays(-7),
                    Description = 'POC check-in call with Lisa Kumar. Very positive feedback, users love natural language querying. Legal review started (MSA). Moving to negotiation stage.',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('EnterpriseGiant') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('EnterpriseGiant'),
                    Subject = 'Proposal: Final pricing and contract review',
                    Status = 'In Progress',
                    Priority = 'High',
                    ActivityDate = today.addDays(3),
                    Description = 'Final pricing proposal submitted: $500k Year 1, $1.5M over 3 years. Legal reviewing MSA. Timeline: 45 days to close. Need executive approval for high-value deal.',
                    OwnerId = currentUserId
                )
            }
        );

        events.add(
            new Event(
                WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('EnterpriseGiant') LIMIT 1]
                .Id,
                WhatId = accountIds.get('EnterpriseGiant'),
                Subject = 'Meeting: Executive Business Review (CEO/CFO/CTO)',
                StartDateTime = DateTime.now().addDays(7),
                EndDateTime = DateTime.now().addDays(7).addHours(1),
                Description = 'Executive business review with CEO, CFO, CTO. Present final proposal, ROI analysis, implementation timeline. Close date target: 45 days.',
                OwnerId = currentUserId
            )
        );

        // HealthTech - Moderate activity (warm but compliance delays)
        tasks.addAll(
            new List<Task>{
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('HealthTech') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('HealthTech'),
                    Subject = 'Call: Discovery call with Rachel Green',
                    Status = 'Completed',
                    Priority = 'Normal',
                    ActivityDate = today.addDays(-30),
                    Description = 'Discovery call with Director of Product Analytics. Healthcare-specific requirements identified: HIPAA, PHI data, audit trails. Budget allocated Q2.',
                    OwnerId = currentUserId
                ),
                new Task(
                    WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('HealthTech') LIMIT 1]
                    .Id,
                    WhatId = accountIds.get('HealthTech'),
                    Subject = 'Email: HIPAA compliance package sent',
                    Status = 'Completed',
                    Priority = 'High',
                    ActivityDate = today.addDays(-14),
                    Description = 'Sent HIPAA BAA and compliance documentation. Compliance review in progress (30-45 day process typical for healthcare).',
                    OwnerId = currentUserId
                )
            }
        );

        // MegaCorp - No activity (cold outreach, no response)
        tasks.add(
            new Task(
                WhoId = [SELECT Id FROM Contact WHERE AccountId = :accountIds.get('MegaCorp') LIMIT 1]
                .Id,
                WhatId = accountIds.get('MegaCorp'),
                Subject = 'Email: Cold outreach - no response',
                Status = 'Completed',
                Priority = 'Low',
                ActivityDate = today.addDays(-90),
                Description = 'Cold outreach email. No response after 5 emails, 3 calls. Poor fit - enterprise deal requires different approach.',
                OwnerId = currentUserId
            )
        );

        // StartupCo - No meaningful activity (poor fit)
        // No tasks/events created

        insert tasks;
        insert events;

        System.debug('[Activities] ✓ Activity history created (' + tasks.size() + ' tasks, ' + events.size() + ' events)');
        System.debug('[Activities]   - High activity: TechCorp (4 tasks, 1 event), EnterpriseGiant (6 tasks, 1 event)');
        System.debug('[Activities]   - Moderate activity: FinanceHub (3 tasks), HealthTech (2 tasks)');
        System.debug('[Activities]   - Low activity: RetailMart (1 task), MegaCorp (1 task)');
    }

    // ===================================================================================
    // AGENT CONFIGURATION - DEMO 1: CASE SUMMARY AGENT
    // ===================================================================================

    private static Id createCaseSummaryAgent(Id llmConfigId) {
        System.debug('[Demo 1] Creating Case Summary Agent...');

        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Case Summary Agent',
            DeveloperName__c = 'Case_Summary_Agent',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            ContextFormatStrategy__c = 'Structured Text',
            EnableParallelToolCalling__c = false,
            EnableToolReasoning__c = false,
            IdentityPrompt__c = 'You are a support case analyst providing concise summaries for managers.',
            InstructionsPrompt__c = 'Summarize cases with: Customer Issue, Current Status, Timeline, Next Steps, and Risk Assessment. ' +
                'Use bullet points. Highlight urgent items. Keep concise but informative.',
            PromptFooter__c = 'This is read-only analysis. Help managers quickly understand case status.'
        );
        insert agent;

        idMap.put('Demo1 Agent', agent.Id);

        // Create context provider for Case data
        createCaseSummaryContextConfig(agent.Id);

        System.debug('[Demo 1] ✓ Basic agent created (no capabilities, 1 context provider)');

        return agent.Id;
    }

    private static void createCaseSummaryContextConfig(Id agentId) {
        AgentContextConfig__c context = new AgentContextConfig__c(
            AIAgentDefinition__c = agentId,
            ContextLabel__c = 'Case Summary Data',
            ImplementationType__c = 'Apex',
            ImplementationName__c = 'CaseContext',
            ApplicableSObjectTypes__c = 'Case',
            RequiresRecordContext__c = true,
            ExecutionOrder__c = 10,
            IsActive__c = true
        );
        insert context;
        idMap.put('Demo1 Context', context.Id);
    }

    // ===================================================================================
    // AGENT CONFIGURATION - DEMO 2: ACCOUNT SCORING AGENT
    // ===================================================================================

    private static Id createAccountScoringAgent(Id llmConfigId) {
        System.debug('[Demo 2] Creating Account Scoring Agent...');

        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Account Fit Scoring Agent',
            DeveloperName__c = 'Account_Fit_Scoring_Agent',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            ContextFormatStrategy__c = 'Structured Text',
            EnableParallelToolCalling__c = false,
            EnableToolReasoning__c = true,
            IdentityPrompt__c = 'You help sales reps assess whether prospect accounts are a good fit for the AI Analytics Platform.',
            InstructionsPrompt__c = 'Use score_account_fit to calculate fit score (0-100). IMPORTANT: When the Flow returns a result, extract ONLY the score, fitLevel, and reasoning fields. ' +
                'Do NOT include Flow metadata, flowName, or other technical details in your response.\n\n' +
                'Format your final response as a clear markdown summary:\n\n' +
                '## Account Fit Analysis\n\n' +
                '**Overall Score:** [score]/100 ([fitLevel])\n\n' +
                '**Scoring Breakdown:**\n' +
                '[Use the reasoning field to explain key factors - industry, size, revenue]\n\n' +
                '**Recommendation:**\n' +
                '- 70-100: HIGH PRIORITY PROSPECT\n' +
                '- 50-69: Medium Priority\n' +
                '- 0-49: Low Priority\n\n' +
                '**Next Steps:**\n' +
                '[Provide actionable recommendations based on the score]\n\n' +
                'CRITICAL: Your response must be ONLY the formatted summary. Never include raw FlowResult, metadata, or technical details.',
            PromptFooter__c = 'Account data is pre-loaded. Call score_account_fit, extract the result fields (score, fitLevel, reasoning), and format a clear business summary.'
        );
        insert agent;

        idMap.put('Demo2 Agent', agent.Id);

        createAccountScoringCapability(agent.Id);
        createAccountScoringContextConfig(agent.Id);

        System.debug('[Demo 2] ✓ Single-capability agent created');

        return agent.Id;
    }

    private static void createAccountScoringCapability(Id agentId) {
        AgentCapability__c capability = new AgentCapability__c(
            AIAgentDefinition__c = agentId,
            CapabilityName__c = 'score_account_fit',
            Description__c = 'Scores Account fit for AI Analytics Platform (0-100).\n\n' +
                '**Optimal Fit Criteria:**\n' +
                '- Industry: Technology (highest fit)\n' +
                '- Company Size: 50-500 employees (mid-market sweet spot)\n' +
                '- Annual Revenue: $10M-$100M\n\n' +
                '**Score Ranges:**\n' +
                '- 70-100: High priority prospect\n' +
                '- 50-69: Medium priority\n' +
                '- 0-49: Low priority (exclude from campaign)',
            ImplementationType__c = 'Flow',
            ImplementationDetail__c = 'Score_Account_Fit',
            Parameters__c = JSON.serialize(
                new Map<String, Object>{
                    'type' => 'object',
                    'required' => new List<String>{ 'accountId', 'industry', 'employeeCount', 'annualRevenue' },
                    'properties' => new Map<String, Object>{
                        'accountId' => new Map<String, Object>{
                            'type' => 'string',
                            'format' => 'salesforce-id',
                            'description' => '18-character Account ID to score for product fit'
                        },
                        'industry' => new Map<String, Object>{
                            'type' => 'string',
                            'description' => 'Account industry from context. Technology/Software scores highest (40 pts), Finance/Healthcare medium (25 pts), others low (10 pts)'
                        },
                        'employeeCount' => new Map<String, Object>{
                            'type' => 'integer',
                            'minimum' => 0,
                            'description' => 'Number of employees from context. 50-500 is optimal (30 pts), outside range scores lower (5-15 pts)'
                        },
                        'annualRevenue' => new Map<String, Object>{
                            'type' => 'number',
                            'minimum' => 0,
                            'description' => 'Annual revenue from context in dollars. $10M-$100M is optimal (30 pts), outside range scores lower (5-15 pts)'
                        }
                    }
                },
                true
            ),
            RunAsynchronously__c = false,
            ExposureLevel__c = 'External'
        );
        insert capability;
        idMap.put('Demo2 Capability', capability.Id);
    }

    private static void createAccountScoringContextConfig(Id agentId) {
        AgentContextConfig__c context = new AgentContextConfig__c(
            AIAgentDefinition__c = agentId,
            ContextLabel__c = 'Account Profile',
            ImplementationType__c = 'Apex',
            ImplementationName__c = 'AccountProductFitContext',
            ApplicableSObjectTypes__c = 'Account',
            RequiresRecordContext__c = true,
            ExecutionOrder__c = 10,
            IsActive__c = true
        );
        insert context;
        idMap.put('Demo2 Context', context.Id);
    }

    // ===================================================================================
    // AGENT CONFIGURATION - DEMO 3: PRODUCT LAUNCH ORCHESTRATOR
    // ===================================================================================

    private static Id createProductLaunchAgent(Id llmConfigId) {
        System.debug('[Demo 3] Creating Product Launch Orchestrator...');

        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Product Launch Orchestrator',
            DeveloperName__c = 'Product_Launch_Orchestrator',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            ContextFormatStrategy__c = 'Structured Text',
            EnableParallelToolCalling__c = true,
            EnableToolReasoning__c = true,
            IdentityPrompt__c = 'You are a B2B marketing orchestrator specializing in product launches. ' +
                'Analyze prospect fit, engagement signals, and buying intent to create targeted campaigns.',
            InstructionsPrompt__c = 'You are building a targeted ABM campaign. Use AI intelligence to qualify prospects, personalize messaging, and make smart approval decisions.\n\n' +
                'Workflow:\n' +
                '1. Qualify each account: score_account_fit + analyze_engagement_signals (parallel). Include score ≥50, exclude <50.\n' +
                '2. Generate personalized messages for qualified accounts (parallel). Reference specific pain points and context.\n' +
                '3. Create campaign with all qualified accounts (sequential).\n' +
                '4. Assign follow-up tasks (sequential). Accounts with revenue over $50M require approval.\n' +
                '   - If APPROVED: Proceed to step 5\n' +
                '   - If REJECTED: Call create_escalation_case and STOP (do not log insights)\n' +
                '5. Log insights to team (sequential). Only if all tasks were successfully assigned.\n\n' +
                'Key rules: Steps 3-5 sequential. One tool call per account (no duplicates). Make data-driven decisions.',
            PromptFooter__c = 'All prospect data is pre-loaded. Make data-driven decisions and showcase AI intelligence.'
        );
        insert agent;

        idMap.put('Demo3 Agent', agent.Id);

        createAgentCapabilities(agent.Id);
        createAgentContextConfig(agent.Id);

        System.debug('[Demo 3] ✓ Multi-capability orchestrator created (7 capabilities)');

        return agent.Id;
    }

    private static void createAgentCapabilities(Id agentId) {
        System.debug('[Capabilities] Creating agent capabilities...');

        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            // CAPABILITY 1: Score Account Fit (Flow)
            new AgentCapability__c(
                AIAgentDefinition__c = agentId,
                CapabilityName__c = 'score_account_fit',
                Description__c = 'Scores an Account\'s fit for the AI Analytics Platform product based on industry match, company size (50-500 employees ideal), and revenue potential. Returns score 0-100 where 70+ is high priority, 50-69 is medium priority, and <50 should be excluded from campaign. Technology industry scores highest, mid-market size is optimal.',
                ImplementationType__c = 'Flow',
                ImplementationDetail__c = 'Score_Account_Fit',
                Parameters__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'object',
                        'required' => new List<String>{ 'accountId', 'industry', 'employeeCount', 'annualRevenue' },
                        'properties' => new Map<String, Object>{
                            'accountId' => new Map<String, Object>{
                                'type' => 'string',
                                'format' => 'salesforce-id',
                                'description' => '18-character Account ID'
                            },
                            'industry' => new Map<String, Object>{ 'type' => 'string', 'description' => 'Account industry from context' },
                            'employeeCount' => new Map<String, Object>{
                                'type' => 'integer',
                                'description' => 'Number of employees from context',
                                'minimum' => 0
                            },
                            'annualRevenue' => new Map<String, Object>{ 'type' => 'number', 'description' => 'Annual revenue from context', 'minimum' => 0 }
                        }
                    },
                    true
                ),
                RunAsynchronously__c = false,
                ExposureLevel__c = 'External'
            ),
            // CAPABILITY 2: Analyze Engagement Signals (Apex)
            new AgentCapability__c(
                AIAgentDefinition__c = agentId,
                CapabilityName__c = 'analyze_engagement_signals',
                Description__c = 'Analyzes Account engagement level by examining recent Opportunities (stage, amount, close date), Support Cases (indicates product interest), and Activity history (calls, emails, meetings). Returns engagement level: "Hot" (late-stage opportunity or high activity), "Warm" (early opportunity or moderate activity), or "Cold" (no meaningful engagement). Includes reasoning with specific data points.',
                ImplementationType__c = 'Apex',
                ImplementationDetail__c = 'ActionAnalyzeEngagement',
                Parameters__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'object',
                        'required' => new List<String>{ 'accountId' },
                        'properties' => new Map<String, Object>{
                            'accountId' => new Map<String, Object>{
                                'type' => 'string',
                                'format' => 'salesforce-id',
                                'description' => '18-character Account ID from context'
                            },
                            'opportunityStageName' => new Map<String, Object>{
                                'type' => 'string',
                                'description' => 'Current opportunity stage if exists (from context)'
                            },
                            'opportunityAmount' => new Map<String, Object>{
                                'type' => 'number',
                                'description' => 'Current opportunity amount if exists',
                                'minimum' => 0
                            },
                            'recentCaseCount' => new Map<String, Object>{
                                'type' => 'integer',
                                'description' => 'Number of cases in last 90 days (from context)',
                                'default' => 0
                            },
                            'recentActivityCount' => new Map<String, Object>{
                                'type' => 'integer',
                                'description' => 'Number of activities in last 90 days (from context)',
                                'default' => 0
                            }
                        }
                    },
                    true
                ),
                BackendConfiguration__c = JSON.serialize(
                    new Map<String, Object>{
                        'operation' => 'ANALYZE_ENGAGEMENT',
                        'hotThreshold' => new Map<String, Object>{
                            'opportunityStages' => new List<String>{ 'Proposal/Price Quote', 'Negotiation/Review' },
                            'minActivityCount' => 5
                        },
                        'warmThreshold' => new Map<String, Object>{
                            'opportunityStages' => new List<String>{ 'Qualification', 'Needs Analysis' },
                            'minActivityCount' => 2
                        }
                    },
                    true
                ),
                RunAsynchronously__c = false,
                ExposureLevel__c = 'External'
            ),
            // CAPABILITY 3: Generate Campaign Message (Apex with AI)
            new AgentCapability__c(
                AIAgentDefinition__c = agentId,
                CapabilityName__c = 'generate_campaign_message',
                Description__c = 'Generates ONE personalized email per account. Call ONCE per qualified account (score ≥50), NOT once per contact. The email should reference all key contacts (e.g., "Hi Lisa, James, and Amanda") in a single cohesive message. Do NOT make multiple calls for the same accountId with different contactName values.',
                ImplementationType__c = 'Apex',
                ImplementationDetail__c = 'ActionGenerateCampaignMessage',
                Parameters__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'object',
                        'required' => new List<String>{ 'accountId', 'accountName', 'industry', 'painPoints' },
                        'properties' => new Map<String, Object>{
                            'accountId' => new Map<String, Object>{
                                'type' => 'string',
                                'format' => 'salesforce-id',
                                'description' => '18-character Account ID'
                            },
                            'accountName' => new Map<String, Object>{ 'type' => 'string', 'description' => 'Account name for personalization' },
                            'industry' => new Map<String, Object>{ 'type' => 'string', 'description' => 'Account industry from context' },
                            'painPoints' => new Map<String, Object>{
                                'type' => 'string',
                                'description' => 'Key pain points identified from account description, opportunities, or cases. Be specific and reference actual context.'
                            },
                            'recentOpportunity' => new Map<String, Object>{
                                'type' => 'string',
                                'description' => 'Recent opportunity name/context if exists (adds relevance)'
                            },
                            'contactNames' => new Map<String, Object>{
                                'type' => 'string',
                                'description' => 'Comma-separated list of key contact names (e.g., "Lisa Kumar, James Park, Amanda Foster"). Will be used to create greeting like "Hi Lisa, James, and Amanda".'
                            }
                        }
                    },
                    true
                ),
                BackendConfiguration__c = JSON.serialize(
                    new Map<String, Object>{
                        'operation' => 'GENERATE_MESSAGE',
                        'productName' => PRODUCT_NAME,
                        'messageStyle' => 'professional-consultative',
                        'maxLength' => 500
                    },
                    true
                ),
                RunAsynchronously__c = false,
                ExposureLevel__c = 'External'
            ),
            // CAPABILITY 4: Create Campaign with Members (Flow)
            new AgentCapability__c(
                AIAgentDefinition__c = agentId,
                CapabilityName__c = 'create_campaign_with_members',
                Description__c = 'Creates ONE Campaign record with all qualified accounts as members. Call AFTER all messages are generated. Sets CampaignMember status based on engagement (Hot=Sent, Warm=Planned). Include accounts with score ≥50. WAIT for this to complete before assigning tasks.',
                ImplementationType__c = 'Flow',
                ImplementationDetail__c = 'Create_Campaign_With_Members',
                Parameters__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'object',
                        'required' => new List<String>{ 'campaignName', 'accountIds' },
                        'properties' => new Map<String, Object>{
                            'campaignName' => new Map<String, Object>{
                                'type' => 'string',
                                'description' => 'Campaign name - use format "Q1 2026 AI Analytics Launch - [Segment]"',
                                'default' => CAMPAIGN_NAME
                            },
                            'accountIds' => new Map<String, Object>{
                                'type' => 'array',
                                'description' => 'Array of Account IDs with score >= 70',
                                'items' => new Map<String, Object>{ 'type' => 'string', 'format' => 'salesforce-id' },
                                'minItems' => 1
                            },
                            'description' => new Map<String, Object>{
                                'type' => 'string',
                                'description' => 'Campaign description including target criteria and goals'
                            }
                        }
                    },
                    true
                ),
                RunAsynchronously__c = false,
                ExposureLevel__c = 'External'
            ),
            // CAPABILITY 5: Assign Sales Tasks (Standard CreateRecord with LLM-Driven Conditional HITL)
            new AgentCapability__c(
                AIAgentDefinition__c = agentId,
                CapabilityName__c = 'assign_sales_tasks',
                Description__c = 'Creates ONE follow-up Task per qualified account. Call AFTER campaign is created. Task includes account context, engagement level, and next steps. REQUIRES APPROVAL if Account.AnnualRevenue > $50M (enterprise accounts require executive review). If rejected, call create_escalation_case instead. WAIT for all tasks to complete before logging insights.',
                ImplementationType__c = 'Standard',
                StandardActionType__c = 'CreateRecord',
                Parameters__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'object',
                        'required' => new List<String>{ 'recordData' },
                        'properties' => new Map<String, Object>{
                            'recordData' => new Map<String, Object>{
                                'type' => 'object',
                                'required' => new List<String>{ 'Subject', 'WhatId', 'ActivityDate', 'Description' },
                                'properties' => new Map<String, Object>{
                                    'Subject' => new Map<String, Object>{
                                        'type' => 'string',
                                        'description' => 'Format: "Follow-up: [Account Name] - [Product] Launch"'
                                    },
                                    'WhatId' => new Map<String, Object>{
                                        'type' => 'string',
                                        'format' => 'salesforce-id',
                                        'description' => 'Account ID',
                                        'pattern' => '^001[a-zA-Z0-9]{15}$'
                                    },
                                    'ActivityDate' => new Map<String, Object>{
                                        'type' => 'string',
                                        'format' => 'date',
                                        'description' => 'Task due date (YYYY-MM-DD). Hot leads: 3 days, Warm leads: 7 days'
                                    },
                                    'Description' => new Map<String, Object>{
                                        'type' => 'string',
                                        'description' => 'Personalized task description with account context, engagement level, recommended action, and key talking points from generated message'
                                    },
                                    'Priority' => new Map<String, Object>{
                                        'type' => 'string',
                                        'enum' => new List<String>{ 'High', 'Normal', 'Low' },
                                        'description' => 'Hot leads: High, Warm leads: Normal',
                                        'default' => 'Normal'
                                    }
                                }
                            }
                        }
                    },
                    true
                ),
                BackendConfiguration__c = JSON.serialize(
                    new Map<String, Object>{
                        'objectApiName' => 'Task',
                        'defaultFieldValues' => new Map<String, Object>{ 'Status' => 'Not Started', 'OwnerId' => UserInfo.getUserId() }
                    },
                    true
                ),
                HITLMode__c = 'ConditionalApproval', // LLM decides based on approval rules in description
                RunAsynchronously__c = false,
                ExposureLevel__c = 'External'
            ),
            // CAPABILITY 6: Log Campaign Insights (Standard PostChatter)
            new AgentCapability__c(
                AIAgentDefinition__c = agentId,
                CapabilityName__c = 'log_campaign_insights',
                Description__c = 'Posts ONE campaign summary to Product Launch Team Chatter. Call AFTER all tasks are assigned. Include: campaign name, target accounts with scores/engagement, messaging approach, expected outcomes. Max 300 words, markdown format.',
                ImplementationType__c = 'Standard',
                StandardActionType__c = 'PostChatter',
                Parameters__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'object',
                        'required' => new List<String>{ 'messageText' },
                        'properties' => new Map<String, Object>{
                            'messageText' => new Map<String, Object>{
                                'type' => 'string',
                                'description' => 'Campaign insights summary in markdown format. Include: campaign name, target accounts (with scores), engagement analysis, messaging strategy, expected outcomes. Max 300 words.'
                            },
                            'topics' => new Map<String, Object>{
                                'type' => 'array',
                                'description' => 'Optional hashtags for categorization (e.g., ["Q1Launch", "Technology", "HighPriority"])',
                                'items' => new Map<String, Object>{ 'type' => 'string' }
                            }
                        }
                    },
                    true
                ),
                BackendConfiguration__c = JSON.serialize(new Map<String, Object>{ 'feedType' => 'Group', 'targetId' => idMap.get('Campaign Chatter Group') }),
                RunAsynchronously__c = false,
                ExposureLevel__c = 'External'
            ),
            // CAPABILITY 7: Create Escalation Case (Standard CreateRecord - for HITL rejection path)
            new AgentCapability__c(
                AIAgentDefinition__c = agentId,
                CapabilityName__c = 'create_escalation_case',
                Description__c = 'Creates a Case record for executive/VP escalation when a high-value deal requires management review. ' +
                    'Use this ONLY when HITL approval is rejected for assign_sales_tasks. ' +
                    'This demonstrates adaptive intelligence - switching from task creation to executive escalation workflow.\n\n' +
                    'Include in Case description:\n' +
                    '- Deal value and strategic importance\n' +
                    '- Rejection reason from approver\n' +
                    '- Account context (revenue, engagement, timeline)\n' +
                    '- Recommended action (e.g., "Schedule executive business review with CTO and CFO")\n' +
                    '- Competitive risks if any',
                ImplementationType__c = 'Standard',
                StandardActionType__c = 'CreateRecord',
                Parameters__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'object',
                        'required' => new List<String>{ 'recordData' },
                        'properties' => new Map<String, Object>{
                            'recordData' => new Map<String, Object>{
                                'type' => 'object',
                                'required' => new List<String>{ 'Subject', 'AccountId', 'Description' },
                                'properties' => new Map<String, Object>{
                                    'Subject' => new Map<String, Object>{
                                        'type' => 'string',
                                        'description' => 'Format: "Executive Review Required: [Account Name] - $[Deal Size] Opportunity"'
                                    },
                                    'AccountId' => new Map<String, Object>{
                                        'type' => 'string',
                                        'format' => 'salesforce-id',
                                        'description' => 'Account ID that requires escalation',
                                        'pattern' => '^001[a-zA-Z0-9]{15}$'
                                    },
                                    'Description' => new Map<String, Object>{
                                        'type' => 'string',
                                        'description' => 'Detailed context: deal value, rejection reason, account background (revenue, engagement signals), recommended VP action, competitive urgency. Be specific and professional.'
                                    },
                                    'Priority' => new Map<String, Object>{
                                        'type' => 'string',
                                        'enum' => new List<String>{ 'High', 'Medium', 'Low' },
                                        'description' => 'Use High for enterprise accounts',
                                        'default' => 'High'
                                    }
                                }
                            }
                        }
                    },
                    true
                ),
                BackendConfiguration__c = JSON.serialize(
                    new Map<String, Object>{
                        'objectApiName' => 'Case',
                        'defaultFieldValues' => new Map<String, Object>{
                            'Status' => 'New',
                            'Type' => 'Other',
                            'Origin' => 'Web',
                            'OwnerId' => UserInfo.getUserId() // In real scenario, would be VP/Manager queue
                        }
                    },
                    true
                ),
                RunAsynchronously__c = false,
                ExposureLevel__c = 'External'
            )
        };

        insert capabilities;

        idMap.put('Capability Score', capabilities[0].Id);
        idMap.put('Capability Engagement', capabilities[1].Id);
        idMap.put('Capability Message', capabilities[2].Id);
        idMap.put('Capability Campaign', capabilities[3].Id);
        idMap.put('Capability Tasks', capabilities[4].Id);
        idMap.put('Capability Insights', capabilities[5].Id);
        idMap.put('Capability Escalation', capabilities[6].Id);

        System.debug('[Capabilities] ✓ 7 capabilities created (2 Apex + 2 Flow + 3 Standard)');
        System.debug('[Capabilities]   - HITL enabled for assign_sales_tasks (high-value accounts)');
        System.debug('[Capabilities]   - Escalation path via create_escalation_case (rejection handling)');
    }

    private static void createAgentContextConfig(Id agentId) {
        System.debug('[Context] Creating context providers...');

        List<AgentContextConfig__c> contexts = new List<AgentContextConfig__c>{
            new AgentContextConfig__c(
                AIAgentDefinition__c = agentId,
                ContextLabel__c = 'Account Profile & Product Fit',
                ImplementationType__c = 'Apex',
                ImplementationName__c = 'AccountProductFitContext',
                ApplicableSObjectTypes__c = 'Account',
                RequiresRecordContext__c = true,
                ExecutionOrder__c = 10,
                IsActive__c = true
            ),
            new AgentContextConfig__c(
                AIAgentDefinition__c = agentId,
                ContextLabel__c = 'Opportunity & Pipeline',
                ImplementationType__c = 'Apex',
                ImplementationName__c = 'OpportunityEngagementContext',
                ApplicableSObjectTypes__c = 'Account',
                RequiresRecordContext__c = true,
                ExecutionOrder__c = 20,
                IsActive__c = true
            ),
            new AgentContextConfig__c(
                AIAgentDefinition__c = agentId,
                ContextLabel__c = 'Support & Engagement History',
                ImplementationType__c = 'Apex',
                ImplementationName__c = 'SupportEngagementContext',
                ApplicableSObjectTypes__c = 'Account',
                RequiresRecordContext__c = true,
                ExecutionOrder__c = 30,
                IsActive__c = true
            ),
            new AgentContextConfig__c(
                AIAgentDefinition__c = agentId,
                ContextLabel__c = 'Activity Timeline',
                ImplementationType__c = 'Apex',
                ImplementationName__c = 'ActivityTimelineContext',
                ApplicableSObjectTypes__c = 'Account',
                RequiresRecordContext__c = true,
                ExecutionOrder__c = 40,
                IsActive__c = true
            )
        };

        insert contexts;

        System.debug('[Context] ✓ 4 context providers created');
        System.debug('[Context]   Eliminates need for data-gathering capabilities!');
    }
}
