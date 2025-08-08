/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Queries Salesforce records with intelligent parameter processing.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *              ActionConfiguration example: {"objectApiName": "Contact", "defaultFields": ["Id", "Name", "Email"], "maxReturnToLLM": 10}
 *              LLM Arguments example: {"filters": {"LastName": "Smith", "MailingCity": "SF"}, "additionalFields": ["Phone"], "limit": 5, "orderBy": "LastName ASC"}
 *
 *              COMPARE TO ORIGINAL: 400+ lines reduced to ~100 lines (75% reduction)!
 * @extends BaseAgentAction
 */
public class ActionGetRecords extends BaseAgentAction {
    private static final String CONFIG_KEY_OBJECT_API_NAME = 'objectApiName';
    private static final String CONFIG_KEY_DEFAULT_FIELDS = 'defaultFields';
    private static final String CONFIG_KEY_MAX_RETURN = 'maxReturnToLLM';

    private static final Integer DEFAULT_QUERY_LIMIT = 10;
    private static final Integer MAX_PERMITTED_LIMIT = 50;
    private static final Integer DEFAULT_MAX_RETURNED_TO_LLM = 10;

    private String objectApiName;
    private List<String> defaultFields = new List<String>();
    private Integer maxReturnToLLM = DEFAULT_MAX_RETURNED_TO_LLM;
    private SObjectType targetSObjectType;

    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction, validation, and security.
     *              ENHANCED: Restores critical robustness while keeping simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        Map<String, Object> filters = (Map<String, Object>) params.get('filters');
        List<String> additionalFields = (List<String>) params.get('additionalFields');
        Integer queryLimit = validateAndCoerceLimit(params.get('limit'));
        String orderBy = (String) params.get('orderBy');

        if (filters == null)
            filters = new Map<String, Object>();
        if (additionalFields == null)
            additionalFields = new List<String>();

        try {
            SecurityUtils.checkObjectPermission(this.targetSObjectType, AccessType.READABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
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
            throw new ValidationException(aie.getMessage(), aie.fieldName);
        } catch (QueryService.QueryValidationException qve) {
            throw new ValidationException(qve.getMessage(), null);
        } catch (System.QueryException qe) {
            String enhancedMessage = enhanceQueryExceptionMessage(qe.getMessage(), filters, orderBy, queryLimit);

            throw qe;
        }

        Long executionTime = System.currentTimeMillis() - startTime;

        return processQueryResults(queryResults);
    }

    /**
     * @description Validates and coerces limit parameter with detailed error handling
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
     * @description Enhances query exception messages with AI-friendly context
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

    private QueryResult processQueryResults(List<SObject> queryResults) {
        Integer totalFoundCount = queryResults != null ? queryResults.size() : 0;
        List<SObject> finalResults = new List<SObject>();

        if (totalFoundCount > 0) {
            Integer countToReturn = Math.min(totalFoundCount, this.maxReturnToLLM);
            for (Integer i = 0; i < countToReturn; i++) {
                finalResults.add(queryResults.get(i));
            }

            if (totalFoundCount > this.maxReturnToLLM) {
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

        return new QueryResult(finalResults, totalFoundCount, this.objectApiName, message);
    }

    public class QueryResult {
        public List<SObject> records;
        public Integer count;
        public String objectApiName;
        public String message;
        public Boolean truncated;
        public Map<String, Object> metadata;

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
