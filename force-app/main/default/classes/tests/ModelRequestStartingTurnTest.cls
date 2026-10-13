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
private class ModelRequestStartingTurnTest {
    private static String turn(String input, Id anchorId) {
        AgentRun__c run = new AgentRun__c(Input__c = input, AnchorRecordId__c = anchorId == null ? null : String.valueOf(anchorId));
        return ModelRequestAssembler.startingTurn(run, new CommandAttemptRuntime(null, null, null, null, null, 0, null, null, null));
    }

    private static Map<String, Object> record(String turnJson) {
        return (Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(turnJson)).get('record');
    }

    @IsTest
    static void aRunFromARecordWithNoInputNamesTheRecord() {
        Account account = new Account(Name = 'Northwind Traders');
        insert account;

        String first = turn('{}', account.Id);

        Map<String, Object> described = record(first);
        System.assertEquals('Account', described.get('object'));
        System.assertEquals(String.valueOf(account.Id), described.get('id'));
        System.assertEquals('Northwind Traders', described.get('name'), 'The name comes from the object\'s name field.');
        System.assert(!first.contains('"input"'), 'An empty input is not sent: ' + first);
        System.assert(first.startsWith('{"record":{"object":"Account","id":'), 'Object, Id, then name: ' + first);
    }

    @IsTest
    static void theCallersInputFollowsTheRecord() {
        Account account = new Account(Name = 'Northwind Traders');
        insert account;

        Map<String, Object> first = (Map<String, Object>) JSON.deserializeUntyped(turn('{"request":"Check the credit limit."}', account.Id));
        System.assertEquals('Check the credit limit.', ((Map<String, Object>) first.get('input')).get('request'));

        first = (Map<String, Object>) JSON.deserializeUntyped(turn('Check the credit limit.', account.Id));
        System.assertEquals('Check the credit limit.', first.get('input'), 'Plain text input is kept as text.');
    }

    @IsTest
    static void aRunWithNoRecordKeepsItsInputOrStartsFromTheInstructions() {
        System.assertEquals('{"request":"Triage"}', turn('{"request":"Triage"}', null));
        System.assertEquals(ModelRequestAssembler.NO_INPUT, turn('{}', null));
        System.assertEquals(ModelRequestAssembler.NO_INPUT, turn(null, null));
    }

    @IsTest
    static void theNameIsLeftOutForAUserWhoCannotReadTheRecord() {
        Account account = new Account(Name = 'Northwind Traders');
        insert account;
        User noAccess = new User(
            Alias = 'noacc',
            Email = 'starting-turn@example.com',
            Username = 'starting-turn-' + Crypto.getRandomInteger() + '@example.com',
            LastName = 'No Access',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert noAccess;

        String first;
        System.runAs(noAccess) {
            first = turn('{}', account.Id);
        }

        Map<String, Object> described = record(first);
        System.assertEquals(String.valueOf(account.Id), described.get('id'), 'The run still names its record.');
        System.assert(!described.containsKey('name'), 'A name the run\'s user cannot read is not sent: ' + first);
    }
}
