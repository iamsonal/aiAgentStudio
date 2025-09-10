/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionConfigUtils provides robust, type-safe extraction and validation of parameters from
 * untyped maps (such as those produced by JSON.deserializeUntyped). It offers a suite of static methods
 * for retrieving required and optional values of various types (String, Id, Boolean, List<String>, Map<String,Object>),
 * with comprehensive validation, error handling, and clear exception semantics. This utility leverages
 * TypeCoercionService for consistent type conversion behavior across the framework.
 *
 * Key responsibilities:
 *   - Enforce presence, type, and format of required parameters using TypeCoercionService
 *   - Provide safe, null-tolerant access to optional parameters
 *   - Validate Salesforce Ids and object types
 *   - Validate lists and maps for content and type
 *   - Log warnings for recoverable issues in optional extraction
 *   - Raise clear exceptions for unrecoverable validation failures
 */
public with sharing class ActionConfigUtils {
    /**
     * Exception thrown when parameter validation fails.
     * Used to signal unrecoverable extraction/validation errors.
     */
    public class ArgumentValidationException extends AIAgentException {
    }

    /**
     * Retrieves a required String value from a parameters map, enforcing presence and non-blankness.
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
     *
     * @param params   Map of parameters (typically from JSON.deserializeUntyped).
     * @param key      Key for the required String parameter.
     * @return         The non-blank String value.
     * @throws         ArgumentValidationException if missing, blank, or not a String.
     */
    public static String getRequiredString(Map<String, Object> params, String key) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            throw new ArgumentValidationException('Missing required parameter: "' + key + '" (non-blank String)');
        }

        try {
            String result = TypeCoercionService.coerceToString(params.get(key), key, null);
            if (String.isBlank(result)) {
                throw new ArgumentValidationException('Required parameter "' + key + '" cannot be blank');
            }
            return result;
        } catch (TypeCoercionService.TypeCoercionException e) {
            throw new ArgumentValidationException('Invalid value for parameter "' + key + '". ' + e.getMessage());
        }
    }

    /**
     * Retrieves an optional String value from a parameters map.
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
     *
     * @param params   Map of parameters.
     * @param key      Key for the optional String parameter.
     * @return         The String value, or null if missing or not a String.
     */
    public static String getOptionalString(Map<String, Object> params, String key) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            return null;
        }

        try {
            // Return even if blank, let caller decide if blank is invalid for *their* use case
            return TypeCoercionService.coerceToString(params.get(key), key, null);
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionConfigUtils.getOptionalString] Invalid value for key "' + key + '". Returning null. Error: ' + e.getMessage()
            );
            return null;
        }
    }

    /**
     * Retrieves a required Salesforce Id value from a parameters map, validating format and optionally object type.
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
     *
     * @param params             Map of parameters.
     * @param key                Key for the required Id parameter.
     * @param requiredObjectType (Optional) SObjectType the Id must belong to; if provided, enforces type match.
     * @return                   The validated Id value.
     * @throws                   ArgumentValidationException if missing, invalid format, or type mismatch.
     */
    public static Id getRequiredId(Map<String, Object> params, String key, SObjectType requiredObjectType) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            throw new ArgumentValidationException('Missing required parameter: "' + key + '" (Salesforce ID)');
        }

        try {
            Id recordId = TypeCoercionService.coerceToId(params.get(key), key);
            if (requiredObjectType != null && recordId.getSObjectType() != requiredObjectType) {
                throw new ArgumentValidationException(
                    'Invalid object type for parameter "' +
                        key +
                        '". ID ' +
                        recordId +
                        ' is not for the required object type ' +
                        requiredObjectType.getDescribe().getName()
                );
            }
            return recordId;
        } catch (TypeCoercionService.TypeCoercionException e) {
            throw new ArgumentValidationException('Invalid value for parameter "' + key + '". ' + e.getMessage());
        }
    }

    /**
     * Retrieves an optional Salesforce Id value from a parameters map, validating format and optionally object type.
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
     *
     * @param params             Map of parameters.
     * @param key                Key for the optional Id parameter.
     * @param requiredObjectType (Optional) SObjectType the Id must belong to; if provided, enforces type match.
     * @return                   The validated Id value, or null if missing/invalid. Logs warning on invalid format/type.
     */
    public static Id getOptionalId(Map<String, Object> params, String key, SObjectType requiredObjectType) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            return null;
        }

        try {
            Id recordId = TypeCoercionService.coerceToId(params.get(key), key);
            if (requiredObjectType != null && recordId.getSObjectType() != requiredObjectType) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ActionConfigUtils.getOptionalId] Provided ID ' +
                        recordId +
                        ' for key "' +
                        key +
                        '" does not match required type ' +
                        requiredObjectType.getDescribe().getName() +
                        '. Returning null.'
                );
                return null; // Type mismatch
            }
            return recordId;
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionConfigUtils.getOptionalId] Invalid ID format for key "' + key + '". Returning null. Error: ' + e.getMessage()
            );
            return null; // Invalid format
        }
    }

    /**
     * Retrieves a required Boolean value from a parameters map, accepting Boolean or String "true"/"false".
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
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

        try {
            return TypeCoercionService.coerceToBoolean(params.get(key), key);
        } catch (TypeCoercionService.TypeCoercionException e) {
            throw new ArgumentValidationException('Invalid value for parameter "' + key + '". ' + e.getMessage());
        }
    }

    /**
     * Retrieves an optional Boolean value from a parameters map, accepting Boolean or String "true"/"false".
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
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

        try {
            return TypeCoercionService.coerceToBoolean(params.get(key), key);
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionConfigUtils.getOptionalBoolean] Invalid value for key "' +
                    key +
                    '". Using default: ' +
                    defaultValue +
                    '. Error: ' +
                    e.getMessage()
            );
            return defaultValue;
        }
    }

    /**
     * Retrieves a required List<String> value from a parameters map, enforcing type and (optionally) non-emptiness.
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
     *
     * @param params         Map of parameters.
     * @param key            Key for the required List<String> parameter.
     * @param requireNonEmpty If true, throws if the list exists but is empty.
     * @return               The List<String> value.
     * @throws               ArgumentValidationException if missing, not a list, contains non-Strings, or (if required) empty.
     */
    public static List<String> getRequiredStringList(Map<String, Object> params, String key, Boolean requireNonEmpty) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            throw new ArgumentValidationException('Missing required parameter: "' + key + '" (List<String>)');
        }

        try {
            List<String> stringList = TypeCoercionService.coerceToStringList(params.get(key), key);
            if (requireNonEmpty && (stringList == null || stringList.isEmpty())) {
                throw new ArgumentValidationException('Required List parameter "' + key + '" cannot be empty.');
            }
            return stringList;
        } catch (TypeCoercionService.TypeCoercionException e) {
            throw new ArgumentValidationException('Invalid value for parameter "' + key + '". ' + e.getMessage());
        }
    }

    /**
     * Retrieves an optional List<String> value from a parameters map.
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
     *
     * @param params   Map of parameters.
     * @param key      Key for the optional List<String> parameter.
     * @return         The List<String> value, or an empty list if missing/invalid. Logs warnings on errors.
     */
    public static List<String> getOptionalStringList(Map<String, Object> params, String key) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            return new List<String>();
        }

        try {
            List<String> result = TypeCoercionService.coerceToStringList(params.get(key), key);
            return result != null ? result : new List<String>();
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionConfigUtils.getOptionalStringList] Invalid list contents for key "' +
                    key +
                    '". Returning empty list. Error: ' +
                    e.getMessage()
            );
            return new List<String>(); // Return empty on error
        }
    }

    /**
     * Retrieves a required Map<String, Object> value from a parameters map, enforcing type and (optionally) non-emptiness.
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
     *
     * @param params         Map of parameters.
     * @param key            Key for the required Map<String, Object> parameter.
     * @param requireNonEmpty If true, throws if the map exists but is empty.
     * @return               The Map<String, Object> value.
     * @throws               ArgumentValidationException if missing, not a map, or (if required) empty.
     */
    public static Map<String, Object> getRequiredMap(Map<String, Object> params, String key, Boolean requireNonEmpty) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            throw new ArgumentValidationException('Missing required parameter: "' + key + '" (Map<String, Object>)');
        }

        try {
            Map<String, Object> mapValue = TypeCoercionService.coerceToStringObjectMap(params.get(key), key);
            if (requireNonEmpty && (mapValue == null || mapValue.isEmpty())) {
                throw new ArgumentValidationException('Required Map parameter "' + key + '" cannot be empty.');
            }
            return mapValue;
        } catch (TypeCoercionService.TypeCoercionException e) {
            throw new ArgumentValidationException('Invalid value for parameter "' + key + '". ' + e.getMessage());
        }
    }

    /**
     * Retrieves an optional Map<String, Object> value from a parameters map.
     * Uses TypeCoercionService for consistent coercion behavior across the framework.
     *
     * @param params   Map of parameters.
     * @param key      Key for the optional Map<String, Object> parameter.
     * @return         The Map<String, Object> value, or an empty map if missing/invalid. Logs warning on invalid type.
     */
    public static Map<String, Object> getOptionalMap(Map<String, Object> params, String key) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            return new Map<String, Object>();
        }

        try {
            Map<String, Object> result = TypeCoercionService.coerceToStringObjectMap(params.get(key), key);
            return result != null ? result : new Map<String, Object>();
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionConfigUtils.getOptionalMap] Invalid type for key "' +
                    key +
                    '". Expected Map<String, Object>. Returning empty map. Error: ' +
                    e.getMessage()
            );
            return new Map<String, Object>();
        }
    }

    /**
     * Retrieves an optional Integer value from a parameters map.
     * Uses TypeCoercionService for consistent coercion and validation.
     *
     * @param params       Map of parameters.
     * @param key          Key for the optional Integer parameter.
     * @param defaultValue Value to return if missing or invalid.
     * @return             The Integer value or defaultValue.
     */
    public static Integer getOptionalInteger(Map<String, Object> params, String key, Integer defaultValue) {
        if (params == null || !params.containsKey(key) || params.get(key) == null) {
            return defaultValue;
        }

        try {
            return TypeCoercionService.coerceToInteger(params.get(key), key);
        } catch (TypeCoercionService.TypeCoercionException e) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionConfigUtils.getOptionalInteger] Invalid value for key "' +
                    key +
                    '". Using default: ' +
                    defaultValue +
                    '. Error: ' +
                    e.getMessage()
            );
            return defaultValue;
        }
    }
}
