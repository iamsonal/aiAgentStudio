/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Test class for the ActionGetRecords standard action implementation.
 *              Verifies functionality using the standard Account object, including
 *              record retrieval, filtering, ordering, limits, permissions, and error handling.
 * @see ActionGetRecords
 * @see IAgentAction
 * @see FrameworkUtils
 */
@isTest
private class ActionGetRecordsTest {
    private static final String ACCOUNT_API_NAME = 'Account';
    private static List<Id> accountIds;
    private static Id parentAccountId;

    @TestSetup
    static void makeData() {
        Account parent = new Account(Name = 'Parent Company Inc');
        insert parent;
        parentAccountId = parent.Id;

        List<Account> testAccounts = new List<Account>{
            new Account(
                Name = 'Alpha Test Inc',
                AccountNumber = 'A100',
                Industry = 'Technology',
                Rating = 'Hot',
                Phone = '111-1111',
                NumberOfEmployees = 100,
                AnnualRevenue = 5000000,
                ParentId = parentAccountId,
                /* IsCustomerPortal = true, REMOVED */ TickerSymbol = 'ATI'
            ),
            new Account(
                Name = 'Bravo Services',
                AccountNumber = 'B200',
                Industry = 'Consulting',
                Rating = 'Warm',
                Phone = '222-2222',
                NumberOfEmployees = 50,
                AnnualRevenue = 1000000,
                /* IsCustomerPortal = false, REMOVED */ TickerSymbol = null
            ),
            new Account(
                Name = 'Charlie Mfg',
                AccountNumber = 'C300',
                Industry = 'Manufacturing',
                Rating = 'Cold',
                Phone = '333-3333',
                NumberOfEmployees = 500,
                AnnualRevenue = 25000000,
                ParentId = parentAccountId,
                /* IsCustomerPortal = false, REMOVED */ TickerSymbol = 'CMF'
            ),
            new Account(
                Name = 'Alpha Holdings',
                AccountNumber = 'A101',
                Industry = 'Finance',
                Rating = 'Hot',
                Phone = '444-4444',
                NumberOfEmployees = 20,
                AnnualRevenue = 10000000,
                /* IsCustomerPortal = true, REMOVED */ TickerSymbol = 'ALHO'
            )
        };

        Test.startTest();

        Long startTime = System.currentTimeMillis();
        while (System.currentTimeMillis() < startTime + 100) {
        }
        insert testAccounts;
        Test.stopTest();

        accountIds = new List<Id>();
        for (Account acc : testAccounts) {
            accountIds.add(acc.Id);
        }
    }

    private static String buildConfigJson(String objectApiName, List<String> defaultFields) {
        return buildConfigJson(objectApiName, defaultFields, null);
    }

    private static String buildConfigJson(String objectApiName, List<String> defaultFields, Object maxReturn) {
        Map<String, Object> configMap = new Map<String, Object>();
        configMap.put('objectApiName', objectApiName);

        List<String> fieldsWithId = defaultFields == null ? new List<String>() : new List<String>(defaultFields);
        if (!new Set<String>(fieldsWithId).contains('Id')) {
            fieldsWithId.add('Id');
        }
        if (!fieldsWithId.isEmpty()) {
            configMap.put('defaultFields', fieldsWithId);
        }

        if (maxReturn != null) {
            configMap.put('maxReturnToLLM', maxReturn);
        }
        return JSON.serialize(configMap);
    }

    private static String buildArgsJson(
        Map<String, Object> filters,
        List<String> additionalFields,
        Integer limitParam,
        String orderBy
    ) {
        Map<String, Object> argsMap = new Map<String, Object>();
        if (filters != null && !filters.isEmpty())
            argsMap.put('filters', filters);
        if (additionalFields != null && !additionalFields.isEmpty())
            argsMap.put('additionalFields', additionalFields);
        if (limitParam != null)
            argsMap.put('limit', limitParam);
        if (orderBy != null)
            argsMap.put('orderBy', orderBy);
        return JSON.serialize(argsMap);
    }

    private static ActionResult executeAction(String configJson, String argsJson) {
        ActionGetRecords action = new ActionGetRecords();
        ActionContext mockContext = new ActionContext(null, UserInfo.getUserId(), null, null, null, null);
        return action.execute(configJson, argsJson, mockContext);
    }

    @isTest
    static void testSuccess_BasicGet() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'Phone' });

        String argsJson = buildArgsJson(null, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Action should succeed. Details: ' + result.internalDetails);
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');
        System.assert(records != null, 'Records list should exist.');

        System.assertEquals(5, records.size(), 'Should return 5 records (total created: 5, limit: 10)');
        System.assertEquals(5, (Integer) outputMap.get('count'), 'Count should report 5 found');

        System.assert(
            outputMap.get('message').ToString().contains('Found and showing all 5'),
            'Success message incorrect.'
        );

        SObject firstRec = records[0];
        Set<String> populatedFields = firstRec.getPopulatedFieldsAsMap().keySet();
        System.assert(populatedFields.contains('Id'), 'Id should be included.');
        System.assert(populatedFields.contains('Name'), 'Name should be included.');
        System.assert(populatedFields.contains('Phone'), 'Phone should be included.');
        System.assert(!populatedFields.contains('AccountNumber'), 'AccountNumber should NOT be included by default.');
    }

    @isTest
    static void testSuccess_WithFilters() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
        Map<String, Object> filters = new Map<String, Object>{ 'Rating' => 'Hot' };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Filter test should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(2, records.size(), 'Should find 2 "Hot" accounts.');
        System.assertEquals(2, (Integer) outputMap.get('count'), 'Count should report 2 found');
        for (SObject rec : records) {
            System.assertEquals('Hot', (String) rec.get('Rating'), 'Only Hot accounts expected.');
        }
    }

    @isTest
    static void testSuccess_WithOrdering() {
        Account parent = [SELECT Id FROM Account WHERE Name = 'Parent Company Inc' LIMIT 1];

        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'AnnualRevenue' });

        Map<String, Object> filters = new Map<String, Object>{
            'Id' => new Map<String, Object>{ '!=' => parent.Id },
            'AnnualRevenue' => new Map<String, Object>{ '!=' => null }
        };

        String argsJson = buildArgsJson(filters, null, 10, 'AnnualRevenue DESC');

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(
            result.isSuccess,
            'Order By test with filter should succeed. Details: ' + result?.internalDetails
        );

        System.assert(result.outputForLlm instanceof Map<String, Object>, 'Output should be a Map.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        System.assert(outputMap.get('records') instanceof List<Object>, 'Records key should contain a List.');
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(4, records.size(), 'Should return exactly 4 records after filtering.');
        System.assertEquals(4, (Integer) outputMap.get('count'), 'Count should report 4 after filtering.');
        System.assert(
            outputMap.get('message').toString().contains('Found and showing all 4'),
            'Message should indicate 4 found/shown.'
        );

        System.assertEquals('Charlie Mfg', (String) records[0].get('Name'), 'Highest revenue expected first.');
        System.assertEquals('Alpha Holdings', (String) records[1].get('Name'), 'Second highest revenue expected.');
        System.assertEquals('Alpha Test Inc', (String) records[2].get('Name'), 'Third highest revenue expected.');
        System.assertEquals('Bravo Services', (String) records[3].get('Name'), 'Lowest revenue expected last.');
    }

    @isTest
    static void testSuccess_WithLimit() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });

        String argsJson = buildArgsJson(null, null, 2, 'Name ASC');

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Limit test should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(2, records.size(), 'Result size should match limit.');
        System.assertEquals(
            2,
            (Integer) outputMap.get('count'),
            'Count should reflect records returned by query limit'
        );
        System.assert(
            outputMap.get('message').toString().contains('Found and showing all 2'),
            'Message should report count returned by limit'
        );
    }

    @isTest
    static void testSuccess_NoRecordsFound() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
        Map<String, Object> filters = new Map<String, Object>{ 'Name' => 'NonExistentAccountXYZ' };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Should succeed even if no records found.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(0, records.size(), 'Should return 0 records.');
        System.assertEquals(0, (Integer) outputMap.get('count'), 'Count should be 0.');
        System.assert(
            outputMap.get('message').ToString().contains('No Account records found'),
            'Message should indicate none found.'
        );
    }

    @isTest
    static void testFailure_Config_MalformedJson() {
        String configJson = '{"o';
        ActionResult result = executeAction(configJson, '{}');
        System.assert(!result.isSuccess);
        System.assertEquals('CONFIG_ERROR', result.errorCode);
    }
    @isTest
    static void testFailure_Config_MissingObjectApiName() {
        String configJson = '{}';
        ActionResult result = executeAction(configJson, '{}');
        System.assert(!result.isSuccess);
        System.assertEquals('CONFIG_ERROR', result.errorCode);
    }
    @isTest
    static void testFailure_Config_InvalidObjectApiName() {
        String configJson = '{"objectApiName": "Bad__c"}';
        ActionResult result = executeAction(configJson, '{}');
        System.assert(!result.isSuccess);
        System.assertEquals('CONFIG_ERROR', result.errorCode);
    }

    @isTest
    static void testFailure_Args_InvalidLimitType() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
        String argsJson = '{"limit": "five"}';
        ActionResult result = executeAction(configJson, argsJson);
        System.assert(!result.isSuccess, 'Should fail with invalid limit type.');
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
        System.assert(
            result.internalDetails.contains('Parameter "limit" must be a valid Integer'),
            'Should mention limit validation'
        );
    }

    @isTest
    static void testFailure_Args_InvalidFilterDataTypeForCoercion() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
        Map<String, Object> filters = new Map<String, Object>{ 'AnnualRevenue' => 'Not A Number' };
        String argsJson = buildArgsJson(filters, null, 10, null);
        ActionResult result = null;

        Test.startTest();
        result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail if filter value cannot be coerced.');
        System.assertEquals('INPUT_VALIDATION', result.errorCode);

        System.assert(
            result.internalDetails.contains('Invalid value provided for filter field "AnnualRevenue"'),
            'Main error message mismatch.'
        );

        System.assert(
            result.internalDetails.contains('Details: Invalid decimal: Not A Number'),
            'Original coercion error detail missing.'
        );

        System.assert(
            result.internalDetails.contains('Expected type compatible with CURRENCY'),
            'Expected type mention mismatch.'
        );
    }

    @isTest
    static void testFailure_Permission_ObjectReadDenied() {
        ActionResult actionResult = null;

        Profile p = [SELECT Id FROM Profile WHERE Name = 'Chatter Free User' LIMIT 1];
        User restrictedUser = new User(
            ProfileId = p.Id,
            LastName = 'NoRead',
            Alias = 'nor',
            Email = 'noread@test.com',
            UserName = 'noread@test.aiagentfw.com' + System.currentTimeMillis(),
            LocaleSidKey = 'en_US',
            LanguageLocaleKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            TimeZoneSidKey = 'America/Los_Angeles',
            IsActive = true
        );
        insert restrictedUser;

        System.runAs(restrictedUser) {
            Test.startTest();
            String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
            String argsJson = buildArgsJson(null, null, 1, null);

            actionResult = executeAction(configJson, argsJson);
            Test.stopTest();
        }

        System.assert(actionResult != null && !actionResult.isSuccess, 'Action should fail due to object read denial.');
        System.assertEquals('PERMISSION_DENIED', actionResult.errorCode);
        System.assert(actionResult.internalDetails.contains('User does not have READABLE access on SObject Account'));
    }

    @isTest
    static void testFailure_OrderBy_InvalidField() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });

        String argsJson = buildArgsJson(null, null, 10, 'FieldDoesNotExist__c ASC');

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Action should fail validation for invalid ORDER BY field.');
        System.assertEquals('INPUT_VALIDATION', result.errorCode);

        System.assert(
            result.internalDetails.contains(
                'ORDER BY field "FieldDoesNotExist__c" (or its base relationship "FieldDoesNotExist__c") not found on object Account.'
            ),
            'Details should indicate missing order by field.'
        );
    }

    @isTest
    static void testFailure_FilterBy_InvalidField() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
        Map<String, Object> filters = new Map<String, Object>{ 'NonFilterableField__c' => 'abc' };
        String argsJson = buildArgsJson(filters, null, 10, null);
        ActionResult result = null;

        Test.startTest();
        result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Action should fail validation for invalid FILTER field.');

        System.assertEquals('INPUT_VALIDATION', result.errorCode);

        System.assert(
            result.internalDetails.contains('Filter field "NonFilterableField__c" not found on object Account.'),
            'Details should indicate missing filter field.'
        );
    }

    @isTest
    static void testSuccess_Config_MaxReturnInteger() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' }, 2);
        String argsJson = buildArgsJson(null, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Config with integer maxReturn should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');
        System.assertEquals(2, records.size(), 'Should return only 2 records as specified by config.');

        System.assertEquals(5, (Integer) outputMap.get('count'), 'Count should report all 5 found records.');
        System.assert(outputMap.get('message').toString().contains('Showing the first 2'));
    }

    @isTest
    static void testSuccess_Config_MaxReturnDecimal() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' }, 3.0);
        String argsJson = buildArgsJson(null, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Config with decimal maxReturn should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');
        System.assertEquals(3, records.size(), 'Should return 3 records as specified by config.');

        System.assertEquals(5, (Integer) outputMap.get('count'), 'Count should report all 5 found records.');
        System.assert(outputMap.get('message').toString().contains('Showing the first 3'));
    }

    @isTest
    static void testSuccess_Config_MaxReturnString() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' }, '1');
        String argsJson = buildArgsJson(null, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Config with string maxReturn should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');
        System.assertEquals(1, records.size(), 'Should return 1 record as specified by config.');

        System.assertEquals(5, (Integer) outputMap.get('count'), 'Count should report all 5 found records.');
        System.assert(outputMap.get('message').toString().contains('Showing the first 1'));
    }

    @isTest
    static void testSuccess_Config_MaxReturnZeroDefaults() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' }, 0);
        String argsJson = buildArgsJson(null, null, 15, null);
        Integer expectedDefaultMaxReturn = ActionGetRecords.DEFAULT_MAX_RETURNED_TO_LLM;

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Config with zero maxReturn should default.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        Integer expectedSize = Math.min(5, expectedDefaultMaxReturn);
        System.assertEquals(expectedSize, records.size(), 'Should return default max or actual count if lower.');

        System.assertEquals(5, (Integer) outputMap.get('count'), 'Count should report all 5 found records.');
        System.assert(outputMap.get('message').toString().contains('showing all 5'));
    }

    @isTest
    static void testSuccess_Config_MaxReturnInvalidStringDefaults() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' }, 'invalidNumber');
        String argsJson = buildArgsJson(null, null, 15, null);
        Integer expectedDefaultMaxReturn = ActionGetRecords.DEFAULT_MAX_RETURNED_TO_LLM;

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Config with invalid string maxReturn should default.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        Integer expectedSize = Math.min(5, expectedDefaultMaxReturn);
        System.assertEquals(expectedSize, records.size(), 'Should return default max or actual count if lower.');

        System.assertEquals(5, (Integer) outputMap.get('count'), 'Count should report all 5 found records.');
        System.assert(outputMap.get('message').toString().contains('showing all 5'));
    }

    @isTest
    static void testSuccess_Filter_Operators_Number() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'AnnualRevenue' });

        Map<String, Object> filters = new Map<String, Object>{
            'AnnualRevenue' => new Map<String, Object>{ '>' => 1000000, '<=' => 10000000 },
            'NumberOfEmployees' => new Map<String, Object>{ '!=' => 500 }
        };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Complex number filter test should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(2, records.size(), 'Should find 2 accounts matching criteria.');
        System.assertEquals(2, (Integer) outputMap.get('count'), 'Count should be 2');
        Set<String> names = new Set<String>();
        for (SObject acc : records) {
            names.add((String) acc.get('Name'));
        }
        System.assert(names.contains('Alpha Test Inc'), 'Expected Alpha Test Inc');
        System.assert(names.contains('Alpha Holdings'), 'Expected Alpha Holdings');
    }

    @isTest
    static void testSuccess_Filter_Operator_Like() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'Industry' });
        Map<String, Object> filters = new Map<String, Object>{
            'Name' => new Map<String, Object>{ 'LIKE' => 'Alpha%' }
        };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'LIKE operator test should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(2, records.size(), 'Should find 2 accounts starting with Alpha.');
        System.assertEquals(2, (Integer) outputMap.get('count'), 'Count should be 2');
        for (SObject rec : records) {
            System.assert(((String) rec.get('Name')).startsWith('Alpha'), 'Only Alpha names expected.');
        }
    }

    @isTest
    static void testSuccess_Filter_Operator_InList() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'Industry' });
        List<String> targetIndustries = new List<String>{ 'Consulting', 'Finance' };
        Map<String, Object> filters = new Map<String, Object>{
            'Industry' => new Map<String, Object>{ 'IN' => targetIndustries }
        };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'IN operator test should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(2, records.size(), 'Should find 2 accounts in Consulting or Finance.');
        System.assertEquals(2, (Integer) outputMap.get('count'), 'Count should be 2');
        Set<String> names = new Set<String>();
        for (SObject acc : records) {
            names.add((String) acc.get('Name'));
        }
        System.assert(names.contains('Bravo Services'), 'Expected Bravo Services');
        System.assert(names.contains('Alpha Holdings'), 'Expected Alpha Holdings');
    }

    @isTest
    static void testSuccess_Filter_Operator_NotNull() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'TickerSymbol' });

        Map<String, Object> filters = new Map<String, Object>{
            'TickerSymbol' => new Map<String, Object>{ '!=' => null }
        };
        String argsJson = buildArgsJson(filters, null, 10, 'Name ASC');

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Not equals null test should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(3, records.size(), 'Should find 3 accounts with non-null Ticker Symbols.');
        System.assertEquals(3, (Integer) outputMap.get('count'), 'Count should be 3');
        System.assertEquals('Alpha Holdings', (String) records[0].get('Name'));
    }

    @isTest
    static void testSuccess_Filter_DateTime() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'CreatedDate' });

        Account anAccount = [SELECT CreatedDate FROM Account ORDER BY CreatedDate ASC LIMIT 1];
        DateTime createdDateTime = anAccount.CreatedDate;

        Date createdDayGmt = createdDateTime.dateGmt();
        String startOfDayGmtString =
            createdDayGmt.year() +
            '-' +
            String.valueOf(createdDayGmt.month()).leftPad(2, '0') +
            '-' +
            String.valueOf(createdDayGmt.day()).leftPad(2, '0') +
            ' 00:00:00';

        Map<String, Object> filters = new Map<String, Object>{
            'CreatedDate' => new Map<String, Object>{ '>=' => startOfDayGmtString }
        };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'DateTime filter should succeed. Details: ' + result.internalDetails);
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assert(records.size() >= 1, 'Should find accounts created on or after the start of the specified day.');
        System.assertEquals(5, records.size(), 'Expected to find all 5 accounts based on test setup and filter.');
        System.assertEquals(5, (Integer) outputMap.get('count'), 'Count should be 5');
    }

    @isTest
    static void testSuccess_Filter_Picklist_Complex() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'Rating' });
        Map<String, Object> filters = new Map<String, Object>{ 'Rating' => new Map<String, Object>{ '=' => 'Warm' } };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Picklist filter with complex map should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(1, records.size(), 'Should find 1 account with Rating = Warm.');
        System.assertEquals(1, (Integer) outputMap.get('count'), 'Count should be 1');
        System.assertEquals('Warm', records[0].get('Rating'), 'Rating mismatch.');
    }

    @isTest
    static void testSuccess_Filter_Id() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'ParentId' });
        Map<String, Object> filters = new Map<String, Object>{ 'ParentId' => parentAccountId };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(result.isSuccess, 'Id filter should succeed.');
        Map<String, Object> outputMap = (Map<String, Object>) result.outputForLlm;
        List<SObject> records = (List<SObject>) outputMap.get('records');

        System.assertEquals(2, records.size(), 'Should find 2 accounts with the correct ParentId.');
        System.assertEquals(2, (Integer) outputMap.get('count'), 'Count should be 2');
    }

    @isTest
    static void testFailure_Filter_InList_Empty() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name', 'Industry' });
        List<String> emptyList = new List<String>();
        Map<String, Object> filters = new Map<String, Object>{
            'Industry' => new Map<String, Object>{ 'IN' => emptyList }
        };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail with empty IN list.');
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
        System.assert(
            result.internalDetails.contains('Cannot use IN operator with an empty list'),
            'Expected empty list error message.'
        );
    }

    @isTest
    static void testFailure_Filter_ComplexOperator_Unsupported() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
        Map<String, Object> filters = new Map<String, Object>{
            'Rating' => new Map<String, Object>{ 'CONTAINS' => 'Warm' }
        };
        String argsJson = buildArgsJson(filters, null, 10, null);
        ActionResult result = null;

        Test.startTest();
        result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Action should fail with unsupported operator.');
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
        System.assert(
            result.internalDetails.contains('Unsupported filter operator "CONTAINS"'),
            'Expected unsupported operator error.'
        );
    }

    @isTest
    static void testFailure_Coercion_InvalidId() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
        Map<String, Object> filters = new Map<String, Object>{ 'ParentId' => 'invalid-id-format' };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail coercing invalid ID string.');
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
    }

    @isTest
    static void testFailure_Coercion_InvalidPicklistValue() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
        Map<String, Object> filters = new Map<String, Object>{ 'Rating' => 'Invalid Rating Value' };
        String argsJson = buildArgsJson(filters, null, 10, null);

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Should fail coercing invalid picklist value.');
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
    }

    @isTest
    static void testFailure_Args_MalformedJsonArgs() {
        String configJson = buildConfigJson(ACCOUNT_API_NAME, new List<String>{ 'Name' });
        String argsJson = '{"filters": {"Na';

        Test.startTest();
        ActionResult result = executeAction(configJson, argsJson);
        Test.stopTest();

        System.assert(!result.isSuccess, 'Action should fail parsing malformed arguments JSON.');
        System.assertEquals('INPUT_VALIDATION', result.errorCode);
        System.assert(
            result.internalDetails.contains('Failed to parse LLM parameters'),
            'Error should indicate failure parsing parameters.'
        );
    }
}
