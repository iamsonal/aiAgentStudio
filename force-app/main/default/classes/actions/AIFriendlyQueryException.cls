/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AIFriendlyQueryException: Structured, AI-optimized exception for SOQL query validation and troubleshooting.
 *
 * This custom exception class provides machine-readable, context-rich error information for SOQL query operations.
 * It enables AI agents and developer tools to understand, classify, and suggest corrections for query failures.
 *
 * Key Features:
 *   - Standardized error codes and severity levels for programmatic handling.
 *   - Contextual metadata and actionable fix suggestions for common query validation scenarios.
 *   - Fluent API for adding context and alternative solutions.
 *   - Serialization to a structured JSON format for LLMs and automation.
 *
 * Use this exception to surface query errors in a way that is both human- and machine-actionable, supporting advanced AI-driven troubleshooting and self-healing workflows.
 */
public class AIFriendlyQueryException extends Exception {
    /**
     * @description
     * Enumeration of standardized error codes for categorizing SOQL query failures.
     * Enables AI agents and tools to programmatically identify and respond to specific error scenarios.
     */
    public enum ErrorCode {
        INVALID_FIELD, // Field doesn't exist on object
        FIELD_NOT_ACCESSIBLE, // FLS violation
        FIELD_NOT_FILTERABLE, // Field cannot be used in WHERE clause
        INVALID_OPERATOR, // Unsupported filter operator
        INVALID_VALUE_TYPE, // Value type doesn't match field type
        INVALID_ORDER_BY, // ORDER BY syntax error
        QUERY_TOO_COMPLEX, // Query exceeds complexity limits
        SECURITY_VIOLATION, // Object access denied
        SOQL_INJECTION_RISK, // Potential injection detected
        QUERY_TIMEOUT, // Query execution timeout
        INVALID_LIMIT, // Invalid LIMIT value
        EMPTY_IN_LIST, // Empty list for IN operator
        GENERAL_VALIDATION // Generic validation error
    }

    /**
     * @description
     * Enumeration of severity levels for classifying the impact and urgency of query errors.
     * Guides AI agents and developer tools in prioritizing error handling and response strategies.
     */
    public enum Severity {
        LOW, // Warning - query can proceed with modifications
        MEDIUM, // Error - query needs correction
        HIGH, // Critical - security or system risk
        CRITICAL // Blocking - fundamental configuration issue
    }

    // Core exception properties: structured error information for AI and developer tools
    public ErrorCode errorCode { get; private set; }
    public Severity severity { get; private set; }
    public String suggestedFix { get; private set; }
    public String fieldName { get; private set; }
    public String objectName { get; private set; }
    public Map<String, Object> context { get; private set; }
    public List<String> alternativeSolutions { get; private set; }

    /**
     * @description
     * Primary constructor for a fully-contextualized exception with all available error details.
     * Use this when maximum error context is available for AI or developer processing.
     *
     * @param message Human-readable error description
     * @param errorCode Standardized error classification code
     * @param severity Impact level of the error
     * @param suggestedFix Actionable recommendation for resolving the error
     * @param fieldName Name of the field involved in the error (null if not field-specific)
     * @param objectName Name of the SObject involved in the error (null if not object-specific)
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
     * @description
     * Convenience constructor for basic error scenarios where field and object context is not available.
     * Sets severity to MEDIUM and initializes empty context collections.
     *
     * @param message Human-readable error description
     * @param errorCode Standardized error classification code
     * @param suggestedFix Actionable recommendation for resolving the error
     */
    public AIFriendlyQueryException(String message, ErrorCode errorCode, String suggestedFix) {
        this(message, errorCode, AIFriendlyQueryException.Severity.MEDIUM, suggestedFix, null, null);
    }

    /**
     * @description
     * Adds additional contextual metadata to the exception for enhanced AI or developer processing.
     * Supports method chaining for fluent exception building.
     *
     * @param key Descriptive identifier for the context information
     * @param value Associated data value (any serializable type)
     * @return This exception instance (for method chaining)
     */
    public AIFriendlyQueryException withContext(String key, Object value) {
        if (this.context == null) {
            this.context = new Map<String, Object>();
        }
        this.context.put(key, value);
        return this;
    }

    /**
     * @description
     * Appends an alternative solution to the list of possible fixes for this error.
     * Multiple alternatives can be added to provide AI agents or users with various resolution options.
     *
     * @param solution Description of an alternative approach to resolve the error
     * @return This exception instance (for method chaining)
     */
    public AIFriendlyQueryException withAlternative(String solution) {
        if (this.alternativeSolutions == null) {
            this.alternativeSolutions = new List<String>();
        }
        this.alternativeSolutions.add(solution);
        return this;
    }

    /**
     * @description
     * Serializes the complete exception state into a structured JSON format optimized for AI and automation.
     * The resulting JSON includes all error details, context, and suggestions in a standardized schema.
     *
     * @return JSON string representation of the exception with all available error information
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
     * @description
     * Generates a concise, human-readable error summary suitable for logging and debugging.
     * Combines error code, message, context, and primary fix suggestion into a single line.
     *
     * @return Formatted string containing the essential error information
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

    // Static factory methods: create pre-configured exceptions for common query error scenarios

    /**
     * @description
     * Factory method for creating exceptions when a referenced field does not exist on the target object.
     * Includes common alternative solutions for field name resolution.
     *
     * @param fieldName The invalid field name that was referenced
     * @param objectName The SObject type where the field was expected
     * @return Configured exception with field validation error details
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
     * @description
     * Factory method for creating exceptions when field-level security prevents access to a field.
     * Provides guidance on permission configuration and alternative approaches.
     *
     * @param fieldName The field that cannot be accessed
     * @param objectName The SObject containing the restricted field
     * @return Configured exception with field access security error details
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
     * @description
     * Factory method for creating exceptions when attempting to filter on fields that don't support WHERE clause operations.
     * Suggests alternative query strategies and field usage patterns.
     *
     * @param fieldName The field that cannot be used in filters
     * @param objectName The SObject containing the non-filterable field
     * @return Configured exception with field filtering restriction details
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
     * @description
     * Factory method for creating exceptions when an unsupported operator is used with a specific field type.
     * Provides a list of valid operators and usage examples.
     *
     * @param operator The invalid operator that was attempted
     * @param fieldName The field where the operator was applied
     * @return Configured exception with operator validation error details
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
     * @description
     * Factory method for creating exceptions when a filter value doesn't match the expected field data type.
     * Includes type conversion guidance and format examples.
     *
     * @param fieldName The field where type mismatch occurred
     * @param expectedType The data type expected by the field
     * @param actualValue The value that caused the type mismatch
     * @return Configured exception with type validation error details
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
     * @description
     * Factory method for creating exceptions when ORDER BY clause contains invalid syntax.
     * Provides correct syntax patterns and formatting examples.
     *
     * @param orderByClause The malformed ORDER BY clause that caused the error
     * @return Configured exception with ORDER BY syntax error details
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
     * @description
     * Factory method for creating exceptions when object-level security prevents the requested operation.
     * Provides guidance on permission configuration and alternative approaches.
     *
     * @param objectName The SObject that cannot be accessed
     * @param operation The operation that was denied (e.g., 'read', 'create', 'update')
     * @return Configured exception with object security violation details
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
