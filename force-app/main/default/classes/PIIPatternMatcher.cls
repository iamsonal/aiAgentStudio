/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Internal implementation class for PIIMaskingService. Detects PII in free text using regex
 * patterns defined in PIIPattern__mdt custom metadata, with optional algorithmic validation.
 *
 * *** DO NOT instantiate or reference this class directly from outside the PII subsystem.
 * All callers should go through PIIMaskingService, which is the sole public entry point. ***
 *
 * Supported ValidatorType__c values:
 *   LUHN         - Credit card Luhn checksum
 *   IBAN_MOD97   - IBAN ISO 13616 mod-97 checksum
 *   SSN_INVALID  - SSN invalid-set blocking (known fakes, reserved areas, all-same-digit)
 *   ABA_CHECKSUM - ABA routing number 3-7-1 weighted checksum
 *
 * The public static validator methods (validateLuhn, validateSsnNotInvalid, etc.) are exposed
 * for direct unit testing only. Production code must not call them outside this class.
 */
public inherited sharing class PIIPatternMatcher {
    // Cached patterns loaded from custom metadata
    private static List<PIIPattern__mdt> cachedPatterns;

    // Categories enabled for this matcher instance
    private Set<String> enabledCategories;

    // Compiled patterns for this instance (filtered by category)
    private List<CompiledPattern> compiledPatterns;

    // CPU safeguard: Maximum text length for pattern matching
    @TestVisible
    private static Integer MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING = 50000;

    // Known invalid SSNs (historically used in advertisements / test data)
    private static final Set<String> KNOWN_INVALID_SSNS = new Set<String>{
        '078051120', // Woolworth wallet insert SSN
        '123456789',
        '987654321',
        '219099999',
        '457555462'
    };

    // Valid first digits for ABA routing numbers (Federal Reserve districts)
    private static final Set<String> ABA_VALID_FIRST_DIGITS = new Set<String>{ '0', '1', '2', '3', '6', '7', '8' };

    /**
     * @description Represents a detected PII match in text.
     */
    public class PIIMatch {
        public String matchedValue { get; set; }
        public String patternName { get; set; }
        public String maskFormat { get; set; }
        public String category { get; set; }
        public Integer startIndex { get; set; }
        public Integer endIndex { get; set; }

        public PIIMatch(String value, String name, String format, String cat, Integer start, Integer endIdx) {
            this.matchedValue = value;
            this.patternName = name;
            this.maskFormat = format;
            this.category = cat;
            this.startIndex = start;
            this.endIndex = endIdx;
        }
    }

    /**
     * @description Internal class to hold compiled pattern data.
     */
    private class CompiledPattern {
        public String developerName;
        public System.Pattern regex;
        public String maskFormat;
        public String category;
        public Integer priority;
        public Boolean requiresValidation;
        public String validatorType;
    }

    /**
     * @description Creates a matcher with all active patterns enabled.
     */
    public PIIPatternMatcher() {
        this(null);
    }

    /**
     * @description Creates a matcher with specific categories enabled.
     * @param categories Set of category names to enable. Pass null to enable all.
     */
    public PIIPatternMatcher(Set<String> categories) {
        this.enabledCategories = categories;
        loadAndCompilePatterns();
    }

    /**
     * @description Finds all PII matches in the given text.
     */
    public List<PIIMatch> findMatches(String text) {
        List<PIIMatch> allMatches = new List<PIIMatch>();

        if (String.isBlank(text) || this.compiledPatterns.isEmpty()) {
            return allMatches;
        }

        if (MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING > 0 && text.length() > MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING) {
            System.debug(
                LoggingLevel.WARN,
                '[PIIPatternMatcher] Text exceeds max length for pattern matching (' +
                    text.length() +
                    ' > ' +
                    MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING +
                    ' chars). Skipping pattern-based PII detection to avoid CPU limits.'
            );
            return allMatches;
        }

        for (CompiledPattern cp : this.compiledPatterns) {
            System.Matcher m = cp.regex.matcher(text);

            while (m.find()) {
                String matchedValue;
                Integer matchStart;
                Integer matchEnd;
                if (m.groupCount() > 0 && m.group(1) != null) {
                    matchedValue = m.group(1);
                    matchStart = m.start(1);
                    matchEnd = m.end(1);
                } else {
                    matchedValue = m.group(0);
                    matchStart = m.start(0);
                    matchEnd = m.end(0);
                }

                if (cp.requiresValidation && !runValidator(matchedValue, cp.validatorType)) {
                    continue;
                }

                allMatches.add(new PIIMatch(matchedValue, cp.developerName, cp.maskFormat, cp.category, matchStart, matchEnd));
            }
        }

        return allMatches;
    }

    /**
     * @description Checks if text contains any PII patterns.
     */
    public Boolean containsPII(String text) {
        if (String.isBlank(text) || this.compiledPatterns.isEmpty()) {
            return false;
        }

        if (MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING > 0 && text.length() > MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING) {
            System.debug(LoggingLevel.WARN, '[PIIPatternMatcher] Text exceeds max length (' + text.length() + ' chars). Skipping containsPII check.');
            return false;
        }

        for (CompiledPattern cp : this.compiledPatterns) {
            System.Matcher m = cp.regex.matcher(text);
            while (m.find()) {
                if (cp.requiresValidation) {
                    String val = (m.groupCount() > 0 && m.group(1) != null) ? m.group(1) : m.group(0);
                    if (runValidator(val, cp.validatorType)) {
                        return true;
                    }
                } else {
                    return true;
                }
            }
        }

        return false;
    }

    public Set<String> getEnabledCategories() {
        return this.enabledCategories;
    }

    public Integer getPatternCount() {
        return this.compiledPatterns != null ? this.compiledPatterns.size() : 0;
    }

    @TestVisible
    public static void clearCache() {
        cachedPatterns = null;
    }

    @TestVisible
    public static void setMaxTextLength(Integer maxLength) {
        MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING = maxLength != null ? maxLength : 50000;
    }

    public static Integer getMaxTextLength() {
        return MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING;
    }

    // =========================================================================
    // PATTERN LOADING
    // =========================================================================

    private void loadAndCompilePatterns() {
        this.compiledPatterns = new List<CompiledPattern>();

        if (cachedPatterns == null) {
            cachedPatterns = [
                SELECT
                    DeveloperName,
                    MasterLabel,
                    PatternRegex__c,
                    MaskFormat__c,
                    Category__c,
                    Priority__c,
                    IsActive__c,
                    RequiresValidation__c,
                    ValidatorType__c
                FROM PIIPattern__mdt
                WHERE IsActive__c = TRUE
                ORDER BY Priority__c ASC
            ];
        }

        for (PIIPattern__mdt pattern : cachedPatterns) {
            if (this.enabledCategories != null && !this.enabledCategories.isEmpty() && !this.enabledCategories.contains(pattern.Category__c)) {
                continue;
            }

            try {
                CompiledPattern cp = new CompiledPattern();
                cp.developerName = pattern.DeveloperName;
                cp.regex = System.Pattern.compile(pattern.PatternRegex__c);
                cp.maskFormat = pattern.MaskFormat__c;
                cp.category = pattern.Category__c;
                cp.priority = pattern.Priority__c != null ? Integer.valueOf(pattern.Priority__c) : 100;
                cp.requiresValidation = pattern.RequiresValidation__c == true;
                cp.validatorType = pattern.ValidatorType__c;
                this.compiledPatterns.add(cp);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[PIIPatternMatcher] Failed to compile pattern "' + pattern.DeveloperName + '": ' + e.getMessage());
            }
        }

        System.debug(LoggingLevel.DEBUG, '[PIIPatternMatcher] Loaded ' + this.compiledPatterns.size() + ' patterns');
    }

    // =========================================================================
    // VALIDATOR DISPATCH
    // =========================================================================

    /**
     * @description Dispatches to the appropriate algorithmic validator based on ValidatorType__c.
     * Returns true if the value is valid (should be masked), false if it should be rejected.
     * Unknown validator types pass through as valid.
     */
    private Boolean runValidator(String value, String validatorType) {
        if (String.isBlank(validatorType)) {
            return true;
        }
        switch on validatorType {
            when 'LUHN' {
                return validateLuhn(value);
            }
            when 'IBAN_MOD97' {
                return validateIbanMod97(value);
            }
            when 'SSN_INVALID' {
                return validateSsnNotInvalid(value);
            }
            when 'ABA_CHECKSUM' {
                return validateAbaChecksum(value);
            }
            when else {
                return true;
            }
        }
    }

    // =========================================================================
    // VALIDATORS
    // =========================================================================

    /**
     * @description Validates a credit card number using the Luhn algorithm.
     */
    @TestVisible
    public static Boolean validateLuhn(String numberStr) {
        if (String.isBlank(numberStr)) {
            return false;
        }

        String digits = numberStr.replaceAll('[^0-9]', '');

        if (digits.length() < 13 || digits.length() > 19) {
            return false;
        }

        Integer sum = 0;
        Boolean alternate = false;

        for (Integer i = digits.length() - 1; i >= 0; i--) {
            Integer digit = Integer.valueOf(digits.substring(i, i + 1));
            if (alternate) {
                digit *= 2;
                if (digit > 9) {
                    digit -= 9;
                }
            }
            sum += digit;
            alternate = !alternate;
        }

        return Math.mod(sum, 10) == 0;
    }

    /**
     * @description Validates an IBAN using the ISO 13616 mod-97 checksum algorithm.
     * Processes digit-by-digit to avoid integer overflow (Apex has no BigInteger).
     */
    @TestVisible
    public static Boolean validateIbanMod97(String iban) {
        if (String.isBlank(iban)) {
            return false;
        }

        // Strip spaces and uppercase
        String cleaned = iban.replaceAll('\\s', '').toUpperCase();

        // Minimum IBAN length is 15 (Norway), maximum is 34
        if (cleaned.length() < 15 || cleaned.length() > 34) {
            return false;
        }

        // Move first 4 chars to end: e.g. GB29NWBK... → NWBK...GB29
        String rearranged = cleaned.substring(4) + cleaned.substring(0, 4);

        // Convert letters to digits: A=10, B=11, ... Z=35
        String numericString = '';
        for (Integer i = 0; i < rearranged.length(); i++) {
            String ch = rearranged.substring(i, i + 1);
            Integer code = ch.charAt(0);
            if (code >= 65 && code <= 90) {
                // A=65 → 10, so offset = code - 55
                numericString += String.valueOf(code - 55);
            } else {
                numericString += ch;
            }
        }

        // Compute mod 97 using running remainder to avoid overflow
        Integer remainder = 0;
        for (Integer i = 0; i < numericString.length(); i++) {
            Integer digit = Integer.valueOf(numericString.substring(i, i + 1));
            remainder = Math.mod(remainder * 10 + digit, 97);
        }

        return remainder == 1;
    }

    /**
     * @description Validates that an SSN is not in the known-invalid set.
     * Returns true if the SSN is structurally plausible (should be masked),
     * false if it is a known fake, reserved, or degenerate value.
     * Mirrors Presidio's UsSsnRecognizer.invalidate_result logic.
     */
    @TestVisible
    public static Boolean validateSsnNotInvalid(String ssn) {
        if (String.isBlank(ssn)) {
            return false;
        }

        String digits = ssn.replaceAll('[^0-9]', '');
        if (digits.length() != 9) {
            return false;
        }

        String area = digits.substring(0, 3);
        String grp = digits.substring(3, 5);
        String serial = digits.substring(5, 9);

        // Block reserved areas
        if (area == '000' || area == '666') {
            return false;
        }
        // Block 900-999 (ITINs start with 9 — handled by separate pattern)
        if (area.substring(0, 1) == '9') {
            return false;
        }

        // Block reserved group and serial values
        if (grp == '00' || serial == '0000') {
            return false;
        }

        // Block all-same-digit sequences (e.g. 111111111, 222222222)
        Boolean allSame = true;
        for (Integer i = 1; i < 9; i++) {
            if (digits.substring(i, i + 1) != digits.substring(0, 1)) {
                allSame = false;
                break;
            }
        }
        if (allSame) {
            return false;
        }

        // Block known invalid SSNs used in advertisements and test data
        if (KNOWN_INVALID_SSNS.contains(digits)) {
            return false;
        }

        return true;
    }

    /**
     * @description Validates a US ABA routing number using the standard 3-7-1 weighted checksum.
     * The weighted sum 3*d0 + 7*d1 + d2 + 3*d3 + 7*d4 + d5 + 3*d6 + 7*d7 + d8 must be
     * divisible by 10. Also validates the first digit is a legal Federal Reserve prefix.
     */
    @TestVisible
    public static Boolean validateAbaChecksum(String routing) {
        if (String.isBlank(routing)) {
            return false;
        }

        String digits = routing.replaceAll('[^0-9]', '');
        if (digits.length() != 9) {
            return false;
        }

        // First digit must be a valid Federal Reserve district prefix
        if (!ABA_VALID_FIRST_DIGITS.contains(digits.substring(0, 1))) {
            return false;
        }

        // 3-7-1 weighted checksum
        Integer[] weights = new List<Integer>{ 3, 7, 1, 3, 7, 1, 3, 7, 1 };
        Integer sum = 0;
        for (Integer i = 0; i < 9; i++) {
            sum += Integer.valueOf(digits.substring(i, i + 1)) * weights[i];
        }

        return Math.mod(sum, 10) == 0;
    }
}
