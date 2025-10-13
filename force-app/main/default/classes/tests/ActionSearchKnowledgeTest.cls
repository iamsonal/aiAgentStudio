/**
 * @description Tests for ActionSearchKnowledge using TestFactory utilities
 */
@IsTest
private class ActionSearchKnowledgeTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        // Create agent setup
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        // Create test search knowledge capability
        TestFactory.newCapability()
            .withAgent(setup.agentDefinition.Id)
            .forSearchKnowledge()
            .withName('test_search_knowledge')
            .save();

        // Create Knowledge Articles
        List<Knowledge__kav> articles = new List<Knowledge__kav>{
            new Knowledge__kav(
                Title = 'Online Article about Apex',
                UrlName = 'Online-Article-Apex',
                Summary = 'Summary for online article',
                Language = 'en_US'
            ),
            new Knowledge__kav(
                Title = 'Draft Article about LWC',
                UrlName = 'Draft-Article-LWC',
                Summary = 'Summary for draft article',
                Language = 'en_US'
            )
        };
        insert articles;

        // Publish one article
        Test.startTest();
        Id onlineArticleId = [SELECT KnowledgeArticleId FROM Knowledge__kav
                             WHERE Title = 'Online Article about Apex' LIMIT 1].KnowledgeArticleId;
        KbManagement.PublishingService.publishArticle(onlineArticleId, true);
        Test.stopTest();
    }

    private static ActionContext createTestContext() {
        Id agentId = [SELECT Id FROM AIAgentDefinition__c LIMIT 1].Id;
        Id sessionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        Id capabilityId = [SELECT Id FROM AgentCapability__c WHERE CapabilityName__c = 'test_search_knowledge' LIMIT 1].Id;

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

    // ===================================================================================
    // SUCCESS SCENARIOS
    // ===================================================================================

    @IsTest
    static void testSearchKnowledge_ByKeywords_Success() {
        // Given: Search by keywords
        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{
            'searchQuery' => 'online summary'
        };

        Id articleId = [SELECT Id FROM Knowledge__kav WHERE Title LIKE '%Online%' LIMIT 1].Id;
        Test.setFixedSearchResults(new List<Id>{articleId});

        // When: Searching
        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should find article
        System.assert(outcome.isSuccess);
        ActionSearchKnowledge.KnowledgeSearchResult result = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(1, result.count);
        System.assert(result.message.contains('Found 1'));
    }

    @IsTest
    static void testSearchKnowledge_ById_Success() {
        // Given: Search by ID
        Id articleId = [SELECT Id FROM Knowledge__kav WHERE Title LIKE '%Online%' LIMIT 1].Id;

        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{
            'articleId' => articleId,
            'language' => 'en_US'
        };

        // When: Searching by ID
        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should find article
        System.assert(outcome.isSuccess);
        ActionSearchKnowledge.KnowledgeSearchResult result = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(1, result.count);
    }

    @IsTest
    static void testSearchKnowledge_WithDrafts_Success() {
        // Given: Search including drafts
        Id draftId = [SELECT Id FROM Knowledge__kav WHERE Title LIKE '%Draft%' LIMIT 1].Id;
        Test.setFixedSearchResults(new List<Id>{draftId});

        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{
            'searchQuery' => 'draft',
            'includeDrafts' => true
        };

        // When: Searching with drafts
        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should find draft
        System.assert(outcome.isSuccess);
        ActionSearchKnowledge.KnowledgeSearchResult result = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(1, result.count);
    }

    @IsTest
    static void testSearchKnowledge_WithoutDrafts_FiltersDrafts() {
        // Given: Search excluding drafts
        Id draftId = [SELECT Id FROM Knowledge__kav WHERE Title LIKE '%Draft%' LIMIT 1].Id;
        Test.setFixedSearchResults(new List<Id>{draftId});

        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{
            'searchQuery' => 'draft',
            'includeDrafts' => false
        };

        // When: Searching without drafts
        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should filter out draft
        System.assert(outcome.isSuccess);
        ActionSearchKnowledge.KnowledgeSearchResult result = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(0, result.count, 'Draft should be filtered');
    }

    // ===================================================================================
    // FAILURE SCENARIOS
    // ===================================================================================

    @IsTest
    static void testSearchKnowledge_MissingParams_Failure() {
        // Given: No search parameters
        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>();

        // When: Searching without params
        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should fail validation
        System.assert(!outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('Either "searchQuery" or "articleId" must be provided'));
    }

    @IsTest
    static void testSearchKnowledge_NoResults_Success() {
        // Given: Query with no results
        ActionSearchKnowledge action = new ActionSearchKnowledge();
        Map<String, Object> params = new Map<String, Object>{
            'searchQuery' => 'nonexistent query'
        };
        Test.setFixedSearchResults(new List<Id>());

        // When: Searching
        Test.startTest();
        ActionOutcome outcome = action.execute(null, JSON.serialize(params), createTestContext());
        Test.stopTest();

        // Then: Should succeed with empty results
        System.assert(outcome.isSuccess, 'Empty result is success');
        ActionSearchKnowledge.KnowledgeSearchResult result = (ActionSearchKnowledge.KnowledgeSearchResult) outcome.data;
        System.assertEquals(0, result.count);
    }
}
