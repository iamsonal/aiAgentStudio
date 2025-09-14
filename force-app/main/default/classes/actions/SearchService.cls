/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SearchService: High-level facade for intelligent entity search with caching, pattern analysis, and result scoring.
 *
 * This service acts as a unified entry point for entity search operations, orchestrating the interaction between
 * pattern analysis, caching, SOSL execution, and result scoring components. It provides a clean, simplified interface
 * for search operations while encapsulating complex logic for optimization and result processing.
 *
 * Key Responsibilities:
 *   - Orchestrates search workflow from query to ranked results
 *   - Integrates pattern analysis for optimized search strategies
 *   - Leverages caching for performance optimization
 *   - Coordinates result scoring and ranking
 *   - Handles security validation and field accessibility
 */
public class SearchService {
    private static final Integer SOSL_QUERY_LIMIT = 50;

    public class SearchConfiguration {
        public Map<String, List<String>> configuredReturnFields;
        public Map<String, ResultScoringService.ScoringInfo> scoringConfig;
        public Integer maxAmbiguousResults;

        public SearchConfiguration(
            Map<String, List<String>> returnFields,
            Map<String, ResultScoringService.ScoringInfo> scoringConfig,
            Integer maxAmbiguousResults
        ) {
            this.configuredReturnFields = returnFields;
            this.scoringConfig = scoringConfig;
            this.maxAmbiguousResults = maxAmbiguousResults;
        }
    }

    public class SearchResult {
        public String resultType;
        public String message;
        public Map<String, Object> record;
        public List<Map<String, String>> options;
        public Map<String, Object> metadata;

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

    /**
     * @description
     * Performs intelligent entity search with pattern analysis, caching, and result scoring.
     *
     * @param searchQuery The search query string
     * @param sObjectTypes Optional list of SObject types to limit search scope
     * @param config Search configuration including field mappings and scoring info
     * @param userId Current user ID for cache isolation
     * @return SearchResult with processed and ranked results
     */
    public static SearchResult performSearch(String searchQuery, List<String> sObjectTypes, SearchConfiguration config, Id userId) {
        Long startTime = System.currentTimeMillis();

        // Analyze search pattern for optimal query strategy
        SearchPatternAnalyzer.SearchAnalysis patternAnalysis = SearchPatternAnalyzer.analyzeSearchQuery(searchQuery);
        System.debug(
            LoggingLevel.INFO,
            '[SearchService] Search pattern: ' + patternAnalysis.primaryPattern + ' (confidence: ' + patternAnalysis.confidenceScore + '%)'
        );

        // Check cache for performance
        String cacheKey = SearchResultCache.generateCacheKey(searchQuery, sObjectTypes, userId);
        SearchResultCache.CachedSearchResult cachedResult = SearchResultCache.getCachedResults(cacheKey);

        List<List<SObject>> searchResults;
        if (cachedResult != null) {
            System.debug(LoggingLevel.INFO, '[SearchService] Cache hit for key: ' + cacheKey);
            searchResults = cachedResult.searchResults;
            patternAnalysis = cachedResult.patternAnalysis;
        } else {
            System.debug(LoggingLevel.INFO, '[SearchService] Cache miss for key: ' + cacheKey + '. Executing new search.');
            Map<String, List<String>> accessibleReturnFields = buildAccessibleReturnFieldMap(sObjectTypes, config.configuredReturnFields);
            searchResults = executeOptimizedSearch(searchQuery, accessibleReturnFields, patternAnalysis);
            SearchResultCache.cacheResults(cacheKey, searchResults, patternAnalysis);
        }

        // Ensure we have full records with all fields populated
        List<List<SObject>> fullRecordsResults = new List<List<SObject>>();
        for (List<SObject> sObjectList : searchResults) {
            List<SObject> fullRecordsList = new List<SObject>();
            for (SObject sObj : sObjectList) {
                // If the record only has an ID (which happens in tests with Test.setFixedSearchResults),
                // query for the full record with all configured fields
                if (sObj.getPopulatedFieldsAsMap().size() <= 1) {
                    // Only ID is populated
                    SObjectType sObjType = sObj.getSObjectType();
                    String sObjName = sObjType.getDescribe().getName();
                    List<String> fieldsToQuery = config.configuredReturnFields.get(sObjName);
                    if (fieldsToQuery != null && !fieldsToQuery.isEmpty()) {
                        String query = 'SELECT ' + String.join(fieldsToQuery, ', ') + ' FROM ' + sObjName + ' WHERE Id = \'' + sObj.Id + '\'';
                        try {
                            List<SObject> fullRecords = Database.query(query);
                            if (!fullRecords.isEmpty()) {
                                fullRecordsList.add(fullRecords[0]);
                            } else {
                                fullRecordsList.add(sObj); // Fallback to original record
                            }
                        } catch (Exception e) {
                            fullRecordsList.add(sObj); // Fallback to original record
                        }
                    } else {
                        fullRecordsList.add(sObj); // Fallback to original record
                    }
                } else {
                    fullRecordsList.add(sObj);
                }
            }
            fullRecordsResults.add(fullRecordsList);
        }

        List<ResultScoringService.ScoredResult> rankedResults = ResultScoringService.scoreAndRankResults(
            fullRecordsResults,
            searchQuery,
            patternAnalysis,
            config.scoringConfig
        );

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(LoggingLevel.INFO, '[SearchService] Search completed in ' + executionTime + ' ms. Results: ' + rankedResults.size());

        return processRankedResults(rankedResults, config.maxAmbiguousResults);
    }

    private static Map<String, List<String>> buildAccessibleReturnFieldMap(
        List<String> sObjectTypesFromArgs,
        Map<String, List<String>> configuredReturnFields
    ) {
        Map<String, List<String>> accessibleMap = new Map<String, List<String>>();
        Set<String> targetSObjectNames = (sObjectTypesFromArgs != null && !sObjectTypesFromArgs.isEmpty())
            ? new Set<String>(sObjectTypesFromArgs)
            : configuredReturnFields.keySet();

        for (String sObjName : targetSObjectNames) {
            if (!configuredReturnFields.containsKey(sObjName))
                continue;

            SObjectType sObjType = SchemaUtils.getSObjectType(sObjName);
            if (sObjType != null && sObjType.getDescribe().isAccessible()) {
                List<String> accessibleFields = new List<String>();
                for (String fieldName : configuredReturnFields.get(sObjName)) {
                    if (SecurityUtils.hasFieldPermission(sObjType, fieldName, AccessType.READABLE)) {
                        accessibleFields.add(fieldName);
                    }
                }
                if (!accessibleFields.isEmpty()) {
                    accessibleMap.put(sObjName, accessibleFields);
                }
            }
        }

        return accessibleMap;
    }

    private static List<List<SObject>> executeOptimizedSearch(
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
            System.debug(LoggingLevel.INFO, '[SearchService] Executing SOSL (' + soslScope + '): ' + soslQuery);
            List<List<SObject>> searchResults = Search.query(soslQuery);
            for (String optimizationHint : patternAnalysis.optimizationHints) {
                System.debug(LoggingLevel.DEBUG, '[SearchService] Optimization hint: ' + optimizationHint);
            }
            return searchResults;
        } catch (SearchException se) {
            if (!soslScope.equals('ALL FIELDS')) {
                System.debug(LoggingLevel.WARN, '[SearchService] SOSL scope ' + soslScope + ' failed, falling back to ALL FIELDS.');
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

    private static String buildSoslReturningClause(Map<String, List<String>> accessibleReturnFields) {
        List<String> returningParts = new List<String>();
        for (String sObjName : accessibleReturnFields.keySet()) {
            String fields = String.join(accessibleReturnFields.get(sObjName), ', ');
            returningParts.add(sObjName + '(' + fields + ')');
        }
        return String.join(returningParts, ', ');
    }

    private static SearchResult processRankedResults(List<ResultScoringService.ScoredResult> rankedResults, Integer maxAmbiguousResults) {
        if (rankedResults.isEmpty()) {
            return new SearchResult('NOT_FOUND', 'No matching records found.', null, null);
        }

        if (rankedResults.size() == 1 || (rankedResults[0].score > rankedResults[1].score + (100 / 2))) {
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
        for (Integer i = 0; i < Math.min(rankedResults.size(), maxAmbiguousResults); i++) {
            ResultScoringService.ScoredResult res = rankedResults[i];
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

    private static Map<String, Object> buildRecordDataMap(SObject record) {
        Map<String, Object> recordData = new Map<String, Object>();
        recordData.put('sObjectType', record.getSObjectType().getDescribe().getName());

        // Handle special case for Contact Name field
        String sObjectName = record.getSObjectType().getDescribe().getName();
        if (sObjectName == 'Contact') {
            // For Contacts, explicitly add FirstName, LastName, and construct Name
            if (record.isSet('FirstName') && record.isSet('LastName')) {
                String firstName = (String) record.get('FirstName');
                String lastName = (String) record.get('LastName');
                recordData.put('FirstName', firstName);
                recordData.put('LastName', lastName);
                recordData.put('Name', firstName + ' ' + lastName);
            } else if (record.isSet('FirstName')) {
                recordData.put('FirstName', record.get('FirstName'));
                recordData.put('Name', record.get('FirstName'));
            } else if (record.isSet('LastName')) {
                recordData.put('LastName', record.get('LastName'));
                recordData.put('Name', record.get('LastName'));
            }

            // Add other fields
            for (String field : record.getPopulatedFieldsAsMap().keySet()) {
                if (field != 'FirstName' && field != 'LastName') {
                    recordData.put(field, record.get(field));
                }
            }
        } else {
            // For other objects, use the default behavior
            for (String field : record.getPopulatedFieldsAsMap().keySet()) {
                recordData.put(field, record.get(field));
            }
        }

        return recordData;
    }
}
