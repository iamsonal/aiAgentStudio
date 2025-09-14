/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SObjectArgumentCoercionService: Streamlined SObject field coercion service with FLS enforcement.
 *
 * This class provides a simple, secure interface for converting JSON/LLM arguments to Salesforce field types.
 * It leverages the powerful, schema-aware TypeCoercionService for all type conversion and validation,
 * while adding essential SObject-specific concerns like field-level security enforcement.
 *
 * Key Responsibilities:
 *   - Enforces field-level security (FLS) for create and update operations
 *   - Delegates all type coercion and validation to TypeCoercionService.coerce()
 *   - Provides structured exceptions for security violations
 *   - Maintains clean separation between security concerns and type coercion logic
 */
public with sharing class SObjectArgumentCoercionService {
    /**
     * @description
     * Converts raw arguments to Salesforce-compatible field values with comprehensive validation.
     * Performs FLS checks, type coercion, and constraint validation for secure SObject operations.
     *
     * @param rawArguments Map of field names to raw values from JSON/LLM input
     * @param targetSObjectType SObjectType for field metadata and validation context
     * @param accessType CREATABLE or UPDATABLE for appropriate FLS validation
     * @return Map of validated field names to properly typed values
     * @throws InvalidArgumentTypeException For type conversion failures or constraint violations
     * @throws ActionSecurityException For security or permission violations
     */
    public static Map<String, Object> coerceArgumentTypesForSObject(
        Map<String, Object> rawArguments,
        SObjectType targetSObjectType,
        AccessType accessType
    ) {
        if (rawArguments == null || rawArguments.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[SObjectArgumentCoercionService] No arguments provided for coercion. Returning empty map.');
            return new Map<String, Object>();
        }

        if (targetSObjectType == null) {
            throw new SecurityUtils.ActionSecurityException('Target SObjectType cannot be null.');
        }
        if (accessType != System.AccessType.CREATABLE && accessType != System.AccessType.UPDATABLE) {
            throw new InvalidArgumentTypeException('AccessType must be CREATABLE or UPDATABLE.');
        }

        Map<String, Object> coercedArguments = new Map<String, Object>();
        Map<String, Schema.SObjectField> allFields = SchemaUtils.getObjectFields(targetSObjectType);

        for (String fieldName : rawArguments.keySet()) {
            Schema.SObjectField fieldToken = allFields.get(fieldName.toLowerCase());
            if (fieldToken == null) {
                System.debug(
                    LoggingLevel.WARN,
                    '[SObjectArgumentCoercionService] Field "' +
                        fieldName +
                        '" not found on ' +
                        targetSObjectType.getDescribe().getName() +
                        '. Skipping coercion.'
                );
                continue;
            }

            Schema.DescribeFieldResult dfr = fieldToken.getDescribe();
            // Enforce field-level security before processing
            if (!SecurityUtils.hasFieldPermission(dfr, accessType)) {
                System.debug(
                    LoggingLevel.DEBUG,
                    '[SObjectArgumentCoercionService] Field "' + fieldName + '" skipped due to FLS (' + accessType + ').'
                );
                continue;
            }

            // Perform type coercion with comprehensive validation
            Object rawValue = rawArguments.get(fieldName);
            try {
                Object coercedValue = coerceValueForField(rawValue, fieldName, dfr);
                coercedArguments.put(dfr.getName(), coercedValue);
            } catch (InvalidArgumentTypeException e) {
                String errMsg = 'Failed coercing value for permitted field "' + fieldName + '". Error: ' + e.getMessage();
                System.debug(LoggingLevel.ERROR, '[SObjectArgumentCoercionService] ' + errMsg);
                throw new InvalidArgumentTypeException(errMsg, e);
            }
        }

        return coercedArguments;
    }

    /**
     * @description
     * Performs field-specific type coercion using the unified TypeCoercionService.
     * Handles all standard Salesforce field types with appropriate error handling.
     *
     * @param rawValue Input value to convert (from JSON/LLM)
     * @param fieldName Field API name for error context
     * @param dfr Field describe result containing type and constraint information
     * @return Object Properly typed value ready for SObject assignment
     * @throws InvalidArgumentTypeException For conversion failures or constraint violations
     */
    private static Object coerceValueForField(Object rawValue, String fieldName, Schema.DescribeFieldResult dfr) {
        if (rawValue == null)
            return null;

        Schema.DisplayType fieldType = dfr.getType();
        System.debug(
            LoggingLevel.FINEST,
            'SObjectArgumentCoercionService: Coercing Field: ' +
                fieldName +
                ', Type: ' +
                fieldType +
                ', Input Value: ' +
                String.valueOf(rawValue).abbreviate(50)
        );

        try {
            // Use the unified TypeCoercionService for all coercion
            return TypeCoercionService.coerce(rawValue, fieldType, fieldName, dfr);
        } catch (TypeCoercionService.TypeCoercionException e) {
            // Convert TypeCoercionService exceptions to our InvalidArgumentTypeException
            throw new InvalidArgumentTypeException(
                'Error coercing value for field "' + fieldName + '" to type ' + fieldType + ': ' + e.getMessage(),
                e
            );
        } catch (InvalidArgumentTypeException e) {
            throw e;
        } catch (Exception e) {
            throw new InvalidArgumentTypeException(
                'Unexpected error coercing value for field "' + fieldName + '" to type ' + fieldType + ': ' + e.getMessage(),
                e
            );
        }
    }

    public class InvalidArgumentTypeException extends AIAgentException {
    }
}
