/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Service class for building and executing secure SOQL queries with bind variables,
 *              field-level security checks, and strict validation of filter/order parameters.
 */
public class QueryService {
    private static final Set<String> SUPPORTED_OPERATORS = new Set<String>{ '=', '!=', '>', '<', '>=', '<=', 'LIKE', 'IN' };

    public virtual class QueryValidationException extends Exception {
    }
    public class FilterValidationException extends QueryValidationException {
    }
    public class OrderByValidationException extends QueryValidationException {
    }

    private final SObjectType targetSObjectType;
    private final Map<String, Schema.SObjectField> allFieldsMap;
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

    /**
     * @description Constructor with basic required parameters
     * @param targetSObjectType The SObject type to query
     * @param logPrefix Optional logging prefix for debug statements
     */
    public QueryService(SObjectType targetSObjectType, String logPrefix) {
        this.targetSObjectType = targetSObjectType;
        this.allFieldsMap = targetSObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();
        this.logPrefix = String.isBlank(logPrefix) ? '[QueryService] ' : logPrefix;
        this.filters = new Map<String, Object>();
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
     * @description Builds and executes the SOQL query with provided bind map
     * @param bindMap Map to populate with bind variables
     * @return List<SObject> Results of the query
     */
    public List<SObject> executeQuery(Map<String, Object> bindMap) {
        String whereClause = buildWhereClauseWithBinds(this.filters, this.allFieldsMap, bindMap);
        prepareSelectFields(this.filterFieldsUsed);
        String orderByClause = validateAndBuildOrderBy(this.orderBy, this.allFieldsMap);

        String queryString = 'SELECT ' + String.join(finalFieldsToSelect, ', ') + ' FROM ' + targetSObjectType.getDescribe().getName();
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
     * @description Prepares the list of fields to include in the SELECT clause with FLS checks
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

        for (String fieldPath : requestedFields) {
            if (String.isBlank(fieldPath))
                continue;

            String baseFieldName = fieldPath.contains('.') ? fieldPath.substringBefore('.') : fieldPath;
            Schema.SObjectField fieldToken = allFieldsMap.get(baseFieldName.toLowerCase());

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
            throw new FilterValidationException('No accessible fields found to select based on request, configuration, filter criteria and FLS.');
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
                throw new FilterValidationException(
                    'Filter field "' + fieldName + '" not found on object ' + targetSObjectType.getDescribe().getName() + '.'
                );
            }
            Schema.DescribeFieldResult dfr = fieldToken.getDescribe();
            if (!dfr.isFilterable()) {
                throw new FilterValidationException('Filter field "' + fieldName + '" is not filterable.');
            }
            if (!dfr.isAccessible()) {
                throw new FilterValidationException('Filter field "' + fieldName + '" is not accessible to the current user.');
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
                        throw new FilterValidationException(
                            'Unsupported filter operator "' +
                                operatorKey +
                                '" provided for field "' +
                                fieldName +
                                '". Supported operators: ' +
                                String.join(new List<String>(SUPPORTED_OPERATORS), ', ')
                        );
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
                        throw new FilterValidationException(
                            'Invalid numeric format for field "' +
                                fieldNameForError +
                                '" (Type: ' +
                                fieldType +
                                '). Received "' +
                                rawValue +
                                '". Error: ' +
                                e.getMessage()
                        );
                    }
                } else {
                    throw new FilterValidationException(
                        'Expected Number or numeric String for field "' + fieldNameForError + '", got data type: ' + String.valueOf(rawValue)
                    );
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
            throw new OrderByValidationException(
                'Invalid ORDER BY syntax provided: "' + orderByParam + '". Expected format: FieldName [ASC|DESC] [NULLS FIRST|LAST].'
            );
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
