/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/** Reference scenarios 2 and 3: a person reviews a tool call before it runs. */
@IsTest
private class ApprovalDecisionScenarioTest {
    @IsTest
    static void approverRejectionWithCustomerEmailIsTokenizedForTheModel() {
        Fixture fixture = waitingApproval(5, 10);

        Id modelCommandId;
        System.runAs(new User(Id = fixture.approverId)) {
            modelCommandId = AgentKernel.decideApproval(
                AgentKernelTestFactory.approvalDecision(fixture.approvalId, false, 'Wrong recipient; reply to jane@example.com instead.')
            );
        }

        AgentCommand__c modelCommand = AgentKernelTestFactory.getCommand(modelCommandId);
        System.assert(modelCommand.Input__c.contains(AgentKernelModels.ERROR_TOOL_APPROVAL_DENIED));
        System.assert(TrustService.containsToken(modelCommand.Input__c), 'The reviewer\'s email reaches the model only as a token.');
        System.assert(!modelCommand.Input__c.contains('jane@example.com'));
        AgentApproval__c approval = AgentKernelTestFactory.pendingApproval(fixture.runId);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_REJECTED, approval.Status__c);
        System.assert(approval.DecisionComment__c.startsWith('Wrong recipient;'), 'The approval keeps the reviewer\'s comment for audit.');
        System.assert(!approval.DecisionComment__c.contains('jane@example.com'));
    }

    @IsTest
    static void approvalAfterTheToolBudgetIsSpentPausesWithTheApprovedCall() {
        Fixture fixture = waitingApproval(5, 1);
        AgentKernelTestFactory.updateRecord(new AgentRun__c(Id = fixture.runId, ToolCallCount__c = 1));

        Id nextCommandId;
        System.runAs(new User(Id = fixture.approverId)) {
            nextCommandId = AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(fixture.approvalId, true, 'Priority change is justified.'));
        }

        AgentRun__c run = AgentKernelTestFactory.getRun(fixture.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(fixture.commandId);
        System.assertEquals(null, nextCommandId);
        System.assertEquals(AgentKernelModels.RUN_STATUS_PAUSED, run.Status__c);
        System.assertEquals('BUDGET_EXCEEDED', run.ErrorCode__c);
        System.assertEquals(command.Id, run.CurrentCommand__c, 'Rescue runs the approved call without asking again.');
        System.assertEquals(AgentKernelModels.COMMAND_STATUS_PENDING, command.Status__c);
        System.assertEquals(true, command.PolicyApproved__c);
        AgentApproval__c approval = AgentKernelTestFactory.pendingApproval(fixture.runId);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_APPROVED, approval.Status__c);
        System.assertEquals('Priority change is justified.', approval.DecisionComment__c, 'An approval keeps the approver\'s comment too.');
    }

    @IsTest
    static void decideActionReportsEachFailureWithoutFailingTheOthers() {
        Fixture fixture = waitingApproval(5, 10);
        AgentApprovalActions.DecisionRequest valid = new AgentApprovalActions.DecisionRequest();
        valid.approvalId = fixture.approvalId;
        valid.approved = true;
        AgentApprovalActions.DecisionRequest invalid = new AgentApprovalActions.DecisionRequest();
        invalid.approvalId = fixture.runId;
        invalid.approved = true;
        Test.setMock(HttpCalloutMock.class, new AcceptedLoopback());

        List<AgentApprovalActions.DecisionResult> results;
        System.runAs(new User(Id = fixture.approverId)) {
            results = AgentApprovalActions.decide(new List<AgentApprovalActions.DecisionRequest>{ invalid, valid });
        }

        System.assertEquals(false, results[0].decided);
        System.assertNotEquals(null, results[0].errorMessage);
        System.assertEquals(true, results[1].decided);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_APPROVED, AgentKernelTestFactory.pendingApproval(fixture.runId).Status__c);
    }

    @IsTest
    static void decideActionDefersDecisionsTheTransactionCannotAfford() {
        Fixture fixture = waitingApproval(5, 10);
        AgentApprovalActions.DecisionRequest request = new AgentApprovalActions.DecisionRequest();
        request.approvalId = fixture.approvalId;
        request.approved = true;
        AgentApprovalActions.queriesPerDecision = Limits.getLimitQueries() + 1;

        List<AgentApprovalActions.DecisionResult> results;
        System.runAs(new User(Id = fixture.approverId)) {
            results = AgentApprovalActions.decide(new List<AgentApprovalActions.DecisionRequest>{ request });
        }

        System.assertEquals(false, results[0].decided);
        System.assertEquals(AgentApprovalActions.CAPACITY_DEFERRED, results[0].errorMessage);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_PENDING, AgentKernelTestFactory.pendingApproval(fixture.runId).Status__c);
    }

    @IsTest
    static void queueMembersThroughAPublicGroupCanDecide() {
        Id approverId = AgentKernelTestFactory.approverUser();
        Group queue = new Group(Name = 'Agent Approval Test Queue', DeveloperName = 'Agent_Approval_Test_Queue', Type = 'Queue');
        Group team = new Group(Name = 'Agent Approval Test Team', DeveloperName = 'Agent_Approval_Test_Team', Type = 'Regular');
        System.runAs(AgentKernelTestFactory.self()) {
            insert new List<Group>{ queue, team };
            insert new QueueSobject(QueueId = queue.Id, SobjectType = 'AgentApproval__c');
            insert new List<GroupMember>{
                new GroupMember(GroupId = team.Id, UserOrGroupId = approverId),
                new GroupMember(GroupId = queue.Id, UserOrGroupId = team.Id)
            };
        }
        Fixture fixture = waitingApproval(5, 10, queue.Id);

        System.runAs(new User(Id = approverId)) {
            AgentKernel.decideApproval(AgentKernelTestFactory.approvalDecision(fixture.approvalId, true, null));
        }

        AgentApproval__c decided = AgentKernelTestFactory.pendingApproval(fixture.runId);
        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_APPROVED, decided.Status__c);
        System.assertEquals(approverId, decided.DecidedBy__c);
    }

    @IsTest
    static void requesterWhoIsAQueueMemberMayDecideTheirRunsApproval() {
        Id requesterId = AgentKernelTestFactory.approverUser();
        Id peerId = AgentKernelTestFactory.approverUser();
        Group queue = new Group(Name = 'Agent Approval Peer Queue', DeveloperName = 'Agent_Approval_Peer_Queue', Type = 'Queue');
        System.runAs(AgentKernelTestFactory.self()) {
            insert queue;
            insert new QueueSobject(QueueId = queue.Id, SobjectType = 'AgentApproval__c');
            insert new List<GroupMember>{
                new GroupMember(GroupId = queue.Id, UserOrGroupId = requesterId),
                new GroupMember(GroupId = queue.Id, UserOrGroupId = peerId)
            };
        }
        AgentApproval__c approval = new AgentApproval__c(OwnerId = queue.Id, ApproverType__c = AgentKernelModels.APPROVER_QUEUE, RequestedBy__c = requesterId);
        AgentRun__c run = new AgentRun__c(
            InitiatingUser__c = requesterId,
            ExecutionIdentity__c = AgentKernelTestFactory.unsavedIdentityId(),
            ExpectedPrincipalUser__c = UserInfo.getUserId(),
            ResolvedPrincipalUser__c = UserInfo.getUserId()
        );

        System.runAs(new User(Id = requesterId)) {
            System.assertEquals(requesterId, AgentApprovalService.authorize(approval, run, null).deciderId, 'A requester who is a queue member may decide.');
        }
        System.runAs(new User(Id = peerId)) {
            System.assertEquals(peerId, AgentApprovalService.authorize(approval, run, null).deciderId);
        }
    }

    @IsTest
    static void anchorOwnerWhoStartedTheRunDecidesTheApproval() {
        Id approverId = AgentKernelTestFactory.approverUser();
        Group queue = new Group(Name = 'Agent Approval Fallback Queue', DeveloperName = 'Agent_Approval_Fallback_Queue', Type = 'Queue');
        System.runAs(AgentKernelTestFactory.self()) {
            insert queue;
            insert new QueueSobject(QueueId = queue.Id, SobjectType = 'AgentApproval__c');
            insert new GroupMember(GroupId = queue.Id, UserOrGroupId = approverId);
        }
        Account anchor = new Account(Name = 'Owned by the requester', OwnerId = approverId);
        insert anchor;
        AgentRun__c run = new AgentRun__c(
            InitiatingUser__c = approverId,
            AnchorRecordId__c = anchor.Id,
            ExecutionIdentity__c = AgentKernelTestFactory.unsavedIdentityId(),
            ExpectedPrincipalUser__c = AgentKernelTestFactory.approverUser()
        );
        AgentTool__c tool = new AgentTool__c(
            DeveloperName__c = 'refund_tool',
            ApproverType__c = AgentKernelModels.APPROVER_ANCHOR_OWNER,
            ApproverQueue__c = 'Agent_Approval_Fallback_Queue'
        );

        AgentApprovalService.Request request = AgentApprovalService.request(run, tool, 'Refund above the threshold.', null, null);

        System.assertEquals(AgentKernelModels.APPROVER_ANCHOR_OWNER, request.approverType, 'The owner started the run and still decides it.');
        System.assertEquals(approverId, request.ownerId, 'The fallback queue is only for an owner who cannot decide.');
    }

    @IsTest
    static void caseOwnedByACaseQueueUsesTheFallbackQueue() {
        Id approverId = AgentKernelTestFactory.approverUser();
        Group caseQueue = new Group(Name = 'Agent Case Intake Queue', DeveloperName = 'Agent_Case_Intake_Queue', Type = 'Queue');
        Group fallback = new Group(Name = 'Agent Refund Review Queue', DeveloperName = 'Agent_Refund_Review_Queue', Type = 'Queue');
        System.runAs(AgentKernelTestFactory.self()) {
            insert new List<Group>{ caseQueue, fallback };
            insert new List<QueueSobject>{
                new QueueSobject(QueueId = caseQueue.Id, SobjectType = 'Case'),
                new QueueSobject(QueueId = fallback.Id, SobjectType = 'AgentApproval__c')
            };
            insert new GroupMember(GroupId = fallback.Id, UserOrGroupId = approverId);
        }
        Case anchor = new Case(Subject = 'Refund request', OwnerId = caseQueue.Id);
        insert anchor;
        AgentRun__c run = new AgentRun__c(
            InitiatingUser__c = UserInfo.getUserId(),
            AnchorRecordId__c = anchor.Id,
            ExecutionIdentity__c = AgentKernelTestFactory.unsavedIdentityId(),
            ExpectedPrincipalUser__c = AgentKernelTestFactory.servicePrincipalUser().Id
        );
        AgentTool__c tool = new AgentTool__c(
            DeveloperName__c = 'refund_tool',
            ApproverType__c = AgentKernelModels.APPROVER_ANCHOR_OWNER,
            ApproverQueue__c = 'Agent_Refund_Review_Queue'
        );

        AgentApprovalService.Request request = AgentApprovalService.request(run, tool, 'Refund above the threshold.', null, null);

        System.assertEquals(AgentKernelModels.APPROVER_QUEUE, request.approverType, 'A Case queue cannot hold approvals, so the fallback decides.');
        System.assertEquals(fallback.Id, request.ownerId);
    }

    @IsTest
    static void unstaffedQueueIsUnresolvedWhenTheCallWaits() {
        Group queue = new Group(Name = 'Agent Approval Empty Queue', DeveloperName = 'Agent_Approval_Empty_Queue', Type = 'Queue');
        System.runAs(AgentKernelTestFactory.self()) {
            insert queue;
            insert new QueueSobject(QueueId = queue.Id, SobjectType = 'AgentApproval__c');
        }
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'queued_tool', '{"type":"object"}');
        AgentRun__c run = AgentKernelTestFactory.getRun(AgentKernelTestFactory.startRunWithoutDispatch(definition).runId);

        try {
            AgentApprovalService.request(run, tool, 'Needs review.', null, queue.Id);
            System.assert(false, 'An approval must not wait on a queue nobody can decide.');
        } catch (AgentApprovalService.AssignmentException expected) {
            System.assert(expected.getMessage().contains('no active member'));
        }
    }

    private class AcceptedLoopback implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(202);
            response.setBody('{}');
            return response;
        }
    }

    private class Fixture {
        Id runId;
        Id commandId;
        Id approvalId;
        Id approverId;
    }

    private static Fixture waitingApproval(Integer maxModelCalls, Integer maxToolCalls) {
        Id approverId = AgentKernelTestFactory.approverUser();
        Fixture fixture = waitingApproval(maxModelCalls, maxToolCalls, approverId);
        fixture.approverId = approverId;
        return fixture;
    }

    /**
     * A Delegated Principal run, as approvals require, whose service user is
     * the running user and whose tool call waits on an Agent Approval owned by ownerId.
     */
    private static Fixture waitingApproval(Integer maxModelCalls, Integer maxToolCalls, Id ownerId) {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(maxModelCalls, maxToolCalls);
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'reviewed_tool', '{"type":"object"}');
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        AgentKernelTestFactory.acceptLoopback(started);
        AgentKernelTestFactory.applyOutcome(
            AgentKernelModels.continueWith(
                started.runId,
                started.commandId,
                started.revision,
                started.operationKey,
                null,
                new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_TOOL, '{}', tool.DeveloperName__c)
            )
        );
        AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
        AgentCommand__c command = AgentKernelTestFactory.getCommand(run.CurrentCommand__c);
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = 'approval-scenario-lease';
        command.LeaseExpiresAt__c = System.now().addMinutes(5);
        command.AttemptNumber__c = 1;
        AgentKernelTestFactory.updateRecord(command);
        AgentApprovalService.Request request = AgentKernelTestFactory.approvalRequest(ownerId);
        if (ownerId.getSObjectType() == Group.SObjectType) {
            request.approverType = AgentKernelModels.APPROVER_QUEUE;
        }
        AgentKernel.waitForApproval(run.Id, command.Id, command.ExpectedRunRevision__c, command.OperationKey__c, 'approval-scenario-lease', request);
        Fixture fixture = new Fixture();
        fixture.runId = run.Id;
        fixture.commandId = command.Id;
        fixture.approvalId = AgentKernelTestFactory.pendingApproval(run.Id).Id;
        return fixture;
    }
}
