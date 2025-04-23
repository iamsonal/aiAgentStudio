/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


public with sharing class SecurityUtils {
    /**
     * @description Checks if the current user has the specified CRUD permission on an SObject type.
     * @param sObjectType The SObjectType to check.
     * @param accessType AccessType.CREATABLE, AccessType.READABLE, AccessType.UPDATABLE, or AccessType.DELETABLE.
     * @throws ActionSecurityException If the required permission is not granted or parameters are invalid.
     */
    public static void checkObjectPermission(SObjectType sObjectType, AccessType accessType) {
        if (sObjectType == null) {
            throw new ActionSecurityException('Cannot check permissions on a null SObjectType.');
        }

        if (accessType == null) {
            throw new ActionSecurityException('AccessType cannot be null for security check.');
        }

        Schema.DescribeSObjectResult describeResult;
        try {
            describeResult = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED);
        } catch (Exception e) {
            throw new ActionSecurityException('Failed to describe SObject: ' + e.getMessage(), e);
        }

        String objectName = describeResult.getName();
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
                throw new ActionSecurityException('Unsupported AccessType provided: ' + accessType);
            }
        }

        if (!hasPermission) {
            String errorMessage = String.format(
                'INSUFFICIENT_PERMISSIONS: User {0} does not have {1} access on SObject {2}.',
                new List<String>{ UserInfo.getUserName(), permissionType, objectName }
            );

            throw new ActionSecurityException(errorMessage);
        }
    }

    /**
     * @description Checks if the current user has the specified FLS permission on a field. Throws ActionSecurityException if permission is denied.
     * @param sObjectType The SObjectType of the field.
     * @param fieldName The API name of the field.
     * @param accessType AccessType.CREATABLE, AccessType.READABLE, or AccessType.UPDATABLE.
     * @throws ActionSecurityException If the required permission is not granted or the field doesn't exist.
     */
    public static void checkFieldPermission(SObjectType sObjectType, String fieldName, AccessType accessType) {
        if (sObjectType == null || String.isBlank(fieldName)) {
            throw new ActionSecurityException(
                'Cannot check field permissions with null SObjectType or blank field name.'
            );
        }
        Map<String, Schema.SObjectField> fieldMap = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED)
            .fields.getMap();
        Schema.SObjectField fieldToken = fieldMap.get(fieldName.toLowerCase());

        if (fieldToken == null) {
            throw new ActionSecurityException(
                'Field ' + fieldName + ' not found on SObject ' + sObjectType.getDescribe().getName() + '.'
            );
        }

        Schema.DescribeFieldResult describeResult = fieldToken.getDescribe();
        Boolean hasPermission = false;

        switch on accessType {
            when CREATABLE {
                hasPermission = describeResult.isCreateable();
            }
            when READABLE {
                hasPermission = describeResult.isAccessible();
            }
            when UPDATABLE {
                hasPermission = describeResult.isUpdateable();
            }
            when else {
                throw new ActionSecurityException('Unsupported AccessType for field check: ' + accessType);
            }
        }

        if (!hasPermission) {
            throw new ActionSecurityException(
                'Permission denied. User does not have ' +
                    accessType +
                    ' access on Field ' +
                    describeResult.getName() +
                    ' of SObject ' +
                    sObjectType.getDescribe().getName() +
                    '.'
            );
        }
    }

    /**
     * @description Validates FLS permissions for a map of field data and returns a new map containing
     *              only the fields the user has the required permission for.
     * @param sObjectType The SObjectType of the record.
     * @param fieldData Map<String, Object> where keys are field API names and values are the data.
     * @param accessType AccessType.CREATABLE or AccessType.UPDATABLE.
     * @return Map<String, Object> A new map containing only the key-value pairs for which the user
     *         has the specified FLS permission. Returns empty map if input map is null/empty.
     * @throws ActionSecurityException if parameters are invalid.
     */
    public static Map<String, Object> filterMapByFieldPermissions(
        SObjectType sObjectType,
        Map<String, Object> fieldData,
        AccessType accessType
    ) {
        if (sObjectType == null) {
            throw new ActionSecurityException('Cannot filter fields for a null SObjectType.');
        }

        if (accessType == null) {
            throw new ActionSecurityException('AccessType cannot be null.');
        }

        if (accessType != System.AccessType.CREATABLE && accessType != System.AccessType.UPDATABLE) {
            throw new ActionSecurityException(
                'filterMapByFieldPermissions supports only AccessType.CREATABLE or AccessType.UPDATABLE. Provided: ' +
                accessType
            );
        }

        Map<String, Object> accessibleFieldsMap = new Map<String, Object>();
        if (fieldData == null || fieldData.isEmpty()) {
            return accessibleFieldsMap;
        }

        Map<String, Schema.SObjectField> allFields;
        try {
            allFields = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();
        } catch (Exception e) {
            throw new ActionSecurityException('Failed to describe SObject fields: ' + e.getMessage(), e);
        }

        Set<String> skippedFields = new Set<String>();

        for (String fieldName : fieldData.keySet()) {
            Schema.SObjectField fieldToken = allFields.get(fieldName.toLowerCase());

            if (fieldToken != null && hasFieldPermission(fieldToken, accessType)) {
                accessibleFieldsMap.put(fieldName, fieldData.get(fieldName));
            } else {
                skippedFields.add(fieldName);
            }
        }

        if (!skippedFields.isEmpty()) {
        }

        return accessibleFieldsMap;
    }

    /**
     * @description Helper method to check if a field has the specified permission.
     * @param fieldToken The SObjectField to check.
     * @param accessType The type of access to check (CREATABLE or UPDATABLE).
     * @return Boolean True if the user has the specified permission, false otherwise.
     */
    public static Boolean hasFieldPermission(Schema.SObjectField fieldToken, AccessType accessType) {
        Schema.DescribeFieldResult dfr = fieldToken.getDescribe();

        if (accessType == System.AccessType.CREATABLE) {
            return dfr.isCreateable();
        } else if (accessType == System.AccessType.UPDATABLE) {
            return dfr.isUpdateable();
        }

        return false;
    }

    /**
     * @description Checks if the current user has the specified access type permission for the field
     * @param dfr The field describe result
     * @param accessType The type of access to check (CREATABLE or UPDATABLE)
     * @return Boolean True if the user has permission, false otherwise
     */
    public static Boolean hasFieldPermission(Schema.DescribeFieldResult dfr, AccessType accessType) {
        return (accessType == System.AccessType.CREATABLE && dfr.isCreateable()) ||
            (accessType == System.AccessType.UPDATABLE && dfr.isUpdateable());
    }

    public class ActionSecurityException extends AIAgentException {
    }
}
