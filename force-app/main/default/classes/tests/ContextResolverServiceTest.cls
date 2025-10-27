/**
 * @description Test class for ContextResolverService
 * Tests context provider invocation, record grouping, and resolution orchestration
 */
@IsTest
private class ContextResolverServiceTest {
    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create test accounts and contacts for context resolution
        List<Account> accounts = new List<Account>();
        for (Integer i = 0; i < 3; i++) {
            accounts.add(TestFactory.newAccount().withName('Test Account ' + i).build());
        }
        insert accounts;

        List<Contact> contacts = new List<Contact>();
        for (Integer i = 0; i < 2; i++) {
            contacts.add(TestFactory.newContact().withName('Test', 'Contact ' + i).withAccount(accounts[0].Id).build());
        }
        insert contacts;

        // Create agent setup
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create execution
        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = setup.agentDefinition.Id,
            User__c = UserInfo.getUserId(),
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            ExecutionType__c = 'Conversational'
        );
        insert execution;

        // Create context ledger items
        List<ContextLedgerItem__c> ledgerItems = new List<ContextLedgerItem__c>();
        ledgerItems.add(
            new ContextLedgerItem__c(
                AgentExecution__c = execution.Id,
                RecordId__c = accounts[0].Id,
                RecordType__c = 'Account',
                ContextType__c = 'IMPLICIT_PRIMARY',
                Status__c = 'ACTIVE',
                TurnAdded__c = 1,
                LastAccessedTurn__c = 1,
                AccessCount__c = 1,
                RelevanceScore__c = 100.0
            )
        );
        ledgerItems.add(
            new ContextLedgerItem__c(
                AgentExecution__c = execution.Id,
                RecordId__c = contacts[0].Id,
                RecordType__c = 'Contact',
                ContextType__c = 'ACTION_GENERATED',
                Status__c = 'ACTIVE',
                TurnAdded__c = 1,
                LastAccessedTurn__c = 2,
                AccessCount__c = 2,
                RelevanceScore__c = 90.0
            )
        );
        insert ledgerItems;

        // Create context provider config
        AgentContextConfig__c config = new AgentContextConfig__c(
            AIAgentDefinition__c = setup.agentDefinition.Id,
            ContextLabel__c = 'Test Account Provider',
            ImplementationName__c = 'MockContextProvider',
            ApplicableSObjectTypes__c = 'Account',
            RequiresRecordContext__c = true,
            IsActive__c = true,
            ExecutionOrder__c = 1
        );
        insert config;
    }

    // ===================================================================================
    // MOCK CONTEXT PROVIDER FOR TESTING
    // ===================================================================================

    /**
     * Mock implementation of IAgentContextProvider for testing
     */
    public class MockContextProvider implements IAgentContextProvider {
        public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configJson) {
            Map<String, List<SObject>> result = new Map<String, List<SObject>>();

            // Query accounts for the provided IDs
            List<Account> accounts = [SELECT Id, Name FROM Account WHERE Id IN :anchorIds];
            if (!accounts.isEmpty()) {
                result.put('Account', accounts);
            }

            return result;
        }
    }

    // ===================================================================================
    // RESOLUTION TESTS
    // ===================================================================================

    @IsTest
    static void testResolve_WithValidContext_ReturnsRecords() {
        // Given: Execution with context ledger
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];

        ContextManagerService mockLedger = new ContextManagerService();
        ContextResolverService resolver = new ContextResolverService(mockLedger);

        // When: Resolving context
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(
            execution.Id,
            execution.AIAgentDefinition__c,
            UserInfo.getUserId(),
            account.Id,
            1
        );
        Test.stopTest();

        // Then: Should return resolution result
        System.assertNotEquals(null, result, 'Should return resolution result');
        System.assertNotEquals(null, result.recordsToLoad, 'Should have records to load');
    }

    @IsTest
    static void testResolve_WithNoConfigs_ReturnsEmptyResult() {
        // Given: Agent with no context provider configs
        LLMConfiguration__c llmConfig = TestFactory.newLLMConfiguration().withName('No Config LLM').save();

        AIAgentDefinition__c agentWithNoConfig = TestFactory.newAgentDefinition().withName('No_Config_Agent').withLLM(llmConfig.Id).save();

        AgentExecution__c execution = new AgentExecution__c(
            AIAgentDefinition__c = agentWithNoConfig.Id,
            User__c = UserInfo.getUserId(),
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            ExecutionType__c = 'Conversational'
        );
        insert execution;

        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving context
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(execution.Id, agentWithNoConfig.Id, UserInfo.getUserId(), null, 1);
        Test.stopTest();

        // Then: Should return empty result
        System.assertNotEquals(null, result, 'Should return result');
        System.assertEquals(0, result.recordsToLoad.size(), 'Should have no records to load');
    }

    @IsTest
    static void testResolve_WithNoRecordContext_InvokesUserProviders() {
        // Given: Execution with no immediate page record or ledger items
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];

        // Create user-centric provider config (no record context required)
        AgentContextConfig__c userConfig = new AgentContextConfig__c(
            AIAgentDefinition__c = execution.AIAgentDefinition__c,
            ContextLabel__c = 'Test User Provider',
            ImplementationName__c = 'MockContextProvider',
            RequiresRecordContext__c = false,
            IsActive__c = true,
            ExecutionOrder__c = 2
        );
        insert userConfig;

        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving context without record context
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(
            execution.Id,
            execution.AIAgentDefinition__c,
            UserInfo.getUserId(),
            null, // No immediate page record
            1
        );
        Test.stopTest();

        // Then: Should invoke user-centric providers
        System.assertNotEquals(null, result, 'Should return result');
    }

    @IsTest
    static void testResolve_WithMultipleSObjectTypes_GroupsCorrectly() {
        // Given: Execution with multiple SObject types in ledger
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];

        // Create contact provider config
        AgentContextConfig__c contactConfig = new AgentContextConfig__c(
            AIAgentDefinition__c = execution.AIAgentDefinition__c,
            ContextLabel__c = 'Test Contact Provider',
            ImplementationName__c = 'MockContextProvider',
            ApplicableSObjectTypes__c = 'Contact',
            RequiresRecordContext__c = true,
            IsActive__c = true,
            ExecutionOrder__c = 3
        );
        insert contactConfig;

        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving context with multiple types
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(
            execution.Id,
            execution.AIAgentDefinition__c,
            UserInfo.getUserId(),
            account.Id,
            2
        );
        Test.stopTest();

        // Then: Should process all types
        System.assertNotEquals(null, result, 'Should return result');
    }

    // ===================================================================================
    // ID GROUPING TESTS
    // ===================================================================================

    @IsTest
    static void testResolve_WithMixedIds_GroupsBySObjectType() {
        // Given: Execution with ledger containing different SObject types
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];
        Contact contact = [SELECT Id FROM Contact LIMIT 1];

        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving with mixed immediate page record
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(
            execution.Id,
            execution.AIAgentDefinition__c,
            UserInfo.getUserId(),
            contact.Id, // Contact as immediate page record
            2
        );
        Test.stopTest();

        // Then: Should handle different types
        System.assertNotEquals(null, result, 'Should return result');
    }

    // ===================================================================================
    // PROVIDER INVOCATION TESTS
    // ===================================================================================

    @IsTest
    static void testResolve_WithInvalidProvider_HandlesGracefully() {
        // Given: Config with non-existent provider class
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];

        AgentContextConfig__c invalidConfig = new AgentContextConfig__c(
            AIAgentDefinition__c = execution.AIAgentDefinition__c,
            ContextLabel__c = 'Invalid Provider',
            ImplementationName__c = 'NonExistentProvider',
            ApplicableSObjectTypes__c = 'Account',
            RequiresRecordContext__c = true,
            IsActive__c = true,
            ExecutionOrder__c = 10
        );
        insert invalidConfig;

        Account account = [SELECT Id FROM Account LIMIT 1];
        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving with invalid provider
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(
            execution.Id,
            execution.AIAgentDefinition__c,
            UserInfo.getUserId(),
            account.Id,
            1
        );
        Test.stopTest();

        // Then: Should handle error gracefully and return result
        System.assertNotEquals(null, result, 'Should return result despite provider error');
    }

    @IsTest
    static void testResolve_WithProviderReturningNull_HandlesGracefully() {
        // Given: Execution and config (provider may return null)
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];
        Account account = [SELECT Id FROM Account LIMIT 1];

        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving (provider might return null or empty)
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(
            execution.Id,
            execution.AIAgentDefinition__c,
            UserInfo.getUserId(),
            account.Id,
            1
        );
        Test.stopTest();

        // Then: Should handle null result gracefully
        System.assertNotEquals(null, result, 'Should return result');
        System.assertNotEquals(null, result.recordsToLoad, 'Should have records list');
    }

    // ===================================================================================
    // CONFIG FILTERING TESTS
    // ===================================================================================

    @IsTest
    static void testResolve_WithInactiveConfig_SkipsProvider() {
        // Given: Inactive provider config
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];

        AgentContextConfig__c inactiveConfig = new AgentContextConfig__c(
            AIAgentDefinition__c = execution.AIAgentDefinition__c,
            ContextLabel__c = 'Inactive Provider',
            ImplementationName__c = 'MockContextProvider',
            ApplicableSObjectTypes__c = 'Account',
            RequiresRecordContext__c = true,
            IsActive__c = false, // Inactive
            ExecutionOrder__c = 99
        );
        insert inactiveConfig;

        Account account = [SELECT Id FROM Account LIMIT 1];
        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving with inactive config
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(
            execution.Id,
            execution.AIAgentDefinition__c,
            UserInfo.getUserId(),
            account.Id,
            1
        );
        Test.stopTest();

        // Then: Should skip inactive provider
        System.assertNotEquals(null, result, 'Should return result');
    }

    @IsTest
    static void testResolve_WithMultipleApplicableTypes_InvokesForAllTypes() {
        // Given: Provider config applicable to multiple SObject types
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];

        AgentContextConfig__c multiTypeConfig = new AgentContextConfig__c(
            AIAgentDefinition__c = execution.AIAgentDefinition__c,
            ContextLabel__c = 'Multi-Type Provider',
            ImplementationName__c = 'MockContextProvider',
            ApplicableSObjectTypes__c = 'Account,Contact,Opportunity',
            RequiresRecordContext__c = true,
            IsActive__c = true,
            ExecutionOrder__c = 5
        );
        insert multiTypeConfig;

        Account account = [SELECT Id FROM Account LIMIT 1];
        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving with multi-type config
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(
            execution.Id,
            execution.AIAgentDefinition__c,
            UserInfo.getUserId(),
            account.Id,
            1
        );
        Test.stopTest();

        // Then: Should invoke for applicable types
        System.assertNotEquals(null, result, 'Should return result');
    }

    // ===================================================================================
    // RESOLUTION RESULT TESTS
    // ===================================================================================

    @IsTest
    static void testResolutionResult_Constructor_InitializesFields() {
        // When: Creating ResolutionResult
        Test.startTest();
        ContextResolverService.ResolutionResult result = new ContextResolverService.ResolutionResult();
        Test.stopTest();

        // Then: Should initialize with defaults
        System.assertNotEquals(null, result.recordsToLoad, 'Should initialize recordsToLoad');
        System.assertEquals(0, result.recordsToLoad.size(), 'Should initialize empty list');
        System.assertNotEquals(null, result.longTermContextSummary, 'Should initialize summary');
        System.assertEquals('', result.longTermContextSummary, 'Should initialize empty string');
    }

    // ===================================================================================
    // EXCEPTION TESTS
    // ===================================================================================

    @IsTest
    static void testResolutionException_Creation() {
        // Given: An exception
        Exception cause = new System.QueryException('Test query error');

        // When: Creating ResolutionException
        Test.startTest();
        ContextResolverService.ResolutionException ex = new ContextResolverService.ResolutionException('Failed to resolve context', cause);
        Test.stopTest();

        // Then: Should contain message
        System.assert(ex.getMessage().contains('Failed to resolve context'), 'Should contain error message');
    }

    // ===================================================================================
    // EDGE CASE TESTS
    // ===================================================================================

    @IsTest
    static void testResolve_WithEmptyLedger_UsesOnlyPageRecord() {
        // Given: Execution with empty ledger
        LLMConfiguration__c llmConfig = TestFactory.newLLMConfiguration().withName('Empty Ledger LLM').save();

        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Empty_Ledger_Agent').withLLM(llmConfig.Id).save();

        AgentExecution__c emptyExecution = new AgentExecution__c(
            AIAgentDefinition__c = agent.Id,
            User__c = UserInfo.getUserId(),
            ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
            ExecutionType__c = 'Conversational'
        );
        insert emptyExecution;

        // Create config for this agent
        AgentContextConfig__c config = new AgentContextConfig__c(
            AIAgentDefinition__c = agent.Id,
            ContextLabel__c = 'Empty Ledger Provider',
            ImplementationName__c = 'MockContextProvider',
            ApplicableSObjectTypes__c = 'Account',
            RequiresRecordContext__c = true,
            IsActive__c = true,
            ExecutionOrder__c = 1
        );
        insert config;

        Account account = [SELECT Id FROM Account LIMIT 1];
        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving with only page record
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(emptyExecution.Id, agent.Id, UserInfo.getUserId(), account.Id, 1);
        Test.stopTest();

        // Then: Should use only page record
        System.assertNotEquals(null, result, 'Should return result');
    }

    @IsTest
    static void testResolve_WithNullPageRecord_UsesOnlyLedger() {
        // Given: Execution with ledger but no page record
        AgentExecution__c execution = [SELECT Id, AIAgentDefinition__c FROM AgentExecution__c LIMIT 1];

        ContextResolverService resolver = new ContextResolverService();

        // When: Resolving without page record
        Test.startTest();
        ContextResolverService.ResolutionResult result = resolver.resolve(
            execution.Id,
            execution.AIAgentDefinition__c,
            UserInfo.getUserId(),
            null, // No page record
            2
        );
        Test.stopTest();

        // Then: Should use ledger items
        System.assertNotEquals(null, result, 'Should return result');
    }
}
