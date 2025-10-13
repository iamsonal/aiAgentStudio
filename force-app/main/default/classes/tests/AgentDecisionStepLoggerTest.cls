/**
 * @description Tests for AgentDecisionStepLogger using TestFactory utilities
 */
@IsTest
private class AgentDecisionStepLoggerTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();
    }

    // ===================================================================================
    // CONSTRUCTOR TESTS
    // ===================================================================================

    @IsTest
    static void testConstructor_WithSessionAndTurn_Success() {
        // Given: Session and turn identifier
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        String turnId = 'test-turn-001';

        // When: Creating logger
        Test.startTest();
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(session.Id, turnId);
        Test.stopTest();

        // Then: Logger should be created
        System.assertNotEquals(null, logger);
    }

    @IsTest
    static void testConstructor_WithAllParams_Success() {
        // Given: Session, turn, and user
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        String turnId = 'test-turn-002';

        // When: Creating logger with user ID
        Test.startTest();
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(
            session.Id,
            turnId,
            UserInfo.getUserId()
        );
        Test.stopTest();

        // Then: Logger should be created
        System.assertNotEquals(null, logger);
    }

    // ===================================================================================
    // LOG METHOD TESTS
    // ===================================================================================

    @IsTest
    static void testLogUserInput_CreatesStep() {
        // Given: Logger instance
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        String turnId = 'test-turn-003';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(session.Id, turnId);

        // When: Logging user input
        Test.startTest();
        logger.logUserInput('User Input', 'Hello, how are you?', 100);
        logger.commitSteps();
        Test.stopTest();

        // Then: Step should be created
        List<AgentDecisionStep__c> steps = [SELECT StepType__c, Title__c, ContentJson__c
                                            FROM AgentDecisionStep__c
                                            WHERE AgentExecution__c = :session.Id];
        System.assertEquals(1, steps.size());
        System.assertEquals('User Input', steps[0].StepType__c);
        System.assertEquals('Hello, how are you?', steps[0].ContentJson__c);
    }

    @IsTest
    static void testLogMultipleSteps_MaintainsOrder() {
        // Given: Logger with multiple steps
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        String turnId = 'test-turn-004';
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(session.Id, turnId);

        // When: Logging multiple steps
        Test.startTest();
        logger.logUserInput('User Input', 'Hello', 100);
        logger.logContextGathering('Context', 'Context data', '{"userId":"123"}', 200);
        logger.logLLMRequest('LLM Request', 'Request sent', '{"prompt":"Hello"}', 300);
        logger.commitSteps();
        Test.stopTest();

        // Then: Steps should be ordered
        List<AgentDecisionStep__c> steps = [SELECT StepType__c, StepOrder__c
                                            FROM AgentDecisionStep__c
                                            WHERE AgentExecution__c = :session.Id
                                            ORDER BY StepOrder__c];
        System.assertEquals(3, steps.size());
        System.assertEquals('User Input', steps[0].StepType__c);
        System.assertEquals('Context Gathering', steps[1].StepType__c);
        System.assertEquals('LLM Request', steps[2].StepType__c);
    }

    @IsTest
    static void testLogToolExecution_WithSuccess() {
        // Given: Logger instance
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(session.Id, 'turn-005');

        // When: Logging successful tool execution
        Test.startTest();
        logger.logToolExecution('Tool Exec', 'Calculator', '{"input":"2+2"}', 200, true, null, null);
        logger.commitSteps();
        Test.stopTest();

        // Then: Step should show success
        List<AgentDecisionStep__c> steps = [SELECT IsSuccess__c FROM AgentDecisionStep__c WHERE AgentExecution__c = :session.Id];
        System.assertEquals(true, steps[0].IsSuccess__c);
    }

    @IsTest
    static void testLogError_CreatesErrorStep() {
        // Given: Logger instance
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(session.Id, 'turn-006');

        // When: Logging error
        Test.startTest();
        logger.logError('Error', 'Failed', 'ERR_CODE', 'Error message', '{}', 50);
        logger.commitSteps();
        Test.stopTest();

        // Then: Error step should be created
        List<AgentDecisionStep__c> steps = [SELECT StepType__c, IsSuccess__c, ErrorCode__c
                                            FROM AgentDecisionStep__c
                                            WHERE AgentExecution__c = :session.Id];
        System.assertEquals('Error', steps[0].StepType__c);
        System.assertEquals(false, steps[0].IsSuccess__c);
        System.assertEquals('ERR_CODE', steps[0].ErrorCode__c);
    }

    @IsTest
    static void testCommitSteps_WithNoSteps_HandlesGracefully() {
        // Given: Logger with no steps
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentDecisionStepLogger logger = new AgentDecisionStepLogger(session.Id, 'turn-007');

        // When: Committing with no steps
        Test.startTest();
        logger.commitSteps();
        Test.stopTest();

        // Then: No steps should be created
        List<AgentDecisionStep__c> steps = [SELECT Id FROM AgentDecisionStep__c
                                            WHERE AgentExecution__c = :session.Id];
        System.assertEquals(0, steps.size());
    }
}
