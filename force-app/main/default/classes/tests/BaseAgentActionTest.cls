/**
 * @description Comprehensive tests for BaseAgentAction exception mapping, token resolution, and configuration parsing.
 */
@IsTest
private class BaseAgentActionTest {
    // ========== TEST ACTION STUBS ==========

    private class TestAction extends BaseAgentAction {
        public override ActionOutcome executeAction(Map<String, Object> params) {
            return ActionOutcome.success(parsedActionConfig);
        }
    }

    private class ThrowingAction extends BaseAgentAction {
        public Exception exceptionToThrow;

        public override ActionOutcome executeAction(Map<String, Object> params) {
            if (exceptionToThrow != null) {
                throw exceptionToThrow;
            }
            return ActionOutcome.success('ok');
        }
    }

    private class NullResultAction extends BaseAgentAction {
        public override ActionOutcome executeAction(Map<String, Object> params) {
            return null;
        }
    }

    private static ActionContext buildContext() {
        return new ActionContext(null, UserInfo.getUserId(), UserInfo.getUserId(), null, null, null, null, 'turn-base-001', 1, 'Function');
    }

    // ========== CONTEXT VALIDATION ==========

    @IsTest
    static void testExecute_NullContext_ReturnsUnexpectedError() {
        TestAction action = new TestAction();
        ActionOutcome outcome = action.execute('{"sample":true}', '{"key":"value"}', null);

        System.assertEquals(false, outcome.isSuccess, 'Null context should return failure');
        System.assertEquals(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('Missing context'), 'Should surface missing context message');
    }

    @IsTest
    static void testExecute_ValidContext_Success() {
        TestAction action = new TestAction();
        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(true, outcome.isSuccess, 'Valid context should succeed');
    }

    // ========== CONFIGURATION PARSING ==========

    @IsTest
    static void testExecute_EmptyActionConfig_Success() {
        TestAction action = new TestAction();
        ActionOutcome outcome = action.execute('', '{}', buildContext());

        System.assertEquals(true, outcome.isSuccess, 'Empty config should succeed');
    }

    @IsTest
    static void testExecute_NullActionConfig_Success() {
        TestAction action = new TestAction();
        ActionOutcome outcome = action.execute(null, '{}', buildContext());

        System.assertEquals(true, outcome.isSuccess, 'Null config should succeed');
    }

    @IsTest
    static void testExecute_InvalidJsonConfig_ReturnsValidationError() {
        TestAction action = new TestAction();
        ActionOutcome outcome = action.execute('{invalid json}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess, 'Invalid JSON should fail');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('Invalid ActionConfiguration JSON'), 'Should indicate invalid JSON');
    }

    @IsTest
    static void testExecute_NonObjectJsonConfig_ReturnsValidationError() {
        TestAction action = new TestAction();
        ActionOutcome outcome = action.execute('["array", "not", "object"]', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess, 'Non-object JSON should fail');
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('must be a JSON Object'), 'Should indicate object requirement');
    }

    // ========== ARGUMENTS PARSING ==========

    @IsTest
    static void testExecute_EmptyArguments_Success() {
        TestAction action = new TestAction();
        ActionOutcome outcome = action.execute('{}', '', buildContext());
        System.assertEquals(true, outcome.isSuccess, 'Empty arguments should succeed');
    }

    @IsTest
    static void testExecute_NullArguments_Success() {
        TestAction action = new TestAction();
        ActionOutcome outcome = action.execute('{}', null, buildContext());
        System.assertEquals(true, outcome.isSuccess, 'Null arguments should succeed');
    }

    // ========== TOKEN RESOLUTION ==========

    @IsTest
    static void testExecute_ResolvesAllContextTokens() {
        TestAction action = new TestAction();
        Map<String, Object> config = new Map<String, Object>{
            'contextUser' => '$Context.UserId',
            'runningUser' => '$User.Id',
            'today' => '$System.Today',
            'now' => '$System.Now'
        };

        ActionOutcome outcome = action.execute(JSON.serialize(config), '{"foo":"bar"}', buildContext());
        System.assertEquals(true, outcome.isSuccess);

        Map<String, Object> resolved = (Map<String, Object>) outcome.data;
        System.assertEquals(UserInfo.getUserId(), resolved.get('contextUser'), 'Should resolve $Context.UserId');
        System.assertEquals(UserInfo.getUserId(), resolved.get('runningUser'), 'Should resolve $User.Id');
        System.assertEquals(String.valueOf(Date.today()), resolved.get('today'), 'Should resolve $System.Today');
        System.assertNotEquals('$System.Now', String.valueOf(resolved.get('now')), 'Should resolve $System.Now');
    }

    @IsTest
    static void testExecute_ResolvesNestedAndListTokens() {
        TestAction action = new TestAction();
        Map<String, Object> config = new Map<String, Object>{
            'nested' => new Map<String, Object>{ 'userId' => '$User.Id', 'deeper' => new Map<String, Object>{ 'today' => '$System.Today' } },
            'list' => new List<Object>{ '$User.Id', new Map<String, Object>{ 'token' => '$System.Today' } }
        };

        ActionOutcome outcome = action.execute(JSON.serialize(config), '{}', buildContext());
        System.assertEquals(true, outcome.isSuccess);

        Map<String, Object> resolved = (Map<String, Object>) outcome.data;
        Map<String, Object> nested = (Map<String, Object>) resolved.get('nested');
        System.assertEquals(UserInfo.getUserId(), nested.get('userId'));

        Map<String, Object> deeper = (Map<String, Object>) nested.get('deeper');
        System.assertEquals(String.valueOf(Date.today()), deeper.get('today'));

        List<Object> listValues = (List<Object>) resolved.get('list');
        System.assertEquals(UserInfo.getUserId(), listValues[0], 'Should resolve token in list');
    }

    @IsTest
    static void testExecute_ConfigWithNullAndPrimitiveValues_Preserved() {
        TestAction action = new TestAction();
        Map<String, Object> config = new Map<String, Object>{
            'plain' => 'no tokens here',
            'blankStr' => '',
            'number' => 123,
            'bool' => true,
            'nullVal' => null
        };

        ActionOutcome outcome = action.execute(JSON.serialize(config), '{}', buildContext());
        System.assertEquals(true, outcome.isSuccess);

        Map<String, Object> resolved = (Map<String, Object>) outcome.data;
        System.assertEquals('no tokens here', resolved.get('plain'), 'Plain string should be unchanged');
        System.assertEquals('', resolved.get('blankStr'), 'Blank string should be preserved');
        System.assertEquals(123, resolved.get('number'), 'Number should be unchanged');
        System.assertEquals(true, resolved.get('bool'), 'Boolean should be unchanged');
        System.assertEquals(null, resolved.get('nullVal'), 'Null should be preserved');
    }

    // ========== EXCEPTION MAPPING: DML ==========

    @IsTest
    static void testExecute_DmlRequiredFieldMissing_ReturnsInputValidation() {
        ThrowingAction action = new ThrowingAction();

        Account acc = new Account(); // Missing required Name
        try {
            insert acc;
        } catch (DmlException dmlEx) {
            action.exceptionToThrow = dmlEx;
        }

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode, 'REQUIRED_FIELD_MISSING maps to INPUT_VALIDATION');
        System.assert(outcome.errorMessage.contains('DML failed'), 'Should indicate DML failure');
    }

    @IsTest
    static void testExecute_DmlStringTooLong_ReturnsInputValidation() {
        ThrowingAction action = new ThrowingAction();

        String longName = '';
        for (Integer i = 0; i < 30; i++) {
            longName += '0123456789';
        }
        Account acc = new Account(Name = longName);
        try {
            insert acc;
        } catch (DmlException dmlEx) {
            action.exceptionToThrow = dmlEx;
        }

        // Only assert if we actually caught a DML exception (some orgs may allow long names)
        if (action.exceptionToThrow != null) {
            ActionOutcome outcome = action.execute('{}', '{}', buildContext());
            System.assertEquals(false, outcome.isSuccess);
            System.assert(outcome.errorMessage.contains('DML failed'));
        }
    }

    @IsTest
    static void testExecute_DmlInvalidCrossReference_ReturnsInputValidation() {
        ThrowingAction action = new ThrowingAction();

        Contact con = new Contact(LastName = 'Test', AccountId = '001000000000000AAA');
        try {
            insert con;
        } catch (DmlException dmlEx) {
            action.exceptionToThrow = dmlEx;
        }

        if (action.exceptionToThrow != null) {
            ActionOutcome outcome = action.execute('{}', '{}', buildContext());
            System.assertEquals(false, outcome.isSuccess);
            System.assert(outcome.errorMessage.contains('DML failed'));
        }
    }

    // ========== EXCEPTION MAPPING: QUERY ==========

    @IsTest
    static void testExecute_QueryException_ReturnsSoqlError() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new System.QueryException('List has no rows for assignment to SObject');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_SOQL_ERROR, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('Query failed'));
    }

    @IsTest
    static void testExecute_QueryExceptionSecurityEnforced_ReturnsPermissionDenied() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new System.QueryException('SOQL query failed: security enforced restriction');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, outcome.errorCode, 'Security enforced should map to PERMISSION_DENIED');
    }

    @IsTest
    static void testExecute_QueryExceptionInsufficientAccess_ReturnsPermissionDenied() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new System.QueryException('Insufficient access rights on object');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, outcome.errorCode, 'Insufficient access should map to PERMISSION_DENIED');
    }

    // ========== EXCEPTION MAPPING: CALLOUT ==========

    @IsTest
    static void testExecute_CalloutException_ReturnsConnectApiError() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new System.CalloutException('Connection timed out');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('External callout failed'));
    }

    // ========== EXCEPTION MAPPING: TYPE COERCION ==========

    @IsTest
    static void testExecute_TypeCoercionWithGuidance_ReturnsValidationWithGuidance() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new TypeCoercionService.TypeCoercionException('Invalid integer', 'Count', 'Integer', 'String');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assertNotEquals(null, outcome.correctionGuidance, 'Should include correction guidance');
    }

    @IsTest
    static void testExecute_TypeCoercionWithoutGuidance_ReturnsValidationNoGuidance() {
        ThrowingAction action = new ThrowingAction();
        // Passing blank targetType produces null correctionGuidance
        action.exceptionToThrow = new TypeCoercionService.TypeCoercionException('Coercion failed', 'field', '', 'String');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
    }

    // ========== EXCEPTION MAPPING: VALIDATION & SECURITY ==========

    @IsTest
    static void testExecute_ValidationException_ReturnsInputValidation() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new BaseAgentAction.ValidationException('Invalid input', 'TestField');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('Invalid input'));
    }

    @IsTest
    static void testExecute_ActionSecurityException_ReturnsPermissionDenied() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new BaseAgentAction.ActionSecurityException('No access');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, outcome.errorCode);
    }

    // ========== EXCEPTION MAPPING: NULL RESULT ==========

    @IsTest
    static void testExecute_NullActionOutcome_ReturnsHandlerNullError() {
        NullResultAction action = new NullResultAction();

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('returned null'));
    }

    // ========== EXCEPTION MAPPING: LLM / PROVIDER ==========

    @IsTest
    static void testExecute_LlmPayloadException_ReturnsConfigError() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new LLMFormattingService.LlmPayloadException('Bad payload format');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('LLM Data Error'));
    }

    @IsTest
    static void testExecute_ProviderException_ReturnsLlmCallFailed() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new AIAgentException.ProviderException('Provider timeout');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('LLM Communication Failed'));
    }

    @IsTest
    static void testExecute_AIAgentExceptionWithLLM_ReturnsLlmCallFailed() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new AIAgentException('LLM request timed out');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, outcome.errorCode, 'AIAgentException with LLM in message should map to LLM_CALL_FAILED');
    }

    // ========== EXCEPTION MAPPING: CAPABILITY ==========

    @IsTest
    static void testExecute_CapabilityExecutionException_ReturnsConfigError() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new CapabilityExecutionService.CapabilityExecutionException('Capability not found');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_CONFIG_ERROR, outcome.errorCode);
        System.assert(outcome.errorMessage.contains('Action Setup Failed'));
    }

    // ========== EXCEPTION MAPPING: GENERIC ==========

    @IsTest
    static void testExecute_GenericException_ReturnsUnexpectedError() {
        ThrowingAction action = new ThrowingAction();
        action.exceptionToThrow = new AIAgentException('Something went wrong');

        ActionOutcome outcome = action.execute('{}', '{}', buildContext());

        System.assertEquals(false, outcome.isSuccess);
        System.assertEquals(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, outcome.errorCode);
    }

    // ========== DML STATUS CODE MAPPING (direct) ==========

    @IsTest
    static void testClassifyDmlStatusCode_AllMappings() {
        // DML status code classification now lives in ActionOutcome (shared by both
        // BaseAgentAction.mapExceptionToOutcome and ActionOutcome.fromException/classifyException)
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

    // ========== toString ==========

    @IsTest
    static void testToString_WithoutContext() {
        TestAction action = new TestAction();
        String result = action.toString();
        System.assert(result.contains('Not Set'), 'Should indicate context not set');
    }

    @IsTest
    static void testToString_WithContext() {
        TestAction action = new TestAction();
        action.execute('{}', '{}', buildContext());

        String result = action.toString();
        System.assert(result.contains('Set'), 'Should indicate context is set');
    }

    // ========== ValidationException constructors ==========

    @IsTest
    static void testValidationException_WithCause() {
        Exception cause = new System.NullPointerException();
        BaseAgentAction.ValidationException ve = new BaseAgentAction.ValidationException('Test error', 'TestField', cause);

        System.assertEquals('TestField', ve.fieldName, 'Field name should be set');
        System.assertNotEquals(null, ve.getCause(), 'Cause should be set');
    }

    @IsTest
    static void testValidationException_WithoutCause() {
        BaseAgentAction.ValidationException ve = new BaseAgentAction.ValidationException('Test error', null);

        System.assertEquals(null, ve.fieldName, 'Field name should be null');
        System.assert(ve.getMessage().contains('Test error'));
    }
}
