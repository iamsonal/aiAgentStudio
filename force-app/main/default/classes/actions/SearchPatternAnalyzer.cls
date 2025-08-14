/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SearchPatternAnalyzer: Intelligent natural language search pattern analyzer for AI-driven query optimization.
 *
 * This class analyzes natural language search queries using pattern recognition, regex matching, and linguistic analysis
 * to determine optimal SOSL strategies, field targeting, and relevance scoring. It provides confidence scoring and
 * pattern-specific optimization recommendations for maximum search effectiveness, supporting AI agents and advanced automation.
 *
 * Key Responsibilities:
 *   - Detects and classifies search patterns (e.g., name, email, phone, company, etc.)
 *   - Scores confidence and recommends SOSL scope and priority fields for each query
 *   - Generates actionable optimization hints for downstream search execution
 *   - Surfaces pattern metadata for diagnostics, monitoring, and LLM-driven workflows
 */
public class SearchPatternAnalyzer {
    /**
     * @description
     * Enumeration of search patterns for intelligent query optimization and routing.
     */
    public enum SearchPattern {
        PERSON_NAME, // "John Smith", "Jane Doe"
        EMAIL_SEARCH, // "john@company.com", "user@domain.org"
        PHONE_SEARCH, // "555-123-4567", "(555) 123-4567"
        COMPANY_SEARCH, // "Acme Corp", "Global Industries Inc"
        MIXED_CRITERIA, // "John at Acme", "Smith from Boston"
        IDENTIFIER_SEARCH, // "ACC-12345", "CASE-67890"
        ADDRESS_SEARCH, // "123 Main St", "New York, NY"
        PARTIAL_MATCH, // Single word searches, abbreviations
        COMPLEX_QUERY // Multiple criteria, complex natural language
    }

    /**
     * @description
     * Result object containing detected search pattern, optimization hints, confidence score, and metadata.
     */
    public class SearchAnalysis {
        public SearchPattern primaryPattern;
        public List<SearchPattern> secondaryPatterns;
        public Map<String, Object> patternMetadata;
        public List<String> optimizationHints;
        public Integer confidenceScore; // 1-100 scale
        public String recommendedSOSLScope;
        public List<String> priorityFields;

        /**
         * @description
         * Constructs a SearchAnalysis result with detected pattern and default confidence.
         *
         * @param pattern Detected primary search pattern
         */
        public SearchAnalysis(SearchPattern pattern) {
            this.primaryPattern = pattern;
            this.secondaryPatterns = new List<SearchPattern>();
            this.patternMetadata = new Map<String, Object>();
            this.optimizationHints = new List<String>();
            this.priorityFields = new List<String>();
            this.confidenceScore = 50; // Default medium confidence
        }
    }

    // Pattern matching regular expressions
    private static final Pattern EMAIL_PATTERN = Pattern.compile('\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}\\b');
    private static final Pattern PHONE_PATTERN = Pattern.compile('\\b(?:\\+?1[-.]?)?\\(?([0-9]{3})\\)?[-.]?([0-9]{3})[-.]?([0-9]{4})\\b');
    private static final Pattern IDENTIFIER_PATTERN = Pattern.compile('\\b[A-Z]{2,}-\\d{3,}\\b');
    private static final Pattern ADDRESS_PATTERN = Pattern.compile(
        '\\b\\d+\\s+[A-Za-z\\s]+(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard|Dr|Drive|Ln|Lane)\\b'
    );

    // Common business entity indicators
    private static final Set<String> COMPANY_INDICATORS = new Set<String>{
        'corp',
        'corporation',
        'inc',
        'incorporated',
        'llc',
        'ltd',
        'limited',
        'company',
        'co',
        'group',
        'enterprises',
        'solutions',
        'services',
        'technologies',
        'tech',
        'systems',
        'consulting',
        'partners'
    };

    // Common name patterns
    private static final Set<String> COMMON_FIRST_NAMES = new Set<String>{
        'john',
        'jane',
        'michael',
        'sarah',
        'david',
        'mary',
        'robert',
        'jennifer',
        'william',
        'elizabeth',
        'james',
        'patricia',
        'charles',
        'linda',
        'joseph',
        'barbara',
        'thomas',
        'susan',
        'christopher',
        'jessica',
        'daniel',
        'karen'
    };

    /**
     * @description
     * Performs comprehensive analysis of natural language search queries to optimize SOSL execution.
     * Uses pattern recognition, confidence scoring, and field prioritization for intelligent search routing.
     *
     * @param searchQuery Natural language search string from user input
     * @return SearchAnalysis with detected patterns, confidence scores, and optimization recommendations
     */
    public static SearchAnalysis analyzeSearchQuery(String searchQuery) {
        if (String.isBlank(searchQuery)) {
            System.debug(LoggingLevel.WARN, '[SearchPatternAnalyzer] Empty search query provided. Returning COMPLEX_QUERY pattern.');
            return new SearchAnalysis(SearchPattern.COMPLEX_QUERY);
        }

        String normalizedQuery = searchQuery.toLowerCase().trim();
        SearchAnalysis analysis = new SearchAnalysis(SearchPattern.PARTIAL_MATCH);

        // Detect primary and secondary search patterns
        analysis.primaryPattern = detectPrimaryPattern(normalizedQuery);
        analysis.secondaryPatterns = detectSecondaryPatterns(normalizedQuery);

        // Enrich analysis with pattern-specific metadata and recommendations
        enrichAnalysisWithPatternData(analysis, normalizedQuery, searchQuery);

        // Calculate confidence score based on pattern strength
        analysis.confidenceScore = calculateConfidenceScore(analysis, normalizedQuery);

        // Determine optimal SOSL scope for the detected pattern
        analysis.recommendedSOSLScope = determineSOSLScope(analysis);

        // Identify priority fields for enhanced relevance scoring
        analysis.priorityFields = determinePriorityFields(analysis);

        System.debug(
            LoggingLevel.DEBUG,
            '[SearchPatternAnalyzer] Pattern=' +
                analysis.primaryPattern +
                ', Confidence=' +
                analysis.confidenceScore +
                ', Scope=' +
                analysis.recommendedSOSLScope
        );

        return analysis;
    }

    /**
     * @description
     * Identifies the dominant search pattern using regex matching and linguistic analysis.
     * Prioritizes structured patterns (email, phone) over contextual patterns (names, companies).
     *
     * @param normalizedQuery Lowercased, trimmed search query
     * @return SearchPattern detected primary pattern
     */
    private static SearchPattern detectPrimaryPattern(String normalizedQuery) {
        // Email detection (highest priority)
        if (EMAIL_PATTERN.matcher(normalizedQuery).find()) {
            return SearchPattern.EMAIL_SEARCH;
        }

        // Phone detection
        if (PHONE_PATTERN.matcher(normalizedQuery).find()) {
            return SearchPattern.PHONE_SEARCH;
        }

        // Identifier detection (case-sensitive check on original)
        if (IDENTIFIER_PATTERN.matcher(normalizedQuery.toUpperCase()).find()) {
            return SearchPattern.IDENTIFIER_SEARCH;
        }

        // Address detection
        if (ADDRESS_PATTERN.matcher(normalizedQuery).find()) {
            return SearchPattern.ADDRESS_SEARCH;
        }

        // Company detection
        if (containsCompanyIndicators(normalizedQuery)) {
            return SearchPattern.COMPANY_SEARCH;
        }

        // Person name detection
        if (isProbablyPersonName(normalizedQuery)) {
            return SearchPattern.PERSON_NAME;
        }

        // Mixed criteria detection
        if (containsMixedCriteria(normalizedQuery)) {
            return SearchPattern.MIXED_CRITERIA;
        }

        // Complex query detection
        if (isComplexQuery(normalizedQuery)) {
            return SearchPattern.COMPLEX_QUERY;
        }

        // Default to partial match
        return SearchPattern.PARTIAL_MATCH;
    }

    /**
     * @description
     * Detects secondary patterns that might also apply to the search query.
     *
     * @param normalizedQuery Lowercased, trimmed search query
     * @return List<SearchPattern> of secondary patterns
     */
    private static List<SearchPattern> detectSecondaryPatterns(String normalizedQuery) {
        List<SearchPattern> secondaryPatterns = new List<SearchPattern>();

        // Check for multiple pattern indicators
        if (containsCompanyIndicators(normalizedQuery) && isProbablyPersonName(normalizedQuery)) {
            secondaryPatterns.add(SearchPattern.MIXED_CRITERIA);
        }

        if (normalizedQuery.split('\\s+').size() == 1) {
            secondaryPatterns.add(SearchPattern.PARTIAL_MATCH);
        }

        return secondaryPatterns;
    }

    /**
     * @description
     * Enriches analysis with pattern-specific metadata and optimization hints.
     *
     * @param analysis SearchAnalysis result to update
     * @param normalizedQuery Lowercased, trimmed search query
     * @param originalQuery Original user input
     */
    private static void enrichAnalysisWithPatternData(SearchAnalysis analysis, String normalizedQuery, String originalQuery) {
        switch on analysis.primaryPattern {
            when EMAIL_SEARCH {
                Matcher emailMatcher = EMAIL_PATTERN.matcher(originalQuery);
                if (emailMatcher.find()) {
                    analysis.patternMetadata.put('extractedEmail', emailMatcher.group());
                    analysis.patternMetadata.put('emailDomain', emailMatcher.group().split('@')[1]);
                }
                analysis.optimizationHints.add('Use EMAIL FIELDS scope for optimal performance');
                analysis.optimizationHints.add('Prioritize Email field in scoring');
            }
            when PHONE_SEARCH {
                Matcher phoneMatcher = PHONE_PATTERN.matcher(originalQuery);
                if (phoneMatcher.find()) {
                    analysis.patternMetadata.put('extractedPhone', phoneMatcher.group());
                    analysis.patternMetadata.put('areaCode', phoneMatcher.group(1));
                }
                analysis.optimizationHints.add('Use PHONE FIELDS scope for optimal performance');
                analysis.optimizationHints.add('Consider phone number formatting variations');
            }
            when PERSON_NAME {
                List<String> nameParts = normalizedQuery.split('\\s+');
                analysis.patternMetadata.put('nameParts', nameParts);
                analysis.patternMetadata.put('isCommonName', containsCommonName(nameParts));
                analysis.optimizationHints.add('Use NAME FIELDS scope for optimal performance');
                analysis.optimizationHints.add('Consider FirstName and LastName field combinations');
            }
            when COMPANY_SEARCH {
                analysis.patternMetadata.put('companyIndicators', getCompanyIndicators(normalizedQuery));
                analysis.optimizationHints.add('Prioritize Account and Company name fields');
                analysis.optimizationHints.add('Consider business entity variations (Inc, Corp, LLC)');
            }
            when IDENTIFIER_SEARCH {
                Matcher idMatcher = IDENTIFIER_PATTERN.matcher(originalQuery.toUpperCase());
                if (idMatcher.find()) {
                    analysis.patternMetadata.put('extractedIdentifier', idMatcher.group());
                    String[] parts = idMatcher.group().split('-');
                    analysis.patternMetadata.put('identifierPrefix', parts[0]);
                    analysis.patternMetadata.put('identifierNumber', parts[1]);
                }
                analysis.optimizationHints.add('Search custom identifier fields');
                analysis.optimizationHints.add('Consider case-insensitive matching');
            }
            when MIXED_CRITERIA {
                analysis.optimizationHints.add('Use ALL FIELDS scope for comprehensive search');
                analysis.optimizationHints.add('Apply weighted scoring across multiple field types');
            }
            when else {
                analysis.optimizationHints.add('Use ALL FIELDS scope for broad coverage');
                analysis.optimizationHints.add('Apply general relevance scoring');
            }
        }

        // Add general metadata
        analysis.patternMetadata.put('wordCount', normalizedQuery.split('\\s+').size());
        analysis.patternMetadata.put('queryLength', normalizedQuery.length());

        Pattern specialCharPattern = Pattern.compile('[^a-zA-Z0-9\\s]');
        Matcher m = specialCharPattern.matcher(normalizedQuery);
        analysis.patternMetadata.put('hasSpecialChars', m.find());
    }

    /**
     * @description
     * Calculates confidence score for pattern detection based on pattern type and query characteristics.
     *
     * @param analysis SearchAnalysis result
     * @param normalizedQuery Lowercased, trimmed search query
     * @return Integer confidence score (1-100)
     */
    private static Integer calculateConfidenceScore(SearchAnalysis analysis, String normalizedQuery) {
        Integer baseScore = 50;

        switch on analysis.primaryPattern {
            when EMAIL_SEARCH, PHONE_SEARCH, IDENTIFIER_SEARCH {
                baseScore = 95; // High confidence for structured patterns
            }
            when PERSON_NAME {
                baseScore = analysis.patternMetadata.containsKey('isCommonName') && (Boolean) analysis.patternMetadata.get('isCommonName') ? 85 : 70;
            }
            when COMPANY_SEARCH {
                baseScore = 75;
            }
            when ADDRESS_SEARCH {
                baseScore = 80;
            }
            when MIXED_CRITERIA {
                baseScore = 60;
            }
            when PARTIAL_MATCH {
                baseScore = 40;
            }
            when COMPLEX_QUERY {
                baseScore = 30;
            }
        }

        // Adjust based on query characteristics
        Integer wordCount = (Integer) analysis.patternMetadata.get('wordCount');
        if (wordCount == 2)
            baseScore += 10; // Two words often indicate name or company
        if (wordCount > 5)
            baseScore -= 10; // Very long queries are less predictable

        return Math.max(10, Math.min(100, baseScore));
    }

    /**
     * @description
     * Determines optimal SOSL scope based on pattern analysis.
     *
     * @param analysis SearchAnalysis result
     * @return String recommended SOSL scope
     */
    private static String determineSOSLScope(SearchAnalysis analysis) {
        switch on analysis.primaryPattern {
            when EMAIL_SEARCH {
                return 'EMAIL FIELDS';
            }
            when PHONE_SEARCH {
                return 'PHONE FIELDS';
            }
            when PERSON_NAME {
                return 'NAME FIELDS';
            }
            when else {
                return 'ALL FIELDS';
            }
        }
    }

    /**
     * @description
     * Determines priority fields for enhanced scoring based on detected pattern.
     *
     * @param analysis SearchAnalysis result
     * @return List<String> of priority field API names
     */
    private static List<String> determinePriorityFields(SearchAnalysis analysis) {
        List<String> priorityFields = new List<String>();

        switch on analysis.primaryPattern {
            when EMAIL_SEARCH {
                priorityFields.addAll(new List<String>{ 'Email', 'PersonEmail', 'WorkEmail' });
            }
            when PHONE_SEARCH {
                priorityFields.addAll(new List<String>{ 'Phone', 'MobilePhone', 'HomePhone', 'WorkPhone' });
            }
            when PERSON_NAME {
                priorityFields.addAll(new List<String>{ 'Name', 'FirstName', 'LastName', 'FullName' });
            }
            when COMPANY_SEARCH {
                priorityFields.addAll(new List<String>{ 'Name', 'CompanyName', 'AccountName', 'Company' });
            }
            when ADDRESS_SEARCH {
                priorityFields.addAll(new List<String>{ 'MailingAddress', 'BillingAddress', 'ShippingAddress', 'Address' });
            }
            when else {
                priorityFields.addAll(new List<String>{ 'Name', 'Email', 'Phone' });
            }
        }

        return priorityFields;
    }

    // Helper methods for pattern detection and analysis
    private static Boolean containsCompanyIndicators(String query) {
        for (String indicator : COMPANY_INDICATORS) {
            if (query.contains(indicator)) {
                return true;
            }
        }
        return false;
    }

    private static List<String> getCompanyIndicators(String query) {
        List<String> found = new List<String>();
        for (String indicator : COMPANY_INDICATORS) {
            if (query.contains(indicator)) {
                found.add(indicator);
            }
        }
        return found;
    }

    private static Boolean isProbablyPersonName(String query) {
        List<String> words = query.split('\\s+');
        if (words.size() < 2 || words.size() > 4) {
            return false; // Names typically 2-4 words
        }

        // Check if any word is a common first name
        for (String word : words) {
            if (COMMON_FIRST_NAMES.contains(word.toLowerCase())) {
                return true;
            }
        }

        // Check if words look like names (capitalized, no numbers)
        Integer namelikeWords = 0;
        Pattern namePattern = Pattern.compile('^[A-Za-z]+$');
        for (String word : words) {
            Matcher m = namePattern.matcher(word);
            if (m.matches() && word.length() > 1) {
                namelikeWords++;
            }
        }

        return namelikeWords >= 2;
    }

    private static Boolean containsCommonName(List<String> nameParts) {
        for (String part : nameParts) {
            if (COMMON_FIRST_NAMES.contains(part.toLowerCase())) {
                return true;
            }
        }
        return false;
    }

    private static Boolean containsMixedCriteria(String query) {
        return query.contains(' at ') || query.contains(' from ') || query.contains(' in ') || query.contains(' with ') || query.contains(' for ');
    }

    private static Boolean isComplexQuery(String query) {
        Pattern p = Pattern.compile('\\b(and|or|but|however|also)\\b');
        Matcher m = p.matcher(query.toLowerCase());

        return query.split('\\s+').size() > 6 || query.contains('?') || query.contains(',') || m.find();
    }
}
