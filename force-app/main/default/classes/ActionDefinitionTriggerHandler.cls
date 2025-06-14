/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Created by sonal on 2025-04-14.
 */

public with sharing class ActionDefinitionTriggerHandler {
    public static void handleTrigger(
        List<ActionDefinition__c> newRecords,
        List<ActionDefinition__c> oldRecords,
        System.TriggerOperation triggerOperation
    ) {
        switch on triggerOperation {
            when BEFORE_INSERT, BEFORE_UPDATE {
                validateRecords(newRecords);
            }
        }
    }

    private static void validateRecords(List<ActionDefinition__c> records) {
        for (ActionDefinition__c record : records) {
            validateJsonSyntax(record, record.InputParameterSchema__c, 'InputParameterSchema__c');
            validateJsonSyntax(record, record.ConfigurationSchema__c, 'ConfigurationSchema__c');
            validateImplementationDetails(record);
        }
    }

    /** Validates that a string is well-formed JSON */
    private static void validateJsonSyntax(ActionDefinition__c record, String jsonString, String fieldName) {
        if (String.isNotBlank(jsonString)) {
            try {
                Object parsed = JSON.deserializeUntyped(jsonString);

                if (!(parsed instanceof Map<String, Object>)) {
                    if (record.Id == null)
                        record.addError(fieldName, 'JSON content must be a valid JSON Object (e.g., {...}).');
                    else
                        Trigger.newMap.get(record.Id).addError(fieldName, 'JSON content must be a valid JSON Object (e.g., {...}).');
                }
            } catch (System.JSONException e) {
                if (record.Id == null)
                    record.addError(fieldName, 'Invalid JSON Syntax: ' + e.getMessage());
                else
                    Trigger.newMap.get(record.Id).addError(fieldName, 'Invalid JSON Syntax: ' + e.getMessage());
            } catch (Exception ex) {
                if (record.Id == null)
                    record.addError(fieldName, 'Unexpected error validating JSON: ' + ex.getMessage());
                else
                    Trigger.newMap.get(record.Id).addError(fieldName, 'Unexpected error validating JSON: ' + ex.getMessage());
            }
        }
    }

    /** Validates implementation fields based on type */
    private static void validateImplementationDetails(ActionDefinition__c record) {
        if (String.isBlank(record.ImplementationType__c)) {
            handleValidationError(record, 'ImplementationType__c', 'Implementation Type is required.');
            return;
        }

        if (record.ImplementationType__c == 'Apex') {
            if (String.isBlank(record.ImplementationName__c)) {
                handleValidationError(record, 'ImplementationName__c', 'Implementation Detail (Apex Class Name) is required when Type is Apex.');
            } else {
                try {
                    Type apexType = Type.forName(record.ImplementationName__c);
                    if (apexType == null) {
                        handleValidationError(record, 'ImplementationName__c', 'Apex class "' + record.ImplementationName__c + '" not found.');
                    } else {
                    }
                } catch (Exception e) {
                    handleValidationError(
                        record,
                        'ImplementationName__c',
                        'Error verifying Apex class "' + record.ImplementationName__c + '": ' + e.getMessage()
                    );
                }
            }
        } else if (record.ImplementationType__c == 'Flow') {
            if (String.isBlank(record.ImplementationName__c)) {
                handleValidationError(record, 'ImplementationName__c', 'Implementation Detail (Flow API Name) is required when Type is Flow.');
            }
        } else if (record.ImplementationType__c == 'Standard') {
            if (String.isBlank(record.StandardActionType__c)) {
                handleValidationError(record, 'StandardActionType__c', 'Standard Action Type is required when Type is Standard.');
            }
        }
    }

    private static void handleValidationError(ActionDefinition__c record, String fieldName, String errorMessage) {
        if (record.Id == null)
            record.addError(fieldName, errorMessage);
        else
            Trigger.newMap.get(record.Id).addError(fieldName, errorMessage);
    }
}
