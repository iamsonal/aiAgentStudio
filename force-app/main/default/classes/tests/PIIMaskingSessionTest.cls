/**
 * @description Focused tests for PIIMaskingSession tokenization and statistics
 */
@IsTest
private class PIIMaskingSessionTest {
    @IsTest
    static void testTokenizationAndResolution() {
        PIIMaskingSession session = new PIIMaskingSession();

        String token1 = session.getOrCreateToken('123-45-6789', 'SSN');
        String token2 = session.getOrCreateToken('123-45-6789', 'SSN');
        String token3 = session.getOrCreateToken('123-45-6789', 'EmployeeId');

        System.assertEquals(token1, token2, 'Same value and pattern should reuse token');
        System.assertNotEquals(token1, token3, 'Different pattern should create a new token');
        System.assertEquals('123-45-6789', session.resolveToken(token1), 'Token should resolve to original value');
        System.assertEquals('unknown', session.resolveToken('unknown'), 'Unknown token should return input');
    }

    @IsTest
    static void testLookupAndStatisticsAndClear() {
        PIIMaskingSession session = new PIIMaskingSession();
        System.assertEquals(null, session.getExistingToken('555-00-1234', 'SSN'), 'No token before masking');
        System.assertEquals(false, session.hasTokenForValue('555-00-1234', 'SSN'), 'No token before masking');

        String token = session.getOrCreateToken('555-00-1234', 'SSN');
        System.assertEquals(true, session.isKnownToken(token), 'Token should be known');
        System.assertEquals(true, session.hasTokenForValue('555-00-1234', 'SSN'), 'Token should be tracked');
        System.assertEquals(token, session.getExistingToken('555-00-1234', 'SSN'), 'Should return existing token');

        Map<String, Object> stats = session.getStatistics();
        System.assertEquals(1, (Integer) stats.get('uniqueValuesmasked'), 'Unique masked count should be 1');
        System.assertEquals(1, (Integer) stats.get('totalMaskingOperations'), 'Masking ops should be 1');
        System.assertEquals(0, (Integer) stats.get('totalUnmaskingOperations'), 'Unmasking ops should be 0');

        session.resolveToken(token);
        stats = session.getStatistics();
        System.assertEquals(1, (Integer) stats.get('totalUnmaskingOperations'), 'Unmasking ops should increment');

        session.clear();
        System.assertEquals(0, session.getUniqueMaskedCount(), 'Clear should reset masked count');
        System.assertEquals(false, session.isKnownToken(token), 'Cleared session should not know token');
    }
}
