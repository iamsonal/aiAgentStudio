/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

public with sharing class ParameterExtractionUtils {
    public class ArgumentValidationException extends AIAgentException {
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
