/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Utility methods for interacting with Salesforce Schema information, including caching.
 */
public inherited sharing class SchemaUtils {
    @TestVisible
    private static Map<String, SObjectType> sObjectTypeCache = new Map<String, SObjectType>();
    @TestVisible
    private static Map<String, Map<String, SObjectField>> fieldDescribeCache = new Map<String, Map<String, SObjectField>>();

    /**
     * @description Gets an SObjectType from cache or Schema. Handles describe errors.
     * @param apiName API Name of the SObject (case-insensitive).
     * @return SObjectType or null if not found or inaccessible.
     */
    public static SObjectType getSObjectType(String apiName) {
        if (String.isBlank(apiName))
            return null;
        String lowerApiName = apiName.toLowerCase();
        if (!sObjectTypeCache.containsKey(lowerApiName)) {
            SObjectType objType = null;
            try {
                objType = Schema.getGlobalDescribe().get(lowerApiName);
            } catch (Exception e) {
            }
            sObjectTypeCache.put(lowerApiName, objType);
        }
        return sObjectTypeCache.get(lowerApiName);
    }

    /**
     * @description Gets the map of fields (lowercase API name -> SObjectField) for an SObject type from cache or Schema. Handles describe errors.
     * @param sObjectType The SObjectType.
     * @return Map<String, SObjectField> or an empty map if describe fails or input is null.
     */
    public static Map<String, SObjectField> getObjectFields(SObjectType sObjectType) {
        if (sObjectType == null)
            return new Map<String, SObjectField>();
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
            }
            fieldDescribeCache.put(typeName, fieldMapLowerKeys);
        }
        return fieldDescribeCache.get(typeName);
    }

    /**
     * @description Gets a specific SObjectField token (case-insensitive).
     * @param sObjectType The SObjectType.
     * @param fieldName API name of the field (case-insensitive).
     * @return SObjectField token or null if SObjectType is null, fieldName is blank, or field not found.
     */
    public static SObjectField getFieldToken(SObjectType sObjectType, String fieldName) {
        if (sObjectType == null || String.isBlank(fieldName))
            return null;
        Map<String, SObjectField> objFields = getObjectFields(sObjectType);
        return objFields.get(fieldName.toLowerCase());
    }
}
