/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Created by sonal on 2025-05-28.
 */

public with sharing class SObjectArgumentCoercionService {
    /**
     * @description Converts raw argument values to types compatible with SObject fields.
     * @param rawArguments Map<String, Object> Parsed JSON arguments from LLM.
     * @param targetSObjectType The SObjectType the arguments are intended for.
     * @param accessType AccessType.CREATABLE or AccessType.UPDATABLE (for relevant describe checks)
     * @return Map<String, Object> A new map with values coerced to appropriate Apex types.
     * @throws InvalidArgumentTypeException If a value cannot be safely coerced to the target field type.
     * @throws ActionSecurityException If object/field describe fails.
     */
    public static Map<String, Object> coerceArgumentTypesForSObject(
        Map<String, Object> rawArguments,
        SObjectType targetSObjectType,
        AccessType accessType
    ) {
        if (rawArguments == null || rawArguments.isEmpty())
            return new Map<String, Object>();

        if (targetSObjectType == null)
            throw new SecurityUtils.ActionSecurityException('Target SObjectType cannot be null.');
        if (accessType != System.AccessType.CREATABLE && accessType != System.AccessType.UPDATABLE) {
            throw new InvalidArgumentTypeException('AccessType must be CREATABLE or UPDATABLE.');
        }

        Map<String, Object> coercedArguments = new Map<String, Object>();
        Map<String, Schema.SObjectField> allFields = SchemaUtils.getObjectFields(targetSObjectType);

        for (String fieldName : rawArguments.keySet()) {
            Schema.SObjectField fieldToken = allFields.get(fieldName.toLowerCase());
            if (fieldToken == null) {
                continue;
            }

            Schema.DescribeFieldResult dfr = fieldToken.getDescribe();

            if (!SecurityUtils.hasFieldPermission(dfr, accessType)) {
                continue;
            }

            Object rawValue = rawArguments.get(fieldName);
            try {
                Object coercedValue = coerceValueForField(rawValue, fieldName, dfr);
                coercedArguments.put(dfr.getName(), coercedValue);
            } catch (InvalidArgumentTypeException e) {
                String errMsg = 'Failed coercing value for permitted field "' + fieldName + '". Error: ' + e.getMessage();

                throw new InvalidArgumentTypeException(errMsg, e);
            }
        }

        return coercedArguments;
    }

    private static String getInputTypeString(Object val) {
        if (val == null)
            return 'null';

        if (val instanceof String)
            return 'String';
        if (val instanceof Integer)
            return 'Integer';
        if (val instanceof Long)
            return 'Long';
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

        if (val instanceof SObject) {
            try {
                return ((SObject) val).getSObjectType().getDescribe().getName();
            } catch (Exception e) {
                return 'SObject';
            }
        }

        return 'Object (Unknown Type)';
    }

    /**
     * @description Coerces a raw value based on field type. Throws InvalidArgumentTypeException on failure.
     * @param rawValue The value to coerce
     * @param fieldName The API name of the field (for error messages)
     * @param dfr The field describe result (for type and validation info)
     * @return Object The coerced value
     * @throws InvalidArgumentTypeException If the value cannot be coerced to the target type or violates constraints.
     */
    private static Object coerceValueForField(Object rawValue, String fieldName, Schema.DescribeFieldResult dfr) {
        if (rawValue == null)
            return null;
        Schema.DisplayType fieldType = dfr.getType();

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
     * @description Coerces a value to a Time type
     */
    private static Time coerceToTime(Object rawValue, String fieldName) {
        if (rawValue instanceof Time) {
            return (Time) rawValue;
        } else if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
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

        throw new InvalidArgumentTypeException(
            'Cannot coerce to Date for field "' + fieldName + '". Expected String or Date, got ' + getInputTypeString(rawValue)
        );
    }

    private static Datetime coerceToDateTime(Object rawValue, String fieldName) {
        if (rawValue instanceof Datetime)
            return (Datetime) rawValue;
        if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
                return Datetime.valueOfGmt(((String) rawValue).replace(' ', 'T'));
            } catch (Exception e) {
                try {
                    return Datetime.valueOf((String) rawValue);
                } catch (Exception e2) {
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

        throw new InvalidArgumentTypeException(
            'Cannot coerce to Datetime for field "' + fieldName + '". Expected String or Datetime, got ' + getInputTypeString(rawValue)
        );
    }

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

        throw new InvalidArgumentTypeException(
            'Cannot coerce to Decimal for field "' + fieldName + '". Expected Number or numeric String, got ' + getInputTypeString(rawValue)
        );
    }

    private static Integer coerceToInteger(Object rawValue, String fieldName) {
        final Long INT_MAX_AS_LONG = 2147483647L;
        final Long INT_MIN_AS_LONG = -2147483648L;

        if (rawValue instanceof Integer)
            return (Integer) rawValue;
        if (rawValue instanceof Long) {
            Long longVal = (Long) rawValue;

            if (longVal > INT_MAX_AS_LONG || longVal < INT_MIN_AS_LONG) {
                throw new InvalidArgumentTypeException('Long value "' + longVal + '" out of range for Integer field "' + fieldName + '".');
            }
            return longVal.intValue();
        }
        if (rawValue instanceof Decimal || rawValue instanceof Double) {
            Decimal dVal = Decimal.valueOf(String.valueOf(rawValue));
            if (dVal.scale() > 0)
                throw new InvalidArgumentTypeException('Decimal value "' + dVal + '" cannot be used for Integer field "' + fieldName + '".');

            if (dVal > INT_MAX_AS_LONG || dVal < INT_MIN_AS_LONG) {
                throw new InvalidArgumentTypeException('Value "' + dVal + '" out of range for Integer field "' + fieldName + '".');
            }

            return dVal.intValue();
        }
        if (rawValue instanceof String && String.isNotBlank((String) rawValue)) {
            try {
                return Integer.valueOf((String) rawValue);
            } catch (System.MathException me) {
                throw new InvalidArgumentTypeException(
                    'Value "' + rawValue + '" is out of the valid range for an Integer field "' + fieldName + '".'
                );
            } catch (Exception e) {
                throw new InvalidArgumentTypeException('Invalid Integer format for field "' + fieldName + '". Got: "' + rawValue + '"');
            }
        }
        throw new InvalidArgumentTypeException(
            'Cannot coerce to Integer for field "' + fieldName + '". Expected Number or numeric String, got ' + getInputTypeString(rawValue)
        );
    }

    /**
     * @description Coerces a value to a numeric type (Integer, Decimal, etc.)
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

        if (fieldType == Schema.DisplayType.INTEGER) {
            return decimalValue.intValue();
        }

        return decimalValue;
    }

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

        throw new InvalidArgumentTypeException(
            'Cannot coerce to Id for field "' + fieldName + '". Expected ID string, got ' + getInputTypeString(rawValue)
        );
    }

    private static String coerceToString(Object rawValue, String fieldName, DescribeFieldResult dfr) {
        String stringValue = String.valueOf(rawValue);
        Integer maxLength = dfr.getLength();
        Schema.DisplayType fieldType = dfr.getType();

        if (fieldType == DisplayType.PICKLIST)
            validatePicklistValue(stringValue, fieldName, dfr);
        else if (fieldType == DisplayType.MULTIPICKLIST)
            validateMultiPicklistValues(stringValue, fieldName, dfr);

        if (fieldType != DisplayType.TEXTAREA && maxLength > 0 && stringValue.length() > maxLength) {
            throw new InvalidArgumentTypeException(
                'Value length (' + stringValue.length() + ') exceeds maximum (' + maxLength + ') for field "' + fieldName + '".'
            );
        }
        return stringValue;
    }

    private static void validatePicklistValue(String value, String fieldName, Schema.DescribeFieldResult dfr) {
        List<Schema.PicklistEntry> entries = dfr.getPicklistValues();
        if (entries == null || entries.isEmpty())
            return;
        Boolean isValid = false;
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive() && entry.getValue().equals(value)) {
                isValid = true;
                break;
            }
        }
        if (!isValid) {
            throw new InvalidArgumentTypeException('Invalid picklist value "' + value + '" for field "' + fieldName + '".');
        }
    }

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

    public class ActionSecurityException extends AIAgentException {
    }
    public class InvalidArgumentTypeException extends AIAgentException {
    }
}
