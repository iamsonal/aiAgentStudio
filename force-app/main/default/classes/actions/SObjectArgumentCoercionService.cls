/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SObjectArgumentCoercionService: Enterprise argument coercion and validation service for secure SObject field value conversion.
 *
 * This class provides comprehensive type coercion from JSON/LLM arguments to Salesforce field types with FLS enforcement,
 * validation, and structured error handling. It supports all standard Salesforce field types, including complex types like picklists,
 * dates, and references, and is optimized for robust, secure, and developer-friendly SObject operations.
 *
 * Key Responsibilities:
 *   - Converts raw arguments to Salesforce-compatible field values with type coercion and validation.
 *   - Enforces field-level security (FLS) for create and update operations.
 *   - Handles all standard and complex Salesforce field types with detailed error reporting.
 *   - Provides structured exceptions for type conversion and security violations.
 */
public with sharing class SObjectArgumentCoercionService {
    /**
     * @description
     * Converts raw arguments to Salesforce-compatible field values with comprehensive validation.
     * Performs FLS checks, type coercion, and constraint validation for secure SObject operations.
     *
     * @param rawArguments Map of field names to raw values from JSON/LLM input
     * @param targetSObjectType SObjectType for field metadata and validation context
     * @param accessType CREATABLE or UPDATABLE for appropriate FLS validation
     * @return Map of validated field names to properly typed values
     * @throws InvalidArgumentTypeException For type conversion failures or constraint violations
     * @throws ActionSecurityException For security or permission violations
     */
    public static Map<String, Object> coerceArgumentTypesForSObject(
        Map<String, Object> rawArguments,
        SObjectType targetSObjectType,
        AccessType accessType
    ) {
        if (rawArguments == null || rawArguments.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[SObjectArgumentCoercionService] No arguments provided for coercion. Returning empty map.');
            return new Map<String, Object>();
        }

        if (targetSObjectType == null) {
            throw new SecurityUtils.ActionSecurityException('Target SObjectType cannot be null.');
        }
        if (accessType != System.AccessType.CREATABLE && accessType != System.AccessType.UPDATABLE) {
            throw new InvalidArgumentTypeException('AccessType must be CREATABLE or UPDATABLE.');
        }

        Map<String, Object> coercedArguments = new Map<String, Object>();
        Map<String, Schema.SObjectField> allFields = SchemaUtils.getObjectFields(targetSObjectType);

        for (String fieldName : rawArguments.keySet()) {
            Schema.SObjectField fieldToken = allFields.get(fieldName.toLowerCase());
            if (fieldToken == null) {
                System.debug(
                    LoggingLevel.WARN,
                    '[SObjectArgumentCoercionService] Field "' +
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
                System.debug(
                    LoggingLevel.DEBUG,
                    '[SObjectArgumentCoercionService] Field "' + fieldName + '" skipped due to FLS (' + accessType + ').'
                );
                continue;
            }

            // Perform type coercion with comprehensive validation
            Object rawValue = rawArguments.get(fieldName);
            try {
                Object coercedValue = coerceValueForField(rawValue, fieldName, dfr);
                coercedArguments.put(dfr.getName(), coercedValue);
            } catch (InvalidArgumentTypeException e) {
                String errMsg = 'Failed coercing value for permitted field "' + fieldName + '". Error: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, '[SObjectArgumentCoercionService] ' + errMsg);
                throw new InvalidArgumentTypeException(errMsg, e);
            }
        }

        return coercedArguments;
    }

    // --- Helper for getting input type as string for error messages ---
    private static String getInputTypeString(Object val) {
        if (val == null)
            return 'null';
        // Check common types explicitly for better names
        if (val instanceof String)
            return 'String';
        if (val instanceof Integer)
            return 'Integer';
        if (val instanceof Long)
            return 'Long'; // Added check for Long
        if (val instanceof Double)
            return 'Double';
        if (val instanceof Decimal)
            return 'Decimal';
        if (val instanceof Boolean)
            return 'Boolean';
        if (val instanceof Date)
            return 'Date';
        if (val instanceof Datetime)
            return 'Datetime';
        if (val instanceof Time)
            return 'Time';
        if (val instanceof Id)
            return 'Id';
        if (val instanceof List<Object>)
            return 'List';
        if (val instanceof Map<String, Object>)
            return 'Map';
        if (val instanceof Blob)
            return 'Blob';
        // ** CORRECTED SObject Check **
        if (val instanceof SObject) {
            try {
                // Cast to SObject *inside* the block where we know the type
                return ((SObject) val).getSObjectType().getDescribe().getName();
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[SObjectArgumentCoercionService] Error getting SObject type name: ' + e.getMessage());
                return 'SObject'; // Fallback if describe fails
            }
        }

        // Fallback using generic Object methods is unreliable in Apex for precise type names.
        // Return a generic placeholder for other types.
        return 'Object (Unknown Type)';
    }

    /**
     * @description
     * Performs field-specific type coercion with validation and constraint checking.
     * Handles all standard Salesforce field types with appropriate error handling.
     *
     * @param rawValue Input value to convert (from JSON/LLM)
     * @param fieldName Field API name for error context
     * @param dfr Field describe result containing type and constraint information
     * @return Object Properly typed value ready for SObject assignment
     * @throws InvalidArgumentTypeException For conversion failures or constraint violations
     */
    private static Object coerceValueForField(Object rawValue, String fieldName, Schema.DescribeFieldResult dfr) {
        if (rawValue == null)
            return null;
        Schema.DisplayType fieldType = dfr.getType();
        System.debug(
            LoggingLevel.FINEST,
            'SObjectArgumentCoercionService: Coercing Field: ' +
                fieldName +
                ', Type: ' +
                fieldType +
                ', Input Value: ' +
                String.valueOf(rawValue).abbreviate(50)
        );

        try {
            switch on fieldType {
                when DATE {
                    return coerceToDate(rawValue, fieldName);
                }
                when DATETIME {
                    return coerceToDateTime(rawValue, fieldName);
                }
                when BOOLEAN {
                    return coerceToBoolean(rawValue, fieldName);
                }
                when INTEGER {
                    return coerceToInteger(rawValue, fieldName);
                }
                when DOUBLE, CURRENCY, PERCENT {
                    return coerceToDecimal(rawValue, fieldName);
                }
                when ID, REFERENCE {
                    return coerceToId(rawValue, fieldName);
                }
                when STRING, TEXTAREA, PICKLIST, MULTIPICKLIST, EMAIL, PHONE, URL, ENCRYPTEDSTRING {
                    return coerceToString(rawValue, fieldName, dfr);
                }
                when TIME {
                    return coerceToTime(rawValue, fieldName);
                }
                when BASE64 {
                    return coerceToBlob(rawValue, fieldName);
                }
                when else {
                    System.debug(
                        LoggingLevel.WARN,
                        '[SObjectArgumentCoercionService] Coercion for field type ' +
                            fieldType +
                            ' (' +
                            fieldName +
                            ') not explicitly handled. Using pass-through.'
                    );
                    return rawValue;
                }
            }
        } catch (InvalidArgumentTypeException e) {
            throw e;
        } catch (Exception e) {
            throw new InvalidArgumentTypeException(
                'Error coercing value for field "' + fieldName + '" to type ' + fieldType + ': ' + e.getMessage(),
                e
            );
        }
    }

    /**
     * @description
     * Coerces a value to a Time type (hh:mm:ss format or Time object).
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @return Time value
     * @throws InvalidArgumentTypeException for invalid input
     */
    private static Time coerceToTime(Object rawValue, String fieldName) {
        if (rawValue instanceof Time) {
            return (Time) rawValue;
        } else if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
                // Parse string as time in hh:mm:ss format
                List<String> timeParts = ((String) rawValue).split(':');
                if (timeParts.size() >= 2) {
                    Integer hour = Integer.valueOf(timeParts[0]);
                    Integer minute = Integer.valueOf(timeParts[1]);
                    Integer second = timeParts.size() > 2 ? Integer.valueOf(timeParts[2]) : 0;
                    return Time.newInstance(hour, minute, second, 0);
                }
            } catch (Exception e) {
                throw new InvalidArgumentTypeException('Invalid time format for field ' + fieldName + '. Expected hh:mm:ss format, got: ' + rawValue);
            }
        }

        throw new InvalidArgumentTypeException('Expected String (hh:mm:ss) or Time for Time field ' + fieldName + ', got ' + rawValue);
    }

    /**
     * @description
     * Coerces a value to a Blob type (Base64 string or Blob object).
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @return Blob value
     * @throws InvalidArgumentTypeException for invalid input
     */
    private static Blob coerceToBlob(Object rawValue, String fieldName) {
        if (rawValue instanceof Blob)
            return (Blob) rawValue;
        if (rawValue instanceof String) {
            try {
                return EncodingUtil.base64Decode((String) rawValue);
            } catch (Exception e) {
                throw new InvalidArgumentTypeException(
                    'Invalid Base64 format for Blob field "' + fieldName + '". Got: "' + String.valueOf(rawValue).abbreviate(50) + '"',
                    e
                );
            }
        }
        throw new InvalidArgumentTypeException(
            'Cannot coerce to Blob for field "' + fieldName + '". Expected String or Blob, got ' + getInputTypeString(rawValue)
        );
    }

    /**
     * @description
     * Coerces a value to a Date type (YYYY-MM-DD string or Date object).
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @return Date value
     * @throws InvalidArgumentTypeException for invalid input
     */
    private static Date coerceToDate(Object rawValue, String fieldName) {
        if (rawValue instanceof Date)
            return (Date) rawValue;
        if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
                return Date.valueOf((String) rawValue);
            } catch (Exception e) {
                throw new InvalidArgumentTypeException(
                    'Invalid date format for field "' + fieldName + '". Expected YYYY-MM-DD. Got: "' + rawValue + '"'
                );
            }
        }
        // *** FIXED ERROR MESSAGE ***
        throw new InvalidArgumentTypeException(
            'Cannot coerce to Date for field "' + fieldName + '". Expected String or Date, got ' + getInputTypeString(rawValue)
        );
    }

    /**
     * @description
     * Coerces a value to a Datetime type (ISO 8601 string, Datetime object).
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @return Datetime value
     * @throws InvalidArgumentTypeException for invalid input
     */
    private static Datetime coerceToDateTime(Object rawValue, String fieldName) {
        if (rawValue instanceof Datetime)
            return (Datetime) rawValue;
        if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
                return Datetime.valueOfGmt(((String) rawValue).replace(' ', 'T'));
            } // Use GMT version for ISO standard T/Z formats
            catch (Exception e) {
                try {
                    return Datetime.valueOf((String) rawValue);
                } // Try local parse as fallback
                catch (Exception e2) {
                    throw new InvalidArgumentTypeException(
                        'Invalid Datetime format for field "' +
                            fieldName +
                            '". Use ISO 8601 (YYYY-MM-DDTHH:mm:ssZ or YYYY-MM-DD hh:mm:ss). Got: "' +
                            rawValue +
                            '"',
                        e2
                    );
                }
            }
        }
        // *** FIXED ERROR MESSAGE ***
        throw new InvalidArgumentTypeException(
            'Cannot coerce to Datetime for field "' + fieldName + '". Expected String or Datetime, got ' + getInputTypeString(rawValue)
        );
    }

    /**
     * @description
     * Coerces a value to a Boolean type (true/false, 0/1, or Boolean object).
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @return Boolean value
     * @throws InvalidArgumentTypeException for invalid input
     */
    private static Boolean coerceToBoolean(Object rawValue, String fieldName) {
        if (rawValue instanceof Boolean)
            return (Boolean) rawValue;
        if (rawValue instanceof String) {
            String sVal = ((String) rawValue).trim().toLowerCase();
            if (sVal == 'true')
                return true;
            if (sVal == 'false')
                return false;
        }
        if (rawValue instanceof Integer || rawValue instanceof Decimal) {
            return Decimal.valueOf(String.valueOf(rawValue)) != 0;
        }
        throw new InvalidArgumentTypeException(
            'Cannot coerce to Boolean for field "' +
                fieldName +
                '". Expected true/false or number 0/1. Got: "' +
                rawValue +
                '" (' +
                getInputTypeString(rawValue) +
                ')'
        );
    }

    /**
     * @description
     * Coerces a value to a Decimal type (number or numeric string).
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @return Decimal value
     * @throws InvalidArgumentTypeException for invalid input
     */
    private static Decimal coerceToDecimal(Object rawValue, String fieldName) {
        if (rawValue instanceof Integer || rawValue instanceof Double || rawValue instanceof Decimal)
            return Decimal.valueOf(String.valueOf(rawValue));
        if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
                return Decimal.valueOf((String) rawValue);
            } catch (Exception e) {
                throw new InvalidArgumentTypeException('Invalid Decimal format for field "' + fieldName + '". Got: "' + rawValue + '"');
            }
        }
        // *** FIXED ERROR MESSAGE ***
        throw new InvalidArgumentTypeException(
            'Cannot coerce to Decimal for field "' + fieldName + '". Expected Number or numeric String, got ' + getInputTypeString(rawValue)
        );
    }

    /**
     * @description
     * Coerces a value to an Integer type (number, numeric string, or Long within range).
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @return Integer value
     * @throws InvalidArgumentTypeException for invalid input or out-of-range values
     */
    private static Integer coerceToInteger(Object rawValue, String fieldName) {
        final Long INT_MAX_AS_LONG = 2147483647L; // Integer.MAX_VALUE equivalent
        final Long INT_MIN_AS_LONG = -2147483648L; // Integer.MIN_VALUE equivalent

        if (rawValue instanceof Integer)
            return (Integer) rawValue;
        if (rawValue instanceof Long) {
            Long longVal = (Long) rawValue;
            // ** CORRECTED Range Check **
            if (longVal > INT_MAX_AS_LONG || longVal < INT_MIN_AS_LONG) {
                throw new InvalidArgumentTypeException('Long value "' + longVal + '" out of range for Integer field "' + fieldName + '".');
            }
            return longVal.intValue(); // Safe cast after range check
        }
        if (rawValue instanceof Decimal || rawValue instanceof Double) {
            Decimal dVal = Decimal.valueOf(String.valueOf(rawValue));
            if (dVal.scale() > 0)
                throw new InvalidArgumentTypeException('Decimal value "' + dVal + '" cannot be used for Integer field "' + fieldName + '".');
            // ** CORRECTED Range Check **
            if (dVal > INT_MAX_AS_LONG || dVal < INT_MIN_AS_LONG) {
                throw new InvalidArgumentTypeException('Value "' + dVal + '" out of range for Integer field "' + fieldName + '".');
            }
            // Use intValue() - Note: This implicitly truncates if needed, but we already checked scale.
            // A direct cast `(Integer)dVal` is unsafe if the decimal value is outside the Integer range, hence the check above.
            return dVal.intValue();
        }
        if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
                // Integer.valueOf() handles range checks internally and throws MathException
                return Integer.valueOf((String) rawValue);
            } catch (System.MathException me) {
                // Catch specific range exception
                throw new InvalidArgumentTypeException(
                    'Value "' + rawValue + '" is out of the valid range for an Integer field "' + fieldName + '".'
                );
            } catch (Exception e) {
                // Catch general format exception
                throw new InvalidArgumentTypeException('Invalid Integer format for field "' + fieldName + '". Got: "' + rawValue + '"');
            }
        }
        throw new InvalidArgumentTypeException(
            'Cannot coerce to Integer for field "' + fieldName + '". Expected Number or numeric String, got ' + getInputTypeString(rawValue)
        );
    }

    /**
     * @description
     * Coerces a value to a numeric type (Integer, Decimal, etc.).
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @param fieldType Schema.DisplayType for numeric type
     * @return Object coerced to the correct numeric type
     * @throws InvalidArgumentTypeException for invalid input
     */
    private static Object coerceToNumber(Object rawValue, String fieldName, Schema.DisplayType fieldType) {
        Decimal decimalValue;

        if (rawValue instanceof Integer || rawValue instanceof Double || rawValue instanceof Decimal) {
            decimalValue = Decimal.valueOf(String.valueOf(rawValue));
        } else if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
                decimalValue = Decimal.valueOf((String) rawValue);
            } catch (Exception e) {
                throw new InvalidArgumentTypeException('Invalid numeric format for field ' + fieldName + ': ' + rawValue);
            }
        } else {
            throw new InvalidArgumentTypeException('Expected Number or numeric String for field ' + fieldName + ', got ' + rawValue);
        }

        // Convert to specific numeric type if needed
        if (fieldType == Schema.DisplayType.INTEGER) {
            return decimalValue.intValue();
        }

        return decimalValue;
    }

    /**
     * @description
     * Coerces a value to a Salesforce Id type (Id object or valid ID string).
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @return Id value
     * @throws InvalidArgumentTypeException for invalid input
     */
    private static Id coerceToId(Object rawValue, String fieldName) {
        if (rawValue instanceof Id)
            return (Id) rawValue;
        if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
                return Id.valueOf((String) rawValue);
            } catch (Exception e) {
                throw new InvalidArgumentTypeException('Invalid Salesforce ID format for field "' + fieldName + '". Got: "' + rawValue + '"');
            }
        }
        // *** FIXED ERROR MESSAGE ***
        throw new InvalidArgumentTypeException(
            'Cannot coerce to Id for field "' + fieldName + '". Expected ID string, got ' + getInputTypeString(rawValue)
        );
    }

    /**
     * @description
     * Coerces a value to a String type, with picklist and multipicklist validation.
     *
     * @param rawValue Input value to convert
     * @param fieldName Field API name for error context
     * @param dfr Field describe result for validation
     * @return String value
     * @throws InvalidArgumentTypeException for invalid input or picklist values
     */
    private static String coerceToString(Object rawValue, String fieldName, DescribeFieldResult dfr) {
        String stringValue = String.valueOf(rawValue); // Let Apex handle basic conversion
        Integer maxLength = dfr.getLength();
        Schema.DisplayType fieldType = dfr.getType();

        // Perform post-conversion validations
        if (fieldType == DisplayType.PICKLIST)
            validatePicklistValue(stringValue, fieldName, dfr);
        else if (fieldType == DisplayType.MULTIPICKLIST)
            validateMultiPicklistValues(stringValue, fieldName, dfr);

        // Note: TextAreas (Long/Rich) don't have 'Length' from describe, checked by DML implicitly.
        // Check length for standard string types
        if (fieldType != DisplayType.TEXTAREA && maxLength > 0 && stringValue.length() > maxLength) {
            throw new InvalidArgumentTypeException(
                'Value length (' + stringValue.length() + ') exceeds maximum (' + maxLength + ') for field "' + fieldName + '".'
            );
        }
        return stringValue;
    }

    /**
     * @description
     * Validates a picklist value against allowed values for the field.
     *
     * @param value Value to validate
     * @param fieldName Field API name for error context
     * @param dfr Field describe result for picklist values
     * @throws InvalidArgumentTypeException if value is not valid for the picklist
     */
    private static void validatePicklistValue(String value, String fieldName, Schema.DescribeFieldResult dfr) {
        List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
        if (entries == null || entries.isEmpty())
            return;
        Boolean isValid = false;
        for (Schema.PicklistEntry entry : entries) {
            // Case-sensitive match is standard for SF picklists generally
            if (entry.isActive() && entry.getValue().equals(value)) {
                isValid = true;
                break;
            }
        }
        if (!isValid) {
            throw new InvalidArgumentTypeException('Invalid picklist value "' + value + '" for field "' + fieldName + '".');
        }
    }

    /**
     * @description
     * Validates a multipicklist value string against allowed values for the field.
     *
     * @param value Multipicklist value string (semicolon-separated)
     * @param fieldName Field API name for error context
     * @param dfr Field describe result for picklist values
     * @throws InvalidArgumentTypeException if any value is not valid for the multipicklist
     */
    private static void validateMultiPicklistValues(String value, String fieldName, Schema.DescribeFieldResult dfr) {
        List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
        if (entries == null || entries.isEmpty())
            return;
        Set<String> validValues = new Set<String>();
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive())
                validValues.add(entry.getValue());
        }

        for (String item : value.split(';')) {
            String trimmedItem = item.trim();
            if (String.isNotBlank(trimmedItem) && !validValues.contains(trimmedItem)) {
                throw new InvalidArgumentTypeException('Invalid value "' + trimmedItem + '" in multipicklist string for field "' + fieldName + '".');
            }
        }
    }

    public class InvalidArgumentTypeException extends AIAgentException {
    }
}
