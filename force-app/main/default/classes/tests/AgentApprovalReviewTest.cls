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

/** Scenario 3: the approver sees what changes, on which record, why, and by when; nobody else does. */
@IsTest
private class AgentApprovalReviewTest {
    @IsTest
    static void approverSeesTheInputsTheRecordAndTheExplanation() {
        Case anchor = new Case(Subject = 'Team cannot log in', Priority = 'Medium');
        insert anchor;
        Fixture fixture = new Fixture(anchor.Id, '{"recordData":{"Priority":"High"}}');

        AgentApprovalReview.Request request;
        System.runAs(new User(Id = fixture.approverId)) {
            request = AgentApprovalActions.reviewRequest(fixture.approval.Id);
        }

        System.assertEquals('Kernel Test Tool set_priority', request.title);
        System.assertEquals(anchor.Id, request.anchor.recordId);
        System.assertEquals([SELECT CaseNumber FROM Case WHERE Id = :anchor.Id].CaseNumber, request.anchor.name);
        System.assertEquals(1, request.inputs.size(), 'A nested object is shown by its own names.');
        System.assertEquals('Priority', request.inputs[0].label);
        System.assertEquals('High', request.inputs[0].value);
        System.assertEquals('Ask before raising.', request.rationale);
        System.assertEquals('Approval required.', request.reason);
        System.assertEquals(false, request.hasProtectedValues);
        System.assertEquals(AgentKernelModels.APPROVAL_EXPIRY_DENY, request.expiryAction);
        System.assertNotEquals(null, request.agentName);
    }

    @IsTest
    static void aRecordTheApproverCannotOpenStaysUnnamed() {
        Case gone = new Case(Subject = 'Deleted before review');
        insert gone;
        // Core refuses to start a run on a record the starter cannot read, so the record goes after the call waits.
        Fixture fixture = new Fixture(gone.Id, '{"recordData":{"Priority":"High"}}');
        delete gone;

        AgentApprovalReview.Request request;
        System.runAs(new User(Id = fixture.approverId)) {
            request = AgentApprovalActions.reviewRequest(fixture.approval.Id);
        }

        System.assertEquals(null, request.anchor.name, 'An unreadable record is never named.');
        System.assertEquals('Case', request.anchor.objectLabel);
    }

    @IsTest
    static void otherToolsShowTheirInputsWithPlaceholdersKept() {
        Fixture fixture = new Fixture(null, '{"amount":1200,"customerEmail":"{{EMAIL_1_9f2c61ab}}"}');

        AgentApprovalReview.Request request;
        System.runAs(new User(Id = fixture.approverId)) {
            request = AgentApprovalActions.reviewRequest(fixture.approval.Id);
        }

        System.assertEquals(null, request.anchor);
        System.assertEquals(2, request.inputs.size());
        System.assertEquals(true, request.hasProtectedValues, 'Placeholders stay; Review Input reveals them with an audit.');
        Map<String, String> values = new Map<String, String>();
        for (AgentApprovalReview.InputValue input : request.inputs) {
            values.put(input.label, input.value);
        }
        System.assertEquals('1200', values.get('amount'));
        System.assertEquals('{{EMAIL_1_9f2c61ab}}', values.get('customerEmail'));
    }

    @IsTest
    static void someoneWhoCannotDecideIsRefused() {
        Fixture fixture = new Fixture(null, '{"amount":1200}');
        User outsider = AgentKernelTestFactory.userWith(new List<String>{ 'AgentKernelHumanDecision' });

        System.runAs(outsider) {
            try {
                AgentApprovalActions.reviewRequest(fixture.approval.Id);
                System.assert(false, 'A Human Decision user who is not assigned cannot review the request.');
            } catch (AuraHandledException expected) {
                System.assert(expected.getMessage().contains('assigned to other approvers'), expected.getMessage());
            }
        }
    }

    @IsTest
    static void aDecidedApprovalShowsWhoDecided() {
        Fixture fixture = new Fixture(null, '{"amount":1200}');
        AgentApprovalService.Authorization authorization = new AgentApprovalService.Authorization();
        authorization.deciderId = fixture.approverId;
        AgentApprovalService.close(fixture.approval, AgentKernelModels.APPROVAL_STATUS_APPROVED, authorization, 'Fine.');

        AgentApprovalReview.Request request = AgentApprovalActions.reviewRequest(fixture.approval.Id);

        System.assertEquals(AgentKernelModels.APPROVAL_STATUS_APPROVED, request.status);
        System.assertEquals('Fine.', request.decisionComment);
        AgentApproval__c stored = [SELECT Reason__c, ToolName__c FROM AgentApproval__c WHERE Id = :fixture.approval.Id];
        System.assertEquals(stored.Reason__c, request.reason, 'A closed approval still says why a person had to decide.');
        System.assertEquals('Set priority', request.title, 'A closed approval names the tool, not just "Agent request".');
        System.assertEquals(0, request.inputs.size(), 'A closed approval shows the decision, not the request.');
    }

    private class Fixture {
        Id approverId;
        AgentApproval__c approval;

        Fixture(Id anchorId, String input) {
            AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
            AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'set_priority', '{"type":"object"}');
            AgentKernelModels.StartResult started = AgentKernelTestFactory.start(definition.Id, '{"request":"test"}', anchorId);
            AgentRun__c run = AgentKernelTestFactory.getRun(started.runId);
            AgentCommand__c command = AgentKernelTestFactory.insertToolCommand(
                run.Id,
                run.Revision__c,
                tool.DeveloperName__c,
                AgentKernelModels.COMMAND_STATUS_WAITING
            );
            AgentKernelTestFactory.updateRecord(new AgentCommand__c(Id = command.Id, Input__c = input, Rationale__c = 'Ask before raising.'));
            approverId = AgentKernelTestFactory.approverUser();
            AgentApprovalService.Request request = AgentKernelTestFactory.approvalRequest(approverId);
            request.toolId = tool.Id;
            approval = AgentApprovalService.open(run, AgentKernelTestFactory.getCommand(command.Id), request);
        }
    }
}
