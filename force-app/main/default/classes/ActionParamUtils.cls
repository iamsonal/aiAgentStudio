/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

public with sharing class ActionParamUtils {
    public class ArgumentValidationException extends AIAgentException {
    }
    public class ActionSecurityException extends AIAgentException {
    }
    public class InvalidArgumentTypeException extends AIAgentException {
    }

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

    /**
     * Safely retrieves a required String value from a parameters map.
     * @param params The map of parameters (typically from JSON.deserializeUntyped).
     * @param key The key for the required String parameter.
     * @return The String value.
     * @throws ArgumentValidationException If the key is missing, value is null/blank, or not a String.
     */
    public static String getRequiredString(Map<String, Object> params, String key) {
        if (params == null || !params.containsKey(key) || !(params.get(key) instanceof String) || String.isBlank((String) params.get(key))) {
            throw new ArgumentValidationException('Missing or invalid required parameter: "' + key + '" (non-blank String)');
        }
        return (String) params.get(key);
    }

    /**
     * Safely retrieves an optional String value from a parameters map.
     * @param params The map of parameters.
     * @param key The key for the optional String parameter.
     * @return The String value, or null if missing, null, or not a String.
     */
    public static String getOptionalString(Map<String, Object> params, String key) {
        if (params != null && params.containsKey(key) && params.get(key) instanceof String) {
            return (String) params.get(key);
        }
        return null;
    }

    /**
     * Safely retrieves a required Salesforce ID value from a parameters map.
     * @param params The map of parameters.
     * @param key The key for the required ID parameter.
     * @param requiredObjectType (Optional) The SObjectType the ID must belong to. If provided, validation is performed.
     * @return The validated Id value.
     * @throws ArgumentValidationException If the key is missing, value is invalid ID format, or doesn't match requiredObjectType.
     */
    public static Id getRequiredId(Map<String, Object> params, String key, SObjectType requiredObjectType) {
        String idStr = getRequiredString(params, key);
        try {
            Id recordId = Id.valueOf(idStr);
            if (requiredObjectType != null && recordId.getSObjectType() != requiredObjectType) {
                throw new ArgumentValidationException(
                    'Invalid format for parameter "' +
                        key +
                        '". ID ' +
                        idStr +
                        ' is not for the required object type ' +
                        requiredObjectType.getDescribe().getName()
                );
            }
            return recordId;
        } catch (System.StringException e) {
            throw new ArgumentValidationException('Invalid format for parameter "' + key + '". Expected valid Salesforce ID, received: ' + idStr);
        }
    }

    /**
     * Safely retrieves an optional Salesforce ID value from a parameters map.
     * @param params The map of parameters.
     * @param key The key for the optional ID parameter.
     * @param requiredObjectType (Optional) The SObjectType the ID must belong to. If provided, validation is performed.
     * @return The validated Id value, or null if missing or invalid format/type. Logs warning on invalid format.
     */
    public static Id getOptionalId(Map<String, Object> params, String key, SObjectType requiredObjectType) {
        if (params != null && params.containsKey(key) && params.get(key) instanceof String && String.isNotBlank((String) params.get(key))) {
            String idStr = (String) params.get(key);
            try {
                Id recordId = Id.valueOf(idStr);
                if (requiredObjectType != null && recordId.getSObjectType() != requiredObjectType) {
                    return null;
                }
                return recordId;
            } catch (System.StringException e) {
                return null;
            }
        }
        return null;
    }

    /**
     * Safely retrieves a required Boolean value from a parameters map.
     * Handles Boolean inputs or String "true"/"false".
     * @param params The map of parameters.
     * @param key The key for the required Boolean parameter.
     * @return The Boolean value.
     * @throws ArgumentValidationException If the key is missing or value is not interpretable as Boolean.
     */
    public static Boolean getRequiredBoolean(Map<String, Object> params, String key) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            throw new ArgumentValidationException('Missing required parameter: "' + key + '" (Boolean)');
        }
        Object val = params.get(key);
        if (val instanceof Boolean)
            return (Boolean) val;
        if (val instanceof String) {
            if (((String) val).equalsIgnoreCase('true'))
                return true;
            if (((String) val).equalsIgnoreCase('false'))
                return false;
        }

        throw new ArgumentValidationException(
            'Invalid value for parameter "' + key + '". Expected Boolean or String "true"/"false", got: ' + String.valueOf(val)
        );
    }

    /**
     * Safely retrieves an optional Boolean value from a parameters map.
     * @param params The map of parameters.
     * @param key The key for the optional Boolean parameter.
     * @param defaultValue The value to return if the key is missing or invalid.
     * @return The Boolean value or the defaultValue.
     */
    public static Boolean getOptionalBoolean(Map<String, Object> params, String key, Boolean defaultValue) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            return defaultValue;
        }
        Object val = params.get(key);
        if (val instanceof Boolean)
            return (Boolean) val;
        if (val instanceof String) {
            if (((String) val).equalsIgnoreCase('true'))
                return true;
            if (((String) val).equalsIgnoreCase('false'))
                return false;
        }

        return defaultValue;
    }

    /**
     * Safely retrieves a required List<String> value from a parameters map.
     * @param params The map of parameters.
     * @param key The key for the required List<String> parameter.
     * @param requireNonEmpty If true, throws exception if the list exists but is empty.
     * @return The List<String> value.
     * @throws ArgumentValidationException If validation fails.
     */
    public static List<String> getRequiredStringList(Map<String, Object> params, String key, Boolean requireNonEmpty) {
        if (params == null || !params.containsKey(key) || !(params.get(key) instanceof List<Object>)) {
            throw new ArgumentValidationException('Missing or invalid required parameter: "' + key + '" (List<String>)');
        }
        List<Object> rawList = (List<Object>) params.get(key);
        List<String> stringList = new List<String>();
        for (Object item : rawList) {
            if (!(item instanceof String)) {
                throw new ArgumentValidationException(
                    'Invalid item type in list parameter "' + key + '": Must contain only Strings. Found: ' + String.valueOf(item)
                );
            }

            stringList.add((String) item);
        }

        if (requireNonEmpty && stringList.isEmpty()) {
            throw new ArgumentValidationException('Required List parameter "' + key + '" cannot be empty.');
        }
        return stringList;
    }

    /**
     * Safely retrieves an optional List<String> value from a parameters map.
     * @param params The map of parameters.
     * @param key The key for the optional List<String> parameter.
     * @return The List<String> value, or an empty list if missing, invalid, or empty. Logs warnings on errors.
     */
    public static List<String> getOptionalStringList(Map<String, Object> params, String key) {
        List<String> stringList = new List<String>();
        if (params != null && params.containsKey(key)) {
            Object val = params.get(key);
            if (val instanceof List<Object>) {
                List<Object> rawList = (List<Object>) val;
                try {
                    for (Object item : rawList) {
                        if (!(item instanceof String)) {
                            throw new ArgumentValidationException('Contains non-String item');
                        }
                        stringList.add((String) item);
                    }
                } catch (Exception ex) {
                    return new List<String>();
                }
            } else if (val != null) {
            }
        }
        return stringList;
    }

    /**
     * Safely retrieves a required Map<String, Object> value from a parameters map.
     * @param params The map of parameters.
     * @param key The key for the required Map<String, Object> parameter.
     * @param requireNonEmpty If true, throws exception if the map exists but is empty.
     * @return The Map<String, Object> value.
     * @throws ArgumentValidationException If validation fails.
     */
    public static Map<String, Object> getRequiredMap(Map<String, Object> params, String key, Boolean requireNonEmpty) {
        if (params == null || !params.containsKey(key) || !(params.get(key) instanceof Map<String, Object>)) {
            throw new ArgumentValidationException('Missing or invalid required parameter: "' + key + '" (Map<String, Object>)');
        }
        Map<String, Object> mapValue = (Map<String, Object>) params.get(key);
        if (requireNonEmpty && mapValue.isEmpty()) {
            throw new ArgumentValidationException('Required Map parameter "' + key + '" cannot be empty.');
        }
        return mapValue;
    }

    /**
     * Safely retrieves an optional Map<String, Object> value from a parameters map.
     * @param params The map of parameters.
     * @param key The key for the optional Map<String, Object> parameter.
     * @return The Map<String, Object> value, or an empty map if missing or invalid.
     */
    public static Map<String, Object> getOptionalMap(Map<String, Object> params, String key) {
        if (params != null && params.containsKey(key) && params.get(key) instanceof Map<String, Object>) {
            return (Map<String, Object>) params.get(key);
        }
        if (params != null && params.containsKey(key) && params.get(key) != null) {
        }
        return new Map<String, Object>();
    }

    public static void validateEmailListFormat(List<String> emails, String paramName) {
        if (emails == null)
            return;
        Pattern emailPattern = Pattern.compile('^[a-zA-Z0-9._|\\\\%#~`=?&/$^*!}{+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,4}$');
        for (String email : emails) {
            if (String.isBlank(email) || !emailPattern.matcher(email).matches()) {
                throw new ArgumentValidationException('Invalid email format "' + email + '" in list parameter "' + paramName + '".');
            }
        }
    }
}
