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
private class ToolExecutionUserAccessTest {
    /** An execution user on Minimum Access who may read Account and Account.Industry, nothing more. */
    private static User executionUser() {
        User principal = new User(
            Alias = 'exacc',
            Email = 'execution-access@example.com',
            Username = 'execution-access-' + Crypto.getRandomInteger() + '@example.com',
            LastName = 'Execution Access User',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Minimum Access - Salesforce' LIMIT 1]
            .Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(AgentKernelTestFactory.self()) {
            insert principal;
            PermissionSet accountReader = new PermissionSet(Name = 'ExecAccessAccountRead' + Math.abs(Crypto.getRandomInteger()), Label = 'Account reader');
            insert accountReader;
            insert new ObjectPermissions(ParentId = accountReader.Id, SobjectType = 'Account', PermissionsRead = true);
            insert new FieldPermissions(ParentId = accountReader.Id, SobjectType = 'Account', Field = 'Account.Industry', PermissionsRead = true);
            insert new PermissionSetAssignment(AssigneeId = principal.Id, PermissionSetId = accountReader.Id);
        }
        AgentKernelTestFactory.grant(principal.Id, new List<String>{ AgentKernelTestFactory.SERVICE_PRINCIPAL });
        return principal;
    }

    private static AgentTool__c recordTool(Id definitionId, String toolType, String configuration) {
        return new AgentTool__c(
            Name = 'Access check tool',
            AgentDefinition__c = definitionId,
            DeveloperName__c = 'access_check_tool',
            Description__c = 'Reads an Account.',
            ToolType__c = toolType,
            ImplementationConfiguration__c = configuration,
            IsActive__c = true,
            SortOrder__c = 1
        );
    }

    @IsTest
    static void savingAToolTheExecutionUserCannotUseFailsWithWhatIsMissing() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        User principal = executionUser();
        AgentKernelTestFactory.useDelegatedPrincipal(definition, principal.Id);

        Database.SaveResult saved = Database.insert(
            recordTool(definition.Id, 'QueryRecords', '{"query":"SELECT Name, Industry, Description FROM Account WHERE Id = :anchorId LIMIT 1"}'),
            false
        );

        System.assertEquals(false, saved.isSuccess(), 'The execution user cannot read Account.Description.');
        String message = saved.getErrors()[0].getMessage();
        System.assert(message.contains('Execution Access User'), message);
        System.assert(message.contains('read Account.Description'), message);
        System.assert(!message.contains('Account.Industry'), 'Fields the user can read are not listed: ' + message);
    }

    @IsTest
    static void aQueryIsCheckedForParentBindAndSortFields() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition, executionUser().Id);

        Database.SaveResult saved = Database.insert(
            recordTool(
                definition.Id,
                'QueryRecords',
                '{"query":"SELECT Name, Parent.AnnualRevenue FROM Account WHERE Rating = :rating ORDER BY NumberOfEmployees LIMIT 5"}'
            ),
            false
        );

        System.assertEquals(false, saved.isSuccess());
        String message = saved.getErrors()[0].getMessage();
        System.assert(message.contains('Account.AnnualRevenue'), 'A parent field is checked on its own object: ' + message);
        System.assert(message.contains('Account.Rating'), 'A bind field is checked: ' + message);
        System.assert(message.contains('Account.NumberOfEmployees'), 'A sort field is checked: ' + message);
    }

    @IsTest
    static void aToolTheExecutionUserCanUseSaves() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition, executionUser().Id);

        insert recordTool(definition.Id, 'QueryRecords', '{"query":"SELECT Name, Industry FROM Account WHERE Id = :anchorId LIMIT 1"}');

        System.assertEquals(1, [SELECT COUNT() FROM AgentTool__c WHERE AgentDefinition__c = :definition.Id]);
    }

    @IsTest
    static void anUpdateToolNeedsEditAccess() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition, executionUser().Id);

        Database.SaveResult saved = Database.insert(
            recordTool(definition.Id, 'UpdateRecord', '{"objectApiName":"Account","fields":["Industry"],"anchorRecordOnly":true}'),
            false
        );

        System.assertEquals(false, saved.isSuccess());
        System.assert(saved.getErrors()[0].getMessage().contains('cannot edit Account'), saved.getErrors()[0].getMessage());
    }

    @IsTest
    static void initiatingUserAgentsAreNotCheckedAndValidateReportsTheGapOnceDelegated() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        insert recordTool(definition.Id, 'QueryRecords', '{"query":"SELECT Name, Description FROM Account WHERE Id = :anchorId LIMIT 1"}');
        AgentKernelTestFactory.useDelegatedPrincipal(definition, executionUser().Id);

        AgentConfigurationValidationService.ValidationRequest request = new AgentConfigurationValidationService.ValidationRequest();
        request.definitionId = definition.Id;
        AgentConfigurationValidationService.ValidationReport report = AgentConfigurationValidationService.validate(request);

        Boolean reported = false;
        for (AgentConfigurationValidationService.ValidationIssue issue : report.issues) {
            reported = reported || (issue.code == 'EXECUTION_USER_ACCESS_MISSING' && issue.message.contains('Account.Description'));
        }
        System.assert(reported, 'Validate reports access the execution user lost or never had: ' + JSON.serialize(report.issues));
        System.assertEquals(false, report.isValid);
    }

    @IsTest
    static void missingAccessNamesTheObjectWhenTheObjectItselfIsMissing() {
        User principal = executionUser();
        System.assertEquals(
            new List<String>{ 'Contact' },
            AttendedAccessService.missingAccess(principal.Id, Contact.SObjectType, new Set<String>{ 'Email' }, AttendedAccessService.Operation.READABLE)
        );
        System.assertEquals(
            0,
            AttendedAccessService.missingAccess(principal.Id, Account.SObjectType, new Set<String>{ 'Industry' }, AttendedAccessService.Operation.READABLE)
                .size()
        );
    }
}
