@IsTest
private class ActionSearchKnowledgeTest {
    @TestSetup
    static void makeData() {
        // 1. Create LLM and Agent Configuration
        LLMConfiguration__c llmConfig = TestFactory.createLLMConfiguration();
        insert llmConfig;

        AIAgentDefinition__c agent = TestFactory.createAgentDefinition(llmConfig.Id);
        insert agent;

        // 2. Create the Agent Capability with the NEW structured schema
        AgentCapability__c cap = new AgentCapability__c(
            AIAgentDefinition__c = agent.Id,
            CapabilityName__c = 'search_knowledge',
            Description__c = 'Searches for Knowledge articles.',
            Parameters__c = JSON.serialize(
                new Map<String, Object>{
                    'type' => 'object',
                    'properties' => new Map<String, Object>{
                        'searchQuery' => new Map<String, Object>{ 'type' => 'string', 'description' => 'Keywords to search for.' },
                        'articleId' => new Map<String, Object>{
                            'type' => 'string',
                            'format' => 'salesforce-id',
                            'description' => 'A specific article ID.'
                        },
                        'language' => new Map<String, Object>{ 'type' => 'string', 'description' => 'Language code, e.g., en_US.' },
                        'includeDrafts' => new Map<String, Object>{ 'type' => 'boolean', 'description' => 'Include draft articles.' },
                        'maxResults' => new Map<String, Object>{ 'type' => 'integer', 'description' => 'Max results to return.' }
                    }
                }
            ),
            ImplementationType__c = 'Standard',
            StandardActionType__c = 'SearchKnowledge'
        );
        insert cap;

        // 3. Create a Chat Session for context
        AgentExecution__c session = TestFactory.createChatSession(agent.Id, UserInfo.getUserId());
        insert session;

        // 4. Create Knowledge Articles for testing
        List<Knowledge__kav> articlesToInsert = new List<Knowledge__kav>();
        articlesToInsert.add(
            new Knowledge__kav(
                Title = 'Online Test Article about Apex',
                UrlName = 'Online-Test-Article-Apex',
                Summary = 'This is the summary for the online test article.',
                Language = 'en_US'
            )
        );
        articlesToInsert.add(
            new Knowledge__kav(
                Title = 'Draft Test Article about LWC',
                UrlName = 'Draft-Test-Article-LWC',
                Summary = 'This summary is for a draft article.',
                Language = 'en_US'
            )
        );
        insert articlesToInsert;

        // The publish action must be done between Test.startTest() and Test.stopTest()
        Test.startTest();
        Id onlineArticleToPublish = [SELECT KnowledgeArticleId FROM Knowledge__kav WHERE Title = 'Online Test Article about Apex' LIMIT 1]
        .KnowledgeArticleId;
        KbManagement.PublishingService.publishArticle(onlineArticleToPublish, true);
        Test.stopTest();
    }

    /**
     * Helper to create a standard ActionContext for executing the action.
     */
    private static ActionContext createTestActionContext() {
        Id agentId = [SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id;
        Id capabilityId = [SELECT Id FROM AgentCapability__c WHERE CapabilityName__c = 'search_knowledge' LIMIT 1].Id;
        Id sessionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;

        return new ActionContext(
            sessionId,
            UserInfo.getUserId(),
            UserInfo.getUserId(),
            null,
            agentId,
            capabilityId,
            null,
            'turn-123',
            1,
            'Conversational'
        );
    }

    @IsTest
    static void executeAction_searchByKeywords_returnsOnlineArticle() {
        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{ 'searchQuery' => 'online summary' };

        Id onlineArticleId = [SELECT Id FROM Knowledge__kav WHERE Title = 'Online Test Article about Apex' LIMIT 1].Id;
        Test.setFixedSearchResults(new List<Id>{ onlineArticleId });

        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestActionContext());
        Test.stopTest();

        System.assert(outcome.isSuccess, 'Action should succeed');

        ActionSearchKnowledge.KnowledgeSearchResult searchResult = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(1, searchResult.count, 'Should find one article');
        System.assertEquals(onlineArticleId, searchResult.articles[0].get('id'), 'Should return the correct online article ID');
        System.assert(searchResult.message.contains('Found 1'), 'Message should reflect one result');
    }

    @IsTest
    static void executeAction_searchById_returnsCorrectArticle() {
        Id onlineArticleId = [SELECT Id FROM Knowledge__kav WHERE Title = 'Online Test Article about Apex' LIMIT 1].Id;

        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{ 'articleId' => onlineArticleId, 'language' => 'en_US' };

        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestActionContext());
        Test.stopTest();

        System.assert(outcome.isSuccess, 'Action should succeed');

        ActionSearchKnowledge.KnowledgeSearchResult searchResult = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(1, searchResult.count, 'Should find one article');
        System.assertEquals(onlineArticleId, searchResult.articles[0].get('id'), 'Should return the correct article ID');
    }

    @IsTest
    static void executeAction_searchWithDrafts_returnsDraftArticle() {
        Id draftArticleId = [SELECT Id FROM Knowledge__kav WHERE Title = 'Draft Test Article about LWC' LIMIT 1].Id;

        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{ 'searchQuery' => 'draft summary', 'includeDrafts' => true };

        Test.setFixedSearchResults(new List<Id>{ draftArticleId });

        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestActionContext());
        Test.stopTest();

        System.assert(outcome.isSuccess, 'Action should succeed');

        ActionSearchKnowledge.KnowledgeSearchResult searchResult = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(1, searchResult.count, 'Should find one draft article');
        System.assertEquals(draftArticleId, searchResult.articles[0].get('id'), 'Should return the correct draft article ID');
    }

    @IsTest
    static void executeAction_searchWithoutDrafts_filtersDraftArticle() {
        Id draftArticleId = [SELECT Id FROM Knowledge__kav WHERE Title = 'Draft Test Article about LWC' LIMIT 1].Id;

        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{ 'searchQuery' => 'draft summary', 'includeDrafts' => false };

        Test.setFixedSearchResults(new List<Id>{ draftArticleId });

        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestActionContext());
        Test.stopTest();

        System.assert(outcome.isSuccess, 'Action should succeed even with no results');

        ActionSearchKnowledge.KnowledgeSearchResult searchResult = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(0, searchResult.count, 'Should find no articles as the draft is filtered out');
    }

    @IsTest
    static void executeAction_failure_missingRequiredParameters() {
        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{};

        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestActionContext());
        Test.stopTest();

        System.assert(!outcome.isSuccess, 'Action should fail without required parameters');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode, 'Error code should be for validation');
        System.assert(outcome.errorMessage.contains('Either "searchQuery" or "articleId" must be provided'), 'Error message should be specific');
    }

    @IsTest
    static void executeAction_noResultsFound() {
        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{ 'searchQuery' => 'query with no results' };

        Test.setFixedSearchResults(new List<Id>());

        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestActionContext());
        Test.stopTest();

        System.assert(outcome.isSuccess, 'An empty search result is a successful operation');

        ActionSearchKnowledge.KnowledgeSearchResult searchResult = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(0, searchResult.count, 'Should find zero articles');
        System.assert(searchResult.message.contains('Found 0'), 'Message should reflect zero results');
    }
}
