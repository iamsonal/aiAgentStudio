/**
 * @description Focused tests for PIIPatternMatcher validation and safeguards
 */
@IsTest
private class PIIPatternMatcherTest {
    @IsTest
    static void testFindMatches_ValidCreditCard_PassesLuhn() {
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher matcher = new PIIPatternMatcher(new Set<String>{ 'Financial' });

        List<PIIPatternMatcher.PIIMatch> matches = matcher.findMatches('Card: 4111 1111 1111 1111');
        System.assert(matches.size() > 0, 'Valid credit card should match');
        System.assertEquals('CreditCard', matches[0].patternName, 'Should match credit card pattern');
    }

    @IsTest
    static void testFindMatches_InvalidCreditCard_FailsLuhn() {
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher matcher = new PIIPatternMatcher(new Set<String>{ 'Financial' });

        List<PIIPatternMatcher.PIIMatch> matches = matcher.findMatches('Card: 4111 1111 1111 1112');
        System.assertEquals(0, matches.size(), 'Invalid credit card should not match');
    }

    @IsTest
    static void testFindMatches_NullBlankText_ReturnsEmpty() {
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher matcher = new PIIPatternMatcher();

        List<PIIPatternMatcher.PIIMatch> nullResult = matcher.findMatches(null);
        System.assertEquals(0, nullResult.size(), 'Null text should return empty matches');

        List<PIIPatternMatcher.PIIMatch> blankResult = matcher.findMatches('');
        System.assertEquals(0, blankResult.size(), 'Blank text should return empty matches');
    }

    @IsTest
    static void testContainsPII_SafeText_ReturnsFalse() {
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher matcher = new PIIPatternMatcher();

        System.assertEquals(false, matcher.containsPII('Hello world'), 'Safe text should not contain PII');
        System.assertEquals(false, matcher.containsPII(''), 'Blank text should not contain PII');
        System.assertEquals(false, matcher.containsPII(null), 'Null should not contain PII');
    }

    @IsTest
    static void testConstructor_NullCategories_AllEnabled() {
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher matcher = new PIIPatternMatcher(null);

        System.assertEquals(null, matcher.getEnabledCategories(), 'Null categories should mean all enabled');
    }

    @IsTest
    static void testValidateLuhn_EdgeCases() {
        System.assertEquals(true, PIIPatternMatcher.validateLuhn('4111111111111111'), 'Valid Visa should pass Luhn');
        System.assertEquals(false, PIIPatternMatcher.validateLuhn('4111111111111112'), 'Invalid card should fail Luhn');
        System.assertEquals(false, PIIPatternMatcher.validateLuhn('123'), 'Too short should fail Luhn');
        System.assertEquals(false, PIIPatternMatcher.validateLuhn(''), 'Blank should fail Luhn');
        System.assertEquals(false, PIIPatternMatcher.validateLuhn(null), 'Null should fail Luhn');
    }

    @IsTest
    static void testGetPatternCount_ReturnsNonNegative() {
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher matcher = new PIIPatternMatcher();

        System.assert(matcher.getPatternCount() >= 0, 'Pattern count should be non-negative');
    }

    @IsTest
    static void testSetMaxTextLength_AndGetMaxTextLength() {
        Integer original = PIIPatternMatcher.getMaxTextLength();

        PIIPatternMatcher.setMaxTextLength(100);
        System.assertEquals(100, PIIPatternMatcher.getMaxTextLength(), 'Max text length should be updated');

        PIIPatternMatcher.setMaxTextLength(original);
    }

    @IsTest
    static void testFindMatches_SkipsWhenTextTooLong() {
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher.setMaxTextLength(10);
        PIIPatternMatcher matcher = new PIIPatternMatcher(new Set<String>{ 'Identity' });

        List<PIIPatternMatcher.PIIMatch> matches = matcher.findMatches('My SSN is 123-45-6789');
        System.assertEquals(0, matches.size(), 'Should skip pattern matching for oversized text');

        PIIPatternMatcher.setMaxTextLength(50000);
    }

    @IsTest
    static void testFindMatches_PhoneUS_NoMatchInsideLongerNumber() {
        // The (?<!\d) lookbehind prevents Phone_US matching digit substrings inside longer numbers.
        PIIPatternMatcher.clearCache();
        PIIMaskingService service = new PIIMaskingService(PIIMaskingService.MODE_PATTERN_ONLY, new Set<String>{ 'Contact' }, null, null);

        String safeInput = 'Order 12125551234567 is ready';
        System.assertEquals(safeInput, service.maskText(safeInput), 'Digit substring inside a longer number must not be masked as a phone');

        String phoneInput = 'Call us at 212-555-1234 for help';
        System.assert(service.maskText(phoneInput).contains('[PHONE:'), 'Standalone US phone number must be masked');
    }

    @IsTest
    static void testFindMatches_IBAN_Detected() {
        PIIPatternMatcher.clearCache();
        PIIMaskingService service = new PIIMaskingService(PIIMaskingService.MODE_PATTERN_ONLY, new Set<String>{ 'Financial' }, null, null);

        String input = 'Transfer to IBAN GB29NWBK60161331926819 today';
        String masked = service.maskText(input);

        System.assert(masked.contains('[IBAN:'), 'IBAN should be detected and masked');
        System.assert(masked.contains('IBAN'), 'IBAN keyword must be preserved in masked text');
        System.assert(!masked.contains('GB29NWBK60161331926819'), 'IBAN value must not appear in masked text');
        System.assertEquals(input, service.unmaskText(masked), 'IBAN masking must round-trip correctly');
    }

    @IsTest
    static void testFindMatches_EIN_Detected() {
        PIIPatternMatcher.clearCache();
        PIIMaskingService service = new PIIMaskingService(PIIMaskingService.MODE_PATTERN_ONLY, new Set<String>{ 'Financial' }, null, null);

        String input = 'Company EIN 12-3456789 is on file';
        String masked = service.maskText(input);

        System.assert(masked.contains('[EIN:'), 'EIN must be detected and masked');
        System.assert(!masked.contains('12-3456789'), 'EIN value must not appear in masked text');
        System.assertEquals(input, service.unmaskText(masked), 'EIN masking must round-trip correctly');
    }

    @IsTest
    static void testFindMatches_NationalInsuranceUK_Detected() {
        PIIPatternMatcher.clearCache();
        PIIMaskingService service = new PIIMaskingService(PIIMaskingService.MODE_PATTERN_ONLY, new Set<String>{ 'Identity' }, null, null);

        String input = 'NINO AB123456C is registered on the account';
        String masked = service.maskText(input);

        System.assert(masked.contains('[NIN:'), 'UK NIN must be detected and masked');
        System.assert(!masked.contains('AB123456C'), 'NIN value must not appear in masked text');
        System.assertEquals(input, service.unmaskText(masked), 'NIN masking must round-trip correctly');
    }

    @IsTest
    static void testFindMatches_VIN_Detected() {
        PIIPatternMatcher.clearCache();
        PIIMaskingService service = new PIIMaskingService(PIIMaskingService.MODE_PATTERN_ONLY, new Set<String>{ 'Identity' }, null, null);

        // VIN uses ISO 3779 charset (excludes I, O, Q); 17 chars
        String input = 'VIN 1HGBH41JXMN109186 for the vehicle recall';
        String masked = service.maskText(input);

        System.assert(masked.contains('[VIN:'), 'VIN must be detected and masked');
        System.assert(!masked.contains('1HGBH41JXMN109186'), 'VIN value must not appear in masked text');
        System.assertEquals(input, service.unmaskText(masked), 'VIN masking must round-trip correctly');
    }

    // =========================================================================
    // IBAN_MOD97 Validator Tests
    // =========================================================================

    @IsTest
    static void testIban_ValidChecksum_Passes() {
        // GB29 NWBK 6016 1331 9268 19 — real UK IBAN with valid mod-97 checksum
        System.assertEquals(true, PIIPatternMatcher.validateIbanMod97('GB29NWBK60161331926819'), 'Valid IBAN checksum should pass');
        // DE89 3704 0044 0532 0130 00 — real German IBAN
        System.assertEquals(true, PIIPatternMatcher.validateIbanMod97('DE89370400440532013000'), 'Valid German IBAN should pass');
    }

    @IsTest
    static void testIban_InvalidChecksum_Blocked() {
        // Flip one digit to invalidate the checksum
        System.assertEquals(false, PIIPatternMatcher.validateIbanMod97('GB29NWBK60161331926820'), 'IBAN with wrong checksum should fail');
        System.assertEquals(false, PIIPatternMatcher.validateIbanMod97(''), 'Blank IBAN should fail');
        System.assertEquals(false, PIIPatternMatcher.validateIbanMod97(null), 'Null IBAN should fail');
        System.assertEquals(false, PIIPatternMatcher.validateIbanMod97('TOOSHORT'), 'Too-short IBAN should fail');
    }

    @IsTest
    static void testIban_SpacesAreStripped() {
        // IBAN with spaces should still validate correctly
        System.assertEquals(true, PIIPatternMatcher.validateIbanMod97('GB29 NWBK 6016 1331 9268 19'), 'IBAN with spaces should pass after stripping');
    }

    // =========================================================================
    // SSN_INVALID Validator Tests
    // =========================================================================

    @IsTest
    static void testSsn_ValidFormat_Passes() {
        System.assertEquals(true, PIIPatternMatcher.validateSsnNotInvalid('123-45-6780'), 'Valid-format SSN should pass');
        System.assertEquals(true, PIIPatternMatcher.validateSsnNotInvalid('301456789'), 'Valid SSN digits should pass');
    }

    @IsTest
    static void testSsn_KnownFake_Blocked() {
        // 078-05-1120 was in a Woolworth wallet display
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('078051120'), 'Known-fake SSN 078051120 should be blocked');
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('123456789'), 'Sequential SSN 123456789 should be blocked');
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('987654321'), 'Reverse sequential SSN should be blocked');
    }

    @IsTest
    static void testSsn_AllSameDigit_Blocked() {
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('111111111'), 'All-same-digit SSN should be blocked');
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('555555555'), 'All-same-digit SSN should be blocked');
    }

    @IsTest
    static void testSsn_ReservedArea_Blocked() {
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('000456789'), 'Area 000 SSN should be blocked');
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('666456789'), 'Area 666 SSN should be blocked');
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('900456789'), 'Area 9xx SSN should be blocked');
    }

    @IsTest
    static void testSsn_ReservedGroupOrSerial_Blocked() {
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('123001234'), 'Group 00 SSN should be blocked');
        System.assertEquals(false, PIIPatternMatcher.validateSsnNotInvalid('123450000'), 'Serial 0000 SSN should be blocked');
    }

    @IsTest
    static void testSsn_Plain_NoKeyword_NotMatched() {
        // The PIIPattern.SSN_Plain regex now requires a keyword anchor; without it the 9-digit
        // number should not be picked up by the SSN_Plain pattern.
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher matcher = new PIIPatternMatcher(new Set<String>{ 'Identity' });

        // 9 plain digits with no SSN keyword — SSN_Plain should not fire
        // (SSN_Dashed still won't fire because there are no dashes)
        List<PIIPatternMatcher.PIIMatch> matches = matcher.findMatches('Account 301456789 is overdue');
        Boolean hasSsnMatch = false;
        for (PIIPatternMatcher.PIIMatch m : matches) {
            if (m.patternName == 'SSN_Plain') {
                hasSsnMatch = true;
            }
        }
        System.assertEquals(false, hasSsnMatch, 'SSN_Plain should not fire without a keyword anchor');
    }

    @IsTest
    static void testSsn_Plain_WithKeyword_Matches() {
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher matcher = new PIIPatternMatcher(new Set<String>{ 'Identity' });

        List<PIIPatternMatcher.PIIMatch> matches = matcher.findMatches('SSN 301456789 is on file');
        Boolean hasSsnMatch = false;
        for (PIIPatternMatcher.PIIMatch m : matches) {
            if (m.patternName == 'SSN_Plain') {
                hasSsnMatch = true;
            }
        }
        System.assertEquals(true, hasSsnMatch, 'SSN_Plain should fire when SSN keyword is present');
    }

    // =========================================================================
    // ABA_CHECKSUM Validator Tests
    // =========================================================================

    @IsTest
    static void testAbaRouting_ValidChecksum_Passes() {
        // 021000021 — JPMorgan Chase, New York (public example, valid checksum)
        System.assertEquals(true, PIIPatternMatcher.validateAbaChecksum('021000021'), 'Valid ABA routing number should pass');
        // 111000025 — Federal Reserve Bank of Minneapolis
        System.assertEquals(true, PIIPatternMatcher.validateAbaChecksum('111000025'), 'Valid ABA routing number should pass');
    }

    @IsTest
    static void testAbaRouting_InvalidChecksum_Blocked() {
        // Flip last digit to break checksum
        System.assertEquals(false, PIIPatternMatcher.validateAbaChecksum('021000022'), 'ABA with wrong checksum should fail');
        System.assertEquals(false, PIIPatternMatcher.validateAbaChecksum(''), 'Blank routing number should fail');
        System.assertEquals(false, PIIPatternMatcher.validateAbaChecksum(null), 'Null routing number should fail');
    }

    @IsTest
    static void testAbaRouting_InvalidFirstDigit_Blocked() {
        // First digit 4 is not a valid Federal Reserve district prefix
        System.assertEquals(false, PIIPatternMatcher.validateAbaChecksum('421000021'), 'ABA with invalid first digit should fail');
        System.assertEquals(false, PIIPatternMatcher.validateAbaChecksum('521000021'), 'ABA with first digit 5 should fail');
    }

    @IsTest
    static void testValidateAbaChecksum_EdgeCases() {
        System.assertEquals(false, PIIPatternMatcher.validateAbaChecksum('12345678'), 'Wrong length should fail');
        System.assertEquals(false, PIIPatternMatcher.validateAbaChecksum('1234567890'), 'Wrong length should fail');
        // Test with spaces/dashes stripped
        System.assertEquals(true, PIIPatternMatcher.validateAbaChecksum('021-000-021'), 'Routing number with dashes should pass after stripping');
    }

    // =========================================================================
    // CreditCard Network Prefix Tests
    // =========================================================================

    @IsTest
    static void testCreditCard_ValidNetworkPrefix_Passes() {
        // Visa test number
        System.assertEquals(true, PIIPatternMatcher.validateLuhn('4111111111111111'), 'Visa test number should pass Luhn');
        // Mastercard test number
        System.assertEquals(true, PIIPatternMatcher.validateLuhn('5500005555555559'), 'Mastercard test number should pass Luhn');
        // Amex test number
        System.assertEquals(true, PIIPatternMatcher.validateLuhn('378282246310005'), 'Amex test number should pass Luhn');
    }

    @IsTest
    static void testCreditCard_NoNetworkPrefix_NotMatchedByRegex() {
        // A 16-digit number with no valid prefix should not be matched by the tightened CreditCard regex.
        // We test this at the pattern level directly.
        PIIPatternMatcher.clearCache();
        PIIPatternMatcher matcher = new PIIPatternMatcher(new Set<String>{ 'Financial' });

        // Starts with 9 — no known card network prefix
        List<PIIPatternMatcher.PIIMatch> matches = matcher.findMatches('Number 9111111111111111 on file');
        Boolean hasCcMatch = false;
        for (PIIPatternMatcher.PIIMatch m : matches) {
            if (m.patternName == 'CreditCard') {
                hasCcMatch = true;
            }
        }
        System.assertEquals(false, hasCcMatch, 'CC regex should not match numbers without a valid network prefix');
    }
}
