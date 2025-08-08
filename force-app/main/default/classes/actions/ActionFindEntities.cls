/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Performs intelligent fuzzy search for records using SOSL with pattern analysis.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *              Configured via SObjectConfig__mdt Custom Metadata Type for searchable objects and scoring.
 *
 *              MAINTAINS: Advanced pattern analysis, caching, security checks, and comprehensive scoring.
 *              ENHANCED: Simplified interface while preserving all robustness features.
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
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction and validation.
     *              ENHANCED: Maintains all advanced functionality while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        String searchQuery = (String) params.get('searchQuery');
        List<String> sObjectTypes = (List<String>) params.get('sObjectTypes');

        if (String.isBlank(searchQuery)) {
            throw new ValidationException('Search query cannot be blank', 'searchQuery');
        }

        SearchPatternAnalyzer.SearchAnalysis patternAnalysis = SearchPatternAnalyzer.analyzeSearchQuery(searchQuery);

        String cacheKey = SearchResultCache.generateCacheKey(searchQuery, sObjectTypes, UserInfo.getUserId());
        SearchResultCache.CachedSearchResult cachedResult = SearchResultCache.getCachedResults(cacheKey);

        List<List<SObject>> searchResults;
        if (cachedResult != null) {
            searchResults = cachedResult.searchResults;
            patternAnalysis = cachedResult.patternAnalysis;
        } else {
            try {
                Map<String, List<String>> accessibleReturnFields = buildAccessibleReturnFieldMap(sObjectTypes);
                searchResults = executeOptimizedSearch(searchQuery, accessibleReturnFields, patternAnalysis);
                SearchResultCache.cacheResults(cacheKey, searchResults, patternAnalysis);
            } catch (ActionSecurityException ase) {
                throw ase;
            }
        }

        List<ScoredResult> rankedResults = scoreAndRankResults(searchResults, searchQuery, patternAnalysis);

        Long executionTime = System.currentTimeMillis() - startTime;

        logCachePerformanceMetrics();

        return processRankedResults(rankedResults);
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (MDT_CACHE == null) {
            try {
                MDT_CACHE = [
                    SELECT SObjectAPIName__c, PrimaryNameField__c, KeyIdentifierFields__c
                    FROM SObjectConfig__mdt
                    WHERE IsActive__c = TRUE
                ];
            } catch (Exception e) {
                throw new ValidationException('Failed to query SObjectConfig__mdt records: ' + e.getMessage(), null, e);
            }
        } else {
        }

        if (MDT_CACHE.isEmpty()) {
            throw new ValidationException('No active SObjectConfig__mdt records found. Please configure searchable objects.', null);
        }

        for (SObjectConfig__mdt config : MDT_CACHE) {
            String sObjApiName = config.SObjectAPIName__c;
            if (String.isBlank(sObjApiName) || String.isBlank(config.PrimaryNameField__c)) {
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

        if (this.parsedActionConfig?.containsKey(CONFIG_MAX_AMBIGUOUS_RESULTS)) {
            Object maxResults = this.parsedActionConfig.get(CONFIG_MAX_AMBIGUOUS_RESULTS);
            if (maxResults instanceof Integer) {
                this.maxAmbiguousResults = (Integer) maxResults;
            }
        }
    }

    /**
     * @description Logs cache performance metrics for monitoring and optimization
     */
    private void logCachePerformanceMetrics() {
        if (Math.mod(System.currentTimeMillis(), 10) == 0) {
            SearchResultCache.CacheStatistics stats = SearchResultCache.getCacheStatistics();
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
            List<List<SObject>> searchResults = Search.query(soslQuery);

            for (String optimizationHint : patternAnalysis.optimizationHints) {
            }

            return searchResults;
        } catch (SearchException se) {
            if (!soslScope.equals('ALL FIELDS')) {
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

    private Map<String, Object> buildRecordDataMap(SObject record) {
        Map<String, Object> recordData = new Map<String, Object>();
        recordData.put('sObjectType', record.getSObjectType().getDescribe().getName());
        for (String field : record.getPopulatedFieldsAsMap().keySet()) {
            recordData.put(field, record.get(field));
        }
        return recordData;
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
            return otherResult.score - this.score;
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
