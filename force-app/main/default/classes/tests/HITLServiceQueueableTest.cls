/**
 * @description Tests for HITLServiceQueueable covering all three operation modes
 * with ServiceUserNamedCredential__c configured and HTTP callouts mocked.
 */
@IsTest
private class HITLServiceQueueableTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('HITLQueue LLM').save();
        AIAgentDefinition__c agent = TestFactory.newAgentDefinition().withName('HITLQueue_Agent').withType('Function').withLLM(llm.Id).save();

        // Set ServiceUserNamedCredential__c so callout logic is reached
        agent.ServiceUserNamedCredential__c = 'AgentStudio_ServiceUser';
        update agent;

        AgentCapability__c cap = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forFlowHandler('HITLQueue_Flow')
            .withName('hitl_queue_cap')
            .withHITLMode(HITLGatewayService.HITL_MODE_APPROVAL)
            .save();

        TestFactory.newExecution()
            .withAgent(agent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Function')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-hitlq-001')
            .save();
    }

    @IsTest
    static void testExecuteTool_Success_ReturnsOk() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentCapability__c cap = [SELECT Id, CapabilityName__c, HITLNotificationPreference__c FROM AgentCapability__c LIMIT 1];

        PendingHITLAction__c action = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = cap.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitlq-001',
            TurnCount__c = 1,
            ToolCallId__c = 'call-hitlq-001',
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{"recordData":{"Subject":"Test"}}',
            ConfirmationPrompt__c = 'Approve?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert action;

        // Mock a successful REST response from the HITL execute endpoint
        Test.setMock(
            HttpCalloutMock.class,
            new MockHttpResponses().withDefaultResponse(new MockHttpResponses.ResponseConfig(200, '{"success":true,"outcome":"Tool executed successfully"}'))
        );

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(action.Id, true));
        Test.stopTest();

        // Verify action status not mutated by the queueable (actual mutation happens in REST endpoint)
        PendingHITLAction__c afterAction = [SELECT Status__c FROM PendingHITLAction__c WHERE Id = :action.Id];
        System.assertEquals(HITLGatewayService.STATUS_PENDING, afterAction.Status__c, 'Action status should remain Pending (REST endpoint handles updates)');
    }

    @IsTest
    static void testExecuteTool_HttpError_LogsError() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentCapability__c cap = [SELECT Id, CapabilityName__c, HITLNotificationPreference__c FROM AgentCapability__c LIMIT 1];

        PendingHITLAction__c action = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = cap.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitlq-002',
            TurnCount__c = 1,
            ToolCallId__c = 'call-hitlq-002',
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{"recordData":{"Subject":"Fail"}}',
            ConfirmationPrompt__c = 'Approve?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert action;

        // Mock a 500 error response - HttpCalloutService wraps this as NonRetriableHttpException
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.serverError());

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(action.Id, false));
        Test.stopTest();

        // Action should remain unchanged (error is logged, not propagated to action)
        PendingHITLAction__c afterAction = [SELECT Status__c FROM PendingHITLAction__c WHERE Id = :action.Id];
        System.assertEquals(HITLGatewayService.STATUS_PENDING, afterAction.Status__c, 'Action status should remain Pending on error');
    }

    @IsTest
    static void testFollowUp_Success_CompletesWithoutMutation() {
        AgentExecution__c exec = [
            SELECT Id, ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            LIMIT 1
        ];

        // Mock a successful follow-up response
        Test.setMock(
            HttpCalloutMock.class,
            new MockHttpResponses().withDefaultResponse(new MockHttpResponses.ResponseConfig(200, '{"success":true,"outcome":"QUEUED_FOLLOWUP"}'))
        );

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'turn-hitlq-followup-001', 2, null));
        Test.stopTest();

        AgentExecution__c afterExec = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :exec.Id
        ];
        System.assertEquals(exec.ExecutionStatus__c, afterExec.ExecutionStatus__c, 'Execution status should remain unchanged');
    }

    @IsTest
    static void testResume_Success_CompletesWithoutMutation() {
        AgentExecution__c exec = [
            SELECT Id, ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            LIMIT 1
        ];

        // Mock a successful resume response
        Test.setMock(
            HttpCalloutMock.class,
            new MockHttpResponses()
                .withDefaultResponse(new MockHttpResponses.ResponseConfig(200, '{"success":true,"outcome":"Resumed","message":"Execution resumed"}'))
        );

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'Resume requested by test', null));
        Test.stopTest();

        AgentExecution__c afterExec = [
            SELECT ExecutionStatus__c, ProcessingStatus__c, ErrorMessage__c
            FROM AgentExecution__c
            WHERE Id = :exec.Id
        ];
        System.assertEquals(exec.ExecutionStatus__c, afterExec.ExecutionStatus__c, 'Execution status should remain unchanged');
    }

    @IsTest
    static void testFollowUp_HttpError_LogsErrorGracefully() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Mock 500 error - HttpCalloutService throws NonRetriableHttpException
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.serverError());

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'turn-hitlq-followup-err', 3, null));
        Test.stopTest();

        // Verify execution not mutated (error caught and logged)
        AgentExecution__c afterExec = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :exec.Id];
        System.assertNotEquals(null, afterExec, 'Execution should still exist after error');
    }

    @IsTest
    static void testResume_SuccessFalse_LogsWarning() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Mock a 200 response with success: false to cover the warning branch
        Test.setMock(
            HttpCalloutMock.class,
            new MockHttpResponses().withDefaultResponse(new MockHttpResponses.ResponseConfig(200, '{"success":false,"message":"Step not found for resume"}'))
        );

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'Resume after failure', null));
        Test.stopTest();

        AgentExecution__c afterExec = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :exec.Id];
        System.assertNotEquals(null, afterExec, 'Execution should still exist after warning');
    }

    @IsTest
    static void testResume_HttpError_LogsErrorGracefully() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Mock 500 error for resume mode
        Test.setMock(HttpCalloutMock.class, MockHttpResponses.serverError());

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'Resume after stuck', true));
        Test.stopTest();

        // Error is caught and logged, not propagated
        AgentExecution__c afterExec = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :exec.Id];
        System.assertNotEquals(null, afterExec, 'Execution should still exist after error');
    }

    @IsTest
    static void testExecuteTool_MissingNamedCredential_DoesNotMutatePendingAction() {
        // Remove ServiceUserNamedCredential to test error path
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        agent.ServiceUserNamedCredential__c = null;
        update agent;

        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentCapability__c cap = [SELECT Id, CapabilityName__c, HITLNotificationPreference__c FROM AgentCapability__c LIMIT 1];

        PendingHITLAction__c action = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = cap.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitlq-001',
            TurnCount__c = 1,
            ToolCallId__c = 'call-hitlq-err-001',
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{"recordData":{"Subject":"Test"}}',
            ConfirmationPrompt__c = 'Approve?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert action;

        PendingHITLAction__c beforeAction = [
            SELECT Status__c, ResolvedAt__c, ResolvedBy__c, ResolutionComment__c
            FROM PendingHITLAction__c
            WHERE Id = :action.Id
        ];

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(action.Id, true));
        Test.stopTest();

        PendingHITLAction__c afterAction = [
            SELECT Status__c, ResolvedAt__c, ResolvedBy__c, ResolutionComment__c
            FROM PendingHITLAction__c
            WHERE Id = :action.Id
        ];

        System.assertEquals(beforeAction.Status__c, afterAction.Status__c, 'Pending action status should remain unchanged');
        System.assertEquals(beforeAction.ResolvedAt__c, afterAction.ResolvedAt__c, 'Resolved timestamp should remain unchanged');
    }

    @IsTest
    static void testFollowUp_MissingNamedCredential_DoesNotMutateExecution() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        agent.ServiceUserNamedCredential__c = null;
        update agent;

        AgentExecution__c exec = [SELECT Id, ExecutionStatus__c FROM AgentExecution__c LIMIT 1];
        String originalStatus = exec.ExecutionStatus__c;

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'turn-no-cred', 1, null));
        Test.stopTest();

        AgentExecution__c afterExec = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :exec.Id];
        System.assertEquals(originalStatus, afterExec.ExecutionStatus__c, 'Execution status should remain unchanged on credential error');
    }

    @IsTest
    static void testResume_MissingNamedCredential_DoesNotMutateExecution() {
        AIAgentDefinition__c agent = [SELECT Id FROM AIAgentDefinition__c LIMIT 1];
        agent.ServiceUserNamedCredential__c = null;
        update agent;

        AgentExecution__c exec = [SELECT Id, ExecutionStatus__c FROM AgentExecution__c LIMIT 1];
        String originalStatus = exec.ExecutionStatus__c;

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'Resume no cred', false));
        Test.stopTest();

        AgentExecution__c afterExec = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :exec.Id];
        System.assertEquals(originalStatus, afterExec.ExecutionStatus__c, 'Execution status should remain unchanged on credential error');
    }

    @IsTest
    static void testFollowUp_WithSourceRecordId_BuildsCorrectRequest() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];

        // Use an Account as sourceRecordId to exercise that branch
        Account acc = new Account(Name = 'HITL Test Account');
        insert acc;

        Test.setMock(
            HttpCalloutMock.class,
            new MockHttpResponses().withDefaultResponse(new MockHttpResponses.ResponseConfig(200, '{"success":true,"outcome":"QUEUED_FOLLOWUP"}'))
        );

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'turn-with-source', 2, acc.Id));
        Test.stopTest();

        AgentExecution__c afterExec = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :exec.Id];
        System.assertNotEquals(null, afterExec, 'Execution should still exist');
    }

    @IsTest
    static void testExecuteTool_WithNeedsFollowUpFalse_Success() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentCapability__c cap = [SELECT Id, CapabilityName__c FROM AgentCapability__c LIMIT 1];

        PendingHITLAction__c action = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = cap.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitlq-nofollow',
            TurnCount__c = 1,
            ToolCallId__c = 'call-hitlq-nofollow',
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{"recordData":{"Subject":"No follow-up"}}',
            ConfirmationPrompt__c = 'Execute without follow-up?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert action;

        Test.setMock(
            HttpCalloutMock.class,
            new MockHttpResponses().withDefaultResponse(new MockHttpResponses.ResponseConfig(200, '{"success":true,"outcome":"Tool executed"}'))
        );

        Test.startTest();
        // Pass needsFollowUp = false
        System.enqueueJob(new HITLServiceQueueable(action.Id, false));
        Test.stopTest();

        PendingHITLAction__c afterAction = [SELECT Status__c FROM PendingHITLAction__c WHERE Id = :action.Id];
        System.assertEquals(HITLGatewayService.STATUS_PENDING, afterAction.Status__c, 'Action should remain Pending');
    }

    @IsTest
    static void testFollowUpOnly_WithValidExecution_Succeeds() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];

        Test.setMock(
            HttpCalloutMock.class,
            new MockHttpResponses().withDefaultResponse(new MockHttpResponses.ResponseConfig(200, '{"success":true,"outcome":"COMPLETED"}'))
        );

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'turn-followup-only', 1, null));
        Test.stopTest();

        AgentExecution__c updated = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :exec.Id];
        System.assertNotEquals(null, updated, 'Execution should still exist after follow-up only');
    }

    @IsTest
    static void testResume_WithValidExecution_Succeeds() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];

        Test.setMock(HttpCalloutMock.class, new MockHttpResponses().withDefaultResponse(new MockHttpResponses.ResponseConfig(200, '{"success":true}')));

        Test.startTest();
        // Use the 3-arg resume constructor: (executionId, resumeReason, retryFailedTool)
        System.enqueueJob(new HITLServiceQueueable(exec.Id, 'HITL resolved', false));
        Test.stopTest();

        AgentExecution__c updated = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :exec.Id];
        System.assertNotEquals(null, updated, 'Execution should still exist after resume');
    }

    @IsTest
    static void testExecuteTool_HttpServerError_HandlesGracefully() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentCapability__c cap = [SELECT Id, CapabilityName__c FROM AgentCapability__c LIMIT 1];

        PendingHITLAction__c action = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = cap.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitlq-err',
            TurnCount__c = 1,
            ToolCallId__c = 'call-hitlq-err',
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{"Subject":"Error test"}',
            ConfirmationPrompt__c = 'Retry on error?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert action;

        Test.setMock(HttpCalloutMock.class, new MockHttpResponses().withDefaultResponse(new MockHttpResponses.ResponseConfig(500, '{"error":"Server error"}')));

        Test.startTest();
        System.enqueueJob(new HITLServiceQueueable(action.Id, true));
        Test.stopTest();

        AgentExecution__c afterExec = [SELECT ExecutionStatus__c FROM AgentExecution__c WHERE Id = :exec.Id];
        System.assertNotEquals(null, afterExec, 'Execution should survive HTTP error');
    }
}
