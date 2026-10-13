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
private without sharing class AgentExtensionInvokerTest {
    @TestSetup
    static void createSharingUser() {
        Profile restrictedProfile = [
            SELECT Id
            FROM Profile
            WHERE UserLicense.Name = 'Salesforce' AND Name != 'System Administrator'
            LIMIT 1
        ];
        User otherUser = new User(
            Alias = 'shrctx',
            Email = 'sharing-context@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'Sharing Context',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = restrictedProfile.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            Username = 'sharing-context-' + UserInfo.getOrganizationId() + '@example.com'
        );
        insert otherUser;
        PermissionSet trustResolver = [SELECT Id FROM PermissionSet WHERE Name = 'AgentKernelTrustResolver' LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = otherUser.Id, PermissionSetId = trustResolver.Id);
    }

    @IsTest
    static void inheritedSharingAppliesInConstructorAndInvocation() {
        AgentKernelModels.StartResult started = AgentKernelTestFactory.startRunWithoutDispatch(AgentKernelTestFactory.createDefinition());
        KernelTestInheritedSharingContext.hiddenRunId = started.runId;
        User otherUser = [SELECT Id FROM User WHERE Alias = 'shrctx' LIMIT 1];
        System.runAs(otherUser) {
            AgentContextProvider__c configuration = new AgentContextProvider__c(ImplementationReference__c = 'KernelTestInheritedSharingContext');
            AgentKernelModels.ContextResponse response = AgentExtensionInvoker.provideContext(configuration, new AgentKernelModels.ContextRequest());
            System.assertEquals('visible rows: 0', response.content);
            System.assertEquals(0, KernelTestInheritedSharingContext.constructorRows);
            System.assertEquals(0, KernelTestInheritedSharingContext.invocationRows);
        }
    }
}
