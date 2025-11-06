/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionAccount is an object-centric action class containing all Account-related query operations.
 * This design pattern consolidates multiple query operations into a single class, reducing class proliferation
 * while maintaining predictable LLM behavior through explicit parameters.
 *
 * Pattern:
 *   - Single class per object (Account, Contact, Opportunity, etc.)
 *   - Multiple operations within the class (getById, searchByName, etc.)
 *   - Operation identifier passed via backend configuration JSON
 *   - Each operation has explicit, typed parameters (no generic filters)
 *   - Hardcoded query structure per operation for predictability
 *
 * Backend Configuration:
 *   {
 *     "operation": "GET_BY_ID",              // REQUIRED: Operation identifier
 *     "defaultFields": ["Id", "Name", ...],  // OPTIONAL: Fields to select
 *     "maxResults": 25                       // OPTIONAL: Result limit
 *   }
 *
 * Supported Operations:
 *   - GET_BY_ID: Get a specific account by Salesforce ID
 *   - SEARCH_BY_NAME: Search accounts by name (partial match)
 *   - GET_BY_INDUSTRY: Get accounts filtered by industry
 *   - SEARCH_BY_REVENUE: Search accounts by revenue range
 *
 * @extends BaseAgentAction
 */
public class ActionAccount extends BaseAgentAction {
    private static final Integer DEFAULT_MAX_RESULTS = 25;
    private static final Integer ABSOLUTE_MAX_RESULTS = 100;

    private ConfigDTO config;

    /**
     * DTO for backend configuration
     */
    public class ConfigDTO {
        public String operation; // Operation identifier (required)
        public List<String> defaultFields; // Fields to select (optional)
        public Integer maxResults; // Maximum results to return (optional)
    }

    /**
     * @description
     * Parses backend configuration JSON to extract operation identifier and settings.
     * The operation field is REQUIRED and determines which query method to execute.
     *
     * @param actionConfigurationJson JSON string containing operation and settings
     * @param logPrefix Logging prefix for debug output
     * @throws ValidationException if operation is missing or configuration is invalid
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        if (String.isBlank(actionConfigurationJson)) {
            throw new ValidationException('Backend configuration is required for ActionAccount', null);
        }

        try {
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

            this.config = new ConfigDTO();
            this.config.operation = (String) configMap.get('operation');
            this.config.defaultFields = ActionConfigUtils.getOptionalStringList(configMap, 'defaultFields');
            this.config.maxResults = configMap.get('maxResults') != null ? Integer.valueOf(configMap.get('maxResults')) : DEFAULT_MAX_RESULTS;

            // Enforce maximum limit
            this.config.maxResults = Math.min(this.config.maxResults, ABSOLUTE_MAX_RESULTS);
        } catch (Exception e) {
            throw new ValidationException('Invalid backend configuration JSON: ' + e.getMessage(), e);
        }

        // Validate required operation field
        if (String.isBlank(this.config.operation)) {
            throw new ValidationException('operation is required in backend configuration. Example: {"operation": "GET_BY_ID"}', 'operation');
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Configured ActionAccount with operation: ' + this.config.operation);
    }

    /**
     * @description
     * Routes execution to the appropriate query operation based on backend configuration.
     * Each operation has explicit parameters and hardcoded query structure for predictability.
     *
     * @param params Map of LLM-provided parameters (operation-specific)
     * @return ActionOutcome with query results or error information
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        // Route based on operation from backend configuration
        switch on this.config.operation {
            when 'GET_BY_ID' {
                return getById(params);
            }
            when 'SEARCH_BY_NAME' {
                return searchByName(params);
            }
            when 'GET_BY_INDUSTRY' {
                return getByIndustry(params);
            }
            when 'SEARCH_BY_REVENUE' {
                return searchByRevenue(params);
            }
            when else {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'Unknown operation: ' +
                        this.config.operation +
                        '. Valid operations: GET_BY_ID, SEARCH_BY_NAME, GET_BY_INDUSTRY, SEARCH_BY_REVENUE'
                );
            }
        }
    }

    /**
     * @description
     * Operation: GET_BY_ID
     * Retrieves a specific Account record by its Salesforce ID.
     *
     * Required Parameters:
     *   - accountId (String): 18-character Salesforce Account ID
     *
     * @param params LLM-provided parameters
     * @return ActionOutcome with single Account record or error
     */
    private ActionOutcome getById(Map<String, Object> params) {
        String accountId = (String) params.get('accountId');

        if (String.isBlank(accountId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'accountId is required for GET_BY_ID operation');
        }

        try {
            List<Account> results = [
                SELECT Id, Name, Industry, Type, AnnualRevenue, BillingCity, BillingState, BillingCountry, Phone, Website, Description
                FROM Account
                WHERE Id = :accountId
                WITH USER_MODE
                LIMIT 1
            ];

            if (results.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, 'Account not found with ID: ' + accountId);
            }

            return ActionOutcome.success(new Map<String, Object>{ 'record' => results[0], 'message' => 'Found account: ' + results[0].Name });
        } catch (System.QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to query account: ' + qEx.getMessage());
        }
    }

    /**
     * @description
     * Operation: SEARCH_BY_NAME
     * Searches for Account records by name using partial match (LIKE).
     *
     * Required Parameters:
     *   - accountName (String): Name or partial name to search for
     *
     * @param params LLM-provided parameters
     * @return ActionOutcome with list of matching Account records
     */
    private ActionOutcome searchByName(Map<String, Object> params) {
        String accountName = (String) params.get('accountName');

        if (String.isBlank(accountName)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'accountName is required for SEARCH_BY_NAME operation');
        }

        try {
            String searchPattern = '%' + String.escapeSingleQuotes(accountName) + '%';

            List<Account> results = [
                SELECT Id, Name, Industry, Type, Phone, BillingCity, BillingState
                FROM Account
                WHERE Name LIKE :searchPattern
                WITH USER_MODE
                ORDER BY Name ASC
                LIMIT :config.maxResults
            ];

            return ActionOutcome.success(
                new Map<String, Object>{
                    'records' => results,
                    'count' => results.size(),
                    'message' => 'Found ' +
                    results.size() +
                    ' account(s) matching "' +
                    accountName +
                    '"'
                }
            );
        } catch (System.QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to search accounts: ' + qEx.getMessage());
        }
    }

    /**
     * @description
     * Operation: GET_BY_INDUSTRY
     * Retrieves Account records filtered by industry.
     *
     * Required Parameters:
     *   - industry (String): Industry value to filter by (exact match)
     *
     * @param params LLM-provided parameters
     * @return ActionOutcome with list of Account records in specified industry
     */
    private ActionOutcome getByIndustry(Map<String, Object> params) {
        String industry = (String) params.get('industry');

        if (String.isBlank(industry)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'industry is required for GET_BY_INDUSTRY operation');
        }

        try {
            List<Account> results = [
                SELECT Id, Name, Industry, Type, AnnualRevenue, Phone
                FROM Account
                WHERE Industry = :industry
                WITH USER_MODE
                ORDER BY Name ASC
                LIMIT :config.maxResults
            ];

            return ActionOutcome.success(
                new Map<String, Object>{
                    'records' => results,
                    'count' => results.size(),
                    'message' => 'Found ' +
                    results.size() +
                    ' account(s) in ' +
                    industry +
                    ' industry'
                }
            );
        } catch (System.QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to query accounts by industry: ' + qEx.getMessage());
        }
    }

    /**
     * @description
     * Operation: SEARCH_BY_REVENUE
     * Searches for Account records within a specified revenue range.
     *
     * Parameters (at least one required):
     *   - minRevenue (Decimal): Minimum annual revenue threshold
     *   - maxRevenue (Decimal): Maximum annual revenue threshold
     *
     * @param params LLM-provided parameters
     * @return ActionOutcome with list of Account records matching revenue criteria
     */
    private ActionOutcome searchByRevenue(Map<String, Object> params) {
        Decimal minRevenue = params.get('minRevenue') != null ? Decimal.valueOf(String.valueOf(params.get('minRevenue'))) : null;
        Decimal maxRevenue = params.get('maxRevenue') != null ? Decimal.valueOf(String.valueOf(params.get('maxRevenue'))) : null;

        if (minRevenue == null && maxRevenue == null) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'At least one of minRevenue or maxRevenue is required for SEARCH_BY_REVENUE operation'
            );
        }

        try {
            List<String> conditions = new List<String>();
            Map<String, Object> binds = new Map<String, Object>();

            if (minRevenue != null) {
                conditions.add('AnnualRevenue >= :minRevenue');
                binds.put('minRevenue', minRevenue);
            }

            if (maxRevenue != null) {
                conditions.add('AnnualRevenue <= :maxRevenue');
                binds.put('maxRevenue', maxRevenue);
            }

            String query =
                'SELECT Id, Name, Industry, Type, AnnualRevenue, Phone ' +
                'FROM Account ' +
                'WHERE ' +
                String.join(conditions, ' AND ') +
                ' ' +
                'ORDER BY AnnualRevenue DESC ' +
                'LIMIT ' +
                config.maxResults;

            List<Account> results = Database.queryWithBinds(query, binds, AccessLevel.USER_MODE);

            String rangeDesc = buildRevenueRangeDescription(minRevenue, maxRevenue);

            return ActionOutcome.success(
                new Map<String, Object>{
                    'records' => results,
                    'count' => results.size(),
                    'message' => 'Found ' +
                    results.size() +
                    ' account(s) with revenue ' +
                    rangeDesc
                }
            );
        } catch (System.QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to search accounts by revenue: ' + qEx.getMessage());
        }
    }

    /**
     * @description
     * Helper method to build a human-readable revenue range description.
     *
     * @param minRevenue Minimum revenue (can be null)
     * @param maxRevenue Maximum revenue (can be null)
     * @return String describing the revenue range
     */
    private String buildRevenueRangeDescription(Decimal minRevenue, Decimal maxRevenue) {
        if (minRevenue != null && maxRevenue != null) {
            return 'between $' + minRevenue.format() + ' and $' + maxRevenue.format();
        } else if (minRevenue != null) {
            return 'greater than $' + minRevenue.format();
        } else {
            return 'less than $' + maxRevenue.format();
        }
    }
}
