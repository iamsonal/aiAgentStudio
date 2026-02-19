/**
 * @description Focused tests for HITLGatewayService evaluation and resolution behavior
 */
@IsTest
private class HITLGatewayServiceTest {
    @TestSetup
    static void setupData() {
        LLMConfiguration__c llm = TestFactory.newLLMConfiguration().withName('HITL LLM').save();

        AIAgentDefinition__c convoAgent = TestFactory.newAgentDefinition().withName('HITL_Convo_Agent').withType('Conversational').withLLM(llm.Id).save();

        AIAgentDefinition__c nonConversationalAgent = TestFactory.newAgentDefinition().withName('HITL_NonConvo_Agent').withType('Email').withLLM(llm.Id).save();

        AgentCapability__c approvalCap = TestFactory.newCapability()
            .withAgent(convoAgent.Id)
            .forFlowHandler('HITL_Flow')
            .withName('hitl_approval')
            .withHITLMode(HITLGatewayService.HITL_MODE_APPROVAL)
            .save();

        AgentCapability__c confirmationCap = TestFactory.newCapability()
            .withAgent(convoAgent.Id)
            .forFlowHandler('HITL_Confirm_Flow')
            .withName('hitl_confirm')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONFIRMATION)
            .save();

        TestFactory.newExecution()
            .withAgent(convoAgent.Id)
            .withUser(UserInfo.getUserId())
            .withExecutionType('Conversational')
            .withProcessingStatus(AIAgentConstants.STATUS_IDLE)
            .withTurnIdentifier('turn-hitl-001')
            .save();
    }

    @IsTest
    static void testEvaluate_ApprovalRequiresIntervention() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c cap = [
            SELECT Id, CapabilityName__c, HITLMode__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'hitl_approval'
            LIMIT 1
        ];

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = cap;
        ctx.agentDefinition = agent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-001';
        ctx.toolCallId = 'call-001';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        System.assertEquals(true, decision.requiresIntervention, 'Approval should require intervention');
        System.assertEquals(HITLGatewayService.HITL_MODE_APPROVAL, decision.hitlMode, 'Decision should be Approval mode');
        System.assertEquals(true, decision.isValidConfiguration, 'Configuration should be valid');
    }

    @IsTest
    static void testEvaluate_ConfirmationInvalidForNonConversationalAgent() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_NonConvo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c cap = [
            SELECT Id, CapabilityName__c, HITLMode__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'hitl_confirm'
            LIMIT 1
        ];

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = cap;
        ctx.agentDefinition = agent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-002';
        ctx.toolCallId = 'call-002';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        System.assertEquals(false, decision.requiresIntervention, 'Invalid config should not require intervention');
        System.assertEquals(false, decision.isValidConfiguration, 'Confirmation on non-conversational agent should be invalid');
        System.assert(String.isNotBlank(decision.configurationError), 'Configuration error should be populated');
    }

    @IsTest
    static void testResolveApproval_ApprovedAndRejected() {
        AIAgentDefinition__c agent = [
            SELECT Id, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c cap = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'hitl_approval'
            LIMIT 1
        ];
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];

        PendingHITLAction__c action = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = cap.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitl-003',
            TurnCount__c = 1,
            ToolCallId__c = 'call-003',
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{"recordData":{"Subject":"Test"}}',
            ConfirmationPrompt__c = 'Approve?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert action;

        HITLGatewayService.HITLResolutionResult approved = HITLGatewayService.resolveApproval(action.Id, true, UserInfo.getUserId(), 'Looks good');
        System.assertEquals(true, approved.success, 'Approval resolution should succeed');
        System.assertEquals(true, approved.shouldProceed, 'Approved action should proceed');
        System.assertEquals(HITLGatewayService.STATUS_APPROVED, approved.status, 'Status should be Approved');
        System.assertNotEquals(null, approved.capability, 'Capability should be returned on approval');

        PendingHITLAction__c updated = [SELECT Status__c FROM PendingHITLAction__c WHERE Id = :action.Id];
        System.assertEquals(HITLGatewayService.STATUS_APPROVED, updated.Status__c, 'Action status should be updated');

        PendingHITLAction__c action2 = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = cap.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitl-004',
            TurnCount__c = 1,
            ToolCallId__c = 'call-004',
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{"recordData":{"Subject":"Test2"}}',
            ConfirmationPrompt__c = 'Approve?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert action2;

        HITLGatewayService.HITLResolutionResult rejected = HITLGatewayService.resolveApproval(action2.Id, false, UserInfo.getUserId(), 'No');
        System.assertEquals(true, rejected.success, 'Rejection resolution should succeed');
        System.assertEquals(false, rejected.shouldProceed, 'Rejected action should not proceed');
        System.assertEquals(HITLGatewayService.STATUS_REJECTED, rejected.status, 'Status should be Rejected');
        System.assert(rejected.llmMessage.contains('Reason: No'), 'Rejection message should include reason');
    }

    @IsTest
    static void testPendingActionsAndNotificationPreference() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentCapability__c cap = [SELECT Id, CapabilityName__c FROM AgentCapability__c WHERE CapabilityName__c = 'hitl_approval' LIMIT 1];

        PendingHITLAction__c pending = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = cap.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitl-005',
            TurnCount__c = 1,
            ToolCallId__c = 'call-005',
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{}',
            ConfirmationPrompt__c = 'Approve?',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert pending;

        System.assertEquals(true, HITLGatewayService.hasPendingActions(exec.Id), 'Execution should have pending actions');

        List<PendingHITLAction__c> pendingList = HITLGatewayService.getPendingActionsForExecution(exec.Id);
        System.assertEquals(true, !pendingList.isEmpty(), 'Pending actions should be returned');

        System.assertEquals(
            true,
            HITLGatewayService.shouldSendHITLNotification(HITLGatewayService.NOTIFICATION_PREF_ALWAYS_NOTIFY, HITLGatewayService.NOTIFICATION_TYPE_APPROVAL),
            'Always notify should send'
        );
        System.assertEquals(
            true,
            HITLGatewayService.shouldSendHITLNotification(HITLGatewayService.NOTIFICATION_PREF_REJECTION_ONLY, HITLGatewayService.NOTIFICATION_TYPE_REJECTION),
            'Rejection-only should send for rejection'
        );
        System.assertEquals(
            false,
            HITLGatewayService.shouldSendHITLNotification(HITLGatewayService.NOTIFICATION_PREF_REJECTION_ONLY, HITLGatewayService.NOTIFICATION_TYPE_APPROVAL),
            'Rejection-only should not send for approval'
        );
    }

    @IsTest
    static void testEvaluate_NullHITLMode_ProceedsWithoutIntervention() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c cap = TestFactory.newCapability().withAgent(agent.Id).forFlowHandler('HITL_NoMode').withName('hitl_no_mode').save();
        // HITLMode__c is null by default

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = cap;
        ctx.agentDefinition = agent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-null-mode';
        ctx.toolCallId = 'call-null-mode-001';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        System.assertEquals(false, decision.requiresIntervention, 'Null HITL mode should not require intervention');
    }

    @IsTest
    static void testEvaluate_ConfirmationWithConversationalAgent_IsValid() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c cap = [
            SELECT Id, CapabilityName__c, HITLMode__c, RunAsynchronously__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'hitl_confirm'
            LIMIT 1
        ];

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = cap;
        ctx.agentDefinition = agent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-confirm-convo';
        ctx.toolCallId = 'call-confirm-convo-001';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        // Confirmation mode is valid for Conversational agents but doesn't require intervention upfront
        System.assertEquals(true, decision.isValidConfiguration, 'Confirmation on Conversational should be valid config');
    }

    @IsTest
    static void testResolveApproval_ActionNotFound_ReturnsError() {
        // Create a PendingHITLAction, delete it, then try to resolve with its old Id
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];
        AgentCapability__c cap = [SELECT Id, CapabilityName__c FROM AgentCapability__c WHERE CapabilityName__c = 'hitl_approval' LIMIT 1];

        PendingHITLAction__c action = new PendingHITLAction__c(
            AgentExecution__c = exec.Id,
            AIAgentCapability__c = cap.Id,
            HITLType__c = HITLGatewayService.HITL_MODE_APPROVAL,
            Status__c = HITLGatewayService.STATUS_PENDING,
            TurnIdentifier__c = 'turn-hitl-ghost',
            TurnCount__c = 1,
            ToolCallId__c = 'call-ghost-001',
            ToolName__c = cap.CapabilityName__c,
            ToolArgumentsJSON__c = '{}',
            RequestedAt__c = Datetime.now(),
            RequestingUser__c = UserInfo.getUserId()
        );
        insert action;
        Id actionId = action.Id;
        delete action;

        HITLGatewayService.HITLResolutionResult result = HITLGatewayService.resolveApproval(actionId, true, UserInfo.getUserId(), 'ok');

        System.assertEquals(false, result.success, 'Deleted action should fail resolution');
    }

    @IsTest
    static void testHasPendingActions_NoActions_ReturnsFalse() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];
        // Delete any existing pending actions
        delete [SELECT Id FROM PendingHITLAction__c WHERE AgentExecution__c = :exec.Id];

        System.assertEquals(false, HITLGatewayService.hasPendingActions(exec.Id), 'No pending actions should return false');
    }

    @IsTest
    static void testGetPendingActionsForExecution_NoActions_ReturnsEmpty() {
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];
        delete [SELECT Id FROM PendingHITLAction__c WHERE AgentExecution__c = :exec.Id];

        List<PendingHITLAction__c> actions = HITLGatewayService.getPendingActionsForExecution(exec.Id);
        System.assertEquals(0, actions.size(), 'No pending actions should return empty list');
    }

    @IsTest
    static void testShouldSendHITLNotification_UnrecognizedPreference_ReturnsFalse() {
        // Any preference string not matching "Always Notify" or "Notify on Rejection Only" returns false
        System.assertEquals(
            false,
            HITLGatewayService.shouldSendHITLNotification('Never', HITLGatewayService.NOTIFICATION_TYPE_APPROVAL),
            'Unrecognized preference should return false for approval'
        );
        System.assertEquals(
            false,
            HITLGatewayService.shouldSendHITLNotification('Never', HITLGatewayService.NOTIFICATION_TYPE_REJECTION),
            'Unrecognized preference should return false for rejection'
        );
        System.assertEquals(
            false,
            HITLGatewayService.shouldSendHITLNotification(null, HITLGatewayService.NOTIFICATION_TYPE_APPROVAL),
            'Null preference should return false'
        );
    }

    @IsTest
    static void testEvaluate_ConditionalApproval_ProceedsWithoutIntervention() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c conditionalCap = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forFlowHandler('HITL_Conditional')
            .withName('hitl_conditional')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONDITIONAL_APPROVAL)
            .save();

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = conditionalCap;
        ctx.agentDefinition = agent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-conditional';
        ctx.toolCallId = 'call-conditional-001';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        System.assertEquals(false, decision.requiresIntervention, 'Conditional approval should not force intervention');
        System.assertEquals(true, decision.isValidConfiguration, 'Conditional approval should be valid config');
    }

    @IsTest
    static void testEvaluate_ApprovalAsync_RequiresIntervention() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c asyncApproval = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forFlowHandler('HITL_Async_Approval')
            .withName('hitl_async_approval')
            .withHITLMode(HITLGatewayService.HITL_MODE_APPROVAL)
            .save();
        // Simulate async flag without DML (validation blocks async+approval)
        asyncApproval.RunAsynchronously__c = true;

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = asyncApproval;
        ctx.agentDefinition = agent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-async-approval';
        ctx.toolCallId = 'call-async-approval-001';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        System.assertEquals(true, decision.requiresIntervention, 'Async approval should still require intervention');
        System.assertEquals(true, decision.isValidConfiguration, 'Approval with async tools should be valid config');
    }

    @IsTest
    static void testInitiateHITL_Approval_Mode() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c cap = [
            SELECT Id, CapabilityName__c
            FROM AgentCapability__c
            WHERE CapabilityName__c = 'hitl_approval'
            LIMIT 1
        ];
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = cap;
        ctx.agentDefinition = agent;
        ctx.executionId = exec.Id;
        ctx.requestingUserId = UserInfo.getUserId();
        ctx.turnIdentifier = 'turn-hitl-approval-init';
        ctx.turnCount = 1;
        ctx.toolCallId = 'call-approval-init-001';
        ctx.toolArguments = '{"recordData":{"Subject":"Test"}}';
        ctx.isConditionalApproval = false;

        HITLGatewayService.HITLDecision decision = HITLGatewayService.createInterventionDecision(HITLGatewayService.HITL_MODE_APPROVAL);
        HITLGatewayService.HITLResult result = HITLGatewayService.initiateHITL(ctx, decision);

        if (result.success) {
            System.assertEquals(HITLGatewayService.HITL_MODE_APPROVAL, result.hitlType, 'HITL type should be Approval');
            System.assertNotEquals(null, result.pendingActionId, 'Pending action should be created');

            PendingHITLAction__c pending = [
                SELECT HITLType__c, ToolCallId__c
                FROM PendingHITLAction__c
                WHERE Id = :result.pendingActionId
                LIMIT 1
            ];
            System.assertEquals(HITLGatewayService.HITL_MODE_APPROVAL, pending.HITLType__c, 'Pending action should be Approval');
            System.assertEquals(ctx.toolCallId, pending.ToolCallId__c, 'Tool call id should match');
        } else {
            System.assert(
                result.errorMessage != null &&
                (result.errorMessage.contains('Failed to submit to approval process') || result.errorMessage.contains('Exception submitting approval')),
                'Should fail with approval submission error when no approval process exists'
            );
            Integer pendingCount = [
                SELECT COUNT()
                FROM PendingHITLAction__c
                WHERE AgentExecution__c = :exec.Id AND ToolCallId__c = :ctx.toolCallId
            ];
            System.assertEquals(0, pendingCount, 'Pending action should be cleaned up on failure');
        }
    }

    @IsTest
    static void testInitiateHITL_ConfirmationThenApproval_Mode() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c cap = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forFlowHandler('HITL_Confirm_Approve')
            .withName('hitl_confirm_then_approve')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONFIRMATION_THEN_APPROVAL)
            .save();
        AgentExecution__c exec = [SELECT Id FROM AgentExecution__c LIMIT 1];

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = cap;
        ctx.agentDefinition = agent;
        ctx.executionId = exec.Id;
        ctx.requestingUserId = UserInfo.getUserId();
        ctx.turnIdentifier = 'turn-hitl-confirm-approve-init';
        ctx.turnCount = 1;
        ctx.toolCallId = 'call-confirm-approve-001';
        ctx.toolArguments = '{"recordData":{"Subject":"Test"}}';
        ctx.isConditionalApproval = false;

        HITLGatewayService.HITLDecision decision = HITLGatewayService.createInterventionDecision(HITLGatewayService.HITL_MODE_CONFIRMATION_THEN_APPROVAL);
        HITLGatewayService.HITLResult result = HITLGatewayService.initiateHITL(ctx, decision);

        if (result.success) {
            System.assertEquals(HITLGatewayService.HITL_MODE_CONFIRMATION_THEN_APPROVAL, result.hitlType, 'HITL type should be ConfirmationThenApproval');
            System.assertNotEquals(null, result.pendingActionId, 'Pending action should be created');

            PendingHITLAction__c pending = [
                SELECT HITLType__c, ToolCallId__c
                FROM PendingHITLAction__c
                WHERE Id = :result.pendingActionId
                LIMIT 1
            ];
            System.assertEquals(
                HITLGatewayService.HITL_MODE_CONFIRMATION_THEN_APPROVAL,
                pending.HITLType__c,
                'Pending action should be ConfirmationThenApproval'
            );
            System.assertEquals(ctx.toolCallId, pending.ToolCallId__c, 'Tool call id should match');
        } else {
            System.assert(
                result.errorMessage != null &&
                (result.errorMessage.contains('Failed to submit to approval process') || result.errorMessage.contains('Exception submitting approval')),
                'Should fail with approval submission error when no approval process exists'
            );
            Integer pendingCount = [
                SELECT COUNT()
                FROM PendingHITLAction__c
                WHERE AgentExecution__c = :exec.Id AND ToolCallId__c = :ctx.toolCallId
            ];
            System.assertEquals(0, pendingCount, 'Pending action should be cleaned up on failure');
        }
    }

    @IsTest
    static void testEvaluate_ConfirmationWithAsyncTool_IsInvalidConfig() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c asyncConfirmCap = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forFlowHandler('HITL_Async_Confirm')
            .withName('hitl_async_confirm')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONFIRMATION)
            .save();
        // Set async flag (in-memory, doesn't persist to DB)
        asyncConfirmCap.RunAsynchronously__c = true;

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = asyncConfirmCap;
        ctx.agentDefinition = agent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-async-confirm';
        ctx.toolCallId = 'call-async-confirm-001';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        System.assertEquals(false, decision.isValidConfiguration, 'Confirmation with async tool should be invalid config');
        System.assert(decision.configurationError.contains('asynchronous'), 'Error should mention async issue');
        System.assertEquals(false, decision.requiresIntervention, 'Invalid config should not require intervention');
    }

    @IsTest
    static void testEvaluate_ConfirmationThenApprovalWithNonConversationalAgent_IsInvalidConfig() {
        AIAgentDefinition__c nonConversationalAgent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_NonConvo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c confirmThenApproveCap = TestFactory.newCapability()
            .withAgent(nonConversationalAgent.Id)
            .forFlowHandler('HITL_Confirm_Approve_Function')
            .withName('hitl_confirm_approve_func')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONFIRMATION_THEN_APPROVAL)
            .build();

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = confirmThenApproveCap;
        ctx.agentDefinition = nonConversationalAgent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-confirm-approve-func';
        ctx.toolCallId = 'call-confirm-approve-func-001';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        System.assertEquals(false, decision.requiresIntervention, 'Invalid config should not require intervention');
        System.assertEquals(false, decision.isValidConfiguration, 'ConfirmationThenApproval on non-conversational agent should be invalid');
        System.assert(
            String.isNotBlank(decision.configurationError) && decision.configurationError.contains('Conversational'),
            'Error should mention Conversational requirement'
        );
    }

    @IsTest
    static void testEvaluate_ConfirmationThenApprovalWithAsyncTool_IsInvalidConfig() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c asyncConfirmApproveCap = TestFactory.newCapability()
            .withAgent(agent.Id)
            .forFlowHandler('HITL_Async_ConfirmApprove')
            .withName('hitl_async_confirm_approve')
            .withHITLMode(HITLGatewayService.HITL_MODE_CONFIRMATION_THEN_APPROVAL)
            .save();
        // Set async flag (in-memory)
        asyncConfirmApproveCap.RunAsynchronously__c = true;

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = asyncConfirmApproveCap;
        ctx.agentDefinition = agent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-async-confirm-approve';
        ctx.toolCallId = 'call-async-confirm-approve-001';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        System.assertEquals(false, decision.isValidConfiguration, 'ConfirmationThenApproval with async should be invalid');
        System.assert(decision.configurationError.contains('asynchronous'), 'Error should mention async issue');
        System.assertEquals(false, decision.requiresIntervention, 'Invalid config should not require intervention');
    }

    @IsTest
    static void testEvaluate_UnknownHITLMode_ReturnsInvalidConfig() {
        AIAgentDefinition__c agent = [
            SELECT Id, AgentType__c, DeveloperName__c
            FROM AIAgentDefinition__c
            WHERE DeveloperName__c LIKE 'HITL_Convo_Agent%'
            LIMIT 1
        ];
        AgentCapability__c unknownModeCap = TestFactory.newCapability().withAgent(agent.Id).forFlowHandler('HITL_Unknown').withName('hitl_unknown_mode').save();
        // Set HITLMode to invalid value (in-memory, as picklist would block this)
        unknownModeCap.HITLMode__c = 'UnsupportedMode';

        HITLGatewayService.HITLContext ctx = new HITLGatewayService.HITLContext();
        ctx.capability = unknownModeCap;
        ctx.agentDefinition = agent;
        ctx.executionId = [SELECT Id FROM AgentExecution__c LIMIT 1].Id;
        ctx.turnIdentifier = 'turn-hitl-unknown';
        ctx.toolCallId = 'call-unknown-001';

        HITLGatewayService.HITLDecision decision = HITLGatewayService.evaluate(ctx);

        System.assertEquals(false, decision.isValidConfiguration, 'Unknown HITL mode should be invalid');
        System.assert(decision.configurationError.contains('Unknown HITLMode'), 'Error should mention unknown mode');
        System.assertEquals(false, decision.requiresIntervention, 'Invalid config should not require intervention');
    }
}
