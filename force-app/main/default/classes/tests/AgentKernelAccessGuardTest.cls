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

@IsTest(SeeAllData=false)
private class AgentKernelAccessGuardTest {
    private static final String SHARING_USER_ALIAS = 'runshare';

    @TestSetup
    static void createSharingUser() {
        Profile profile = [SELECT Id FROM Profile WHERE UserLicense.Name = 'Salesforce' AND Name != 'System Administrator' LIMIT 1];
        User sharingUser = new User(
            Alias = SHARING_USER_ALIAS,
            Email = 'run-sharing@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Run Sharing',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'run-sharing-' + System.now().getTime() + '@example.com'
        );
        insert sharingUser;
        PermissionSet trustResolver = [SELECT Id FROM PermissionSet WHERE Name = 'AgentKernelTrustResolver' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = sharingUser.Id, PermissionSetId = trustResolver.Id);
    }

    /**
     * The documented runner setup: a Minimum Access profile plus only Run Agents.
     * Core's other tests clone the admin profile, which hid that Run Agents could
     * not read an agent definition's identity lookup.
     */
    @IsTest
    static void aRunnerWithOnlyRunAgentsStartsASharedAgentAndNoOther() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        User runner = minimumAccessRunner('runonly');
        User outsider = minimumAccessRunner('runnone');
        insert new AgentDefinition__Share(ParentId = definition.Id, UserOrGroupId = runner.Id, AccessLevel = 'Read', RowCause = 'Manual');
        AgentConfigService.clearCacheForTest();

        System.runAs(runner) {
            AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
            System.assertNotEquals(null, started.runId, 'A runner may start an agent with an identity that is shared with them.');
        }
        AgentConfigService.clearCacheForTest();
        System.runAs(outsider) {
            try {
                AgentKernelTestFactory.startRunWithoutDispatch(definition);
                System.assert(false, 'A runner the agent is not shared with must be refused.');
            } catch (AgentKernelException.NotFoundException expected) {
                System.assertEquals('You can\'t run agent ' + definition.DeveloperName__c + '. Ask your admin to share it with you.', expected.getMessage());
            }
        }
        System.assertEquals(1, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id], 'The refused start made no run.');
    }

    @IsTest
    static void anUnknownAgentNameIsReportedPlainly() {
        AgentKernelModels.StartRequest request = new AgentKernelModels.StartRequest();
        request.developerName = 'no_such_agent';
        try {
            AgentKernel.startRun(request, AgentKernelModels.INVOCATION_APEX);
            System.assert(false, 'An unknown agent must not start.');
        } catch (AgentKernelException.NotFoundException expected) {
            System.assertEquals('No active agent has the Id or API name no_such_agent.', expected.getMessage());
        }
    }

    @IsTest
    static void aUserWithoutRunAgentsCannotStartAnAgent() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        User stranger = new User(
            Alias = 'norun',
            Email = 'norun@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'No Run Agents',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'norun-' + Crypto.getRandomInteger() + '@example.com'
        );
        System.runAs(AgentKernelTestFactory.self()) {
            insert stranger;
        }
        // The platform may refuse to share an object with a user who has no access to it; either way the start must fail.
        Database.insert(new AgentDefinition__Share(ParentId = definition.Id, UserOrGroupId = stranger.Id, AccessLevel = 'Read', RowCause = 'Manual'), false);
        AgentConfigService.clearCacheForTest();

        Boolean refused = false;
        System.runAs(stranger) {
            try {
                AgentKernelTestFactory.startRunWithoutDispatch(definition);
            } catch (Exception expected) {
                refused = true;
            }
        }

        System.assert(refused, 'Sharing alone is not enough; the user also needs Run Agents.');
        System.assertEquals(0, [SELECT COUNT() FROM AgentRun__c WHERE AgentDefinition__c = :definition.Id]);
    }

    private static User minimumAccessRunner(String alias) {
        User runner = new User(
            Alias = alias,
            Email = alias + '@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Runner ' + alias,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = alias + '-' + Crypto.getRandomInteger() + '@example.com'
        );
        System.runAs(AgentKernelTestFactory.self()) {
            insert runner;
        }
        AgentKernelTestFactory.grant(runner.Id, new List<String>{ 'AgentKernelRunAgents' });
        return runner;
    }

    @IsTest
    static void directKernelMutationCannotBypassRunAccess() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        Profile profile = [SELECT Id FROM Profile WHERE UserLicense.Name = 'Salesforce' AND Name != 'System Administrator' LIMIT 1];
        User unprivileged = new User(
            Alias = 'noguard',
            Email = 'kernel-guard@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Kernel Guard',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = profile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'kernel-guard-' + System.now().getTime() + '@example.com'
        );
        insert unprivileged;

        System.runAs(unprivileged) {
            try {
                AgentKernelTestFactory.start(definition.Id, '{}');
                System.assert(false, 'Direct kernel start must enforce definition access.');
            } catch (AgentKernelException.NotFoundException expected) {
            }
            try {
                AgentKernel.cancel(started.runId, started.revision, 'unauthorized');
                System.assert(false, 'Direct kernel mutation must enforce record access.');
            } catch (AgentKernelException.NotFoundException expected) {
            }
        }
        System.assertEquals(AgentKernelModels.RUN_STATUS_RUNNING, [SELECT Status__c FROM AgentRun__c WHERE Id = :started.runId].Status__c);
    }

    @IsTest
    static void privateRunRequiresExplicitRecordAccess() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(definition);
        User sharingUser = [SELECT Id FROM User WHERE Alias = :SHARING_USER_ALIAS LIMIT 1];

        System.runAs(sharingUser) {
            try {
                AgentKernelAccessGuard.assertRunReadable(started.runId);
                System.assert(false, 'An unshared private run must not be readable.');
            } catch (AgentKernelException.NotFoundException expected) {
            }
        }

        insert new AgentRun__Share(
            ParentId = started.runId,
            UserOrGroupId = sharingUser.Id,
            AccessLevel = 'Read',
            RowCause = Schema.AgentRun__Share.RowCause.Manual
        );

        System.runAs(sharingUser) {
            AgentKernelAccessGuard.assertRunReadable(started.runId);
            System.assertEquals(started.runId, AgentRunService.getRun(started.runId).id);
        }
    }
}
