/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description AI-optimized exception handling for query operations.
 *              Provides structured error information that AI agents can understand and act upon.
 *              Includes error codes, suggested fixes, and contextual information for debugging.
 */
public class AIFriendlyQueryException extends Exception {
    /**
     * @description Standardized error codes for AI agent consumption
     */
    public enum ErrorCode {
        INVALID_FIELD,
        FIELD_NOT_ACCESSIBLE,
        FIELD_NOT_FILTERABLE,
        INVALID_OPERATOR,
        INVALID_VALUE_TYPE,
        INVALID_ORDER_BY,
        QUERY_TOO_COMPLEX,
        SECURITY_VIOLATION,
        SOQL_INJECTION_RISK,
        QUERY_TIMEOUT,
        INVALID_LIMIT,
        EMPTY_IN_LIST,
        GENERAL_VALIDATION
    }

    /**
     * @description Severity levels for error classification
     */
    public enum Severity {
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL
    }

    public ErrorCode errorCode { get; private set; }
    public Severity severity { get; private set; }
    public String suggestedFix { get; private set; }
    public String fieldName { get; private set; }
    public String objectName { get; private set; }
    public Map<String, Object> context { get; private set; }
    public List<String> alternativeSolutions { get; private set; }

    /**
     * @description Constructor with full error context
     * @param message Human-readable error message
     * @param errorCode Standardized error code
     * @param severity Error severity level
     * @param suggestedFix AI-actionable fix suggestion
     * @param fieldName Field name involved in error (if applicable)
     * @param objectName SObject name involved in error (if applicable)
     */
    public AIFriendlyQueryException(
        String message,
        ErrorCode errorCode,
        Severity severity,
        String suggestedFix,
        String fieldName,
        String objectName
    ) {
        this(message);
        this.errorCode = errorCode;
        this.severity = severity;
        this.suggestedFix = suggestedFix;
        this.fieldName = fieldName;
        this.objectName = objectName;
        this.context = new Map<String, Object>();
        this.alternativeSolutions = new List<String>();
    }

    /**
     * @description Simplified constructor for common cases
     * @param message Human-readable error message
     * @param errorCode Standardized error code
     * @param suggestedFix AI-actionable fix suggestion
     */
    public AIFriendlyQueryException(String message, ErrorCode errorCode, String suggestedFix) {
        this(message, errorCode, AIFriendlyQueryException.Severity.MEDIUM, suggestedFix, null, null);
    }

    /**
     * @description Adds contextual information to the exception
     * @param key Context key
     * @param value Context value
     * @return This exception instance for method chaining
     */
    public AIFriendlyQueryException withContext(String key, Object value) {
        if (this.context == null) {
            this.context = new Map<String, Object>();
        }
        this.context.put(key, value);
        return this;
    }

    /**
     * @description Adds alternative solution suggestions
     * @param solution Alternative approach description
     * @return This exception instance for method chaining
     */
    public AIFriendlyQueryException withAlternative(String solution) {
        if (this.alternativeSolutions == null) {
            this.alternativeSolutions = new List<String>();
        }
        this.alternativeSolutions.add(solution);
        return this;
    }

    /**
     * @description Converts exception to structured JSON for AI consumption
     * @return JSON string containing all error information
     */
    public String toAIJson() {
        Map<String, Object> errorData = new Map<String, Object>{
            'errorType' => 'QueryValidationError',
            'message' => this.getMessage(),
            'errorCode' => this.errorCode?.name(),
            'severity' => this.severity?.name(),
            'suggestedFix' => this.suggestedFix,
            'fieldName' => this.fieldName,
            'objectName' => this.objectName,
            'context' => this.context,
            'alternativeSolutions' => this.alternativeSolutions,
            'timestamp' => DateTime.now().format('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
        };

        return JSON.serialize(errorData);
    }

    /**
     * @description Gets user-friendly error summary for logging
     * @return Formatted error summary
     */
    public String getErrorSummary() {
        String summary = '[' + (this.errorCode?.name() ?? 'UNKNOWN') + '] ' + this.getMessage();

        if (String.isNotBlank(this.fieldName)) {
            summary += ' (Field: ' + this.fieldName + ')';
        }

        if (String.isNotBlank(this.objectName)) {
            summary += ' (Object: ' + this.objectName + ')';
        }

        if (String.isNotBlank(this.suggestedFix)) {
            summary += ' | Fix: ' + this.suggestedFix;
        }

        return summary;
    }

    /**
     * @description Creates exception for invalid field errors
     */
    public static AIFriendlyQueryException invalidField(String fieldName, String objectName) {
        return new AIFriendlyQueryException(
                'Field "' + fieldName + '" does not exist on object ' + objectName,
                AIFriendlyQueryException.ErrorCode.INVALID_FIELD,
                AIFriendlyQueryException.Severity.MEDIUM,
                'Check field API name spelling and verify field exists on ' + objectName,
                fieldName,
                objectName
            )
            .withAlternative('Use Schema.getGlobalDescribe() to list available fields')
            .withAlternative('Check if field is in a different namespace');
    }

    /**
     * @description Creates exception for field access errors
     */
    public static AIFriendlyQueryException fieldNotAccessible(String fieldName, String objectName) {
        return new AIFriendlyQueryException(
                'Field "' + fieldName + '" is not accessible to current user',
                AIFriendlyQueryException.ErrorCode.FIELD_NOT_ACCESSIBLE,
                AIFriendlyQueryException.Severity.HIGH,
                'Grant field-level security read access for ' + fieldName + ' field',
                fieldName,
                objectName
            )
            .withAlternative('Remove field from query if not essential')
            .withAlternative('Use different field with appropriate access');
    }

    /**
     * @description Creates exception for non-filterable field errors
     */
    public static AIFriendlyQueryException fieldNotFilterable(String fieldName, String objectName) {
        return new AIFriendlyQueryException(
                'Field "' + fieldName + '" cannot be used in WHERE clause filters',
                AIFriendlyQueryException.ErrorCode.FIELD_NOT_FILTERABLE,
                AIFriendlyQueryException.Severity.MEDIUM,
                'Remove "' + fieldName + '" from filters or use it only in SELECT clause',
                fieldName,
                objectName
            )
            .withAlternative('Use a different field for filtering')
            .withAlternative('Consider using SOSL instead of SOQL for text fields');
    }

    /**
     * @description Creates exception for invalid operator errors
     */
    public static AIFriendlyQueryException invalidOperator(String operator, String fieldName) {
        return new AIFriendlyQueryException(
                'Operator "' + operator + '" is not supported for field "' + fieldName + '"',
                AIFriendlyQueryException.ErrorCode.INVALID_OPERATOR,
                AIFriendlyQueryException.Severity.MEDIUM,
                'Use supported operators: =, !=, >, <, >=, <=, LIKE, IN',
                fieldName,
                null
            )
            .withContext('invalidOperator', operator)
            .withAlternative('Use = operator for exact matches')
            .withAlternative('Use LIKE operator for text pattern matching');
    }

    /**
     * @description Creates exception for value type mismatch errors
     */
    public static AIFriendlyQueryException invalidValueType(String fieldName, String expectedType, Object actualValue) {
        return new AIFriendlyQueryException(
                'Invalid value type for field "' + fieldName + '". Expected ' + expectedType + ', got: ' + String.valueOf(actualValue),
                AIFriendlyQueryException.ErrorCode.INVALID_VALUE_TYPE,
                AIFriendlyQueryException.Severity.MEDIUM,
                'Convert value to ' + expectedType + ' format before filtering',
                fieldName,
                null
            )
            .withContext('expectedType', expectedType)
            .withContext('actualValue', actualValue)
            .withAlternative('Use proper date format (YYYY-MM-DD) for date fields')
            .withAlternative('Use numeric values for number fields');
    }

    /**
     * @description Creates exception for ORDER BY syntax errors
     */
    public static AIFriendlyQueryException invalidOrderBy(String orderByClause) {
        return new AIFriendlyQueryException(
                'Invalid ORDER BY syntax: "' + orderByClause + '"',
                AIFriendlyQueryException.ErrorCode.INVALID_ORDER_BY,
                AIFriendlyQueryException.Severity.MEDIUM,
                'Use format: "FieldName ASC|DESC" or "FieldName ASC|DESC NULLS FIRST|LAST"',
                null,
                null
            )
            .withContext('invalidOrderBy', orderByClause)
            .withAlternative('Example: "Name ASC"')
            .withAlternative('Example: "CreatedDate DESC NULLS LAST"');
    }

    /**
     * @description Creates exception for security violations
     */
    public static AIFriendlyQueryException securityViolation(String objectName, String operation) {
        return new AIFriendlyQueryException(
                'Access denied: Cannot ' + operation + ' ' + objectName + ' records',
                AIFriendlyQueryException.ErrorCode.SECURITY_VIOLATION,
                AIFriendlyQueryException.Severity.HIGH,
                'Grant ' + operation + ' permission for ' + objectName + ' object to current user',
                null,
                objectName
            )
            .withAlternative('Use a different object with appropriate permissions')
            .withAlternative('Contact system administrator for access');
    }
}
