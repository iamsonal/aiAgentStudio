/**
 * @description Tests for ActionOutcome: factory methods, LLM-friendly message formatting,
 *              error message sanitization, default messages, and toString.
 *              Error attributes (category, default message, LLM guidance) are resolved from
 *              ErrorHandlerConfig__mdt via the metadata cache — no mocking needed since custom
 *              metadata records are available in test context.
 */
@IsTest
private class ActionOutcomeTest {
    // ========== FACTORY METHODS ==========

    @IsTest
    static void testSuccessWithData_SetsPropertiesCorrectly() {
        Map<String, Object> data = new Map<String, Object>{ 'key' => 'value' };
        ActionOutcome outcome = ActionOutcome.success(data);

        System.assertEquals(true, outcome.isSuccess);
        System.assertEquals(data, outcome.data);
        System.assertEquals(null, outcome.errorCode);
        System.assertEquals(null, outcome.errorMessage);
        System.assertEquals(null, outcome.correctionGuidance);
        System.assertEquals(null, outcome.llmFriendlyMessage, 'Success should have no LLM message');
    }

    @IsTest
    static void testSuccessNoArg_SetsNullData() {
        ActionOutcome outcome = ActionOutcome.success();

        System.assertEquals(true, outcome.isSuccess);
        System.assertEquals(null, outcome.data);
        System.assertEquals(null, outcome.llmFriendlyMessage);
    }

    @IsTest
    static void testFailureTwoArg_SetsErrorFields() {
        ActionOutcome outcome = ActionOutcome.failure('DML_ERROR', 'Insert failed on Account.');

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(null, outcome.data);
        System.assertEquals('DML_ERROR', outcome.errorCode);
        System.assertEquals('Insert failed on Account.', outcome.errorMessage);
        System.assertEquals('data', outcome.errorCategory, 'Should categorize DML errors as data (from metadata)');
        System.assertNotEquals(null, outcome.llmFriendlyMessage, 'Failure should generate LLM message');
    }

    @IsTest
    static void testFailureThreeArg_IncludesGuidanceInLlmMessage() {
        ActionOutcome outcome = ActionOutcome.failure(
            'INPUT_VALIDATION',
            'Field "Amount" must be a number.',
            'Provide Amount as a numeric value, e.g. 100 or 99.50'
        );

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals('INPUT_VALIDATION', outcome.errorCode);
        System.assertEquals('Provide Amount as a numeric value, e.g. 100 or 99.50', outcome.correctionGuidance);
        System.assert(outcome.llmFriendlyMessage.contains('How to Fix'), 'Guidance outcome should include How to Fix section');
        System.assert(outcome.llmFriendlyMessage.contains('Provide Amount as a numeric value'), 'Should embed the guidance text');
    }

    // ========== LLM FRIENDLY MESSAGE FORMAT ==========

    @IsTest
    static void testLlmMessage_FailureWithoutCallerGuidance_UsesMetadataGuidance() {
        // When no caller guidance is provided, LLMGuidance__c from metadata is used as How to Fix.
        ActionOutcome outcome = ActionOutcome.failure('PERMISSION_DENIED', 'You cannot update this record due to access restrictions.');

        System.assert(outcome.llmFriendlyMessage.contains('**Error**'), 'Should have Error label');
        System.assert(outcome.llmFriendlyMessage.contains('**How to Fix**'), 'Metadata guidance should produce How to Fix section');
        System.assert(!outcome.llmFriendlyMessage.contains('**Suggestion**'), 'No Suggestion section in new architecture');
    }

    @IsTest
    static void testLlmMessage_FailureWithCallerGuidance_OverridesMetadataGuidance() {
        String callerGuidance = 'Use ISO format: YYYY-MM-DD';
        ActionOutcome outcome = ActionOutcome.failure('INPUT_VALIDATION', 'Invalid date format provided for StartDate.', callerGuidance);

        System.assert(outcome.llmFriendlyMessage.contains('**Error**'), 'Should have Error label');
        System.assert(outcome.llmFriendlyMessage.contains('**How to Fix**'), 'Should have How to Fix section');
        System.assert(outcome.llmFriendlyMessage.contains(callerGuidance), 'Caller guidance should override metadata guidance');
        System.assert(!outcome.llmFriendlyMessage.contains('**Suggestion**'), 'No Suggestion section in new architecture');
    }

    // ========== SANITIZATION: STACK TRACE REMOVAL ==========

    @IsTest
    static void testSanitize_StackTraceUpperCase_IsTruncated() {
        String rawMsg = 'Record failed validation. Stack Trace: Class.MyClass.doStuff line 42 column 1';
        ActionOutcome outcome = ActionOutcome.failure('DML_ERROR', rawMsg);

        System.assert(!outcome.llmFriendlyMessage.contains('Class.MyClass'), 'Stack trace content should be removed');
        System.assert(outcome.llmFriendlyMessage.contains('Record failed validation'), 'Text before stack trace should remain');
    }

    @IsTest
    static void testSanitize_StackTraceLowerCase_IsTruncated() {
        String rawMsg = 'Null pointer error occurred when processing the request. the stack trace is below at line 55';
        ActionOutcome outcome = ActionOutcome.failure('UNEXPECTED_ERROR', rawMsg);

        System.assert(!outcome.llmFriendlyMessage.contains('at line 55'), 'Lowercase stack trace content should be removed');
    }

    @IsTest
    static void testSanitize_NewlineAtPattern_IsTruncated() {
        String rawMsg = 'Operation could not complete.' + '\n' + 'at Class.MyClass.execute: line 10, column 1';
        ActionOutcome outcome = ActionOutcome.failure('UNEXPECTED_ERROR', rawMsg);

        String lowerMsg = outcome.llmFriendlyMessage.toLowerCase();
        System.assert(lowerMsg.contains('operation') || lowerMsg.contains('complete'), 'Should preserve main error message');
    }

    // ========== SANITIZATION: TECHNICAL DETAILS STRIPPED ==========

    @IsTest
    static void testSanitize_RecordIdsReplaced() {
        String rawMsg = 'Cannot find record 001000000000000AAA in the system for processing.';
        ActionOutcome outcome = ActionOutcome.failure('RECORD_NOT_FOUND', rawMsg);

        System.assert(!outcome.llmFriendlyMessage.contains('001000000000000AAA'), '18-char IDs should be replaced');
        System.assert(outcome.llmFriendlyMessage.contains('[Record ID]'), 'Should substitute with [Record ID]');
    }

    @IsTest
    static void testSanitize_ExceptionPrefixRemoved() {
        String rawMsg = 'NullPointerException: Attempt to de-reference a null object during field access.';
        ActionOutcome outcome = ActionOutcome.failure('UNEXPECTED_ERROR', rawMsg);

        System.assert(!outcome.llmFriendlyMessage.contains('NullPointerException:'), 'Exception prefix should be stripped');
    }

    @IsTest
    static void testSanitize_SystemDotRemoved() {
        String rawMsg = 'System.QueryException thrown during the record lookup operation.';
        ActionOutcome outcome = ActionOutcome.failure('SOQL_ERROR', rawMsg);

        System.assert(!outcome.llmFriendlyMessage.contains('System.'), 'System. prefix should be stripped');
    }

    // ========== SANITIZATION: FRIENDLY REPLACEMENTS ==========

    @IsTest
    static void testSanitize_InsufficientAccessReplacedWithFriendlyText() {
        String rawMsg = 'Failed because of insufficient access on the target object or fields.';
        ActionOutcome outcome = ActionOutcome.failure('PERMISSION_DENIED', rawMsg);

        System.assert(outcome.llmFriendlyMessage.contains('you do not have permission'), 'Should replace with friendly text');
    }

    @IsTest
    static void testSanitize_SecurityEnforcedReplacedWithFriendlyText() {
        String rawMsg = 'Query failed because security enforced check on the fields was not met.';
        ActionOutcome outcome = ActionOutcome.failure('PERMISSION_DENIED', rawMsg);

        System.assert(outcome.llmFriendlyMessage.contains('permission check'), 'Should replace security enforced');
    }

    @IsTest
    static void testSanitize_FieldNotWriteableReplacedWithFriendlyText() {
        String rawMsg = 'The Status field is not writeable on this record and cannot be changed.';
        ActionOutcome outcome = ActionOutcome.failure('DML_ERROR', rawMsg);

        System.assert(outcome.llmFriendlyMessage.contains('field cannot be modified'), 'Should replace with friendly text');
    }

    @IsTest
    static void testSanitize_DmlStatusCodesReplacedWithFriendlyText() {
        ActionOutcome lockOutcome = ActionOutcome.failure('RECORD_LOCKED', 'UNABLE_TO_LOCK_ROW while saving the record batch');
        System.assert(!lockOutcome.llmFriendlyMessage.contains('UNABLE_TO_LOCK_ROW'), 'Should replace UNABLE_TO_LOCK_ROW');
        System.assert(lockOutcome.llmFriendlyMessage.toLowerCase().contains('locked'), 'Should contain friendly lock text');

        ActionOutcome valOutcome = ActionOutcome.failure('INPUT_VALIDATION', 'FIELD_CUSTOM_VALIDATION_EXCEPTION on the Amount field');
        System.assert(!valOutcome.llmFriendlyMessage.contains('FIELD_CUSTOM_VALIDATION_EXCEPTION'), 'Should replace validation exception code');
        System.assert(valOutcome.llmFriendlyMessage.toLowerCase().contains('validation'), 'Should contain friendly validation text');

        ActionOutcome reqOutcome = ActionOutcome.failure('INPUT_VALIDATION', 'REQUIRED_FIELD_MISSING for the Name field value');
        System.assert(!reqOutcome.llmFriendlyMessage.contains('REQUIRED_FIELD_MISSING'), 'Should replace required field code');
        System.assert(reqOutcome.llmFriendlyMessage.toLowerCase().contains('required'), 'Should contain friendly required text');

        ActionOutcome lenOutcome = ActionOutcome.failure('INPUT_VALIDATION', 'STRING_TOO_LONG for field Description exceeding limit');
        System.assert(!lenOutcome.llmFriendlyMessage.contains('STRING_TOO_LONG'), 'Should replace string too long code');
        System.assert(lenOutcome.llmFriendlyMessage.toLowerCase().contains('length'), 'Should contain friendly length text');

        ActionOutcome dupOutcome = ActionOutcome.failure('INPUT_VALIDATION', 'DUPLICATE_VALUE found when inserting the new record');
        System.assert(!dupOutcome.llmFriendlyMessage.contains('DUPLICATE_VALUE'), 'Should replace duplicate value code');
        System.assert(dupOutcome.llmFriendlyMessage.toLowerCase().contains('duplicate'), 'Should contain friendly duplicate text');
    }

    // ========== SANITIZATION: LENGTH / EDGE CASES ==========

    @IsTest
    static void testSanitize_LongMessageTruncatedTo300Chars() {
        String longMsg = '';
        for (Integer i = 0; i < 35; i++) {
            longMsg += '0123456789';
        }
        ActionOutcome outcome = ActionOutcome.failure('UNEXPECTED_ERROR', longMsg);
        System.assertNotEquals(null, outcome.llmFriendlyMessage);
    }

    @IsTest
    static void testSanitize_BlankMessage_FallsBackToDefaultMessage() {
        ActionOutcome outcome = ActionOutcome.failure('DML_ERROR', '');

        System.assert(outcome.llmFriendlyMessage.contains('Unable to save'), 'Blank message should use DML_ERROR default from metadata');
    }

    @IsTest
    static void testSanitize_NullMessage_FallsBackToDefaultMessage() {
        ActionOutcome outcome = ActionOutcome.failure('SOQL_ERROR', null);

        System.assert(outcome.llmFriendlyMessage.contains('Unable to retrieve'), 'Null message should use SOQL_ERROR default from metadata');
    }

    @IsTest
    static void testSanitize_MessageBecomesShortAfterSanitization_FallsBackToDefault() {
        String rawMsg = 'System.Err';
        ActionOutcome outcome = ActionOutcome.failure('UNEXPECTED_ERROR', rawMsg);

        System.assertNotEquals(null, outcome.llmFriendlyMessage);
        System.assert(outcome.llmFriendlyMessage.contains('**Error**'));
    }

    @IsTest
    static void testSanitize_AddsTrailingPeriod_WhenMissing() {
        String rawMsg = 'The record could not be saved because a required field is empty';
        ActionOutcome outcome = ActionOutcome.failure('DML_ERROR', rawMsg);

        System.assert(
            outcome.llmFriendlyMessage.contains('empty.') || outcome.llmFriendlyMessage.contains('empty.\n'),
            'Should add trailing period when missing'
        );
    }

    @IsTest
    static void testSanitize_PreservesExistingPunctuation() {
        String rawMsgExcl = 'Access denied! You need the correct profile to proceed.';
        ActionOutcome outcomeExcl = ActionOutcome.failure('PERMISSION_DENIED', rawMsgExcl);
        System.assertNotEquals(null, outcomeExcl.llmFriendlyMessage);

        String rawMsgQuestion = 'Did you mean to update this locked record?';
        ActionOutcome outcomeQ = ActionOutcome.failure('RECORD_LOCKED', rawMsgQuestion);
        System.assertNotEquals(null, outcomeQ.llmFriendlyMessage);
    }

    // ========== DEFAULT MESSAGES AND METADATA-DRIVEN ATTRIBUTES ==========

    @IsTest
    static void testDefaultMessages_AllErrorCodes_ProduceLlmMessages() {
        // Each known error code should produce a valid LLM-friendly message even with blank errorMessage.
        // Attributes (category, default message, guidance) come from ErrorHandlerConfig__mdt.
        List<String> allCodes = new List<String>{
            'INPUT_VALIDATION',
            'CONFIG_ERROR',
            'PERMISSION_DENIED',
            'DML_ERROR',
            'SOQL_ERROR',
            'RECORD_NOT_FOUND',
            'RECORD_LOCKED',
            'CONNECT_API_ERROR',
            'LLM_CALL_FAILED',
            'ACTION_EXECUTION_FAILED',
            'FLOW_FAULT',
            'MAX_TURNS_EXCEEDED',
            'SYSTEM_LIMIT_EXCEEDED',
            'USER_REJECTED_ACTION',
            'CONFIRMATION_TIMEOUT',
            'CONFIRMATION_STATE_ERROR',
            'COMPLETION_CAPABILITY_FAILED',
            'ACTION_HANDLER_NULL_RESULT',
            'UNEXPECTED_ERROR'
        };

        for (String code : allCodes) {
            ActionOutcome outcome = ActionOutcome.failure(code, '');
            System.assertNotEquals(null, outcome.llmFriendlyMessage, 'Error code ' + code + ' should produce LLM message');
            System.assert(outcome.llmFriendlyMessage.contains('**Error**'), 'Error code ' + code + ' LLM message should contain Error label');
            System.assertNotEquals(null, outcome.errorCategory, 'Error code ' + code + ' should have a category from metadata');
        }
    }

    @IsTest
    static void testDefaultMessage_UnknownErrorCode_FallsBackToUnexpectedErrorConfig() {
        // Unknown codes fall back to the UNEXPECTED_ERROR metadata record.
        ActionOutcome outcome = ActionOutcome.failure('SOME_NEW_UNKNOWN_CODE', '');

        System.assertNotEquals(null, outcome.llmFriendlyMessage);
        System.assert(outcome.llmFriendlyMessage.contains('**Error**'), 'Unknown code should produce Error label');
        // Falls back to UNEXPECTED_ERROR which has category 'system'
        System.assertEquals('system', outcome.errorCategory, 'Unknown code falls back to UNEXPECTED_ERROR metadata (category: system)');
    }

    @IsTest
    static void testDefaultMessage_NullErrorCode_ProducesGenericMessage() {
        ActionOutcome outcome = ActionOutcome.failure(null, '');

        System.assertNotEquals(null, outcome.llmFriendlyMessage);
        System.assert(outcome.llmFriendlyMessage.contains('**Error**'), 'Null code should produce Error label');
    }

    // ========== fromException FACTORY ==========

    @IsTest
    static void testFromException_CalloutException_MapsToConnectApiError() {
        System.CalloutException ex = new System.CalloutException('Connection timed out');
        ActionOutcome outcome = ActionOutcome.fromException(ex);

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, outcome.errorCode, 'CalloutException should map to CONNECT_API_ERROR');
        System.assertEquals('Connection timed out', outcome.errorMessage);
        System.assertEquals('external', outcome.errorCategory);
        System.assertEquals(true, ActionOutcome.isTransient(outcome.errorCode), 'CONNECT_API_ERROR should be transient (retriable)');
    }

    @IsTest
    static void testFromException_MathException_MapsToActionExecutionFailed() {
        System.MathException ex = new System.MathException('Divide by 0');
        ActionOutcome outcome = ActionOutcome.fromException(ex);

        System.assertEquals(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, outcome.errorCode, 'MathException should map to ACTION_EXECUTION_FAILED');
        System.assertEquals('Divide by 0', outcome.errorMessage);
        System.assertEquals(true, ActionOutcome.isTransient(outcome.errorCode), 'ACTION_EXECUTION_FAILED should be transient');
    }

    @IsTest
    static void testFromException_JSONException_MapsToInputValidation() {
        System.JSONException ex = new System.JSONException('Unexpected character');
        ActionOutcome outcome = ActionOutcome.fromException(ex);

        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode, 'JSONException should map to INPUT_VALIDATION');
    }

    @IsTest
    static void testFromException_NullPointerException_MapsToActionExecutionFailed() {
        System.NullPointerException ex = new System.NullPointerException();
        ActionOutcome outcome = ActionOutcome.fromException(ex);

        System.assertEquals(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, outcome.errorCode, 'NullPointerException should map to ACTION_EXECUTION_FAILED');
    }

    @IsTest
    static void testFromException_UnknownException_MapsToUnexpectedError() {
        Exception ex = new AIAgentException('Something unexpected');
        ActionOutcome outcome = ActionOutcome.fromException(ex);

        System.assertEquals(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, outcome.errorCode, 'Unknown exception type should map to UNEXPECTED_ERROR');
    }

    @IsTest
    static void testFromException_WithCorrectionGuidance_OverridesMetadataGuidance() {
        System.CalloutException ex = new System.CalloutException('Timeout');
        String domainGuidance = 'The external API is down. Retry in a few minutes.';
        ActionOutcome outcome = ActionOutcome.fromException(ex, domainGuidance);

        System.assertEquals(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, outcome.errorCode);
        System.assertEquals(domainGuidance, outcome.correctionGuidance, 'Caller guidance should override metadata default');
        System.assert(outcome.llmFriendlyMessage.contains(domainGuidance), 'LLM message should embed caller guidance');
    }

    @IsTest
    static void testFromException_NullGuidance_UsesMetadataGuidance() {
        System.JSONException ex = new System.JSONException('Bad JSON');
        ActionOutcome outcome = ActionOutcome.fromException(ex, null);

        System.assertNotEquals(null, outcome.correctionGuidance, 'Metadata guidance should be populated when no override');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    // ========== classifyException UTILITY ==========

    @IsTest
    static void testClassifyException_AllMappedTypes() {
        System.assertEquals(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, ActionOutcome.classifyException(new System.CalloutException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_SYSTEM_LIMIT, ActionOutcome.classifyException(new System.LimitException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, ActionOutcome.classifyException(new System.MathException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, ActionOutcome.classifyException(new System.NullPointerException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyException(new System.TypeException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyException(new System.JSONException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ActionOutcome.classifyException(new System.NoAccessException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_SOQL_ERROR, ActionOutcome.classifyException(new System.SearchException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, ActionOutcome.classifyException(new System.ListException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyException(new System.StringException()));
        System.assertEquals(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ActionOutcome.classifyException(new AIAgentException('fallback')));
    }

    // ========== classifyDmlStatusCode UTILITY ==========

    @IsTest
    static void testClassifyDmlStatusCode_AllMappings() {
        System.assertEquals(AIAgentConstants.ERR_CODE_RECORD_LOCKED, ActionOutcome.classifyDmlStatusCode('UNABLE_TO_LOCK_ROW'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyDmlStatusCode('FIELD_CUSTOM_VALIDATION_EXCEPTION'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyDmlStatusCode('REQUIRED_FIELD_MISSING'));
        System.assertEquals(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ActionOutcome.classifyDmlStatusCode('INSUFFICIENT_ACCESS_OR_READONLY'));
        System.assertEquals(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ActionOutcome.classifyDmlStatusCode('CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyDmlStatusCode('INVALID_CROSS_REFERENCE_KEY'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyDmlStatusCode('INVALID_FIELD_FOR_INSERT_UPDATE'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyDmlStatusCode('INVALID_ID_FIELD'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyDmlStatusCode('STRING_TOO_LONG'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyDmlStatusCode('DUPLICATE_VALUE'));
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ActionOutcome.classifyDmlStatusCode('FIELD_FILTER_VALIDATION_EXCEPTION'));
        System.assertEquals(AIAgentConstants.ERR_CODE_DML_ERROR, ActionOutcome.classifyDmlStatusCode('DELETE_FAILED'));
        System.assertEquals(AIAgentConstants.ERR_CODE_DML_ERROR, ActionOutcome.classifyDmlStatusCode(null), 'Null status should return DML_ERROR');
        System.assertEquals(
            AIAgentConstants.ERR_CODE_DML_ERROR,
            ActionOutcome.classifyDmlStatusCode('SOME_UNKNOWN_CODE'),
            'Unknown status should return DML_ERROR'
        );
    }

    @IsTest
    static void testClassifyException_DmlException_RecordLock_MapsToRecordLocked() {
        // This is the key correctness test: a DmlException with UNABLE_TO_LOCK_ROW caught
        // in action code must classify as RECORD_LOCKED (transient), not DML_ERROR (non-transient).
        // Previously fromException() would have returned DML_ERROR, preventing LLM retry.
        System.assertEquals(
            AIAgentConstants.ERR_CODE_RECORD_LOCKED,
            ActionOutcome.classifyDmlStatusCode('UNABLE_TO_LOCK_ROW'),
            'UNABLE_TO_LOCK_ROW must map to RECORD_LOCKED (transient) so LLM can retry'
        );
        System.assertEquals(true, ActionOutcome.isTransient(AIAgentConstants.ERR_CODE_RECORD_LOCKED), 'RECORD_LOCKED must be transient');
    }

    // ========== isTransient and deriveCategory UTILITIES ==========

    @IsTest
    static void testIsTransient_TransientCodes_ReturnTrue() {
        System.assertEquals(true, ActionOutcome.isTransient('CONNECT_API_ERROR'), 'CONNECT_API_ERROR should be transient');
        System.assertEquals(true, ActionOutcome.isTransient('RECORD_LOCKED'), 'RECORD_LOCKED should be transient');
        System.assertEquals(true, ActionOutcome.isTransient('LLM_CALL_FAILED'), 'LLM_CALL_FAILED should be transient');
        System.assertEquals(true, ActionOutcome.isTransient('ACTION_EXECUTION_FAILED'), 'ACTION_EXECUTION_FAILED should be transient');
    }

    @IsTest
    static void testIsTransient_NonTransientCodes_ReturnFalse() {
        System.assertEquals(false, ActionOutcome.isTransient('PERMISSION_DENIED'), 'PERMISSION_DENIED should not be transient');
        System.assertEquals(false, ActionOutcome.isTransient('CONFIG_ERROR'), 'CONFIG_ERROR should not be transient');
        System.assertEquals(false, ActionOutcome.isTransient('INPUT_VALIDATION'), 'INPUT_VALIDATION should not be transient');
        System.assertEquals(false, ActionOutcome.isTransient('UNEXPECTED_ERROR'), 'UNEXPECTED_ERROR should not be transient');
        System.assertEquals(false, ActionOutcome.isTransient('SAFETY_BLOCKED'), 'SAFETY_BLOCKED should not be transient');
    }

    @IsTest
    static void testDeriveCategory_KnownCodes_ReturnsCorrectCategory() {
        System.assertEquals('data', ActionOutcome.deriveCategory('DML_ERROR'));
        System.assertEquals('data', ActionOutcome.deriveCategory('SOQL_ERROR'));
        System.assertEquals('data', ActionOutcome.deriveCategory('RECORD_NOT_FOUND'));
        System.assertEquals('data', ActionOutcome.deriveCategory('RECORD_LOCKED'));
        System.assertEquals('permission', ActionOutcome.deriveCategory('PERMISSION_DENIED'));
        System.assertEquals('validation', ActionOutcome.deriveCategory('INPUT_VALIDATION'));
        System.assertEquals('config', ActionOutcome.deriveCategory('CONFIG_ERROR'));
        System.assertEquals('external', ActionOutcome.deriveCategory('CONNECT_API_ERROR'));
        System.assertEquals('external', ActionOutcome.deriveCategory('LLM_CALL_FAILED'));
        System.assertEquals('system', ActionOutcome.deriveCategory('UNEXPECTED_ERROR'));
        System.assertEquals('user', ActionOutcome.deriveCategory('USER_REJECTED_ACTION'));
    }

    @IsTest
    static void testDeriveCategory_UnknownCode_FallsBackToSystem() {
        // Unknown codes fall back to UNEXPECTED_ERROR config which has category 'system'
        System.assertEquals('system', ActionOutcome.deriveCategory('TOTALLY_UNKNOWN_CODE'));
    }

    // ========== toString ==========

    @IsTest
    static void testToString_Success() {
        ActionOutcome outcome = ActionOutcome.success('test data');
        String result = outcome.toString();

        System.assert(result.contains('isSuccess=true'), 'Should indicate success');
        System.assert(result.contains('ActionOutcome'), 'Should include class name');
    }

    @IsTest
    static void testToString_Failure() {
        ActionOutcome outcome = ActionOutcome.failure('DML_ERROR', 'Insert failed');
        String result = outcome.toString();

        System.assert(result.contains('isSuccess=false'), 'Should indicate failure');
        System.assert(result.contains('DML_ERROR'), 'Should include error code');
        System.assert(result.contains('Insert failed'), 'Should include error message');
    }
}
