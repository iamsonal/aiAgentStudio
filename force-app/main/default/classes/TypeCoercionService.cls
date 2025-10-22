/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * TypeCoercionService provides unified, high-performance type coercion capabilities for the AI Agent Framework.
 * This service consolidates type conversion logic and Field-Level Security (FLS) validation for SObject operations.
 *
 * Key Responsibilities:
 *   - Unified type coercion methods for Salesforce field types using Schema.DisplayType
 *   - Integrated Field-Level Security (FLS) enforcement for CREATABLE and UPDATABLE operations
 *   - Centralized picklist and multipicklist validation when DescribeFieldResult is provided
 *   - Comprehensive validation with structured error reporting (string length, range checking, format validation)
 *   - Support for all standard Salesforce types and common JSON/LLM input formats
 *
 * Architecture:
 *   - Primary method: coerceArgumentTypesForSObject() - Takes Map<String, Object> from DTOs and SObjectType
 *   - Performs FLS checks and type coercion against Salesforce schema
 *   - Individual coerce methods (coerceToString, coerceToInteger, etc.) for specific type conversions
 *   - No longer handles JSON schema parsing - actions use native JSON.deserialize() with DTOs instead
 *
 * Design Benefits:
 *   - Focused, single-responsibility utility for SObject field coercion
 *   - Leverages native Apex JSON deserialization for speed
 *   - Consistent error handling and validation patterns
 *   - Reduced complexity and improved maintainability
 */
public with sharing class TypeCoercionService {
    /**
     * Exception for type coercion failures with detailed context.
     */
    public class TypeCoercionException extends AIAgentException {
        public String fieldName { get; private set; }
        public String targetType { get; private set; }
        public String inputType { get; private set; }

        public TypeCoercionException(String message, String field, String target, String input) {
            super(message);
            this.fieldName = field;
            this.targetType = target;
            this.inputType = input;
        }

        public TypeCoercionException(String message, String field, String target, String input, Exception cause) {
            super(message);
            this.fieldName = field;
            this.targetType = target;
            this.inputType = input;
            this.initCause(cause);
        }
    }

    // ============================================================================
    // --- Schema-Aware Coercion (Primary Interface) ---
    // ============================================================================

    /**
     * Coerces and validates raw arguments to Salesforce-compatible field values with comprehensive validation.
     * This is the authoritative method for SObject field processing, combining FLS enforcement, type coercion,
     * and constraint validation in a single, secure operation.
     *
     * @param rawArguments Map of field names to raw values from JSON/LLM input
     * @param targetSObjectType SObjectType for field metadata and validation context
     * @param accessType CREATABLE or UPDATABLE for appropriate FLS validation
     * @return Map of validated field names to properly typed values
     * @throws TypeCoercionException For type conversion failures, constraint violations, or security violations
     */
    public static Map<String, Object> coerceArgumentTypesForSObject(
        Map<String, Object> rawArguments,
        SObjectType targetSObjectType,
        AccessType accessType
    ) {
        if (rawArguments == null || rawArguments.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[TypeCoercionService] No arguments provided for coercion. Returning empty map.');
            return new Map<String, Object>();
        }

        if (targetSObjectType == null) {
            throw new TypeCoercionException('Target SObjectType cannot be null', '', 'SObjectType', 'null');
        }
        if (accessType != System.AccessType.CREATABLE && accessType != System.AccessType.UPDATABLE) {
            throw new TypeCoercionException('AccessType must be CREATABLE or UPDATABLE', '', 'AccessType', String.valueOf(accessType));
        }

        Map<String, Object> coercedArguments = new Map<String, Object>();
        Map<String, Schema.SObjectField> allFields = SchemaUtils.getObjectFields(targetSObjectType);

        for (String fieldName : rawArguments.keySet()) {
            Schema.SObjectField fieldToken = allFields.get(fieldName.toLowerCase());
            if (fieldToken == null) {
                System.debug(
                    LoggingLevel.WARN,
                    '[TypeCoercionService] Field "' +
                        fieldName +
                        '" not found on ' +
                        targetSObjectType.getDescribe().getName() +
                        '. Skipping coercion.'
                );
                continue;
            }

            Schema.DescribeFieldResult dfr = fieldToken.getDescribe();
            // Enforce field-level security before processing
            if (!SecurityUtils.hasFieldPermission(dfr, accessType)) {
                System.debug(LoggingLevel.DEBUG, '[TypeCoercionService] Field "' + fieldName + '" skipped due to FLS (' + accessType + ').');
                continue;
            }

            // Perform type coercion with comprehensive validation
            Object rawValue = rawArguments.get(fieldName);
            if (rawValue != null) {
                Schema.DisplayType fieldType = dfr.getType();
                System.debug(
                    LoggingLevel.FINEST,
                    '[TypeCoercionService] Coercing Field: ' +
                        fieldName +
                        ', Type: ' +
                        fieldType +
                        ', Input Value: ' +
                        String.valueOf(rawValue).abbreviate(50)
                );

                Object coercedValue = coerce(rawValue, fieldType, fieldName, dfr);
                coercedArguments.put(dfr.getName(), coercedValue);
            } else {
                coercedArguments.put(dfr.getName(), null);
            }
        }

        return coercedArguments;
    }

    /**
     * Coerces a value to the target Salesforce field type using Schema.DisplayType.
     * This is the primary interface for SObject field assignment with full validation.
     *
     * @param value      The raw input value to coerce
     * @param targetType The target Schema.DisplayType
     * @param fieldName  The field name for error context
     * @param fieldDescribe Optional field describe result for additional validation (picklist, length, etc.)
     * @return           The coerced value ready for SObject assignment
     * @throws TypeCoercionException for conversion failures or validation errors
     */
    public static Object coerce(Object value, Schema.DisplayType targetType, String fieldName, Schema.DescribeFieldResult fieldDescribe) {
        if (value == null) {
            return null;
        }

        try {
            switch on targetType {
                when STRING, TEXTAREA, ENCRYPTEDSTRING {
                    return coerceToString(value, fieldName, fieldDescribe);
                }
                when PICKLIST {
                    String stringValue = coerceToString(value, fieldName, fieldDescribe);
                    // Automatic picklist validation when fieldDescribe is provided
                    if (fieldDescribe != null) {
                        validatePicklistValue(stringValue, fieldName, fieldDescribe);
                    }
                    return stringValue;
                }
                when MULTIPICKLIST {
                    String stringValue = coerceToString(value, fieldName, fieldDescribe);
                    // Automatic multipicklist validation when fieldDescribe is provided
                    if (fieldDescribe != null) {
                        validateMultiPicklistValues(stringValue, fieldName, fieldDescribe);
                    }
                    return stringValue;
                }
                when EMAIL, PHONE, URL {
                    return coerceToString(value, fieldName, fieldDescribe);
                }
                when INTEGER {
                    return coerceToInteger(value, fieldName);
                }
                when DOUBLE, CURRENCY, PERCENT {
                    return coerceToDecimal(value, fieldName);
                }
                when BOOLEAN {
                    return coerceToBoolean(value, fieldName);
                }
                when DATE {
                    return coerceToDate(value, fieldName);
                }
                when DATETIME {
                    return coerceToDateTime(value, fieldName);
                }
                when TIME {
                    return coerceToTime(value, fieldName);
                }
                when ID, REFERENCE {
                    return coerceToId(value, fieldName);
                }
                when BASE64 {
                    return coerceToBlob(value, fieldName);
                }
                when else {
                    System.debug(LoggingLevel.WARN, '[TypeCoercionService] Unsupported DisplayType: ' + targetType + ' for field: ' + fieldName);
                    return value; // Pass-through for unsupported types
                }
            }
        } catch (TypeCoercionException e) {
            throw e; // Re-throw our exceptions
        } catch (Exception e) {
            throw new TypeCoercionException(
                'Unexpected error coercing value to ' + targetType + ': ' + e.getMessage(),
                fieldName,
                String.valueOf(targetType),
                getInputTypeString(value),
                e
            );
        }
    }

    /**
     * Simplified coercion method without field describe result.
     * Useful for basic type coercion without advanced validation.
     */
    public static Object coerce(Object value, Schema.DisplayType targetType, String fieldName) {
        return coerce(value, targetType, fieldName, null);
    }

    // ============================================================================
    // --- Type-Specific Coercion Methods ---
    // ============================================================================

    /**
     * Coerces a value to String with optional length validation.
     */
    public static String coerceToString(Object value, String fieldName, Schema.DescribeFieldResult fieldDescribe) {
        if (value == null) {
            return null;
        }

        String stringValue = String.valueOf(value);

        // Validate length if field describe is provided
        if (fieldDescribe != null) {
            Integer maxLength = fieldDescribe.getLength();
            Schema.DisplayType fieldType = fieldDescribe.getType();

            // Skip length check for TextArea fields (they don't have reliable length limits from describe)
            if (fieldType != Schema.DisplayType.TEXTAREA && maxLength > 0 && stringValue.length() > maxLength) {
                throw new TypeCoercionException(
                    'Value length (' + stringValue.length() + ') exceeds maximum (' + maxLength + ') for field',
                    fieldName,
                    'String',
                    getInputTypeString(value)
                );
            }
        }

        return stringValue;
    }

    /**
     * Coerces a value to Integer with range validation.
     */
    public static Integer coerceToInteger(Object value, String fieldName) {
        final Long INT_MAX_AS_LONG = 2147483647L; // Integer.MAX_VALUE equivalent
        final Long INT_MIN_AS_LONG = -2147483648L; // Integer.MIN_VALUE equivalent

        if (value == null) {
            return null;
        }

        if (value instanceof Integer) {
            return (Integer) value;
        }

        if (value instanceof Long) {
            Long longVal = (Long) value;
            if (longVal > INT_MAX_AS_LONG || longVal < INT_MIN_AS_LONG) {
                throw new TypeCoercionException('Long value out of Integer range: ' + longVal, fieldName, 'Integer', getInputTypeString(value));
            }
            return longVal.intValue();
        }

        if (value instanceof Decimal || value instanceof Double) {
            Decimal decimalVal = Decimal.valueOf(String.valueOf(value));
            if (decimalVal.scale() > 0) {
                throw new TypeCoercionException(
                    'Decimal value has fractional part, cannot convert to Integer: ' + decimalVal,
                    fieldName,
                    'Integer',
                    getInputTypeString(value)
                );
            }
            if (decimalVal > INT_MAX_AS_LONG || decimalVal < INT_MIN_AS_LONG) {
                throw new TypeCoercionException('Decimal value out of Integer range: ' + decimalVal, fieldName, 'Integer', getInputTypeString(value));
            }
            return decimalVal.intValue();
        }

        if (value instanceof String && String.isNotBlank((String) value)) {
            try {
                return Integer.valueOf((String) value);
            } catch (System.MathException e) {
                throw new TypeCoercionException('Value out of Integer range: ' + value, fieldName, 'Integer', getInputTypeString(value), e);
            } catch (Exception e) {
                throw new TypeCoercionException('Invalid Integer format: ' + value, fieldName, 'Integer', getInputTypeString(value), e);
            }
        }

        throw new TypeCoercionException('Cannot coerce to Integer', fieldName, 'Integer', getInputTypeString(value));
    }

    /**
     * Coerces a value to Decimal.
     */
    public static Decimal coerceToDecimal(Object value, String fieldName) {
        if (value == null) {
            return null;
        }

        if (value instanceof Decimal) {
            return (Decimal) value;
        }

        if (value instanceof Integer || value instanceof Long || value instanceof Double) {
            return Decimal.valueOf(String.valueOf(value));
        }

        if (value instanceof String && String.isNotBlank((String) value)) {
            try {
                return Decimal.valueOf((String) value);
            } catch (Exception e) {
                throw new TypeCoercionException('Invalid Decimal format: ' + value, fieldName, 'Decimal', getInputTypeString(value), e);
            }
        }

        throw new TypeCoercionException('Cannot coerce to Decimal', fieldName, 'Decimal', getInputTypeString(value));
    }

    /**
     * Coerces a value to Boolean with flexible input handling.
     */
    public static Boolean coerceToBoolean(Object value, String fieldName) {
        if (value == null) {
            return null;
        }

        if (value instanceof Boolean) {
            return (Boolean) value;
        }

        if (value instanceof String) {
            String stringVal = ((String) value).trim().toLowerCase();
            if (stringVal == 'true' || stringVal == '1' || stringVal == 'yes' || stringVal == 'on') {
                return true;
            }
            if (stringVal == 'false' || stringVal == '0' || stringVal == 'no' || stringVal == 'off') {
                return false;
            }
        }

        if (value instanceof Integer || value instanceof Decimal || value instanceof Long || value instanceof Double) {
            return Decimal.valueOf(String.valueOf(value)) != 0;
        }

        throw new TypeCoercionException(
            'Cannot coerce to Boolean. Expected true/false, 1/0, yes/no, or numeric value',
            fieldName,
            'Boolean',
            getInputTypeString(value)
        );
    }

    /**
     * Coerces a value to Salesforce Id with validation.
     */
    public static Id coerceToId(Object value, String fieldName) {
        if (value == null) {
            return null;
        }

        if (value instanceof Id) {
            return (Id) value;
        }

        if (value instanceof String && String.isNotBlank((String) value)) {
            try {
                return Id.valueOf((String) value);
            } catch (Exception e) {
                throw new TypeCoercionException('Invalid Salesforce ID format: ' + value, fieldName, 'Id', getInputTypeString(value), e);
            }
        }

        throw new TypeCoercionException('Cannot coerce to Id', fieldName, 'Id', getInputTypeString(value));
    }

    /**
     * Coerces a value to Date with multiple format support.
     */
    public static Date coerceToDate(Object value, String fieldName) {
        if (value == null) {
            return null;
        }

        if (value instanceof Date) {
            return (Date) value;
        }

        if (value instanceof DateTime) {
            return ((DateTime) value).date();
        }

        if (value instanceof String && String.isNotBlank((String) value)) {
            String dateStr = ((String) value).trim();

            try {
                return Date.valueOf(dateStr);
            } catch (Exception e) {
                throw new TypeCoercionException(
                    'Invalid Date format. Expected YYYY-MM-DD: ' + value,
                    fieldName,
                    'Date',
                    getInputTypeString(value),
                    e
                );
            }
        }

        throw new TypeCoercionException('Cannot coerce to Date', fieldName, 'Date', getInputTypeString(value));
    }

    /**
     * Coerces a value to DateTime with multiple format support.
     */
    public static DateTime coerceToDateTime(Object value, String fieldName) {
        if (value == null) {
            return null;
        }

        if (value instanceof DateTime) {
            return (DateTime) value;
        }

        if (value instanceof Date) {
            return DateTime.newInstance((Date) value, Time.newInstance(0, 0, 0, 0));
        }

        if (value instanceof String && String.isNotBlank((String) value)) {
            String dateTimeStr = ((String) value).trim();

            try {
                // Try ISO datetime format with JSON deserialization
                if (dateTimeStr.contains('T')) {
                    return (DateTime) JSON.deserialize('"' + dateTimeStr + '"', DateTime.class);
                }

                // Try Salesforce format
                return DateTime.valueOf(dateTimeStr);
            } catch (Exception e) {
                throw new TypeCoercionException(
                    'Invalid DateTime format. Expected ISO 8601 (YYYY-MM-DDTHH:mm:ssZ) or Salesforce format (YYYY-MM-DD HH:mm:ss): ' + value,
                    fieldName,
                    'DateTime',
                    getInputTypeString(value),
                    e
                );
            }
        }

        throw new TypeCoercionException('Cannot coerce to DateTime', fieldName, 'DateTime', getInputTypeString(value));
    }

    /**
     * Coerces a value to Time.
     */
    public static Time coerceToTime(Object value, String fieldName) {
        if (value == null) {
            return null;
        }

        if (value instanceof Time) {
            return (Time) value;
        }

        if (value instanceof String && String.isNotBlank((String) value)) {
            try {
                List<String> timeParts = ((String) value).split(':');
                if (timeParts.size() >= 2) {
                    Integer hour = Integer.valueOf(timeParts[0]);
                    Integer minute = Integer.valueOf(timeParts[1]);
                    Integer second = timeParts.size() > 2 ? Integer.valueOf(timeParts[2]) : 0;
                    return Time.newInstance(hour, minute, second, 0);
                }
            } catch (Exception e) {
                throw new TypeCoercionException('Invalid Time format. Expected HH:mm:ss: ' + value, fieldName, 'Time', getInputTypeString(value), e);
            }
        }

        throw new TypeCoercionException('Cannot coerce to Time', fieldName, 'Time', getInputTypeString(value));
    }

    /**
     * Coerces a value to Blob (Base64 decoding).
     */
    public static Blob coerceToBlob(Object value, String fieldName) {
        if (value == null) {
            return null;
        }

        if (value instanceof Blob) {
            return (Blob) value;
        }

        if (value instanceof String) {
            try {
                return EncodingUtil.base64Decode((String) value);
            } catch (Exception e) {
                throw new TypeCoercionException(
                    'Invalid Base64 format: ' + String.valueOf(value).abbreviate(50),
                    fieldName,
                    'Blob',
                    getInputTypeString(value),
                    e
                );
            }
        }

        throw new TypeCoercionException('Cannot coerce to Blob', fieldName, 'Blob', getInputTypeString(value));
    }

    // ============================================================================
    // --- Validation Helpers ---
    // ============================================================================

    /**
     * Validates a picklist value against allowed values for the field.
     * Centralized picklist validation used by all coercion operations.
     *
     * @param value Value to validate
     * @param fieldName Field API name for error context
     * @param fieldDescribe Field describe result for picklist values
     * @throws TypeCoercionException if value is not valid for the picklist
     */
    private static void validatePicklistValue(String value, String fieldName, Schema.DescribeFieldResult fieldDescribe) {
        List<Schema.PicklistEntry> entries = fieldDescribe.getPicklistValues();
        if (entries == null || entries.isEmpty()) {
            return;
        }

        for (Schema.PicklistEntry entry : entries) {
            // Case-sensitive match is standard for SF picklists
            if (entry.isActive() && entry.getValue().equals(value)) {
                return; // Valid value found
            }
        }

        throw new TypeCoercionException('Invalid picklist value: ' + value, fieldName, 'Picklist', 'String');
    }

    /**
     * Validates multipicklist values against allowed values for the field.
     * Centralized multipicklist validation used by all coercion operations.
     *
     * @param value Multipicklist value string (semicolon-separated)
     * @param fieldName Field API name for error context
     * @param fieldDescribe Field describe result for picklist values
     * @throws TypeCoercionException if any value is not valid for the multipicklist
     */
    private static void validateMultiPicklistValues(String value, String fieldName, Schema.DescribeFieldResult fieldDescribe) {
        List<Schema.PicklistEntry> entries = fieldDescribe.getPicklistValues();
        if (entries == null || entries.isEmpty()) {
            return;
        }

        Set<String> validValues = new Set<String>();
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive()) {
                validValues.add(entry.getValue());
            }
        }

        for (String item : value.split(';')) {
            String trimmedItem = item.trim();
            if (String.isNotBlank(trimmedItem) && !validValues.contains(trimmedItem)) {
                throw new TypeCoercionException('Invalid multipicklist value: ' + trimmedItem, fieldName, 'Multipicklist', 'String');
            }
        }
    }

    // ============================================================================
    // --- Format Validation Methods ---
    // ============================================================================

    /**
     * Coerces and validates an email format string.
     * Centralized email validation used by all coercion operations.
     *
     * @param value     The raw parameter value.
     * @param fieldName The field name for error reporting.
     * @return          The validated email string.
     * @throws TypeCoercionException for invalid email format.
     */
    public static String coerceToEmailString(Object value, String fieldName) {
        if (value == null) {
            return null;
        }

        String emailStr = coerceToString(value, fieldName, null);

        if (String.isNotBlank(emailStr) && emailStr.contains('@')) {
            List<String> parts = emailStr.split('@');
            if (parts.size() == 2 && String.isNotBlank(parts[0]) && String.isNotBlank(parts[1]) && parts[1].contains('.')) {
                return emailStr;
            }
        }

        throw new TypeCoercionException(
            'Invalid email format. Expected format: user@domain.com',
            fieldName,
            'Email String',
            getInputTypeString(value)
        );
    }

    /**
     * Coerces and validates a URL format string.
     * Centralized URL validation used by all coercion operations.
     *
     * @param value     The raw parameter value.
     * @param fieldName The field name for error reporting.
     * @return          The validated URL string.
     * @throws TypeCoercionException for invalid URL format.
     */
    public static String coerceToUrlString(Object value, String fieldName) {
        if (value == null) {
            return null;
        }

        String urlStr = coerceToString(value, fieldName, null);

        if (String.isNotBlank(urlStr) && (urlStr.toLowerCase().startsWith('http://') || urlStr.toLowerCase().startsWith('https://'))) {
            return urlStr;
        }

        throw new TypeCoercionException(
            'Invalid URL format. Expected format: http://... or https://...',
            fieldName,
            'URL String',
            getInputTypeString(value)
        );
    }

    // ============================================================================
    // --- Utility Methods ---
    // ============================================================================

    /**
     * Gets a human-readable string representation of the input type.
     */
    private static String getInputTypeString(Object value) {
        if (value == null)
            return 'null';
        if (value instanceof String)
            return 'String';
        if (value instanceof Integer)
            return 'Integer';
        if (value instanceof Long)
            return 'Long';
        if (value instanceof Double)
            return 'Double';
        if (value instanceof Decimal)
            return 'Decimal';
        if (value instanceof Boolean)
            return 'Boolean';
        if (value instanceof Date)
            return 'Date';
        if (value instanceof DateTime)
            return 'DateTime';
        if (value instanceof Time)
            return 'Time';
        if (value instanceof Id)
            return 'Id';
        if (value instanceof List<Object>)
            return 'List';
        if (value instanceof Map<String, Object>)
            return 'Map';
        if (value instanceof Blob)
            return 'Blob';
        if (value instanceof SObject) {
            try {
                return ((SObject) value).getSObjectType().getDescribe().getName();
            } catch (Exception e) {
                return 'SObject';
            }
        }
        return 'Object (Unknown Type)';
    }
}
