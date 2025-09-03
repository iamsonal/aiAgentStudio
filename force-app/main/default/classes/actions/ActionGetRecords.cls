/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionGetRecords is a robust Apex action for querying Salesforce records with intelligent parameter processing, comprehensive validation, and security enforcement.
 *
 * Responsibilities:
 *   - Validates and extracts query parameters, including filters, fields, sorting, and limits.
 *   - Enforces object and field-level security before executing queries.
 *   - Handles field selection, filtering, sorting, and result limiting with detailed error handling.
 *   - Returns structured, LLM-friendly result data and AI-friendly error messages for downstream use.
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
     * Main entry point for record query. Validates parameters, enforces security, executes the query, and formats results.
     *
     * @param params Map<String, Object> - May include 'filters', 'additionalFields', 'limit', and 'orderBy'.
     * @return QueryResult - Contains found records and metadata.
     * @throws ValidationException or AIFriendlyQueryException for parameter, security, or query errors.
     *
     * Side effects: Logs key steps, errors, and performance metrics for troubleshooting and monitoring.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        Map<String, Object> filters = ParameterExtractionUtils.getOptionalMap(params, 'filters');
        List<String> additionalFields = ParameterExtractionUtils.getOptionalStringList(params, 'additionalFields');
        Integer queryLimit = validateAndCoerceLimit(params.get('limit'));
        String orderBy = ParameterExtractionUtils.getOptionalString(params, 'orderBy');

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

        QueryResult result = processQueryResults(queryResults);

        // SECURITY: Analyze retrieved records for prompt injection threats
        if (result.records != null && !result.records.isEmpty()) {
            analyzeRecordsForSecurity(result.records);
        }

        return result;
    }

    /**
     * @description
     * Validates and coerces the limit parameter with comprehensive error handling.
     *
     * @param limitObj Object - Raw limit value from parameters.
     * @return Integer - Valid integer limit within acceptable bounds.
     * @throws ValidationException if the limit is not a valid number or string.
     */
    private Integer validateAndCoerceLimit(Object limitObj) {
        if (limitObj == null)
            return DEFAULT_QUERY_LIMIT;

        if (limitObj instanceof Integer) {
            Integer queryLimit = (Integer) limitObj;
            return queryLimit <= 0 ? DEFAULT_QUERY_LIMIT : Math.min(queryLimit, MAX_PERMITTED_LIMIT);
        }

        if (limitObj instanceof String && String.isNotBlank((String) limitObj)) {
            try {
                Integer queryLimit = Integer.valueOf((String) limitObj);
                return queryLimit <= 0 ? DEFAULT_QUERY_LIMIT : Math.min(queryLimit, MAX_PERMITTED_LIMIT);
            } catch (Exception e) {
                throw new ValidationException('Parameter "limit" must be a valid Integer: ' + limitObj, 'limit');
            }
        }

        throw new ValidationException('Parameter "limit" must be a Number or numeric String: ' + limitObj, 'limit');
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

        if (this.parsedActionConfig == null || !this.parsedActionConfig.containsKey(CONFIG_KEY_OBJECT_API_NAME)) {
            throw new ValidationException('ActionConfiguration must contain "' + CONFIG_KEY_OBJECT_API_NAME + '"', CONFIG_KEY_OBJECT_API_NAME);
        }

        this.objectApiName = (String) this.parsedActionConfig.get(CONFIG_KEY_OBJECT_API_NAME);
        if (String.isBlank(this.objectApiName)) {
            throw new ValidationException('objectApiName cannot be blank', CONFIG_KEY_OBJECT_API_NAME);
        }

        this.targetSObjectType = Schema.getGlobalDescribe().get(this.objectApiName.toLowerCase());
        if (this.targetSObjectType == null) {
            throw new ValidationException('Invalid SObject API Name: ' + this.objectApiName, CONFIG_KEY_OBJECT_API_NAME);
        }

        if (this.parsedActionConfig.containsKey(CONFIG_KEY_DEFAULT_FIELDS)) {
            Object fieldsObj = this.parsedActionConfig.get(CONFIG_KEY_DEFAULT_FIELDS);
            if (fieldsObj instanceof List<Object>) {
                for (Object fieldObj : (List<Object>) fieldsObj) {
                    if (fieldObj instanceof String && String.isNotBlank((String) fieldObj)) {
                        this.defaultFields.add((String) fieldObj);
                    }
                }
            }
        }

        if (this.parsedActionConfig.containsKey(CONFIG_KEY_MAX_RETURN)) {
            Object maxReturnObj = this.parsedActionConfig.get(CONFIG_KEY_MAX_RETURN);
            if (maxReturnObj instanceof Integer && (Integer) maxReturnObj > 0) {
                this.maxReturnToLLM = (Integer) maxReturnObj;
            }
        }
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
     * Analyzes retrieved records for potential security threats in text fields
     *
     * @param records List of SObject records to analyze
     */
    private void analyzeRecordsForSecurity(List<SObject> records) {
        try {
            for (SObject record : records) {
                Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

                for (String fieldName : populatedFields.keySet()) {
                    Object fieldValue = populatedFields.get(fieldName);

                    // Only analyze string fields that could contain malicious content
                    if (fieldValue instanceof String && String.isNotBlank((String) fieldValue)) {
                        String textValue = (String) fieldValue;

                        // Skip very short values that are unlikely to contain injection attempts
                        if (textValue.length() < 20) {
                            continue;
                        }

                        PromptInjectionGuard.SecurityAnalysisResult securityResult = PromptInjectionGuard.analyzeContent(
                            textValue,
                            fieldName,
                            this.objectApiName,
                            null
                        );

                        if (!securityResult.isSafe) {
                            System.debug(
                                LoggingLevel.WARN,
                                '[ActionGetRecords] Security risk detected in retrieved record ' +
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
            System.debug(LoggingLevel.ERROR, '[ActionGetRecords] Error during security analysis: ' + e.getMessage());
        }
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
