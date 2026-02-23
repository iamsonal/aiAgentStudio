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
        createEmailAgent(llmConfig.Id);

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

//        delete [SELECT Id FROM AgentDecisionStep__c];
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

        List<User> serviceUsers = [SELECT Id FROM User WHERE Name = 'Service User' AND IsActive = TRUE];
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
            PermissionSetAssignment psa = new PermissionSetAssignment(AssigneeId = serviceUser.Id, PermissionSetId = permSets[0].Id);
            insert psa;
            System.debug('[Service User] ✓ Service User created and permission set assigned: ' + serviceUser.Username);
        } else {
            System.debug(
                LoggingLevel.WARN,
                '[Service User] ⚠ Service User created but permission set "AI Agent Studio Service User" not found. Assign it manually: ' +
                serviceUser.Username
            );
        }
    }

    // ===================================================================================
    // FOUNDATIONAL DATA
    // ===================================================================================

    private static void seedFoundationalData() {
        System.debug('[Foundation] Creating core business data...');

        List<Account> accounts = new List<Account>{
            new Account(
                Name = 'Acme Corporation',
                Industry = 'Technology',
                Type = 'Customer - Direct',
                BillingCountry = 'USA',
                BillingCity = 'San Francisco',
                BillingState = 'CA',
                BillingStreet = '350 Mission Street',
                BillingPostalCode = '94105',
                AnnualRevenue = 5000000,
                NumberOfEmployees = 250,
                AccountNumber = 'ACC-001234',
                Phone = '(415) 555-0199',
                Website = 'www.acmecorp.com',
                Description = 'Enterprise SaaS customer since 2020. Tier 1 support contract with 4-hour SLA. 250 active users across 3 business units (Sales, Marketing, Support). Annual contract value: $500K. Renewal date: Q4 2024. Key stakeholders: Sarah Johnson (IT Director), Michael Chen (Support Manager).'
            ),
            new Account(
                Name = 'Global Logistics Ltd',
                Industry = 'Transportation',
                Type = 'Customer - Direct',
                BillingCountry = 'UK',
                BillingCity = 'London',
                BillingStreet = '1 Canada Square',
                BillingPostalCode = 'E14 5AB',
                AnnualRevenue = 2000000,
                NumberOfEmployees = 150,
                AccountNumber = 'ACC-005678',
                Phone = '+44 20 7946 0958',
                Website = 'www.globallogistics.co.uk',
                Description = 'Mid-market logistics customer since 2021. Standard support package. 75 active users in operations and warehouse management. Recently completed professional services implementation. Complex legacy system integrations (SAP, Oracle WMS).'
            ),
            new Account(
                Name = 'TechStart Innovations',
                Industry = 'Technology',
                Type = 'Customer - Direct',
                BillingCountry = 'Canada',
                BillingCity = 'Toronto',
                BillingState = 'ON',
                BillingStreet = '100 King Street West',
                BillingPostalCode = 'M5X 1A9',
                AnnualRevenue = 500000,
                NumberOfEmployees = 45,
                AccountNumber = 'ACC-009012',
                Phone = '+1 (416) 555-0234',
                Website = 'www.techstart.ca',
                Description = 'Fast-growing startup customer since 2023. Basic support tier. 25 active users. High growth potential - expanded team by 50% in last 6 months. Interested in upgrading to premium features. Champion: David Martinez (CTO).'
            )
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
                Subject = 'URGENT: Platform Performance Issues - Dashboard Timeouts',
                Description = '🔴 URGENCY: HIGH\n\n' +
                    '=== ISSUE DETAILS ===\n' +
                    'Problem: Enterprise dashboard timing out during peak hours (9-11am PST)\n' +
                    'Error Message: "Request timeout after 30s" in browser console (Error Code: PERF-504)\n' +
                    'First Occurred: 3 days ago (coincides with platform update v2.4.1)\n' +
                    'Frequency: Daily, consistent during business hours\n\n' +
                    '=== BUSINESS IMPACT ===\n' +
                    '• 50+ users across Sales, Marketing, and Executive teams unable to access real-time metrics\n' +
                    '• Q1 Sales Review meeting delayed (scheduled for tomorrow)\n' +
                    '• Executive dashboard visibility completely blocked\n' +
                    '• Revenue at Risk: $500K annual contract up for renewal in 60 days\n\n' +
                    '=== TECHNICAL DETAILS ===\n' +
                    '• Dashboard load time: Previously 2s, now 30s+ (timeout)\n' +
                    '• Browser: Chrome 120.0, Firefox 121.0 (consistent across browsers)\n' +
                    '• Network: Corporate network, 100Mbps+ stable connection\n' +
                    '• Workaround: Users reverting to legacy reports (missing key features, slower)\n\n' +
                    '=== CUSTOMER SENTIMENT ===\n' +
                    'Escalated to VP level (Sarah Johnson). Customer frustration high. Renewal conversation at risk.\n\n' +
                    'Contact: Sarah Johnson (IT Director) - Available for screen share 2-4pm PST',
                Status = 'New',
                Priority = 'High',
                Origin = 'Email',
                Type = 'Problem',
                Reason = 'Performance'
            ),
            new Case(
                AccountId = accounts[0].Id,
                ContactId = contacts[1].Id,
                Subject = 'Unable to Access Reports Module - Error 403',
                Description = '⚠️ ISSUE SUMMARY\n\n' +
                    '=== PROBLEM ===\n' +
                    'Since yesterday (2:00 PM EST), our support team (12 users) cannot access the Reports module.\n' +
                    'Error: "Module not available - Access Denied (Error Code: AUTH-403)"\n\n' +
                    '=== STEPS TO REPRODUCE ===\n' +
                    '1. Login as Support Manager or Support Agent\n' +
                    '2. Navigate to Reports tab\n' +
                    '3. Click any report folder\n' +
                    '4. Error appears immediately\n\n' +
                    '=== BUSINESS IMPACT ===\n' +
                    '• Blocking end-of-quarter performance analysis (due Friday)\n' +
                    '• Team KPI dashboards inaccessible\n' +
                    '• Manual data pulls required (adding 2 hours/day overhead)\n' +
                    '• Impact Level: Medium - workaround exists but inefficient\n\n' +
                    '=== WHAT CHANGED ===\n' +
                    'IT ran user permission audit yesterday morning. May have affected report access permissions.\n\n' +
                    '=== ATTEMPTED FIXES ===\n' +
                    '• Cleared browser cache - No change\n' +
                    '• Tried different browsers - Same error\n' +
                    '• Logged out/in - Issue persists\n' +
                    '• Admin access works fine - Issue only affects Support team\n\n' +
                    'Contact: Michael Chen (Support Manager) - michael.chen@acme.com',
                Status = 'Working',
                Priority = 'Medium',
                Origin = 'Web',
                Type = 'Problem',
                Reason = 'Permissions'
            ),
            new Case(
                AccountId = accounts[1].Id,
                ContactId = contacts[2].Id,
                Subject = 'CRITICAL: Legacy System Integration Failure - Orders Not Syncing',
                Description = '🔴 CRITICAL - BUSINESS OPERATIONS IMPACTED\n\n' +
                    '=== SITUATION ===\n' +
                    'Implementation services completed last week. Integration with Oracle WMS (Warehouse Management System) failing since go-live on Monday.\n' +
                    'Error: "Connection timeout - Host unreachable (Error Code: INT-408)"\n\n' +
                    '=== BUSINESS IMPACT - CRITICAL ===\n' +
                    '• Orders NOT syncing to warehouse system\n' +
                    '• 150+ orders in queue, manual processing required\n' +
                    '• Shipping delays: 24-48 hours behind schedule\n' +
                    '• Customer complaints increasing\n' +
                    '• Daily Revenue Impact: ~$50K in delayed shipments\n' +
                    '• Operations team working overtime to manually process\n\n' +
                    '=== TECHNICAL DETAILS ===\n' +
                    'Source System: Your platform (Order Management)\n' +
                    'Target System: Oracle WMS v12.2 (on-premises)\n' +
                    'Integration Method: REST API calls every 5 minutes\n' +
                    'Endpoint: https://wms.globallogistics.internal/api/v1/orders\n' +
                    'Authentication: API Key (confirmed valid, expires 2025-12-31)\n\n' +
                    '=== ERROR LOGS ===\n' +
                    '2024-01-15 09:23:15 - Connection attempt #1 - TIMEOUT (30s)\n' +
                    '2024-01-15 09:28:20 - Connection attempt #2 - TIMEOUT (30s)\n' +
                    '2024-01-15 09:33:25 - Retry queue building up - 47 orders pending\n\n' +
                    '=== SUSPECTED CAUSE ===\n' +
                    'IT team suspects firewall rules may have been reset during weekend network maintenance.\n' +
                    'Need to coordinate with customer IT to verify:\n' +
                    '1. Firewall whitelist includes your IP ranges\n' +
                    '2. Port 443 open for HTTPS traffic\n' +
                    '3. API endpoint accessible from external network\n\n' +
                    '=== URGENCY ===\n' +
                    'IMMEDIATE RESPONSE NEEDED. Customer exec team involved. Account at risk.\n\n' +
                    'Primary Contact: Emma Williams (Operations Lead) - +44 20 7946 0958\n' +
                    'Technical Contact: IT Infrastructure Team - Available for joint troubleshooting call ASAP',
                Status = 'Escalated',
                Priority = 'High',
                Origin = 'Phone',
                Type = 'Problem',
                Reason = 'Installation'
            ),
            new Case(
                AccountId = accounts[2].Id,
                ContactId = contacts[3].Id,
                Subject = 'Request for Additional User Licenses - Team Expansion',
                Description = '📋 LICENSE REQUEST\n\n' +
                    '=== REQUEST DETAILS ===\n' +
                    'Our team has grown significantly and we need to add 10 more user licenses to accommodate new hires.\n\n' +
                    '=== BUSINESS CONTEXT ===\n' +
                    '• Current License Count: 25 users\n' +
                    '• Requested Additional Licenses: 10 users\n' +
                    '• New Total: 35 users\n' +
                    '• Reason: Successful Series A funding, expanding Engineering and Sales teams\n' +
                    '• Timeline: Need licenses activated by next Monday (new hire onboarding)\n\n' +
                    '=== CURRENT USAGE ===\n' +
                    '• Active Users: 25/25 (at capacity)\n' +
                    '• Average Daily Active Users: 23\n' +
                    '• License Utilization: 92%\n\n' +
                    '=== ADDITIONAL REQUESTS ===\n' +
                    '• Please provide pricing quote for 10 additional licenses\n' +
                    '• Confirm if pro-rated to current subscription end date (Aug 2024)\n' +
                    '• Interested in volume discount discussion for future growth\n\n' +
                    '=== DECISION MAKER ===\n' +
                    'David Martinez (CTO) - Approved budget for expansion\n' +
                    'PO ready to issue upon quote receipt\n\n' +
                    'Contact: david.martinez@techstart.com | +1 (416) 555-0234',
                Status = 'New',
                Priority = 'Low',
                Origin = 'Web',
                Type = 'Feature Request',
                Reason = 'Enhancement'
            )
        };
        insert cases;
        idMap.put('Performance Case', cases[0].Id);
        idMap.put('Reports Case', cases[1].Id);
        idMap.put('Integration Case', cases[2].Id);

        // Add Tasks to show case progression
        List<Task> caseTasks = new List<Task>{
            new Task(
                WhatId = cases[0].Id, // Performance case
                Subject = 'Initial triage - Review error logs and system metrics',
                Status = 'Completed',
                Priority = 'High',
                ActivityDate = Date.today().addDays(-2),
                Description = 'Reviewed dashboard performance logs. Identified slow query patterns in widget rendering. Average query time increased from 200ms to 15s after v2.4.1 deployment.'
            ),
            new Task(
                WhatId = cases[0].Id,
                Subject = 'Investigate database query performance',
                Status = 'Completed',
                Priority = 'High',
                ActivityDate = Date.today().addDays(-1),
                Description = 'Found N+1 query pattern in dashboard widgets. Main dashboard making 50+ database calls instead of optimized batch queries. Caching layer bypassed in recent update.'
            ),
            new Task(
                WhatId = cases[0].Id,
                Subject = 'Develop and test performance fix',
                Status = 'In Progress',
                Priority = 'High',
                ActivityDate = Date.today(),
                Description = 'Engineering team developing query optimization patch. Target: Reduce DB calls from 50+ to 5-8 using batch loading. ETA: Hotfix ready for testing by EOD.'
            ),
            new Task(
                WhatId = cases[1].Id, // Reports case
                Subject = 'Verify user permissions in Setup',
                Status = 'Completed',
                Priority = 'Medium',
                ActivityDate = Date.today().addDays(-1),
                Description = 'Checked Support Manager and Support Agent profiles. Reports Viewer permission was accidentally removed during yesterday\'s permission audit. Root cause identified.'
            ),
            new Task(
                WhatId = cases[1].Id,
                Subject = 'Restore Reports Viewer permission for Support team',
                Status = 'In Progress',
                Priority = 'Medium',
                ActivityDate = Date.today(),
                Description = 'Re-enabling Reports Viewer permission on Support profiles. Need to test with 2-3 users before rolling out to entire team (12 users).'
            ),
            new Task(
                WhatId = cases[2].Id, // Integration case
                Subject = 'Schedule technical call with customer IT team',
                Status = 'Completed',
                Priority = 'High',
                ActivityDate = Date.today().addDays(-1),
                Description = 'Call scheduled for today 10am GMT. Agenda: (1) Verify firewall rules, (2) Test API endpoint accessibility, (3) Review authentication credentials.'
            ),
            new Task(
                WhatId = cases[2].Id,
                Subject = 'Test API connectivity from external network',
                Status = 'In Progress',
                Priority = 'High',
                ActivityDate = Date.today(),
                Description = 'Working with customer IT to whitelist integration server IPs. Testing connection from our staging environment to their Oracle WMS endpoint. Initial tests showing DNS resolution working but connection refused - likely firewall blocking port 443.'
            ),
            new Task(
                WhatId = cases[3].Id, // License request case
                Subject = 'Generate quote for 10 additional user licenses',
                Status = 'Completed',
                Priority = 'Low',
                ActivityDate = Date.today().addDays(-3),
                Description = 'Quote generated: 10 licenses @ $400/user/year = $4,000 total. Pro-rated to subscription end date (Aug 2024): $2,400. Quote sent to David Martinez.'
            )
        };
        insert caseTasks;

        // Add Case Comments for historical context
        List<CaseComment> caseComments = new List<CaseComment>{
            new CaseComment(
                ParentId = cases[0].Id, // Performance case
                CommentBody = '[Customer - Sarah Johnson] Dashboard performance has gotten significantly worse over the past 3 days. Our executive team can\'t access their KPI dashboards during morning meetings. This is becoming a serious issue - we have our quarterly business review tomorrow and need this resolved ASAP.',
                IsPublished = true
            ),
            new CaseComment(
                ParentId = cases[0].Id,
                CommentBody = '[Internal - Support Engineer] Initial investigation shows the issue started immediately after the v2.4.1 platform update deployed on Friday evening. Timeline correlates perfectly with customer complaints. Dashboard query performance degraded significantly - seeing 15+ second response times vs. previous 200ms baseline.',
                IsPublished = false
            ),
            new CaseComment(
                ParentId = cases[0].Id,
                CommentBody = '[Internal - Engineering Team] Root cause identified: Recent refactoring introduced N+1 query antipattern in dashboard widget loader. Each widget making individual DB calls instead of batch queries. Caching layer also accidentally disabled in config merge. Hotfix in development - targeting deployment tonight with customer approval.',
                IsPublished = false
            ),
            new CaseComment(
                ParentId = cases[1].Id, // Reports case
                CommentBody = '[Customer - Michael Chen] Just following up - our support team still can\'t access any reports. We tried all the basic troubleshooting (cache clear, different browsers, logout/login) with no luck. It seems like a permissions issue since our admin account can access reports fine.',
                IsPublished = true
            ),
            new CaseComment(
                ParentId = cases[1].Id,
                CommentBody = '[Internal - Support Engineer] Confirmed this is a permissions issue. The "Reports Viewer" permission was removed from the Support Manager and Support Agent profiles during yesterday\'s security audit. Easy fix - just need to re-enable the permission. Testing with pilot user group before rolling out to all 12 affected users.',
                IsPublished = false
            ),
            new CaseComment(
                ParentId = cases[2].Id, // Integration case
                CommentBody = '[Customer - Emma Williams] This is becoming critical. We now have over 150 orders stuck in the queue that aren\'t syncing to our warehouse system. Our operations team is manually processing these but it\'s not sustainable. We\'re falling 2 days behind on shipments and getting customer complaints. Need immediate help on this integration issue.',
                IsPublished = true
            ),
            new CaseComment(
                ParentId = cases[2].Id,
                CommentBody = '[Internal - Implementation Team] Spoke with customer IT. During weekend network maintenance, their firewall rules were reset to default settings. Our integration server IPs were removed from the whitelist. Customer IT is re-adding the IP ranges now. We should see connection restored within the hour. Will monitor sync queue to ensure orders start flowing.',
                IsPublished = false
            ),
            new CaseComment(
                ParentId = cases[2].Id,
                CommentBody = '[Internal - Update] Firewall rules updated. Test connection successful from our staging environment to their Oracle WMS API endpoint. Orders are now syncing correctly. Backlog of 150+ orders should process within next 2-3 hours. Recommended to customer: Add our IP ranges to their firewall change control process to prevent future incidents.',
                IsPublished = false
            )
        };
        insert caseComments;

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

        // Add Opportunity Products for richer context
        List<OpportunityLineItem> oppProducts = new List<OpportunityLineItem>{
            new OpportunityLineItem(
                OpportunityId = opportunities[0].Id, // Acme expansion
                PricebookEntryId = pbes[0].Id, // Enterprise Cloud Platform License
                Quantity = 50,
                UnitPrice = 1000,
                Description = 'Expansion: 50 additional user licenses for Sales and Marketing teams. Upgrade from 250 to 300 total users.'
            ),
            new OpportunityLineItem(
                OpportunityId = opportunities[0].Id,
                PricebookEntryId = pbes[2].Id, // Premium Support Package
                Quantity = 1,
                UnitPrice = 15000,
                Description = 'Renewal: Premium support package with 4-hour SLA for expanded team (300 users). Includes dedicated CSM and quarterly business reviews.'
            ),
            new OpportunityLineItem(
                OpportunityId = opportunities[0].Id,
                PricebookEntryId = pbes[1].Id, // Professional Services
                Quantity = 40,
                UnitPrice = 250,
                Description = 'Professional Services: 40 hours for implementation support, custom integration development, and user training for new team members.'
            ),
            new OpportunityLineItem(
                OpportunityId = opportunities[1].Id, // TechStart new customer
                PricebookEntryId = pbes[0].Id, // Enterprise Cloud Platform License
                Quantity = 35,
                UnitPrice = 1200,
                Description = 'New Customer: 35 user licenses for entire team. Initial deployment across Engineering (20 users) and Sales (15 users) departments.'
            ),
            new OpportunityLineItem(
                OpportunityId = opportunities[1].Id,
                PricebookEntryId = pbes[1].Id, // Professional Services
                Quantity = 200,
                UnitPrice = 250,
                Description = 'Professional Services: Full implementation package (200 hours) including system setup, data migration, custom configuration, and comprehensive user training.'
            ),
            new OpportunityLineItem(
                OpportunityId = opportunities[1].Id,
                PricebookEntryId = pbes[2].Id, // Premium Support
                Quantity = 1,
                UnitPrice = 8000,
                Description = 'Standard Support Package: 12-hour SLA, email and phone support, access to knowledge base and community forums. First year included in implementation package.'
            )
        };
        insert oppProducts;

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
                NumberOfEmployees = 250,
                AnnualRevenue = 50000000,
                Rating = null,
                Description = 'HIGH-INTENT LEAD - Downloaded whitepaper: "Cloud Migration Strategies for Manufacturing". ' +
                    '\n\n📊 ENGAGEMENT SIGNALS:\n' +
                    '• Content Downloads: 2 (Cloud Migration Whitepaper, ROI Calculator)\n' +
                    '• Webinar Attendance: Attended "Digital Transformation for Manufacturers" (Jan 10, 2024)\n' +
                    '• Website Activity: Viewed pricing page 3x, spent 12 minutes on Enterprise features page\n' +
                    '• Email Engagement: 85% open rate, clicked "Schedule Demo" link twice\n\n' +
                    '🏢 FIRMOGRAPHICS:\n' +
                    '• Company Size: 250 employees\n' +
                    '• Annual Revenue: $50M\n' +
                    '• Industry: Manufacturing (Industrial Equipment)\n' +
                    '• Location: Midwest USA\n\n' +
                    '💡 PAIN POINTS & BUYING SIGNALS:\n' +
                    '• Current Challenge: "Legacy ERP system limiting growth and visibility"\n' +
                    '• Timeline: Q2 2024 decision (mentioned in webinar Q&A)\n' +
                    '• Budget: $200K allocated for cloud transformation project\n' +
                    '• Decision Committee: VP Operations (Jennifer), CIO, CFO\n' +
                    '• Competitor Eval: Also evaluating 2 competitors (mentioned on discovery call)\n\n' +
                    '🎯 QUALIFICATION NOTES:\n' +
                    'Strong HOT lead - Enterprise buyer, clear pain point, active budget, senior decision-maker engaged. Recommend immediate sales follow-up.'
            ),
            new Lead(
                FirstName = 'Robert',
                LastName = 'Taylor',
                Company = 'Startup Co',
                Title = 'Founder & CEO',
                Email = 'robert@startupco.com',
                Phone = '555-0102',
                Status = 'Open - Not Contacted',
                LeadSource = 'Referral',
                Industry = 'Technology',
                NumberOfEmployees = 12,
                AnnualRevenue = 800000,
                Rating = null,
                Description = 'EARLY-STAGE STARTUP - Referred by existing customer (TechStart Innovations). ' +
                    '\n\n📊 ENGAGEMENT SIGNALS:\n' +
                    '• Referral Source: David Martinez (TechStart CTO) - warm introduction\n' +
                    '• Initial Contact: Brief phone inquiry about pricing\n' +
                    '• Content Downloads: 1 (Startup pricing guide)\n' +
                    '• Website Activity: Minimal - viewed homepage and pricing page once\n\n' +
                    '🏢 FIRMOGRAPHICS:\n' +
                    '• Company Size: 12 employees (seed stage)\n' +
                    '• Annual Revenue: ~$800K (bootstrapped)\n' +
                    '• Industry: Technology (B2B SaaS)\n' +
                    '• Location: Austin, TX\n' +
                    '• Stage: Seed - Pre Series A\n\n' +
                    '💡 PAIN POINTS & BUYING SIGNALS:\n' +
                    '• Current Challenge: "Need affordable solution to manage growing customer base"\n' +
                    '• Budget Constraint: Looking for starter tier, very price sensitive\n' +
                    '• Timeline: "Exploring options, no immediate urgency"\n' +
                    '• Decision Maker: Founder (Robert) has full authority\n' +
                    '• Competition: Also considering free/open-source alternatives\n\n' +
                    '🎯 QUALIFICATION NOTES:\n' +
                    'COLD lead - Very small company, limited budget, no urgent timeline. However, strong referral source and high growth potential if they secure Series A funding. Consider for startup/SMB nurture program rather than enterprise sales track.'
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

        // gpt-4o-mini: proven, reliable tool calling. Used as default for all showcase agents.
        LLMConfiguration__c gpt4oMiniConfig = new LLMConfiguration__c(
            Name = 'OpenAI GPT-4o Mini',
            DeveloperName__c = 'OpenAI_GPT4o_Mini',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-4o-mini',
            DefaultTemperature__c = 0.1,
            MaxResponseTokens__c = 2048,
            IsActive__c = true
        );
        configs.add(gpt4oMiniConfig);

        // gpt-5-mini: cost-efficient GPT-5 for well-defined tasks
        LLMConfiguration__c gpt5MiniConfig = new LLMConfiguration__c(
            Name = 'OpenAI GPT-5 Mini',
            DeveloperName__c = 'OpenAI_GPT5_Mini',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-5-mini',
            DefaultTemperature__c = 0.1,
            MaxResponseTokens__c = 2048,
            IsActive__c = true
        );
        configs.add(gpt5MiniConfig);

        // gpt-5-nano: fastest, most cost-efficient GPT-5 — good starting point for simple agents
        LLMConfiguration__c gpt5NanoConfig = new LLMConfiguration__c(
            Name = 'OpenAI GPT-5 Nano',
            DeveloperName__c = 'OpenAI_GPT5_Nano',
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API',
            DefaultModelIdentifier__c = 'gpt-5-nano',
            DefaultTemperature__c = 0.1,
            MaxResponseTokens__c = 2048,
            IsActive__c = true
        );
        configs.add(gpt5NanoConfig);

        insert configs;

        idMap.put('LLM Config', gpt4oMiniConfig.Id);
        idMap.put('LLM Config GPT4o Mini', gpt4oMiniConfig.Id);
        idMap.put('LLM Config GPT5 Mini', gpt5MiniConfig.Id);
        idMap.put('LLM Config GPT5 Nano', gpt5NanoConfig.Id);

        System.debug('[LLM] ✓ Created ' + configs.size() + ' LLM configurations');
        return gpt4oMiniConfig;
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
            PromptSafetyPreset__c = 'Standard',
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
                false, // No confirmation for async tools
                false,
                true, // Runs asynchronously
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
            'Updates the lead rating field based on qualification analysis. Valid `Rating` values and qualification criteria:\n\n**"Hot"** - High-priority, enterprise leads:\n  • Company: 500+ employees OR ≥$50M annual revenue\n  • Title: C-level, VP, SVP, EVP, or Director\n  • Engagement: 2+ touchpoints (downloads, webinars, demos, multiple page views)\n  • Budget/Timeline: Active budget, specific timeline, urgent need\n  • Example: "VP Operations, 250 employees, $50M revenue, attended 2 webinars, Q2 budget"\n\n**"Warm"** - Mid-market qualified leads:\n  • Company: 50-500 employees OR $5M-$50M revenue\n  • Title: Manager, Senior Manager, Team Lead, Supervisor\n  • Engagement: 1-2 activities (content download, pricing view, form submission)\n  • Budget/Timeline: Exploring, no immediate urgency\n  • Example: "IT Manager, 75 employees, downloaded whitepaper"\n\n**"Cold"** - Low-priority/nurture leads:\n  • Company: <50 employees OR <$5M revenue OR unknown\n  • Title: Coordinator, Associate, Analyst, Junior, or missing\n  • Engagement: Minimal (single page view, generic inquiry)\n  • Budget/Timeline: No budget, price-sensitive, very early stage\n  • Example: "Coordinator, 12 employees, $800K revenue, minimal activity"\n\n**Special Rules:**\n• Strong customer referral: Boost one level\n• Fortune 500: Always Hot\n• 3+ engagement signals: Boost one level\n\nUse this tool IMMEDIATELY after analyzing lead context. DO NOT provide text explanations.',
            '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id","description":"The 18-character Lead ID to update. MUST start with \'00Q\'. Extract from lead context - never fabricate IDs.","examples":["00QXX000004ABCDEF","00Q5500000AbCdEfG"],"pattern":"^00Q[a-zA-Z0-9]{15}$"},"recordData":{"type":"object","properties":{"Rating":{"type":"string","enum":["Hot","Warm","Cold"],"description":"Lead qualification rating based on company size, title seniority, and engagement level. Choose using the criteria in tool description.","examples":["Hot","Warm","Cold"]}},"required":["Rating"],"additionalProperties":false}},"required":["recordId","recordData"],"additionalProperties":false}',
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

    private static void createEmailAgent(Id llmConfigId) {
        AIAgentDefinition__c emailAgent = new AIAgentDefinition__c(
            Name = 'Customer Support Email Agent',
            DeveloperName__c = 'Customer_Support_Email_Agent',
            AgentType__c = 'Email',
            LLMConfiguration__c = llmConfigId,
            // Identity & Instructions
            IdentityPrompt__c = 'You are a professional customer support agent for Acme Corporation. ' +
                'You help customers with their questions, issues, and concerns via email.',
            InstructionsPrompt__c = 'Analyze the customer\'s email and provide a helpful, professional response. ' +
                'Be empathetic and understanding. ' +
                'If the issue requires human escalation or cannot be resolved via email, explain this clearly. ' +
                'Use information from the case history and account context to provide personalized assistance. ' +
                'Keep responses concise but complete.',
            // Memory & Execution Settings
            MemoryStrategy__c = 'Buffer Window',
            EnableToolReasoning__c = false,
            EnableParallelToolCalling__c = false,
            AsyncDispatchType__c = 'Low',
            // Security Settings
            PromptSafetyPreset__c = 'Standard',
            IsActive__c = true
        );
        insert emailAgent;

        List<AgentCapability__c> capabilities = new List<AgentCapability__c>();

        // Get Record Details capability
        capabilities.add(
            new AgentCapability__c(
                AIAgentDefinition__c = emailAgent.Id,
                CapabilityName__c = 'get_case_details',
                Description__c = 'Retrieves detailed information about a case including fields, related contacts, and account data',
                ImplementationType__c = 'Standard',
                StandardActionType__c = 'GetRecordDetails',
                BackendConfiguration__c = JSON.serialize(
                    new Map<String, Object>{
                        'variant' => 'field_list',
                        'objectApiName' => 'Case',
                        'defaultFields' => new List<String>{
                            'Id',
                            'CaseNumber',
                            'Subject',
                            'Description',
                            'Status',
                            'Priority',
                            'Origin',
                            'Type',
                            'Reason',
                            'CreatedDate',
                            'ClosedDate',
                            'OwnerId',
                            'Owner.Name',
                            'ContactId',
                            'Contact.Name',
                            'Contact.Email',
                            'Contact.Phone',
                            'AccountId',
                            'Account.Name'
                        }
                    }
                ),
                Parameters__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'object',
                        'properties' => new Map<String, Object>{
                            'Id' => new Map<String, Object>{
                                'type' => 'string',
                                'description' => 'The 18-character Salesforce Case ID (e.g., 500XXXXXXXXXXXX)'
                            },
                            'CaseNumber' => new Map<String, Object>{ 'type' => 'string', 'description' => 'The human-readable Case Number (e.g., 00001092)' }
                        },
                        'required' => new List<String>{}
                    }
                ),
                ExposureLevel__c = 'External',
                RunAsynchronously__c = false
            )
        );

        // Update Record capability
        capabilities.add(
            new AgentCapability__c(
                AIAgentDefinition__c = emailAgent.Id,
                CapabilityName__c = 'update_case',
                Description__c = 'Updates case fields such as Priority, Status, or custom fields based on email analysis',
                ImplementationType__c = 'Standard',
                StandardActionType__c = 'UpdateRecord',
                BackendConfiguration__c = '{"objectApiName": "Case"}',
                Parameters__c = JSON.serialize(
                    new Map<String, Object>{
                        'type' => 'object',
                        'properties' => new Map<String, Object>{
                            'recordId' => new Map<String, Object>{ 'type' => 'string', 'description' => 'The 18-character Salesforce Case ID to update' },
                            'recordData' => new Map<String, Object>{
                                'type' => 'object',
                                'description' => 'Field values to update (e.g., {"Priority": "High", "Status": "In Progress"})'
                            }
                        },
                        'required' => new List<String>{ 'recordId', 'recordData' }
                    }
                ),
                ExposureLevel__c = 'External',
                RunAsynchronously__c = false
            )
        );

        insert capabilities;

        AgentContextConfig__c caseContext = createContext(emailAgent.Id, 'Case Context', 'CaseContext', 'Case', true, 10);
        insert caseContext;
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

    public static void replaceCapabilitiesWithHttpCallout(Set<String> capabilityNames) {
        System.debug('[Capability Replacement] Starting replacement of capabilities with HTTP callout...');

        // Find existing capabilities to update
        List<AgentCapability__c> capabilities = [
            SELECT Id, CapabilityName__c, Description__c, Parameters__c, ImplementationType__c, ImplementationDetail__c, BackendConfiguration__c
            FROM AgentCapability__c
            WHERE CapabilityName__c IN :capabilityNames
        ];

        for (AgentCapability__c cap : capabilities) {
            cap.ImplementationType__c = 'Apex';
            cap.ImplementationDetail__c = 'ActionJSONPlaceholder';
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
