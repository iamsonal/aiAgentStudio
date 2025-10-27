/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionGetRecords is a high-performance Apex action for querying Salesforce records using strongly-typed DTOs.
 *
 * Responsibilities:
 *   - Uses DTOs for type-safe argument and configuration handling
 *   - Enforces object and field-level security before executing queries
 *   - Handles field selection, filtering, sorting, and result limiting with detailed error handling
 *   - Returns structured, LLM-friendly result data and AI-friendly error messages for downstream use
 *
 * Architecture:
 *   - ArgumentsDTO: Strongly-typed with filters, additionalFields, limit, orderBy
 *   - ConfigDTO: Strongly-typed configuration with objectApiName, defaultFields, maxReturnToLLM
 *   - Uses native JSON.deserialize() for high-performance type conversion
 *
 * @extends BaseAgentAction
 */
public class ActionGetRecords extends BaseAgentAction {
    private static final Integer DEFAULT_QUERY_LIMIT = 10;
    private static final Integer MAX_PERMITTED_LIMIT = 50;
    private static final Integer DEFAULT_MAX_RETURNED_TO_LLM = 10;

    private ConfigDTO config;
    private SObjectType targetSObjectType;

    // Dependency injection for QueryService
    private QueryService queryService;

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        public Map<String, Object> filters;
        public List<String> additionalFields;
        public Integer queryLimit;
        public String orderBy;
    }

    /**
     * DTO for strongly-typed backend configuration
     */
    public class ConfigDTO {
        public String objectApiName;
        public List<String> defaultFields;
        public Integer maxReturnToLLM;
    }

    /**
     * @description
     * Constructor that accepts a QueryService dependency for testing and flexibility.
     *
     * @param queryService The QueryService instance to use for executing queries
     */
    public ActionGetRecords(QueryService queryService) {
        this.queryService = queryService;
    }

    /**
     * @description
     * Default constructor that creates a new QueryService instance.
     */
    public ActionGetRecords() {
        // Default constructor - will create QueryService in executeAction
    }

    /**
     * @description
     * Main entry point for record query using strongly-typed DTOs.
     *
     * @param params Map<String, Object> - Raw parameters (deserialized into ArgumentsDTO for type safety)
     * @return ActionOutcome<QueryResult> - Contains found records and metadata or error information
     *
     * Side effects: Logs key steps, errors, and performance metrics for troubleshooting and monitoring
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();
        args.filters = params.get('filters') != null ? (Map<String, Object>) params.get('filters') : new Map<String, Object>();
        args.additionalFields = ActionConfigUtils.getOptionalStringList(params, 'additionalFields');
        args.queryLimit = params.get('queryLimit') != null ? Integer.valueOf(params.get('queryLimit')) : DEFAULT_QUERY_LIMIT;
        args.orderBy = (String) params.get('orderBy');

        // Enforce maximum limit for security
        args.queryLimit = Math.min(args.queryLimit, MAX_PERMITTED_LIMIT);

        try {
            SecurityUtils.checkObjectPermission(this.targetSObjectType, AccessType.READABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
            System.debug(LoggingLevel.ERROR, '[ActionGetRecords] Security violation: ' + ase.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ase.getMessage());
        }

        List<SObject> queryResults;
        Map<String, Object> bindMap = new Map<String, Object>();

        try {
            // Create QueryService if not injected
            if (this.queryService == null) {
                this.queryService = new QueryService(this.targetSObjectType, '[ActionGetRecords] ');
            }

            this.queryService
                .withDefaultFields(config.defaultFields != null ? config.defaultFields : new List<String>())
                .withAdditionalFields(args.additionalFields)
                .withFilters(args.filters)
                .withOrderBy(args.orderBy)
                .withLimit(args.queryLimit, MAX_PERMITTED_LIMIT);

            QueryResult queryResult = this.queryService.executeQuery(bindMap);
            if (!queryResult.isSuccess) {
                return ActionOutcome.failure(queryResult.errorCode, queryResult.errorMessage);
            }

            // Extract the records from QueryResult
            queryResults = queryResult.records;
        } catch (System.QueryException qe) {
            String enhancedMessage = enhanceQueryExceptionMessage(qe.getMessage(), args.filters, args.orderBy, args.queryLimit);
            System.debug(LoggingLevel.ERROR, '[ActionGetRecords] SOQL execution failed: ' + enhancedMessage);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, enhancedMessage);
        }

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(
            LoggingLevel.INFO,
            '[ActionGetRecords] Query completed in ' + executionTime + ' ms. Records found: ' + (queryResults != null ? queryResults.size() : 0)
        );

        return ActionOutcome.success(processQueryResults(queryResults));
    }

    /**
     * @description
     * Enhances query exception messages with contextual information for better troubleshooting.
     *
     * @param originalMessage String - Original exception message
     * @param filters Map<String, Object> - Applied filter criteria
     * @param orderBy String - Sort specification
     * @param queryLimit Integer - Query limit value
     * @return String - Enhanced error message with query context
     */
    private String enhanceQueryExceptionMessage(String originalMessage, Map<String, Object> filters, String orderBy, Integer queryLimit) {
        String enhanced = originalMessage + ' | Query Context: Object=' + config.objectApiName;

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
     * Parses and validates the action configuration JSON using strongly-typed ConfigDTO.
     * Extracts the target SObject type, default fields, and max return limit.
     * Also validates that defaultFields are valid fields on the configured objectApiName.
     *
     * @param actionConfigurationJson String - The JSON configuration string
     * @param logPrefix String - Prefix for log output
     * @throws ValidationException if required configuration is missing or invalid
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        // Parse config using hybrid approach for consistency
        try {
            if (String.isBlank(actionConfigurationJson)) {
                throw new ValidationException('Configuration JSON is required', null);
            }

            // First deserialize as untyped map
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

            // Then manually populate ConfigDTO
            this.config = new ConfigDTO();
            this.config.objectApiName = (String) configMap.get('objectApiName');
            this.config.defaultFields = ActionConfigUtils.getOptionalStringList(configMap, 'defaultFields');
            this.config.maxReturnToLLM = configMap.get('maxReturnToLLM') != null ? Integer.valueOf(configMap.get('maxReturnToLLM')) : null;
        } catch (Exception e) {
            throw new ValidationException('Invalid configuration JSON: ' + e.getMessage(), e);
        }

        // Validate required fields
        if (String.isBlank(config.objectApiName)) {
            throw new ValidationException('objectApiName is required in configuration', 'objectApiName');
        }

        this.targetSObjectType = SchemaUtils.getSObjectType(config.objectApiName);
        if (this.targetSObjectType == null) {
            throw new ValidationException('Invalid SObject API Name in configuration: ' + config.objectApiName, 'objectApiName');
        }

        // Initialize optional fields with defaults
        if (config.defaultFields == null) {
            config.defaultFields = new List<String>();
        }
        if (config.maxReturnToLLM == null) {
            config.maxReturnToLLM = DEFAULT_MAX_RETURNED_TO_LLM;
        }

        // Validate that defaultFields are valid fields on the configured object
        if (!config.defaultFields.isEmpty()) {
            QueryService validatorService = new QueryService(this.targetSObjectType, '[ActionGetRecords] ');
            QueryResult validationResult = validatorService.validateFields(config.defaultFields);
            if (!validationResult.isSuccess) {
                throw new ValidationException(validationResult.errorMessage, 'defaultFields');
            }
        }
    }

    /**
     * @description
     * Processes query results, applies max return limit, and builds a user-facing message.
     *
     * @param queryResults List<SObject> - The raw query results
     * @return GetRecordsResult - Structured result with records, count, and metadata
     */
    private GetRecordsResult processQueryResults(List<SObject> queryResults) {
        Integer totalFoundCount = queryResults != null ? queryResults.size() : 0;
        List<SObject> finalResults = new List<SObject>();

        if (totalFoundCount > 0) {
            Integer countToReturn = Math.min(totalFoundCount, config.maxReturnToLLM);
            for (Integer i = 0; i < countToReturn; i++) {
                finalResults.add(queryResults.get(i));
            }

            if (totalFoundCount > config.maxReturnToLLM) {
                System.debug(
                    LoggingLevel.INFO,
                    '[ActionGetRecords] Truncated results: ' + totalFoundCount + ' found, returning ' + config.maxReturnToLLM + ' for LLM.'
                );
            }
        }

        String message;
        if (totalFoundCount == 0) {
            message = 'No ' + config.objectApiName + ' records found matching the criteria.';
        } else if (totalFoundCount > config.maxReturnToLLM) {
            message = 'Found ' + totalFoundCount + ' ' + config.objectApiName + ' record(s). Showing the first ' + config.maxReturnToLLM + '.';
        } else {
            message = 'Found and showing all ' + totalFoundCount + ' ' + config.objectApiName + ' record(s).';
        }

        System.debug(LoggingLevel.INFO, '[ActionGetRecords] ' + message);
        return new GetRecordsResult(finalResults, totalFoundCount, config.objectApiName, message);
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
    public class GetRecordsResult {
        public List<SObject> records;
        public Integer count;
        public String objectApiName;
        public String message; // Framework uses this for user display
        public Boolean truncated;
        public Map<String, Object> metadata; // Additional context for LLMs

        public GetRecordsResult(List<SObject> records, Integer count, String objectApiName, String message) {
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
