/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Enterprise-grade search pattern analysis for AI agent optimization.
 *              Analyzes natural language search queries to determine optimal search strategies,
 *              field targeting, and result scoring approaches for maximum relevance.
 */
public class SearchPatternAnalyzer {
    /**
     * @description Search patterns for intelligent query optimization
     */
    public enum SearchPattern {
        PERSON_NAME,
        EMAIL_SEARCH,
        PHONE_SEARCH,
        COMPANY_SEARCH,
        MIXED_CRITERIA,
        IDENTIFIER_SEARCH,
        ADDRESS_SEARCH,
        PARTIAL_MATCH,
        COMPLEX_QUERY
    }

    /**
     * @description Search optimization recommendations based on pattern analysis
     */
    public class SearchAnalysis {
        public SearchPattern primaryPattern;
        public List<SearchPattern> secondaryPatterns;
        public Map<String, Object> patternMetadata;
        public List<String> optimizationHints;
        public Integer confidenceScore;
        public String recommendedSOSLScope;
        public List<String> priorityFields;

        public SearchAnalysis(SearchPattern pattern) {
            this.primaryPattern = pattern;
            this.secondaryPatterns = new List<SearchPattern>();
            this.patternMetadata = new Map<String, Object>();
            this.optimizationHints = new List<String>();
            this.priorityFields = new List<String>();
            this.confidenceScore = 50;
        }
    }

    private static final Pattern EMAIL_PATTERN = Pattern.compile('\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}\\b');
    private static final Pattern PHONE_PATTERN = Pattern.compile('\\b(?:\\+?1[-.]?)?\\(?([0-9]{3})\\)?[-.]?([0-9]{3})[-.]?([0-9]{4})\\b');
    private static final Pattern IDENTIFIER_PATTERN = Pattern.compile('\\b[A-Z]{2,}-\\d{3,}\\b');
    private static final Pattern ADDRESS_PATTERN = Pattern.compile(
        '\\b\\d+\\s+[A-Za-z\\s]+(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard|Dr|Drive|Ln|Lane)\\b'
    );

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
     * @description Analyzes a search query to determine optimal search patterns and strategies
     * @param searchQuery The natural language search query
     * @return SearchAnalysis containing pattern detection and optimization recommendations
     */
    public static SearchAnalysis analyzeSearchQuery(String searchQuery) {
        if (String.isBlank(searchQuery)) {
            return new SearchAnalysis(SearchPattern.COMPLEX_QUERY);
        }

        String normalizedQuery = searchQuery.toLowerCase().trim();
        SearchAnalysis analysis = new SearchAnalysis(SearchPattern.PARTIAL_MATCH);

        analysis.primaryPattern = detectPrimaryPattern(normalizedQuery);
        analysis.secondaryPatterns = detectSecondaryPatterns(normalizedQuery);

        enrichAnalysisWithPatternData(analysis, normalizedQuery, searchQuery);

        analysis.confidenceScore = calculateConfidenceScore(analysis, normalizedQuery);

        analysis.recommendedSOSLScope = determineSOSLScope(analysis);

        analysis.priorityFields = determinePriorityFields(analysis);

        return analysis;
    }

    /**
     * @description Detects the primary search pattern from the query
     */
    private static SearchPattern detectPrimaryPattern(String normalizedQuery) {
        if (EMAIL_PATTERN.matcher(normalizedQuery).find()) {
            return SearchPattern.EMAIL_SEARCH;
        }

        if (PHONE_PATTERN.matcher(normalizedQuery).find()) {
            return SearchPattern.PHONE_SEARCH;
        }

        if (IDENTIFIER_PATTERN.matcher(normalizedQuery.toUpperCase()).find()) {
            return SearchPattern.IDENTIFIER_SEARCH;
        }

        if (ADDRESS_PATTERN.matcher(normalizedQuery).find()) {
            return SearchPattern.ADDRESS_SEARCH;
        }

        if (containsCompanyIndicators(normalizedQuery)) {
            return SearchPattern.COMPANY_SEARCH;
        }

        if (isProbablyPersonName(normalizedQuery)) {
            return SearchPattern.PERSON_NAME;
        }

        if (containsMixedCriteria(normalizedQuery)) {
            return SearchPattern.MIXED_CRITERIA;
        }

        if (isComplexQuery(normalizedQuery)) {
            return SearchPattern.COMPLEX_QUERY;
        }

        return SearchPattern.PARTIAL_MATCH;
    }

    /**
     * @description Detects secondary patterns that might also apply
     */
    private static List<SearchPattern> detectSecondaryPatterns(String normalizedQuery) {
        List<SearchPattern> secondaryPatterns = new List<SearchPattern>();

        if (containsCompanyIndicators(normalizedQuery) && isProbablyPersonName(normalizedQuery)) {
            secondaryPatterns.add(SearchPattern.MIXED_CRITERIA);
        }

        if (normalizedQuery.split('\\s+').size() == 1) {
            secondaryPatterns.add(SearchPattern.PARTIAL_MATCH);
        }

        return secondaryPatterns;
    }

    /**
     * @description Enriches analysis with pattern-specific metadata and hints
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

        analysis.patternMetadata.put('wordCount', normalizedQuery.split('\\s+').size());
        analysis.patternMetadata.put('queryLength', normalizedQuery.length());

        Pattern specialCharPattern = Pattern.compile('[^a-zA-Z0-9\\s]');
        Matcher m = specialCharPattern.matcher(normalizedQuery);
        analysis.patternMetadata.put('hasSpecialChars', m.find());
    }

    /**
     * @description Calculates confidence score for pattern detection
     */
    private static Integer calculateConfidenceScore(SearchAnalysis analysis, String normalizedQuery) {
        Integer baseScore = 50;

        switch on analysis.primaryPattern {
            when EMAIL_SEARCH, PHONE_SEARCH, IDENTIFIER_SEARCH {
                baseScore = 95;
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

        Integer wordCount = (Integer) analysis.patternMetadata.get('wordCount');
        if (wordCount == 2)
            baseScore += 10;
        if (wordCount > 5)
            baseScore -= 10;

        return Math.max(10, Math.min(100, baseScore));
    }

    /**
     * @description Determines optimal SOSL scope based on pattern analysis
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
     * @description Determines priority fields for enhanced scoring
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
            return false;
        }

        for (String word : words) {
            if (COMMON_FIRST_NAMES.contains(word.toLowerCase())) {
                return true;
            }
        }

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
