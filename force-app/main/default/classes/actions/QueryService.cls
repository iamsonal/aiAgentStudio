/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Production-ready SOQL query builder for LLM-driven data access.
 * Converts dynamic filter criteria and field selections to validated SOQL queries.
 */
public class QueryService {
    // Supported Filter Operators
    private static final Set<String> SUPPORTED_OPERATORS = new Set<String>{ '=', '!=', '>', '<', '>=', '<=', 'LIKE', 'IN' };

    public class FilterValidationException extends Exception {
    }
    public class OrderByValidationException extends Exception {
    }

    // Internal state - optimized with lazy loading
    private final SObjectType targetSObjectType;
    private Map<String, Schema.SObjectField> allFieldsMap; // Now lazy-loaded
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
     * Initializes QueryService with schema caching.
     *
     * @param targetSObjectType SObject type to query against
     * @param logPrefix Logging prefix for debug output
     */
    public QueryService(SObjectType targetSObjectType, String logPrefix) {
        this.targetSObjectType = targetSObjectType;
        // Lazy load field map for better memory efficiency
        this.allFieldsMap = null;
        this.logPrefix = String.isBlank(logPrefix) ? '[QueryService] ' : logPrefix;
        this.filters = new Map<String, Object>();
    }

    /**
     * Retrieves field metadata map with caching.
     *
     * @return Map of lowercase field API names to SObjectField tokens
     */
    private Map<String, Schema.SObjectField> getFieldMap() {
        if (this.allFieldsMap == null) {
            this.allFieldsMap = SchemaUtils.getObjectFields(this.targetSObjectType);
        }
        return this.allFieldsMap;
    }

    /**
     * Sets default fields to select.
     *
     * @param fields List of field API names
     * @return QueryService instance for chaining
     */
    public QueryService withDefaultFields(List<String> fields) {
        if (fields != null) {
            this.defaultFields = fields;
        }
        return this;
    }

    /**
     * Sets additional fields to select.
     *
     * @param fields List of field API names
     * @return QueryService instance for chaining
     */
    public QueryService withAdditionalFields(List<String> fields) {
        if (fields != null) {
            this.additionalFields = fields;
        }
        return this;
    }

    /**
     * Sets filters for the WHERE clause.
     *
     * @param filters Map of field name to filter value or complex filter map
     * @return QueryService instance for chaining
     */
    public QueryService withFilters(Map<String, Object> filters) {
        if (filters != null) {
            this.filters = filters;
        }
        return this;
    }

    /**
     * Sets ORDER BY clause for the query.
     *
     * @param orderBy String in format "FieldName [ASC|DESC] [NULLS FIRST|LAST]"
     * @return QueryService instance for chaining
     */
    public QueryService withOrderBy(String orderBy) {
        this.orderBy = orderBy;
        return this;
    }

    /**
     * Sets query LIMIT with optional maximum enforcement.
     *
     * @param queryLimit Integer value for query limit
     * @param maxPermittedLimit Optional maximum allowed limit
     * @return QueryService instance for chaining
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
     * Builds and executes the SOQL query.
     *
     * @return QueryResult with results or error information
     */
    public QueryResult executeQuery() {
        Map<String, Object> bindMap = new Map<String, Object>();
        return executeQuery(bindMap);
    }

    /**
     * Executes SOQL query with optimized validation routing.
     *
     * @param bindMap Map populated with bind variables for secure parameter binding
     * @return QueryResult Query results with USER_MODE security enforcement or error information
     */
    public QueryResult executeQuery(Map<String, Object> bindMap) {
        Long startTime = System.currentTimeMillis();

        try {
            // Execute query with comprehensive validation
            String whereClause = buildWhereClauseWithBinds(this.filters, getFieldMap(), bindMap);
            prepareSelectFields(this.filterFieldsUsed);
            String orderByClause = validateAndBuildOrderBy(this.orderBy, getFieldMap());

            List<SObject> results = executeQueryString(whereClause, orderByClause, bindMap);

            // Log execution metrics for performance monitoring
            Long executionTime = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, logPrefix + 'Query executed in ' + executionTime + 'ms. Records=' + results.size());

            return QueryResult.success(results);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Query execution failed: ' + e.getMessage());
            // Convert to structured AI-friendly exception format
            if (e instanceof QueryServiceException) {
                QueryServiceException aiEx = (QueryServiceException) e;
                return QueryResult.failure('INPUT_VALIDATION', aiEx.getMessage());
            } else {
                return QueryResult.failure('SOQL_ERROR', 'Query execution failed: ' + e.getMessage());
            }
        }
    }

    /**
     * Validates that provided fields are valid on the configured SObject.
     *
     * @param fields List of field API names to validate
     * @return QueryResult with validation details
     */
    public QueryResult validateFields(List<String> fields) {
        if (fields == null || fields.isEmpty()) {
            return QueryResult.success(new List<SObject>());
        }

        Map<String, Schema.SObjectField> fieldMap = getFieldMap();
        String objectName = SchemaUtils.getDescribe(this.targetSObjectType).getName();

        for (String field : fields) {
            if (String.isBlank(field)) {
                continue;
            }

            String baseFieldName = field.contains('.') ? field.substringBefore('.') : field;
            Schema.SObjectField fieldToken = fieldMap.get(baseFieldName.toLowerCase());

            // If direct field lookup fails and this is a relationship field, try with 'Id' suffix
            if (fieldToken == null && field.contains('.')) {
                String relationshipFieldName = baseFieldName + 'Id';
                fieldToken = fieldMap.get(relationshipFieldName.toLowerCase());
            }

            if (fieldToken == null) {
                return QueryResult.failure('INPUT_VALIDATION', 'Invalid field "' + field + '" on object "' + objectName + '". Field does not exist.');
            }
        }

        return QueryResult.success(new List<SObject>());
    }

    /**
     * Executes final SOQL query with validation and security enforcement.
     *
     * @param whereClause WHERE clause string
     * @param orderByClause The ORDER BY clause string
     * @param bindMap The bind variables map
     * @return List<SObject> Results of the query
     */
    private List<SObject> executeQueryString(String whereClause, String orderByClause, Map<String, Object> bindMap) {
        // Assemble final query string
        String objectName = SchemaUtils.getDescribe(this.targetSObjectType).getName();
        String queryString = 'SELECT ' + String.join(finalFieldsToSelect, ', ') + ' FROM ' + objectName;

        if (String.isNotBlank(whereClause)) {
            queryString += ' WHERE ' + whereClause;
        }
        if (String.isNotBlank(orderByClause)) {
            queryString += ' ORDER BY ' + orderByClause;
        }
        queryString += ' LIMIT ' + this.queryLimit;

        System.debug(LoggingLevel.INFO, logPrefix + 'Executing Query: ' + queryString + ' | Binds: ' + JSON.serialize(bindMap)?.abbreviate(500));

        // Execute query with USER_MODE
        return Database.queryWithBinds(queryString, bindMap, AccessLevel.USER_MODE);
    }

    /**
     * Prepares fields with existence validation.
     * FLS enforcement delegated to USER_MODE execution.
     *
     * @param filterFields Fields identified as being used in the WHERE clause
     * @throws QueryServiceException if fields don't exist or no valid fields remain
     */
    private void prepareSelectFields(Set<String> filterFields) {
        this.requestedFields.clear(); // Ensure fresh list
        this.finalFieldsToSelect.clear();

        // Combine fields from configuration and parameters
        if (this.defaultFields != null)
            requestedFields.addAll(this.defaultFields);
        if (this.additionalFields != null)
            requestedFields.addAll(this.additionalFields);
        if (filterFields != null)
            requestedFields.addAll(filterFields);
        requestedFields.add('Id'); // Always include Id

        // Validate field existence (FLS will be enforced by USER_MODE at query execution time)
        Map<String, Schema.SObjectField> fieldMap = getFieldMap();
        for (String fieldPath : requestedFields) {
            if (String.isBlank(fieldPath))
                continue;

            // Simple Check for now - only direct fields or single level relationship
            String baseFieldName = fieldPath.contains('.') ? fieldPath.substringBefore('.') : fieldPath;
            Schema.SObjectField fieldToken = fieldMap.get(baseFieldName.toLowerCase());

            // If direct field lookup fails and this is a relationship field, try with 'Id' suffix
            if (fieldToken == null && fieldPath.contains('.')) {
                String relationshipFieldName = baseFieldName + 'Id';
                fieldToken = fieldMap.get(relationshipFieldName.toLowerCase());
            }

            if (fieldToken != null) {
                // Field exists - add it to SELECT list. USER_MODE will enforce FLS at runtime.
                this.finalFieldsToSelect.add(fieldPath);
                System.debug(
                    LoggingLevel.DEBUG,
                    logPrefix + 'Added field "' + fieldPath + '" to SELECT clause. FLS will be enforced by USER_MODE query execution.'
                );
            } else {
                // Throw exception for invalid fields to provide clear feedback to AI agents
                throw QueryServiceException.invalidField(fieldPath, SchemaUtils.getDescribe(targetSObjectType).getName());
            }
        }

        if (this.finalFieldsToSelect.isEmpty()) {
            throw QueryServiceException.fieldNotAccessible('requested fields', SchemaUtils.getDescribe(targetSObjectType).getName())
                .withContext('requestedFields', requestedFields);
        }
    }

    /**
     * Builds WHERE clause with bind variables.
     * Handles simple and complex filters with operator support.
     *
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

        // Reset bindCounter for this specific build
        this.bindCounter = 0;
        this.filterFieldsUsed.clear();

        for (String fieldName : filters.keySet()) {
            Object filterValue = filters.get(fieldName);

            // Field validation (Perform once per field)
            Schema.SObjectField fieldToken = allFieldsMap.get(fieldName.toLowerCase());
            if (fieldToken == null) {
                throw QueryServiceException.invalidField(fieldName, SchemaUtils.getDescribe(targetSObjectType).getName());
            }
            Schema.DescribeFieldResult dfr = fieldToken.getDescribe();
            if (!dfr.isFilterable()) {
                throw QueryServiceException.fieldNotFilterable(fieldName, SchemaUtils.getDescribe(targetSObjectType).getName());
            }
            if (!dfr.isAccessible()) {
                throw QueryServiceException.fieldNotAccessible(fieldName, SchemaUtils.getDescribe(targetSObjectType).getName());
            }
            this.filterFieldsUsed.add(dfr.getName()); // Track fields used for filtering/selection

            // Condition Generation Logic (Handles simple and complex filters)
            if (filterValue instanceof Map<String, Object>) {
                // Complex Filter: {field: {op1: val1, op2: val2}}
                Map<String, Object> complexFilter = (Map<String, Object>) filterValue;
                if (complexFilter.isEmpty()) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Empty complex filter map provided for field "' + fieldName + '". Skipping.');
                    continue;
                }
                // Iterate through EACH operator specified for this field
                for (String operatorKey : complexFilter.keySet()) {
                    String operator = operatorKey.toUpperCase();
                    Object actualValue = complexFilter.get(operatorKey);

                    // Validate the operator from the inner map
                    if (!SUPPORTED_OPERATORS.contains(operator)) {
                        throw QueryServiceException.invalidOperator(operatorKey, fieldName)
                            .withContext('supportedOperators', new List<String>(SUPPORTED_OPERATORS));
                    }

                    // Generate condition for this specific operator-value pair
                    String condition = generateSingleConditionClause(dfr, fieldName, operator, actualValue, bindMap);
                    conditions.add(condition);
                }
            } else {
                // Simple Filter: {field: value} (Implicit '=')
                String operator = '=';
                Object actualValue = filterValue;
                String condition = generateSingleConditionClause(dfr, fieldName, operator, actualValue, bindMap);
                conditions.add(condition);
            }
        }

        return conditions.isEmpty() ? '' : String.join(conditions, ' AND ');
    }

    /**
     * Generates SOQL clause for a single condition with bind variables.
     * Called by buildWhereClauseWithBinds for both simple and complex filters.
     *
     * @param dfr DescribeFieldResult of the target field
     * @param fieldName API name of the field
     * @param operator Uppercase comparison operator (e.g., '=', '>', 'IN')
     * @param actualValue The value to compare against (could be simple value or List for IN)
     * @param bindMap Map to populate with bind variables (passed by reference)
     * @return The generated SOQL condition clause string (e.g., "Name = :filterBind0", "Amount > :filterBind1")
     */
    private String generateSingleConditionClause(
        Schema.DescribeFieldResult dfr,
        String fieldName,
        String operator,
        Object actualValue,
        Map<String, Object> bindMap
    ) {
        String condition;
        String bindNameBase = 'filterBind' + this.bindCounter++; // Increment instance counter

        // --- Logic for generating condition based on operator and actualValue ---
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
            Object bindList = null; // Use Object initially to hold the correctly typed list

            try {
                if (fieldType == Schema.DisplayType.ID || fieldType == Schema.DisplayType.REFERENCE) {
                    List<Id> typedList = new List<Id>();
                    for (Object item : valueList)
                        typedList.add((Id) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (
                    fieldType == Schema.DisplayType.STRING ||
                    fieldType == Schema.DisplayType.PICKLIST ||
                    fieldType == Schema.DisplayType.MULTIPICKLIST ||
                    fieldType == Schema.DisplayType.TEXTAREA ||
                    fieldType == Schema.DisplayType.PHONE ||
                    fieldType == Schema.DisplayType.EMAIL ||
                    fieldType == Schema.DisplayType.URL
                ) {
                    List<String> typedList = new List<String>();
                    for (Object item : valueList)
                        typedList.add((String) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (fieldType == Schema.DisplayType.INTEGER) {
                    List<Integer> typedList = new List<Integer>();
                    for (Object item : valueList)
                        typedList.add((Integer) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (
                    fieldType == Schema.DisplayType.DOUBLE ||
                    fieldType == Schema.DisplayType.CURRENCY ||
                    fieldType == Schema.DisplayType.PERCENT
                ) {
                    List<Decimal> typedList = new List<Decimal>();
                    for (Object item : valueList)
                        typedList.add((Decimal) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (fieldType == Schema.DisplayType.DATE) {
                    List<Date> typedList = new List<Date>();
                    for (Object item : valueList)
                        typedList.add((Date) coerceFilterValue(item, dfr, fieldName));
                    bindList = typedList;
                } else if (fieldType == Schema.DisplayType.DATETIME) {
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
            } // Rethrow validation exceptions
            catch (Exception ex) {
                throw new FilterValidationException(
                    'Unexpected error preparing IN list for field "' + fieldName + '". Check list values. Error: ' + ex.getMessage()
                );
            }

            String bindName = bindNameBase;
            condition = dfr.getName() + ' IN :' + bindName;
            bindMap.put(bindName, bindList);
        } else if (actualValue == null) {
            // Handle null after IN check
            if (operator == '=')
                condition = dfr.getName() + ' = null';
            else if (operator == '!=')
                condition = dfr.getName() + ' != null';
            else
                throw new FilterValidationException(
                    'Operator "' + operator + '" cannot be used with an explicit null value for field ' + fieldName + '. Use "=" or "!=".'
                );
            // No bind variable needed for null checks
        } else {
            // --- Handle standard operators (=, !=, >, <, >=, <=, LIKE) ---
            Object coercedValue = coerceFilterValue(actualValue, dfr, fieldName);
            String bindName = bindNameBase;
            condition = dfr.getName() + ' ' + operator + ' :' + bindName;
            bindMap.put(bindName, coercedValue);
        }
        return condition;
    }

    /**
     * Coerces filter value based on field type for WHERE clause.
     *
     * @param rawValue The raw filter value
     * @param dfr DescribeFieldResult of the target field
     * @param fieldNameForError Field name for error messages
     * @return Object coerced to the correct type for binding
     * @throws FilterValidationException or QueryServiceException on invalid input
     */
    private Object coerceFilterValue(Object rawValue, Schema.DescribeFieldResult dfr, String fieldNameForError) {
        Schema.DisplayType fieldType = dfr.getType();

        try {
            if (rawValue == null)
                return null;

            // Numeric Types
            if (
                fieldType == Schema.DisplayType.INTEGER ||
                fieldType == Schema.DisplayType.DOUBLE ||
                fieldType == Schema.DisplayType.CURRENCY ||
                fieldType == Schema.DisplayType.PERCENT
            ) {
                Decimal decimalValue;
                // Attempt to create a Decimal value first for validation and consistent parsing
                if (rawValue instanceof Integer || rawValue instanceof Double || rawValue instanceof Decimal) {
                    decimalValue = Decimal.valueOf(String.valueOf(rawValue));
                } else if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
                    try {
                        decimalValue = Decimal.valueOf((String) rawValue);
                    } catch (Exception e) {
                        throw QueryServiceException.invalidValueType(fieldNameForError, fieldType.name(), rawValue)
                            .withContext('parseError', e.getMessage());
                    }
                } else {
                    // If it's not a direct number or string, throw error
                    throw QueryServiceException.invalidValueType(fieldNameForError, 'Number or numeric String', rawValue);
                }

                // *** Important: Return the specific type expected by the field ***
                if (fieldType == Schema.DisplayType.INTEGER) {
                    try {
                        // Check if it exceeds Integer limits
                        if (decimalValue.scale() > 0) {
                            throw new FilterValidationException(
                                'Decimal value "' + decimalValue + '" cannot be used for Integer field "' + fieldNameForError + '".'
                            );
                        }
                        return decimalValue.intValue(); // Return Integer if field is Integer type
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
                    return decimalValue; // Return Decimal for Double, Currency, Percent
                }
            }
            // Boolean
            else if (fieldType == Schema.DisplayType.BOOLEAN) {
                if (rawValue instanceof Boolean)
                    return rawValue;
                if (rawValue instanceof String) {
                    if (((String) rawValue).equalsIgnoreCase('true'))
                        return true;
                    if (((String) rawValue).equalsIgnoreCase('false'))
                        return false;
                }
                // Optionally handle 0/1 for boolean
                if (rawValue instanceof Integer || rawValue instanceof Decimal) {
                    return Decimal.valueOf(String.valueOf(rawValue)) != 0;
                }
                throw new FilterValidationException(
                    'Invalid Boolean format for field "' + fieldNameForError + '". Expected true/false, got "' + rawValue + '".'
                );
            }
            // ID / Reference
            else if (fieldType == Schema.DisplayType.ID || fieldType == Schema.DisplayType.REFERENCE) {
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
            }
            // Date
            else if (fieldType == Schema.DisplayType.DATE) {
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
            }
            // Datetime
            else if (fieldType == Schema.DisplayType.DATETIME) {
                if (rawValue instanceof String) {
                    String dateString = (String) rawValue;
                    // Handle multiple datetime formats, standardizing towards 'T' separator if space exists
                    try {
                        if (dateString.contains('T')) {
                            return Datetime.valueOfGmt(dateString); // Assumes GMT if Z specified or handled by platform
                        } else if (dateString.contains(' ')) {
                            return Datetime.valueOf(dateString); // Assume local timezone parse
                        } else {
                            // Handle date-only strings by converting to Date first, then to Datetime
                            try {
                                Date dateOnly = Date.valueOf(dateString);
                                return Datetime.newInstance(dateOnly, Time.newInstance(0, 0, 0, 0));
                            } catch (Exception dateEx) {
                                throw new FilterValidationException(
                                    'Invalid datetime format for field "' +
                                        fieldNameForError +
                                        '". Use ISO 8601, YYYY-MM-DD HH:MM:SS, or YYYY-MM-DD. Received: "' +
                                        rawValue +
                                        '"'
                                );
                            }
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
            }
            // String and other types that bind as String
            else if (
                dfr.getSOAPType() == Schema.SoapType.STRING ||
                fieldType == Schema.DisplayType.PICKLIST || // Bind Picklists as String
                fieldType == Schema.DisplayType.MULTIPICKLIST || // Bind Multipicklist as String (single value for filters other than IN)
                fieldType == Schema.DisplayType.EMAIL ||
                fieldType == Schema.DisplayType.PHONE ||
                fieldType == Schema.DisplayType.URL ||
                fieldType == Schema.DisplayType.TEXTAREA ||
                fieldType == Schema.DisplayType.ENCRYPTEDSTRING
            ) {
                String stringVal = String.valueOf(rawValue);
                // Basic Length check (excluding TextArea/LongTextArea handled by DML limits)
                Integer fieldLength = dfr.getLength();
                if (fieldLength > 0 && stringVal.length() > fieldLength && fieldType != Schema.DisplayType.TEXTAREA) {
                    throw new FilterValidationException('Value length exceeds maximum (' + fieldLength + ') for field "' + fieldNameForError + '".');
                }
                return stringVal;
            }

            // Fallback for any unhandled types - may or may not work with binding
            System.debug(
                LoggingLevel.WARN,
                'Coercing value for unhandled field type: ' + fieldNameForError + ' (' + fieldType + '). Attempting direct pass.'
            );
            return rawValue;
        } catch (Exception e) {
            // Catch specific FilterValidationExceptions and rethrow them
            if (e instanceof FilterValidationException) {
                throw e;
            }
            // Wrap other unexpected exceptions
            System.debug(LoggingLevel.ERROR, 'Unexpected error coercing value for ' + fieldNameForError + ': ' + e.getMessage());
            throw new FilterValidationException(
                'Unexpected error coercing value for filter field "' + fieldNameForError + '". Details: ' + e.getMessage()
            );
        }
    }

    /**
     * Validates and builds ORDER BY clause, enforcing field existence and FLS.
     *
     * @param orderByParam The ORDER BY parameter
     * @param allFieldsMap Describe result map for the SObjectType
     * @return String ORDER BY clause
     * @throws OrderByValidationException or QueryServiceException on invalid input
     */
    private String validateAndBuildOrderBy(String orderByParam, Map<String, Schema.SObjectField> allFieldsMap) {
        if (String.isBlank(orderByParam))
            return '';

        String fieldName;
        String direction = 'ASC';
        String nullsOrder = '';

        // Parse "FieldName [ASC|DESC] [NULLS FIRST|LAST]"
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
            throw QueryServiceException.invalidOrderBy(orderByParam);
        }

        // Field validation
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

        // Construct final clause with explicit NULLS handling
        String finalNullsClause = '';
        if (String.isNotBlank(nullsOrder)) {
            finalNullsClause = ' NULLS ' + nullsOrder;
        } else {
            finalNullsClause = (direction == 'DESC') ? ' NULLS FIRST' : ' NULLS LAST';
        }

        return fieldName + ' ' + direction + finalNullsClause;
    }
}
