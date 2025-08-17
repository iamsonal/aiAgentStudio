/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ParameterExtractionUtils provides robust, type-safe extraction and validation of parameters from
 * untyped maps (such as those produced by JSON.deserializeUntyped). It offers a suite of static methods
 * for retrieving required and optional values of various types (String, Id, Boolean, List<String>, Map<String,Object>),
 * with comprehensive validation, error handling, and clear exception semantics. This utility is designed
 * to centralize parameter validation logic, reduce boilerplate, and ensure consistent error reporting
 * across agent and orchestration flows.
 *
 * Key responsibilities:
 *   - Enforce presence, type, and format of required parameters
 *   - Provide safe, null-tolerant access to optional parameters
 *   - Validate Salesforce Ids and object types
 *   - Validate lists and maps for content and type
 *   - Log warnings for recoverable issues in optional extraction
 *   - Raise clear exceptions for unrecoverable validation failures
 */
public with sharing class ParameterExtractionUtils {
    /**
     * Exception thrown when parameter validation fails.
     * Used to signal unrecoverable extraction/validation errors.
     */
    public class ArgumentValidationException extends AIAgentException {
    }

    /**
     * Retrieves a required String value from a parameters map, enforcing presence and non-blankness.
     *
     * @param params   Map of parameters (typically from JSON.deserializeUntyped).
     * @param key      Key for the required String parameter.
     * @return         The non-blank String value.
     * @throws         ArgumentValidationException if missing, blank, or not a String.
     */
    public static String getRequiredString(Map<String, Object> params, String key) {
        if (params == null || !params.containsKey(key) || !(params.get(key) instanceof String) || String.isBlank((String) params.get(key))) {
            throw new ArgumentValidationException('Missing or invalid required parameter: "' + key + '" (non-blank String)');
        }
        return (String) params.get(key);
    }

    /**
     * Retrieves an optional String value from a parameters map.
     *
     * @param params   Map of parameters.
     * @param key      Key for the optional String parameter.
     * @return         The String value, or null if missing or not a String.
     */
    public static String getOptionalString(Map<String, Object> params, String key) {
        if (params != null && params.containsKey(key) && params.get(key) instanceof String) {
            // Return even if blank, let caller decide if blank is invalid for *their* use case
            return (String) params.get(key);
        }
        return null;
    }

    /**
     * Retrieves a required Salesforce Id value from a parameters map, validating format and optionally object type.
     *
     * @param params             Map of parameters.
     * @param key                Key for the required Id parameter.
     * @param requiredObjectType (Optional) SObjectType the Id must belong to; if provided, enforces type match.
     * @return                   The validated Id value.
     * @throws                   ArgumentValidationException if missing, invalid format, or type mismatch.
     */
    public static Id getRequiredId(Map<String, Object> params, String key, SObjectType requiredObjectType) {
        String idStr = getRequiredString(params, key); // Reuse required string check
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
     * Retrieves an optional Salesforce Id value from a parameters map, validating format and optionally object type.
     *
     * @param params             Map of parameters.
     * @param key                Key for the optional Id parameter.
     * @param requiredObjectType (Optional) SObjectType the Id must belong to; if provided, enforces type match.
     * @return                   The validated Id value, or null if missing/invalid. Logs warning on invalid format/type.
     */
    public static Id getOptionalId(Map<String, Object> params, String key, SObjectType requiredObjectType) {
        if (params != null && params.containsKey(key) && params.get(key) instanceof String && String.isNotBlank((String) params.get(key))) {
            String idStr = (String) params.get(key);
            try {
                Id recordId = Id.valueOf(idStr);
                if (requiredObjectType != null && recordId.getSObjectType() != requiredObjectType) {
                    System.debug(
                        LoggingLevel.WARN,
                        '[ParameterExtractionUtils.getOptionalId] Provided ID ' +
                            idStr +
                            ' for key "' +
                            key +
                            '" does not match required type ' +
                            requiredObjectType.getDescribe().getName() +
                            '. Returning null.'
                    );
                    return null; // Type mismatch
                }
                return recordId;
            } catch (System.StringException e) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ParameterExtractionUtils.getOptionalId] Invalid ID format for key "' + key + '": ' + idStr + '. Returning null.'
                );
                return null; // Invalid format
            }
        }
        return null; // Not present or not a string
    }

    /**
     * Retrieves a required Boolean value from a parameters map, accepting Boolean or String "true"/"false".
     *
     * @param params   Map of parameters.
     * @param key      Key for the required Boolean parameter.
     * @return         The Boolean value.
     * @throws         ArgumentValidationException if missing or not interpretable as Boolean.
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
        // Add handling for numbers 0/1 if desired
        // if (val instanceof Integer || val instanceof Decimal) return Decimal.valueOf(String.valueOf(val)) != 0;
        throw new ArgumentValidationException(
            'Invalid value for parameter "' + key + '". Expected Boolean or String "true"/"false", got: ' + String.valueOf(val)
        );
    }

    /**
     * Retrieves an optional Boolean value from a parameters map, accepting Boolean or String "true"/"false".
     *
     * @param params       Map of parameters.
     * @param key          Key for the optional Boolean parameter.
     * @param defaultValue Value to return if missing or invalid.
     * @return             The Boolean value or defaultValue.
     * @sideeffect         Logs warning if value is present but invalid.
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
        // Optionally handle numbers 0/1
        // if (val instanceof Integer || val instanceof Decimal) return Decimal.valueOf(String.valueOf(val)) != 0;
        System.debug(
            LoggingLevel.WARN,
            '[ParameterExtractionUtils.getOptionalBoolean] Invalid value for key "' + key + '". Using default: ' + defaultValue
        );
        return defaultValue;
    }

    /**
     * Retrieves a required List<String> value from a parameters map, enforcing type and (optionally) non-emptiness.
     *
     * @param params         Map of parameters.
     * @param key            Key for the required List<String> parameter.
     * @param requireNonEmpty If true, throws if the list exists but is empty.
     * @return               The List<String> value.
     * @throws               ArgumentValidationException if missing, not a list, contains non-Strings, or (if required) empty.
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
            // Optionally: check for blank strings within the list if needed
            stringList.add((String) item);
        }

        if (requireNonEmpty && stringList.isEmpty()) {
            throw new ArgumentValidationException('Required List parameter "' + key + '" cannot be empty.');
        }
        return stringList;
    }

    /**
     * Retrieves an optional List<String> value from a parameters map.
     *
     * @param params   Map of parameters.
     * @param key      Key for the optional List<String> parameter.
     * @return         The List<String> value, or an empty list if missing/invalid. Logs warnings on errors.
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
                            throw new ArgumentValidationException('List contains non-String item'); // Trigger catch
                        }
                        stringList.add((String) item);
                    }
                } catch (Exception ex) {
                    System.debug(
                        LoggingLevel.WARN,
                        '[ParameterExtractionUtils.getOptionalStringList] Invalid list contents for key "' +
                            key +
                            '". Returning empty list. Error: ' +
                            ex.getMessage()
                    );
                    return new List<String>(); // Return empty on item error
                }
            } else if (val != null) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ParameterExtractionUtils.getOptionalStringList] Invalid type for key "' +
                        key +
                        '". Expected List<String>. Returning empty list.'
                );
            }
        }
        return stringList; // Return potentially empty list
    }

    /**
     * Retrieves a required Map<String, Object> value from a parameters map, enforcing type and (optionally) non-emptiness.
     *
     * @param params         Map of parameters.
     * @param key            Key for the required Map<String, Object> parameter.
     * @param requireNonEmpty If true, throws if the map exists but is empty.
     * @return               The Map<String, Object> value.
     * @throws               ArgumentValidationException if missing, not a map, or (if required) empty.
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
     * Retrieves an optional Map<String, Object> value from a parameters map.
     *
     * @param params   Map of parameters.
     * @param key      Key for the optional Map<String, Object> parameter.
     * @return         The Map<String, Object> value, or an empty map if missing/invalid. Logs warning on invalid type.
     */
    public static Map<String, Object> getOptionalMap(Map<String, Object> params, String key) {
        if (params != null && params.containsKey(key) && params.get(key) instanceof Map<String, Object>) {
            return (Map<String, Object>) params.get(key);
        }
        if (params != null && params.containsKey(key) && params.get(key) != null) {
            System.debug(
                LoggingLevel.WARN,
                '[ParameterExtractionUtils.getOptionalMap] Invalid type for key "' + key + '". Expected Map<String, Object>. Returning empty map.'
            );
        }
        return new Map<String, Object>();
    }

    /**
     * Validates that all strings in a list are properly formatted email addresses.
     *
     * @param emails     List of email strings to validate.
     * @param paramName  Name of the parameter being validated (for error messages).
     * @throws           ArgumentValidationException if any email is invalid or blank.
     */
    public static void validateEmailListFormat(List<String> emails, String paramName) {
        if (emails == null)
            return; // Optional lists might be null
        Pattern emailPattern = Pattern.compile('^[a-zA-Z0-9._|\\\\%#~`=?&/$^*!}{+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,4}$');
        for (String email : emails) {
            if (String.isBlank(email) || !emailPattern.matcher(email).matches()) {
                throw new ArgumentValidationException('Invalid email format "' + email + '" in list parameter "' + paramName + '".');
            }
        }
    }
}
