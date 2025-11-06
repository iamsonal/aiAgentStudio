/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionOrder is an object-centric action class containing Order-related query operations.
 * Follows the object-centric pattern to consolidate related queries in a single class.
 *
 * Supported Operations:
 *   - GET_BY_ID: Get a specific order by Salesforce ID
 *   - SEARCH_BY_ACCOUNT: Get orders for a specific account
 *
 * @extends BaseAgentAction
 */
public class ActionOrder extends BaseAgentAction {
    private static final Integer DEFAULT_MAX_RESULTS = 25;
    private static final Integer ABSOLUTE_MAX_RESULTS = 100;

    private ConfigDTO config;

    /**
     * DTO for backend configuration
     */
    public class ConfigDTO {
        public String operation;
        public List<String> defaultFields;
        public Integer maxResults;
    }

    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        if (String.isBlank(actionConfigurationJson)) {
            throw new ValidationException('Backend configuration is required for ActionOrder', null);
        }

        try {
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

            this.config = new ConfigDTO();
            this.config.operation = (String) configMap.get('operation');
            this.config.defaultFields = ActionConfigUtils.getOptionalStringList(configMap, 'defaultFields');
            this.config.maxResults = configMap.get('maxResults') != null ? Integer.valueOf(configMap.get('maxResults')) : DEFAULT_MAX_RESULTS;

            this.config.maxResults = Math.min(this.config.maxResults, ABSOLUTE_MAX_RESULTS);
        } catch (Exception e) {
            throw new ValidationException('Invalid backend configuration JSON: ' + e.getMessage(), e);
        }

        if (String.isBlank(this.config.operation)) {
            throw new ValidationException('operation is required in backend configuration. Example: {"operation": "GET_BY_ID"}', 'operation');
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Configured ActionOrder with operation: ' + this.config.operation);
    }

    public override ActionOutcome executeAction(Map<String, Object> params) {
        switch on this.config.operation {
            when 'GET_BY_ID' {
                return getById(params);
            }
            when 'SEARCH_BY_ACCOUNT' {
                return searchByAccount(params);
            }
            when else {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'Unknown operation: ' + this.config.operation + '. Valid operations: GET_BY_ID, SEARCH_BY_ACCOUNT'
                );
            }
        }
    }

    private ActionOutcome getById(Map<String, Object> params) {
        String orderId = (String) params.get('orderId');

        if (String.isBlank(orderId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'orderId is required for GET_BY_ID operation');
        }

        try {
            List<Order> results = [
                SELECT Id, OrderNumber, Status, TotalAmount, EffectiveDate, Type, AccountId, BillToContactId, Description
                FROM Order
                WHERE Id = :orderId
                WITH USER_MODE
                LIMIT 1
            ];

            if (results.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, 'Order not found with ID: ' + orderId);
            }

            return ActionOutcome.success(new Map<String, Object>{ 'record' => results[0], 'message' => 'Found order: ' + results[0].OrderNumber });
        } catch (System.QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to query order: ' + qEx.getMessage());
        }
    }

    private ActionOutcome searchByAccount(Map<String, Object> params) {
        String accountId = (String) params.get('accountId');

        if (String.isBlank(accountId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'accountId is required for SEARCH_BY_ACCOUNT operation');
        }

        try {
            List<Order> results = [
                SELECT Id, OrderNumber, Status, TotalAmount, EffectiveDate, Type
                FROM Order
                WHERE AccountId = :accountId
                WITH USER_MODE
                ORDER BY EffectiveDate DESC
                LIMIT :config.maxResults
            ];

            return ActionOutcome.success(
                new Map<String, Object>{
                    'records' => results,
                    'count' => results.size(),
                    'message' => 'Found ' +
                    results.size() +
                    ' order(s) for account'
                }
            );
        } catch (System.QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to search orders: ' + qEx.getMessage());
        }
    }
}
