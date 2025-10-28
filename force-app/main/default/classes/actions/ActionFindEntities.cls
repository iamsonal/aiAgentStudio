/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionFindEntities is a high-performance Apex action for performing dynamic SOSL searches using strongly-typed DTOs.
 * This action replaces the need for complex Apex-based pattern analysis by leveraging the LLM's ability to destructure natural language
 * into a well-defined search request.
 *
 * Responsibilities:
 *   - Uses DTOs for type-safe argument handling
 *   - Accepts structured search criteria: sObject types, fields to return, and filters
 *   - Enforces Object and Field-Level Security (FLS) on all aspects of the query
 *   - Dynamically constructs and executes a secure SOSL query
 *   - Returns a structured, LLM-friendly result with found records and metadata
 *
 * Architecture:
 *   - ArgumentsDTO: Strongly-typed with sObjectTypes, fieldsToReturn, filters, limit
 *   - No configuration needed - fully dynamic based on LLM input
 *   - Uses native JSON.deserialize() for high-performance type conversion
 *
 * @extends BaseAgentAction
 */
public class ActionFindEntities extends BaseAgentAction {
    private static final Integer MAX_QUERY_LIMIT = 50;
    private static final Integer DEFAULT_QUERY_LIMIT = 10;

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        public List<String> sObjectTypes;
        public List<String> fieldsToReturn;
        public Map<String, Object> filters;
        public Integer queryLimit;
    }

    /**
     * @description
     * Main entry point for entity search using strongly-typed DTOs.
     *
     * @param params Map<String, Object> - Raw parameters (deserialized into ArgumentsDTO for type safety)
     * @return ActionOutcome<QueryResult> - Contains found records and metadata, or a structured error
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        try {
            // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
            ArgumentsDTO args = new ArgumentsDTO();
            args.sObjectTypes = ActionConfigUtils.getOptionalStringList(params, 'sObjectTypes');
            args.fieldsToReturn = ActionConfigUtils.getOptionalStringList(params, 'fieldsToReturn');
            args.filters = params.get('filters') != null ? (Map<String, Object>) params.get('filters') : new Map<String, Object>();
            args.queryLimit = params.get('queryLimit') != null ? Integer.valueOf(params.get('queryLimit')) : DEFAULT_QUERY_LIMIT;

            // Validate required DTO parameters
            if (args.sObjectTypes.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'sObjectTypes is required and cannot be empty');
            }
            if (args.fieldsToReturn.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'fieldsToReturn is required and cannot be empty');
            }
            if (args.filters.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'filters is required and cannot be empty');
            }

            Integer finalLimit = Math.min(args.queryLimit, MAX_QUERY_LIMIT);

            // 2. Build a secure SOSL query from the DTO parameters
            String soslQuery = buildSoslQuery(args.sObjectTypes, args.fieldsToReturn, args.filters, finalLimit);

            if (String.isBlank(soslQuery)) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                    'Could not construct a valid search. This may be due to a lack of access to the requested objects or fields.'
                );
            }

            // 3. Execute the query
            List<List<SObject>> searchResults = Search.query(soslQuery);
            List<SObject> flatResults = flattenSearchResults(searchResults);

            Long executionTime = System.currentTimeMillis() - startTime;
            System.debug(
                LoggingLevel.INFO,
                '[ActionFindEntities] SOSL query completed in ' + executionTime + ' ms. Records found: ' + flatResults.size()
            );

            // 4. Format and return the result using DTO data
            return ActionOutcome.success(new QueryResult(flatResults, args.sObjectTypes));
        } catch (System.QueryException qe) {
            System.debug(LoggingLevel.ERROR, '[ActionFindEntities] SOSL execution failed: ' + qe.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'The search query failed: ' + qe.getMessage());
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, '[ActionFindEntities] Unexpected error during search: ' + ex.getMessage());
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                'An unexpected error occurred during the search: ' + ex.getMessage()
            );
        }
    }

    /**
     * @description
     * Constructs a secure SOSL query string by validating object/field access and sanitizing inputs.
     *
     * @param sObjectTypes   List of SObject API names to search.
     * @param fieldsToReturn List of field API names to retrieve.
     * @param filters        Map of field-value pairs for the WHERE clause.
     * @param limitValue          The maximum number of records to return.
     * @return A secure, executable SOSL query string.
     */
    private String buildSoslQuery(List<String> sObjectTypes, List<String> fieldsToReturn, Map<String, Object> filters, Integer limitValue) {
        List<String> filterValues = new List<String>();
        for (Object value : filters.values()) {
            if (value != null && String.isNotBlank(String.valueOf(value))) {
                filterValues.add(String.escapeSingleQuotes(String.valueOf(value)));
            }
        }

        if (filterValues.isEmpty()) {
            return null;
        }
        String findClause = 'FIND \'' + String.join(filterValues, ' AND ') + '\'';

        String returningClause = buildSecureReturningClause(sObjectTypes, fieldsToReturn);

        if (String.isBlank(returningClause)) {
            System.debug(LoggingLevel.WARN, '[ActionFindEntities] No accessible objects or fields to search. Returning empty query.');
            return null;
        }

        return findClause + ' IN ALL FIELDS RETURNING ' + returningClause + ' LIMIT ' + limitValue;
    }

    /**
     * @description
     * Builds the 'RETURNING' clause for a SOSL query, ensuring the current user has access to all requested objects and fields.
     *
     * @param sObjectTypes   List of SObject API names.
     * @param fieldsToReturn List of field API names.
     * @return A secure RETURNING clause string.
     */
    private String buildSecureReturningClause(List<String> sObjectTypes, List<String> fieldsToReturn) {
        List<String> returningParts = new List<String>();
        Map<String, SObjectType> globalDescribe = Schema.getGlobalDescribe();

        for (String sObjName : sObjectTypes) {
            SObjectType sObjToken = globalDescribe.get(sObjName);
            if (sObjToken == null || !sObjToken.getDescribe().isQueryable() || !sObjToken.getDescribe().isAccessible()) {
                System.debug(LoggingLevel.WARN, '[ActionFindEntities] Skipping inaccessible or invalid object: ' + sObjName);
                continue;
            }

            List<String> accessibleFields = new List<String>();
            for (String fieldName : fieldsToReturn) {
                if (SecurityUtils.hasFieldPermission(sObjToken, fieldName, AccessType.READABLE)) {
                    accessibleFields.add(fieldName);
                } else {
                    System.debug(LoggingLevel.WARN, '[ActionFindEntities] Skipping inaccessible field ' + fieldName + ' on object ' + sObjName);
                }
            }

            if (!accessibleFields.isEmpty()) {
                returningParts.add(sObjName + '(' + String.join(accessibleFields, ', ') + ')');
            }
        }

        return String.join(returningParts, ', ');
    }

    /**
     * @description
     * Converts the nested List<List<SObject>> from a SOSL result into a single flat list.
     *
     * @param searchResults The result from Search.query().
     * @return A flattened List<SObject>.
     */
    private List<SObject> flattenSearchResults(List<List<SObject>> searchResults) {
        List<SObject> flatList = new List<SObject>();
        if (searchResults != null) {
            for (List<SObject> sObjectList : searchResults) {
                flatList.addAll(sObjectList);
            }
        }
        return flatList;
    }

    /**
     * @description
     * This action is fully dynamic based on LLM input, so no static backend configuration is required.
     * @param actionConfigurationJson The JSON configuration string (ignored)
     * @param logPrefix               Prefix for log output
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        // No static configuration is needed for this dynamic action.
        // The sObject types and fields are provided by the LLM at runtime via ArgumentsDTO.
    }

    /**
     * @description
     * Result wrapper for the find entities operation. Provides structured data for both user display and LLM processing.
     */
    public class QueryResult {
        @AuraEnabled
        public List<SObject> records;
        @AuraEnabled
        public Integer count;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Map<String, Object> metadata;

        public QueryResult(List<SObject> records, List<String> sObjectTypesSearched) {
            this.records = records;
            this.count = records.size();
            this.message = 'Found ' + this.count + ' record(s) matching the criteria.';
            this.metadata = new Map<String, Object>{ 'totalFound' => this.count, 'sObjectTypesSearched' => sObjectTypesSearched };
        }
    }
}
