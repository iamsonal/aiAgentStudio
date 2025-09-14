/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionFindEntities is a thin wrapper around SearchService for performing intelligent entity search.
 *
 * Responsibilities:
 *   - Acts as a facade for the SearchService
 *   - Delegates search operations to specialized services
 *   - Provides structured, LLM-friendly results
 *
 * @extends BaseAgentAction
 */
public class ActionFindEntities extends BaseAgentAction {
    private static final String CONFIG_MAX_AMBIGUOUS_RESULTS = 'maxAmbiguousResults';
    private static final Integer DEFAULT_MAX_AMBIGUOUS_RESULTS = 5;

    @TestVisible
    private static List<SObjectConfig__mdt> MDT_CACHE;

    private class ScoringInfo {
        public String primaryNameField;
        public Set<String> keyIdentifierFields;
        public ScoringInfo(String nameField, Set<String> keyFields) {
            this.primaryNameField = nameField;
            this.keyIdentifierFields = keyFields;
        }
    }

    private Map<String, List<String>> configuredReturnFields = new Map<String, List<String>>();
    private Map<String, ScoringInfo> scoringConfig = new Map<String, ScoringInfo>();
    private Integer maxAmbiguousResults = DEFAULT_MAX_AMBIGUOUS_RESULTS;

    /**
     * @description
     * Main entry point for entity search. Delegates to SearchService for all processing.
     *
     * @param params Map<String, Object> - Must include 'searchQuery' (String), may include 'sObjectTypes' (List<String>).
     * @return ActionOutcome - Contains search results or error information.
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        try {
            // Extract and validate parameters
            String searchQuery = (String) params.get('searchQuery');
            if (String.isBlank(searchQuery)) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Search term is required');
            }

            List<String> sObjectTypes = ActionConfigUtils.getOptionalStringList(params, 'sObjectTypes');

            // Prepare search configuration
            SearchService.SearchConfiguration searchConfig = new SearchService.SearchConfiguration(
                this.configuredReturnFields,
                convertScoringConfig(),
                this.maxAmbiguousResults
            );

            // Delegate to SearchService
            SearchService.SearchResult result = SearchService.performSearch(searchQuery, sObjectTypes, searchConfig, UserInfo.getUserId());

            return ActionOutcome.success(result);
        } catch (Exception ex) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Entity search failed: ' + ex.getMessage());
        }
    }

    /**
     * @description
     * Parses and validates the action configuration JSON.
     *
     * @param actionConfigurationJson String - The JSON configuration string.
     * @param logPrefix String - Prefix for log output.
     * @throws ValidationException if required configuration or metadata is missing or invalid.
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        // Load and cache custom metadata configuration for searchable objects
        if (MDT_CACHE == null) {
            try {
                MDT_CACHE = [
                    SELECT SObjectAPIName__c, PrimaryNameField__c, KeyIdentifierFields__c
                    FROM SObjectConfig__mdt
                    WHERE IsActive__c = TRUE
                ];
                System.debug(
                    LoggingLevel.INFO,
                    '[ActionFindEntities] Custom metadata cache miss. Loaded ' + MDT_CACHE.size() + ' SObjectConfig__mdt records.'
                );
            } catch (Exception e) {
                throw new ValidationException('Failed to query SObjectConfig__mdt records: ' + e.getMessage(), null, e);
            }
        } else {
            System.debug(LoggingLevel.INFO, '[ActionFindEntities] Custom metadata cache hit. Using cached SObjectConfig__mdt records.');
        }

        if (MDT_CACHE.isEmpty()) {
            throw new ValidationException('No active SObjectConfig__mdt records found. Please configure searchable objects.', null);
        }

        // Build search configuration from custom metadata
        for (SObjectConfig__mdt config : MDT_CACHE) {
            String sObjApiName = config.SObjectAPIName__c;
            if (String.isBlank(sObjApiName) || String.isBlank(config.PrimaryNameField__c)) {
                System.debug(LoggingLevel.WARN, '[ActionFindEntities] Skipping invalid SObjectConfig__mdt record: ' + config.DeveloperName);
                continue;
            }

            Set<String> keyFields = new Set<String>();
            if (String.isNotBlank(config.KeyIdentifierFields__c)) {
                for (String field : config.KeyIdentifierFields__c.split(',')) {
                    if (String.isNotBlank(field.trim())) {
                        keyFields.add(field.trim());
                    }
                }
            }

            this.scoringConfig.put(sObjApiName.toLowerCase(), new ScoringInfo(config.PrimaryNameField__c, keyFields));

            List<String> fieldsForObject = new List<String>(keyFields);
            fieldsForObject.addAll(new List<String>{ config.PrimaryNameField__c, 'Id' });
            this.configuredReturnFields.put(sObjApiName, new List<String>(new Set<String>(fieldsForObject)));
        }

        this.maxAmbiguousResults = ActionConfigUtils.getOptionalInteger(
            this.parsedActionConfig,
            CONFIG_MAX_AMBIGUOUS_RESULTS,
            DEFAULT_MAX_AMBIGUOUS_RESULTS
        );

        if (this.maxAmbiguousResults != DEFAULT_MAX_AMBIGUOUS_RESULTS) {
            System.debug(LoggingLevel.INFO, '[ActionFindEntities] maxAmbiguousResults overridden to: ' + this.maxAmbiguousResults);
        }
    }

    /**
     * @description
     * Converts internal ScoringInfo to ResultScoringService.ScoringInfo for compatibility.
     *
     * @return Map<String, ResultScoringService.ScoringInfo> Converted scoring configuration
     */
    private Map<String, ResultScoringService.ScoringInfo> convertScoringConfig() {
        Map<String, ResultScoringService.ScoringInfo> converted = new Map<String, ResultScoringService.ScoringInfo>();
        for (String key : this.scoringConfig.keySet()) {
            ScoringInfo info = this.scoringConfig.get(key);
            converted.put(key, new ResultScoringService.ScoringInfo(info.primaryNameField, info.keyIdentifierFields));
        }
        return converted;
    }
}
