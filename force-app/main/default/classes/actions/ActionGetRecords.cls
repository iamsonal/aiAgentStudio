/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Standard Action: Queries Salesforce records based on configuration and LLM parameters.
 *              Extends BaseAgentAction for standardized execution flow and error handling.
 *              ActionConfiguration example: {"objectApiName": "Contact", "defaultFields": ["Id", "Name", "Email"], "maxReturnToLLM": 10}
 *              LLM Arguments example: {"filters": {"LastName": "Smith", "MailingCity": "SF"}, "additionalFields": ["Phone"], "limit": 5, "orderBy": "LastName ASC"}
 *              Supports various filter operators: =, !=, >, <, >=, <=, LIKE, IN
 *              Uses QueryService for safe SOQL building, FLS checks, and validation.
 * @extends BaseAgentAction
 * @see QueryService
 * @see SecurityUtils
 * @see ActionParamUtils
 */
public class ActionGetRecords extends BaseAgentAction {
    private static final String CONFIG_KEY_OBJECT_API_NAME = 'objectApiName';
    private static final String CONFIG_KEY_DEFAULT_FIELDS = 'defaultFields';
    private static final String CONFIG_KEY_MAX_RETURN = 'maxReturnToLLM';
    private static final String PARAM_KEY_FILTERS = 'filters';
    private static final String PARAM_KEY_ADDITIONAL_FIELDS = 'additionalFields';
    private static final String PARAM_KEY_LIMIT = 'limit';
    private static final String PARAM_KEY_ORDER_BY = 'orderBy';

    private static final Integer DEFAULT_QUERY_LIMIT = 10;
    private static final Integer MAX_PERMITTED_LIMIT = 50;
    @TestVisible
    private static final Integer DEFAULT_MAX_RETURNED_TO_LLM = 10;

    private String objectApiName;
    private List<String> defaultFields = new List<String>();
    private Integer maxReturnToLLM = DEFAULT_MAX_RETURNED_TO_LLM;
    private SObjectType targetSObjectType;

    /**
     * @description Provides a specific log prefix for this action type.
     * @return String 'ActionGetRecords'
     */
    protected override String getLogPrefixName() {
        return 'ActionGetRecords';
    }

    /**
     * @description Parses the ActionConfiguration JSON. Extracts objectApiName, defaultFields, maxReturnToLLM.
     *              Stores them in instance variables for use by performAction.
     * @param actionConfigurationJson The raw JSON string.
     * @param logPrefix Logging prefix.
     * @throws ValidationException if JSON is invalid or required 'objectApiName' is missing/invalid.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig == null || !this.parsedActionConfig.containsKey(CONFIG_KEY_OBJECT_API_NAME)) {
            throw new ValidationException(
                'ActionConfiguration JSON is required and must contain "' + CONFIG_KEY_OBJECT_API_NAME + '".',
                CONFIG_KEY_OBJECT_API_NAME
            );
        }

        Object apiNameObj = this.parsedActionConfig.get(CONFIG_KEY_OBJECT_API_NAME);
        if (!(apiNameObj instanceof String) || String.isBlank((String) apiNameObj)) {
            throw new ValidationException(
                'Required property "' +
                    CONFIG_KEY_OBJECT_API_NAME +
                    '" in ActionConfiguration must be a non-blank String.',
                CONFIG_KEY_OBJECT_API_NAME
            );
        }

        this.objectApiName = (String) apiNameObj;
        this.targetSObjectType = Schema.getGlobalDescribe().get(this.objectApiName.toLowerCase());
        if (this.targetSObjectType == null) {
            throw new ValidationException(
                'Invalid SObject API Name configured: ' + this.objectApiName,
                CONFIG_KEY_OBJECT_API_NAME
            );
        }

        if (this.parsedActionConfig.containsKey(CONFIG_KEY_DEFAULT_FIELDS)) {
            try {
                Object fieldsObj = this.parsedActionConfig.get(CONFIG_KEY_DEFAULT_FIELDS);
                if (fieldsObj instanceof List<Object>) {
                    for (Object fieldObj : (List<Object>) fieldsObj) {
                        if (fieldObj instanceof String && String.isNotBlank((String) fieldObj)) {
                            this.defaultFields.add((String) fieldObj);
                        }
                    }
                }
            } catch (Exception e) {
                this.defaultFields = new List<String>();
            }
        }

        if (this.parsedActionConfig.containsKey(CONFIG_KEY_MAX_RETURN)) {
            Object maxReturnObj = this.parsedActionConfig.get(CONFIG_KEY_MAX_RETURN);
            try {
                Decimal decVal = null;
                if (maxReturnObj instanceof Integer)
                    decVal = (Integer) maxReturnObj;
                else if (maxReturnObj instanceof Decimal)
                    decVal = (Decimal) maxReturnObj;
                else if (maxReturnObj instanceof String && String.isNotBlank((String) maxReturnObj))
                    decVal = Decimal.valueOf((String) maxReturnObj);

                if (decVal != null && decVal > 0) {
                    this.maxReturnToLLM = decVal.intValue();
                }
            } catch (Exception e) {
            }
        }
    }

    /**
     * @description Concrete implementation of ParsedArguments specific to ActionGetRecords.
     */
    class GetRecordsParsedArguments extends BaseAgentAction.ParsedArguments {
        Map<String, Object> filters;
        List<String> additionalFields;
        Integer queryLimit;
        String orderBy;

        public GetRecordsParsedArguments(
            Map<String, Object> filters,
            List<String> additionalFields,
            Integer queryLimit,
            String orderBy
        ) {
            this.filters = filters;
            this.additionalFields = additionalFields;
            this.queryLimit = queryLimit;
            this.orderBy = orderBy;
        }
    }

    /**
     * @description Parses and validates the LLM arguments specific to GetRecords.
     * @param argumentsJson Raw JSON string from the LLM.
     * @param logPrefix Logging prefix.
     * @return GetRecordsParsedArguments instance.
     * @throws ValidationException If arguments are invalid.
     */
    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(
        String argumentsJson,
        String logPrefix
    ) {
        Map<String, Object> parsedLlmArgs;
        try {
            parsedLlmArgs = String.isNotBlank(argumentsJson)
                ? (Map<String, Object>) JSON.deserializeUntyped(argumentsJson)
                : new Map<String, Object>();
        } catch (Exception e) {
            throw new ValidationException('Failed to parse LLM arguments JSON: ' + e.getMessage(), null);
        }

        Map<String, Object> filters = new Map<String, Object>();
        Object filtersObj = parsedLlmArgs.get(PARAM_KEY_FILTERS);
        if (filtersObj != null) {
            if (filtersObj instanceof Map<String, Object>) {
                filters = (Map<String, Object>) filtersObj;
            } else {
                throw new ValidationException(
                    'Parameter "' + PARAM_KEY_FILTERS + '" must be a valid JSON Object (Map).',
                    PARAM_KEY_FILTERS
                );
            }
        }

        List<String> additionalFields = ActionParamUtils.getOptionalStringList(
            parsedLlmArgs,
            PARAM_KEY_ADDITIONAL_FIELDS
        );

        Integer queryLimit = parseLimitParameter(parsedLlmArgs.get(PARAM_KEY_LIMIT));

        String orderBy = ActionParamUtils.getOptionalString(parsedLlmArgs, PARAM_KEY_ORDER_BY)?.trim();

        return new GetRecordsParsedArguments(filters, additionalFields, queryLimit, orderBy);
    }

    /**
     * @description Contains the core logic: builds and executes the SOQL query, processes results.
     * @param validatedArgs Parsed arguments (must be cast to GetRecordsParsedArguments).
     * @param logPrefix Logging prefix.
     * @return ActionResult Result of the query.
     * @throws System.QueryException If SOQL execution fails (will be caught by base).
     * @throws Other exceptions (e.g., from QueryService validation)
     */
    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        GetRecordsParsedArguments params = (GetRecordsParsedArguments) validatedArgs;

        try {
            SecurityUtils.checkObjectPermission(this.targetSObjectType, AccessType.READABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
            throw ase;
        }

        List<SObject> queryResults = null;
        Map<String, Object> bindMap = new Map<String, Object>();

        try {
            QueryService queryService = new QueryService(this.targetSObjectType, logPrefix)
                .withDefaultFields(this.defaultFields)
                .withAdditionalFields(params.additionalFields)
                .withFilters(params.filters)
                .withOrderBy(params.orderBy)
                .withLimit(params.queryLimit, MAX_PERMITTED_LIMIT);

            queryResults = queryService.executeQuery(bindMap);
        } catch (QueryService.QueryValidationException qve) {
            throw new ValidationException(qve.getMessage(), null);
        } catch (System.QueryException qe) {
            throw qe;
        } catch (Exception e) {
            throw e;
        }

        String resultMessage = '';
        List<SObject> finalResultsForLlm = new List<SObject>();
        Integer totalFoundCount = (queryResults != null ? queryResults.size() : 0);

        if (totalFoundCount > 0) {
            Integer countToReturn = Math.min(totalFoundCount, this.maxReturnToLLM);
            for (Integer i = 0; i < countToReturn; i++) {
                finalResultsForLlm.add(queryResults.get(i));
            }

            if (totalFoundCount > this.maxReturnToLLM) {
                resultMessage =
                    'Found ' +
                    totalFoundCount +
                    ' ' +
                    this.objectApiName +
                    ' record(s). Showing the first ' +
                    this.maxReturnToLLM +
                    '.';
            } else {
                resultMessage = 'Found and showing all ' + totalFoundCount + ' ' + this.objectApiName + ' record(s).';
            }
        } else {
            resultMessage = 'No ' + this.objectApiName + ' records found matching the criteria.';
        }

        Map<String, Object> outputMap = new Map<String, Object>{
            'count' => totalFoundCount,
            'message' => resultMessage,
            'records' => finalResultsForLlm
        };

        String internalDetails =
            'Query executed. Total found: ' +
            totalFoundCount +
            '. Returned to LLM: ' +
            finalResultsForLlm.size() +
            '.';

        return this.success(outputMap, internalDetails);
    }

    /**
     * @description Parses the limit parameter with validation.
     * @param limitObj Raw object from parsed arguments.
     * @return Validated integer limit.
     * @throws ValidationException if limit is invalid type or format.
     */
    private Integer parseLimitParameter(Object limitObj) {
        Integer effectiveLimit = DEFAULT_QUERY_LIMIT;
        if (limitObj != null) {
            Decimal requestedDecimal = null;
            if (limitObj instanceof Integer || limitObj instanceof Decimal) {
                requestedDecimal = (Decimal) limitObj;
            } else if (limitObj instanceof String && String.isNotBlank((String) limitObj)) {
                try {
                    requestedDecimal = Decimal.valueOf((String) limitObj);
                } catch (Exception e) {
                    throw new ValidationException(
                        'Parameter "' + PARAM_KEY_LIMIT + '" must be a valid Integer.',
                        PARAM_KEY_LIMIT
                    );
                }
            } else {
                throw new ValidationException(
                    'Invalid data type for parameter "' + PARAM_KEY_LIMIT + '". Expected Number or numeric String.',
                    PARAM_KEY_LIMIT
                );
            }

            if (requestedDecimal == null) {
                throw new ValidationException(
                    'Parameter "' + PARAM_KEY_LIMIT + '" must be a valid Integer.',
                    PARAM_KEY_LIMIT
                );
            } else if (requestedDecimal <= 0) {
                effectiveLimit = DEFAULT_QUERY_LIMIT;
            } else {
                effectiveLimit = Math.min(requestedDecimal.intValue(), MAX_PERMITTED_LIMIT);
            }
        }
        return effectiveLimit;
    }
}
