/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SchemaUtils is a high-performance utility class for accessing Salesforce schema metadata with intelligent caching.
 * It provides static methods to retrieve SObjectType and SObjectField tokens efficiently, minimizing describe calls
 * and improving performance across transactions. All lookups are case-insensitive and results are cached for the
 * duration of the transaction, making this class ideal for repeated schema operations in orchestration, validation,
 * and dynamic logic.
 *
 * Responsibilities:
 *   - Provide fast, cached access to SObjectType and field metadata
     - Normalize all lookups to be case-insensitive
 *   - Handle describe errors gracefully and log meaningful debug output
 *   - Support robust, maintainable dynamic schema operations
 */
public inherited sharing class SchemaUtils {
    @TestVisible
    private static Map<String, SObjectType> sObjectTypeCache = new Map<String, SObjectType>();
    @TestVisible
    private static Map<String, Map<String, SObjectField>> fieldDescribeCache = new Map<String, Map<String, SObjectField>>();

    /**
     * Retrieves an SObjectType by API name, using case-insensitive lookup and transaction-scoped caching.
     *
     * @param apiName   The SObject API name to retrieve (case-insensitive).
     * @return          SObjectType instance, or null if not found or inaccessible.
     * @sideeffect      Caches the result for the duration of the transaction.
     * @debug           Logs errors if describe fails.
     */
    public static SObjectType getSObjectType(String apiName) {
        if (String.isBlank(apiName)) {
            System.debug(LoggingLevel.WARN, '[SchemaUtils.getSObjectType] Blank API name provided. Returning null.');
            return null;
        }
        String lowerApiName = apiName.toLowerCase();
        if (!sObjectTypeCache.containsKey(lowerApiName)) {
            SObjectType objType = null;
            try {
                objType = Schema.getGlobalDescribe().get(lowerApiName);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[SchemaUtils.getSObjectType] Error describing SObject "' + apiName + '": ' + e.getMessage());
            }
            sObjectTypeCache.put(lowerApiName, objType);
        }
        return sObjectTypeCache.get(lowerApiName);
    }

    /**
     * Retrieves a map of all fields for an SObjectType, with case-insensitive keys and transaction-scoped caching.
     *
     * @param sObjectType   The SObjectType to retrieve fields for.
     * @return              Map of lowercase field names to SObjectField tokens, or empty if describe fails.
     * @sideeffect          Caches the field map for the duration of the transaction.
     * @debug               Logs warnings if describe fails.
     */
    public static Map<String, SObjectField> getObjectFields(SObjectType sObjectType) {
        if (sObjectType == null) {
            System.debug(LoggingLevel.WARN, '[SchemaUtils.getObjectFields] Null SObjectType provided. Returning empty map.');
            return new Map<String, SObjectField>();
        }
        String typeName = sObjectType.getDescribe().getName().toLowerCase();
        if (!fieldDescribeCache.containsKey(typeName)) {
            Map<String, SObjectField> fieldMapLowerKeys = new Map<String, SObjectField>();
            try {
                Map<String, SObjectField> originalCaseMap = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();
                if (originalCaseMap != null) {
                    for (String fieldKey : originalCaseMap.keySet()) {
                        if (originalCaseMap.get(fieldKey) != null) {
                            fieldMapLowerKeys.put(fieldKey.toLowerCase(), originalCaseMap.get(fieldKey));
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.WARN,
                    '[SchemaUtils.getObjectFields] Error describing fields for ' + sObjectType.getDescribe().getName() + ': ' + e.getMessage()
                );
                // Return empty map on describe failure
            }
            fieldDescribeCache.put(typeName, fieldMapLowerKeys);
        }
        return fieldDescribeCache.get(typeName);
    }

    /**
     * Retrieves a specific SObjectField token by field name, using case-insensitive lookup and caching.
     *
     * @param sObjectType   The SObjectType containing the field.
     * @param fieldName     The field API name to retrieve (case-insensitive).
     * @return              SObjectField token, or null if not found or invalid parameters.
     */
    public static SObjectField getFieldToken(SObjectType sObjectType, String fieldName) {
        if (sObjectType == null || String.isBlank(fieldName))
            return null;
        Map<String, SObjectField> objFields = getObjectFields(sObjectType);
        return objFields.get(fieldName.toLowerCase());
    }
}
