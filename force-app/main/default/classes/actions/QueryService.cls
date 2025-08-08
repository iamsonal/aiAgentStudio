/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Enterprise-grade service class for building and executing secure SOQL queries.
 *              Features AI-optimized query pattern detection, schema caching, and intelligent
 *              execution path selection for maximum performance in high-stakes environments.
 */
public class QueryService {
    private static final Set<String> SUPPORTED_OPERATORS = new Set<String>{ '=', '!=', '>', '<', '>=', '<=', 'LIKE', 'IN' };

    private static final Integer SIMPLE_PATH_FILTER_LIMIT = 3;
    private static final Integer COMPLEX_OPERATOR_THRESHOLD = 2;

    public virtual class QueryValidationException extends Exception {
    }
    public class FilterValidationException extends QueryValidationException {
    }
    public class OrderByValidationException extends QueryValidationException {
    }

    private final SObjectType targetSObjectType;
    private Map<String, Schema.SObjectField> allFieldsMap;
    private final String logPrefix;
    private final Set<String> requestedFields = new Set<String>();
    private final List<String> finalFieldsToSelect = new List<String>();
    private final Set<String> filterFieldsUsed = new Set<String>();
    private Integer bindCounter = 0;
    private Integer queryLimit = 10;
    private Map<String, Object> filters;
    private List<String> additionalFields = new List<String>();
    private List<String> defaultFields = new List<String>();
    private String orderBy;

    private QueryPatternAnalyzer.PatternAnalysis patternAnalysis;
    private Boolean useSimplePath = false;

    /**
     * @description Constructor with basic required parameters - optimized with lazy loading
     * @param targetSObjectType The SObject type to query
     * @param logPrefix Optional logging prefix for debug statements
     */
    public QueryService(SObjectType targetSObjectType, String logPrefix) {
        this.targetSObjectType = targetSObjectType;

        this.allFieldsMap = null;
        this.logPrefix = String.isBlank(logPrefix) ? '[QueryService] ' : logPrefix;
        this.filters = new Map<String, Object>();
    }

    /**
     * @description Lazy-loaded field map getter with caching optimization
     * @return Map of field API names to SObjectField tokens
     */
    private Map<String, Schema.SObjectField> getFieldMap() {
        if (this.allFieldsMap == null) {
            this.allFieldsMap = SchemaCache.getFieldMap(this.targetSObjectType);
        }
        return this.allFieldsMap;
    }

    /**
     * @description Sets the default fields to select
     * @param fields List of field API names
     * @return QueryService instance for method chaining
     */
    public QueryService withDefaultFields(List<String> fields) {
        if (fields != null) {
            this.defaultFields = fields;
        }
        return this;
    }

    /**
     * @description Sets additional fields to select
     * @param fields List of field API names
     * @return QueryService instance for method chaining
     */
    public QueryService withAdditionalFields(List<String> fields) {
        if (fields != null) {
            this.additionalFields = fields;
        }
        return this;
    }

    /**
     * @description Sets the filters for the WHERE clause
     * @param filters Map of field name to filter value or complex filter map
     * @return QueryService instance for method chaining
     */
    public QueryService withFilters(Map<String, Object> filters) {
        if (filters != null) {
            this.filters = filters;
        }
        return this;
    }

    /**
     * @description Sets the ORDER BY clause
     * @param orderBy String in format "FieldName [ASC|DESC] [NULLS FIRST|LAST]"
     * @return QueryService instance for method chaining
     */
    public QueryService withOrderBy(String orderBy) {
        this.orderBy = orderBy;
        return this;
    }

    /**
     * @description Sets the query LIMIT
     * @param queryLimit Integer value for query limit
     * @param maxPermittedLimit Optional maximum allowed limit value
     * @return QueryService instance for method chaining
     */
    public QueryService withLimit(Integer queryLimit, Integer maxPermittedLimit) {
        if (queryLimit > 0) {
            if (maxPermittedLimit != null && maxPermittedLimit > 0) {
                this.queryLimit = Math.min(queryLimit, maxPermittedLimit);
            } else {
                this.queryLimit = queryLimit;
            }
        }
        return this;
    }

    /**
     * @description Builds and executes the SOQL query
     * @return List<SObject> Results of the query
     */
    public List<SObject> executeQuery() {
        Map<String, Object> bindMap = new Map<String, Object>();
        return executeQuery(bindMap);
    }

    /**
     * @description Builds and executes the SOQL query with AI-optimized execution path selection
     * @param bindMap Map to populate with bind variables
     * @return List<SObject> Results of the query
     */
    public List<SObject> executeQuery(Map<String, Object> bindMap) {
        Long startTime = System.currentTimeMillis();

        try {
            this.patternAnalysis = QueryPatternAnalyzer.analyzeQuery(this.filters, this.orderBy, getFieldMap());
            this.useSimplePath = this.patternAnalysis.canUseSimplePath;

            if (!this.patternAnalysis.optimizationHints.isEmpty()) {
            }

            List<SObject> results;
            if (this.useSimplePath) {
                results = executeSimpleQuery(bindMap);
            } else {
                results = executeComplexQuery(bindMap);
            }

            Long executionTime = System.currentTimeMillis() - startTime;

            return results;
        } catch (Exception e) {
            if (!(e instanceof AIFriendlyQueryException)) {
                throw convertToAIException(e);
            }
            throw e;
        }
    }

    /**
     * @description Optimized execution path for simple queries
     * @param bindMap Map to populate with bind variables
     * @return List<SObject> Results of the query
     */
    private List<SObject> executeSimpleQuery(Map<String, Object> bindMap) {
        String whereClause = buildSimpleWhereClause(this.filters, bindMap);
        prepareSelectFieldsSimple(this.filterFieldsUsed);
        String orderByClause = buildSimpleOrderBy(this.orderBy);

        return executeQueryString(whereClause, orderByClause, bindMap);
    }

    /**
     * @description Full validation execution path for complex queries
     * @param bindMap Map to populate with bind variables
     * @return List<SObject> Results of the query
     */
    private List<SObject> executeComplexQuery(Map<String, Object> bindMap) {
        String whereClause = buildWhereClauseWithBinds(this.filters, getFieldMap(), bindMap);
        prepareSelectFields(this.filterFieldsUsed);
        String orderByClause = validateAndBuildOrderBy(this.orderBy, getFieldMap());

        return executeQueryString(whereClause, orderByClause, bindMap);
    }

    /**
     * @description Common query execution logic
     * @param whereClause The WHERE clause string
     * @param orderByClause The ORDER BY clause string
     * @param bindMap The bind variables map
     * @return List<SObject> Results of the query
     */
    private List<SObject> executeQueryString(String whereClause, String orderByClause, Map<String, Object> bindMap) {
        String objectName = SchemaCache.getDescribe(this.targetSObjectType).getName();
        String queryString = 'SELECT ' + String.join(finalFieldsToSelect, ', ') + ' FROM ' + objectName;

        if (String.isNotBlank(whereClause)) {
            queryString += ' WHERE ' + whereClause;
        }
        if (String.isNotBlank(orderByClause)) {
            queryString += ' ORDER BY ' + orderByClause;
        }
        queryString += ' LIMIT ' + this.queryLimit;

        return Database.queryWithBinds(queryString, bindMap, AccessLevel.USER_MODE);
    }

    /**
     * @description Simplified field preparation for simple query patterns
     * @param filterFields Fields identified as being used in the WHERE clause
     */
    private void prepareSelectFieldsSimple(Set<String> filterFields) {
        this.requestedFields.clear();
        this.finalFieldsToSelect.clear();

        if (this.defaultFields != null)
            requestedFields.addAll(this.defaultFields);
        if (this.additionalFields != null)
            requestedFields.addAll(this.additionalFields);
        if (filterFields != null)
            requestedFields.addAll(filterFields);
        requestedFields.add('Id');

        Map<String, Schema.SObjectField> fieldMap = getFieldMap();
        for (String fieldPath : requestedFields) {
            if (String.isBlank(fieldPath))
                continue;

            String baseFieldName = fieldPath.contains('.') ? fieldPath.substringBefore('.') : fieldPath;
            Schema.SObjectField fieldToken = fieldMap.get(baseFieldName.toLowerCase());

            if (fieldToken != null && fieldToken.getDescribe().isAccessible()) {
                this.finalFieldsToSelect.add(fieldPath);
            }
        }

        if (this.finalFieldsToSelect.isEmpty()) {
            this.finalFieldsToSelect.add('Id');
        }
    }

    /**
     * @description Full field preparation with comprehensive FLS checks (existing logic)
     * @param filterFields Fields identified as being used in the WHERE clause
     */
    private void prepareSelectFields(Set<String> filterFields) {
        this.requestedFields.clear();
        this.finalFieldsToSelect.clear();

        if (this.defaultFields != null)
            requestedFields.addAll(this.defaultFields);
        if (this.additionalFields != null)
            requestedFields.addAll(this.additionalFields);
        if (filterFields != null)
            requestedFields.addAll(filterFields);
        requestedFields.add('Id');

        Map<String, Schema.SObjectField> fieldMap = getFieldMap();
        for (String fieldPath : requestedFields) {
            if (String.isBlank(fieldPath))
                continue;

            String baseFieldName = fieldPath.contains('.') ? fieldPath.substringBefore('.') : fieldPath;
            Schema.SObjectField fieldToken = fieldMap.get(baseFieldName.toLowerCase());

            if (fieldToken != null) {
                Boolean isAccessible = false;

                if (!fieldPath.contains('.')) {
                    isAccessible = fieldToken.getDescribe().isAccessible();
                } else {
                    isAccessible = fieldToken.getDescribe().isAccessible();
                    if (isAccessible) {
                    }
                }

                if (isAccessible) {
                    this.finalFieldsToSelect.add(fieldPath);
                } else {
                }
            } else {
            }
        }

        if (this.finalFieldsToSelect.isEmpty()) {
            throw AIFriendlyQueryException.fieldNotAccessible('requested fields', SchemaCache.getDescribe(targetSObjectType).getName())
                .withContext('requestedFields', requestedFields);
        }
    }

    /**
     * @description Simplified WHERE clause builder for simple query patterns
     * @param filters Map from LLM arguments
     * @param bindMap Map to populate with bind variables
     * @return WHERE clause string or empty string
     */
    private String buildSimpleWhereClause(Map<String, Object> filters, Map<String, Object> bindMap) {
        if (filters == null || filters.isEmpty())
            return '';

        List<String> conditions = new List<String>();
        this.bindCounter = 0;
        this.filterFieldsUsed.clear();

        Map<String, Schema.SObjectField> fieldMap = getFieldMap();

        for (String fieldName : filters.keySet()) {
            Object filterValue = filters.get(fieldName);

            Schema.SObjectField fieldToken = fieldMap.get(fieldName.toLowerCase());
            if (fieldToken == null) {
                throw AIFriendlyQueryException.invalidField(fieldName, SchemaCache.getDescribe(targetSObjectType).getName());
            }

            Schema.DescribeFieldResult dfr = fieldToken.getDescribe();
            if (!dfr.isAccessible()) {
                throw AIFriendlyQueryException.fieldNotAccessible(fieldName, SchemaCache.getDescribe(targetSObjectType).getName());
            }

            this.filterFieldsUsed.add(dfr.getName());

            if (filterValue == null) {
                conditions.add(dfr.getName() + ' = null');
            } else {
                String bindName = 'filterBind' + this.bindCounter++;
                conditions.add(dfr.getName() + ' = :' + bindName);
                bindMap.put(bindName, filterValue);
            }
        }

        return String.join(conditions, ' AND ');
    }

    /**
     * @description Simplified ORDER BY builder for simple patterns
     * @param orderByParam The ORDER BY parameter
     * @return ORDER BY clause string
     */
    private String buildSimpleOrderBy(String orderByParam) {
        if (String.isBlank(orderByParam))
            return '';

        if (orderByParam.containsIgnoreCase('NULLS') || orderByParam.split('\\s+').size() > 2) {
            return validateAndBuildOrderBy(orderByParam, getFieldMap());
        }

        return orderByParam.trim();
    }

    /**
     * @description Converts standard exceptions to AI-friendly exceptions
     * @param originalException The original exception
     * @return AIFriendlyQueryException with structured error information
     */
    private AIFriendlyQueryException convertToAIException(Exception originalException) {
        String message = originalException.getMessage();
        String objectName = SchemaCache.getDescribe(targetSObjectType).getName();

        if (message.containsIgnoreCase('field') && message.containsIgnoreCase('not found')) {
            return AIFriendlyQueryException.invalidField('unknown', objectName).withContext('originalMessage', message);
        } else if (message.containsIgnoreCase('access') || message.containsIgnoreCase('permission')) {
            return AIFriendlyQueryException.securityViolation(objectName, 'query').withContext('originalMessage', message);
        } else if (message.containsIgnoreCase('order by')) {
            return AIFriendlyQueryException.invalidOrderBy(this.orderBy ?? 'unknown').withContext('originalMessage', message);
        } else {
            return new AIFriendlyQueryException(
                    message,
                    AIFriendlyQueryException.ErrorCode.GENERAL_VALIDATION,
                    'Review query parameters and ensure all fields and values are valid'
                )
                .withContext('originalException', originalException.getTypeName())
                .withContext('originalMessage', message);
        }
    }

    /**
     * @description Builds WHERE clause using bind variables with enhanced operator support.
     *              Handles simple filters {field: value} and complex {field: {op1: val1, op2: val2}}.
     * @param filters Map from LLM arguments
     * @param allFieldsMap Describe result map for the SObjectType
     * @param bindMap Map to populate with bind variables (passed by reference)
     * @return WHERE clause string or empty string
     */
    private String buildWhereClauseWithBinds(
        Map<String, Object> filters,
        Map<String, Schema.SObjectField> allFieldsMap,
        Map<String, Object> bindMap
    ) {
        List<String> conditions = new List<String>();
        if (filters == null || filters.isEmpty())
            return '';

        this.bindCounter = 0;
        this.filterFieldsUsed.clear();

        for (String fieldName : filters.keySet()) {
            Object filterValue = filters.get(fieldName);

            Schema.SObjectField fieldToken = allFieldsMap.get(fieldName.toLowerCase());
            if (fieldToken == null) {
                throw AIFriendlyQueryException.invalidField(fieldName, SchemaCache.getDescribe(targetSObjectType).getName());
            }
            Schema.DescribeFieldResult dfr = fieldToken.getDescribe();
            if (!dfr.isFilterable()) {
                throw AIFriendlyQueryException.fieldNotFilterable(fieldName, SchemaCache.getDescribe(targetSObjectType).getName());
            }
            if (!dfr.isAccessible()) {
                throw AIFriendlyQueryException.fieldNotAccessible(fieldName, SchemaCache.getDescribe(targetSObjectType).getName());
            }
            this.filterFieldsUsed.add(dfr.getName());

            if (filterValue instanceof Map<String, Object>) {
                Map<String, Object> complexFilter = (Map<String, Object>) filterValue;
                if (complexFilter.isEmpty()) {
                    continue;
                }

                for (String operatorKey : complexFilter.keySet()) {
                    String operator = operatorKey.toUpperCase();
                    Object actualValue = complexFilter.get(operatorKey);

                    if (!SUPPORTED_OPERATORS.contains(operator)) {
                        throw AIFriendlyQueryException.invalidOperator(operatorKey, fieldName)
                            .withContext('supportedOperators', new List<String>(SUPPORTED_OPERATORS));
                    }

                    String condition = generateSingleConditionClause(dfr, fieldName, operator, actualValue, bindMap);
                    conditions.add(condition);
                }
            } else {
                String operator = '=';
                Object actualValue = filterValue;
                String condition = generateSingleConditionClause(dfr, fieldName, operator, actualValue, bindMap);
                conditions.add(condition);
            }
        }

        return conditions.isEmpty() ? '' : String.join(conditions, ' AND ');
    }

    /**
     * Generates the SOQL clause string and populates bindMap for a SINGLE condition.
     * Called by buildWhereClauseWithBinds for both simple and complex filter structures.
     * @param dfr DescribeFieldResult of the target field
     * @param fieldName API name of the field
     * @param operator Uppercase comparison operator (e.g., '=', '>', 'IN')
     * @param actualValue The value to compare against (could be simple value or List for IN)
     * @param bindMap Map to populate with bind variables (passed by reference)
     * @return The generated SOQL condition clause string (e.g., "Name = :filterBind0", "Amount > :filterBind1")
     */
    private String generateSingleConditionClause(
        DescribeFieldResult dfr,
        String fieldName,
        String operator,
        Object actualValue,
        Map<String, Object> bindMap
    ) {
        String condition;
        String bindNameBase = 'filterBind' + this.bindCounter++;

        if (operator == 'IN') {
            if (!(actualValue instanceof List<Object>)) {
                throw new FilterValidationException(
                    'IN operator requires a List value for field "' + fieldName + '". Received: ' + String.valueOf(actualValue)
                );
            }
            List<Object> valueList = (List<Object>) actualValue;
            if (valueList.isEmpty()) {
                throw new FilterValidationException('Cannot use IN operator with an empty list for field ' + fieldName);
            }

            Schema.DisplayType fieldType = dfr.getType();
            Object bindList = null;

            try {
                if (fieldType == DisplayType.ID || fieldType == DisplayType.REFERENCE) {
                    List<Id> typedList = new List<Id>();
                    for (Object item : valueList)
                        typedList.add((Id) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (
                    fieldType == DisplayType.STRING ||
                    fieldType == DisplayType.PICKLIST ||
                    fieldType == DisplayType.MULTIPICKLIST ||
                    fieldType == DisplayType.TEXTAREA ||
                    fieldType == DisplayType.PHONE ||
                    fieldType == DisplayType.EMAIL ||
                    fieldType == DisplayType.URL
                ) {
                    List<String> typedList = new List<String>();
                    for (Object item : valueList)
                        typedList.add((String) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (fieldType == DisplayType.INTEGER) {
                    List<Integer> typedList = new List<Integer>();
                    for (Object item : valueList)
                        typedList.add((Integer) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (fieldType == DisplayType.DOUBLE || fieldType == DisplayType.CURRENCY || fieldType == DisplayType.PERCENT) {
                    List<Decimal> typedList = new List<Decimal>();
                    for (Object item : valueList)
                        typedList.add((Decimal) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (fieldType == DisplayType.DATE) {
                    List<Date> typedList = new List<Date>();
                    for (Object item : valueList)
                        typedList.add((Date) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (fieldType == DisplayType.DATETIME) {
                    List<Datetime> typedList = new List<Datetime>();
                    for (Object item : valueList)
                        typedList.add((Datetime) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else {
                    throw new FilterValidationException(
                        'Field type ' + fieldType + ' is not currently supported for IN operator list binding for field "' + fieldName + '".'
                    );
                }
            } catch (FilterValidationException e) {
                throw e;
            } catch (Exception ex) {
                throw new FilterValidationException(
                    'Unexpected error preparing IN list for field "' + fieldName + '". Check list values. Error: ' + ex.getMessage()
                );
            }

            String bindName = bindNameBase;
            condition = dfr.getName() + ' IN :' + bindName;
            bindMap.put(bindName, bindList);
        } else if (actualValue == null) {
            if (operator == '=')
                condition = dfr.getName() + ' = null';
            else if (operator == '!=')
                condition = dfr.getName() + ' != null';
            else
                throw new FilterValidationException(
                    'Operator "' + operator + '" cannot be used with an explicit null value for field ' + fieldName + '. Use "=" or "!=".'
                );
        } else {
            Object coercedValue = coerceFilterValue(actualValue, dfr, fieldName);
            String bindName = bindNameBase;
            condition = dfr.getName() + ' ' + operator + ' :' + bindName;
            bindMap.put(bindName, coercedValue);
        }
        return condition;
    }

    /**
     * @description Coerces a filter value based on the field type for WHERE clause conditions
     */
    private Object coerceFilterValue(Object rawValue, Schema.DescribeFieldResult dfr, String fieldNameForError) {
        Schema.DisplayType fieldType = dfr.getType();

        try {
            if (rawValue == null)
                return null;

            if (
                fieldType == DisplayType.INTEGER ||
                fieldType == DisplayType.DOUBLE ||
                fieldType == DisplayType.CURRENCY ||
                fieldType == DisplayType.PERCENT
            ) {
                Decimal decimalValue;

                if (rawValue instanceof Integer || rawValue instanceof Double || rawValue instanceof Decimal) {
                    decimalValue = Decimal.valueOf(String.valueOf(rawValue));
                } else if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
                    try {
                        decimalValue = Decimal.valueOf((String) rawValue);
                    } catch (Exception e) {
                        throw AIFriendlyQueryException.invalidValueType(fieldNameForError, fieldType.name(), rawValue)
                            .withContext('parseError', e.getMessage());
                    }
                } else {
                    throw AIFriendlyQueryException.invalidValueType(fieldNameForError, 'Number or numeric String', rawValue);
                }

                if (fieldType == DisplayType.INTEGER) {
                    try {
                        if (decimalValue.scale() > 0) {
                            throw new FilterValidationException(
                                'Decimal value "' + decimalValue + '" cannot be used for Integer field "' + fieldNameForError + '".'
                            );
                        }
                        return decimalValue.intValue();
                    } catch (Exception integerEx) {
                        throw new FilterValidationException(
                            'Value "' +
                                decimalValue +
                                '" cannot be converted to Integer for field "' +
                                fieldNameForError +
                                '". Error: ' +
                                integerEx.getMessage()
                        );
                    }
                } else {
                    return decimalValue;
                }
            } else if (fieldType == DisplayType.BOOLEAN) {
                if (rawValue instanceof Boolean)
                    return rawValue;
                if (rawValue instanceof String) {
                    if (((String) rawValue).equalsIgnoreCase('true'))
                        return true;
                    if (((String) rawValue).equalsIgnoreCase('false'))
                        return false;
                }

                if (rawValue instanceof Integer || rawValue instanceof Decimal) {
                    return Decimal.valueOf(String.valueOf(rawValue)) != 0;
                }
                throw new FilterValidationException(
                    'Invalid Boolean format for field "' + fieldNameForError + '". Expected true/false, got "' + rawValue + '".'
                );
            } else if (fieldType == DisplayType.ID || fieldType == DisplayType.REFERENCE) {
                if (rawValue instanceof String) {
                    try {
                        return Id.valueOf((String) rawValue);
                    } catch (Exception idEx) {
                        throw new FilterValidationException(
                            'Invalid Salesforce ID format for field "' + fieldNameForError + '". Received "' + rawValue + '".'
                        );
                    }
                }
                if (rawValue instanceof Id)
                    return rawValue;
                throw new FilterValidationException('Invalid data type for ID field "' + fieldNameForError + '". Received "' + rawValue + '".');
            } else if (fieldType == DisplayType.DATE) {
                if (rawValue instanceof String) {
                    try {
                        return Date.valueOf((String) rawValue);
                    } catch (Exception dateEx) {
                        throw new FilterValidationException(
                            'Invalid Date format for field "' + fieldNameForError + '". Expected YYYY-MM-DD. Received "' + rawValue + '".'
                        );
                    }
                }
                if (rawValue instanceof Date)
                    return rawValue;
                throw new FilterValidationException('Invalid data type for Date field "' + fieldNameForError + '". Received "' + rawValue + '".');
            } else if (fieldType == DisplayType.DATETIME) {
                if (rawValue instanceof String) {
                    String dateString = (String) rawValue;

                    try {
                        if (dateString.contains('T')) {
                            return Datetime.valueOfGmt(dateString);
                        } else if (dateString.contains(' ')) {
                            return Datetime.valueOf(dateString);
                        } else {
                            throw new FilterValidationException(
                                'Invalid datetime format for field "' +
                                    fieldNameForError +
                                    '". Use ISO 8601 or YYYY-MM-DD HH:MM:SS. Received: "' +
                                    rawValue +
                                    '"'
                            );
                        }
                    } catch (Exception dtEx) {
                        throw new FilterValidationException(
                            'Could not parse Datetime string for field "' +
                                fieldNameForError +
                                '". Received "' +
                                rawValue +
                                '". Error: ' +
                                dtEx.getMessage()
                        );
                    }
                }
                if (rawValue instanceof Datetime)
                    return rawValue;
                throw new FilterValidationException('Invalid data type for Datetime field "' + fieldNameForError + '". Received "' + rawValue + '".');
            } else if (
                dfr.getSOAPType() == Schema.SoapType.STRING ||
                fieldType == DisplayType.PICKLIST ||
                fieldType == DisplayType.MULTIPICKLIST ||
                fieldType == DisplayType.EMAIL ||
                fieldType == DisplayType.PHONE ||
                fieldType == DisplayType.URL ||
                fieldType == DisplayType.TEXTAREA ||
                fieldType == DisplayType.ENCRYPTEDSTRING
            ) {
                String stringVal = String.valueOf(rawValue);

                Integer fieldLength = dfr.getLength();
                if (fieldLength > 0 && stringVal.length() > fieldLength && fieldType != DisplayType.TEXTAREA) {
                    throw new FilterValidationException('Value length exceeds maximum (' + fieldLength + ') for field "' + fieldNameForError + '".');
                }
                return stringVal;
            }

            return rawValue;
        } catch (Exception e) {
            if (e instanceof FilterValidationException) {
                throw e;
            }

            throw new FilterValidationException(
                'Unexpected error coercing value for filter field "' + fieldNameForError + '". Details: ' + e.getMessage()
            );
        }
    }

    /**
     * @description Validates and builds ORDER BY clause
     */
    private String validateAndBuildOrderBy(String orderByParam, Map<String, Schema.SObjectField> allFieldsMap) {
        if (String.isBlank(orderByParam))
            return '';

        String fieldName;
        String direction = 'ASC';
        String nullsOrder = '';

        Pattern orderByPattern = Pattern.compile('(?i)^([a-zA-Z0-9_\\.]+)(?:\\s+(ASC|DESC))?(?:\\s+NULLS\\s+(FIRST|LAST))?$');
        Matcher m = orderByPattern.matcher(orderByParam.trim());

        if (m.matches()) {
            fieldName = m.group(1);
            if (String.isNotBlank(m.group(2))) {
                direction = m.group(2).toUpperCase();
            }
            if (String.isNotBlank(m.group(3))) {
                nullsOrder = m.group(3).toUpperCase();
            }
        } else {
            throw AIFriendlyQueryException.invalidOrderBy(orderByParam);
        }

        String baseFieldName = fieldName.contains('.') ? fieldName.substringBefore('.') : fieldName;
        Schema.SObjectField fieldToken = allFieldsMap.get(baseFieldName.toLowerCase());

        if (fieldToken == null) {
            String objName = !allFieldsMap.isEmpty()
                ? allFieldsMap.values()[0].getDescribe().getSObjectType().getDescribe().getName()
                : 'unknown object';
            throw new OrderByValidationException(
                'ORDER BY field "' + fieldName + '" (or its base relationship "' + baseFieldName + '") not found on object ' + objName + '.'
            );
        }

        Schema.DescribeFieldResult dfr = fieldToken.getDescribe();
        if (!dfr.isSortable()) {
            throw new OrderByValidationException('ORDER BY field "' + fieldName + '" is not sortable.');
        }
        if (!dfr.isAccessible()) {
            throw new OrderByValidationException('ORDER BY field "' + fieldName + '" is not accessible to the current user.');
        }

        String finalNullsClause = '';
        if (String.isNotBlank(nullsOrder)) {
            finalNullsClause = ' NULLS ' + nullsOrder;
        } else {
            finalNullsClause = (direction == 'DESC') ? ' NULLS FIRST' : ' NULLS LAST';
        }

        return fieldName + ' ' + direction + finalNullsClause;
    }
}
