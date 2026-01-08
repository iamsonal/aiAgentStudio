/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * JailbreakPatternMatcher detects prompt injection and jailbreak attempts using regex patterns
 * defined in JailbreakPattern__mdt custom metadata. This is Layer 1 of the multi-layered
 * Prompt Safety detection system.
 *
 * Key Features:
 * - Pattern-based detection using configurable regex patterns from custom metadata
 * - Category filtering to enable/disable groups of patterns
 * - Priority ordering to process critical patterns first
 * - Severity scoring for each pattern match
 * - Cached pattern loading for performance
 * - CPU safeguards for large text inputs
 *
 * Categories:
 * - RoleManipulation: "you are now DAN", "pretend to be", persona changes
 * - InstructionOverride: "ignore previous instructions", "new instructions"
 * - DelimiterInjection: System markers like "### System:", "[INST]"
 * - EncodingAttack: Base64 encoded instructions, obfuscation
 * - PromptLeaking: "repeat your system prompt", "what are your instructions"
 * - ContextManipulation: Token stuffing, context exhaustion
 *
 * Part of the Prompt Safety Trust Layer for AI safety.
 *
 * @example
 * JailbreakPatternMatcher matcher = new JailbreakPatternMatcher();
 * List<JailbreakPatternMatcher.PatternMatch> matches = matcher.findMatches('ignore all previous instructions');
 * // matches[0].patternName = 'IgnorePrevious'
 * // matches[0].severity = 0.9
 */
public inherited sharing class JailbreakPatternMatcher {
    // Cached patterns loaded from custom metadata
    private static List<JailbreakPattern__mdt> cachedPatterns;

    // Categories enabled for this matcher instance
    private Set<String> enabledCategories;

    // Compiled patterns for this instance (filtered by category)
    private List<CompiledPattern> compiledPatterns;

    // Logging prefix
    private static final String LOG_PREFIX = '[JailbreakPatternMatcher] ';

    // CPU safeguard: Maximum text length for pattern matching
    @TestVisible
    private static Integer MAX_TEXT_LENGTH = 50000;

    /**
     * @description Represents a detected jailbreak pattern match.
     */
    public class PatternMatch {
        public String matchedValue { get; set; } // The actual matched text
        public String patternName { get; set; } // Name of the pattern that matched
        public String category { get; set; } // Category of the pattern
        public Decimal severity { get; set; } // Severity score (0.0-1.0)
        public String description { get; set; } // Pattern description
        public Integer startIndex { get; set; } // Position in original text
        public Integer endIndex { get; set; } // End position in original text

        public PatternMatch(String value, String name, String cat, Decimal sev, String descr, Integer startPos, Integer endIdx) {
            this.matchedValue = value;
            this.patternName = name;
            this.category = cat;
            this.severity = sev;
            this.description = descr;
            this.startIndex = startPos;
            this.endIndex = endIdx;
        }
    }

    /**
     * @description Internal class to hold compiled pattern data.
     */
    private class CompiledPattern {
        public String developerName;
        public System.Pattern regex;
        public String category;
        public Decimal severity;
        public String description;
        public Integer priority;
    }

    /**
     * @description Creates a matcher with all active patterns enabled.
     */
    public JailbreakPatternMatcher() {
        this(null);
    }

    /**
     * @description Creates a matcher with specific categories enabled.
     * @param categories Set of category names to enable (e.g., {'RoleManipulation', 'InstructionOverride'})
     *                   Pass null or empty set to enable all categories.
     */
    public JailbreakPatternMatcher(Set<String> categories) {
        this.enabledCategories = categories;
        loadAndCompilePatterns();
    }

    /**
     * @description Finds all jailbreak pattern matches in the given text.
     * Returns matches sorted by position in text.
     *
     * @param text The text to search for jailbreak patterns
     * @return List of PatternMatch objects representing found patterns
     */
    public List<PatternMatch> findMatches(String text) {
        List<PatternMatch> allMatches = new List<PatternMatch>();

        if (String.isBlank(text) || this.compiledPatterns.isEmpty()) {
            return allMatches;
        }

        // CPU safeguard: Skip pattern matching for excessively large text
        if (MAX_TEXT_LENGTH > 0 && text.length() > MAX_TEXT_LENGTH) {
            System.debug(
                LoggingLevel.WARN,
                LOG_PREFIX +
                    'Text exceeds max length for pattern matching (' +
                    text.length() +
                    ' > ' +
                    MAX_TEXT_LENGTH +
                    ' chars). Skipping pattern-based jailbreak detection.'
            );
            return allMatches;
        }

        // Apply each pattern in priority order
        for (CompiledPattern cp : this.compiledPatterns) {
            try {
                System.Matcher m = cp.regex.matcher(text);

                while (m.find()) {
                    String matchedValue = m.group();

                    PatternMatch match = new PatternMatch(matchedValue, cp.developerName, cp.category, cp.severity, cp.description, m.start(), m.end());
                    allMatches.add(match);
                }
            } catch (Exception e) {
                // Log but don't fail on individual pattern errors
                System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Error matching pattern "' + cp.developerName + '": ' + e.getMessage());
            }
        }

        // Sort by position (descending) for replacement from end to start
        allMatches.sort(new PatternMatchComparator());

        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Found ' + allMatches.size() + ' pattern matches');

        return allMatches;
    }

    /**
     * @description Checks if text contains any jailbreak patterns.
     * More efficient than findMatches() when you only need a boolean result.
     *
     * @param text The text to check
     * @return True if any jailbreak pattern is detected
     */
    public Boolean containsJailbreakPattern(String text) {
        if (String.isBlank(text) || this.compiledPatterns.isEmpty()) {
            return false;
        }

        // CPU safeguard
        if (MAX_TEXT_LENGTH > 0 && text.length() > MAX_TEXT_LENGTH) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Text exceeds max length (' + text.length() + ' chars). Skipping check.');
            return false;
        }

        for (CompiledPattern cp : this.compiledPatterns) {
            try {
                System.Matcher m = cp.regex.matcher(text);
                if (m.find()) {
                    return true;
                }
            } catch (Exception e) {
                // Continue to next pattern
            }
        }

        return false;
    }

    /**
     * @description Calculates the aggregated severity score from all matches.
     * Uses a weighted combination that caps at 1.0.
     *
     * @param matches List of pattern matches
     * @return Aggregated severity score (0.0-1.0)
     */
    public Decimal calculateAggregatedSeverity(List<PatternMatch> matches) {
        if (matches == null || matches.isEmpty()) {
            return 0.0;
        }

        // Use max severity + diminishing contribution from additional matches
        Decimal maxSeverity = 0.0;
        Decimal additionalScore = 0.0;

        for (PatternMatch match : matches) {
            Decimal sev = match.severity != null ? match.severity : 0.5;
            if (sev > maxSeverity) {
                maxSeverity = sev;
            } else {
                // Additional matches contribute 10% of their severity
                additionalScore += sev * 0.1;
            }
        }

        return Math.min(1.0, maxSeverity + additionalScore);
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
     *
     * @param maxLength Maximum text length in characters, or 0 to disable
     */
    @TestVisible
    public static void setMaxTextLength(Integer maxLength) {
        MAX_TEXT_LENGTH = maxLength != null ? maxLength : 50000;
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
                SELECT DeveloperName, MasterLabel, PatternRegex__c, Category__c, Severity__c, Priority__c, IsActive__c, Description__c
                FROM JailbreakPattern__mdt
                WHERE IsActive__c = TRUE
                ORDER BY Priority__c ASC
            ];
        }

        // Compile patterns, filtering by category
        for (JailbreakPattern__mdt pattern : cachedPatterns) {
            // Skip if category filtering is enabled and this category isn't included
            if (this.enabledCategories != null && !this.enabledCategories.isEmpty() && !this.enabledCategories.contains(pattern.Category__c)) {
                continue;
            }

            try {
                CompiledPattern cp = new CompiledPattern();
                cp.developerName = pattern.DeveloperName;
                cp.regex = System.Pattern.compile(pattern.PatternRegex__c);
                cp.category = pattern.Category__c;
                cp.severity = pattern.Severity__c != null ? pattern.Severity__c : 0.5;
                cp.description = pattern.Description__c;
                cp.priority = pattern.Priority__c != null ? Integer.valueOf(pattern.Priority__c) : 100;

                this.compiledPatterns.add(cp);
            } catch (Exception e) {
                // Log but don't fail - skip invalid patterns
                System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Failed to compile pattern "' + pattern.DeveloperName + '": ' + e.getMessage());
            }
        }

        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Loaded ' + this.compiledPatterns.size() + ' patterns');
    }

    // =========================================================================
    // COMPARATOR FOR SORTING MATCHES
    // =========================================================================

    /**
     * @description Comparator to sort PatternMatch objects by position (descending).
     * Descending order allows replacement from end to start without index shifting.
     */
    private class PatternMatchComparator implements Comparator<PatternMatch> {
        public Integer compare(PatternMatch a, PatternMatch b) {
            // Sort descending by start index
            return b.startIndex - a.startIndex;
        }
    }
}
