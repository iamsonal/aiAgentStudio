/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Utility methods for performing security checks (CRUD/FLS).
 */
public with sharing class SecurityUtils {
    /** @description Custom exception for security check failures */
    public class ActionSecurityException extends AIAgentException {
    }

    /**
     * @description Checks if the current user has the specified CRUD permission on an SObject type.
     * @param sObjectType The SObjectType to check.
     * @param accessType AccessType.CREATABLE, AccessType.READABLE, AccessType.UPDATABLE, or AccessType.DELETABLE.
     * @throws ActionSecurityException If the required permission is not granted or parameters are invalid.
     */
    public static void checkObjectPermission(SObjectType sObjectType, AccessType accessType) {
        if (sObjectType == null) {
            throw new ActionSecurityException('SObjectType cannot be null.');
        }
        if (accessType == null) {
            throw new ActionSecurityException('AccessType cannot be null.');
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
                throw new ActionSecurityException('Unsupported AccessType for object check: ' + accessType);
            }
        }

        if (!hasPermission) {
            String errorMessage = String.format(
                'User {0} does not have {1} access on SObject {2}.',
                new List<String>{ UserInfo.getUserName(), permissionType, describeResult.getName() }
            );

            throw new ActionSecurityException(errorMessage);
        }
    }

    /**
     * @description Checks if the current user has the specified FLS permission on a field using DescribeFieldResult.
     * @param dfr The Schema.DescribeFieldResult of the field.
     * @param accessType AccessType.READABLE, AccessType.CREATABLE, or AccessType.UPDATABLE.
     * @throws ActionSecurityException If the required permission is not granted.
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
            throw new ActionSecurityException('Invalid AccessType for field check: ' + accessType + '. Expected READABLE, CREATABLE, or UPDATABLE.');
        }

        Boolean hasPermission = hasFieldPermission(dfr, accessType);

        if (!hasPermission) {
            throw new ActionSecurityException('Permission denied. User does not have ' + accessType + ' access on Field ' + dfr.getName() + '.');
        }
    }

    /**
     * @description Helper method returning boolean FLS check without throwing exception.
     * @param dfr The Schema.DescribeFieldResult of the field.
     * @param accessType AccessType.READABLE, AccessType.CREATABLE, or AccessType.UPDATABLE.
     * @return Boolean true if permission granted, false otherwise. Returns false for invalid accessType.
     */
    public static Boolean hasFieldPermission(Schema.DescribeFieldResult dfr, AccessType accessType) {
        if (dfr == null)
            return false;
        if (accessType == System.AccessType.CREATABLE) {
            return dfr.isCreateable();
        }
        if (accessType == System.AccessType.UPDATABLE) {
            return dfr.isUpdateable();
        }
        if (accessType == System.AccessType.READABLE) {
            return dfr.isAccessible();
        }
        return false;
    }

    public static Boolean hasFieldPermission(SObjectType sObjectType, String fieldName, AccessType accessType) {
        Schema.SObjectField fieldToken = SchemaUtils.getFieldToken(sObjectType, fieldName);
        return (fieldToken != null) && hasFieldPermission(fieldToken.getDescribe(), accessType);
    }
}
