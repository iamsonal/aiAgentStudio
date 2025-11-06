/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionOpportunity is an object-centric action class containing Opportunity-related query operations.
 * Follows the object-centric pattern to consolidate related queries in a single class.
 *
 * Supported Operations:
 *   - SEARCH_BY_ACCOUNT: Search opportunities for a specific account
 *
 * @extends BaseAgentAction
 */
public class ActionOpportunity extends BaseAgentAction {
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
            throw new ValidationException('Backend configuration is required for ActionOpportunity', null);
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
            throw new ValidationException('operation is required in backend configuration. Example: {"operation": "SEARCH_BY_ACCOUNT"}', 'operation');
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Configured ActionOpportunity with operation: ' + this.config.operation);
    }

    public override ActionOutcome executeAction(Map<String, Object> params) {
        switch on this.config.operation {
            when 'SEARCH_BY_ACCOUNT' {
                return searchByAccount(params);
            }
            when else {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'Unknown operation: ' + this.config.operation + '. Valid operations: SEARCH_BY_ACCOUNT'
                );
            }
        }
    }

    private ActionOutcome searchByAccount(Map<String, Object> params) {
        String accountId = (String) params.get('accountId');

        if (String.isBlank(accountId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'accountId is required for SEARCH_BY_ACCOUNT operation');
        }

        try {
            List<Opportunity> results = [
                SELECT Id, Name, StageName, Amount, CloseDate, Probability, AccountId
                FROM Opportunity
                WHERE AccountId = :accountId
                WITH USER_MODE
                ORDER BY CloseDate DESC
                LIMIT :config.maxResults
            ];

            return ActionOutcome.success(
                new Map<String, Object>{
                    'records' => results,
                    'count' => results.size(),
                    'message' => 'Found ' +
                    results.size() +
                    ' opportunit' +
                    (results.size() == 1 ? 'y' : 'ies') +
                    ' for account'
                }
            );
        } catch (System.QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to search opportunities: ' + qEx.getMessage());
        }
    }
}
