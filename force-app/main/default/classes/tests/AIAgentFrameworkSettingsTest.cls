/**
 * @description Tests for AIAgentFrameworkSettings centralized configuration management.
 * Validates default fallback behavior, field-level defaulting, and all public API methods.
 *
 * Each @IsTest method gets a fresh static context, so the singleton cache resets between tests.
 */
@IsTest
private class AIAgentFrameworkSettingsTest {
    @IsTest
    static void testGetInstance_NoCustomSetting_ReturnsDefaults() {
        AIAgentFrameworkSettings__c instance = AIAgentFrameworkSettings.getInstance();

        System.assertNotEquals(null, instance, 'Should return a settings instance even without a custom setting record');
        System.assertEquals(10, instance.DefaultMaxConversationTurns__c, 'Default max turns should be 10');
        System.assertEquals(2, instance.MaxToolRetries__c, 'Default max retries should be 2');
        System.assertEquals(5, instance.BulkConcurrencyLimit__c, 'Default concurrency should be 5');
        System.assertEquals(5, instance.BulkFailureThreshold__c, 'Default failure threshold should be 5');
        System.assertEquals(true, instance.EnableDecisionStepLogging__c, 'Decision step logging should be enabled by default');
        System.assertEquals(false, instance.ExtendQueueableChainLimit__c, 'Extend chain limit should be false by default');
    }

    @IsTest
    static void testGetInstance_WithCustomSetting_ReturnsConfiguredValues() {
        AIAgentFrameworkSettings__c custom = new AIAgentFrameworkSettings__c(
            DefaultMaxConversationTurns__c = 20,
            MaxToolRetries__c = 5,
            BulkConcurrencyLimit__c = 10,
            BulkFailureThreshold__c = 3,
            EnableDecisionStepLogging__c = false,
            ExtendQueueableChainLimit__c = true,
            MaxLLMCallsPerTransaction__c = 4
        );
        insert custom;

        AIAgentFrameworkSettings__c instance = AIAgentFrameworkSettings.getInstance();

        System.assertEquals(20, instance.DefaultMaxConversationTurns__c, 'Should return configured max turns');
        System.assertEquals(5, instance.MaxToolRetries__c, 'Should return configured max retries');
        System.assertEquals(10, instance.BulkConcurrencyLimit__c, 'Should return configured concurrency limit');
        System.assertEquals(3, instance.BulkFailureThreshold__c, 'Should return configured failure threshold');
    }

    @IsTest
    static void testGetInstance_NullFields_FillsWithDefaults() {
        AIAgentFrameworkSettings__c custom = new AIAgentFrameworkSettings__c(
            DefaultMaxConversationTurns__c = null,
            MaxToolRetries__c = -1,
            BulkConcurrencyLimit__c = 0,
            BulkFailureThreshold__c = -5
        );
        insert custom;

        AIAgentFrameworkSettings__c instance = AIAgentFrameworkSettings.getInstance();

        System.assertEquals(10, instance.DefaultMaxConversationTurns__c, 'Null max turns should default to 10');
        System.assertEquals(2, instance.MaxToolRetries__c, 'Negative retries should default to 2');
        System.assertEquals(5, instance.BulkConcurrencyLimit__c, 'Zero concurrency should default to 5');
        System.assertEquals(5, instance.BulkFailureThreshold__c, 'Negative threshold should default to 5');
    }

    @IsTest
    static void testGetInstance_Singleton_ReturnsSameInstance() {
        AIAgentFrameworkSettings__c first = AIAgentFrameworkSettings.getInstance();
        AIAgentFrameworkSettings__c second = AIAgentFrameworkSettings.getInstance();

        System.assert(first === second, 'Repeated calls should return the same cached instance');
    }

    @IsTest
    static void testGetDefaultMaxConversationTurns_ReturnsInteger() {
        Integer turns = AIAgentFrameworkSettings.getDefaultMaxConversationTurns();

        System.assertEquals(10, turns, 'Default max conversation turns should be 10');
    }

    @IsTest
    static void testGetMaxProcessingCycles_AgentOverride_ReturnsAgentValue() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('Cycles_Agent').withType('Function').withLLM(llm.Id).save();
        agent.MaxProcessingCycles__c = 25;
        update agent;

        Integer cycles = AIAgentFrameworkSettings.getMaxProcessingCycles(agent.DeveloperName__c);

        System.assertEquals(25, cycles, 'Should return agent-specific override');
    }

    @IsTest
    static void testGetMaxProcessingCycles_NoOverride_FallsBackToOrgDefault() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('NoOverride_Agent').withType('Function').withLLM(llm.Id).save();

        Integer cycles = AIAgentFrameworkSettings.getMaxProcessingCycles(agent.DeveloperName__c);

        System.assertEquals(AIAgentFrameworkSettings.getDefaultMaxConversationTurns(), cycles, 'Should fall back to org-wide default');
    }

    @IsTest
    static void testGetMaxProcessingCycles_BlankAgentName_FallsBackToOrgDefault() {
        Integer cycles = AIAgentFrameworkSettings.getMaxProcessingCycles('');

        System.assertEquals(AIAgentFrameworkSettings.getDefaultMaxConversationTurns(), cycles, 'Blank agent name should use org default');
    }

    @IsTest
    static void testGetMaxProcessingCycles_NonexistentAgent_FallsBackToOrgDefault() {
        Integer cycles = AIAgentFrameworkSettings.getMaxProcessingCycles('Agent_That_Does_Not_Exist_123');

        System.assertEquals(AIAgentFrameworkSettings.getDefaultMaxConversationTurns(), cycles, 'Nonexistent agent should fall back to org default');
    }

    @IsTest
    static void testGetMaxToolRetries_ReturnsPositive() {
        Integer retries = AIAgentFrameworkSettings.getMaxToolRetries();

        System.assert(retries > 0, 'Max tool retries should be positive');
        System.assertEquals(2, retries, 'Default max tool retries should be 2');
    }

    @IsTest
    static void testGetBulkConcurrencyLimit_ReturnsAtLeastOne() {
        Integer concurrency = AIAgentFrameworkSettings.getBulkConcurrencyLimit();

        System.assert(concurrency >= 1, 'Bulk concurrency limit should be at least 1');
        System.assertEquals(5, concurrency, 'Default concurrency should be 5');
    }

    @IsTest
    static void testGetBulkFailureThreshold_ReturnsNonNegative() {
        Integer threshold = AIAgentFrameworkSettings.getBulkFailureThreshold();

        System.assert(threshold >= 0, 'Bulk failure threshold should be non-negative');
        System.assertEquals(5, threshold, 'Default failure threshold should be 5');
    }

    @IsTest
    static void testCalculateOptimalWorkerCount_ZeroOrNegative_ReturnsZero() {
        System.assertEquals(0, AIAgentFrameworkSettings.calculateOptimalWorkerCount(0), 'Zero records should return 0 workers');
        System.assertEquals(0, AIAgentFrameworkSettings.calculateOptimalWorkerCount(null), 'Null records should return 0 workers');
        System.assertEquals(0, AIAgentFrameworkSettings.calculateOptimalWorkerCount(-5), 'Negative records should return 0 workers');
    }

    @IsTest
    static void testCalculateOptimalWorkerCount_SmallCount_ReturnsReasonableWorkers() {
        Integer workers = AIAgentFrameworkSettings.calculateOptimalWorkerCount(3);
        System.assert(workers > 0 && workers <= 3, 'Worker count should be between 1 and record count');
    }

    @IsTest
    static void testCalculateOptimalWorkerCount_LargeCount_CappedByLimit() {
        Integer workers = AIAgentFrameworkSettings.calculateOptimalWorkerCount(1000);
        Integer concurrency = AIAgentFrameworkSettings.getBulkConcurrencyLimit();
        System.assert(workers <= concurrency, 'Worker count should not exceed concurrency limit');
        System.assert(workers > 0, 'Large record count should produce at least 1 worker');
    }

    @IsTest
    static void testBooleanFlags_ReturnExpectedDefaults() {
        System.assertEquals(true, AIAgentFrameworkSettings.isDecisionStepLoggingEnabled(), 'Decision step logging should default to enabled');
        System.assertEquals(false, AIAgentFrameworkSettings.shouldExtendQueueableChainLimit(), 'Extend chain limit should default to false');
    }

    @IsTest
    static void testBooleanFlags_WithCustomSetting_ReturnsConfiguredValues() {
        AIAgentFrameworkSettings__c custom = new AIAgentFrameworkSettings__c(EnableDecisionStepLogging__c = false, ExtendQueueableChainLimit__c = true);
        insert custom;

        System.assertEquals(false, AIAgentFrameworkSettings.isDecisionStepLoggingEnabled(), 'Decision step logging should be disabled');
        System.assertEquals(true, AIAgentFrameworkSettings.shouldExtendQueueableChainLimit(), 'Extend chain limit should be true');
    }

    @IsTest
    static void testGetMaxLLMCallsPerTransaction_ReturnsDefault() {
        Integer maxCalls = AIAgentFrameworkSettings.getMaxLLMCallsPerTransaction();

        System.assertEquals(2, maxCalls, 'Default max LLM calls should be 2');
    }

    @IsTest
    static void testGetMaxLLMCallsPerTransaction_WithCustomSetting_ReturnsConfigured() {
        AIAgentFrameworkSettings__c custom = new AIAgentFrameworkSettings__c(MaxLLMCallsPerTransaction__c = 8);
        insert custom;

        Integer maxCalls = AIAgentFrameworkSettings.getMaxLLMCallsPerTransaction();
        System.assertEquals(8, maxCalls, 'Should return configured max LLM calls');
    }

    @IsTest
    static void testGetMaxDependencyViolations_ReturnsThree() {
        Integer violations = AIAgentFrameworkSettings.getMaxDependencyViolations();

        System.assertEquals(3, violations, 'Default max dependency violations should be 3');
    }
}
