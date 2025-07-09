/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Standard Action: Performs a fuzzy search for records using a hybrid SOSL and a "Known Fields" mapping.
 *              This action is optimized for natural language queries, typos, and ambiguity.
 *
 * @extends BaseAgentAction
 *
 * @configuration
 * This action is configured entirely via the 'SObjectConfig__mdt' Custom Metadata Type.
 * Create records in this CMDT to define which objects are searchable, their primary display field,
 * and key fields for scoring. The action dynamically reads this metadata at runtime.
 *
 * An optional JSON configuration can be provided on the AgentCapability__c record to override 'maxAmbiguousResults'.
 * @example BackendConfiguration__c JSON: { "maxAmbiguousResults": 3 }
 *
 * @returns {ActionResult} A structured result indicating the outcome: SUCCESS, AMBIGUOUS, or NOT_FOUND.
 */
public class ActionFindEntities extends BaseAgentAction {
    private static final String CONFIG_MAX_AMBIGUOUS_RESULTS = 'maxAmbiguousResults';
    private static final String ARG_SEARCH_QUERY = 'searchQuery';
    private static final String ARG_SOBJECT_TYPES = 'sObjectTypes';

    private static final String STATUS_SUCCESS = 'SUCCESS';
    private static final String STATUS_AMBIGUOUS = 'AMBIGUOUS';
    private static final String STATUS_NOT_FOUND = 'NOT_FOUND';

    private static final Integer DEFAULT_MAX_AMBIGUOUS_RESULTS = 5;
    private static final Integer SOSL_QUERY_LIMIT = 50;
    private static final Integer NAME_FIELD_MATCH_SCORE = 100;
    private static final Integer KEY_FIELD_MATCH_SCORE = 50;

    @TestVisible
    private static List<SObjectConfig__mdt> MDT_CACHE;

    private class ScoringInfo {
        public String primaryNameField { get; set; }
        public Set<String> keyIdentifierFields { get; set; }
        public ScoringInfo(String nameField, Set<String> keyFields) {
            this.primaryNameField = nameField;
            this.keyIdentifierFields = keyFields;
        }
    }

    private Map<String, List<String>> configuredReturnFields = new Map<String, List<String>>();
    private Map<String, ScoringInfo> scoringConfig = new Map<String, ScoringInfo>();
    private Integer maxAmbiguousResults;

    protected override String getLogPrefixName() {
        return 'ActionFindEntities';
    }

    /**
     * @description Populates the searchable objects and fields by querying the SObjectConfig__mdt
     *              Custom Metadata Type. This allows administrators to configure search behavior without code changes.
     *              The results are cached for the duration of the transaction.
     * @param actionConfigurationJson The raw JSON string from the binding (may be null).
     * @param logPrefix Logging prefix.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        this.maxAmbiguousResults = DEFAULT_MAX_AMBIGUOUS_RESULTS;

        if (MDT_CACHE == null) {
            try {
                MDT_CACHE = [
                    SELECT SObjectAPIName__c, PrimaryNameField__c, KeyIdentifierFields__c
                    FROM SObjectConfig__mdt
                    WHERE IsActive__c = TRUE
                ];
            } catch (Exception e) {
                throw new ValidationException('Failed to query required SObjectConfig__mdt records: ' + e.getMessage(), null, e);
            }
        } else {
        }

        if (MDT_CACHE.isEmpty()) {
            throw new ValidationException('No active SObjectConfig__mdt records found. Please configure at least one searchable object.', null);
        }

        for (SObjectConfig__mdt config : MDT_CACHE) {
            String sObjApiName = config.SObjectAPIName__c;
            if (String.isBlank(sObjApiName) || String.isBlank(config.PrimaryNameField__c)) {
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
            fieldsForObject.add(config.PrimaryNameField__c);
            fieldsForObject.add('Id');

            this.configuredReturnFields.put(sObjApiName, new List<String>(new Set<String>(fieldsForObject)));
        }

        if (this.parsedActionConfig != null && this.parsedActionConfig.containsKey(CONFIG_MAX_AMBIGUOUS_RESULTS)) {
            try {
                this.maxAmbiguousResults = (Integer) this.parsedActionConfig.get(CONFIG_MAX_AMBIGUOUS_RESULTS);
            } catch (Exception e) {
            }
        }
    }

    private class FindEntitiesParsedArguments extends BaseAgentAction.ParsedArguments {
        String searchQuery;
        List<String> sObjectTypes;
        public FindEntitiesParsedArguments(String query, List<String> types) {
            this.searchQuery = query;
            this.sObjectTypes = types;
        }
    }

    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        Map<String, Object> parsedArgs = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);
        String searchQuery = ParameterExtractionUtils.getRequiredString(parsedArgs, ARG_SEARCH_QUERY);
        List<String> sObjectTypes = ParameterExtractionUtils.getOptionalStringList(parsedArgs, ARG_SOBJECT_TYPES);
        return new FindEntitiesParsedArguments(searchQuery, sObjectTypes);
    }

    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        FindEntitiesParsedArguments args = (FindEntitiesParsedArguments) validatedArgs;

        Map<String, List<String>> accessibleReturnFields = buildAccessibleReturnFieldMap(args.sObjectTypes, logPrefix);
        if (accessibleReturnFields.isEmpty()) {
            throw new ActionSecurityException('User lacks read access to any configured or requested objects.');
        }

        String soslReturningClause = buildSoslReturningClause(accessibleReturnFields);

        String sanitizedSearchQuery = String.escapeSingleQuotes(args.searchQuery);
        String soslQuery = 'FIND \'' + sanitizedSearchQuery + '\' IN ALL FIELDS RETURNING ' + soslReturningClause + ' LIMIT ' + SOSL_QUERY_LIMIT;

        List<List<SObject>> searchResults;
        try {
            searchResults = Search.query(soslQuery);
        } catch (SearchException se) {
            throw new QueryException('SOSL search failed: ' + se.getMessage());
        }

        List<ScoredResult> finalRankedResults = scoreAndRankResults(searchResults, args.searchQuery, logPrefix);
        Map<String, Object> result = processRankedResults(finalRankedResults, logPrefix);
        return this.success((Map<String, Object>) result.get('data'), (String) result.get('messageForUser'), (String) result.get('internalDetails'));
    }

    private Map<String, List<String>> buildAccessibleReturnFieldMap(List<String> sObjectTypesFromArgs, String logPrefix) {
        Map<String, List<String>> accessibleMap = new Map<String, List<String>>();
        Set<String> targetSObjectNames = (sObjectTypesFromArgs != null && !sObjectTypesFromArgs.isEmpty())
            ? new Set<String>(sObjectTypesFromArgs)
            : this.configuredReturnFields.keySet();

        for (String sObjName : targetSObjectNames) {
            if (!this.configuredReturnFields.containsKey(sObjName))
                continue;

            SObjectType sObjType = SchemaUtils.getSObjectType(sObjName);
            if (sObjType != null && sObjType.getDescribe().isAccessible()) {
                List<String> accessibleFields = new List<String>();
                for (String fieldName : this.configuredReturnFields.get(sObjName)) {
                    if (SecurityUtils.hasFieldPermission(sObjType, fieldName, AccessType.READABLE)) {
                        accessibleFields.add(fieldName);
                    }
                }
                if (!accessibleFields.isEmpty()) {
                    accessibleMap.put(sObjName, accessibleFields);
                }
            }
        }
        return accessibleMap;
    }

    private String buildSoslReturningClause(Map<String, List<String>> accessibleReturnFields) {
        List<String> returningParts = new List<String>();
        for (String sObjName : accessibleReturnFields.keySet()) {
            String fields = String.join(accessibleReturnFields.get(sObjName), ', ');
            returningParts.add(sObjName + '(' + fields + ')');
        }
        return String.join(returningParts, ', ');
    }

    private List<ScoredResult> scoreAndRankResults(List<List<SObject>> searchResults, String searchQuery, String logPrefix) {
        List<ScoredResult> scoredList = new List<ScoredResult>();
        Integer initialScore = SOSL_QUERY_LIMIT;

        for (List<SObject> sObjectList : searchResults) {
            for (SObject sObj : sObjectList) {
                Integer score = initialScore--;
                String sObjNameLower = sObj.getSObjectType().getDescribe().getName().toLowerCase();
                ScoringInfo scoringInfo = this.scoringConfig.get(sObjNameLower);

                if (scoringInfo != null) {
                    Object nameValueObj = sObj.get(scoringInfo.primaryNameField);
                    if (nameValueObj != null && String.valueOf(nameValueObj).toLowerCase().contains(searchQuery.toLowerCase())) {
                        score += NAME_FIELD_MATCH_SCORE;
                    }

                    for (String keyField : scoringInfo.keyIdentifierFields) {
                        Object keyValueObj = sObj.get(keyField);
                        if (keyValueObj != null && String.valueOf(keyValueObj).toLowerCase().contains(searchQuery.toLowerCase())) {
                            score += KEY_FIELD_MATCH_SCORE;
                        }
                    }
                }
                scoredList.add(new ScoredResult(sObj, score, this.scoringConfig));
            }
        }
        scoredList.sort();
        return scoredList;
    }

    private Map<String, Object> processRankedResults(List<ScoredResult> rankedResults, String logPrefix) {
        Map<String, Object> result = new Map<String, Object>();

        if (rankedResults.isEmpty()) {
            result.put('data', new Map<String, Object>{ 'status' => STATUS_NOT_FOUND });
            result.put('messageForUser', 'No matching records found.');
            result.put('internalDetails', 'Search complete: No results.');
        } else if (rankedResults.size() == 1 || (rankedResults[0].score > rankedResults[1].score + (NAME_FIELD_MATCH_SCORE / 2))) {
            String msg = (rankedResults.size() == 1) ? 'Found a single matching record.' : 'Found a high-confidence match.';
            result.put('data', new Map<String, Object>{ 'status' => STATUS_SUCCESS, 'record' => buildRecordDataMap(rankedResults[0].record) });
            result.put('messageForUser', msg + ' Here are the details for ' + rankedResults[0].displayLabel + '.');
            result.put('internalDetails', 'Search complete: ' + msg);
        } else {
            List<Map<String, String>> options = new List<Map<String, String>>();
            for (Integer i = 0; i < Math.min(rankedResults.size(), this.maxAmbiguousResults); i++) {
                ScoredResult res = rankedResults[i];
                options.add(
                    new Map<String, String>{
                        'id' => res.record.Id,
                        'label' => res.displayLabel,
                        'sObjectType' => res.record.getSObjectType().getDescribe().getName()
                    }
                );
            }
            result.put('data', new Map<String, Object>{ 'status' => STATUS_AMBIGUOUS, 'options' => options });
            result.put('messageForUser', 'Found multiple possible matches. Please clarify which one you mean.');
            result.put('internalDetails', 'Search complete: Ambiguous matches found.');
        }
        return result;
    }

    private Map<String, Object> buildRecordDataMap(SObject record) {
        Map<String, Object> recordData = new Map<String, Object>();
        recordData.put('sObjectType', record.getSObjectType().getDescribe().getName());
        for (String field : record.getPopulatedFieldsAsMap().keySet()) {
            recordData.put(field, record.get(field));
        }
        return recordData;
    }

    private class ScoredResult implements Comparable {
        public SObject record { get; private set; }
        public Integer score { get; private set; }
        public String displayLabel { get; private set; }

        public ScoredResult(SObject record, Integer score, Map<String, ScoringInfo> dynamicScoringConfig) {
            this.record = record;
            this.score = score;
            this.displayLabel = buildDisplayLabel(record, dynamicScoringConfig);
        }

        private String buildDisplayLabel(SObject sObj, Map<String, ScoringInfo> dynamicScoringConfig) {
            String sObjNameLower = sObj.getSObjectType().getDescribe().getName().toLowerCase();
            ScoringInfo scoringInfo = dynamicScoringConfig.get(sObjNameLower);
            String primaryValue = (scoringInfo != null && sObj.isSet(scoringInfo.primaryNameField))
                ? String.valueOf(sObj.get(scoringInfo.primaryNameField))
                : sObj.Id;

            return primaryValue + ' (' + sObj.getSObjectType().getDescribe().getLabel() + ')';
        }

        public Integer compareTo(Object other) {
            return ((ScoredResult) other).score - this.score;
        }
    }
}
