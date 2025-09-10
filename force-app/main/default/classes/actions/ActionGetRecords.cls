/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionGetRecords is a streamlined Apex action for querying Salesforce records with schema-driven parameter validation.
 *
 * Responsibilities:
 *   - Leverages BaseAgentAction's schema-driven parameter validation (no manual validation needed)
 *   - Enforces object and field-level security before executing queries
 *   - Handles field selection, filtering, sorting, and result limiting with detailed error handling
 *   - Returns structured, LLM-friendly result data and AI-friendly error messages for downstream use
 *
 * Scope:
 *   - Strictly focused on secure, flexible record retrieval for any SObject type specified in configuration.
 *   - Designed for maintainability, extensibility, and clarity, with detailed debug output and robust error handling.
 *
 * Configuration Example: {"objectApiName": "Contact", "defaultFields": ["Id", "Name"], "maxReturnToLLM": 10}
 * Parameters Example: {"filters": {"LastName": "Smith"}, "additionalFields": ["Phone"], "limit": 5, "orderBy": "LastName ASC"}
 *
 * @extends BaseAgentAction
 */
public class ActionGetRecords extends BaseAgentAction {
    private static final String CONFIG_KEY_OBJECT_API_NAME = 'objectApiName';
    private static final String CONFIG_KEY_DEFAULT_FIELDS = 'defaultFields';
    private static final String CONFIG_KEY_MAX_RETURN = 'maxReturnToLLM';

    private static final Integer DEFAULT_QUERY_LIMIT = 10;
    private static final Integer MAX_PERMITTED_LIMIT = 50;
    private static final Integer DEFAULT_MAX_RETURNED_TO_LLM = 10;

    // Configuration populated during parseActionConfiguration
    private String objectApiName;
    private List<String> defaultFields = new List<String>();
    private Integer maxReturnToLLM = DEFAULT_MAX_RETURNED_TO_LLM;
    private SObjectType targetSObjectType;

    /**
     * @description
     * Main entry point for record query. Parameters are pre-validated by BaseAgentAction's schema-driven processing.
     *
     * @param params Map<String, Object> - Pre-validated parameters: 'filters', 'additionalFields', 'limit', and 'orderBy'.
     * @return QueryResult - Contains found records and metadata.
     * @throws ValidationException or AIFriendlyQueryException for security or query errors.
     *
     * Side effects: Logs key steps, errors, and performance metrics for troubleshooting and monitoring.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Parameters are already validated and coerced by BaseAgentAction's schema-driven processing
        Map<String, Object> filters = (Map<String, Object>) params.get('filters');
        List<String> additionalFields = (List<String>) params.get('additionalFields');
        Integer queryLimit = (Integer) params.get('limit');
        String orderBy = (String) params.get('orderBy');

        // Apply defaults for optional parameters that weren't provided
        if (filters == null) {
            filters = new Map<String, Object>();
        }
        if (additionalFields == null) {
            additionalFields = new List<String>();
        }
        if (queryLimit == null) {
            queryLimit = DEFAULT_QUERY_LIMIT;
        }
        // Enforce maximum limit for security
        queryLimit = Math.min(queryLimit, MAX_PERMITTED_LIMIT);

        try {
            SecurityUtils.checkObjectPermission(this.targetSObjectType, AccessType.READABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
            System.debug(LoggingLevel.ERROR, '[ActionGetRecords] Security violation: ' + ase.getMessage());
            throw new AIFriendlyQueryException(
                ase.getMessage(),
                AIFriendlyQueryException.ErrorCode.SECURITY_VIOLATION,
                AIFriendlyQueryException.Severity.HIGH,
                'Grant read permission for ' + this.objectApiName + ' object to current user',
                null,
                this.objectApiName
            );
        }

        List<SObject> queryResults;
        Map<String, Object> bindMap = new Map<String, Object>();

        try {
            QueryService queryService = new QueryService(this.targetSObjectType, '[ActionGetRecords] ')
                .withDefaultFields(this.defaultFields)
                .withAdditionalFields(additionalFields)
                .withFilters(filters)
                .withOrderBy(orderBy)
                .withLimit(queryLimit, MAX_PERMITTED_LIMIT);

            queryResults = queryService.executeQuery(bindMap);
        } catch (AIFriendlyQueryException aie) {
            System.debug(LoggingLevel.ERROR, '[ActionGetRecords] AI-friendly query error: ' + aie.getErrorSummary());
            throw new ValidationException(aie.getMessage(), aie.fieldName);
        } catch (QueryService.QueryValidationException qve) {
            System.debug(LoggingLevel.ERROR, '[ActionGetRecords] QueryService validation failed: ' + qve.getMessage());
            throw new ValidationException(qve.getMessage(), null);
        } catch (System.QueryException qe) {
            String enhancedMessage = enhanceQueryExceptionMessage(qe.getMessage(), filters, orderBy, queryLimit);
            System.debug(LoggingLevel.ERROR, '[ActionGetRecords] SOQL execution failed: ' + enhancedMessage);
            throw qe;
        }

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(
            LoggingLevel.INFO,
            '[ActionGetRecords] Query completed in ' + executionTime + ' ms. Records found: ' + (queryResults != null ? queryResults.size() : 0)
        );

        return processQueryResults(queryResults);
    }

    /**
     * @description
     * Enhances query exception messages with contextual information for better troubleshooting.
     *
     * @param originalMessage String - Original exception message.
     * @param filters Map<String, Object> - Applied filter criteria.
     * @param orderBy String - Sort specification.
     * @param queryLimit Integer - Query limit value.
     * @return String - Enhanced error message with query context.
     */
    private String enhanceQueryExceptionMessage(String originalMessage, Map<String, Object> filters, String orderBy, Integer queryLimit) {
        String enhanced = originalMessage + ' | Query Context: Object=' + this.objectApiName;

        if (filters != null && !filters.isEmpty()) {
            enhanced += ', Filters=' + filters.size();
        }
        if (String.isNotBlank(orderBy)) {
            enhanced += ', OrderBy=' + orderBy;
        }
        enhanced += ', Limit=' + queryLimit;

        return enhanced;
    }

    /**
     * @description
     * Parses and validates the action configuration JSON. Extracts the target SObject type, default fields, and max return limit.
     *
     * @param actionConfigurationJson String - The JSON configuration string.
     * @param logPrefix String - Prefix for log output.
     * @throws ValidationException if required configuration is missing or invalid.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        this.objectApiName = ActionConfigUtils.getRequiredString(this.parsedActionConfig, CONFIG_KEY_OBJECT_API_NAME);

        this.targetSObjectType = SchemaUtils.getSObjectType(this.objectApiName);
        if (this.targetSObjectType == null) {
            throw new ValidationException('Invalid SObject API Name in configuration: ' + this.objectApiName, CONFIG_KEY_OBJECT_API_NAME);
        }

        this.defaultFields = ActionConfigUtils.getOptionalStringList(this.parsedActionConfig, CONFIG_KEY_DEFAULT_FIELDS);

        this.maxReturnToLLM = ActionConfigUtils.getOptionalInteger(this.parsedActionConfig, CONFIG_KEY_MAX_RETURN, DEFAULT_MAX_RETURNED_TO_LLM);
    }

    /**
     * @description
     * Processes query results, applies max return limit, and builds a user-facing message.
     *
     * @param queryResults List<SObject> - The raw query results.
     * @return QueryResult - Structured result with records, count, and metadata.
     */
    private QueryResult processQueryResults(List<SObject> queryResults) {
        Integer totalFoundCount = queryResults != null ? queryResults.size() : 0;
        List<SObject> finalResults = new List<SObject>();

        if (totalFoundCount > 0) {
            Integer countToReturn = Math.min(totalFoundCount, this.maxReturnToLLM);
            for (Integer i = 0; i < countToReturn; i++) {
                finalResults.add(queryResults.get(i));
            }

            if (totalFoundCount > this.maxReturnToLLM) {
                System.debug(
                    LoggingLevel.INFO,
                    '[ActionGetRecords] Truncated results: ' + totalFoundCount + ' found, returning ' + this.maxReturnToLLM + ' for LLM.'
                );
            }
        }

        String message;
        if (totalFoundCount == 0) {
            message = 'No ' + this.objectApiName + ' records found matching the criteria.';
        } else if (totalFoundCount > this.maxReturnToLLM) {
            message = 'Found ' + totalFoundCount + ' ' + this.objectApiName + ' record(s). Showing the first ' + this.maxReturnToLLM + '.';
        } else {
            message = 'Found and showing all ' + totalFoundCount + ' ' + this.objectApiName + ' record(s).';
        }

        System.debug(LoggingLevel.INFO, '[ActionGetRecords] ' + message);
        return new QueryResult(finalResults, totalFoundCount, this.objectApiName, message);
    }

    /**
     * @description
     * Result wrapper for query operations with record data and metadata. Provides structured data for both user display and LLM processing.
     *
     * Fields:
     *   - records: List<SObject> - The records returned by the query.
     *   - count: Integer - The total number of records found.
     *   - objectApiName: String - The SObject API name queried.
     *   - message: String - User-facing message summarizing the result.
     *   - truncated: Boolean - True if results were truncated for LLM.
     *   - metadata: Map<String, Object> - Additional context for downstream consumers.
     */
    public class QueryResult {
        public List<SObject> records;
        public Integer count;
        public String objectApiName;
        public String message; // Framework uses this for user display
        public Boolean truncated;
        public Map<String, Object> metadata; // Additional context for LLMs

        public QueryResult(List<SObject> records, Integer count, String objectApiName, String message) {
            this.records = records;
            this.count = count;
            this.objectApiName = objectApiName;
            this.message = message;
            this.truncated = records.size() < count;

            this.metadata = new Map<String, Object>{
                'totalFound' => count,
                'returned' => records.size(),
                'hasMore' => this.truncated,
                'objectType' => objectApiName
            };
        }
    }
}
