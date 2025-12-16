/**
 * @description Test script for Case Processing Workflow Agent
 * 
 * This script:
 * 1. Creates test case records with different priorities and scenarios
 * 2. Invokes the Case Processing Workflow agent for each case
 * 3. Displays execution results and tracking IDs
 * 
 * **Prerequisites:**
 * - Run AgentTestDataFactory.createComprehensiveShowcase() first to create agents
 * - Ensure OpenAI API credentials are configured
 * - Chatter must be enabled
 * 
 * **Usage:**
 * Execute this script in Anonymous Apex (Developer Console or VS Code)
 * 
 * @author Sonal
 * @since 2025
 */

public class TestCaseProcessingWorkflow {
    
    /**
     * Main entry point - creates cases and invokes workflow
     */
    public static void execute() {
        System.debug('========================================');
        System.debug('CASE PROCESSING WORKFLOW - TEST SCRIPT');
        System.debug('========================================');
        
        try {
            // Step 1: Verify the workflow agent exists
            verifyWorkflowAgentExists();
            
            // Step 2: Create test cases
            List<Case> testCases = createTestCases();
            System.debug('[TestScript] Created ' + testCases.size() + ' test cases');
            
            // Step 3: Invoke workflow for each case
            invokeWorkflowForCases(testCases);
            
            System.debug('========================================');
            System.debug('TEST SCRIPT COMPLETED SUCCESSFULLY');
            System.debug('========================================');
            
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[TestScript] ERROR: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, '[TestScript] Stack Trace: ' + e.getStackTraceString());
        }
    }
    
    /**
     * Verifies that the Case Processing Workflow agent exists
     */
    private static void verifyWorkflowAgentExists() {
        List<AIAgentDefinition__c> agents = [
            SELECT Id, Name, DeveloperName__c, AgentType__c, IsActive__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c = 'Case_Processing_Workflow'
            LIMIT 1
        ];
        
        if (agents.isEmpty()) {
            throw new TestException(
                'Case Processing Workflow agent not found! ' +
                'Please run AgentTestDataFactory.createComprehensiveShowcase() first.'
            );
        }
        
        AIAgentDefinition__c agent = agents[0];
        if (!agent.IsActive__c) {
            throw new TestException('Case Processing Workflow agent is not active!');
        }
        
        System.debug('[TestScript] ✓ Workflow agent found: ' + agent.Name + ' (ID: ' + agent.Id + ')');
    }
    
    /**
     * Creates test cases for workflow processing
     */
    private static List<Case> createTestCases() {
        System.debug('[TestScript] Creating test cases...');
        
        // Get test accounts (created by AgentTestDataFactory)
        List<Account> accounts = [
            SELECT Id, Name
            FROM Account
            WHERE Name IN ('Acme Corporation', 'Global Logistics Ltd', 'TechStart Innovations')
            ORDER BY Name
        ];
        
        if (accounts.isEmpty()) {
            throw new TestException(
                'Test accounts not found! ' +
                'Please run AgentTestDataFactory.createComprehensiveShowcase() first.'
            );
        }
        
        // Get test contacts
        List<Contact> contacts = [
            SELECT Id, AccountId
            FROM Contact
            WHERE AccountId IN :getAccountIds(accounts)
            LIMIT 3
        ];
        
        // Create diverse test cases
        List<Case> cases = new List<Case>{
            new Case(
                AccountId = accounts[0].Id,
                ContactId = !contacts.isEmpty() ? contacts[0].Id : null,
                Subject = 'Critical: System Performance Degradation',
                Description = 'Our enterprise platform is experiencing severe performance issues. Response times have increased from 2 seconds to over 45 seconds during peak hours. This is affecting 200+ users and causing significant business disruption. We have an active Premium Support Package and need immediate assistance.',
                Status = 'New',
                Priority = 'Medium', // Will be analyzed and potentially changed to High
                Origin = 'Email'
            ),
            new Case(
                AccountId = accounts[1].Id,
                ContactId = contacts.size() > 1 ? contacts[1].Id : null,
                Subject = 'Unable to Generate Monthly Reports',
                Description = 'Since the last update, we cannot generate monthly financial reports. When clicking the Generate Report button, we receive an error message: "Report generation failed - contact support". This is blocking our month-end close process.',
                Status = 'New',
                Priority = 'Medium',
                Origin = 'Web'
            ),
            new Case(
                AccountId = accounts[0].Id,
                ContactId = !contacts.isEmpty() ? contacts[0].Id : null,
                Subject = 'Question about API Rate Limits',
                Description = 'We are planning to increase our API usage and want to understand the current rate limits on our subscription. What are the limits and can we upgrade if needed?',
                Status = 'New',
                Priority = 'Low',
                Origin = 'Web'
            ),
            new Case(
                AccountId = accounts[2].Id,
                ContactId = contacts.size() > 2 ? contacts[2].Id : null,
                Subject = 'Integration Setup Assistance Needed',
                Description = 'We recently purchased Professional Services for implementation and need help configuring the integration with our CRM system. The integration wizard is not recognizing our API credentials.',
                Status = 'New',
                Priority = 'Medium',
                Origin = 'Phone'
            )
        };
        
        insert cases;
        
        // Display created cases
        for (Case c : cases) {
            System.debug('[TestScript] Created Case: ' + c.Subject + ' (ID: ' + c.Id + ')');
        }
        
        return cases;
    }
    
    /**
     * Invokes the workflow agent for cases - supports both single and bulk modes
     */
    private static void invokeWorkflowForCases(List<Case> cases) {
        System.debug('[TestScript] ========================================');
        System.debug('[TestScript] INVOKING WORKFLOW AGENT FOR CASES');
        System.debug('[TestScript] ========================================');
        System.debug('[TestScript] ');
        
        // Display the two available approaches
        System.debug('[TestScript] Available approaches:');
        System.debug('[TestScript] 1. BULK MODE - Process all cases in parallel (RECOMMENDED)');
        System.debug('[TestScript] 2. INDIVIDUAL MODE - Process cases one by one');
        System.debug('[TestScript] ');
        
        // Choose your approach by commenting/uncommenting:
        
        // APPROACH 1: BULK MODE (Recommended for multiple records)
        invokeBulkWorkflow(cases);
        
        // APPROACH 2: INDIVIDUAL MODE (Uncomment to use instead)
        // invokeIndividualWorkflows(cases);
    }
    
    /**
     * BULK MODE: Invokes workflow once with list of case IDs
     * This creates a single BulkExecution record and processes all cases in parallel
     */
    private static void invokeBulkWorkflow(List<Case> cases) {
        System.debug('[TestScript] Using BULK MODE - processing ' + cases.size() + ' cases in parallel');
        System.debug('[TestScript] ');
        
        try {
            // Extract case IDs
            List<Id> caseIds = new List<Id>();
            for (Case c : cases) {
                caseIds.add(c.Id);
                System.debug('[TestScript] • ' + c.Subject + ' (ID: ' + c.Id + ')');
            }
            
            System.debug('[TestScript] ');
            System.debug('[TestScript] Invoking workflow agent with ' + caseIds.size() + ' case IDs...');
            
                // Build execution payload with multiple source records
                AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
                payload.sourceRecordIds = caseIds; // Pass list of IDs for bulk processing
                payload.userId = UserInfo.getUserId();
                payload.userMessage = 'Process these cases through the automated workflow';
                payload.triggerSource = 'Test'; // Valid values: Chat, API, UI, Email, Schedule, DataChange, Workflow, Test
                payload.turnIdentifier = 'bulk-workflow-test-' + String.valueOf(System.now().getTime());
            
            // Invoke the workflow agent (it will detect multiple IDs and use bulk handler)
            AgentExecutionService.ExecutionResult result = 
                AgentExecutionService.startExecution('Case_Processing_Workflow', payload);
            
            // Display results
            System.debug('[TestScript] ');
            if (result.success) {
                System.debug('[TestScript] ✓ BULK WORKFLOW INITIATED SUCCESSFULLY');
                System.debug('[TestScript]   Bulk Execution ID: ' + result.executionId);
                System.debug('[TestScript]   Status: ' + result.status);
                System.debug('[TestScript]   Message: ' + result.message);
                System.debug('[TestScript]   Records Queued: ' + caseIds.size());
            } else {
                System.debug('[TestScript] ✗ Bulk workflow initiation failed');
                System.debug('[TestScript]   Error: ' + result.message);
            }
            
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[TestScript] ✗ Exception invoking bulk workflow: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, '[TestScript]   Stack: ' + e.getStackTraceString());
        }
        
        System.debug('[TestScript] ');
        System.debug('[TestScript] ========================================');
        System.debug('[TestScript] BULK WORKFLOW PROCESSING');
        System.debug('[TestScript] ========================================');
        System.debug('[TestScript] ');
        System.debug('[TestScript] How bulk processing works:');
        System.debug('[TestScript] 1. One BulkExecution__c record tracks overall progress');
        System.debug('[TestScript] 2. Each case gets its own workflow execution (parallel)');
        System.debug('[TestScript] 3. Each workflow runs 2 steps asynchronously');
        System.debug('[TestScript] ');
        System.debug('[TestScript] To monitor bulk execution:');
        System.debug('[TestScript] 1. Navigate to Bulk Executions tab');
        System.debug('[TestScript] 2. Find the most recent BulkExecution record');
        System.debug('[TestScript] 3. View Related Agent Executions to see all workflows');
        System.debug('[TestScript] 4. Each workflow will have 2 child executions (steps)');
        System.debug('[TestScript] ========================================');
    }
    
    /**
     * INDIVIDUAL MODE: Invokes workflow separately for each case
     * Useful for sequential processing or testing individual cases
     */
    private static void invokeIndividualWorkflows(List<Case> cases) {
        System.debug('[TestScript] Using INDIVIDUAL MODE - processing cases sequentially');
        System.debug('[TestScript] ');
        
        Integer caseNumber = 1;
        List<Id> executionIds = new List<Id>();
        
        for (Case c : cases) {
            System.debug('[TestScript] --- Case ' + caseNumber + ' of ' + cases.size() + ' ---');
            System.debug('[TestScript] Subject: ' + c.Subject);
            System.debug('[TestScript] Case ID: ' + c.Id);
            
            try {
                // Build execution payload with single source record
                AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();
                payload.sourceRecordId = c.Id; // Single case ID
                payload.userId = UserInfo.getUserId();
                payload.userMessage = 'Process this case through the automated workflow';
                payload.triggerSource = 'Test'; // Valid values: Chat, API, UI, Email, Schedule, DataChange, Workflow, Test
                payload.turnIdentifier = 'individual-workflow-' + c.Id;
                
                // Invoke the workflow agent
                AgentExecutionService.ExecutionResult result = 
                    AgentExecutionService.startExecution('Case_Processing_Workflow', payload);
                
                // Display results
                if (result.success) {
                    System.debug('[TestScript] ✓ Workflow initiated successfully');
                    System.debug('[TestScript]   Execution ID: ' + result.executionId);
                    System.debug('[TestScript]   Status: ' + result.status);
                    if (result.executionId != null) {
                        executionIds.add(result.executionId);
                    }
                } else {
                    System.debug('[TestScript] ✗ Workflow initiation failed');
                    System.debug('[TestScript]   Error: ' + result.message);
                }
                
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[TestScript] ✗ Exception: ' + e.getMessage());
            }
            
            System.debug('[TestScript] ');
            caseNumber++;
        }
        
        System.debug('[TestScript] ========================================');
        System.debug('[TestScript] Individual workflow invocations completed!');
        System.debug('[TestScript] Total executions initiated: ' + executionIds.size());
        System.debug('[TestScript] ');
        System.debug('[TestScript] To view execution results:');
        System.debug('[TestScript] 1. Navigate to Agent Executions tab');
        System.debug('[TestScript] 2. Look for executions with Type = "Workflow"');
        System.debug('[TestScript] 3. Check child executions for each step');
        System.debug('[TestScript] 4. Review execution logs and tool calls');
        System.debug('[TestScript] ========================================');
    }
    
    /**
     * Helper method to extract account IDs
     */
    private static List<Id> getAccountIds(List<Account> accounts) {
        List<Id> ids = new List<Id>();
        for (Account acc : accounts) {
            ids.add(acc.Id);
        }
        return ids;
    }
    
    /**
     * Custom exception class
     */
    public class TestException extends Exception {}
}

// ========================================
// EXECUTION INSTRUCTIONS
// ========================================
//
// Execute in Anonymous Apex:
// TestCaseProcessingWorkflow.execute();
//
// Expected Output:
// - 4 new case records created
// - 4 workflow executions initiated
// - Each workflow will run 2 steps:
//   Step 1: Case Analysis (get account, get orders, update priority)
//   Step 2: Resolution & Notification (search knowledge, create task, post to chatter)
//
// Monitoring:
// - Navigate to Agent Executions tab in your org
// - Filter by Execution Type = "Workflow"
// - View child executions to see each step
// - Check Chatter for workflow notifications
// - Check Tasks for follow-up items created
//
// ========================================

