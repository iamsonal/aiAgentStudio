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
private class AgentConfigurationValidationServiceTest {
    @IsTest
    static void validDefinitionReturnsDeterministicWarnings() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentConfigurationValidationService.ValidationRequest request = new AgentConfigurationValidationService.ValidationRequest();
        request.definitionId = definition.Id;
        AgentConfigurationValidationService.ValidationReport report = AgentConfigurationValidationService.validate(request);
        System.assertEquals(true, report.isValid);
        System.assert(report.issues.size() >= 2);
        System.assertEquals('NAMED_CREDENTIAL_ACCESS_NOT_PREFLIGHTED', report.issues[0].code);
    }

    @IsTest
    static void unknownModelFailsWhenSavedAndDeactivatedModelFailsPreflight() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.Model__c = 'Unapproved_Model';
        try {
            update definition;
            System.assert(false, 'An active definition must name an active Agent Model.');
        } catch (DmlException expected) {
            System.assert(expected.getMessage().contains('Unapproved_Model'));
        }
        AgentModel__mdt deactivated = AgentKernelTestFactory.kernelTestModel();
        deactivated.IsActive__c = false;
        AgentModelService.setTestModels(new List<AgentModel__mdt>{ deactivated });

        AgentConfigurationValidationService.ValidationReport report = validate(definition.Id);

        System.assertEquals(false, report.isValid);
        System.assert(codes(report).contains('MODEL_NOT_APPROVED'));
    }

    @IsTest
    static void deactivatedServiceUserFailsPreflight() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentExecutionIdentity__c identity = AgentKernelTestFactory.useDelegatedPrincipal(definition);
        update new AgentExecutionIdentity__c(Id = identity.Id, IsActive__c = false);

        AgentConfigurationValidationService.ValidationReport report = validate(definition.Id);

        System.assertEquals(false, report.isValid);
        System.assert(codes(report).contains('EXECUTION_IDENTITY_UNUSABLE'));
    }

    @IsTest
    static void delegatedPrincipalWithActiveServiceUserPassesPreflight() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);

        AgentConfigurationValidationService.ValidationReport report = validate(definition.Id);

        System.assertEquals(true, report.isValid);
        System.assertEquals(false, codes(report).contains('EXECUTION_IDENTITY_UNUSABLE'));
        System.assert(codes(report).contains('NAMED_CREDENTIAL_ACCESS_NOT_PREFLIGHTED'));
    }

    @IsTest
    static void unscopedUpdateToolIsFlaggedUntilItIsScoped() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = new AgentTool__c(
            Name = 'set_priority',
            AgentDefinition__c = definition.Id,
            DeveloperName__c = 'set_priority',
            Description__c = 'Sets a case priority.',
            ToolType__c = 'UpdateRecord',
            ImplementationConfiguration__c = '{"objectApiName":"Case","fields":["Priority"]}',
            IsActive__c = true
        );
        AgentKernelTestFactory.insertRecord(tool);

        System.assert(codes(validate(definition.Id)).contains('UNSCOPED_RECORD_UPDATE'));

        AgentKernelTestFactory.updateRecord(
            new AgentTool__c(
                Id = tool.Id,
                InputSchema__c = null,
                ImplementationConfiguration__c = '{"objectApiName":"Case","fields":["Priority"],"anchorRecordOnly":true}'
            )
        );
        System.assertEquals(false, codes(validate(definition.Id)).contains('UNSCOPED_RECORD_UPDATE'));
    }

    @IsTest
    static void aPolicyWithNoToolToDecideIsFlagged() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'refund_tool', '{"type":"object"}');
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        update definition;

        AgentConfigurationValidationService.ValidationReport report = validate(definition.Id);
        System.assertEquals(true, report.isValid, 'The tools still run; the policy is only never asked.');
        System.assert(codes(report).contains('POLICY_NEVER_RUNS'));

        tool.ApprovalMode__c = AgentKernelModels.APPROVAL_DECIDED_BY_POLICY;
        tool.ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY;
        AgentKernelTestFactory.updateRecord(tool);
        System.assertEquals(false, codes(validate(definition.Id)).contains('POLICY_NEVER_RUNS'), 'The policy decides the tool now.');
    }

    @IsTest
    static void aPolicyDecidedToolNeedsTheAgentsPolicy() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'refund_tool', '{"type":"object"}');
        AgentTool__c decided = new AgentTool__c(
            Id = tool.Id,
            ApprovalMode__c = AgentKernelModels.APPROVAL_DECIDED_BY_POLICY,
            ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY
        );

        Database.SaveResult refused = Database.update(decided, false);
        System.assertEquals(false, refused.isSuccess(), 'Nothing would decide the tool without a policy.');
        System.assertEquals(AgentApprovalService.POLICY_REQUIRED_MESSAGE, refused.getErrors()[0].getMessage());

        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        update definition;
        AgentKernelTestFactory.updateRecord(decided);
        definition.ToolAuthorizationPolicyClass__c = null;
        Database.SaveResult cleared = Database.update(definition, false);
        System.assertEquals(false, cleared.isSuccess(), 'Clearing the policy would leave the tool undecided.');
        System.assert(cleared.getErrors()[0].getMessage().contains('refund_tool'), cleared.getErrors()[0].getMessage());
    }

    @IsTest
    static void approvalSettingsMatchTheApprovalChoice() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        definition.ToolAuthorizationPolicyClass__c = 'KernelTestToolPolicy';
        update definition;
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'refund_tool', '{"type":"object"}');
        Id approverId = AgentKernelTestFactory.approverUser();

        assertRefused(
            new AgentTool__c(Id = tool.Id, ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY),
            'Approval is Not Required, so clear the approver, Approval Timeout, and When Approval Expires.'
        );
        assertRefused(
            new AgentTool__c(
                Id = tool.Id,
                ApprovalMode__c = AgentKernelModels.APPROVAL_ALWAYS_REQUIRED,
                ApproverType__c = AgentKernelModels.APPROVER_USER,
                ApproverUser__c = approverId
            ),
            'Choose When Approval Expires for a tool whose calls can wait for approval.'
        );
        assertRefused(
            new AgentTool__c(
                Id = tool.Id,
                ApprovalMode__c = AgentKernelModels.APPROVAL_ALWAYS_REQUIRED,
                ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY
            ),
            'Choose an Approver Type for a tool whose Approval is Always Required.'
        );
        assertRefused(
            new AgentTool__c(
                Id = tool.Id,
                ApprovalMode__c = AgentKernelModels.APPROVAL_DECIDED_BY_POLICY,
                ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY,
                ApproverType__c = AgentKernelModels.APPROVER_USER,
                ApproverUser__c = approverId
            ),
            'Approval is Decided by Policy, so the policy names the approver. Clear Approver Type, Approver User, and Approver Queue.'
        );
        AgentKernelTestFactory.updateRecord(
            new AgentTool__c(
                Id = tool.Id,
                ApprovalMode__c = AgentKernelModels.APPROVAL_DECIDED_BY_POLICY,
                ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_PAUSE,
                ApprovalTimeoutMinutes__c = 60
            )
        );
    }

    private static void assertRefused(AgentTool__c tool, String message) {
        Database.SaveResult result = Database.update(tool, false);
        System.assertEquals(false, result.isSuccess(), message);
        System.assertEquals(message, result.getErrors()[0].getMessage());
    }

    @IsTest
    static void initiatingUserDoesNotRequireServiceUser() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();

        AgentConfigurationValidationService.ValidationReport report = validate(definition.Id);

        System.assertEquals(true, report.isValid);
        System.assertEquals(false, codes(report).contains('EXECUTION_IDENTITY_UNUSABLE'));
    }

    @IsTest
    static void approvalToolOnAgentWithoutIdentityFailsWhenSaved() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'write_case', '{"type":"object"}');

        Database.SaveResult result = Database.update(
            new AgentTool__c(
                Id = tool.Id,
                ApprovalMode__c = AgentKernelModels.APPROVAL_ALWAYS_REQUIRED,
                ApproverType__c = AgentKernelModels.APPROVER_DELIVERY_CHANNEL,
                ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY
            ),
            false
        );

        System.assertEquals(false, result.isSuccess());
        System.assertEquals(AgentDefinitionIdentityRules.APPROVAL_UNSUPPORTED_MESSAGE, result.getErrors()[0].getMessage());
    }

    @IsTest
    static void clearingTheIdentityOfAnApprovalAgentFailsWhenSaved() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentKernelTestFactory.useDelegatedPrincipal(definition);
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'write_case', '{"type":"object"}');
        tool.ApprovalMode__c = AgentKernelModels.APPROVAL_ALWAYS_REQUIRED;
        tool.ApproverType__c = AgentKernelModels.APPROVER_DELIVERY_CHANNEL;
        tool.ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY;
        AgentKernelTestFactory.updateRecord(tool);
        definition.ExecutionIdentity__c = null;

        Database.SaveResult result = Database.update(definition, false);

        System.assertEquals(false, result.isSuccess());
        System.assertEquals(AgentDefinitionIdentityRules.CLEAR_IDENTITY_REFUSED_MESSAGE, result.getErrors()[0].getMessage());
    }

    @IsTest
    static void initiatingUserChainDepthFailsWhenSaved() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition(5, 10, 2);
        definition.MaxModelCalls__c = 60;
        definition.MaxToolCalls__c = 37;

        Database.SaveResult result = Database.update(definition, false);

        System.assertEquals(false, result.isSuccess(), 'Sixty model calls, 37 tool calls, and two retries need 101 chained jobs.');
        System.assert(result.getErrors()[0].getMessage().contains('chain at most 100 jobs'));
    }

    @IsTest
    static void invalidRetryOverrideFailsWhenSaved() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.MaxRetries__c = 100;

        Database.SaveResult result = Database.update(definition, false);

        System.assertEquals(false, result.isSuccess());
        System.assertEquals('MaxRetries__c', result.getErrors()[0].getFields()[0]);
    }

    @IsTest
    static void aggregatesMultipleConfigurationIssues() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        definition.IsActive__c = false;
        definition.Instructions__c = null;
        definition.ToolAuthorizationPolicyClass__c = 'MissingPolicyClass';
        definition.OutputSchema__c = '{"unsupported":true}';
        update definition;
        AgentModel__mdt missingAdapter = AgentKernelTestFactory.kernelTestModel();
        missingAdapter.ModelAdapterClass__c = 'MissingClass';
        AgentModelService.setTestModels(new List<AgentModel__mdt>{ missingAdapter });
        AgentExecutionPolicyService.Policy badPolicy = AgentExecutionPolicyService.defaults();
        badPolicy.retryBaseDelaySeconds = 100;
        badPolicy.retryMaxDelaySeconds = 50;
        badPolicy.retainedPayloadCharacters = -1;
        badPolicy.sensitiveJsonKeys = '{bad json}';
        AgentKernelTestFactory.configureExecutionPolicy(badPolicy);

        AgentConfigurationValidationService.ValidationRequest request = new AgentConfigurationValidationService.ValidationRequest();
        request.developerName = definition.DeveloperName__c;
        AgentConfigurationValidationService.ValidationReport report = AgentConfigurationValidationService.validate(request);
        System.assertEquals(false, report.isValid);
        Set<String> codes = new Set<String>();
        for (AgentConfigurationValidationService.ValidationIssue issue : report.issues)
            codes.add(issue.code);
        System.assert(codes.contains('DEFINITION_INACTIVE'));
        System.assert(codes.contains('INSTRUCTIONS_REQUIRED'));
        System.assert(codes.contains('MODEL_ADAPTER_INVALID'));
        System.assert(codes.contains('TOOL_AUTHORIZATION_POLICY_INVALID'));
        System.assert(codes.contains('EXECUTION_POLICY_INVALID'));
        System.assert(codes.contains('OUTPUT_SCHEMA_INVALID'));
    }

    @IsTest
    static void selectorMustContainExactlyOneValue() {
        for (
            AgentConfigurationValidationService.ValidationRequest request : new List<AgentConfigurationValidationService.ValidationRequest>{
                new AgentConfigurationValidationService.ValidationRequest(),
                bothSelectors()
            }
        ) {
            try {
                AgentConfigurationValidationService.validate(request);
                System.assert(false, 'Expected malformed request.');
            } catch (AgentKernelException.ConfigurationException expected) {
                System.assert(expected.getMessage().contains('exactly one'));
            }
        }
    }

    @IsTest
    static void unknownToolTypeIsRejected() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'unknown_type', '{"type":"object"}');
        tool.ToolType__c = 'NoSuchToolType';

        List<AgentConfigurationValidator.Finding> findings = AgentConfigurationValidator.collectErrors(
            definition,
            new List<AgentTool__c>{ tool },
            new List<AgentContextProvider__c>()
        );

        Boolean found = false;
        for (AgentConfigurationValidator.Finding finding : findings) {
            found = found || (finding.code == 'TOOL_TYPE_INVALID' && finding.message.contains('NoSuchToolType'));
        }
        System.assert(found);
    }

    @IsTest
    static void activeToolsRequireAnInputSchema() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'missing_schemas', '{"type":"object"}');
        tool.InputSchema__c = null;

        List<AgentConfigurationValidator.Finding> findings = AgentConfigurationValidator.collectErrors(
            definition,
            new List<AgentTool__c>{ tool },
            new List<AgentContextProvider__c>()
        );
        Set<String> codes = new Set<String>();
        for (AgentConfigurationValidator.Finding finding : findings) {
            codes.add(finding.code);
        }
        System.assert(codes.contains('TOOL_INPUT_SCHEMA_REQUIRED'));
    }

    @IsTest
    static void implementationConfigurationMustBeJsonObject() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'invalid_configuration', '{"type":"object"}');
        tool.ImplementationConfiguration__c = '["not","an","object"]';

        List<AgentConfigurationValidator.Finding> findings = AgentConfigurationValidator.collectErrors(
            definition,
            new List<AgentTool__c>{ tool },
            new List<AgentContextProvider__c>()
        );

        Boolean found = false;
        for (AgentConfigurationValidator.Finding finding : findings) {
            found = found || finding.code == 'TOOL_IMPLEMENTATION_CONFIGURATION_INVALID';
        }
        System.assert(found);
    }

    @IsTest
    static void sensitiveToolsRequireClosedObjectSchemas() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'sensitive_tool', '{"type":"object"}');
        tool.InputSchema__c = '{"type":"object"}';
        tool.AllowedSensitiveDataCategories__c = 'Email';

        List<AgentConfigurationValidator.Finding> findings = AgentConfigurationValidator.collectErrors(
            definition,
            new List<AgentTool__c>{ tool },
            new List<AgentContextProvider__c>()
        );

        Boolean found = false;
        for (AgentConfigurationValidator.Finding finding : findings) {
            found = found || (finding.code == 'TOOL_INPUT_SCHEMA_INVALID' && finding.message.contains('additionalProperties'));
        }
        System.assert(found);
    }

    @IsTest
    static void emailInputRequiresEmailCategoryAtSave() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        AgentTool__c tool = AgentKernelTestFactory.createTool(definition.Id, 'send_reply', '{"type":"object"}');
        tool.InputSchema__c = '{"type":"object","additionalProperties":false,"properties":{"to":{"type":"string","format":"email"}}}';

        List<AgentConfigurationValidator.Finding> findings = AgentConfigurationValidator.collectErrors(
            definition,
            new List<AgentTool__c>{ tool },
            new List<AgentContextProvider__c>()
        );
        Boolean found = false;
        for (AgentConfigurationValidator.Finding finding : findings) {
            found = found || (finding.code == 'TOOL_SENSITIVE_CATEGORY_REQUIRED' && finding.path.endsWith('.AllowedSensitiveDataCategories'));
        }
        System.assert(found, 'An email input must be rejected at save until the Email category is allowed.');

        tool.AllowedSensitiveDataCategories__c = 'Email';
        for (
            AgentConfigurationValidator.Finding finding : AgentConfigurationValidator.collectErrors(
                definition,
                new List<AgentTool__c>{ tool },
                new List<AgentContextProvider__c>()
            )
        ) {
            System.assertNotEquals('TOOL_SENSITIVE_CATEGORY_REQUIRED', finding.code);
        }
    }

    @IsTest
    static void preflightReusesExactQueueableCostBoundaryFinding() {
        AgentDefinition__c supported = AgentKernelTestFactory.createDefinition(100, 0, 0);
        AgentConfigurationValidationService.ValidationReport supportedReport = validate(supported.Id);
        System.assertEquals(true, supportedReport.isValid);
        System.assertEquals(false, codes(supportedReport).contains('ASYNC_JOB_BUDGET_EXCEEDS_SUPPORTED_MAXIMUM'));

        AgentDefinition__c unsupported = AgentKernelTestFactory.createDefinition(1, 50, 0);
        AgentConfigurationValidationService.ValidationReport unsupportedReport = validate(unsupported.Id);
        System.assertEquals(false, unsupportedReport.isValid);
        System.assert(codes(unsupportedReport).contains('ASYNC_JOB_BUDGET_EXCEEDS_SUPPORTED_MAXIMUM'));
        System.assertEquals(false, codes(unsupportedReport).contains('ASYNC_JOB_BUDGET_EXCEEDS_CHAIN_DEPTH'));
        System.assertEquals(false, codes(unsupportedReport).contains('HIGH_ASYNC_JOB_BUDGET'));

        AgentConfigurationValidator.Finding sharedFinding;
        for (
            AgentConfigurationValidator.Finding finding : AgentConfigurationValidator.collectErrors(
                unsupported,
                new List<AgentTool__c>(),
                new List<AgentContextProvider__c>()
            )
        ) {
            if (finding.code == 'ASYNC_JOB_BUDGET_EXCEEDS_SUPPORTED_MAXIMUM') {
                sharedFinding = finding;
            }
        }
        AgentConfigurationValidationService.ValidationIssue reportedIssue;
        for (AgentConfigurationValidationService.ValidationIssue issue : unsupportedReport.issues) {
            if (issue.code == 'ASYNC_JOB_BUDGET_EXCEEDS_SUPPORTED_MAXIMUM') {
                reportedIssue = issue;
            }
        }
        System.assertNotEquals(null, sharedFinding);
        System.assertNotEquals(null, reportedIssue);
        System.assertEquals('Error', reportedIssue.severity);
        System.assertEquals(sharedFinding.path, reportedIssue.path);
        System.assertEquals(sharedFinding.message, reportedIssue.message);
    }

    @IsTest
    static void activeToolCountIsRejectedBeforeSnapshotting() {
        AgentDefinition__c definition = AgentKernelTestFactory.createDefinition();
        List<AgentTool__c> tools = new List<AgentTool__c>();
        for (Integer index = 0; index <= AgentConfigService.MAX_ACTIVE_TOOL_COUNT; index++) {
            tools.add(
                new AgentTool__c(
                    Name = 'Bounded Tool ' + index,
                    AgentDefinition__c = definition.Id,
                    DeveloperName__c = 'bounded_tool_' + index,
                    Description__c = 'Tool-count validation fixture.',
                    ToolType__c = AgentToolTypeTestFixtures.IN_ORG,
                    InputSchema__c = '{"type":"object","properties":{},"additionalProperties":false}',
                    IsActive__c = true,
                    SortOrder__c = index
                )
            );
        }
        insert tools;

        AgentConfigurationValidationService.ValidationReport report = validate(definition.Id);
        System.assertEquals(false, report.isValid);
        System.assert(codes(report).contains('ACTIVE_TOOL_COUNT_INVALID'));
        try {
            AgentConfigService.getActiveTools(definition.Id);
            System.assert(false, 'Runtime loading must reject an oversized active-tool configuration.');
        } catch (AgentKernelException.ConfigurationException expected) {
            System.assert(expected.getMessage().contains('at most'));
        }
    }

    @IsTest
    static void previewSchemaDerivesQueryBindsWithoutWriting() {
        Integer toolsBefore = [SELECT COUNT() FROM AgentTool__c];
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(
            ToolAuthoringService.previewSchema(
                'QueryRecords',
                '{"query":"SELECT Subject FROM Case WHERE Status = :status AND ClosedDate > :closedAfter LIMIT 10"}'
            )
        );
        Map<String, Object> properties = (Map<String, Object>) schema.get('properties');
        System.assertEquals(new Set<String>{ 'status', 'closedAfter' }, properties.keySet());
        System.assert(((Map<String, Object>) properties.get('status')).containsKey('enum'), 'A picklist bind offers its values.');
        System.assertEquals('date-time', ((Map<String, Object>) properties.get('closedAfter')).get('format'));
        System.assertEquals(toolsBefore, [SELECT COUNT() FROM AgentTool__c]);
    }

    @IsTest
    static void createRecordRequiresTheFieldsTheRecordCannotBeSavedWithout() {
        System.assertEquals(
            new List<Object>{ 'Name' },
            recordData(ToolAuthoringService.previewSchema('CreateRecord', '{"objectApiName":"Account","fields":["Name","Industry"]}')).get('required')
        );
        System.assertEquals(
            null,
            recordData(ToolAuthoringService.previewSchema('CreateRecord', '{"objectApiName":"Account","fields":["Name"],"defaultFieldValues":{"Name":"Acme"}}'))
                .get('required'),
            'A field the tool supplies as a default is not asked of the model.'
        );
        System.assertEquals(
            null,
            recordData(ToolAuthoringService.previewSchema('UpdateRecord', '{"objectApiName":"Account","fields":["Name"]}')).get('required'),
            'An update changes only the fields it sends.'
        );
        System.assertEquals(
            'Field values for the new Account.',
            recordData(ToolAuthoringService.previewSchema('CreateRecord', '{"objectApiName":"Account","fields":["Name"]}')).get('description'),
            'The model is told what recordData holds.'
        );
    }

    @IsTest
    static void derivedSchemasKeepTheListedFieldOrder() {
        String schema = ToolAuthoringService.previewSchema('CreateRecord', '{"objectApiName":"Account","fields":["Name","Industry","Description"]}');
        System.assert(
            schema.indexOf('"Name"') < schema.indexOf('"Industry"') && schema.indexOf('"Industry"') < schema.indexOf('"Description"'),
            'Fields appear in the order the admin listed them: ' + schema
        );
        System.assertEquals(
            '{"b":1,"a":[true,null,"x"]}',
            CanonicalJson.serializeInOrder(new Map<String, Object>{ 'b' => 1, 'a' => new List<Object>{ true, null, 'x' } }, false)
        );
    }

    private static Map<String, Object> recordData(String schema) {
        return (Map<String, Object>) ((Map<String, Object>) ((Map<String, Object>) JSON.deserializeUntyped(schema)).get('properties')).get('recordData');
    }

    @IsTest
    static void previewSchemaRefusesUnreadableConfigurationWithTheSaveMessage() {
        try {
            ToolAuthoringService.previewSchema('CreateRecord', '{"objectApiName":"Case"}');
            System.assert(false, 'A Create Record draft without fields must be refused.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assert(expected.getMessage().contains('List the fields the agent may set'), expected.getMessage());
        }
    }

    private static AgentConfigurationValidationService.ValidationRequest bothSelectors() {
        AgentConfigurationValidationService.ValidationRequest request = new AgentConfigurationValidationService.ValidationRequest();
        request.definitionId = UserInfo.getUserId();
        request.developerName = 'also_set';
        return request;
    }

    private static AgentConfigurationValidationService.ValidationReport validate(Id definitionId) {
        AgentConfigurationValidationService.ValidationRequest request = new AgentConfigurationValidationService.ValidationRequest();
        request.definitionId = definitionId;
        return AgentConfigurationValidationService.validate(request);
    }

    private static Set<String> codes(AgentConfigurationValidationService.ValidationReport report) {
        Set<String> result = new Set<String>();
        for (AgentConfigurationValidationService.ValidationIssue issue : report.issues) {
            result.add(issue.code);
        }
        return result;
    }
}
