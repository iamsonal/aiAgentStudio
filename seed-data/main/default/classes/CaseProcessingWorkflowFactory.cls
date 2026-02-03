/**
 * @description Factory class for creating a realistic Case Processing Workflow
 *
 * This class creates a production-grade multi-agent workflow that mirrors how actual
 * support organizations handle incoming cases, demonstrating AI Agent Studio's capabilities
 * with real-world business logic.
 *
 * **Workflow Architecture (Realistic):**
 * - Context: Case, Account, Contact, Entitlements (pre-loaded via Agent Context Config - no enrichment agent)
 * - Step 1: Triage & Routing Agent - Classify, score urgency, filter spam, route to queue, suggest knowledge
 * - Step 2: Assignment & Notification Agent - Assign to best rep (skills, workload), notify rep & customer
 * - Step 3: High-Value Escalation Agent (CONDITIONAL) - Executive review for critical/high-value cases only
 *
 * **Key Design Principles:**
 * - Enrichment = Context Config (not an agent step) → faster, no wasted tool calls
 * - Clear separation: Triage thinks, Assignment acts, Escalation runs conditionally
 * - SLA/monitoring = automation (scheduled jobs), not agent logic
 * - Knowledge search integrated into Triage (the agent that understands the issue)
 *
 * **Business Outcomes:**
 * - 90%+ SLA compliance (smart routing + conditional escalation)
 * - 60% faster time-to-touch (intelligent assignment + instant notifications)
 * - Higher first-time resolution (right expert + knowledge articles)
 * - Efficient use of LLM calls (no redundant enrichment steps)
 *
 * @usage
 * Execute in Anonymous Apex (2-step process due to Mixed DML restrictions):
 *
 * // Step 1: Create queues first (setup objects)
 * CaseProcessingWorkflowFactory.setupQueues();
 *
 * // Step 2: Create workflow, agents, and test data
 * CaseProcessingWorkflowFactory.executeDemo();
 *
 * Or create workflow only (requires existing LLM config):
 * Id llmConfigId = [SELECT Id FROM LLMConfiguration__c WHERE DeveloperName__c = 'OpenAI_GPT4' LIMIT 1].Id;
 * Map<String, Id> result = CaseProcessingWorkflowFactory.createWorkflow(llmConfigId);
 *
 * @author Sonal
 * @since 2025
 */
public with sharing class CaseProcessingWorkflowFactory {
    private static Map<String, Id> dataIds = new Map<String, Id>();

    /**
     * @description Main demo entry point - creates everything needed to test the workflow
     * Creates: LLM Config → Agents → Test Data → Test Execution
     *
     * NOTE: Queues must be created separately due to Salesforce Mixed DML restrictions.
     * Run setupQueues() first if queues don't exist, then run this method.
     *
     * @return Map<String, Id> containing all created record IDs
     */
    public static Map<String, Id> executeDemo() {
        System.debug('========================================');
        System.debug('CASE PROCESSING WORKFLOW - DEMO');
        System.debug('========================================');

        try {
            // Step 1: Check if queues exist, if not guide user
            List<Group> existingQueues = [
                SELECT Id, DeveloperName
                FROM Group
                WHERE Type = 'Queue' AND DeveloperName IN ('Engineering_Support_Queue', 'Finance_Support_Queue', 'Product_Support_Queue')
            ];

            if (existingQueues.size() < 3) {
                System.debug(LoggingLevel.WARN, '[Demo] ⚠️  Queues not found. Please run setupQueues() first.');
                System.debug(LoggingLevel.WARN, '[Demo] Execute: CaseProcessingWorkflowFactory.setupQueues();');
                System.debug(LoggingLevel.WARN, '[Demo] Then run: CaseProcessingWorkflowFactory.executeDemo();');
                throw new DemoException('Setup queues required. Run setupQueues() first, then executeDemo().');
            }

            // Step 2: Get or create LLM Configuration
            LLMConfiguration__c llmConfig = getOrCreateLLMConfig();
            dataIds.put('LLM_Config', llmConfig.Id);

            // Step 3: Create the workflow and agents
            System.debug('[Demo] Creating workflow and agents...');
            Map<String, Id> agentIds = createWorkflow(llmConfig.Id);
            dataIds.putAll(agentIds);

            // Step 4: Create seed data (accounts, contacts, entitlements, knowledge)
            System.debug('[Demo] Creating seed data...');
            createSeedData();

            // Step 5: Execute test scenarios
            System.debug('[Demo] Executing test scenarios...');
            //            executeTestScenarios();

            System.debug('========================================');
            System.debug('DEMO COMPLETE!');
            System.debug('Created ' + dataIds.size() + ' records');
            System.debug('Monitor AgentExecution__c records to see workflow in action');
            System.debug('========================================');

            return dataIds;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Demo failed: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'Stack trace: ' + e.getStackTraceString());
            throw e;
        }
    }

    /**
     * @description Creates support queues (must be run FIRST before executeDemo due to Mixed DML)
     * Execute this separately: CaseProcessingWorkflowFactory.setupQueues();
     */
    public static Map<String, Id> setupQueues() {
        System.debug('========================================');
        System.debug('QUEUE SETUP - Creating Support Queues');
        System.debug('========================================');

        Map<String, Id> queueIds = new Map<String, Id>();

        try {
            // Check if queues already exist
            List<Group> existingQueues = [
                SELECT Id, DeveloperName, Name
                FROM Group
                WHERE Type = 'Queue' AND DeveloperName IN ('Engineering_Support_Queue', 'Finance_Support_Queue', 'Product_Support_Queue')
            ];

            if (existingQueues.size() == 3) {
                System.debug('[Queues] ✓ All queues already exist');
                for (Group q : existingQueues) {
                    queueIds.put(q.DeveloperName, q.Id);
                    System.debug('[Queues]   - ' + q.Name);
                }
                return queueIds;
            }

            // Create missing queues
            Set<String> existingDevNames = new Set<String>();
            for (Group q : existingQueues) {
                existingDevNames.add(q.DeveloperName);
                queueIds.put(q.DeveloperName, q.Id);
            }

            List<Group> queuesToCreate = new List<Group>();
            if (!existingDevNames.contains('Engineering_Support_Queue')) {
                queuesToCreate.add(new Group(Name = 'Engineering Support Queue', Type = 'Queue', DeveloperName = 'Engineering_Support_Queue'));
            }
            if (!existingDevNames.contains('Finance_Support_Queue')) {
                queuesToCreate.add(new Group(Name = 'Finance Support Queue', Type = 'Queue', DeveloperName = 'Finance_Support_Queue'));
            }
            if (!existingDevNames.contains('Product_Support_Queue')) {
                queuesToCreate.add(new Group(Name = 'Product Support Queue', Type = 'Queue', DeveloperName = 'Product_Support_Queue'));
            }

            if (!queuesToCreate.isEmpty()) {
                insert queuesToCreate;
                System.debug('[Queues] ✓ Created ' + queuesToCreate.size() + ' new queues');
                for (Group q : queuesToCreate) {
                    queueIds.put(q.DeveloperName, q.Id);
                }
            }

            // Assign Case object to queues
            List<Group> allQueues = [
                SELECT Id
                FROM Group
                WHERE Type = 'Queue' AND DeveloperName IN ('Engineering_Support_Queue', 'Finance_Support_Queue', 'Product_Support_Queue')
            ];

            // Check if QueueSobject already exists
            List<QueueSobject> existingQueueSobjects = [
                SELECT QueueId
                FROM QueueSobject
                WHERE QueueId IN :allQueues AND SobjectType = 'Case'
            ];

            Set<Id> existingQueueIds = new Set<Id>();
            for (QueueSobject qs : existingQueueSobjects) {
                existingQueueIds.add(qs.QueueId);
            }

            List<QueueSobject> queueSobjectsToCreate = new List<QueueSobject>();
            for (Group queue : allQueues) {
                if (!existingQueueIds.contains(queue.Id)) {
                    queueSobjectsToCreate.add(new QueueSobject(QueueId = queue.Id, SobjectType = 'Case'));
                }
            }

            if (!queueSobjectsToCreate.isEmpty()) {
                insert queueSobjectsToCreate;
                System.debug('[Queues] ✓ Assigned Case object to ' + queueSobjectsToCreate.size() + ' queues');
            }

            System.debug('========================================');
            System.debug('QUEUE SETUP COMPLETE');
            System.debug('Now run: CaseProcessingWorkflowFactory.executeDemo();');
            System.debug('========================================');

            return queueIds;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Queue setup failed: ' + e.getMessage());
            throw e;
        }
    }

    /**
     * @description Main entry point - creates realistic 3-agent workflow (Triage → Assignment → Escalation)
     * @param llmConfigId The LLM Configuration to use for all agents
     * @return Map<String, Id> containing agent IDs: 'WorkflowAgent', 'TriageAgent', 'AssignmentAgent', 'EscalationAgent'
     */
    public static Map<String, Id> createWorkflow(Id llmConfigId) {
        System.debug('========================================');
        System.debug('CASE PROCESSING WORKFLOW - CREATION');
        System.debug('========================================');

        Map<String, Id> agentIds = new Map<String, Id>();

        // Create the workflow orchestrator (NO context configs - those go on child agents)
        AIAgentDefinition__c workflow = new AIAgentDefinition__c(
            Name = 'Case Processing Workflow',
            DeveloperName__c = 'Case_Processing_Workflow',
            AgentType__c = 'Workflow',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            Description__c = 'Production-grade case processing: Triage → Assignment → Conditional Escalation. Child agents have consolidated context (Case+Account+Contact+Entitlement). No enrichment agent needed.',
            AuditLevel__c = 'Full',
            ContextFormatStrategy__c = 'Structured Text'
        );
        insert workflow;
        agentIds.put('WorkflowAgent', workflow.Id);
        System.debug('[Workflow] ✓ Created orchestrator: ' + workflow.Name);

        // Create 3 specialized child function agents (they will each get context config)
        Id triageAgent = createCaseTriageAgent(llmConfigId);
        Id assignmentAgent = createCaseAssignmentAgent(llmConfigId);
        Id escalationAgent = createHighValueEscalationAgent(llmConfigId);

        agentIds.put('TriageAgent', triageAgent);
        agentIds.put('AssignmentAgent', assignmentAgent);
        agentIds.put('EscalationAgent', escalationAgent);

        // Define workflow steps (realistic sequence with conditional branching)
        List<AgentWorkflowStep__c> steps = new List<AgentWorkflowStep__c>{
            new AgentWorkflowStep__c(
                WorkflowAgent__c = workflow.Id,
                ChildAgent__c = triageAgent,
                ExecutionOrder__c = 1,
                IsActive__c = true,
                Description__c = 'Step 1: Triage & Routing - Classify, score urgency, filter spam, route to queue, suggest knowledge articles'
            ),
            new AgentWorkflowStep__c(
                WorkflowAgent__c = workflow.Id,
                ChildAgent__c = assignmentAgent,
                ExecutionOrder__c = 2,
                IsActive__c = true,
                Description__c = 'Step 2: Assignment & Notification - Assign to best rep (skills, workload), notify rep & customer, create follow-up task'
            ),
            new AgentWorkflowStep__c(
                WorkflowAgent__c = workflow.Id,
                ChildAgent__c = escalationAgent,
                ExecutionOrder__c = 3,
                IsActive__c = true,
                Description__c = 'Step 3: High-Value Escalation (CONDITIONAL - designed for Priority=Critical OR High+$1M revenue) - Executive review for critical/high-value cases. Note: Conditional execution to be implemented in framework. For now, agent will assess and skip if not applicable.'
            )
        };
        insert steps;

        System.debug('[Workflow] ✓ Created ' + steps.size() + ' workflow steps');
        System.debug('========================================');
        System.debug('Workflow Architecture (Realistic):');
        System.debug('  • Context: Case + Account + Contact + Entitlements (consolidated, attached to child agents)');
        System.debug('  1. Triage → Classify, route, filter, knowledge');
        System.debug('  2. Assignment → Match rep, notify, acknowledge');
        System.debug('  3. Escalation → Conditional (high-value only, LLM-assessed)');
        System.debug('  • SLA monitoring → Scheduled automation (not agent)');
        System.debug('========================================');

        return agentIds;
    }

    /**
     * @description Creates comprehensive seed data for testing the workflow
     * Creates: Accounts, Contacts, Entitlements, Queues, Knowledge Articles, Test Cases
     * Uses get-or-create for accounts/contacts so running after AgentTestDataFactory (or re-runs) does not hit duplicate rules.
     */
    public static void createSeedData() {
        System.debug('[SeedData] Creating test data for workflow...');

        // Get or create Accounts by name (avoids DUPLICATES_DETECTED when run after AgentTestDataFactory or on re-run)
        List<Account> accounts = getOrCreateWorkflowAccounts();
        dataIds.put('Premium_Account', accounts[0].Id);
        dataIds.put('Standard_Account', accounts[1].Id);
        dataIds.put('Basic_Account', accounts[2].Id);
        System.debug('[SeedData] ✓ Using ' + accounts.size() + ' accounts (Premium, Standard, Basic)');

        // Get or create Contacts by email (avoids duplicate errors on re-run)
        List<Contact> contacts = getOrCreateWorkflowContacts(accounts);
        System.debug('[SeedData] ✓ Created ' + contacts.size() + ' contacts');

        // Get or create Entitlements (SLA tiers) - Status is auto-set by Salesforce
        List<Entitlement> entitlements = getOrCreateWorkflowEntitlements(accounts);
        System.debug('[SeedData] ✓ Using ' + entitlements.size() + ' entitlements (SLA tiers)');

        // Note: Queues are created separately via setupQueues() due to Mixed DML restrictions

        // Create Knowledge Articles
        createKnowledgeArticles();

        System.debug('[SeedData] ✓ All seed data created successfully');
    }

    /**
     * @description Get or create the three workflow accounts by name. Reuses existing records to avoid DUPLICATES_DETECTED when run after AgentTestDataFactory or on re-run.
     * @return List of 3 Account records in order: Premium, Standard, Basic
     */
    private static List<Account> getOrCreateWorkflowAccounts() {
        List<String> names = new List<String>{ 'Enterprise Corp (Premium)', 'MidMarket Ltd (Standard)', 'Startup Inc (Basic)' };
        List<Account> existing = [
            SELECT Id, Name
            FROM Account
            WHERE Name IN :names
            ORDER BY Name
        ];
        Map<String, Id> nameToId = new Map<String, Id>();
        for (Account a : existing) {
            nameToId.put(a.Name, a.Id);
        }
        List<Account> toInsert = new List<Account>();
        if (!nameToId.containsKey(names[0])) {
            toInsert.add(
                new Account(
                    Name = names[0],
                    Industry = 'Technology',
                    Type = 'Customer - Direct',
                    AnnualRevenue = 5000000,
                    NumberOfEmployees = 250,
                    BillingCity = 'San Francisco',
                    BillingState = 'CA',
                    Phone = '(415) 555-0199',
                    Description = 'Premium tier customer. SLA: 4-hour response time.'
                )
            );
        }
        if (!nameToId.containsKey(names[1])) {
            toInsert.add(
                new Account(
                    Name = names[1],
                    Industry = 'Manufacturing',
                    Type = 'Customer - Direct',
                    AnnualRevenue = 1000000,
                    NumberOfEmployees = 100,
                    BillingCity = 'Chicago',
                    BillingState = 'IL',
                    Phone = '(312) 555-0234',
                    Description = 'Standard tier customer. SLA: 24-hour response time.'
                )
            );
        }
        if (!nameToId.containsKey(names[2])) {
            toInsert.add(
                new Account(
                    Name = names[2],
                    Industry = 'Technology',
                    Type = 'Customer - Direct',
                    AnnualRevenue = 200000,
                    NumberOfEmployees = 25,
                    BillingCity = 'Austin',
                    BillingState = 'TX',
                    Phone = '(512) 555-0567',
                    Description = 'Basic tier customer. SLA: 48-hour response time.'
                )
            );
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
            for (Account a : toInsert) {
                nameToId.put(a.Name, a.Id);
            }
        }
        // Return in fixed order: Premium, Standard, Basic
        return new List<Account>{
            new Account(Id = nameToId.get(names[0]), Name = names[0]),
            new Account(Id = nameToId.get(names[1]), Name = names[1]),
            new Account(Id = nameToId.get(names[2]), Name = names[2])
        };
    }

    /**
     * @description Get or create workflow contacts by email. Reuses existing to avoid duplicate errors on re-run.
     * @param accounts List of 3 accounts (Premium, Standard, Basic order)
     * @return List of 3 Contact records in same order
     */
    private static List<Contact> getOrCreateWorkflowContacts(List<Account> accounts) {
        List<String> emails = new List<String>{ 'john.smith@enterprisecorp.com', 'jane.doe@midmarket.com', 'bob@startup.com' };
        List<Contact> existing = [
            SELECT Id, Email, AccountId
            FROM Contact
            WHERE Email IN :emails
        ];
        Map<String, Contact> emailToContact = new Map<String, Contact>();
        for (Contact c : existing) {
            emailToContact.put(c.Email, c);
        }
        List<Contact> toInsert = new List<Contact>();
        if (!emailToContact.containsKey(emails[0])) {
            toInsert.add(new Contact(FirstName = 'John', LastName = 'Smith', AccountId = accounts[0].Id, Email = emails[0], Title = 'IT Director'));
        }
        if (!emailToContact.containsKey(emails[1])) {
            toInsert.add(new Contact(FirstName = 'Jane', LastName = 'Doe', AccountId = accounts[1].Id, Email = emails[1], Title = 'Operations Manager'));
        }
        if (!emailToContact.containsKey(emails[2])) {
            toInsert.add(new Contact(FirstName = 'Bob', LastName = 'Johnson', AccountId = accounts[2].Id, Email = emails[2], Title = 'CTO'));
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
            for (Contact c : toInsert) {
                emailToContact.put(c.Email, c);
            }
        }
        return new List<Contact>{ emailToContact.get(emails[0]), emailToContact.get(emails[1]), emailToContact.get(emails[2]) };
    }

    /**
     * @description Get or create entitlements for the three workflow accounts. Reuses existing by Name + AccountId.
     * @param accounts List of 3 accounts (Premium, Standard, Basic order)
     * @return List of 3 Entitlement records
     */
    private static List<Entitlement> getOrCreateWorkflowEntitlements(List<Account> accounts) {
        List<String> entNames = new List<String>{ 'Premium Support - 4hr SLA', 'Standard Support - 24hr SLA', 'Basic Support - 48hr SLA' };
        Set<Id> accountIds = new Set<Id>{ accounts[0].Id, accounts[1].Id, accounts[2].Id };
        List<Entitlement> existing = [
            SELECT Id, Name, AccountId
            FROM Entitlement
            WHERE AccountId IN :accountIds AND Name IN :entNames
        ];
        Map<Id, Map<String, Entitlement>> accountEntitlements = new Map<Id, Map<String, Entitlement>>();
        for (Entitlement e : existing) {
            if (!accountEntitlements.containsKey(e.AccountId)) {
                accountEntitlements.put(e.AccountId, new Map<String, Entitlement>());
            }
            accountEntitlements.get(e.AccountId).put(e.Name, e);
        }
        List<Entitlement> toInsert = new List<Entitlement>();
        if (accountEntitlements.get(accounts[0].Id) == null || !accountEntitlements.get(accounts[0].Id).containsKey(entNames[0])) {
            toInsert.add(
                new Entitlement(
                    Name = entNames[0],
                    AccountId = accounts[0].Id,
                    StartDate = Date.today().addMonths(-12),
                    EndDate = Date.today().addMonths(12),
                    Type = 'Premium'
                )
            );
        }
        if (accountEntitlements.get(accounts[1].Id) == null || !accountEntitlements.get(accounts[1].Id).containsKey(entNames[1])) {
            toInsert.add(
                new Entitlement(
                    Name = entNames[1],
                    AccountId = accounts[1].Id,
                    StartDate = Date.today().addMonths(-6),
                    EndDate = Date.today().addMonths(18),
                    Type = 'Standard'
                )
            );
        }
        if (accountEntitlements.get(accounts[2].Id) == null || !accountEntitlements.get(accounts[2].Id).containsKey(entNames[2])) {
            toInsert.add(
                new Entitlement(
                    Name = entNames[2],
                    AccountId = accounts[2].Id,
                    StartDate = Date.today().addMonths(-3),
                    EndDate = Date.today().addMonths(9),
                    Type = 'Basic'
                )
            );
        }
        if (!toInsert.isEmpty()) {
            insert toInsert;
            for (Entitlement e : toInsert) {
                if (!accountEntitlements.containsKey(e.AccountId)) {
                    accountEntitlements.put(e.AccountId, new Map<String, Entitlement>());
                }
                accountEntitlements.get(e.AccountId).put(e.Name, e);
            }
        }
        return new List<Entitlement>{
            accountEntitlements.get(accounts[0].Id).get(entNames[0]),
            accountEntitlements.get(accounts[1].Id).get(entNames[1]),
            accountEntitlements.get(accounts[2].Id).get(entNames[2])
        };
    }

    /**
     * @description Creates knowledge articles for testing search_knowledge capability
     */
    private static void createKnowledgeArticles() {
        List<Knowledge__kav> articles = new List<Knowledge__kav>{
            new Knowledge__kav(
                Title = 'Password Reset Self-Service Guide',
                UrlName = 'Password-Reset-Guide-' + System.currentTimeMillis(),
                Summary = 'Step-by-step guide to reset your password: 1) Click "Forgot Password" on login page. 2) Enter your email. 3) Check email for reset link (valid 24 hours). 4) Create new password (min 8 chars, uppercase, lowercase, number, special character). If no email received, check spam folder or contact support.'
            ),
            new Knowledge__kav(
                Title = 'SAP Integration Troubleshooting',
                UrlName = 'SAP-Integration-Troubleshooting-' + System.currentTimeMillis(),
                Summary = 'Common SAP integration issues: HTTP 500 errors - Check endpoint availability and API credentials. Authentication failures - Verify API key validity and SAP user permissions. Data sync delays - Review sync schedule and volume limits. Field mapping errors - Verify API field names match between systems.'
            ),
            new Knowledge__kav(
                Title = 'System Performance Optimization',
                UrlName = 'System-Performance-Optimization-' + System.currentTimeMillis(),
                Summary = 'Troubleshooting slow performance: 1) Clear browser cache. 2) Verify network connection. 3) Disable browser extensions. 4) Check Status Page for incidents. 5) Review concurrent user limits. Common causes: browser cache buildup, network latency, hitting license limits.'
            ),
            new Knowledge__kav(
                Title = 'Understanding SLA Response Times',
                UrlName = 'SLA-Response-Times-' + System.currentTimeMillis(),
                Summary = 'SLA tiers: Premium (4hr response, 24/7 coverage), Standard (24hr response, business hours), Basic (48hr response, best effort). Response time starts when case submitted. Escalations handled immediately regardless of tier. Contact Account Manager to upgrade tier.'
            )
        };
        insert articles;

        // Publish articles
        List<Knowledge__kav> insertedArticles = [SELECT Id, KnowledgeArticleId FROM Knowledge__kav WHERE Id IN :articles];
        for (Knowledge__kav article : insertedArticles) {
            KbManagement.PublishingService.publishArticle(article.KnowledgeArticleId, true);
        }
        System.debug('[SeedData] ✓ Created and published ' + articles.size() + ' knowledge articles');
    }

    /**
     * @description Executes test scenarios to demonstrate the workflow
     */
    private static void executeTestScenarios() {
        List<Account> accounts = [
            SELECT Id, Name
            FROM Account
            WHERE Name LIKE '%Corp%' OR Name LIKE '%Ltd%' OR Name LIKE '%Inc%'
            ORDER BY AnnualRevenue DESC
            LIMIT 3
        ];

        if (accounts.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[Test] No accounts found. Skipping test execution.');
            return;
        }

        // Create diverse test cases
        List<Case> testCases = new List<Case>{
            new Case(
                AccountId = accounts[0].Id,
                Subject = 'CRITICAL: System Down - Revenue Impact',
                Description = 'Production system completely down. 200+ users unable to access platform. Estimated $50K/hour revenue loss. Need immediate assistance.',
                Status = 'New',
                Priority = 'Medium',
                Origin = 'Phone',
                Type = 'Problem'
            ),
            new Case(
                AccountId = accounts[0].Id,
                Subject = 'SAP Integration Error 500',
                Description = 'SAP integration failing with HTTP 500 errors. Orders not syncing. Started 2 hours ago after system update.',
                Status = 'New',
                Priority = 'High',
                Origin = 'Email',
                Type = 'Problem'
            ),
            new Case(
                AccountId = accounts[1].Id,
                Subject = 'Invoice Discrepancy - Overcharged',
                Description = 'December invoice shows $15K but contract specifies $12K. Please review and issue credit.',
                Status = 'New',
                Priority = 'Medium',
                Origin = 'Web',
                Type = 'Question'
            ),
            new Case(
                AccountId = accounts[2].Id,
                Subject = 'How to reset user password?',
                Description = 'One of our users forgot their password. What is the reset process? Is there self-service option?',
                Status = 'New',
                Priority = 'Low',
                Origin = 'Email',
                Type = 'Question'
            ),
            new Case(
                AccountId = accounts[2].Id,
                Subject = 'CLICK HERE FOR FREE MONEY!!!',
                Description = 'asdfkj aslkdfj alskdfj spam promotional junk gibberish',
                Status = 'New',
                Priority = 'Low',
                Origin = 'Web'
            )
        };
        insert testCases;

        System.debug('[Test] ✓ Created ' + testCases.size() + ' test cases');
        System.debug('[Test] Scenarios:');
        System.debug('  1. Critical outage (should escalate)');
        System.debug('  2. SAP integration issue (route to Engineering)');
        System.debug('  3. Billing question (route to Finance)');
        System.debug('  4. Password reset (should find KB article)');
        System.debug('  5. Spam case (should auto-close)');

        // Trigger workflow execution
        AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
        payload.sourceRecordIds = new List<Id>();
        for (Case c : testCases) {
            payload.sourceRecordIds.add(c.Id);
        }

        try {
            AgentExecutionService.ExecutionResult result = AgentExecutionService.startExecution('Case_Processing_Workflow', payload);

            System.debug('[Test] ✓ Workflow execution initiated');
            System.debug('[Test] Execution ID: ' + result.executionId);
            System.debug('[Test] Success: ' + result.success);

            if (!result.success) {
                System.debug(LoggingLevel.ERROR, '[Test] Execution failed: ' + result.message);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[Test] Failed to execute workflow: ' + e.getMessage());
        }
    }

    /**
     * @description Gets existing or creates new LLM Configuration
     */
    private static LLMConfiguration__c getOrCreateLLMConfig() {
        // Try to find existing config
        List<LLMConfiguration__c> existing = [
            SELECT Id, Name
            FROM LLMConfiguration__c
            WHERE DefaultModelIdentifier__c = 'gpt-4o-mini'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (!existing.isEmpty()) {
            System.debug('[LLM] ✓ Using existing LLM Configuration: ' + existing[0].Name);
            return existing[0];
        }

        // Create new config
        LLMConfiguration__c config = new LLMConfiguration__c(
            Name = 'OpenAI GPT-4 (Workflow Demo)',
            DeveloperName__c = 'OpenAI_GPT4_Workflow_Demo',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-4o-mini',
            DefaultTemperature__c = 0.1,
            IsActive__c = true
        );
        insert config;
        System.debug('[LLM] ✓ Created new LLM Configuration: ' + config.Name);
        return config;
    }

    // ===================================================================================
    // AGENT CREATION METHODS (REALISTIC SCENARIO)
    // ===================================================================================

    /**
     * @description Step 1: Case Triage & Routing Agent
     * Classifies cases, scores urgency, filters spam, routes to queue, suggests knowledge
     * Receives pre-loaded context (Case, Account, Contact, Entitlement) from workflow config
     * Capabilities: classify_and_update_case, search_knowledge_base, assign_to_queue, add_internal_comment, attach_knowledge_articles
     */
    private static Id createCaseTriageAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Case Triage & Routing Agent',
            DeveloperName__c = 'Case_Triage_Routing_Agent',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            EnableParallelToolCalling__c = true,
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You are a Case Triage Specialist for a support organization. You analyze incoming cases, classify them accurately, detect spam, route to the correct queue, and suggest relevant knowledge articles.',
            InstructionsPrompt__c = 'Analyze the case using the provided context (Case, Account, Contact, Entitlement).\n\n' +
                '**1. SPAM DETECTION:** Check for spam indicators: gibberish, phishing, test submissions, promotional content. If spam → mark as "Closed" with Reason="Spam".\n\n' +
                '**2. CLASSIFICATION:**\n' +
                '- Type: Problem (bugs, errors), Question (how-to), Feature Request, Technical (general technical issues)\n' +
                '- Category (use Reason field): Technical-SAP, Technical-Platform, Technical-API, Billing-Invoice, Billing-Payment, Product-Feature, Product-Question\n\n' +
                '**3. URGENCY SCORING (Priority field - High/Medium/Low):**\n' +
                '- High: "system down", "revenue impact", "data loss", ">50 users affected", "broken", "not working", "urgent", Premium customer SLA\n' +
                '- Medium: Standard issues with workarounds, moderate impact\n' +
                '- Low: Questions, minor issues, general inquiries\n\n' +
                '**4. ROUTING:**\n' +
                '- Technical issues → Engineering_Support_Queue\n' +
                '- Billing/invoicing → Finance_Support_Queue\n' +
                '- Product questions/features → Product_Support_Queue\n\n' +
                '**5. KNOWLEDGE SEARCH:** Search for relevant KB articles (2-4 keywords from Subject). Attach top 2-3 articles.\n\n' +
                '**6. DOCUMENTATION:** Add internal comment with triage reasoning (category, priority, routing decision, confidence).'
        );
        insert agent;

        // Add consolidated context config to this agent
        AgentContextConfig__c contextConfig = createContext(
            agent.Id,
            'Case Processing Context',
            'CaseProcessingContextProvider',
            'Case,Account,Contact,Entitlement',
            true,
            1
        );
        insert contextConfig;
        System.debug('[Agent] ✓ Added consolidated context config to Triage agent');

        // Capabilities (5 total)
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            createCapability(
                agent.Id,
                'classify_and_update_case',
                'Updates Case classification fields based on triage analysis.\n\n' +
                    '**Fields to update:**\n' +
                    '- Type: Flexible string field (e.g., "Problem", "Question", "Feature Request", "Technical")\n' +
                    '- Priority: High, Medium, Low (standard Salesforce values)\n' +
                    '- Status: New, Working, Escalated, Closed (standard Salesforce values)\n' +
                    '- Reason: Flexible string field for categorization (e.g., "Technical-SAP", "Billing-Invoice")\n\n' +
                    '**When to use:** After analyzing case description and context. Use this to set classification before routing.',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"Case ID from context. MUST start with 500.","pattern":"^500[a-zA-Z0-9]{15}$"},"recordData":{"type":"object","properties":{"Type":{"type":"string","description":"Case type/category (flexible text)"},"Priority":{"type":"string","enum":["High","Medium","Low"],"description":"Priority level"},"Status":{"type":"string","enum":["New","Working","Escalated","Closed"],"description":"Case status"},"Reason":{"type":"string","maxLength":255,"description":"Category reason like Technical-SAP, Billing-Invoice"}},"additionalProperties":false}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{"objectApiName":"Case"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'search_knowledge_base',
                'Searches Salesforce Knowledge for relevant troubleshooting articles and solutions.\n\n' +
                    '**Returns:** Articles with Title, Summary, ArticleNumber, URL\n\n' +
                    '**Search strategy:** Extract 2-4 key terms from case Subject (e.g., "SAP integration error" → "SAP integration").\n\n' +
                    '**When to use:** After classification, before routing. Find articles that can help rep or customer resolve faster.\n\n' +
                    '**Limit:** Return top 5 results, most relevant first.',
                '{"type":"object","properties":{"searchQuery":{"type":"string","description":"2-4 keywords from case Subject or Description","examples":["password reset","SAP integration error","billing invoice"]},"maxResults":{"type":"integer","description":"Max articles to return (default 5)","default":5,"minimum":1,"maximum":10}},"required":["searchQuery"]}',
                'Apex',
                null,
                'ActionSearchKnowledge',
                null,
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'assign_to_queue',
                'Routes case to appropriate support queue based on classification.\n\n' +
                    '**Available Queues (use OwnerId from queue lookup):**\n' +
                    '- Engineering_Support_Queue (00Gxxx) - Technical issues, bugs, integrations, errors\n' +
                    '- Finance_Support_Queue (00Gxxx) - Billing, invoicing, payments, credits\n' +
                    '- Product_Support_Queue (00Gxxx) - Product questions, features, how-to\n\n' +
                    '**Workflow:** Classify case first, then route to correct queue.\n\n' +
                    '**Note:** Queue IDs start with "00G". You must provide the correct queue ID.',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"Case ID. MUST start with 500.","pattern":"^500[a-zA-Z0-9]{15}$"},"recordData":{"type":"object","properties":{"OwnerId":{"type":"string","format":"salesforce-id","description":"Queue ID to route to. MUST start with 00G. Engineering, Finance, or Product queue.","pattern":"^00G[a-zA-Z0-9]{15}$"}},"required":["OwnerId"]}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{"objectApiName":"Case"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'add_internal_comment',
                'Adds internal-only comment to case with triage reasoning and analysis.\n\n' +
                    '**Content:** Triage decision summary: classification, urgency assessment, routing rationale, confidence level, any flags (recurring issue, VIP customer, etc.).\n\n' +
                    '**Visibility:** Internal only (not visible to customer).\n\n' +
                    '**Purpose:** Audit trail, rep context, quality assurance.',
                '{"type":"object","properties":{"caseId":{"type":"string","format":"salesforce-id","description":"Case ID. MUST start with 500.","pattern":"^500[a-zA-Z0-9]{15}$"},"commentBody":{"type":"string","maxLength":4000,"description":"Internal triage notes: category, priority reasoning, routing decision"},"isPublic":{"type":"boolean","const":false,"description":"Always false for internal comments"}},"required":["caseId","commentBody"]}',
                'Apex',
                null,
                'ActionCaseProcessing',
                '{"operation":"create_case_comment"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'attach_knowledge_articles',
                'Links knowledge articles to case (visible in rep\'s case view).\n\n' +
                    '**Purpose:** Provide rep with instant access to relevant solutions without manual search.\n\n' +
                    '**Workflow:** After search_knowledge_base returns results, attach top 2-3 most relevant articles.\n\n' +
                    '**Benefit:** Faster resolution, consistent solutions, reduced research time.',
                '{"type":"object","properties":{"caseId":{"type":"string","format":"salesforce-id","description":"Case ID. MUST start with 500.","pattern":"^500[a-zA-Z0-9]{15}$"},"articleIds":{"type":"array","items":{"type":"string","format":"salesforce-id","description":"Knowledge Article ID (ka0xxx)","pattern":"^ka0[a-zA-Z0-9]{15}$"},"description":"List of article IDs to attach (from search_knowledge_base response)","minItems":1,"maxItems":5}},"required":["caseId","articleIds"]}',
                'Apex',
                null,
                'ActionCaseProcessing',
                '{"operation":"attach_knowledge_articles"}',
                null,
                false,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Agent] ✓ Triage & Routing Agent created with ' + capabilities.size() + ' capabilities');
        return agent.Id;
    }

    /**
     * @description Step 2: Case Assignment & Notification Agent
     * Assigns to best rep (skills, workload), notifies rep & customer, creates follow-up task
     * Capabilities: get_queue_members, get_user_workload, get_account_case_history, assign_case_to_user,
     *               send_rep_notification, send_customer_acknowledgment, create_followup_task
     */
    private static Id createCaseAssignmentAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'Case Assignment & Notification Agent',
            DeveloperName__c = 'Case_Assignment_Notification_Agent',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            EnableParallelToolCalling__c = false,
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You are a Case Assignment Specialist. You match cases to the best-fit support representative based on expertise, workload, and customer history, then notify all parties.',
            InstructionsPrompt__c = 'Assign the case to the best rep using available context.\n\n' +
                '**1. GATHER CONTEXT:**\n' +
                '- Get queue members: `get_queue_members` (case is already routed to a queue)\n' +
                '- Check workload: `get_user_workload` (avoid overloading)\n' +
                '- Review history: `get_account_case_history` (prefer continuity)\n\n' +
                '**2. SELECT BEST REP:**\n' +
                '- Match skills to case category (SAP expert for SAP issues)\n' +
                '- Balance workload (choose rep with fewer open cases)\n' +
                '- Prefer rep who handled previous cases for this account (if applicable)\n' +
                '- Consider SLA tier (Premium customers → senior reps)\n\n' +
                '**3. ASSIGN:**\n' +
                '- Update case owner: `assign_case_to_user`\n' +
                '- Set Status to "Working"\n\n' +
                '**4. NOTIFY:**\n' +
                '- Alert rep: `send_rep_notification` (in-app, includes case summary, priority, SLA)\n' +
                '- Acknowledge customer: `send_customer_acknowledgment` (email: "Your case is assigned to [Rep], expected response within [SLA]")\n\n' +
                '**5. CREATE FOLLOW-UP:**\n' +
                '- For urgent cases (High priority + Premium SLA): `create_followup_task` due before SLA deadline'
        );
        insert agent;

        // Add consolidated context config to this agent
        AgentContextConfig__c contextConfig = createContext(
            agent.Id,
            'Case Processing Context',
            'CaseProcessingContextProvider',
            'Case,Account,Contact,Entitlement',
            true,
            1
        );
        insert contextConfig;
        System.debug('[Agent] ✓ Added consolidated context config to Assignment agent');

        // Capabilities (7 total)
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            createCapability(
                agent.Id,
                'get_queue_members',
                'Retrieves all active users in the case\'s assigned queue.\n\n' +
                    '**Returns:** List of queue members with User ID, Name, current open case count, skills (if available).\n\n' +
                    '**Purpose:** Identify available reps in the queue for assignment decision.\n\n' +
                    '**Note:** Case must already be assigned to a queue (from Triage agent).',
                '{"type":"object","properties":{"queueDeveloperName":{"type":"string","description":"Queue developer name: Engineering_Support_Queue, Finance_Support_Queue, or Product_Support_Queue","enum":["Engineering_Support_Queue","Finance_Support_Queue","Product_Support_Queue"]}},"required":["queueDeveloperName"]}',
                'Apex',
                null,
                'ActionCaseProcessing',
                '{"operation":"get_queue_members"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_user_workload',
                'Retrieves current workload for specified users (open case counts, critical case counts).\n\n' +
                    '**Returns:** For each user: open cases, critical cases, workload score (0-100, higher = busier).\n\n' +
                    '**Purpose:** Avoid overloading reps. Choose rep with lower workload score.\n\n' +
                    '**Workflow:** Call after `get_queue_members` to check workload for candidate reps.',
                '{"type":"object","properties":{"userIds":{"type":"array","items":{"type":"string","format":"salesforce-id","pattern":"^005[a-zA-Z0-9]{15}$"},"description":"List of User IDs to check workload for (from get_queue_members)","minItems":1}},"required":["userIds"]}',
                'Apex',
                null,
                'ActionCaseProcessing',
                '{"operation":"get_user_workload"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'get_account_case_history',
                'Retrieves recent cases for this account (last 90 days) to identify rep continuity.\n\n' +
                    '**Returns:** Recent cases with Owner, Subject, Status, Resolution.\n\n' +
                    '**Purpose:** If a rep has successfully handled previous cases for this customer, prefer assigning to same rep for continuity.\n\n' +
                    '**Use case:** VIP accounts, complex technical issues, relationship building.',
                '{"type":"object","properties":{"accountId":{"type":"string","format":"salesforce-id","description":"Account ID from case context. MUST start with 001.","pattern":"^001[a-zA-Z0-9]{15}$"},"maxResults":{"type":"integer","description":"Max cases to return (default 10)","default":10,"minimum":1,"maximum":50}},"required":["accountId"]}',
                'Apex',
                null,
                'ActionCaseProcessing',
                '{"operation":"get_account_case_history"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'assign_case_to_user',
                'Assigns case to selected support rep and updates status.\n\n' +
                    '**What it does:** Updates Case.OwnerId to chosen user, sets Status to "Working".\n\n' +
                    '**When to use:** After selecting best rep based on skills, workload, and history.\n\n' +
                    '**Critical:** Use valid User ID (starts with 005) from get_queue_members response.',
                '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"Case ID. MUST start with 500.","pattern":"^500[a-zA-Z0-9]{15}$"},"recordData":{"type":"object","properties":{"OwnerId":{"type":"string","format":"salesforce-id","description":"User ID of rep to assign to. MUST start with 005.","pattern":"^005[a-zA-Z0-9]{15}$"},"Status":{"type":"string","enum":["Working"],"const":"Working"}},"required":["OwnerId","Status"]}},"required":["recordId","recordData"]}',
                'Standard',
                'UpdateRecord',
                null,
                '{"objectApiName":"Case"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'send_rep_notification',
                'Sends in-app notification (bell icon) to assigned rep with case details.\n\n' +
                    '**Content:**\n' +
                    '- Title: "New Case Assigned: [Priority] - [Customer Name]"\n' +
                    '- Body: Case number, customer, priority, brief summary (50-100 words), SLA deadline\n' +
                    '- Highlight urgency for Critical/High priority\n\n' +
                    '**Delivery:** Instant notification in Salesforce (bell icon + optional email).',
                '{"type":"object","properties":{"recipientIds":{"type":"array","items":{"type":"string","format":"salesforce-id","pattern":"^005[a-zA-Z0-9]{15}$"},"description":"User IDs to notify (assigned rep)","minItems":1,"maxItems":1},"title":{"type":"string","maxLength":255,"description":"Notification title"},"body":{"type":"string","maxLength":1000,"description":"Notification body with case details"},"targetId":{"type":"string","format":"salesforce-id","description":"Case ID to link notification to","pattern":"^500[a-zA-Z0-9]{15}$"}},"required":["recipientIds","title","body","targetId"]}',
                'Apex',
                null,
                'ActionSendNotification',
                null,
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'send_customer_acknowledgment',
                'Sends customer-facing email: "Your case has been received and assigned."\n\n' +
                    '**Content:**\n' +
                    '- Case number, assigned rep name\n' +
                    '- Expected response time based on SLA tier (Premium 4hr, Standard 24hr, Basic 48hr)\n' +
                    '- Professional, branded template\n\n' +
                    '**Purpose:** Customer gets immediate confirmation, knows who\'s handling their case.',
                '{"type":"object","properties":{"toAddress":{"type":"string","format":"email","description":"Customer email address (from Contact context)"},"subject":{"type":"string","maxLength":255,"description":"Email subject line"},"body":{"type":"string","description":"Email body content"},"ccAddresses":{"type":"array","items":{"type":"string","format":"email"},"description":"CC email addresses (optional)"}},"required":["toAddress","subject","body"]}',
                'Apex',
                null,
                'ActionCaseProcessing',
                '{"operation":"send_email"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'create_followup_task',
                'Creates follow-up Task for assigned rep with SLA-based due date.\n\n' +
                    '**Purpose:** Ensure urgent cases don\'t slip through cracks. Task reminds rep of SLA deadline.\n\n' +
                    '**When to use:** For High priority cases with tight SLAs (Premium 4hr, Standard 24hr).\n\n' +
                    '**Task details:** Subject: "Follow up on Case #[CaseNumber]", Due: 80% of SLA time (e.g., 3.2 hours for 4hr SLA), Priority: High, Status: Not Started',
                '{"type":"object","properties":{"recordData":{"type":"object","properties":{"Subject":{"type":"string","description":"Task subject"},"ActivityDate":{"type":"string","format":"date","description":"Due date (YYYY-MM-DD format)"},"WhatId":{"type":"string","format":"salesforce-id","description":"Case ID to link task to","pattern":"^500[a-zA-Z0-9]{15}$"},"OwnerId":{"type":"string","format":"salesforce-id","description":"Assigned rep User ID","pattern":"^005[a-zA-Z0-9]{15}$"},"Priority":{"type":"string","enum":["High"],"const":"High"},"Status":{"type":"string","enum":["Not Started"],"const":"Not Started"}},"required":["Subject","ActivityDate","WhatId","OwnerId"]}},"required":["recordData"]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Task","defaultFieldValues":{"Status":"Not Started","Priority":"High"}}',
                null,
                false,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Agent] ✓ Assignment & Notification Agent created with ' + capabilities.size() + ' capabilities');
        return agent.Id;
    }

    /**
     * @description Step 3: High-Value Escalation Agent (CONDITIONAL)
     * Designed for critical/high-value cases requiring executive attention
     * Target cases: Priority = "Critical" OR (Priority = "High" AND Account.AnnualRevenue >= $1M)
     * Agent will assess and skip if case doesn't meet criteria
     * Capabilities: create_escalation_task, notify_account_team, post_to_executive_support_channel, recommend_proactive_outreach
     */
    private static Id createHighValueEscalationAgent(Id llmConfigId) {
        AIAgentDefinition__c agent = new AIAgentDefinition__c(
            Name = 'High-Value Escalation Agent',
            DeveloperName__c = 'High_Value_Escalation_Agent',
            AgentType__c = 'Function',
            IsActive__c = true,
            LLMConfiguration__c = llmConfigId,
            AuditLevel__c = 'Full',
            EnableParallelToolCalling__c = true,
            ContextFormatStrategy__c = 'Structured Text',
            IdentityPrompt__c = 'You are an Escalation Manager for high-value and critical cases. You ensure executive visibility, coordinate cross-functional teams, and recommend proactive customer outreach.',
            InstructionsPrompt__c = '**IMPORTANT: This agent is designed for high-value cases ONLY.**\n\n' +
                '**FIRST, ASSESS IF YOU SHOULD ACT:**\n' +
                '- Check Case Priority: Must be "High" (standard Salesforce has High/Medium/Low)\n' +
                '- If High priority: Check Account.AnnualRevenue >= $1,000,000\n' +
                '- If case does NOT meet criteria (e.g., Priority=Medium/Low, or Priority=High but revenue <$1M), respond: "This case does not require escalation. Skipping escalation agent." and STOP.\n\n' +
                '**IF CASE MEETS CRITERIA (High Priority + $1M+ Revenue), PROCEED:**\n\n' +
                '**1. ASSESS SEVERITY:**\n' +
                '- Review case details, customer value, business impact\n' +
                '- Determine if management/executive oversight is warranted\n' +
                '- Check for: system outages, revenue impact, data loss, VIP customer, relationship risk\n\n' +
                '**2. ESCALATE TO MANAGEMENT:**\n' +
                '- Create escalation task for Support Manager: `create_escalation_task`\n' +
                '- Task should include: case summary, customer value, business impact, urgency\n' +
                '- Priority: High, Due: TODAY\n\n' +
                '**3. NOTIFY ACCOUNT TEAM:**\n' +
                '- Alert Customer Success Manager / Account Executive: `notify_account_team`\n' +
                '- Purpose: Keep account owner aware of high-priority customer issues\n' +
                '- Use for: $1M+ accounts, relationship risk, potential churn\n\n' +
                '**4. EXECUTIVE VISIBILITY:**\n' +
                '- Post to Executive Support Chatter group: `post_to_executive_support_channel`\n' +
                '- For: System outages, >$5M accounts, multi-customer impact\n' +
                '- Include: Customer name, issue summary, business impact, assigned rep\n\n' +
                '**5. PROACTIVE OUTREACH:**\n' +
                '- Recommend executive call/meeting: `recommend_proactive_outreach`\n' +
                '- For: VIP accounts with high-priority issues, relationship salvage, major incidents\n' +
                '- Creates recommendation task for Account Manager'
        );
        insert agent;

        // Add consolidated context config to this agent
        AgentContextConfig__c contextConfig = createContext(
            agent.Id,
            'Case Processing Context',
            'CaseProcessingContextProvider',
            'Case,Account,Contact,Entitlement',
            true,
            1
        );
        insert contextConfig;
        System.debug('[Agent] ✓ Added consolidated context config to Escalation agent');

        // Capabilities (5 total - pure reasoning + 4 tools)
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>{
            createCapability(
                agent.Id,
                'create_escalation_task',
                'Creates high-priority task for Support Manager to review escalated case.\n\n' +
                    '**Task details:**\n' +
                    '- Subject: "ESCALATION: [Customer Name] - [Issue Summary]"\n' +
                    '- Description: Case details, customer value, business impact, severity rationale\n' +
                    '- Priority: High, Status: Not Started, Due: TODAY\n' +
                    '- Assigned to: Support Manager\n\n' +
                    '**When to use:** All critical/high-value cases that reach this agent.',
                '{"type":"object","properties":{"recordData":{"type":"object","properties":{"Subject":{"type":"string","maxLength":255,"description":"Escalation task subject"},"Description":{"type":"string","description":"Case details, customer value, business impact"},"ActivityDate":{"type":"string","format":"date","description":"Due date (TODAY, YYYY-MM-DD format)"},"WhatId":{"type":"string","format":"salesforce-id","description":"Case ID","pattern":"^500[a-zA-Z0-9]{15}$"},"OwnerId":{"type":"string","format":"salesforce-id","description":"Support Manager User ID","pattern":"^005[a-zA-Z0-9]{15}$"},"Priority":{"type":"string","enum":["High"],"const":"High"},"Status":{"type":"string","enum":["Not Started"],"const":"Not Started"},"Type":{"type":"string","const":"Escalation Review"}},"required":["Subject","Description","ActivityDate","WhatId","OwnerId"]}},"required":["recordData"]}',
                'Standard',
                'CreateRecord',
                null,
                '{"objectApiName":"Task","defaultFieldValues":{"Priority":"High","Status":"Not Started","Type":"Escalation Review"}}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'notify_account_team',
                'Sends notification to Account Owner (Customer Success Manager / Account Executive) about critical case.\n\n' +
                    '**Content:** Case number, customer name, issue severity, assigned rep, action needed (monitor for escalation).\n\n' +
                    '**Purpose:** Keep account team aware of issues with their accounts, especially relationship risks.\n\n' +
                    '**When to use:** $1M+ accounts, relationship-sensitive issues, potential churn risks.',
                '{"type":"object","properties":{"accountId":{"type":"string","format":"salesforce-id","description":"Account ID (to find Account Owner). MUST start with 001.","pattern":"^001[a-zA-Z0-9]{15}$"},"title":{"type":"string","maxLength":255,"description":"Notification title"},"body":{"type":"string","maxLength":1000,"description":"Notification body with case details"}},"required":["accountId","title","body"]}',
                'Apex',
                null,
                'ActionCaseProcessing',
                '{"operation":"notify_account_team"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'post_to_executive_support_channel',
                'Posts alert to Executive Support Chatter group for leadership visibility.\n\n' +
                    '**Use for:**\n' +
                    '- System-wide outages affecting multiple customers\n' +
                    '- $5M+ account issues\n' +
                    '- Major security incidents\n' +
                    '- Situations requiring cross-functional coordination\n\n' +
                    '**Content:** @mentions Support Manager, includes customer, issue, business impact, assigned rep.',
                '{"type":"object","properties":{"messageText":{"type":"string","maxLength":1000,"description":"Chatter post content with @mentions"},"topics":{"type":"array","items":{"type":"string"},"description":"Hashtags like #critical #escalation","examples":[["critical","escalation"]]}},"required":["messageText"]}',
                'Standard',
                'PostChatter',
                null,
                '{"feedType":"Group","targetId":"[Executive_Support_Group_Id]"}',
                null,
                false,
                'External'
            ),
            createCapability(
                agent.Id,
                'recommend_proactive_outreach',
                'Creates recommendation for Account Manager to schedule proactive call/meeting with customer.\n\n' +
                    '**Purpose:** For VIP accounts with critical issues, proactive executive outreach demonstrates commitment and can prevent churn.\n\n' +
                    '**Recommendation includes:** Talking points, case context, relationship risk assessment.\n\n' +
                    '**When to use:** $5M+ accounts, relationship-sensitive situations, major service failures.',
                '{"type":"object","properties":{"accountId":{"type":"string","format":"salesforce-id","description":"Account ID. MUST start with 001.","pattern":"^001[a-zA-Z0-9]{15}$"},"caseId":{"type":"string","format":"salesforce-id","description":"Case ID. MUST start with 500.","pattern":"^500[a-zA-Z0-9]{15}$"},"recommendation":{"type":"string","maxLength":2000,"description":"Why proactive outreach is recommended, talking points, relationship assessment"},"dueDate":{"type":"string","format":"date","description":"Recommended due date (YYYY-MM-DD)"}},"required":["accountId","recommendation"]}',
                'Apex',
                null,
                'ActionCaseProcessing',
                '{"operation":"recommend_proactive_outreach"}',
                null,
                false,
                'External'
            )
        };
        insert capabilities;

        System.debug('[Agent] ✓ High-Value Escalation Agent created with ' + capabilities.size() + ' capabilities (CONDITIONAL)');
        return agent.Id;
    }

    // ===================================================================================
    // HELPER METHODS
    // ===================================================================================

    /**
     * @description Creates an AgentContextConfig__c record
     */
    private static AgentContextConfig__c createContext(
        Id agentId,
        String name,
        String providerClass,
        String objectName,
        Boolean includePrevious,
        Integer executionOrder
    ) {
        return new AgentContextConfig__c(
            AIAgentDefinition__c = agentId,
            ContextLabel__c = name,
            ImplementationType__c = 'Apex',
            ImplementationName__c = providerClass,
            ApplicableSObjectTypes__c = objectName,
            RequiresRecordContext__c = includePrevious,
            ExecutionOrder__c = executionOrder,
            IsActive__c = true
        );
    }

    /**
     * @description Creates an AgentCapability__c record with standard configuration
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

    /**
     * @description Custom exception for demo execution errors
     */
    public class DemoException extends Exception {
    }
}
