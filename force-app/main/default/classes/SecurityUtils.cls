/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Utility class for enforcing Salesforce CRUD and Field-Level Security permissions.
 * Provides static methods to validate and check user access for SObject and field operations.
 */
public with sharing class SecurityUtils {
    /**
     * Exception thrown when security validation fails.
     */
    public class ActionSecurityException extends AIAgentException {
    }

    /**
     * Validates that the current user has the specified CRUD permission on an SObject type.
     * Throws ActionSecurityException if permission is denied or parameters are invalid.
     *
     * @param sObjectType   The SObjectType to validate permissions for.
     * @param accessType    The required access level (CREATABLE, READABLE, UPDATABLE).
     * @throws              ActionSecurityException if permission is denied or parameters are invalid.
     * @debug               Logs warnings on denied access and debug on success.
     */
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
            System.debug(LoggingLevel.WARN, '[SecurityUtils.checkObjectPermission] ' + errorMessage);
            throw new ActionSecurityException(errorMessage);
        }
        System.debug(LoggingLevel.DEBUG, '[SecurityUtils.checkObjectPermission] PASSED: User has ' + permissionType + ' on ' + describeResult.getName());
    }

    /**
     * Validates Field-Level Security (FLS) permissions for a specific field using its describe result.
     * Throws ActionSecurityException if permission is denied or parameters are invalid.
     *
     * @param dfr         The Schema.DescribeFieldResult containing field metadata.
     * @param accessType  The required field access level (READABLE, CREATABLE, UPDATABLE).
     * @throws            ActionSecurityException if field permission is denied or parameters are invalid.
     * @debug             Logs debug output on success.
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
        System.debug(LoggingLevel.DEBUG, '[SecurityUtils.checkFieldPermission] PASSED: Field ' + dfr.getName() + ', Permission ' + accessType);
    }

    /**
     * Non-throwing helper method that returns boolean result for FLS permission checks.
     * Useful for conditional logic where exceptions are not desired.
     *
     * @param dfr         The Schema.DescribeFieldResult to check permissions for.
     * @param accessType  The required field access level to validate.
     * @return            true if permission is granted, false if denied or invalid parameters.
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
        return false; // Unsupported AccessType for FLS check
    }

    /**
     * Convenience method for checking field permissions using SObjectType and field name.
     * Internally resolves the field token and delegates to the DescribeFieldResult version.
     *
     * @param sObjectType   The SObjectType containing the field.
     * @param fieldName     The API name of the field to check.
     * @param accessType    The required field access level.
     * @return              true if permission is granted, false otherwise.
     */
    public static Boolean hasFieldPermission(SObjectType sObjectType, String fieldName, AccessType accessType) {
        Schema.SObjectField fieldToken = SchemaUtils.getFieldToken(sObjectType, fieldName);
        return (fieldToken != null) && hasFieldPermission(fieldToken.getDescribe(), accessType);
    }
}
