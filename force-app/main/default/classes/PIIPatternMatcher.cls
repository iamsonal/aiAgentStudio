/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * PIIPatternMatcher detects Personally Identifiable Information (PII) in text using regex patterns
 * defined in PIIPattern__mdt custom metadata. Supports additional validation for specific patterns
 * like credit card numbers (Luhn algorithm).
 *
 * Key Features:
 * - Pattern-based detection using configurable regex patterns
 * - Priority ordering to handle overlapping patterns correctly
 * - Category filtering to enable/disable groups of patterns
 * - Luhn algorithm validation for credit card numbers
 * - Cached pattern loading for performance
 *
 * @example
 * PIIPatternMatcher matcher = new PIIPatternMatcher(new Set<String>{'Financial', 'Identity'});
 * List<PIIPatternMatcher.PIIMatch> matches = matcher.findMatches('My SSN is 123-45-6789');
 * // matches[0].matchedValue = '123-45-6789'
 * // matches[0].patternName = 'SSN_Dashed'
 * // matches[0].maskFormat = '[SSN:{index}]'
 */
public inherited sharing class PIIPatternMatcher {
    // Cached patterns loaded from custom metadata
    private static List<PIIPattern__mdt> cachedPatterns;

    // Categories enabled for this matcher instance
    private Set<String> enabledCategories;

    // Compiled patterns for this instance (filtered by category)
    private List<CompiledPattern> compiledPatterns;

    // CPU safeguard: Maximum text length for pattern matching
    // Regex matching against very large texts (e.g., 50KB email bodies) with multiple patterns
    // can consume excessive CPU time and risk hitting Apex governor limits.
    // Default: 50,000 characters (~50KB). Set to 0 to disable limit.
    @TestVisible
    private static Integer MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING = 50000;

    /**
     * @description Represents a detected PII match in text.
     */
    public class PIIMatch {
        public String matchedValue { get; set; } // The actual matched text
        public String patternName { get; set; } // Name of the pattern that matched
        public String maskFormat { get; set; } // Format string for the mask token
        public String category { get; set; } // Category of the pattern
        public Integer startIndex { get; set; } // Position in original text
        public Integer endIndex { get; set; } // End position in original text

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
    }

    /**
     * @description Creates a matcher with all active patterns enabled.
     */
    public PIIPatternMatcher() {
        this(null);
    }

    /**
     * @description Creates a matcher with specific categories enabled.
     * @param categories Set of category names to enable (e.g., {'Financial', 'Identity'})
     *                   Pass null or empty set to enable all categories.
     */
    public PIIPatternMatcher(Set<String> categories) {
        this.enabledCategories = categories;
        loadAndCompilePatterns();
    }

    /**
     * @description Finds all PII matches in the given text.
     * Returns matches sorted by position in text (for proper masking order).
     *
     * @param text The text to search for PII
     * @return List of PIIMatch objects representing found PII
     */
    public List<PIIMatch> findMatches(String text) {
        List<PIIMatch> allMatches = new List<PIIMatch>();

        if (String.isBlank(text) || this.compiledPatterns.isEmpty()) {
            return allMatches;
        }

        // CPU safeguard: Skip pattern matching for excessively large text
        // This prevents CPU timeout when processing large email bodies or documents
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

        // Apply each pattern in priority order
        for (CompiledPattern cp : this.compiledPatterns) {
            System.Matcher m = cp.regex.matcher(text);

            while (m.find()) {
                String matchedValue = m.group();

                // Skip if validation is required and fails
                if (cp.requiresValidation && !validateMatch(matchedValue, cp.developerName)) {
                    continue;
                }

                PIIMatch match = new PIIMatch(matchedValue, cp.developerName, cp.maskFormat, cp.category, m.start(), m.end());
                allMatches.add(match);
            }
        }

        // Sort by position (descending) for replacement from end to start
        allMatches.sort(new PIIMatchComparator());

        return allMatches;
    }

    /**
     * @description Checks if text contains any PII patterns.
     * More efficient than findMatches() when you only need a boolean result.
     *
     * @param text The text to check
     * @return True if any PII is detected
     */
    public Boolean containsPII(String text) {
        if (String.isBlank(text) || this.compiledPatterns.isEmpty()) {
            return false;
        }

        // CPU safeguard: Skip for excessively large text
        if (MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING > 0 && text.length() > MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING) {
            System.debug(LoggingLevel.WARN, '[PIIPatternMatcher] Text exceeds max length (' + text.length() + ' chars). Skipping containsPII check.');
            return false;
        }

        for (CompiledPattern cp : this.compiledPatterns) {
            System.Matcher m = cp.regex.matcher(text);
            while (m.find()) {
                // If validation is required, check it
                if (cp.requiresValidation) {
                    if (validateMatch(m.group(), cp.developerName)) {
                        return true;
                    }
                } else {
                    return true;
                }
            }
        }

        return false;
    }

    /**
     * @description Gets the categories enabled for this matcher.
     *
     * @return Set of enabled category names, or null if all are enabled
     */
    public Set<String> getEnabledCategories() {
        return this.enabledCategories;
    }

    /**
     * @description Gets the count of active patterns loaded.
     *
     * @return Number of compiled patterns
     */
    public Integer getPatternCount() {
        return this.compiledPatterns != null ? this.compiledPatterns.size() : 0;
    }

    /**
     * @description Clears the cached patterns to force reload on next instantiation.
     * Useful for testing or when metadata has been updated.
     */
    @TestVisible
    public static void clearCache() {
        cachedPatterns = null;
    }

    /**
     * @description Sets the maximum text length for pattern matching (CPU safeguard).
     * Set to 0 to disable the limit entirely.
     * Default is 50,000 characters (~50KB).
     *
     * @param maxLength Maximum text length in characters, or 0 to disable
     */
    @TestVisible
    public static void setMaxTextLength(Integer maxLength) {
        MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING = maxLength != null ? maxLength : 50000;
    }

    /**
     * @description Gets the current maximum text length for pattern matching.
     *
     * @return Current max length setting
     */
    public static Integer getMaxTextLength() {
        return MAX_TEXT_LENGTH_FOR_PATTERN_MATCHING;
    }

    // =========================================================================
    // PATTERN LOADING AND COMPILATION
    // =========================================================================

    /**
     * @description Loads patterns from custom metadata and compiles them.
     */
    private void loadAndCompilePatterns() {
        this.compiledPatterns = new List<CompiledPattern>();

        // Load from cache or query
        if (cachedPatterns == null) {
            cachedPatterns = [
                SELECT DeveloperName, MasterLabel, PatternRegex__c, MaskFormat__c, Category__c, Priority__c, IsActive__c, RequiresValidation__c
                FROM PIIPattern__mdt
                WHERE IsActive__c = TRUE
                ORDER BY Priority__c ASC
            ];
        }

        // Compile patterns, filtering by category
        for (PIIPattern__mdt pattern : cachedPatterns) {
            // Skip if category filtering is enabled and this category isn't included
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

                this.compiledPatterns.add(cp);
            } catch (Exception e) {
                // Log but don't fail - skip invalid patterns
                System.debug(LoggingLevel.ERROR, '[PIIPatternMatcher] Failed to compile pattern "' + pattern.DeveloperName + '": ' + e.getMessage());
            }
        }

        System.debug(LoggingLevel.DEBUG, '[PIIPatternMatcher] Loaded ' + this.compiledPatterns.size() + ' patterns');
    }

    // =========================================================================
    // VALIDATION METHODS
    // =========================================================================

    /**
     * @description Validates a match using pattern-specific validation logic.
     *
     * @param matchedValue The value to validate
     * @param patternName The pattern name to determine validation type
     * @return True if validation passes or is not applicable
     */
    private Boolean validateMatch(String matchedValue, String patternName) {
        if (String.isBlank(matchedValue)) {
            return false;
        }

        // Credit card patterns require Luhn validation
        if (patternName != null && patternName.toLowerCase().contains('credit')) {
            return validateLuhn(matchedValue);
        }

        // Add other validations here as needed
        return true;
    }

    /**
     * @description Validates a number using the Luhn algorithm (checksum for credit cards).
     * The Luhn algorithm is used to validate credit card numbers and other identification numbers.
     *
     * @param numberStr The number string to validate (can contain spaces/dashes)
     * @return True if the number passes Luhn validation
     */
    @TestVisible
    public static Boolean validateLuhn(String numberStr) {
        if (String.isBlank(numberStr)) {
            return false;
        }

        // Remove all non-digit characters
        String digits = numberStr.replaceAll('[^0-9]', '');

        // Must have at least 13 digits for a valid credit card
        if (digits.length() < 13 || digits.length() > 19) {
            return false;
        }

        Integer sum = 0;
        Boolean alternate = false;

        // Process from right to left
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

    // =========================================================================
    // COMPARATOR FOR SORTING MATCHES
    // =========================================================================

    /**
     * @description Comparator to sort PIIMatch objects by position (descending).
     * Descending order allows replacement from end to start without index shifting.
     */
    private class PIIMatchComparator implements Comparator<PIIMatch> {
        public Integer compare(PIIMatch a, PIIMatch b) {
            // Sort descending by start index
            return b.startIndex - a.startIndex;
        }
    }
}
