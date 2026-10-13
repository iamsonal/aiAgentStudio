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

@IsTest
private class StandardUpdateRecordToolTest {
    private static AgentKernelModels.ToolRequest request(String config, String input) {
        AgentKernelModels.ToolRequest toolRequest = new AgentKernelModels.ToolRequest();
        toolRequest.toolName = 'standard_update';
        toolRequest.input = input;
        toolRequest.implementationConfiguration = config;
        return toolRequest;
    }

    @IsTest
    static void updatesAccountIndustry() {
        Account account = new Account(Name = 'ToolAuthoring Update Target');
        insert account;

        AgentKernelModels.ToolResponse response = new StandardUpdateRecordTool()
            .execute(request(accountConfig(), '{"recordId":"' + account.Id + '","recordData":{"Industry":"Energy"}}'));

        System.assertEquals(true, response.isSuccess);
        Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(response.output);
        System.assertEquals(account.Id, (Id) output.get('id'));
        System.assertEquals('Energy', [SELECT Industry FROM Account WHERE Id = :account.Id LIMIT 1].Industry);
    }

    @IsTest
    static void appliesOperatorDefaultFields() {
        Account account = new Account(Name = 'Default update target');
        insert account;

        new StandardUpdateRecordTool()
            .execute(
                request(
                    '{"objectApiName":"Account","fields":["Industry"],"defaultFieldValues":{"Description":"Updated by AI Agent"}}',
                    '{"recordId":"' + account.Id + '","recordData":{"Industry":"Energy"}}'
                )
            );

        System.assertEquals('Updated by AI Agent', [SELECT Description FROM Account WHERE Id = :account.Id].Description);
    }

    @IsTest
    static void rejectsBadIdentityAndMissingFields() {
        Account account = new Account(Name = 'ToolAuthoring Update Target 2');
        insert account;

        assertPermanent(accountConfig(), '{"recordData":{"Industry":"Energy"}}', 'recordId');
        assertPermanent(accountConfig(), '{"recordId":"not-an-id","recordData":{"Industry":"Energy"}}', 'recordId is invalid');
        assertPermanent(accountConfig(), '{"recordId":"001000000000000AAA","recordData":{"Industry":"Energy"}}', 'not found or is not visible');
        assertPermanent(accountConfig(), '{"recordId":"' + account.Id + '","recordData":{}}', 'at least one field value');
    }

    @IsTest
    static void rejectsUnknownFieldAndMissingConfiguration() {
        Account account = new Account(Name = 'ToolAuthoring Update Target 3');
        insert account;

        assertPermanent(accountConfig(), '{"recordId":"' + account.Id + '","recordData":{"Nope__c":"x"}}', 'may not set Nope__c');
        assertPermanent(
            '{"objectApiName":"Account"}',
            '{"recordId":"' + account.Id + '","recordData":{"Industry":"Energy"}}',
            'List the fields the agent may update'
        );
        assertPermanent(null, '{"recordId":"' + account.Id + '","recordData":{"Industry":"Energy"}}', 'implementation configuration');
    }

    @IsTest
    static void anchorRecordOnlyUpdatesOnlyTheRunsRecord() {
        Account anchor = new Account(Name = 'Anchor customer');
        Account other = new Account(Name = 'Other customer');
        insert new List<Account>{ anchor, other };
        String config = '{"objectApiName":"Account","fields":["Industry"],"anchorRecordOnly":true}';

        AgentKernelModels.ToolRequest steered = request(config, '{"recordId":"' + other.Id + '","recordData":{"Industry":"Energy"}}');
        steered.principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, UserInfo.getUserId(), anchor.Id, null);
        Boolean refused = false;
        try {
            new StandardUpdateRecordTool().execute(steered);
        } catch (AgentKernelException.PermanentException expected) {
            refused = true;
        }
        System.assert(refused, 'The model cannot choose a record when the tool is limited to the run\'s record.');
        System.assertEquals(null, [SELECT Industry FROM Account WHERE Id = :other.Id].Industry);

        AgentKernelModels.ToolRequest allowed = request(config, '{"recordData":{"Industry":"Energy"}}');
        allowed.principal = steered.principal;
        new StandardUpdateRecordTool().execute(allowed);
        System.assertEquals('Energy', [SELECT Industry FROM Account WHERE Id = :anchor.Id].Industry);
    }

    @IsTest
    static void replacedTargetSettingsAreRefusedNotIgnored() {
        AgentKernelModels.ToolConfiguration old = new AgentKernelModels.ToolConfiguration();
        old.implementationConfiguration = '{"objectApiName":"Account","fields":["Industry"],"target":"Anchor Record"}';
        System.assert(String.join(new StandardUpdateRecordTool().validateConfiguration(old), ' ').contains('anchorRecordOnly'));
        assertPermanent(old.implementationConfiguration, '{"recordData":{"Industry":"Energy"}}', 'anchorRecordOnly');
    }

    @IsTest
    static void fixedFieldValuesFillRunValues() {
        Account anchor = new Account(Name = 'Run record');
        insert anchor;
        Contact contact = new Contact(LastName = 'Run value target');
        insert contact;
        String config =
            '{"objectApiName":"Contact","fields":["Title"],' +
            '"defaultFieldValues":{"OwnerId":":initiatingUserId","Birthdate":":today","AccountId":":anchorId"}}';
        AgentKernelModels.ToolRequest call = request(config, '{"recordId":"' + contact.Id + '","recordData":{"Title":":principalUserId"}}');
        call.principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, UserInfo.getUserId(), anchor.Id, null);

        new StandardUpdateRecordTool().execute(call);

        Contact updated = [SELECT OwnerId, Birthdate, AccountId, Title FROM Contact WHERE Id = :contact.Id];
        System.assertEquals(UserInfo.getUserId(), updated.OwnerId);
        System.assertEquals(Date.today(), updated.Birthdate);
        System.assertEquals(anchor.Id, updated.AccountId);
        System.assertEquals(':principalUserId', updated.Title, 'A :name the model sends is plain text, never a run value.');
    }

    @IsTest
    static void runValuesThatDoNotFitAreRefusedAtSave() {
        System.assert(contactProblems('{"Title":":today"}').contains('only in a Date field'));
        System.assert(contactProblems('{"Birthdate":":initiatingUserId"}').contains('lookup field that can point to a user'));
        System.assert(contactProblems('{"Title":":ownerId"}').contains('is not a run value'));
        System.assertEquals('', contactProblems('{"OwnerId":":principalUserId","Title":"Plain text"}'));

        AgentKernelModels.ToolRequest noRecord = request(
            '{"objectApiName":"Contact","fields":["Title"],"defaultFieldValues":{"AccountId":":anchorId"}}',
            '{"recordId":"003000000000000AAA","recordData":{"Title":"x"}}'
        );
        Boolean refused = false;
        try {
            new StandardUpdateRecordTool().execute(noRecord);
        } catch (AgentKernelException.PermanentException expected) {
            refused = expected.getMessage().contains('not started on a record');
        }
        System.assert(refused, 'A run without a record cannot fill :anchorId.');
    }

    private static String contactProblems(String defaults) {
        AgentKernelModels.ToolConfiguration configuration = new AgentKernelModels.ToolConfiguration();
        configuration.implementationConfiguration = '{"objectApiName":"Contact","fields":["Department"],"defaultFieldValues":' + defaults + '}';
        return String.join(new StandardUpdateRecordTool().validateConfiguration(configuration), ' ');
    }

    private static String accountConfig() {
        return '{"objectApiName":"Account","fields":["Industry"]}';
    }

    private static void assertPermanent(String config, String input, String expectedFragment) {
        Boolean rejected = false;
        try {
            new StandardUpdateRecordTool().execute(request(config, input));
        } catch (AgentKernelException.PermanentException expected) {
            rejected = expected.getMessage().contains(expectedFragment);
        }
        System.assert(rejected, 'Expected permanent rejection containing: ' + expectedFragment);
    }
}
