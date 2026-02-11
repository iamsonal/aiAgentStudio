/**
 * @description Focused tests for PII masking behavior
 */
@IsTest
private class PIIMaskingServiceTest {
    @IsTest
    static void testMaskMessagePayload_MasksToolArguments() {
        PIIPatternMatcher.clearCache();

        PIIMaskingService service = new PIIMaskingService(PIIMaskingService.MODE_PATTERN_ONLY, new Set<String>{ 'Identity' }, null, null);

        List<Map<String, Object>> payload = new List<Map<String, Object>>{
            new Map<String, Object>{
                'role' => 'assistant',
                'tool_calls' => new List<Object>{
                    new Map<String, Object>{
                        'id' => 'call-1',
                        'type' => 'function',
                        'function' => new Map<String, Object>{ 'name' => 'do_something', 'arguments' => '{"ssn":"123-45-6789"}' }
                    }
                }
            }
        };

        List<Map<String, Object>> masked = service.maskMessagePayload(payload);
        Map<String, Object> maskedCall = (Map<String, Object>) ((List<Object>) masked[0].get('tool_calls'))[0];
        Map<String, Object> func = (Map<String, Object>) maskedCall.get('function');
        String maskedArgs = (String) func.get('arguments');

        System.assert(maskedArgs.contains('[SSN:'), 'Tool arguments should be masked in payload');
    }

    @IsTest
    static void testUnmaskText_AllowsDigitsInTokenPrefix() {
        PIIMaskingService service = new PIIMaskingService();
        PIIMaskingSession session = service.getSession();

        String token = session.getOrCreateToken('555-1212', 'FIELD_PHONE1__C');
        String unmasked = service.unmaskText('Contact: ' + token);

        System.assertEquals('Contact: 555-1212', unmasked, 'Token with digits in prefix should be unmasked');
    }

    @IsTest
    static void testMaskText_ReusesTokenForSameValue() {
        PIIPatternMatcher.clearCache();
        PIIMaskingService service = new PIIMaskingService(PIIMaskingService.MODE_PATTERN_ONLY, new Set<String>{ 'Identity' }, null, null);

        String input = 'SSN 123-45-6789 appears twice: 123-45-6789';
        String masked = service.maskText(input);

        Integer firstTokenStart = masked.indexOf('[');
        Integer firstTokenEnd = masked.indexOf(']');
        System.assert(firstTokenStart > -1 && firstTokenEnd > firstTokenStart, 'Masked text should include a token');
        String token = masked.substring(firstTokenStart, firstTokenEnd + 1);

        Integer occurrenceCount = 0;
        Integer searchIndex = 0;
        while (true) {
            Integer foundAt = masked.indexOf(token, searchIndex);
            if (foundAt < 0) {
                break;
            }
            occurrenceCount++;
            searchIndex = foundAt + token.length();
        }

        System.assertEquals(2, occurrenceCount, 'Same PII value should reuse the same token within a session');
    }

    @IsTest
    static void testMaskText_NestedJsonRoundTrip() {
        PIIPatternMatcher.clearCache();
        PIIMaskingService service = new PIIMaskingService(PIIMaskingService.MODE_PATTERN_ONLY, new Set<String>{ 'Identity' }, null, null);

        String input = '{"user":{"email":"jane.doe@example.com","ssn":"123-45-6789"},"contacts":[{"phone":"555-1212"}]}';
        String masked = service.maskText(input);
        System.assert(masked.contains('['), 'Masked JSON should include tokens');

        String unmasked = service.unmaskText(masked);
        System.assertEquals(input, unmasked, 'Masked JSON should round-trip back to original');
    }

    @IsTest
    static void testMaskText_NullBlankText_ReturnsOriginal() {
        PIIMaskingService service = new PIIMaskingService();

        System.assertEquals(null, service.maskText(null), 'Null text should return null');
        System.assertEquals('', service.maskText(''), 'Blank text should return blank');
    }

    @IsTest
    static void testUnmaskText_NoTokens_ReturnsOriginal() {
        PIIMaskingService service = new PIIMaskingService();

        String input = 'No tokens in this text';
        System.assertEquals(input, service.unmaskText(input), 'Text without tokens should return unchanged');
    }

    @IsTest
    static void testMaskMessagePayload_NullEmpty_ReturnsGracefully() {
        PIIMaskingService service = new PIIMaskingService();

        List<Map<String, Object>> nullResult = service.maskMessagePayload(null);
        System.assertEquals(null, nullResult, 'Null payload should return null as per implementation');

        List<Map<String, Object>> emptyResult = service.maskMessagePayload(new List<Map<String, Object>>());
        System.assertEquals(0, emptyResult.size(), 'Empty payload should return empty');
    }

    @IsTest
    static void testIsEnabled_DefaultConstructor_ReturnsExpectedState() {
        PIIMaskingService service = new PIIMaskingService();
        // Default constructor creates an enabled service in HYBRID mode
        System.assertNotEquals(null, service.getMode(), 'Mode should not be null');
        System.assertNotEquals(null, service.getSession(), 'Session should not be null');
    }

    @IsTest
    static void testCreateForAgent_NullAgent_ReturnsNull() {
        PIIMaskingService service = PIIMaskingService.createForAgent(null);
        System.assertEquals(null, service, 'Null agent should return null service');
    }

    @IsTest
    static void testGetStatistics_ReturnsNonNull() {
        PIIPatternMatcher.clearCache();
        PIIMaskingService service = new PIIMaskingService(PIIMaskingService.MODE_PATTERN_ONLY, new Set<String>{ 'Identity' }, null, null);

        service.maskText('My SSN is 123-45-6789');

        Map<String, Object> stats = service.getStatistics();
        System.assertNotEquals(null, stats, 'Statistics should not be null');
    }

    @IsTest
    static void testSession_DifferentPatternNamesUseDifferentTokens() {
        PIIMaskingSession session = new PIIMaskingSession();
        String ssnToken = session.getOrCreateToken('123-45-6789', 'SSN');
        String phoneToken = session.getOrCreateToken('123-45-6789', 'PHONE');

        System.assertNotEquals(ssnToken, phoneToken, 'Same value with different pattern names should get different tokens');
        System.assertEquals('123-45-6789', session.resolveToken(ssnToken), 'SSN token should resolve to original');
        System.assertEquals('123-45-6789', session.resolveToken(phoneToken), 'PHONE token should resolve to original');
    }
}
