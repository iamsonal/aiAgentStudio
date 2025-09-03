@IsTest
private class SemanticReferenceTest {
    @IsTest
    static void parse_inputReference_parsesCorrectly() {
        String reference = '{!input.searchQuery}';

        Test.startTest();
        SemanticReference ref = SemanticReference.parse(reference);
        Test.stopTest();

        System.assertEquals(SemanticReference.Scope.INPUT, ref.scope, 'Should parse INPUT scope');
        System.assertEquals('searchQuery', ref.source, 'Should extract correct source');
        System.assertEquals(null, ref.fieldPath, 'Should have null field path for simple reference');
    }

    @IsTest
    static void parse_inputReferenceWithFieldPath_parsesCorrectly() {
        String reference = '{!input.user.firstName}';

        Test.startTest();
        SemanticReference ref = SemanticReference.parse(reference);
        Test.stopTest();

        System.assertEquals(SemanticReference.Scope.INPUT, ref.scope, 'Should parse INPUT scope');
        System.assertEquals('user', ref.source, 'Should extract correct source');
        System.assertEquals('firstName', ref.fieldPath, 'Should extract correct field path');
    }

    @IsTest
    static void parse_nodeReference_parsesCorrectly() {
        String reference = '{!node.find_account.output.Id}';

        Test.startTest();
        SemanticReference ref = SemanticReference.parse(reference);
        Test.stopTest();

        System.assertEquals(SemanticReference.Scope.NODE, ref.scope, 'Should parse NODE scope');
        System.assertEquals('find_account', ref.source, 'Should extract correct node name');
        System.assertEquals('Id', ref.fieldPath, 'Should extract correct field path');
    }

    @IsTest
    static void parse_nodeReferenceWithNestedPath_parsesCorrectly() {
        String reference = '{!node.search_results.output.records.0.Name}';

        Test.startTest();
        SemanticReference ref = SemanticReference.parse(reference);
        Test.stopTest();

        System.assertEquals(SemanticReference.Scope.NODE, ref.scope, 'Should parse NODE scope');
        System.assertEquals('search_results', ref.source, 'Should extract correct node name');
        System.assertEquals('records.0.Name', ref.fieldPath, 'Should extract correct nested field path');
    }

    @IsTest
    static void parse_contextReference_parsesCorrectly() {
        String reference = '{!context.userId}';

        Test.startTest();
        SemanticReference ref = SemanticReference.parse(reference);
        Test.stopTest();

        System.assertEquals(SemanticReference.Scope.CONTEXT, ref.scope, 'Should parse CONTEXT scope');
        System.assertEquals('userId', ref.source, 'Should extract correct context variable');
        System.assertEquals(null, ref.fieldPath, 'Should have null field path for simple context reference');
    }

    @IsTest
    static void parse_resultReference_parsesCorrectly() {
        String reference = '{!result.isSuccess}';

        Test.startTest();
        SemanticReference ref = SemanticReference.parse(reference);
        Test.stopTest();

        System.assertEquals(SemanticReference.Scope.RESULT, ref.scope, 'Should parse RESULT scope');
        System.assertEquals('isSuccess', ref.source, 'Should extract correct result property');
        System.assertEquals(null, ref.fieldPath, 'Should have null field path for simple result reference');
    }

    @IsTest
    static void parse_resultReferenceWithFieldPath_parsesCorrectly() {
        String reference = '{!result.output.recordCount}';

        Test.startTest();
        SemanticReference ref = SemanticReference.parse(reference);
        Test.stopTest();

        System.assertEquals(SemanticReference.Scope.RESULT, ref.scope, 'Should parse RESULT scope');
        System.assertEquals('output', ref.source, 'Should extract correct result property');
        System.assertEquals('recordCount', ref.fieldPath, 'Should extract correct field path');
    }

    @IsTest
    static void parse_invalidFormat_throwsException() {
        String reference = 'invalid.reference';

        Test.startTest();
        try {
            SemanticReference.parse(reference);
            System.assert(false, 'Should have thrown GraphConfigurationException');
        } catch (GraphExecutionService.GraphConfigurationException e) {
            System.assert(e.getMessage().contains('Invalid reference format'), 'Should indicate invalid format');
        }
        Test.stopTest();
    }

    @IsTest
    static void parse_emptyReference_throwsException() {
        String reference = '{!}';

        Test.startTest();
        try {
            SemanticReference.parse(reference);
            System.assert(false, 'Should have thrown GraphConfigurationException');
        } catch (GraphExecutionService.GraphConfigurationException e) {
            System.assert(e.getMessage().contains('Invalid reference format'), 'Should indicate invalid format');
        }
        Test.stopTest();
    }

    @IsTest
    static void parse_invalidScope_throwsException() {
        String reference = '{!invalid.parameter}';

        Test.startTest();
        try {
            SemanticReference.parse(reference);
            System.assert(false, 'Should have thrown GraphConfigurationException');
        } catch (GraphExecutionService.GraphConfigurationException e) {
            System.assert(e.getMessage().contains('Invalid scope'), 'Should indicate invalid scope');
        }
        Test.stopTest();
    }

    @IsTest
    static void parse_nodeReferenceWithoutOutput_throwsException() {
        String reference = '{!node.find_account.result}';

        Test.startTest();
        try {
            SemanticReference.parse(reference);
            System.assert(false, 'Should have thrown GraphConfigurationException');
        } catch (GraphExecutionService.GraphConfigurationException e) {
            System.assert(e.getMessage().contains('Invalid "node" reference format'), 'Should indicate invalid node format');
        }
        Test.stopTest();
    }

    @IsTest
    static void parse_incompleteReference_throwsException() {
        String reference = '{!input}';

        Test.startTest();
        try {
            SemanticReference.parse(reference);
            System.assert(false, 'Should have thrown GraphConfigurationException');
        } catch (GraphExecutionService.GraphConfigurationException e) {
            System.assert(e.getMessage().contains('Must have at least a source'), 'Should indicate missing source');
        }
        Test.stopTest();
    }

    @IsTest
    static void resolveValue_inputReference_returnsValue() {
        Map<String, Object> stateMap = new Map<String, Object>{
            'inputs' => new Map<String, Object>{ 'searchQuery' => 'test query', 'userId' => '12345' }
        };

        SemanticReference ref = SemanticReference.parse('{!input.searchQuery}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals('test query', result, 'Should resolve input reference correctly');
    }

    @IsTest
    static void resolveValue_inputReferenceWithFieldPath_returnsValue() {
        Map<String, Object> stateMap = new Map<String, Object>{
            'inputs' => new Map<String, Object>{ 'user' => new Map<String, Object>{ 'firstName' => 'John', 'lastName' => 'Doe' } }
        };

        SemanticReference ref = SemanticReference.parse('{!input.user.firstName}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals('John', result, 'Should resolve nested input reference correctly');
    }

    @IsTest
    static void resolveValue_nodeReference_returnsValue() {
        Map<String, Object> stateMap = new Map<String, Object>{
            'nodes' => new Map<String, Object>{
                'find_account' => new Map<String, Object>{
                    'output' => new Map<String, Object>{ 'Id' => '001000000000001', 'Name' => 'Test Account' }
                }
            }
        };

        SemanticReference ref = SemanticReference.parse('{!node.find_account.output.Id}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals('001000000000001', result, 'Should resolve node output reference correctly');
    }

    @IsTest
    static void resolveValue_nodeReferenceWithArrayIndex_returnsValue() {
        Map<String, Object> stateMap = new Map<String, Object>{
            'nodes' => new Map<String, Object>{
                'search_results' => new Map<String, Object>{
                    'output' => new Map<String, Object>{
                        'records' => new List<Object>{
                            new Map<String, Object>{ 'Name' => 'First Record' },
                            new Map<String, Object>{ 'Name' => 'Second Record' }
                        }
                    }
                }
            }
        };

        SemanticReference ref = SemanticReference.parse('{!node.search_results.output.records[0].Name}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals('First Record', result, 'Should resolve array indexed reference correctly');
    }

    @IsTest
    static void resolveValue_contextUserId_returnsValue() {
        Id testUserId = UserInfo.getUserId();
        Map<String, Object> stateMap = new Map<String, Object>{ 'originalUserId' => testUserId };

        SemanticReference ref = SemanticReference.parse('{!context.userId}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(testUserId, result, 'Should resolve context userId correctly');
    }

    @IsTest
    static void resolveValue_contextOriginalUserId_returnsValue() {
        Id testUserId = UserInfo.getUserId();
        Map<String, Object> stateMap = new Map<String, Object>{ 'originalUserId' => testUserId };

        SemanticReference ref = SemanticReference.parse('{!context.originalUserId}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(testUserId, result, 'Should resolve context originalUserId correctly');
    }

    @IsTest
    static void resolveValue_contextExecutionUserId_returnsValue() {
        Id testUserId = UserInfo.getUserId();
        Map<String, Object> stateMap = new Map<String, Object>{ 'executionUserId' => testUserId };

        SemanticReference ref = SemanticReference.parse('{!context.executionUserId}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(testUserId, result, 'Should resolve context executionUserId correctly');
    }

    @IsTest
    static void resolveValue_contextChatSessionId_returnsValue() {
        String testSessionId = 'test-session-123';
        Map<String, Object> stateMap = new Map<String, Object>{ 'chatSessionId' => testSessionId };

        SemanticReference ref = SemanticReference.parse('{!context.chatSessionId}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(testSessionId, result, 'Should resolve context chatSessionId correctly');
    }

    @IsTest
    static void resolveValue_contextTurnIdentifier_returnsValue() {
        String testTurnId = 'turn-123';
        Map<String, Object> stateMap = new Map<String, Object>{ 'turnIdentifier' => testTurnId };

        SemanticReference ref = SemanticReference.parse('{!context.turnIdentifier}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(testTurnId, result, 'Should resolve context turnIdentifier correctly');
    }

    @IsTest
    static void resolveValue_contextCurrentTurnCount_returnsValue() {
        Integer testTurnCount = 5;
        Map<String, Object> stateMap = new Map<String, Object>{ 'currentTurnCount' => testTurnCount };

        SemanticReference ref = SemanticReference.parse('{!context.currentTurnCount}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(testTurnCount, result, 'Should resolve context currentTurnCount correctly');
    }

    @IsTest
    static void resolveValue_contextAgentDefinitionId_returnsValue() {
        String testAgentId = 'agent-123';
        Map<String, Object> stateMap = new Map<String, Object>{ 'agentDefinitionId' => testAgentId };

        SemanticReference ref = SemanticReference.parse('{!context.agentDefinitionId}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(testAgentId, result, 'Should resolve context agentDefinitionId correctly');
    }

    @IsTest
    static void resolveValue_contextUnknownVariable_returnsNull() {
        Map<String, Object> stateMap = new Map<String, Object>();

        SemanticReference ref = SemanticReference.parse('{!context.unknownVariable}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for unknown context variable');
    }

    @IsTest
    static void resolveValue_resultReference_returnsValue() {
        Map<String, Object> stateMap = new Map<String, Object>{
            'currentNodeResult' => new Map<String, Object>{ 'isSuccess' => true, 'output' => 'Success result' }
        };

        SemanticReference ref = SemanticReference.parse('{!result.isSuccess}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(true, result, 'Should resolve result reference correctly');
    }

    @IsTest
    static void resolveValue_resultReferenceWithFieldPath_returnsValue() {
        Map<String, Object> stateMap = new Map<String, Object>{
            'currentNodeResult' => new Map<String, Object>{ 'output' => new Map<String, Object>{ 'recordCount' => 10, 'status' => 'completed' } }
        };

        SemanticReference ref = SemanticReference.parse('{!result.output.recordCount}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(10, result, 'Should resolve nested result reference correctly');
    }

    @IsTest
    static void resolveValue_nonExistentReference_returnsNull() {
        Map<String, Object> stateMap = new Map<String, Object>{ 'inputs' => new Map<String, Object>{ 'existingParam' => 'value' } };

        SemanticReference ref = SemanticReference.parse('{!input.nonExistentParam}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for non-existent reference');
    }

    @IsTest
    static void resolveValue_invalidFieldPath_returnsNull() {
        Map<String, Object> stateMap = new Map<String, Object>{ 'inputs' => new Map<String, Object>{ 'user' => 'simple string value' } };

        SemanticReference ref = SemanticReference.parse('{!input.user.firstName}');

        Test.startTest();
        Object result = ref.resolveValue(stateMap);
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null when trying to navigate into non-map value');
    }

    @IsTest
    static void getNestedValue_arrayIndexing_returnsCorrectValue() {
        SemanticReference ref = SemanticReference.parse('{!input.dummy}'); // Just to get an instance

        Map<String, Object> data = new Map<String, Object>{
            'records' => new List<Object>{
                new Map<String, Object>{ 'Name' => 'First', 'Id' => '001' },
                new Map<String, Object>{ 'Name' => 'Second', 'Id' => '002' }
            }
        };

        Test.startTest();
        Object result = ref.getNestedValue(data, 'records[1].Name');
        Test.stopTest();

        System.assertEquals('Second', result, 'Should return correct value from array index');
    }

    @IsTest
    static void getNestedValue_arrayIndexOutOfBounds_returnsNull() {
        SemanticReference ref = SemanticReference.parse('{!input.dummy}'); // Just to get an instance

        Map<String, Object> data = new Map<String, Object>{ 'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'First' } } };

        Test.startTest();
        Object result = ref.getNestedValue(data, 'records[5].Name');
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for out of bounds array index');
    }

    @IsTest
    static void getNestedValue_invalidArrayIndex_returnsNull() {
        SemanticReference ref = SemanticReference.parse('{!input.dummy}'); // Just to get an instance

        Map<String, Object> data = new Map<String, Object>{ 'records' => new List<Object>{ new Map<String, Object>{ 'Name' => 'First' } } };

        Test.startTest();
        Object result = ref.getNestedValue(data, 'records[invalid].Name');
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for invalid array index');
    }

    @IsTest
    static void getNestedValue_arrayIndexOnNonList_returnsNull() {
        SemanticReference ref = SemanticReference.parse('{!input.dummy}'); // Just to get an instance

        Map<String, Object> data = new Map<String, Object>{ 'records' => 'not a list' };

        Test.startTest();
        Object result = ref.getNestedValue(data, 'records[0].Name');
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null when trying to index non-list value');
    }

    @IsTest
    static void getNestedValue_nullData_returnsNull() {
        SemanticReference ref = SemanticReference.parse('{!input.dummy}'); // Just to get an instance

        Test.startTest();
        Object result = ref.getNestedValue(null, 'any.path');
        Test.stopTest();

        System.assertEquals(null, result, 'Should return null for null data');
    }

    @IsTest
    static void getNestedValue_emptyPath_returnsOriginalData() {
        SemanticReference ref = SemanticReference.parse('{!input.dummy}'); // Just to get an instance

        Map<String, Object> data = new Map<String, Object>{ 'key' => 'value' };

        Test.startTest();
        Object result = ref.getNestedValue(data, '');
        Test.stopTest();

        System.assertEquals(data, result, 'Should return original data for empty path');
    }

    @IsTest
    static void getNestedValue_complexNestedPath_returnsValue() {
        SemanticReference ref = SemanticReference.parse('{!input.dummy}'); // Just to get an instance

        Map<String, Object> data = new Map<String, Object>{
            'level1' => new Map<String, Object>{
                'level2' => new Map<String, Object>{ 'level3' => new Map<String, Object>{ 'finalValue' => 'found it' } }
            }
        };

        Test.startTest();
        Object result = ref.getNestedValue(data, 'level1.level2.level3.finalValue');
        Test.stopTest();

        System.assertEquals('found it', result, 'Should navigate complex nested path correctly');
    }
}
