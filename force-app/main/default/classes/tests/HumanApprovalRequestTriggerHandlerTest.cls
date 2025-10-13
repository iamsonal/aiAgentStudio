/**
 * @description Tests for HumanApprovalRequestTriggerHandler using TestFactory utilities
 */
@IsTest
private class HumanApprovalRequestTriggerHandlerTest {

    // ===================================================================================
    // TEST SETUP
    // ===================================================================================

    @TestSetup
    static void setupTestData() {
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup()
            .withStandardActions()
            .save();
    }

    // ===================================================================================
    // APPROVAL TESTS
    // ===================================================================================

    @IsTest
    static void testHandleAfterUpdate_Approved_ExecutesAction() {
        // Given: Approval request in pending state
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];

        ExecutionStep__c assistantMessage = new ExecutionStep__c(
            AgentExecution__c = session.Id,
            StepRole__c = AIAgentConstants.ROLE_ASSISTANT,
            Content__c = 'I will search for sales records.',
            ExternalId__c = 'turn-123',
            Timestamp__c = System.now(),
            StepType__c = 'AgentResponse'
        );
        insert assistantMessage;

        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            AgentExecution__c = session.Id,
            OriginalAssistantStep__c = assistantMessage.Id,
            LLMConfirmationMessage__c = 'User requested search',
            LLMToolCallId__c = 'call_123',
            LLMToolName__c = 'find_records',
                LLMToolArgumentsJSON__c = JSON.serialize(new Map<String, Object>{
                        'sObjectTypes' => new List<String>{'Account'},
                        'fieldsToReturn' => new List<String>{'Id', 'Name'},
                        'filters' => new Map<String, Object>{ 'Name' => 'Test Account' }
                }),
            OriginalTurnIdentifier__c = 'turn-123',
            OriginalTurnCount__c = 1,
            ApprovalStatus__c = 'Pending'
        );
        insert har;

        Account testAccount = TestFactory.newAccount().withName('Test Account').save();
        Test.setFixedSearchResults(new List<Id>{testAccount.Id});

        // When: Approving request
        Test.startTest();
        har.ApprovalStatus__c = 'Approved';
        har.ApproverComments__c = 'Approved by manager';
        update har;
        Test.stopTest();

        // Then: Should execute action
        HumanApprovalRequest__c updatedHar = [
            SELECT ApprovalStatus__c, ApproverComments__c
            FROM HumanApprovalRequest__c
            WHERE Id = :har.Id
        ];

        System.assertEquals('Approved', updatedHar.ApprovalStatus__c);
        System.assert(updatedHar.ApproverComments__c.contains('Action completed successfully'));
    }

    @IsTest
    static void testHandleAfterUpdate_Rejected_NotifiesUser() {
        // Given: Pending approval request
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];

        ExecutionStep__c assistantMessage = new ExecutionStep__c(
            AgentExecution__c = session.Id,
            StepRole__c = AIAgentConstants.ROLE_ASSISTANT,
            Content__c = 'I will execute action.',
            ExternalId__c = 'turn-456',
            Timestamp__c = System.now(),
            StepType__c = 'AgentResponse'
        );
        insert assistantMessage;

        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            AgentExecution__c = session.Id,
            OriginalAssistantStep__c = assistantMessage.Id,
            LLMToolCallId__c = 'call_456',
            LLMToolName__c = 'find_records',
            LLMToolArgumentsJSON__c = '{}',
            OriginalTurnIdentifier__c = 'turn-456',
            OriginalTurnCount__c = 1,
            ApprovalStatus__c = 'Pending'
        );
        insert har;

        // When: Rejecting request
        Test.startTest();
        har.ApprovalStatus__c = 'Rejected';
        har.ApproverComments__c = 'Request denied';
        update har;
        Test.stopTest();

        // Then: Should notify user
        HumanApprovalRequest__c updatedHar = [
            SELECT ApprovalStatus__c, ApproverComments__c
            FROM HumanApprovalRequest__c
            WHERE Id = :har.Id
        ];

        System.assertEquals('Rejected', updatedHar.ApprovalStatus__c);
        System.assert(updatedHar.ApproverComments__c.contains('Rejection processed'));

        // Verify tool result message was created
        List<ExecutionStep__c> toolMessages = [
            SELECT ToolCallId__c, ToolResult__c
            FROM ExecutionStep__c
            WHERE AgentExecution__c = :session.Id
            AND StepRole__c = 'tool'
        ];

        System.assertEquals(1, toolMessages.size());
        System.assertEquals('call_456', toolMessages[0].ToolCallId__c);
    }

    @IsTest
    static void testHandleAfterUpdate_MultipleRecords_MixedStatuses() {
        // Given: Multiple pending requests
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];

        List<ExecutionStep__c> assistantMessages = new List<ExecutionStep__c>();
        for (Integer i = 1; i <= 3; i++) {
            assistantMessages.add(new ExecutionStep__c(
                AgentExecution__c = session.Id,
                StepRole__c = AIAgentConstants.ROLE_ASSISTANT,
                Content__c = 'Request ' + i,
                ExternalId__c = 'turn-' + i,
                Timestamp__c = System.now(),
                StepType__c = 'AgentResponse'
            ));
        }
        insert assistantMessages;

        List<HumanApprovalRequest__c> hars = new List<HumanApprovalRequest__c>{
            new HumanApprovalRequest__c(
                AgentExecution__c = session.Id,
                OriginalAssistantStep__c = assistantMessages[0].Id,
                LLMToolCallId__c = 'call_1',
                LLMToolName__c = 'find_records',
                    LLMToolArgumentsJSON__c = JSON.serialize(new Map<String, Object>{
                            'sObjectTypes' => new List<String>{'Account'},
                            'fieldsToReturn' => new List<String>{'Id', 'Name'},
                            'filters' => new Map<String, Object>{ 'Name' => 'Test Account' }
                    }),
                OriginalTurnIdentifier__c = 'turn-1',
                OriginalTurnCount__c = 1,
                ApprovalStatus__c = 'Pending'
            ),
            new HumanApprovalRequest__c(
                AgentExecution__c = session.Id,
                OriginalAssistantStep__c = assistantMessages[1].Id,
                LLMToolCallId__c = 'call_2',
                LLMToolName__c = 'find_records',
                LLMToolArgumentsJSON__c = '{}',
                OriginalTurnIdentifier__c = 'turn-2',
                OriginalTurnCount__c = 1,
                ApprovalStatus__c = 'Pending'
            ),
            new HumanApprovalRequest__c(
                AgentExecution__c = session.Id,
                OriginalAssistantStep__c = assistantMessages[2].Id,
                LLMToolCallId__c = 'call_3',
                LLMToolName__c = 'find_records',
                LLMToolArgumentsJSON__c = '{}',
                OriginalTurnIdentifier__c = 'turn-3',
                OriginalTurnCount__c = 1,
                ApprovalStatus__c = 'Pending'
            )
        };
        insert hars;

        Account testAccount = TestFactory.newAccount().withName('Test Account').save();
        Test.setFixedSearchResults(new List<Id>{testAccount.Id});

        // When: Processing mixed statuses
        Test.startTest();
        hars[0].ApprovalStatus__c = 'Approved';
        hars[1].ApprovalStatus__c = 'Rejected';
        // hars[2] stays Pending
        update hars;
        Test.stopTest();

        // Then: Should process each correctly
        List<HumanApprovalRequest__c> updatedHars = [
            SELECT ApprovalStatus__c
            FROM HumanApprovalRequest__c
            ORDER BY LLMToolCallId__c
        ];

        System.assertEquals('Approved', updatedHars[0].ApprovalStatus__c);
        System.assertEquals('Rejected', updatedHars[1].ApprovalStatus__c);
        System.assertEquals('Pending', updatedHars[2].ApprovalStatus__c);
    }

    @IsTest
    static void testHandleAfterUpdate_NoStatusChange_NoProcessing() {
        // Given: Pending request
        AgentExecution__c session = [SELECT Id FROM AgentExecution__c LIMIT 1];

        ExecutionStep__c assistantMessage = new ExecutionStep__c(
            AgentExecution__c = session.Id,
            StepRole__c = AIAgentConstants.ROLE_ASSISTANT,
            Content__c = 'Request',
            ExternalId__c = 'turn-789',
            Timestamp__c = System.now(),
            StepType__c = 'AgentResponse'
        );
        insert assistantMessage;

        HumanApprovalRequest__c har = new HumanApprovalRequest__c(
            AgentExecution__c = session.Id,
            OriginalAssistantStep__c = assistantMessage.Id,
            LLMToolCallId__c = 'call_789',
            LLMToolName__c = 'find_records',
            LLMToolArgumentsJSON__c = '{}',
            OriginalTurnIdentifier__c = 'turn-789',
            OriginalTurnCount__c = 1,
            ApprovalStatus__c = 'Pending'
        );
        insert har;

        // When: Updating without status change
        Test.startTest();
        har.ApproverComments__c = 'Under review';
        update har;
        Test.stopTest();

        // Then: Should not process
        HumanApprovalRequest__c updatedHar = [
            SELECT ApprovalStatus__c, ApproverComments__c
            FROM HumanApprovalRequest__c
            WHERE Id = :har.Id
        ];

        System.assertEquals('Pending', updatedHar.ApprovalStatus__c);
        System.assertEquals('Under review', updatedHar.ApproverComments__c);
    }

    @IsTest
    static void testHandleAfterUpdate_EmptyList_NoProcessing() {
        // When: Calling with empty list
        Test.startTest();
        HumanApprovalRequestTriggerHandler.handleAfterUpdate(
            new List<HumanApprovalRequest__c>(),
            new Map<Id, HumanApprovalRequest__c>()
        );
        Test.stopTest();

        // Then: Should handle gracefully
        System.assert(true, 'Should handle empty list gracefully');
    }
}
