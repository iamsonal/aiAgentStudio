/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * Utility class responsible for securely building SOQL queries based on declarative
 * ContextGraphSource__c definitions. Assumes config syntax/structure validated by Trigger.
 * Focuses on safe SOQL construction, bind variable generation, and runtime filterable/sortable checks.
 * Uses ContextUtils for schema validation.
 */
public inherited sharing class ContextQueryBuilder {
    public static final Set<String> ALLOWED_FILTER_OPERATORS = new Set<String>{
        '=',
        '!=',
        '<',
        '>',
        '<=',
        '>=',
        'IN',
        'NOT IN',
        'LIKE'
    };

    public class QueryDetails {
        /* Unchanged */ public String soqlQuery;
        public Map<String, Object> bindMap;
        public Boolean hasErrors;
        public String errorMessage;
        public QueryDetails() {
            this.bindMap = new Map<String, Object>();
            this.hasErrors = false;
        }
    }

    private Integer bindCounter_Instance = 0;

    /**
     * Builds a safe SOQL query string and bind map. Assumes input Source config has passed basic validation.
     * Checks runtime suitability (filterable/sortable) of fields using ContextUtils.
     * @return QueryDetails object. Caller MUST check `hasErrors` before using.
     */
    public QueryDetails buildDeclarativeQuery(
        ContextGraphSource__c source,
        List<Id> targetRecordIds,
        Map<String, Id> parentIdFilterMap
    ) {
        QueryDetails qd = new QueryDetails();
        String logPrefix = '[ContextQueryBuilder Src:' + source?.SourceDeveloperName__c + '] ';
        this.bindCounter_Instance = 0;

        if (String.isBlank(source.TargetSObjectApiName__c) || String.isBlank(source.TargetFieldSetName__c)) {
            return failQuery(qd, 'Config Error: Source missing required Target SObject/Field Set.', logPrefix);
        }

        Schema.SObjectType targetSObjectType = ContextUtils.getSObjectType(source.TargetSObjectApiName__c);
        if (targetSObjectType == null) {
            return failQuery(
                qd,
                'Runtime Error: Target SObject inaccessible: ' + source.TargetSObjectApiName__c,
                logPrefix
            );
        }
        if (!targetSObjectType.getDescribe().isQueryable()) {
            return failQuery(
                qd,
                'Runtime Error: Target SObject not queryable: ' + source.TargetSObjectApiName__c,
                logPrefix
            );
        }

        List<String> fieldPaths = FrameworkUtils.getFieldsFromFieldSet(targetSObjectType, source.TargetFieldSetName__c);
        if (fieldPaths == null) {
            return failQuery(qd, 'Runtime Error: Field Set not found: ' + source.TargetFieldSetName__c, logPrefix);
        }
        if (fieldPaths.isEmpty()) {
        }

        Set<String> fieldsToSelect = new Set<String>{ 'Id' };
        for (String path : fieldPaths) {
            if (isValidFieldPathSyntax(path))
                fieldsToSelect.add(path);
        }
        String selectClause = 'SELECT ' + String.join(new List<String>(fieldsToSelect), ', ');
        String fromClause = 'FROM ' + targetSObjectType.getDescribe().getName();

        List<String> whereConditions = new List<String>();

        if (targetRecordIds != null && !targetRecordIds.isEmpty()) {
            whereConditions.add(generateIdFilter('Id', targetRecordIds, qd.bindMap));
        }

        if (parentIdFilterMap != null && !parentIdFilterMap.isEmpty()) {
            for (String parentField : parentIdFilterMap.keySet()) {
                if (!ContextUtils.isFieldFilterable(targetSObjectType, parentField)) {
                    return failQuery(
                        qd,
                        'Runtime Error: Parent field "' + parentField + '" invalid/inaccessible/not filterable.',
                        logPrefix
                    );
                }
                whereConditions.add(
                    generateSimpleCondition(parentField, '=', parentIdFilterMap.get(parentField), qd.bindMap)
                );
            }
        }

        String filterByClause = '';
        if (String.isNotBlank(source.FilterBy__c)) {
            ContextUtils.ContextParseResult filterResult = ContextUtils.parseAndValidateFilterBy(
                source.FilterBy__c,
                targetSObjectType
            );
            if (filterResult.isValid && !filterResult.validatedConditions.isEmpty()) {
                List<String> filterParts = new List<String>();
                for (ContextUtils.ValidatedCondition vc : filterResult.validatedConditions) {
                    try {
                        filterParts.add(generateConditionClause(vc, targetSObjectType, qd.bindMap));
                    } catch (QueryBuilderException qbe) {
                        return failQuery(qd, qbe.getMessage(), logPrefix);
                    }
                }
                if (!filterParts.isEmpty()) {
                    filterByClause = '(' + String.join(filterParts, ' ' + filterResult.conditionLogic + ' ') + ')';
                }
            }
        }
        if (String.isNotBlank(filterByClause)) {
            whereConditions.add(filterByClause);
        }

        String whereClause = whereConditions.isEmpty() ? '' : 'WHERE ' + String.join(whereConditions, ' AND ');

        String orderByClause = '';
        if (String.isNotBlank(source.OrderBy__c)) {
            ContextUtils.ContextParseResult orderResult = ContextUtils.parseAndValidateOrderBy(
                source.OrderBy__c,
                targetSObjectType
            );
            if (!orderResult.isValid) {
                return failQuery(
                    qd,
                    'Runtime Error: Invalid OrderBy config detected: ' + orderResult.errorMessages[0],
                    logPrefix
                );
            }

            List<String> orderParts = new List<String>();
            for (ContextUtils.ValidatedOrder vo : orderResult.validatedOrders) {
                orderParts.add(vo.fieldPath + ' ' + vo.direction + ' NULLS ' + vo.nullsParam);
            }
            if (!orderParts.isEmpty()) {
                orderByClause = 'ORDER BY ' + String.join(orderParts, ', ');
            }
        }

        String limitClause = '';
        if (source.RecordLimit__c != null && source.RecordLimit__c > 0) {
            limitClause = 'LIMIT ' + String.valueOf(Math.min(source.RecordLimit__c.intValue(), 1000));
        }

        qd.soqlQuery = String.format(
                '{0} {1} {2} {3} {4}',
                new List<String>{ selectClause, fromClause, whereClause, orderByClause, limitClause }
            )
            .trim()
            .normalizeSpace();

        qd.hasErrors = false;
        return qd;
    }

    private class FilterParseResult {
        /* Unchanged */ String whereClausePart = '';
        Boolean hasErrors = false;
        String errorMessage = '';
    }
    private class OrderParseResult {
        /* Unchanged */ String orderByClause = '';
        Boolean hasErrors = false;
        String errorMessage = '';
    }

    private String generateSimpleCondition(String field, String operator, Object value, Map<String, Object> bindMap) {
        String bindName = generateBindVariableName(field);
        bindMap.put(bindName, value);
        return field + ' ' + operator + ' :' + bindName;
    }

    private String generateIdFilter(String field, List<Id> values, Map<String, Object> bindMap) {
        String bindName = generateBindVariableName(field + '_list');
        bindMap.put(bindName, values);
        return field + ' IN :' + bindName;
    }

    /**
     * (REVISED) Helper to generate the SOQL clause string and populate the bind map for a single validated condition.
     * Handles type coercion for IN clauses using the field token.
     * @param vc The validated condition object from ContextUtils.
     * @param targetSObjectType The SObjectType the field belongs to (needed for type checking).
     * @param bindMap The map to populate with bind variables.
     * @return The generated SOQL clause string for this condition.
     * @throws QueryBuilderException if errors occur during processing.
     */
    private String generateConditionClause(
        ContextUtils.ValidatedCondition vc,
        SObjectType targetSObjectType,
        Map<String, Object> bindMap
    ) {
        try {
            String fieldName = vc.fieldName;
            String operator = vc.operator;
            Object value = vc.value;

            SObjectField fieldToken = ContextUtils.getFieldToken(targetSObjectType, fieldName);
            if (fieldToken == null) {
                throw new QueryBuilderException(
                    'Internal Error: Field token not found at runtime for validated field: ' +
                        fieldName +
                        ' on ' +
                        targetSObjectType
                );
            }
            Schema.DisplayType fieldType = fieldToken.getDescribe().getType();

            if (value == null && (operator == '=' || operator == '!=')) {
                return fieldName + ' ' + operator + ' null';
            } else if (value == null) {
                throw new QueryBuilderException(
                    'Operator "' + operator + '" cannot be used with a null value for field ' + fieldName + '.'
                );
            }

            if (
                (fieldType == DisplayType.DATE ||
                fieldType == DisplayType.DATETIME) &&
                value instanceof String &&
                DATE_LITERALS.contains(((String) value).toUpperCase())
            ) {
                return fieldName + ' ' + operator + ' ' + ((String) value).toUpperCase();
            }

            if (operator == 'IN' || operator == 'NOT IN') {
                if (!(value instanceof List<Object>) || ((List<Object>) value).isEmpty()) {
                    throw new QueryBuilderException(
                        'Invalid value for ' + operator + ' field ' + fieldName + ' - must be non-empty List.'
                    );
                }
                List<Object> rawList = (List<Object>) value;
                List<Object> typedBindList = new List<Object>();

                if (fieldType == DisplayType.ID || fieldType == DisplayType.REFERENCE) {
                    List<Id> idList = new List<Id>();
                    for (Object item : rawList) {
                        try {
                            idList.add(Id.valueOf(String.valueOf(item)));
                        } catch (Exception e) {
                            throw new QueryBuilderException('Invalid ID "' + item + '" in IN list for ' + fieldName);
                        }
                    }
                    typedBindList = idList;
                } else if (
                    fieldType == DisplayType.PICKLIST ||
                    fieldType == DisplayType.MULTIPICKLIST ||
                    fieldType == DisplayType.STRING ||
                    fieldType == DisplayType.TEXTAREA ||
                    fieldType == DisplayType.EMAIL ||
                    fieldType == DisplayType.PHONE ||
                    fieldType == DisplayType.URL
                ) {
                    List<String> stringList = new List<String>();
                    for (Object item : rawList) {
                        stringList.add(String.valueOf(item));
                    }
                    typedBindList = stringList;
                } else if (fieldType == DisplayType.INTEGER) {
                    List<Integer> intList = new List<Integer>();
                    for (Object item : rawList) {
                        try {
                            intList.add(Integer.valueOf(String.valueOf(item)));
                        } catch (Exception e) {
                            throw new QueryBuilderException(
                                'Invalid Integer "' + item + '" in IN list for ' + fieldName
                            );
                        }
                    }
                    typedBindList = intList;
                } else if (
                    fieldType == DisplayType.DOUBLE ||
                    fieldType == DisplayType.CURRENCY ||
                    fieldType == DisplayType.PERCENT
                ) {
                    List<Decimal> decimalList = new List<Decimal>();
                    for (Object item : rawList) {
                        try {
                            decimalList.add(Decimal.valueOf(String.valueOf(item)));
                        } catch (Exception e) {
                            throw new QueryBuilderException(
                                'Invalid Number "' + item + '" in IN list for ' + fieldName
                            );
                        }
                    }
                    typedBindList = decimalList;
                } else {
                    throw new QueryBuilderException(
                        'Unsupported field type ' + fieldType + ' for IN clause dynamic binding for field ' + fieldName
                    );
                }

                if (typedBindList.isEmpty()) {
                    throw new QueryBuilderException(
                        'IN/NOT IN clause for field "' +
                            fieldName +
                            '" resulted in an empty list after type processing.'
                    );
                }

                String bindName = generateBindVariableName(fieldName + '_list');
                bindMap.put(bindName, typedBindList);
                return fieldName + ' ' + operator + ' :' + bindName;
            }

            if (value instanceof String && ((String) value).equalsIgnoreCase(':UserInfo.getUserId()')) {
                if (
                    fieldType != DisplayType.ID &&
                    fieldType != DisplayType.REFERENCE &&
                    fieldType != DisplayType.STRING
                ) {
                    throw new QueryBuilderException(
                        ':UserInfo.getUserId() cannot be used for field "' + fieldName + '" of type ' + fieldType
                    );
                }
                String bindName = generateBindVariableName(fieldName + '_user');
                bindMap.put(bindName, UserInfo.getUserId());
                return fieldName + ' ' + operator + ' :' + bindName;
            }

            return generateSimpleCondition(fieldName, operator, value, bindMap);
        } catch (Exception e) {
            String errMsg =
                '[CtxQueryBuilder.generateConditionClause] Failed processing field ' +
                vc.fieldName +
                ': ' +
                e.getMessage();

            if (e instanceof QueryBuilderException)
                throw e;
            throw new QueryBuilderException('Failed generating condition clause. Error: ' + e.getMessage(), e);
        }
    }

    private static final Set<String> DATE_LITERALS = new Set<String>{
        'YESTERDAY',
        'TODAY',
        'TOMORROW',
        'LAST_WEEK',
        'THIS_WEEK',
        'NEXT_WEEK',
        'LAST_MONTH',
        'THIS_MONTH',
        'NEXT_MONTH',
        'LAST_90_DAYS',
        'NEXT_90_DAYS',
        'THIS_QUARTER',
        'LAST_QUARTER',
        'NEXT_QUARTER',
        'THIS_YEAR',
        'LAST_YEAR',
        'NEXT_YEAR',
        'THIS_FISCAL_QUARTER',
        'LAST_FISCAL_QUARTER',
        'NEXT_FISCAL_QUARTER',
        'THIS_FISCAL_YEAR',
        'LAST_FISCAL_YEAR',
        'NEXT_FISCAL_YEAR'
    };

    private static Boolean isValidFieldPathSyntax(String fieldPath) {
        return String.isNotBlank(fieldPath) && Pattern.matches('^[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)*$', fieldPath);
    }
    private QueryDetails failQuery(QueryDetails qd, String message, String logPrefix) {
        qd.hasErrors = true;
        qd.errorMessage = message;
        qd.soqlQuery = null;
        qd.bindMap = new Map<String, Object>();
        return qd;
    }
    private String generateBindVariableName(String base) {
        this.bindCounter_Instance++;
        String sanitizedBase = base.replaceAll('[^a-zA-Z0-9_]', '').replaceAll('^_|_$', '');
        if (String.isBlank(sanitizedBase))
            sanitizedBase = 'bindvar';
        return 'cqb_bind_' + sanitizedBase + '_' + this.bindCounter_Instance;
    }

    public class QueryBuilderException extends Exception {
    }
}
