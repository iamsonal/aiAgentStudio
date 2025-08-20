/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionFindEntities is an advanced Apex action for performing intelligent, pattern-aware fuzzy search across Salesforce records.
 *
 * Responsibilities:
 *   - Analyzes search queries using pattern recognition (email, phone, name, ID) to optimize SOSL search strategies.
 *   - Leverages custom metadata (SObjectConfig__mdt) to configure searchable objects and scoring fields.
 *   - Implements result caching for performance and sophisticated scoring algorithms for ranking results.
 *   - Supports dynamic configuration, field-level security, and provides structured, LLM-friendly results.
 *
 * Scope:
 *   - Designed for extensibility, maintainability, and clarity, with detailed debug output and robust error handling.
 *   - Does not modify or create records; strictly focused on search and result ranking.
 *
 * Configuration: SObjectConfig__mdt records define searchable objects and scoring fields.
 * Parameters: {"searchQuery": "search text", "sObjectTypes": ["Contact", "Account"]}
 *
 * @extends BaseAgentAction
 */
public class ActionFindEntities extends BaseAgentAction {
    private static final String CONFIG_MAX_AMBIGUOUS_RESULTS = 'maxAmbiguousResults';
    private static final Integer DEFAULT_MAX_AMBIGUOUS_RESULTS = 5;
    private static final Integer SOSL_QUERY_LIMIT = 50;
    private static final Integer NAME_FIELD_MATCH_SCORE = 100;
    private static final Integer KEY_FIELD_MATCH_SCORE = 50;

    @TestVisible
    private static List<SObjectConfig__mdt> MDT_CACHE;

    private class ScoringInfo {
        public String primaryNameField;
        public Set<String> keyIdentifierFields;
        public ScoringInfo(String nameField, Set<String> keyFields) {
            this.primaryNameField = nameField;
            this.keyIdentifierFields = keyFields;
        }
    }

    private Map<String, List<String>> configuredReturnFields = new Map<String, List<String>>();
    private Map<String, ScoringInfo> scoringConfig = new Map<String, ScoringInfo>();
    private Integer maxAmbiguousResults = DEFAULT_MAX_AMBIGUOUS_RESULTS;

    /**
     * @description
     * Main entry point for entity search. Analyzes the search query, checks the cache, performs SOSL queries if needed,
     * and ranks results using advanced scoring algorithms. Returns a structured result for downstream use.
     *
     * @param params Map<String, Object> - Must include 'searchQuery' (String), may include 'sObjectTypes' (List<String>).
     * @return SearchResult - Contains found records, ambiguous options, or not found status.
     * @throws ValidationException if required parameters are missing or invalid.
     * @throws ActionSecurityException if user lacks access to any configured or requested objects.
     *
     * Side effects: Logs pattern analysis, cache usage, performance, and error details for troubleshooting.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Extract and validate parameters
        String searchQuery = (String) params.get('searchQuery');
        List<String> sObjectTypes = (List<String>) params.get('sObjectTypes');
        if (String.isBlank(searchQuery)) {
            throw new ValidationException('Search query cannot be blank', 'searchQuery');
        }

        // Analyze search pattern for optimal query strategy
        SearchPatternAnalyzer.SearchAnalysis patternAnalysis = SearchPatternAnalyzer.analyzeSearchQuery(searchQuery);
        System.debug(
            LoggingLevel.INFO,
            '[ActionFindEntities] Search pattern: ' + patternAnalysis.primaryPattern + ' (confidence: ' + patternAnalysis.confidenceScore + '%)'
        );

        // Check cache for performance
        String cacheKey = SearchResultCache.generateCacheKey(searchQuery, sObjectTypes, UserInfo.getUserId());
        SearchResultCache.CachedSearchResult cachedResult = SearchResultCache.getCachedResults(cacheKey);

        List<List<SObject>> searchResults;
        if (cachedResult != null) {
            System.debug(LoggingLevel.INFO, '[ActionFindEntities] Cache hit for key: ' + cacheKey);
            searchResults = cachedResult.searchResults;
            patternAnalysis = cachedResult.patternAnalysis;
        } else {
            System.debug(LoggingLevel.INFO, '[ActionFindEntities] Cache miss for key: ' + cacheKey + '. Executing new search.');
            try {
                Map<String, List<String>> accessibleReturnFields = buildAccessibleReturnFieldMap(sObjectTypes);
                searchResults = executeOptimizedSearch(searchQuery, accessibleReturnFields, patternAnalysis);
                SearchResultCache.cacheResults(cacheKey, searchResults, patternAnalysis);
            } catch (ActionSecurityException ase) {
                System.debug(LoggingLevel.ERROR, '[ActionFindEntities] Security error during search: ' + ase.getMessage());
                throw ase;
            }
        }

        List<ScoredResult> rankedResults = scoreAndRankResults(searchResults, searchQuery, patternAnalysis);

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(LoggingLevel.INFO, '[ActionFindEntities] Search completed in ' + executionTime + ' ms. Results: ' + rankedResults.size());
        logCachePerformanceMetrics();

        SearchResult result = processRankedResults(rankedResults);

        // SECURITY: Analyze search results for prompt injection threats
        analyzeSearchResultsForSecurity(rankedResults);

        return result;
    }

    /**
     * @description
     * Parses and validates the action configuration JSON. Loads and caches custom metadata for searchable objects,
     * builds scoring and return field maps, and applies configuration overrides.
     *
     * @param actionConfigurationJson String - The JSON configuration string.
     * @param logPrefix String - Prefix for log output.
     * @throws ValidationException if required configuration or metadata is missing or invalid.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        // Load and cache custom metadata configuration for searchable objects
        if (MDT_CACHE == null) {
            try {
                MDT_CACHE = [
                    SELECT SObjectAPIName__c, PrimaryNameField__c, KeyIdentifierFields__c
                    FROM SObjectConfig__mdt
                    WHERE IsActive__c = TRUE
                ];
                System.debug(
                    LoggingLevel.INFO,
                    '[ActionFindEntities] Custom metadata cache miss. Loaded ' + MDT_CACHE.size() + ' SObjectConfig__mdt records.'
                );
            } catch (Exception e) {
                throw new ValidationException('Failed to query SObjectConfig__mdt records: ' + e.getMessage(), null, e);
            }
        } else {
            System.debug(LoggingLevel.INFO, '[ActionFindEntities] Custom metadata cache hit. Using cached SObjectConfig__mdt records.');
        }

        if (MDT_CACHE.isEmpty()) {
            throw new ValidationException('No active SObjectConfig__mdt records found. Please configure searchable objects.', null);
        }

        // Build search configuration from custom metadata
        for (SObjectConfig__mdt config : MDT_CACHE) {
            String sObjApiName = config.SObjectAPIName__c;
            if (String.isBlank(sObjApiName) || String.isBlank(config.PrimaryNameField__c)) {
                System.debug(LoggingLevel.WARN, '[ActionFindEntities] Skipping invalid SObjectConfig__mdt record: ' + config.DeveloperName);
                continue;
            }

            Set<String> keyFields = new Set<String>();
            if (String.isNotBlank(config.KeyIdentifierFields__c)) {
                for (String field : config.KeyIdentifierFields__c.split(',')) {
                    if (String.isNotBlank(field.trim())) {
                        keyFields.add(field.trim());
                    }
                }
            }

            this.scoringConfig.put(sObjApiName.toLowerCase(), new ScoringInfo(config.PrimaryNameField__c, keyFields));

            List<String> fieldsForObject = new List<String>(keyFields);
            fieldsForObject.addAll(new List<String>{ config.PrimaryNameField__c, 'Id' });
            this.configuredReturnFields.put(sObjApiName, new List<String>(new Set<String>(fieldsForObject)));
        }

        // Apply configuration overrides
        if (this.parsedActionConfig?.containsKey(CONFIG_MAX_AMBIGUOUS_RESULTS)) {
            Object maxResults = this.parsedActionConfig.get(CONFIG_MAX_AMBIGUOUS_RESULTS);
            if (maxResults instanceof Integer) {
                this.maxAmbiguousResults = (Integer) maxResults;
                System.debug(LoggingLevel.INFO, '[ActionFindEntities] maxAmbiguousResults overridden to: ' + this.maxAmbiguousResults);
            }
        }
    }

    /**
     * @description
     * Logs cache performance metrics periodically for monitoring and optimization.
     * Only logs every 10th execution to avoid log clutter.
     */
    private void logCachePerformanceMetrics() {
        if (Math.mod(System.currentTimeMillis(), 10) == 0) {
            SearchResultCache.CacheStatistics stats = SearchResultCache.getCacheStatistics();
            System.debug(
                LoggingLevel.INFO,
                '[ActionFindEntities] Cache stats: size=' +
                    stats.totalCacheSize +
                    ', hitRatio=' +
                    stats.hitRatio.setScale(1) +
                    '%, hits=' +
                    stats.hitCount +
                    ', misses=' +
                    stats.missCount
            );
        }
    }

    private Map<String, List<String>> buildAccessibleReturnFieldMap(List<String> sObjectTypesFromArgs) {
        Map<String, List<String>> accessibleMap = new Map<String, List<String>>();
        Set<String> targetSObjectNames = (sObjectTypesFromArgs != null && !sObjectTypesFromArgs.isEmpty())
            ? new Set<String>(sObjectTypesFromArgs)
            : this.configuredReturnFields.keySet();

        for (String sObjName : targetSObjectNames) {
            if (!this.configuredReturnFields.containsKey(sObjName))
                continue;

            SObjectType sObjType = SchemaUtils.getSObjectType(sObjName);
            if (sObjType != null && sObjType.getDescribe().isAccessible()) {
                List<String> accessibleFields = new List<String>();
                for (String fieldName : this.configuredReturnFields.get(sObjName)) {
                    if (SecurityUtils.hasFieldPermission(sObjType, fieldName, AccessType.READABLE)) {
                        accessibleFields.add(fieldName);
                    }
                }
                if (!accessibleFields.isEmpty()) {
                    accessibleMap.put(sObjName, accessibleFields);
                }
            }
        }

        if (accessibleMap.isEmpty()) {
            throw new ActionSecurityException('User lacks read access to any configured or requested objects.');
        }

        return accessibleMap;
    }

    private List<List<SObject>> executeOptimizedSearch(
        String searchQuery,
        Map<String, List<String>> accessibleReturnFields,
        SearchPatternAnalyzer.SearchAnalysis patternAnalysis
    ) {
        String soslReturningClause = buildSoslReturningClause(accessibleReturnFields);
        String sanitizedSearchQuery = String.escapeSingleQuotes(searchQuery);
        String soslScope = patternAnalysis.recommendedSOSLScope;
        String soslQuery =
            'FIND \'' +
            sanitizedSearchQuery +
            '\' IN ' +
            soslScope +
            ' RETURNING ' +
            soslReturningClause +
            ' LIMIT ' +
            SOSL_QUERY_LIMIT;

        try {
            System.debug(LoggingLevel.INFO, '[ActionFindEntities] Executing SOSL (' + soslScope + '): ' + soslQuery);
            List<List<SObject>> searchResults = Search.query(soslQuery);
            for (String optimizationHint : patternAnalysis.optimizationHints) {
                System.debug(LoggingLevel.DEBUG, '[ActionFindEntities] Optimization hint: ' + optimizationHint);
            }
            return searchResults;
        } catch (SearchException se) {
            if (!soslScope.equals('ALL FIELDS')) {
                System.debug(LoggingLevel.WARN, '[ActionFindEntities] SOSL scope ' + soslScope + ' failed, falling back to ALL FIELDS.');
                String fallbackQuery =
                    'FIND \'' +
                    sanitizedSearchQuery +
                    '\' IN ALL FIELDS RETURNING ' +
                    soslReturningClause +
                    ' LIMIT ' +
                    SOSL_QUERY_LIMIT;
                try {
                    return Search.query(fallbackQuery);
                } catch (SearchException fallbackException) {
                    throw new QueryException('SOSL search failed: ' + fallbackException.getMessage());
                }
            } else {
                throw new QueryException('SOSL search failed: ' + se.getMessage());
            }
        }
    }

    private String buildSoslReturningClause(Map<String, List<String>> accessibleReturnFields) {
        List<String> returningParts = new List<String>();
        for (String sObjName : accessibleReturnFields.keySet()) {
            String fields = String.join(accessibleReturnFields.get(sObjName), ', ');
            returningParts.add(sObjName + '(' + fields + ')');
        }
        return String.join(returningParts, ', ');
    }

    private List<ScoredResult> scoreAndRankResults(
        List<List<SObject>> searchResults,
        String searchQuery,
        SearchPatternAnalyzer.SearchAnalysis patternAnalysis
    ) {
        List<ScoredResult> scoredList = new List<ScoredResult>();
        Integer initialScore = SOSL_QUERY_LIMIT;

        for (List<SObject> sObjectList : searchResults) {
            for (SObject sObj : sObjectList) {
                Integer score = initialScore--;
                String sObjNameLower = sObj.getSObjectType().getDescribe().getName().toLowerCase();
                ScoringInfo scoringInfo = this.scoringConfig.get(sObjNameLower);

                if (scoringInfo != null) {
                    score += calculatePatternAwareScore(sObj, searchQuery, patternAnalysis, scoringInfo);
                    score += calculateTraditionalScore(sObj, searchQuery, scoringInfo);
                }

                scoredList.add(new ScoredResult(sObj, score, scoringInfo));
            }
        }

        scoredList.sort();
        System.debug(
            LoggingLevel.DEBUG,
            '[ActionFindEntities] Scored ' + scoredList.size() + ' results using pattern: ' + patternAnalysis.primaryPattern
        );
        return scoredList;
    }

    private Integer calculatePatternAwareScore(
        SObject sObj,
        String searchQuery,
        SearchPatternAnalyzer.SearchAnalysis patternAnalysis,
        ScoringInfo scoringInfo
    ) {
        Integer patternScore = 0;

        switch on patternAnalysis.primaryPattern {
            when EMAIL_SEARCH {
                patternScore += scoreEmailPattern(sObj, patternAnalysis);
            }
            when PHONE_SEARCH {
                patternScore += scorePhonePattern(sObj, patternAnalysis);
            }
            when PERSON_NAME {
                patternScore += scorePersonNamePattern(sObj, patternAnalysis);
            }
            when IDENTIFIER_SEARCH {
                patternScore += scoreIdentifierPattern(sObj, patternAnalysis, scoringInfo);
            }
        }

        return (Integer) (patternScore * (patternAnalysis.confidenceScore / 100.0));
    }

    private Integer calculateTraditionalScore(SObject sObj, String searchQuery, ScoringInfo scoringInfo) {
        Integer score = 0;

        Object nameValue = sObj.get(scoringInfo.primaryNameField);
        if (nameValue != null && String.valueOf(nameValue).toLowerCase().contains(searchQuery.toLowerCase())) {
            score += NAME_FIELD_MATCH_SCORE;
        }

        for (String keyField : scoringInfo.keyIdentifierFields) {
            Object keyValue = sObj.get(keyField);
            if (keyValue != null && String.valueOf(keyValue).toLowerCase().contains(searchQuery.toLowerCase())) {
                score += KEY_FIELD_MATCH_SCORE;
            }
        }

        return score;
    }

    private Integer scoreEmailPattern(SObject sObj, SearchPatternAnalyzer.SearchAnalysis patternAnalysis) {
        String extractedEmail = (String) patternAnalysis.patternMetadata?.get('extractedEmail');
        if (String.isBlank(extractedEmail))
            return 0;

        for (String field : new List<String>{ 'Email', 'PersonEmail', 'WorkEmail' }) {
            if (sObj.isSet(field)) {
                Object fieldValue = sObj.get(field);
                if (fieldValue != null && String.valueOf(fieldValue).equalsIgnoreCase(extractedEmail)) {
                    return 150;
                }
            }
        }
        return 0;
    }

    private Integer scorePhonePattern(SObject sObj, SearchPatternAnalyzer.SearchAnalysis patternAnalysis) {
        String extractedPhone = (String) patternAnalysis.patternMetadata?.get('extractedPhone');
        if (String.isBlank(extractedPhone))
            return 0;

        for (String field : new List<String>{ 'Phone', 'MobilePhone', 'HomePhone', 'WorkPhone' }) {
            if (sObj.isSet(field)) {
                Object fieldValue = sObj.get(field);
                if (fieldValue != null && normalizePhoneNumber(String.valueOf(fieldValue)).equals(normalizePhoneNumber(extractedPhone))) {
                    return 140;
                }
            }
        }
        return 0;
    }

    private Integer scorePersonNamePattern(SObject sObj, SearchPatternAnalyzer.SearchAnalysis patternAnalysis) {
        List<String> nameParts = (List<String>) patternAnalysis.patternMetadata?.get('nameParts');
        if (nameParts == null || nameParts.size() < 2)
            return 0;

        Map<String, Object> populatedFields = sObj.getPopulatedFieldsAsMap();
        String firstName = populatedFields.containsKey('FirstName') && populatedFields.get('FirstName') != null
            ? String.valueOf(populatedFields.get('FirstName')).toLowerCase()
            : null;
        String lastName = populatedFields.containsKey('LastName') && populatedFields.get('LastName') != null
            ? String.valueOf(populatedFields.get('LastName')).toLowerCase()
            : null;

        if (firstName != null || lastName != null) {
            Boolean firstNameMatch = firstName != null && nameParts.contains(firstName);
            Boolean lastNameMatch = lastName != null && nameParts.contains(lastName);

            if (firstNameMatch && lastNameMatch)
                return 120;
            if (firstNameMatch || lastNameMatch)
                return 60;
        }
        return 0;
    }

    private Integer scoreIdentifierPattern(SObject sObj, SearchPatternAnalyzer.SearchAnalysis patternAnalysis, ScoringInfo scoringInfo) {
        String extractedId = (String) patternAnalysis.patternMetadata?.get('extractedIdentifier');
        if (String.isBlank(extractedId))
            return 0;

        for (String keyField : scoringInfo.keyIdentifierFields) {
            if (sObj.isSet(keyField)) {
                Object fieldValue = sObj.get(keyField);
                if (fieldValue != null && String.valueOf(fieldValue).equalsIgnoreCase(extractedId)) {
                    return 160;
                }
            }
        }
        return 0;
    }

    private String normalizePhoneNumber(String phone) {
        return String.isBlank(phone) ? '' : phone.replaceAll('[^0-9]', '');
    }

    private SearchResult processRankedResults(List<ScoredResult> rankedResults) {
        if (rankedResults.isEmpty()) {
            return new SearchResult('NOT_FOUND', 'No matching records found.', null, null);
        }

        if (rankedResults.size() == 1 || (rankedResults[0].score > rankedResults[1].score + (NAME_FIELD_MATCH_SCORE / 2))) {
            String msg = (rankedResults.size() == 1) ? 'Found a single matching record.' : 'Found a high-confidence match.';
            return new SearchResult(
                'SUCCESS',
                msg + ' Here are the details for ' + rankedResults[0].displayLabel + '.',
                buildRecordDataMap(rankedResults[0].record),
                null
            );
        }

        // Ambiguous results
        List<Map<String, String>> options = new List<Map<String, String>>();
        for (Integer i = 0; i < Math.min(rankedResults.size(), this.maxAmbiguousResults); i++) {
            ScoredResult res = rankedResults[i];
            options.add(
                new Map<String, String>{
                    'id' => res.record.Id,
                    'label' => res.displayLabel,
                    'sObjectType' => res.record.getSObjectType().getDescribe().getName()
                }
            );
        }
        return new SearchResult('AMBIGUOUS', 'Found multiple possible matches. Please clarify which one you mean.', null, options);
    }

    /**
     * Analyzes search results for potential security threats in text fields
     *
     * @param rankedResults List of scored search results to analyze
     */
    private void analyzeSearchResultsForSecurity(List<ScoredResult> rankedResults) {
        try {
            for (ScoredResult scoredResult : rankedResults) {
                SObject record = scoredResult.record;
                Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
                String objectType = record.getSObjectType().getDescribe().getName();

                for (String fieldName : populatedFields.keySet()) {
                    Object fieldValue = populatedFields.get(fieldName);

                    // Only analyze string fields that could contain malicious content
                    if (fieldValue instanceof String && String.isNotBlank((String) fieldValue)) {
                        String textValue = (String) fieldValue;

                        // Skip very short values and system fields
                        if (textValue.length() < 20 || fieldName.equalsIgnoreCase('Id') || fieldName.equalsIgnoreCase('Name')) {
                            continue;
                        }

                        PromptInjectionGuard.SecurityAnalysisResult securityResult = PromptInjectionGuard.analyzeContent(
                            textValue,
                            fieldName,
                            objectType,
                            null
                        );

                        if (!securityResult.isSafe) {
                            System.debug(
                                LoggingLevel.WARN,
                                '[ActionFindEntities] Security risk detected in search result ' +
                                    record.Id +
                                    '.' +
                                    fieldName +
                                    ': ' +
                                    securityResult.riskLevel
                            );
                        }
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionFindEntities] Error during security analysis: ' + e.getMessage());
        }
    }

    private Map<String, Object> buildRecordDataMap(SObject record) {
        Map<String, Object> recordData = new Map<String, Object>();
        recordData.put('sObjectType', record.getSObjectType().getDescribe().getName());
        for (String field : record.getPopulatedFieldsAsMap().keySet()) {
            recordData.put(field, record.get(field));
        }
        return recordData;
    }

    /**
     * @description Result wrapper for search operations with support for single matches, ambiguous results, and not found scenarios.
     *              Provides structured data for both user display and LLM processing.
     */
    public class SearchResult {
        public String resultType;
        public String message; // Framework uses this for user display
        public Map<String, Object> record;
        public List<Map<String, String>> options;
        public Map<String, Object> metadata; // Additional context for LLMs

        public SearchResult(String resultType, String message, Map<String, Object> record, List<Map<String, String>> options) {
            this.resultType = resultType;
            this.message = message;
            this.record = record;
            this.options = options;
            this.metadata = new Map<String, Object>{
                'searchType' => resultType,
                'hasRecord' => record != null,
                'optionCount' => options != null ? options.size() : 0
            };
        }
    }

    private class ScoredResult implements Comparable {
        public SObject record;
        public Integer score;
        public String displayLabel;

        public ScoredResult(SObject record, Integer score, ScoringInfo scoringInfo) {
            this.record = record;
            this.score = score;
            this.displayLabel = buildDisplayLabel(record, scoringInfo);
        }

        public Integer compareTo(Object other) {
            ScoredResult otherResult = (ScoredResult) other;
            return otherResult.score - this.score; // Descending order
        }

        private String buildDisplayLabel(SObject record, ScoringInfo scoringInfo) {
            if (scoringInfo != null && String.isNotBlank(scoringInfo.primaryNameField)) {
                Object nameValue = record.get(scoringInfo.primaryNameField);
                if (nameValue != null) {
                    return String.valueOf(nameValue);
                }
            }
            return record.getSObjectType().getDescribe().getName() + ' (' + record.Id + ')';
        }
    }
}
