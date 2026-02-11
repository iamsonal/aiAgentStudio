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
}
