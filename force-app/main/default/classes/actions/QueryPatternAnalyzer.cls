/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * QueryPatternAnalyzer: Intelligent SOQL query pattern analyzer for AI-driven optimization and smart execution routing.
 *
 * This class analyzes SOQL query filters, field types, and structure to recommend the most efficient execution path.
 * It provides pattern detection, complexity scoring, and actionable optimization hints to enable smart routing between
 * simple and complex query validation paths. Designed for use by AI agents and developer tools to maximize query performance
 * and maintainability.
 *
 * Key Responsibilities:
 *   - Detects query patterns (e.g., simple lookup, range, multi-field, text search, etc.)
 *   - Scores query complexity and determines if a simple execution path is possible
 *   - Generates optimization hints and recommendations for query tuning
 *   - Surfaces metadata for monitoring, debugging, and AI-driven decision making
 */
public class QueryPatternAnalyzer {
    /**
     * @description
     * Enumeration of query complexity patterns for optimization routing and execution strategy selection.
     */
    public enum QueryPattern {
        SIMPLE_LOOKUP, // Single field equals (e.g., Id = 'xxx')
        SIMPLE_RANGE, // Single field range (e.g., Amount > 1000)
        MULTI_FIELD_AND, // Multiple AND conditions (2-4 fields)
        DATE_RANGE_QUERY, // Date/DateTime range queries
        TEXT_SEARCH, // LIKE operations on text fields
        IN_LIST_QUERY, // IN operator with lists
        COMPLEX_MIXED, // Complex combinations requiring full validation
        EMPTY_QUERY // No filters (full table scan with limit)
    }

    /**
     * @description
     * Result object containing detected query pattern, optimization hints, complexity score, and metadata.
     */
    public class PatternAnalysis {
        public QueryPattern pattern;
        public Boolean canUseSimplePath;
        public List<String> optimizationHints;
        public Map<String, Object> metadata;
        public Integer complexityScore; // 1-10 scale

        /**
         * @description
         * Constructs a PatternAnalysis result with detected pattern and execution path recommendation.
         * Calculates complexity score and initializes optimization hints and metadata.
         *
         * @param pattern Detected query pattern
         * @param canUseSimplePath Whether a simple execution path is recommended
         */
        public PatternAnalysis(QueryPattern pattern, Boolean canUseSimplePath) {
            this.pattern = pattern;
            this.canUseSimplePath = canUseSimplePath;
            this.optimizationHints = new List<String>();
            this.metadata = new Map<String, Object>();
            this.complexityScore = calculateComplexityScore(pattern);
        }

        /**
         * @description
         * Calculates a numeric complexity score (1-10) for the given query pattern.
         *
         * @param pattern QueryPattern to score
         * @return Integer complexity score (1=trivial, 10=most complex)
         */
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
     * @description
     * Analyzes query filters and structure to determine the optimal execution strategy.
     * Performs pattern detection, complexity scoring, and generates optimization hints for tuning.
     *
     * @param filters Map of field names to filter values (simple or complex operator maps)
     * @param orderBy ORDER BY clause string for additional complexity assessment
     * @param fieldMap SObject field metadata for type-aware analysis
     * @return PatternAnalysis with detected pattern, optimization hints, and execution recommendations
     */
    public static PatternAnalysis analyzeQuery(Map<String, Object> filters, String orderBy, Map<String, Schema.SObjectField> fieldMap) {
        // Handle empty query case: full table scan scenario
        if (filters == null || filters.isEmpty()) {
            PatternAnalysis analysis = new PatternAnalysis(QueryPattern.EMPTY_QUERY, true);
            analysis.optimizationHints.add('Consider adding filters to improve performance');
            if (String.isNotBlank(orderBy)) {
                analysis.optimizationHints.add('ORDER BY on full table scan - ensure indexed field');
            }
            System.debug(LoggingLevel.INFO, '[QueryPatternAnalyzer] Empty query detected. Full table scan with LIMIT is recommended.');
            return analysis;
        }

        Integer filterCount = filters.size();
        Boolean hasComplexOperators = hasComplexOperators(filters);
        Boolean hasTextSearch = hasTextSearchOperators(filters);
        Boolean hasDateRange = hasDateRangeFilters(filters, fieldMap);
        Boolean hasInOperators = hasInOperators(filters);

        // Detect primary query pattern based on filter characteristics
        QueryPattern detectedPattern = detectPattern(filterCount, hasComplexOperators, hasTextSearch, hasDateRange, hasInOperators, filters);

        // Determine execution path based on pattern complexity
        Boolean canUseSimplePath = canUseSimpleExecutionPath(detectedPattern, orderBy, filterCount);

        PatternAnalysis analysis = new PatternAnalysis(detectedPattern, canUseSimplePath);

        // Generate pattern-specific optimization recommendations
        addOptimizationHints(analysis, filters, orderBy, fieldMap);

        // Store analysis metadata for debugging and monitoring
        analysis.metadata.put('filterCount', filterCount);
        analysis.metadata.put('hasComplexOperators', hasComplexOperators);
        analysis.metadata.put('hasTextSearch', hasTextSearch);
        analysis.metadata.put('hasDateRange', hasDateRange);
        analysis.metadata.put('hasOrderBy', String.isNotBlank(orderBy));

        System.debug(
            LoggingLevel.DEBUG,
            '[QueryPatternAnalyzer] Pattern=' + detectedPattern + ', SimplePath=' + canUseSimplePath + ', ComplexityScore=' + analysis.complexityScore
        );

        return analysis;
    }

    /**
     * @description
     * Detects the primary query pattern based on filter characteristics and operator types.
     *
     * @param filterCount Number of filters
     * @param hasComplexOperators Whether complex operators are present
     * @param hasTextSearch Whether LIKE/text search is present
     * @param hasDateRange Whether date/datetime range is present
     * @param hasInOperators Whether IN operator is present
     * @param filters Map of filters
     * @return QueryPattern detected pattern
     */
    private static QueryPattern detectPattern(
        Integer filterCount,
        Boolean hasComplexOperators,
        Boolean hasTextSearch,
        Boolean hasDateRange,
        Boolean hasInOperators,
        Map<String, Object> filters
    ) {
        // Single field patterns
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

        // Multi-field patterns
        if (filterCount <= 4 && !hasComplexOperators && !hasTextSearch) {
            return QueryPattern.MULTI_FIELD_AND;
        }

        if (hasDateRange && filterCount <= 3) {
            return QueryPattern.DATE_RANGE_QUERY;
        }

        // Default to complex for anything else
        return QueryPattern.COMPLEX_MIXED;
    }

    /**
     * @description
     * Determines if the query can use a simplified execution path based on pattern, ORDER BY, and filter count.
     *
     * @param pattern Detected query pattern
     * @param orderBy ORDER BY clause string
     * @param filterCount Number of filters
     * @return Boolean true if simple path is recommended
     */
    private static Boolean canUseSimpleExecutionPath(QueryPattern pattern, String orderBy, Integer filterCount) {
        // Simple path criteria - only allow truly simple patterns
        Boolean simplePattern =
            pattern == QueryPattern.SIMPLE_LOOKUP ||
            pattern == QueryPattern.MULTI_FIELD_AND ||
            pattern == QueryPattern.EMPTY_QUERY;

        Boolean simpleOrderBy = String.isBlank(orderBy) || !orderBy.containsIgnoreCase('NULLS');
        Boolean reasonableFilterCount = filterCount <= 3;

        return simplePattern && simpleOrderBy && reasonableFilterCount;
    }

    /**
     * @description
     * Adds specific optimization hints to the PatternAnalysis result based on detected query pattern and structure.
     *
     * @param analysis PatternAnalysis result to update
     * @param filters Map of filters
     * @param orderBy ORDER BY clause string
     * @param fieldMap SObject field metadata
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

        // ORDER BY specific hints
        if (String.isNotBlank(orderBy)) {
            analysis.optimizationHints.add('ORDER BY detected - ensure sort field is indexed');
        }
    }

    /**
     * @description
     * Checks for indexed fields in filters and adds optimization hints if found.
     *
     * @param analysis PatternAnalysis result to update
     * @param filters Map of filters
     * @param fieldMap SObject field metadata
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
     * @description
     * Checks IN list sizes in filters and provides optimization recommendations for large lists.
     *
     * @param analysis PatternAnalysis result to update
     * @param filters Map of filters
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
     * @description
     * Suggests optimal filter ordering for performance based on selectivity and index usage.
     *
     * @param analysis PatternAnalysis result to update
     * @param filters Map of filters
     * @param fieldMap SObject field metadata
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

    // Helper methods for pattern detection and operator analysis
    /**
     * @description
     * Determines if any filter uses complex operators (not '=' or 'IN').
     *
     * @param filters Map of filters
     * @return Boolean true if complex operators are present
     */
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

    /**
     * @description
     * Determines if any filter uses a LIKE/text search operator.
     *
     * @param filters Map of filters
     * @return Boolean true if LIKE operator is present
     */
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

    /**
     * @description
     * Determines if any filter is on a date or datetime field (for date range detection).
     *
     * @param filters Map of filters
     * @param fieldMap SObject field metadata
     * @return Boolean true if date/datetime field is present
     */
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

    /**
     * @description
     * Determines if any filter uses the IN operator.
     *
     * @param filters Map of filters
     * @return Boolean true if IN operator is present
     */
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
