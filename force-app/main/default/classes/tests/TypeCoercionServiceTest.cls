/**
 * @description Comprehensive tests for TypeCoercionService coercion rules and validation
 * Following TESTING_GUIDELINES.md: tests validate observable outcomes, cover edge cases,
 * and verify correct behavior under all conditions.
 */
@IsTest
private class TypeCoercionServiceTest {
    // ========================================
    // coerceArgumentTypesForSObject Tests
    // ========================================

    @IsTest
    static void testCoerceArgumentsForSObject_ValidAccount_Success() {
        Map<String, Object> rawArgs = new Map<String, Object>{
            'Name' => 'Test Account',
            'AnnualRevenue' => '1000000',
            'NumberOfEmployees' => 500,
            'Website' => 'https://example.com'
        };

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(rawArgs, Account.SObjectType, System.AccessType.CREATABLE);
        Test.stopTest();

        System.assertEquals('Test Account', result.get('Name'), 'Name should be coerced to string');
        System.assertEquals(1000000.0, result.get('AnnualRevenue'), 'AnnualRevenue should be coerced to Decimal');
        System.assertEquals(500, result.get('NumberOfEmployees'), 'NumberOfEmployees should be coerced to Integer');
        System.assertEquals('https://example.com', result.get('Website'), 'Website should be coerced to string');
    }

    @IsTest
    static void testCoerceArgumentsForSObject_NullOrEmpty_ReturnsEmpty() {
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(null, Account.SObjectType, System.AccessType.CREATABLE);
        System.assertEquals(0, result.size(), 'Null arguments should return empty map');

        result = TypeCoercionService.coerceArgumentTypesForSObject(new Map<String, Object>(), Account.SObjectType, System.AccessType.CREATABLE);
        System.assertEquals(0, result.size(), 'Empty arguments should return empty map');
    }

    @IsTest
    static void testCoerceArgumentsForSObject_NullSObjectType_Throws() {
        Map<String, Object> rawArgs = new Map<String, Object>{ 'Name' => 'Test' };

        Boolean threw = false;
        try {
            TypeCoercionService.coerceArgumentTypesForSObject(rawArgs, null, System.AccessType.CREATABLE);
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
            System.assert(e.getMessage().contains('Target SObjectType cannot be null'), 'Should have null SObjectType error message');
        }
        System.assertEquals(true, threw, 'Null SObjectType should throw');
    }

    @IsTest
    static void testCoerceArgumentsForSObject_InvalidAccessType_Throws() {
        Map<String, Object> rawArgs = new Map<String, Object>{ 'Name' => 'Test' };

        Boolean threw = false;
        try {
            TypeCoercionService.coerceArgumentTypesForSObject(rawArgs, Account.SObjectType, System.AccessType.READABLE);
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
            System.assert(e.getMessage().contains('AccessType must be CREATABLE or UPDATABLE'), 'Should have invalid AccessType error message');
        }
        System.assertEquals(true, threw, 'Invalid AccessType should throw');
    }

    @IsTest
    static void testCoerceArgumentsForSObject_UnknownField_Skipped() {
        Map<String, Object> rawArgs = new Map<String, Object>{ 'Name' => 'Test Account', 'NonExistentField__c' => 'Value' };

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(rawArgs, Account.SObjectType, System.AccessType.CREATABLE);
        Test.stopTest();

        System.assertEquals(true, result.containsKey('Name'), 'Valid field should be present');
        System.assertEquals(false, result.containsKey('NonExistentField__c'), 'Unknown field should be skipped');
    }

    @IsTest
    static void testCoerceArgumentsForSObject_NullValue_PreservedAsNull() {
        Map<String, Object> rawArgs = new Map<String, Object>{ 'Name' => 'Test Account', 'Description' => null };

        Test.startTest();
        Map<String, Object> result = TypeCoercionService.coerceArgumentTypesForSObject(rawArgs, Account.SObjectType, System.AccessType.CREATABLE);
        Test.stopTest();

        System.assertEquals(true, result.containsKey('Description'), 'Null field should be present in result');
        System.assertEquals(null, result.get('Description'), 'Null value should be preserved');
    }

    // ========================================
    // TypeCoercionException Tests
    // ========================================

    @IsTest
    static void testTypeCoercionException_Properties() {
        TypeCoercionService.TypeCoercionException ex = new TypeCoercionService.TypeCoercionException('Test error', 'TestField', 'String', 'Integer');

        System.assertEquals('TestField', ex.fieldName, 'Field name should be set');
        System.assertEquals('String', ex.targetType, 'Target type should be set');
        System.assertEquals('Integer', ex.inputType, 'Input type should be set');
        System.assertNotEquals(null, ex.correctionGuidance, 'Correction guidance should be generated');
    }

    @IsTest
    static void testTypeCoercionException_CorrectionGuidance() {
        TypeCoercionService.TypeCoercionException idEx = new TypeCoercionService.TypeCoercionException('', '', 'ID', '');
        System.assert(idEx.correctionGuidance.contains('18-character'), 'ID guidance should mention format');

        TypeCoercionService.TypeCoercionException dateEx = new TypeCoercionService.TypeCoercionException('', '', 'Date', '');
        System.assert(dateEx.correctionGuidance.contains('YYYY-MM-DD'), 'Date guidance should mention format');

        TypeCoercionService.TypeCoercionException boolEx = new TypeCoercionService.TypeCoercionException('', '', 'Boolean', '');
        System.assert(boolEx.correctionGuidance.contains('true'), 'Boolean guidance should mention values');

        TypeCoercionService.TypeCoercionException decEx = new TypeCoercionService.TypeCoercionException('', '', 'Decimal', '');
        System.assert(decEx.correctionGuidance.contains('numeric'), 'Decimal guidance should mention numeric');
    }

    // ========================================
    // Null Handling Tests
    // ========================================

    @IsTest
    static void testCoerce_NullValue_ReturnsNull() {
        System.assertEquals(null, TypeCoercionService.coerce(null, Schema.DisplayType.STRING, 'TestField'), 'Null should return null');
        System.assertEquals(null, TypeCoercionService.coerceToString(null, 'TestField', null), 'Null string should return null');
        System.assertEquals(null, TypeCoercionService.coerceToInteger(null, 'TestField'), 'Null integer should return null');
        System.assertEquals(null, TypeCoercionService.coerceToDecimal(null, 'TestField'), 'Null decimal should return null');
        System.assertEquals(null, TypeCoercionService.coerceToBoolean(null, 'TestField'), 'Null boolean should return null');
        System.assertEquals(null, TypeCoercionService.coerceToDate(null, 'TestField'), 'Null date should return null');
        System.assertEquals(null, TypeCoercionService.coerceToDateTime(null, 'TestField'), 'Null datetime should return null');
        System.assertEquals(null, TypeCoercionService.coerceToTime(null, 'TestField'), 'Null time should return null');
        System.assertEquals(null, TypeCoercionService.coerceToId(null, 'TestField'), 'Null ID should return null');
        System.assertEquals(null, TypeCoercionService.coerceToBlob(null, 'TestField'), 'Null blob should return null');
        System.assertEquals(null, TypeCoercionService.coerceToEmailString(null, 'TestField'), 'Null email should return null');
        System.assertEquals(null, TypeCoercionService.coerceToUrlString(null, 'TestField'), 'Null URL should return null');
    }

    @IsTest
    static void testCoerce_NullTargetType_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerce('value', null, 'TestField');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
            System.assert(e.getMessage().contains('Target type cannot be null'), 'Should have null target type error');
        }
        System.assertEquals(true, threw, 'Null target type should throw');
    }

    // ========================================
    // String Coercion Tests
    // ========================================

    @IsTest
    static void testCoerceToString_ValidConversions() {
        System.assertEquals('test', TypeCoercionService.coerceToString('test', 'Name', null), 'String should remain string');
        System.assertEquals('123', TypeCoercionService.coerceToString(123, 'Name', null), 'Integer should convert to string');
        System.assertEquals('true', TypeCoercionService.coerceToString(true, 'Name', null), 'Boolean should convert to string');
    }

    @IsTest
    static void testCoerceToString_TextAreaIgnoresMaxLength() {
        Schema.DescribeFieldResult textAreaDfr = Account.Description.getDescribe();
        String longValue = 'A'.repeat(5000);

        String result = TypeCoercionService.coerceToString(longValue, 'Description', textAreaDfr);
        System.assertEquals(longValue, result, 'TextArea should allow long values');
    }

    // ========================================
    // Integer Coercion Tests
    // ========================================

    @IsTest
    static void testCoerceToInteger_ValidConversions() {
        System.assertEquals(123, TypeCoercionService.coerceToInteger(123, 'Count'), 'Integer should remain integer');
        System.assertEquals(456, TypeCoercionService.coerceToInteger(456L, 'Count'), 'Long should convert to integer');
        System.assertEquals(789, TypeCoercionService.coerceToInteger(Decimal.valueOf(789), 'Count'), 'Decimal without fraction should convert');
        System.assertEquals(100, TypeCoercionService.coerceToInteger('100', 'Count'), 'String integer should convert');
    }

    @IsTest
    static void testCoerceToInteger_LongOutOfRange_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToInteger(3000000000L, 'Count');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
            System.assert(e.getMessage().contains('out of Integer range'), 'Should mention range error');
        }
        System.assertEquals(true, threw, 'Long out of range should throw');
    }

    @IsTest
    static void testCoerceToInteger_DecimalOutOfRange_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToInteger(Decimal.valueOf('3000000000'), 'Count');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
            System.assert(e.getMessage().contains('out of Integer range'), 'Should mention range error');
        }
        System.assertEquals(true, threw, 'Decimal out of range should throw');
    }

    @IsTest
    static void testCoerceToInteger_InvalidString_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToInteger('abc', 'Count');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
            System.assert(e.getMessage().contains('Invalid Integer format'), 'Should mention invalid format');
        }
        System.assertEquals(true, threw, 'Invalid string should throw');
    }

    @IsTest
    static void testCoerceToInteger_BlankString_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToInteger('', 'Count');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank string should throw');
    }

    // ========================================
    // Decimal Coercion Tests
    // ========================================

    @IsTest
    static void testCoerceToDecimal_ValidConversions() {
        System.assertEquals(123.45, TypeCoercionService.coerceToDecimal(123.45, 'Amount'), 'Decimal should remain decimal');
        System.assertEquals(456.0, TypeCoercionService.coerceToDecimal(456, 'Amount'), 'Integer should convert to decimal');
        System.assertEquals(789.0, TypeCoercionService.coerceToDecimal(789L, 'Amount'), 'Long should convert to decimal');
        System.assertEquals(12.34, TypeCoercionService.coerceToDecimal(12.34, 'Amount'), 'Double should convert to decimal');
        System.assertEquals(99.99, TypeCoercionService.coerceToDecimal('99.99', 'Amount'), 'String decimal should convert');
    }

    @IsTest
    static void testCoerceToDecimal_InvalidString_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToDecimal('not-a-number', 'Amount');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
            System.assert(e.getMessage().contains('Invalid Decimal format'), 'Should mention invalid format');
        }
        System.assertEquals(true, threw, 'Invalid decimal string should throw');
    }

    @IsTest
    static void testCoerceToDecimal_BlankString_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToDecimal('', 'Amount');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank string should throw');
    }

    // ========================================
    // Boolean Coercion Tests
    // ========================================

    @IsTest
    static void testCoerceToBoolean_ValidTrue() {
        System.assertEquals(true, TypeCoercionService.coerceToBoolean(true, 'IsActive'), 'Boolean true should remain true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('true', 'IsActive'), 'String "true" should be true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('TRUE', 'IsActive'), 'Uppercase TRUE should be true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('1', 'IsActive'), 'String "1" should be true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('yes', 'IsActive'), 'String "yes" should be true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('YES', 'IsActive'), 'Uppercase YES should be true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('on', 'IsActive'), 'String "on" should be true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('ON', 'IsActive'), 'Uppercase ON should be true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean(1, 'IsActive'), 'Integer 1 should be true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean(2, 'IsActive'), 'Non-zero integer should be true');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean(1.5, 'IsActive'), 'Non-zero decimal should be true');
    }

    @IsTest
    static void testCoerceToBoolean_ValidFalse() {
        System.assertEquals(false, TypeCoercionService.coerceToBoolean(false, 'IsActive'), 'Boolean false should remain false');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('false', 'IsActive'), 'String "false" should be false');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('FALSE', 'IsActive'), 'Uppercase FALSE should be false');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('0', 'IsActive'), 'String "0" should be false');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('no', 'IsActive'), 'String "no" should be false');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('NO', 'IsActive'), 'Uppercase NO should be false');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('off', 'IsActive'), 'String "off" should be false');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('OFF', 'IsActive'), 'Uppercase OFF should be false');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean(0, 'IsActive'), 'Integer 0 should be false');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean(0.0, 'IsActive'), 'Decimal 0 should be false');
    }

    @IsTest
    static void testCoerceToBoolean_InvalidString_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToBoolean('maybe', 'IsActive');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
            System.assert(e.getMessage().contains('Cannot coerce to Boolean'), 'Should mention boolean coercion error');
        }
        System.assertEquals(true, threw, 'Invalid boolean string should throw');
    }

    // ========================================
    // Date Coercion Tests
    // ========================================

    @IsTest
    static void testCoerceToDate_ValidConversions() {
        Date testDate = Date.newInstance(2024, 3, 15);
        System.assertEquals(testDate, TypeCoercionService.coerceToDate(testDate, 'StartDate'), 'Date should remain date');
        System.assertEquals(testDate, TypeCoercionService.coerceToDate('2024-03-15', 'StartDate'), 'String date should convert');

        DateTime testDateTime = DateTime.newInstance(2024, 3, 15, 10, 30, 0);
        System.assertEquals(testDate, TypeCoercionService.coerceToDate(testDateTime, 'StartDate'), 'DateTime should extract date');
    }

    @IsTest
    static void testCoerceToDate_BlankString_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToDate('', 'StartDate');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank date string should throw');
    }

    // ========================================
    // DateTime Coercion Tests
    // ========================================

    @IsTest
    static void testCoerceToDateTime_ValidConversions() {
        DateTime testDateTime = DateTime.newInstance(2024, 3, 15, 14, 30, 0);
        System.assertEquals(testDateTime, TypeCoercionService.coerceToDateTime(testDateTime, 'StartDateTime'), 'DateTime should remain datetime');

        // Date to DateTime conversion - verify successful conversion
        Date testDate = Date.newInstance(2024, 3, 15);
        DateTime resultFromDate = TypeCoercionService.coerceToDateTime(testDate, 'StartDateTime');
        System.assertNotEquals(null, resultFromDate, 'Date should convert to datetime');
        // Note: Time portion is timezone-dependent, so we just verify conversion succeeded

        // ISO-8601 format parsing
        DateTime dtFromIso = TypeCoercionService.coerceToDateTime('2024-03-15T14:30:00Z', 'StartDateTime');
        System.assertNotEquals(null, dtFromIso, 'ISO-8601 should parse');

        // Salesforce datetime format parsing
        DateTime dtFromSf = TypeCoercionService.coerceToDateTime('2024-03-15 14:30:00', 'StartDateTime');
        System.assertNotEquals(null, dtFromSf, 'Salesforce format should parse');
    }

    @IsTest
    static void testCoerceToDateTime_BlankString_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToDateTime('', 'StartDateTime');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank datetime string should throw');
    }

    // ========================================
    // Time Coercion Tests
    // ========================================

    @IsTest
    static void testCoerceToTime_ValidConversions() {
        Time testTime = Time.newInstance(14, 30, 45, 0);
        System.assertEquals(testTime, TypeCoercionService.coerceToTime(testTime, 'StartTime'), 'Time should remain time');

        Time timeFromHHMM = TypeCoercionService.coerceToTime('14:30', 'StartTime');
        System.assertEquals(14, timeFromHHMM.hour(), 'Hour should be parsed');
        System.assertEquals(30, timeFromHHMM.minute(), 'Minute should be parsed');

        Time timeFromHHMMSS = TypeCoercionService.coerceToTime('14:30:45', 'StartTime');
        System.assertEquals(14, timeFromHHMMSS.hour(), 'Hour should be parsed');
        System.assertEquals(30, timeFromHHMMSS.minute(), 'Minute should be parsed');
        System.assertEquals(45, timeFromHHMMSS.second(), 'Second should be parsed');
    }

    @IsTest
    static void testCoerceToTime_InvalidFormat_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToTime('14', 'StartTime');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Single component time should throw');
    }

    @IsTest
    static void testCoerceToTime_BlankString_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToTime('', 'StartTime');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank time string should throw');
    }

    // ========================================
    // ID Coercion Tests
    // ========================================

    @IsTest
    static void testCoerceToId_ValidConversions() {
        Account acc = new Account(Name = 'Test');
        insert acc;

        Id testId = acc.Id;
        System.assertEquals(testId, TypeCoercionService.coerceToId(testId, 'AccountId'), 'Id should remain Id');
        System.assertEquals(testId, TypeCoercionService.coerceToId(String.valueOf(testId), 'AccountId'), 'String Id should convert');
    }

    @IsTest
    static void testCoerceToId_BlankString_Throws() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToId('', 'AccountId');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Blank Id string should throw');
    }

    // ========================================
    // Blob Coercion Tests
    // ========================================

    @IsTest
    static void testCoerceToBlob_ValidConversions() {
        Blob testBlob = Blob.valueOf('test');
        System.assertEquals(testBlob, TypeCoercionService.coerceToBlob(testBlob, 'Body'), 'Blob should remain blob');

        String base64String = EncodingUtil.base64Encode(Blob.valueOf('test'));
        Blob decodedBlob = TypeCoercionService.coerceToBlob(base64String, 'Body');
        System.assertEquals('test', decodedBlob.toString(), 'Base64 string should decode correctly');
    }

    // ========================================
    // Picklist Tests
    // ========================================

    @IsTest
    static void testCoercePicklist_ValidValue_Success() {
        Schema.DescribeFieldResult dfr = Case.Origin.getDescribe();
        List<Schema.PicklistEntry> entries = dfr.getPicklistValues();

        if (!entries.isEmpty()) {
            String validValue = entries[0].getValue();
            String result = (String) TypeCoercionService.coerce(validValue, Schema.DisplayType.PICKLIST, 'Origin', dfr);
            System.assertEquals(validValue, result, 'Valid picklist value should pass through');
        }
    }

    // ========================================
    // Multipicklist Tests
    // ========================================

    @IsTest
    static void testCoerceMultipicklist_ValidValues_Success() {
        // Create a custom object with multipicklist in memory for testing
        Schema.DescribeFieldResult dfr = Case.Origin.getDescribe(); // Using Origin as proxy

        String result = (String) TypeCoercionService.coerce('Value1;Value2', Schema.DisplayType.MULTIPICKLIST, 'TestField', null);
        System.assertEquals('Value1;Value2', result, 'Multipicklist without validation should pass through');
    }

    // ========================================
    // Email and URL String Tests
    // ========================================

    @IsTest
    static void testCoerceToEmailString_EdgeCases() {
        System.assertEquals('test@example.com', TypeCoercionService.coerceToEmailString('test@example.com', 'Email'), 'Valid email should pass');
        System.assertEquals('user+tag@domain.co.uk', TypeCoercionService.coerceToEmailString('user+tag@domain.co.uk', 'Email'), 'Complex email should pass');

        Boolean threw = false;
        try {
            TypeCoercionService.coerceToEmailString('no-at-sign.com', 'Email');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Email without @ should throw');

        threw = false;
        try {
            TypeCoercionService.coerceToEmailString('@domain.com', 'Email');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Email without local part should throw');

        threw = false;
        try {
            TypeCoercionService.coerceToEmailString('user@', 'Email');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Email without domain should throw');

        threw = false;
        try {
            TypeCoercionService.coerceToEmailString('user@domain', 'Email');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Email without domain extension should throw');
    }

    @IsTest
    static void testCoerceToUrlString_EdgeCases() {
        System.assertEquals('http://example.com', TypeCoercionService.coerceToUrlString('http://example.com', 'Website'), 'HTTP URL should pass');
        System.assertEquals('https://example.com', TypeCoercionService.coerceToUrlString('https://example.com', 'Website'), 'HTTPS URL should pass');
        System.assertEquals('HTTPS://EXAMPLE.COM', TypeCoercionService.coerceToUrlString('HTTPS://EXAMPLE.COM', 'Website'), 'Uppercase HTTPS should pass');

        Boolean threw = false;
        try {
            TypeCoercionService.coerceToUrlString('example.com', 'Website');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'URL without protocol should throw');

        threw = false;
        try {
            TypeCoercionService.coerceToUrlString('ftp://example.com', 'Website');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'FTP URL should throw');
    }

    // ========================================
    // DisplayType Coerce Tests
    // ========================================

    @IsTest
    static void testCoerce_AllDisplayTypes_Coverage() {
        System.assertEquals('test', TypeCoercionService.coerce('test', Schema.DisplayType.STRING, 'Field'), 'STRING type');
        System.assertEquals('test', TypeCoercionService.coerce('test', Schema.DisplayType.TEXTAREA, 'Field'), 'TEXTAREA type');
        System.assertEquals('test', TypeCoercionService.coerce('test', Schema.DisplayType.ENCRYPTEDSTRING, 'Field'), 'ENCRYPTEDSTRING type');
        System.assertEquals('test', TypeCoercionService.coerce('test', Schema.DisplayType.EMAIL, 'Field'), 'EMAIL type');
        System.assertEquals('test', TypeCoercionService.coerce('test', Schema.DisplayType.PHONE, 'Field'), 'PHONE type');
        System.assertEquals('test', TypeCoercionService.coerce('test', Schema.DisplayType.URL, 'Field'), 'URL type');
        System.assertEquals(123, TypeCoercionService.coerce(123, Schema.DisplayType.INTEGER, 'Field'), 'INTEGER type');
        System.assertEquals(123.45, TypeCoercionService.coerce(123.45, Schema.DisplayType.DOUBLE, 'Field'), 'DOUBLE type');
        System.assertEquals(123.45, TypeCoercionService.coerce(123.45, Schema.DisplayType.CURRENCY, 'Field'), 'CURRENCY type');
        System.assertEquals(123.45, TypeCoercionService.coerce(123.45, Schema.DisplayType.PERCENT, 'Field'), 'PERCENT type');
        System.assertEquals(true, TypeCoercionService.coerce(true, Schema.DisplayType.BOOLEAN, 'Field'), 'BOOLEAN type');

        Date testDate = Date.today();
        System.assertEquals(testDate, TypeCoercionService.coerce(testDate, Schema.DisplayType.DATE, 'Field'), 'DATE type');

        DateTime testDateTime = DateTime.now();
        System.assertEquals(testDateTime, TypeCoercionService.coerce(testDateTime, Schema.DisplayType.DATETIME, 'Field'), 'DATETIME type');

        Time testTime = Time.newInstance(12, 0, 0, 0);
        System.assertEquals(testTime, TypeCoercionService.coerce(testTime, Schema.DisplayType.TIME, 'Field'), 'TIME type');

        Account acc = new Account(Name = 'Test');
        insert acc;
        System.assertEquals(acc.Id, TypeCoercionService.coerce(acc.Id, Schema.DisplayType.ID, 'Field'), 'ID type');
        System.assertEquals(acc.Id, TypeCoercionService.coerce(acc.Id, Schema.DisplayType.REFERENCE, 'Field'), 'REFERENCE type');

        Blob testBlob = Blob.valueOf('test');
        System.assertEquals(testBlob, TypeCoercionService.coerce(testBlob, Schema.DisplayType.BASE64, 'Field'), 'BASE64 type');
    }

    @IsTest
    static void testCoerce_UnsupportedType_ReturnsValue() {
        Object result = TypeCoercionService.coerce('value', Schema.DisplayType.ADDRESS, 'Field');
        System.assertEquals('value', result, 'Unsupported type should return original value');
    }

    @IsTest
    static void testCoerce_UnexpectedException_WrapsInTypeCoercionException() {
        // Force an unexpected exception by passing incompatible value
        Boolean threw = false;
        try {
            TypeCoercionService.coerce(new List<String>(), Schema.DisplayType.INTEGER, 'Field');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
            // The service correctly throws TypeCoercionException for incompatible types
            System.assert(
                e.getMessage().contains('Cannot coerce to Integer') || e.getMessage().contains('Unexpected error'),
                'Should throw TypeCoercionException for incompatible type'
            );
        }
        System.assertEquals(true, threw, 'Incompatible type should throw TypeCoercionException');
    }

    // ========================================
    // Edge Cases and Boundary Tests
    // ========================================

    @IsTest
    static void testCoerceBooleanAndDateTime() {
        System.assertEquals(true, TypeCoercionService.coerceToBoolean('yes', 'IsActive__c'), 'Yes should coerce to true');
        System.assertEquals(false, TypeCoercionService.coerceToBoolean('0', 'IsActive__c'), '0 should coerce to false');
        System.assertEquals(true, TypeCoercionService.coerceToBoolean(2, 'IsActive__c'), 'Non-zero numeric should coerce to true');

        DateTime dt = TypeCoercionService.coerceToDateTime('2024-03-15T14:30:00Z', 'StartDateTime__c');
        System.assertEquals(Date.newInstance(2024, 3, 15), dt.date(), 'ISO-8601 DateTime should parse');
    }

    @IsTest
    static void testCoercePicklist_InvalidValue_Throws() {
        Schema.DescribeFieldResult dfr = Case.Origin.getDescribe();
        Boolean threw = false;
        try {
            TypeCoercionService.coerce('NotARealPicklistValue', Schema.DisplayType.PICKLIST, 'Origin', dfr);
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Invalid picklist value should throw TypeCoercionException');
    }

    @IsTest
    static void testCoerceString_EnforcesMaxLength() {
        Schema.DescribeFieldResult dfr = Account.Name.getDescribe();
        Integer maxLength = dfr.getLength();
        List<String> parts = new List<String>();
        for (Integer i = 0; i < maxLength + 1; i++) {
            parts.add('A');
        }
        String longValue = String.join(parts, '');

        Boolean threw = false;
        try {
            TypeCoercionService.coerceToString(longValue, 'Name', dfr);
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'String exceeding max length should throw TypeCoercionException');
    }

    @IsTest
    static void testCoerceInteger_RangeAndFraction() {
        System.assertEquals(10, TypeCoercionService.coerceToInteger('10', 'Count__c'), 'String integer should coerce');

        Boolean threw = false;
        try {
            TypeCoercionService.coerceToInteger(12.5, 'Count__c');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Fractional decimal should not coerce to Integer');

        threw = false;
        try {
            TypeCoercionService.coerceToInteger('2147483648', 'Count__c');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Out-of-range integer should throw');
    }

    @IsTest
    static void testCoerceDateAndTime_InvalidFormats() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToDate('2024-13-01', 'StartDate__c');
            System.assert(false, 'Expected invalid date to throw');
        } catch (Exception e) {
            threw = true;
            System.assert(e instanceof TypeCoercionService.TypeCoercionException, 'Should throw TypeCoercionException');
        }
        System.assertEquals(true, threw, 'Invalid date format should throw');

        threw = false;
        try {
            TypeCoercionService.coerceToTime('aa:bb', 'StartTime__c');
            System.assert(false, 'Expected invalid time to throw');
        } catch (Exception e) {
            threw = true;
            System.assert(e instanceof TypeCoercionService.TypeCoercionException, 'Should throw TypeCoercionException');
        }
        System.assertEquals(true, threw, 'Invalid time should throw');
    }

    @IsTest
    static void testCoerceIdAndBlob_InvalidValues() {
        Boolean threw = false;
        try {
            TypeCoercionService.coerceToId('not-an-id', 'AccountId');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Invalid ID should throw');

        threw = false;
        try {
            TypeCoercionService.coerceToBlob('not-base64', 'Body');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Invalid base64 should throw');
    }

    @IsTest
    static void testCoerceEmailAndUrl() {
        System.assertEquals('user@example.com', TypeCoercionService.coerceToEmailString('user@example.com', 'Email'), 'Valid email should pass');
        System.assertEquals('https://example.com', TypeCoercionService.coerceToUrlString('https://example.com', 'Website'), 'Valid URL should pass');

        Boolean threw = false;
        try {
            TypeCoercionService.coerceToEmailString('invalid-email', 'Email');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Invalid email should throw');

        threw = false;
        try {
            TypeCoercionService.coerceToUrlString('ftp://example.com', 'Website');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Invalid URL should throw');
    }

    @IsTest
    static void testCoerceDecimalAndDateTime_Invalid() {
        System.assertEquals(12.5, TypeCoercionService.coerceToDecimal('12.5', 'Amount__c'), 'String decimal should coerce');

        Boolean threw = false;
        try {
            TypeCoercionService.coerceToDateTime('not-a-datetime', 'StartDateTime__c');
        } catch (TypeCoercionService.TypeCoercionException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Invalid datetime should throw');
    }
}
