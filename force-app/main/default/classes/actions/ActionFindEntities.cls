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
 * The ActionConfiguration__c JSON for this action defines which objects are searchable and which fields to return.
 * The system uses a built-in map to understand primary name fields (e.g., Name, CaseNumber) and key identifier fields
 * (e.g., Email, AccountNumber) for intelligent scoring.
 *
 * @example ActionConfiguration__c JSON (This is now OPTIONAL and only used for maxAmbiguousResults)
 * {
 *   "maxAmbiguousResults": 3
 * }
 *
 * @returns {ActionResult} A structured result indicating the outcome: SUCCESS, AMBIGUOUS, or NOT_FOUND.
 */
public class ActionFindEntities extends BaseAgentAction {
    private static final String CONFIG_SEARCHABLE_OBJECTS = 'searchableObjects';
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

    private static final Map<String, KnownFieldInfo> KNOWN_FIELDS_MAP = new Map<String, KnownFieldInfo>{
        'Account' => new KnownFieldInfo('Name', new Set<String>{ 'AccountNumber', 'Phone' }),
        'Contact' => new KnownFieldInfo('Name', new Set<String>{ 'Email', 'Phone' }),
        'Opportunity' => new KnownFieldInfo('Name', new Set<String>{ 'NextStep' }),
        'Case' => new KnownFieldInfo('CaseNumber', new Set<String>{ 'Subject' }),
        'User' => new KnownFieldInfo('Name', new Set<String>{ 'Email' })
    };

    private Map<String, List<String>> configuredReturnFields;
    private Integer maxAmbiguousResults;

    protected override String getLogPrefixName() {
        return 'ActionFindEntities';
    }

    /**
     * @description *** UPDATED ***
     *              Populates the searchable objects and fields from the hard-coded KNOWN_FIELDS_MAP
     *              instead of from the ActionConfiguration JSON. It can still optionally read
     *              maxAmbiguousResults from the JSON if provided.
     * @param actionConfigurationJson The raw JSON string from the binding (may be null).
     * @param logPrefix Logging prefix.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        this.configuredReturnFields = new Map<String, List<String>>();
        this.maxAmbiguousResults = DEFAULT_MAX_AMBIGUOUS_RESULTS;

        for (String sObjName : KNOWN_FIELDS_MAP.keySet()) {
            KnownFieldInfo knowns = KNOWN_FIELDS_MAP.get(sObjName);
            List<String> fieldsForObject = new List<String>();

            if (String.isNotBlank(knowns.nameField)) {
                fieldsForObject.add(knowns.nameField);
            }
            if (knowns.keyIdentifierFields != null) {
                fieldsForObject.addAll(knowns.keyIdentifierFields);
            }

            if (!fieldsForObject.isEmpty()) {
                Set<String> fieldSet = new Set<String>(fieldsForObject);
                fieldSet.add('Id');
                this.configuredReturnFields.put(sObjName, new List<String>(fieldSet));
            }
        }

        if (this.configuredReturnFields.isEmpty()) {
            throw new ValidationException('Internal configuration error: KNOWN_FIELDS_MAP is empty or invalid.', null);
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
        return processRankedResults(finalRankedResults, logPrefix);
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
                KnownFieldInfo knowns = KNOWN_FIELDS_MAP.get(sObj.getSObjectType().getDescribe().getName());

                if (knowns != null) {
                    Object nameValueObj = sObj.get(knowns.nameField);
                    if (nameValueObj != null && String.valueOf(nameValueObj).toLowerCase().contains(searchQuery.toLowerCase())) {
                        score += NAME_FIELD_MATCH_SCORE;
                    }

                    for (String keyField : knowns.keyIdentifierFields) {
                        Object keyValueObj = sObj.get(keyField);
                        if (keyValueObj != null && String.valueOf(keyValueObj).toLowerCase().contains(searchQuery.toLowerCase())) {
                            score += KEY_FIELD_MATCH_SCORE;
                        }
                    }
                }
                scoredList.add(new ScoredResult(sObj, score));
            }
        }
        scoredList.sort();
        return scoredList;
    }

    private ActionResult processRankedResults(List<ScoredResult> rankedResults, String logPrefix) {
        if (rankedResults.isEmpty()) {
            return success(
                new Map<String, Object>{ 'status' => STATUS_NOT_FOUND, 'message' => 'No matching records found.' },
                'Search complete: No results.'
            );
        } else if (rankedResults.size() == 1) {
            return success(
                new Map<String, Object>{ 'status' => STATUS_SUCCESS, 'record' => buildRecordDataMap(rankedResults[0].record) },
                'Search complete: Found single match.'
            );
        } else {
            Integer topScore = rankedResults[0].score;
            Integer secondScore = rankedResults[1].score;
            if (topScore > secondScore + (NAME_FIELD_MATCH_SCORE / 2)) {
                return success(
                    new Map<String, Object>{ 'status' => STATUS_SUCCESS, 'record' => buildRecordDataMap(rankedResults[0].record) },
                    'Search complete: Found single high-confidence match.'
                );
            }

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
            return success(
                new Map<String, Object>{ 'status' => STATUS_AMBIGUOUS, 'options' => options },
                'Search complete: Ambiguous matches found.'
            );
        }
    }

    private Map<String, Object> buildRecordDataMap(SObject record) {
        Map<String, Object> recordData = new Map<String, Object>();
        recordData.put('sObjectType', record.getSObjectType().getDescribe().getName());
        for (String field : record.getPopulatedFieldsAsMap().keySet()) {
            recordData.put(field, record.get(field));
        }
        return recordData;
    }

    /** @description DTO to hold info about an SObject's key text fields. */
    private class KnownFieldInfo {
        public String nameField { get; private set; }
        public Set<String> keyIdentifierFields { get; private set; }

        public KnownFieldInfo(String nameField, Set<String> keyIdentifiers) {
            this.nameField = nameField;
            this.keyIdentifierFields = keyIdentifiers;
        }
    }

    /** @description Wrapper class to hold a record and its calculated relevance score. */
    private class ScoredResult implements Comparable {
        public SObject record { get; private set; }
        public Integer score { get; private set; }
        public String displayLabel { get; private set; }

        public ScoredResult(SObject record, Integer score) {
            this.record = record;
            this.score = score;
            this.displayLabel = buildDisplayLabel(record);
        }

        private String buildDisplayLabel(SObject sObj) {
            String sObjName = sObj.getSObjectType().getDescribe().getName();
            KnownFieldInfo knowns = KNOWN_FIELDS_MAP.get(sObjName);
            String primaryValue = (knowns != null && sObj.isSet(knowns.nameField)) ? String.valueOf(sObj.get(knowns.nameField)) : sObj.Id;

            return primaryValue + ' (' + sObj.getSObjectType().getDescribe().getLabel() + ')';
        }

        public Integer compareTo(Object other) {
            return ((ScoredResult) other).score - this.score;
        }
    }
}
