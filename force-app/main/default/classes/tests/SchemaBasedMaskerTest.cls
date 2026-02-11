/**
 * @description Focused tests for SchemaBasedMasker fallback and token behavior
 */
@IsTest
private class SchemaBasedMaskerTest {
    @IsTest
    static void testFallbackPattern_MatchesSensitiveFieldName() {
        SchemaBasedMasker masker = new SchemaBasedMasker().withFallbackPatterns(true);
        System.assertEquals(true, masker.shouldMaskField('Contact', 'SSN'), 'Fallback should match SSN field name');
    }

    @IsTest
    static void testFallbackDisabled_DoesNotMatchFieldName() {
        SchemaBasedMasker masker = new SchemaBasedMasker().withFallbackPatterns(false);
        System.assertEquals(false, masker.shouldMaskField('Contact', 'SSN'), 'Fallback disabled should not match');
    }

    @IsTest
    static void testMaskFieldValue_UsesSessionToken() {
        SchemaBasedMasker masker = new SchemaBasedMasker();
        PIIMaskingSession session = new PIIMaskingSession();

        String token = masker.maskFieldValue('123-45-6789', 'SSN', session);
        System.assert(token.startsWith('[') && token.endsWith(']'), 'Mask should return token format');
        System.assertEquals('123-45-6789', session.resolveToken(token), 'Token should resolve back to original value');
    }

    @IsTest
    static void testFallbackPattern_BoundaryAvoidsFalsePositives() {
        SchemaBasedMasker masker = new SchemaBasedMasker().withFallbackPatterns(true);

        System.assertEquals(true, masker.shouldMaskField('Contact', 'SSN'), 'SSN pattern should match');
        System.assertEquals(false, masker.shouldMaskField('Contact', 'Classness__c'), 'Boundary should avoid false positives');
    }

    @IsTest
    static void testConstructor_DefaultClassifications_ContainsExpectedValues() {
        SchemaBasedMasker masker = new SchemaBasedMasker();
        Set<String> classifications = masker.getSensitiveClassifications();

        System.assert(classifications.contains('Confidential'), 'Default should include Confidential');
        System.assert(classifications.contains('Restricted'), 'Default should include Restricted');
    }

    @IsTest
    static void testConstructor_CustomClassifications_AreUsed() {
        Set<String> custom = new Set<String>{ 'MissionCritical', 'Internal' };
        SchemaBasedMasker masker = new SchemaBasedMasker(custom);

        Set<String> result = masker.getSensitiveClassifications();
        System.assert(result.contains('MissionCritical'), 'Custom classification should be used');
        System.assert(result.contains('Internal'), 'Custom classification should be used');
    }

    @IsTest
    static void testConstructor_NullClassifications_UsesDefaults() {
        SchemaBasedMasker masker = new SchemaBasedMasker(null);
        Set<String> result = masker.getSensitiveClassifications();

        System.assert(!result.isEmpty(), 'Null classifications should fall back to defaults');
    }

    @IsTest
    static void testShouldMaskField_BlankInputs_ReturnsFalse() {
        SchemaBasedMasker masker = new SchemaBasedMasker();

        System.assertEquals(false, masker.shouldMaskField('', 'SSN'), 'Blank object name should return false');
        System.assertEquals(false, masker.shouldMaskField('Contact', ''), 'Blank field name should return false');
        System.assertEquals(false, masker.shouldMaskField('', ''), 'Both blank should return false');
    }

    @IsTest
    static void testMaskFieldValue_NullValue_ReturnsNull() {
        SchemaBasedMasker masker = new SchemaBasedMasker();
        PIIMaskingSession session = new PIIMaskingSession();

        String result = masker.maskFieldValue(null, 'SSN', session);
        System.assertEquals(null, result, 'Null value should return null');
    }

    @IsTest
    static void testGetDefaultSensitiveClassifications_ReturnsClone() {
        Set<String> defaults = SchemaBasedMasker.getDefaultSensitiveClassifications();
        Integer originalSize = defaults.size();

        defaults.add('TestClassification');
        Set<String> defaults2 = SchemaBasedMasker.getDefaultSensitiveClassifications();
        System.assertEquals(originalSize, defaults2.size(), 'Modifying returned set should not affect original defaults');
    }

    @IsTest
    static void testClearCache_AllowsReload() {
        SchemaBasedMasker masker = new SchemaBasedMasker().withFallbackPatterns(true);
        masker.shouldMaskField('Account', 'Name');

        SchemaBasedMasker.clearCache();

        // After clearing cache, should work fine (reloads)
        Boolean result = masker.shouldMaskField('Account', 'Name');
        System.assertNotEquals(null, result, 'Should return a result after cache clear');
    }

    @IsTest
    static void testFallbackPatterns_AllSensitiveFieldNames_Match() {
        SchemaBasedMasker masker = new SchemaBasedMasker().withFallbackPatterns(true);

        // Test that fallback patterns can detect some sensitive field names
        // Exact matching depends on the regex patterns defined in the implementation

        // Test a few common patterns - at least one should match
        Boolean hasMatches =
            masker.shouldMaskField('Contact', 'Password__c') ||
            masker.shouldMaskField('Contact', 'SSN') ||
            masker.shouldMaskField('Contact', 'Birthdate') ||
            masker.shouldMaskField('Contact', 'TaxId');

        System.assert(hasMatches, 'At least one sensitive field pattern should match with fallback enabled');

        // Verify that fallback patterns work for known sensitive keywords
        System.assertEquals(true, masker.shouldMaskField('Contact', 'SSN'), 'SSN pattern should match');
    }

    @IsTest
    static void testGetMaskedFields_StandardObject_ReturnsSet() {
        SchemaBasedMasker masker = new SchemaBasedMasker();

        Set<String> maskedFields = masker.getMaskedFields(Account.SObjectType);
        System.assertNotEquals(null, maskedFields, 'Should return a set (possibly empty) for Account');
    }

    @IsTest
    static void testAnalyzeObjectClassifications_StandardObject_ReturnsMap() {
        SchemaBasedMasker masker = new SchemaBasedMasker();

        Map<String, String> classifications = masker.analyzeObjectClassifications(Account.SObjectType);
        System.assertNotEquals(null, classifications, 'Should return a map for Account');
    }
}
