/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Advanced query pattern analysis for AI agent optimization.
 *              Analyzes filter patterns to determine optimal execution strategies.
 *              Provides performance hints and execution path recommendations.
 */
public class QueryPatternAnalyzer {
    /**
     * @description Query complexity patterns for optimization routing
     */
    public enum QueryPattern {
        SIMPLE_LOOKUP,
        SIMPLE_RANGE,
        MULTI_FIELD_AND,
        DATE_RANGE_QUERY,
        TEXT_SEARCH,
        IN_LIST_QUERY,
        COMPLEX_MIXED,
        EMPTY_QUERY
    }

    /**
     * @description Analysis result containing pattern and optimization hints
     */
    public class PatternAnalysis {
        public QueryPattern pattern;
        public Boolean canUseSimplePath;
        public List<String> optimizationHints;
        public Map<String, Object> metadata;
        public Integer complexityScore;

        public PatternAnalysis(QueryPattern pattern, Boolean canUseSimplePath) {
            this.pattern = pattern;
            this.canUseSimplePath = canUseSimplePath;
            this.optimizationHints = new List<String>();
            this.metadata = new Map<String, Object>();
            this.complexityScore = calculateComplexityScore(pattern);
        }

        private Integer calculateComplexityScore(QueryPattern pattern) {
            switch on pattern {
                when EMPTY_QUERY {
                    return 1;
                }
                when SIMPLE_LOOKUP {
                    return 2;
                }
                when SIMPLE_RANGE {
                    return 3;
                }
                when DATE_RANGE_QUERY {
                    return 4;
                }
                when TEXT_SEARCH {
                    return 5;
                }
                when IN_LIST_QUERY {
                    return 6;
                }
                when MULTI_FIELD_AND {
                    return 7;
                }
                when COMPLEX_MIXED {
                    return 10;
                }
                when else {
                    return 8;
                }
            }
        }
    }

    /**
     * @description Analyzes filter patterns to determine optimal execution strategy
     * @param filters The filter map from the query request
     * @param orderBy The ORDER BY clause (if any)
     * @param fieldMap The field metadata map for validation context
     * @return PatternAnalysis containing optimization recommendations
     */
    public static PatternAnalysis analyzeQuery(Map<String, Object> filters, String orderBy, Map<String, Schema.SObjectField> fieldMap) {
        if (filters == null || filters.isEmpty()) {
            PatternAnalysis analysis = new PatternAnalysis(QueryPattern.EMPTY_QUERY, true);
            analysis.optimizationHints.add('Consider adding filters to improve performance');
            if (String.isNotBlank(orderBy)) {
                analysis.optimizationHints.add('ORDER BY on full table scan - ensure indexed field');
            }
            return analysis;
        }

        Integer filterCount = filters.size();
        Boolean hasComplexOperators = hasComplexOperators(filters);
        Boolean hasTextSearch = hasTextSearchOperators(filters);
        Boolean hasDateRange = hasDateRangeFilters(filters, fieldMap);
        Boolean hasInOperators = hasInOperators(filters);

        QueryPattern detectedPattern = detectPattern(filterCount, hasComplexOperators, hasTextSearch, hasDateRange, hasInOperators, filters);

        Boolean canUseSimplePath = canUseSimpleExecutionPath(detectedPattern, orderBy, filterCount);

        PatternAnalysis analysis = new PatternAnalysis(detectedPattern, canUseSimplePath);

        addOptimizationHints(analysis, filters, orderBy, fieldMap);

        analysis.metadata.put('filterCount', filterCount);
        analysis.metadata.put('hasComplexOperators', hasComplexOperators);
        analysis.metadata.put('hasTextSearch', hasTextSearch);
        analysis.metadata.put('hasDateRange', hasDateRange);
        analysis.metadata.put('hasOrderBy', String.isNotBlank(orderBy));

        return analysis;
    }

    /**
     * @description Detects the primary query pattern based on filter characteristics
     */
    private static QueryPattern detectPattern(
        Integer filterCount,
        Boolean hasComplexOperators,
        Boolean hasTextSearch,
        Boolean hasDateRange,
        Boolean hasInOperators,
        Map<String, Object> filters
    ) {
        if (filterCount == 1) {
            if (hasInOperators)
                return QueryPattern.IN_LIST_QUERY;
            if (hasTextSearch)
                return QueryPattern.TEXT_SEARCH;
            if (hasDateRange)
                return QueryPattern.DATE_RANGE_QUERY;
            if (hasComplexOperators)
                return QueryPattern.SIMPLE_RANGE;
            return QueryPattern.SIMPLE_LOOKUP;
        }

        if (filterCount <= 4 && !hasComplexOperators && !hasTextSearch) {
            return QueryPattern.MULTI_FIELD_AND;
        }

        if (hasDateRange && filterCount <= 3) {
            return QueryPattern.DATE_RANGE_QUERY;
        }

        return QueryPattern.COMPLEX_MIXED;
    }

    /**
     * @description Determines if query can use simplified execution path
     */
    private static Boolean canUseSimpleExecutionPath(QueryPattern pattern, String orderBy, Integer filterCount) {
        Boolean simplePattern =
            pattern == QueryPattern.SIMPLE_LOOKUP ||
            pattern == QueryPattern.SIMPLE_RANGE ||
            pattern == QueryPattern.MULTI_FIELD_AND ||
            pattern == QueryPattern.EMPTY_QUERY;

        Boolean simpleOrderBy = String.isBlank(orderBy) || !orderBy.containsIgnoreCase('NULLS');
        Boolean reasonableFilterCount = filterCount <= 3;

        return simplePattern && simpleOrderBy && reasonableFilterCount;
    }

    /**
     * @description Adds specific optimization hints based on query analysis
     */
    private static void addOptimizationHints(
        PatternAnalysis analysis,
        Map<String, Object> filters,
        String orderBy,
        Map<String, Schema.SObjectField> fieldMap
    ) {
        switch on analysis.pattern {
            when SIMPLE_LOOKUP {
                analysis.optimizationHints.add('Optimal for indexed field lookups');
                checkForIndexedFields(analysis, filters, fieldMap);
            }
            when DATE_RANGE_QUERY {
                analysis.optimizationHints.add('Consider using selective date ranges');
                analysis.optimizationHints.add('Ensure date fields are indexed for performance');
            }
            when TEXT_SEARCH {
                analysis.optimizationHints.add('LIKE operations can be expensive - consider SOSL for full-text search');
                analysis.optimizationHints.add('Use leading wildcards sparingly');
            }
            when IN_LIST_QUERY {
                checkInListSize(analysis, filters);
            }
            when MULTI_FIELD_AND {
                analysis.optimizationHints.add('Multiple AND conditions - ensure most selective filter is first');
                suggestFilterOrdering(analysis, filters, fieldMap);
            }
            when COMPLEX_MIXED {
                analysis.optimizationHints.add('Complex query detected - full validation path required');
                analysis.optimizationHints.add('Consider breaking into multiple simpler queries if possible');
            }
        }

        if (String.isNotBlank(orderBy)) {
            analysis.optimizationHints.add('ORDER BY detected - ensure sort field is indexed');
        }
    }

    /**
     * @description Checks for indexed fields in filters
     */
    private static void checkForIndexedFields(PatternAnalysis analysis, Map<String, Object> filters, Map<String, Schema.SObjectField> fieldMap) {
        for (String fieldName : filters.keySet()) {
            Schema.SObjectField field = fieldMap.get(fieldName.toLowerCase());
            if (field != null) {
                Schema.DescribeFieldResult dfr = field.getDescribe();
                if (dfr.isIdLookup() || dfr.isUnique() || dfr.getType() == DisplayType.ID) {
                    analysis.optimizationHints.add('Using indexed field: ' + fieldName);
                    break;
                }
            }
        }
    }

    /**
     * @description Checks IN list sizes and provides recommendations
     */
    private static void checkInListSize(PatternAnalysis analysis, Map<String, Object> filters) {
        for (Object filterValue : filters.values()) {
            if (filterValue instanceof Map<String, Object>) {
                Map<String, Object> complexFilter = (Map<String, Object>) filterValue;
                Object inValue = complexFilter.get('IN');
                if (inValue instanceof List<Object>) {
                    Integer listSize = ((List<Object>) inValue).size();
                    if (listSize > 200) {
                        analysis.optimizationHints.add('Large IN list detected (' + listSize + ' items) - consider chunking');
                    } else if (listSize > 50) {
                        analysis.optimizationHints.add('Medium IN list (' + listSize + ' items) - monitor performance');
                    }
                }
            }
        }
    }

    /**
     * @description Suggests optimal filter ordering for performance
     */
    private static void suggestFilterOrdering(PatternAnalysis analysis, Map<String, Object> filters, Map<String, Schema.SObjectField> fieldMap) {
        List<String> selectiveFields = new List<String>();

        for (String fieldName : filters.keySet()) {
            Schema.SObjectField field = fieldMap.get(fieldName.toLowerCase());
            if (field != null) {
                Schema.DescribeFieldResult dfr = field.getDescribe();
                if (dfr.isIdLookup() || dfr.isUnique() || dfr.getType() == DisplayType.ID) {
                    selectiveFields.add(fieldName);
                }
            }
        }

        if (!selectiveFields.isEmpty()) {
            analysis.optimizationHints.add('Most selective fields detected: ' + String.join(selectiveFields, ', '));
        }
    }

    private static Boolean hasComplexOperators(Map<String, Object> filters) {
        for (Object filterValue : filters.values()) {
            if (filterValue instanceof Map<String, Object>) {
                Map<String, Object> complexFilter = (Map<String, Object>) filterValue;
                for (String operator : complexFilter.keySet()) {
                    if (operator.toUpperCase() != '=' && operator.toUpperCase() != 'IN') {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    private static Boolean hasTextSearchOperators(Map<String, Object> filters) {
        for (Object filterValue : filters.values()) {
            if (filterValue instanceof Map<String, Object>) {
                Map<String, Object> complexFilter = (Map<String, Object>) filterValue;
                if (complexFilter.containsKey('LIKE')) {
                    return true;
                }
            }
        }
        return false;
    }

    private static Boolean hasDateRangeFilters(Map<String, Object> filters, Map<String, Schema.SObjectField> fieldMap) {
        for (String fieldName : filters.keySet()) {
            Schema.SObjectField field = fieldMap.get(fieldName.toLowerCase());
            if (field != null) {
                Schema.DisplayType fieldType = field.getDescribe().getType();
                if (fieldType == DisplayType.DATE || fieldType == DisplayType.DATETIME) {
                    return true;
                }
            }
        }
        return false;
    }

    private static Boolean hasInOperators(Map<String, Object> filters) {
        for (Object filterValue : filters.values()) {
            if (filterValue instanceof Map<String, Object>) {
                Map<String, Object> complexFilter = (Map<String, Object>) filterValue;
                if (complexFilter.containsKey('IN')) {
                    return true;
                }
            }
        }
        return false;
    }
}
