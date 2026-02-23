/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Tests for ActionSendEmail covering both direct-content and template-based
 * composition modes, argument validation, config parsing, and recipient handling.
 */
@IsTest
private class ActionSendEmailTest {
    // =========================================================================
    // Test data setup
    // =========================================================================

    @TestSetup
    static void setupData() {
        // Insert a Contact used as the template targetObjectId
        Contact c = new Contact(FirstName = 'Agent', LastName = 'Test', Email = 'agent.test@example.com');
        insert c;

        // Insert an EmailTemplate used by template-mode tests.
        // TemplateType 'text' avoids the FIELD_INTEGRITY_EXCEPTION that 'html' triggers
        // when no Letterhead (BrandTemplateId) exists in the test org.
        User currentUser = [SELECT Id FROM User WHERE Id = :UserInfo.getUserId()];
        System.runAs(currentUser) {
            EmailTemplate tmpl = new EmailTemplate(
                isActive = true,
                Name = 'Agent Email Test Template',
                DeveloperName = 'Agent_Email_Test_Template',
                TemplateType = 'text',
                FolderId = UserInfo.getUserId(),
                Subject = 'Hello {!Contact.FirstName}',
                Body = 'Hi {!Contact.FirstName}, this is an agent email.'
            );
            insert tmpl;
        }
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private static ActionContext buildContext() {
        return new ActionContext(null, UserInfo.getUserId(), UserInfo.getUserId(), null, null, null, null, 'turn-email-001', 1, 'Function');
    }

    /** Builds a minimal valid direct-content args JSON with optional overrides. */
    private static String directArgs(Map<String, Object> overrides) {
        Map<String, Object> base = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'recipient@example.com' },
            'subject' => 'Test Subject',
            'body' => 'Hello from the agent.'
        };
        if (overrides != null) {
            base.putAll(overrides);
        }
        return JSON.serialize(base);
    }

    /** Builds a minimal valid template-mode args JSON with optional overrides. */
    private static String templateArgs(String contactId, Map<String, Object> overrides) {
        Map<String, Object> base = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'recipient@example.com' },
            'templateName' => 'Agent_Email_Test_Template',
            'targetObjectId' => contactId
        };
        if (overrides != null) {
            base.putAll(overrides);
        }
        return JSON.serialize(base);
    }

    /**
     * Returns a backend config JSON with variant set to "template".
     * Required for all template-mode tests because usingTemplate is now driven
     * exclusively by config.variant — there is no inference fallback.
     */
    private static String templateConfig() {
        return JSON.serialize(new Map<String, Object>{ 'variant' => 'template' });
    }

    /** Returns a template backend config JSON that also supplies a defaultTemplateName. */
    private static String templateConfigWithDefault(String defaultTemplateName) {
        return JSON.serialize(new Map<String, Object>{ 'variant' => 'template', 'defaultTemplateName' => defaultTemplateName });
    }

    // =========================================================================
    // Direct-content mode — success paths
    // =========================================================================

    @IsTest
    static void testDirect_BasicEmail_ReturnsSuccess() {
        ActionSendEmail action = new ActionSendEmail();

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', directArgs(null), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Basic direct email should succeed');
        ActionSendEmail.EmailSendResult result = (ActionSendEmail.EmailSendResult) outcome.data;
        System.assertEquals(1, result.toCount);
        System.assertEquals(0, result.ccCount);
        System.assertEquals(0, result.bccCount);
        System.assertEquals(false, result.templateUsed, 'templateUsed should be false for direct mode');
        System.assertEquals('Test Subject', result.subjectOrTemplate);
        System.assertNotEquals(null, result.trackingId, 'Tracking ID should be generated');
        System.assert(result.message.contains('Test Subject'), 'Message should include subject');
    }

    @IsTest
    static void testDirect_WithCcAndBcc_ReturnsCorrectCounts() {
        ActionSendEmail action = new ActionSendEmail();
        String args = directArgs(
            new Map<String, Object>{
                'ccAddresses' => new List<String>{ 'cc1@example.com', 'cc2@example.com' },
                'bccAddresses' => new List<String>{ 'bcc@example.com' }
            }
        );

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', args, buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        ActionSendEmail.EmailSendResult result = (ActionSendEmail.EmailSendResult) outcome.data;
        System.assertEquals(1, result.toCount);
        System.assertEquals(2, result.ccCount);
        System.assertEquals(1, result.bccCount);
        System.assertEquals(4, (Integer) result.metadata.get('totalRecipients'));
    }

    @IsTest
    static void testDirect_SingleToAddressShorthand_ReturnsSuccess() {
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> argsMap = new Map<String, Object>{ 'toAddress' => 'single@example.com', 'subject' => 'Shorthand Recipient', 'body' => 'body' };

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        ActionSendEmail.EmailSendResult result = (ActionSendEmail.EmailSendResult) outcome.data;
        System.assertEquals(1, result.toCount, 'Shorthand toAddress should resolve to 1 recipient');
    }

    @IsTest
    static void testDirect_WithFullConfig_AppliesDisplayNameAndReplyTo() {
        ActionSendEmail action = new ActionSendEmail();
        String configJson = JSON.serialize(
            new Map<String, Object>{ 'fromAddress' => 'Support Team <support@acme.com>', 'replyTo' => 'no-reply@acme.com', 'saveAsActivity' => false }
        );

        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, directArgs(null), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Email with full config should succeed');
    }

    @IsTest
    static void testDirect_MultipleToAddresses_CountsCorrectly() {
        ActionSendEmail action = new ActionSendEmail();
        String args = directArgs(new Map<String, Object>{ 'toAddresses' => new List<String>{ 'a@example.com', 'b@example.com', 'c@example.com' } });

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', args, buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        System.assertEquals(3, ((ActionSendEmail.EmailSendResult) outcome.data).toCount);
    }

    // =========================================================================
    // Template mode — success paths
    // =========================================================================

    @IsTest
    static void testTemplate_ValidTemplateAndTarget_ReturnsSuccess() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        ActionSendEmail action = new ActionSendEmail();

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfig(), templateArgs(c.Id, null), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Template-mode email should succeed');
        ActionSendEmail.EmailSendResult result = (ActionSendEmail.EmailSendResult) outcome.data;
        System.assertEquals(true, result.templateUsed, 'templateUsed should be true');
        System.assertEquals('Agent_Email_Test_Template', result.subjectOrTemplate);
        System.assert(result.message.contains('Agent_Email_Test_Template'), 'Message should reference the template name');
    }

    @IsTest
    static void testTemplate_WithWhatObjectId_ReturnsSuccess() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];

        // Create a related Account to use as the whatObjectId
        Account acc = new Account(Name = 'Agent Test Account');
        insert acc;

        ActionSendEmail action = new ActionSendEmail();
        String args = templateArgs(c.Id, new Map<String, Object>{ 'whatObjectId' => acc.Id });

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfig(), args, buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Template email with whatObjectId should succeed');
        System.assertEquals(true, ((ActionSendEmail.EmailSendResult) outcome.data).templateUsed);
    }

    @IsTest
    static void testTemplate_DefaultTemplateFromConfig_UsedWhenNoRuntimeTemplate() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        ActionSendEmail action = new ActionSendEmail();

        // variant must be 'template' so usingTemplate=true; defaultTemplateName provides the template
        // when the LLM does not supply templateName at runtime
        Map<String, Object> argsMap = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'recipient@example.com' },
            'targetObjectId' => c.Id
            // templateName intentionally omitted — action falls back to config.defaultTemplateName
        };

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfigWithDefault('Agent_Email_Test_Template'), JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Default template from config should be used');
        System.assertEquals(true, ((ActionSendEmail.EmailSendResult) outcome.data).templateUsed);
    }

    @IsTest
    static void testTemplate_WithCcAndBcc_CountsCorrectly() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        ActionSendEmail action = new ActionSendEmail();
        String args = templateArgs(
            c.Id,
            new Map<String, Object>{ 'ccAddresses' => new List<String>{ 'cc@example.com' }, 'bccAddresses' => new List<String>{ 'bcc@example.com' } }
        );

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfig(), args, buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        ActionSendEmail.EmailSendResult result = (ActionSendEmail.EmailSendResult) outcome.data;
        System.assertEquals(1, result.ccCount);
        System.assertEquals(1, result.bccCount);
    }

    // =========================================================================
    // Direct-content mode — argument validation failures
    // =========================================================================

    @IsTest
    static void testDirect_MissingToAddresses_ReturnsValidationFailure() {
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> argsMap = new Map<String, Object>{ 'subject' => 'No Recipient', 'body' => 'Body' };

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.containsIgnoreCase('recipient'), 'Error should mention recipient');
    }

    @IsTest
    static void testDirect_MissingSubject_ReturnsValidationFailure() {
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> argsMap = new Map<String, Object>{ 'toAddresses' => new List<String>{ 'r@example.com' }, 'body' => 'body' };

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.containsIgnoreCase('subject'), 'Error should mention subject');
    }

    @IsTest
    static void testDirect_MissingBody_ReturnsValidationFailure() {
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> argsMap = new Map<String, Object>{ 'toAddresses' => new List<String>{ 'r@example.com' }, 'subject' => 'No Body' };

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.containsIgnoreCase('body'), 'Error should mention body');
    }

    @IsTest
    static void testDirect_SubjectTooLong_ReturnsValidationFailure() {
        ActionSendEmail action = new ActionSendEmail();

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', directArgs(new Map<String, Object>{ 'subject' => 'A'.repeat(256) }), buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.containsIgnoreCase('255'));
    }

    @IsTest
    static void testDirect_TooManyRecipients_ReturnsValidationFailure() {
        ActionSendEmail action = new ActionSendEmail();
        List<String> addrs = new List<String>();
        for (Integer i = 0; i < 101; i++) {
            addrs.add('user' + i + '@example.com');
        }

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', directArgs(new Map<String, Object>{ 'toAddresses' => addrs }), buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.containsIgnoreCase('100'));
    }

    @IsTest
    static void testDirect_RecipientLimitAcrossToCcBcc_ReturnsValidationFailure() {
        ActionSendEmail action = new ActionSendEmail();
        List<String> fifty = new List<String>();
        for (Integer i = 0; i < 50; i++) {
            fifty.add('u' + i + '@example.com');
        }
        String args = directArgs(
            new Map<String, Object>{ 'toAddresses' => fifty, 'ccAddresses' => fifty, 'bccAddresses' => new List<String>{ 'extra@example.com' } }
        );

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', args, buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    // =========================================================================
    // Template mode — validation failures
    // =========================================================================

    @IsTest
    static void testTemplate_MissingTargetObjectId_ReturnsValidationFailure() {
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> argsMap = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'r@example.com' },
            'templateName' => 'Agent_Email_Test_Template'
            // targetObjectId intentionally omitted
        };

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfig(), JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.containsIgnoreCase('targetObjectId'), 'Error should mention targetObjectId');
    }

    @IsTest
    static void testTemplate_NonExistentTemplate_ReturnsConfigError() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> argsMap = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'r@example.com' },
            'templateName' => 'Nonexistent_Template_XYZ',
            'targetObjectId' => c.Id
        };

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfig(), JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, outcome.errorCode);
        System.assert(outcome.errorMessage.containsIgnoreCase('Nonexistent_Template_XYZ'), 'Error should name the missing template');
    }

    @IsTest
    static void testTemplate_InvalidTargetObjectIdFormat_ReturnsValidationFailure() {
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> argsMap = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'r@example.com' },
            'templateName' => 'Agent_Email_Test_Template',
            'targetObjectId' => 'not-a-valid-id'
        };

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfig(), JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    @IsTest
    static void testTemplate_InvalidWhatObjectIdFormat_ReturnsValidationFailure() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        ActionSendEmail action = new ActionSendEmail();
        String args = templateArgs(c.Id, new Map<String, Object>{ 'whatObjectId' => 'bad-id' });

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfig(), args, buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    // =========================================================================
    // Framework contract
    // =========================================================================

    @IsTest
    static void testExecute_NullContext_ReturnsUnexpectedError() {
        ActionSendEmail action = new ActionSendEmail();

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', directArgs(null), null);
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, outcome.errorCode);
    }

    @IsTest
    static void testDirect_ResultMetadataIsComplete() {
        ActionSendEmail action = new ActionSendEmail();
        String args = directArgs(new Map<String, Object>{ 'ccAddresses' => new List<String>{ 'cc@example.com' } });

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', args, buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        ActionSendEmail.EmailSendResult result = (ActionSendEmail.EmailSendResult) outcome.data;
        System.assertNotEquals(null, result.metadata);
        System.assertEquals(true, (Boolean) result.metadata.get('success'));
        System.assertEquals(2, (Integer) result.metadata.get('totalRecipients'));
        System.assertEquals(false, (Boolean) result.metadata.get('templateUsed'));
        System.assertNotEquals(null, result.metadata.get('sentAt'));
        System.assertNotEquals(null, result.metadata.get('trackingId'));
    }

    @IsTest
    static void testTemplate_ResultMetadataIsComplete() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        ActionSendEmail action = new ActionSendEmail();

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfig(), templateArgs(c.Id, null), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        ActionSendEmail.EmailSendResult result = (ActionSendEmail.EmailSendResult) outcome.data;
        System.assertEquals(true, (Boolean) result.metadata.get('templateUsed'));
        System.assertNotEquals(null, result.metadata.get('trackingId'));
    }

    // =========================================================================
    // Default To Addresses
    // =========================================================================

    @IsTest
    static void testDirect_DefaultToAddressesFromConfig_UsedWhenLLMProvidesNone() {
        ActionSendEmail action = new ActionSendEmail();
        String configJson = JSON.serialize(new Map<String, Object>{ 'defaultToAddresses' => new List<String>{ 'default@example.com' } });
        Map<String, Object> argsMap = new Map<String, Object>{ 'subject' => 'Test', 'body' => 'Body' };

        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Should succeed using defaultToAddresses from config');
        System.assertEquals(1, ((ActionSendEmail.EmailSendResult) outcome.data).toCount);
    }

    @IsTest
    static void testDirect_LLMAddressesOverrideDefaultToAddresses() {
        ActionSendEmail action = new ActionSendEmail();
        String configJson = JSON.serialize(new Map<String, Object>{ 'defaultToAddresses' => new List<String>{ 'default@example.com' } });
        // LLM provides its own address — config default must be ignored
        String args = directArgs(new Map<String, Object>{ 'toAddresses' => new List<String>{ 'runtime@example.com' } });

        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, args, buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        System.assertEquals(1, ((ActionSendEmail.EmailSendResult) outcome.data).toCount, 'Only the LLM-provided address should be used');
    }

    @IsTest
    static void testTemplate_DefaultToAddressesFromConfig_UsedWhenLLMProvidesNone() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        ActionSendEmail action = new ActionSendEmail();
        String configJson = JSON.serialize(
            new Map<String, Object>{ 'variant' => 'template', 'defaultToAddresses' => new List<String>{ 'default@example.com' } }
        );
        Map<String, Object> argsMap = new Map<String, Object>{
            'templateName' => 'Agent_Email_Test_Template',
            'targetObjectId' => c.Id
            // toAddresses intentionally omitted
        };

        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Template mode should use defaultToAddresses from config');
        System.assertEquals(1, ((ActionSendEmail.EmailSendResult) outcome.data).toCount);
    }

    // =========================================================================
    // Always CC / Always BCC merging
    // =========================================================================

    @IsTest
    static void testDirect_DefaultCcAlwaysIncluded_WhenLLMProvidesNoCc() {
        ActionSendEmail action = new ActionSendEmail();
        String configJson = JSON.serialize(new Map<String, Object>{ 'defaultCcAddresses' => new List<String>{ 'compliance@example.com' } });

        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, directArgs(null), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        System.assertEquals(1, ((ActionSendEmail.EmailSendResult) outcome.data).ccCount, 'Config CC should always be included');
    }

    @IsTest
    static void testDirect_DefaultCcMergedWithLLMCc_Deduplicated() {
        ActionSendEmail action = new ActionSendEmail();
        String configJson = JSON.serialize(
            new Map<String, Object>{ 'defaultCcAddresses' => new List<String>{ 'compliance@example.com', 'shared@example.com' } }
        );
        String args = directArgs(new Map<String, Object>{ 'ccAddresses' => new List<String>{ 'runtime@example.com', 'shared@example.com' } });

        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, args, buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        // compliance + runtime + shared (deduplicated) = 3
        System.assertEquals(3, ((ActionSendEmail.EmailSendResult) outcome.data).ccCount, 'Merged CC should be deduplicated');
    }

    @IsTest
    static void testDirect_DefaultBccAlwaysIncluded() {
        ActionSendEmail action = new ActionSendEmail();
        String configJson = JSON.serialize(new Map<String, Object>{ 'defaultBccAddresses' => new List<String>{ 'audit@example.com' } });

        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, directArgs(null), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess);
        System.assertEquals(1, ((ActionSendEmail.EmailSendResult) outcome.data).bccCount, 'Config BCC should always be included');
    }

    // =========================================================================
    // whatObjectId in direct mode
    // =========================================================================

    @IsTest
    static void testDirect_WhatObjectIdParam_Succeeds() {
        Account acc = new Account(Name = 'Activity Test Account');
        insert acc;
        ActionSendEmail action = new ActionSendEmail();
        String args = directArgs(new Map<String, Object>{ 'whatObjectId' => acc.Id });

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', args, buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Direct mode with valid whatObjectId should succeed');
    }

    @IsTest
    static void testDirect_InvalidWhatObjectIdFormat_ReturnsValidationFailure() {
        ActionSendEmail action = new ActionSendEmail();
        String args = directArgs(new Map<String, Object>{ 'whatObjectId' => 'not-a-valid-id' });

        Test.startTest();
        ActionOutcome outcome = action.execute('{}', args, buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.containsIgnoreCase('whatObjectId'));
    }

    @IsTest
    static void testDirect_DefaultWhatObjectIdFromConfig_AppliedWhenLLMProvidesNone() {
        Account acc = new Account(Name = 'Default What Account');
        insert acc;
        ActionSendEmail action = new ActionSendEmail();
        String configJson = JSON.serialize(new Map<String, Object>{ 'defaultWhatObjectId' => String.valueOf(acc.Id), 'saveAsActivity' => true });

        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, directArgs(null), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Config defaultWhatObjectId should be applied automatically');
    }

    // =========================================================================
    // Template mode — blank templateName guard
    // =========================================================================

    @IsTest
    static void testTemplate_NoTemplateName_ReturnsConfigError() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        ActionSendEmail action = new ActionSendEmail();
        Map<String, Object> argsMap = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'r@example.com' },
            'targetObjectId' => c.Id
            // templateName omitted and no defaultTemplateName in config
        };

        Test.startTest();
        ActionOutcome outcome = action.execute(templateConfig(), JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, outcome.errorCode);
        System.assert(outcome.errorMessage.containsIgnoreCase('defaultTemplateName'), 'Error should guide admin to set defaultTemplateName');
    }

    // =========================================================================
    // Template mode — defaultTargetObjectId from config
    // =========================================================================

    @IsTest
    static void testTemplate_DefaultTargetObjectIdFromConfig_UsedWhenLLMProvidesNone() {
        Contact c = [SELECT Id FROM Contact LIMIT 1];
        ActionSendEmail action = new ActionSendEmail();
        String configJson = JSON.serialize(new Map<String, Object>{ 'variant' => 'template', 'defaultTargetObjectId' => String.valueOf(c.Id) });
        Map<String, Object> argsMap = new Map<String, Object>{
            'toAddresses' => new List<String>{ 'r@example.com' },
            'templateName' => 'Agent_Email_Test_Template'
            // targetObjectId intentionally omitted — should fall back to config default
        };

        Test.startTest();
        ActionOutcome outcome = action.execute(configJson, JSON.serialize(argsMap), buildContext());
        Test.stopTest();

        System.assertEquals(true, outcome.isSuccess, 'Config defaultTargetObjectId should be used when LLM omits targetObjectId');
    }

    // =========================================================================
    // mergeAddresses helper
    // =========================================================================

    @IsTest
    static void testMergeAddresses_DeduplicatesCaseInsensitive() {
        ActionSendEmail action = new ActionSendEmail();
        List<String> base = new List<String>{ 'A@example.com', 'b@example.com' };
        List<String> runtime = new List<String>{ 'a@example.com', 'C@example.com' };

        List<String> merged = action.mergeAddresses(base, runtime);

        System.assertEquals(3, merged.size(), 'Duplicate address (case-insensitive) should be removed');
        System.assert(merged.contains('A@example.com'), 'Base address should be present');
        System.assert(merged.contains('C@example.com'), 'Runtime-only address should be present');
    }

    @IsTest
    static void testMergeAddresses_HandlesNullInputs() {
        ActionSendEmail action = new ActionSendEmail();
        List<String> result = action.mergeAddresses(null, null);
        System.assertEquals(0, result.size(), 'Null inputs should return empty list');
    }
}
