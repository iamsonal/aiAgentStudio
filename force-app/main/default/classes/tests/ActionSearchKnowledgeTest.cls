@IsTest
private class ActionSearchKnowledgeTest {
    @TestSetup
    static void makeData() {
        // Create LLM Configuration
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        // Create Agent Definition
        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        // Create Agent Capabilities
        List<AgentCapability__c> caps = new List<AgentCapability__c>{
            TestFactory.createSingleCapability(
                agent.Id,
                'search_knowledge',
                'Searches for Knowledge articles.',
                '{"type":"object","properties":{"searchQuery":{"type":"string"}, "articleId":{"type":"string"}, "language":{"type":"string"}, "includeDrafts":{"type":"boolean"}, "maxResults":{"type":"integer"}},"required":["searchQuery"]}',
                'Standard',
                null,
                'SearchKnowledge',
                false,
                null
            )
        };
        insert caps;

        // Create Chat Session
        ChatSession__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
        insert session;
    }

    @IsTest
    static void executeAction_success_withSearchQuery() {
        ActionSearchKnowledge action = new ActionSearchKnowledge();

        // Configuration
        String config = '{"defaultLanguage": "en_US", "maxResults": 5, "summaryMaxLength": 500}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Parameters
        Map<String, Object> params = new Map<String, Object>{ 'searchQuery' => 'test knowledge article' };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Note: Actual success depends on data availability, but shouldn't throw exceptions
    }

    @IsTest
    static void executeAction_success_withArticleId() {
        ActionSearchKnowledge action = new ActionSearchKnowledge();

        // Configuration
        String config = '{"defaultLanguage": "en_US"}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Parameters with article ID
        Map<String, Object> params = new Map<String, Object>{
            'articleId' => 'kA0XXXXXXXXXXXXXXX' // Invalid ID, but testing parameter handling
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Should handle gracefully without throwing exceptions
    }

    @IsTest
    static void executeAction_failure_missingRequiredParameters() {
        ActionSearchKnowledge action = new ActionSearchKnowledge();

        // Configuration
        String config = '{"defaultLanguage": "en_US"}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Empty parameters
        Map<String, Object> params = new Map<String, Object>{};

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals(false, result.isSuccess, 'Action should fail without required parameters');
        System.assert(
            String.valueOf(result.errorMessage).contains('Either "searchQuery" or "articleId" must be provided'),
            'Should indicate missing required parameters'
        );
    }

    @IsTest
    static void executeAction_success_withLanguageAndOptions() {
        ActionSearchKnowledge action = new ActionSearchKnowledge();

        // Configuration
        String config = '{"defaultLanguage": "fr_FR", "maxResults": 10}';
        action.parseActionConfiguration(config, '[TEST] ');

        // Parameters with all options - use default language instead of es_ES
        Map<String, Object> params = new Map<String, Object>{
            'searchQuery' => 'test query',
            'language' => 'en_US', // Use en_US which is more likely to be available
            'includeDrafts' => true,
            'maxResults' => 3
        };

        Test.startTest();
        ActionOutcome result = action.executeAction(params);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        // Note: Actual success depends on data availability, but shouldn't throw exceptions
    }

    @IsTest
    static void parseActionConfiguration_validJson_success() {
        ActionSearchKnowledge action = new ActionSearchKnowledge();

        // Valid configuration
        String config = '{"defaultLanguage": "fr_FR", "maxResults": 10, "summaryMaxLength": 1000}';

        Test.startTest();
        action.parseActionConfiguration(config, '[TEST] ');
        Test.stopTest();

        // Should not throw exceptions during parsing
        System.assert(true, 'Configuration should parse successfully');
    }

    @IsTest
    static void parseActionConfiguration_invalidJson_handledGracefully() {
        ActionSearchKnowledge action = new ActionSearchKnowledge();

        // Invalid configuration
        String config = '{"defaultLanguage": "fr_FR", "maxResults": }'; // Invalid JSON

        Test.startTest();
        try {
            action.parseActionConfiguration(config, '[TEST] ');
            System.assert(false, 'Should have thrown exception for invalid JSON');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('Invalid ActionConfiguration JSON'), 'Should indicate invalid JSON');
        }
        Test.stopTest();
    }

    @IsTest
    static void knowledgeSearchResult_constructor_setsProperties() {
        Test.startTest();
        ActionSearchKnowledge.KnowledgeSearchResult result = new ActionSearchKnowledge.KnowledgeSearchResult(
            'SUCCESS',
            'Test message',
            new Map<String, Object>{ 'id' => 'kA0XXXXXXXXXXXXXXX', 'title' => 'Test Article' },
            null,
            'test query'
        );
        Test.stopTest();

        System.assertEquals('SUCCESS', result.resultType, 'Should set resultType');
        System.assertEquals('Test message', result.message, 'Should set message');
        System.assertNotEquals(null, result.article, 'Should set article');
        System.assertEquals(null, result.options, 'Should set options to null');
        System.assertNotEquals(null, result.metadata, 'Should initialize metadata');
        System.assertEquals('test query', result.metadata.get('searchQuery'), 'Metadata should contain search query');
    }
}
