/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Utils consolidates shared schema and security utilities:
 *  - Cached schema metadata access (SObjectType, fields, describe)
 *  - CRUD/FLS permission checks with clear error reporting
 */
public inherited sharing class Utils {
    // ===== Schema utilities =====
    @TestVisible
    private static Map<String, SObjectType> sObjectTypeCache = new Map<String, SObjectType>();
    @TestVisible
    private static Map<String, Map<String, SObjectField>> fieldDescribeCache = new Map<String, Map<String, SObjectField>>();
    @TestVisible
    private static Map<String, DescribeSObjectResult> describeCache = new Map<String, DescribeSObjectResult>();

    public static SObjectType getSObjectType(String apiName) {
        if (String.isBlank(apiName)) {
            System.debug(LoggingLevel.WARN, '[Utils.getSObjectType] Blank API name provided. Returning null.');
            return null;
        }
        String lowerApiName = apiName.toLowerCase();
        if (!sObjectTypeCache.containsKey(lowerApiName)) {
            SObjectType objType = null;
            try {
                objType = Schema.getGlobalDescribe().get(lowerApiName);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '[Utils.getSObjectType] Error describing SObject "' + apiName + '": ' + e.getMessage());
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
     */
    public static Map<String, SObjectField> getObjectFields(SObjectType sObjectType) {
        if (sObjectType == null) {
            System.debug(LoggingLevel.WARN, '[Utils.getObjectFields] Null SObjectType provided. Returning empty map.');
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
                    '[Utils.getObjectFields] Error describing fields for ' + sObjectType.getDescribe().getName() + ': ' + e.getMessage()
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
        if (sObjectType == null || String.isBlank(fieldName)) {
            return null;
        }
        Map<String, SObjectField> objFields = getObjectFields(sObjectType);
        return objFields.get(fieldName.toLowerCase());
    }

    /**
     * Retrieves the DescribeSObjectResult for an SObjectType with transaction-scoped caching.
     *
     * @param sObjectType   The SObjectType to describe.
     * @return              DescribeSObjectResult with comprehensive object metadata, or null if describe fails.
     */
    public static DescribeSObjectResult getDescribe(SObjectType sObjectType) {
        if (sObjectType == null) {
            System.debug(LoggingLevel.WARN, '[Utils.getDescribe] Null SObjectType provided. Returning null.');
            return null;
        }
        String typeName = sObjectType.getDescribe().getName().toLowerCase();
        if (!describeCache.containsKey(typeName)) {
            DescribeSObjectResult describeResult = null;
            try {
                describeResult = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[Utils.getDescribe] Error describing SObject ' + sObjectType.getDescribe().getName() + ': ' + e.getMessage());
            }
            describeCache.put(typeName, describeResult);
        }
        return describeCache.get(typeName);
    }

    // ===== Security utilities =====
    public class ActionSecurityException extends AIAgentException {
    }

    public static void checkObjectPermission(SObjectType sObjectType, AccessType accessType) {
        if (sObjectType == null) {
            throw new ActionSecurityException('SObjectType cannot be null for object permission check.');
        }
        if (accessType == null) {
            throw new ActionSecurityException('AccessType cannot be null for object permission check.');
        }

        Schema.DescribeSObjectResult describeResult;
        try {
            describeResult = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED);
        } catch (Exception e) {
            throw new ActionSecurityException('Failed to describe SObject ' + String.valueOf(sObjectType) + ': ' + e.getMessage(), e);
        }

        Boolean hasPermission = false;
        String permissionType = '';
        switch on accessType {
            when CREATABLE {
                hasPermission = describeResult.isCreateable();
                permissionType = 'CREATE';
            }
            when READABLE {
                hasPermission = describeResult.isAccessible();
                permissionType = 'READ';
            }
            when UPDATABLE {
                hasPermission = describeResult.isUpdateable();
                permissionType = 'UPDATE';
            }
            when else {
                throw new ActionSecurityException('Unsupported AccessType for object permission check: ' + accessType);
            }
        }

        if (!hasPermission) {
            String errorMessage = String.format(
                'User {0} does not have {1} access on SObject {2}.',
                new List<String>{ UserInfo.getUserName(), permissionType, describeResult.getName() }
            );
            System.debug(LoggingLevel.WARN, '[Utils.checkObjectPermission] ' + errorMessage);
            throw new ActionSecurityException(errorMessage);
        }
        System.debug(LoggingLevel.DEBUG, '[Utils.checkObjectPermission] PASSED: User has ' + permissionType + ' on ' + describeResult.getName());
    }

    /**
     * Validates Field-Level Security (FLS) permissions for a specific field using its describe result.
     * Throws ActionSecurityException if permission is denied or parameters are invalid.
     */
    public static void checkFieldPermission(Schema.DescribeFieldResult dfr, AccessType accessType) {
        if (dfr == null) {
            throw new ActionSecurityException('DescribeFieldResult cannot be null for field permission check.');
        }
        if (
            accessType == null ||
            (accessType != System.AccessType.READABLE &&
            accessType != System.AccessType.CREATABLE &&
            accessType != System.AccessType.UPDATABLE)
        ) {
            throw new ActionSecurityException('Invalid AccessType for field permission check: ' + accessType + '. Expected READABLE, CREATABLE, or UPDATABLE.');
        }

        Boolean hasPermission = hasFieldPermission(dfr, accessType);

        if (!hasPermission) {
            throw new ActionSecurityException('Permission denied. User does not have ' + accessType + ' access on field ' + dfr.getName() + '.');
        }
        System.debug(LoggingLevel.DEBUG, '[Utils.checkFieldPermission] PASSED: Field ' + dfr.getName() + ', Permission ' + accessType);
    }

    /**
     * Non-throwing helper method that returns boolean result for FLS permission checks.
     * Useful for conditional logic where exceptions are not desired.
     */
    public static Boolean hasFieldPermission(Schema.DescribeFieldResult dfr, AccessType accessType) {
        if (dfr == null) {
            return false;
        }
        if (accessType == System.AccessType.CREATABLE) {
            return dfr.isCreateable();
        }
        if (accessType == System.AccessType.UPDATABLE) {
            return dfr.isUpdateable();
        }
        if (accessType == System.AccessType.READABLE) {
            return dfr.isAccessible();
        }
        return false; // Unsupported AccessType for FLS check
    }

    /**
     * Convenience method for checking field permissions using SObjectType and field name.
     */
    public static Boolean hasFieldPermission(SObjectType sObjectType, String fieldName, AccessType accessType) {
        Schema.SObjectField fieldToken = Utils.getFieldToken(sObjectType, fieldName);
        return (fieldToken != null) && hasFieldPermission(fieldToken.getDescribe(), accessType);
    }
}
