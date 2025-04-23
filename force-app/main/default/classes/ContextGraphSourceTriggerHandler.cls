/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * Trigger Handler for ContextGraphSource__c validations.
 * Performs deep validation on save to ensure configuration quality.
 * Validates JSON syntax, structure, and referenced schema elements.
 */
public with sharing class ContextGraphSourceTriggerHandler {
    private static Map<String, SObjectType> sObjectTypeCache = new Map<String, SObjectType>();

    private static Map<String, Map<String, SObjectField>> fieldDescribeCache = new Map<String, Map<String, SObjectField>>();

    private static final String IMPL_DECLARATIVE = 'Declarative';
    private static final String IMPL_APEX = 'Apex';
    private static final String LINK_DIRECT = 'Direct';
    private static final String LINK_PARENT = 'Parent Lookup';
    private static final String LINK_CHILD = 'Child Relationship';
    private static final String ANCHOR_RECORD = 'Record Anchored';
    private static final Set<String> ALLOWED_FILTER_OPERATORS = new Set<String>{
        '=',
        '!=',
        '<',
        '>',
        '<=',
        '>=',
        'IN',
        'NOT IN',
        'LIKE'
    };

    public static void handleTrigger(
        List<ContextGraphSource__c> newRecords,
        List<ContextGraphSource__c> oldRecords,
        System.TriggerOperation triggerOperation
    ) {
        switch on triggerOperation {
            when BEFORE_INSERT, BEFORE_UPDATE {
                validateRecords(newRecords);
            }
        }
    }

    private static void validateRecords(List<ContextGraphSource__c> records) {
        validateRequiredFieldsAndTypes(records);
        validateLinkLogicAndDetails(records);
        validateJsonFieldsSyntaxAndStructure(records);
        validateDeveloperNameUniqueness(records);
    }

    /** Validates Required Fields and Basic SObject/FieldSet Type references */
    private static void validateRequiredFieldsAndTypes(List<ContextGraphSource__c> records) {
        for (ContextGraphSource__c record : records) {
            SObjectType targetSObjectType = null;
            SObjectType startSObjectType = null;

            if (String.isBlank(record.SourceDeveloperName__c)) {
                addError(record, 'SourceDeveloperName__c', 'Source Developer Name is required.');
            }
            if (String.isBlank(record.SourceType__c)) {
                addError(record, 'SourceType__c', 'Source Type is required.');
            }
            if (String.isBlank(record.ImplementationType__c)) {
                record.ImplementationType__c = IMPL_DECLARATIVE;
            }

            if (isDeclarative(record)) {
                if (String.isBlank(record.TargetSObjectApiName__c)) {
                    addError(
                        record,
                        'TargetSObjectApiName__c',
                        'Target SObject API Name is required for Declarative implementation.'
                    );
                } else {
                    targetSObjectType = ContextUtils.getSObjectType(record.TargetSObjectApiName__c);
                    if (targetSObjectType == null) {
                        addError(
                            record,
                            'TargetSObjectApiName__c',
                            'Target SObject "' + record.TargetSObjectApiName__c + '" is invalid or inaccessible.'
                        );
                    } else {
                        if (!targetSObjectType.getDescribe().isQueryable()) {
                            addError(
                                record,
                                'TargetSObjectApiName__c',
                                'Target SObject "' + record.TargetSObjectApiName__c + '" is not queryable.'
                            );
                        } else if (!ContextUtils.isFieldAccessible(targetSObjectType, 'Id')) {
                            addError(
                                record,
                                'TargetSObjectApiName__c',
                                'Target SObject "' + record.TargetSObjectApiName__c + '" Id field is not accessible.'
                            );
                        } else {
                            if (String.isBlank(record.TargetFieldSetName__c)) {
                                addError(
                                    record,
                                    'TargetFieldSetName__c',
                                    'Target Field Set Name is required for Declarative implementation.'
                                );
                            } else {
                                List<String> fieldPaths = FrameworkUtils.getFieldsFromFieldSet(
                                    targetSObjectType,
                                    record.TargetFieldSetName__c
                                );
                                if (fieldPaths == null) {
                                    addError(
                                        record,
                                        'TargetFieldSetName__c',
                                        'Field Set "' +
                                            record.TargetFieldSetName__c +
                                            '" not found on SObject "' +
                                            record.TargetSObjectApiName__c +
                                            '".'
                                    );
                                } else {
                                    validateFieldsInFieldSet(
                                        record,
                                        targetSObjectType,
                                        fieldPaths,
                                        record.TargetFieldSetName__c
                                    );
                                }
                            }
                        }
                    }
                }

                if (record.SourceType__c == ANCHOR_RECORD) {
                    if (String.isBlank(record.StartingSObjectApiName__c)) {
                        addError(
                            record,
                            'StartingSObjectApiName__c',
                            'Starting SObject API Name is required for Declarative, RecordAnchored sources.'
                        );
                    } else {
                        startSObjectType = ContextUtils.getSObjectType(record.StartingSObjectApiName__c);
                        if (startSObjectType == null) {
                            addError(
                                record,
                                'StartingSObjectApiName__c',
                                'Starting SObject "' +
                                    record.StartingSObjectApiName__c +
                                    '" is invalid or inaccessible.'
                            );
                        } else if (!startSObjectType.getDescribe().isQueryable()) {
                            addError(
                                record,
                                'StartingSObjectApiName__c',
                                'Starting SObject "' + record.StartingSObjectApiName__c + '" is not queryable.'
                            );
                        } else if (!ContextUtils.isFieldAccessible(startSObjectType, 'Id')) {
                            addError(
                                record,
                                'StartingSObjectApiName__c',
                                'Starting SObject "' +
                                    record.StartingSObjectApiName__c +
                                    '" Id field is not accessible.'
                            );
                        }
                    }
                }
            } else if (isApex(record)) {
                if (String.isBlank(record.ProviderClassName__c)) {
                    addError(
                        record,
                        'ProviderClassName__c',
                        'Provider Class Name is required for Apex implementation.'
                    );
                } else {
                    validateProviderClass(record, record.ProviderClassName__c);
                }
            } else {
                addError(
                    record,
                    'ImplementationType__c',
                    'Unsupported Implementation Type: ' + record.ImplementationType__c
                );
            }
        }
    }

    /** Validates fields within a field set for existence and basic accessibility */
    private static void validateFieldsInFieldSet(
        ContextGraphSource__c record,
        SObjectType baseObjType,
        List<String> fieldPaths,
        String fieldSetName
    ) {
        if (fieldPaths.isEmpty())
            return;

        for (String fieldPath : fieldPaths) {
            if (String.isBlank(fieldPath)) {
                addError(
                    record,
                    'TargetFieldSetName__c',
                    'FieldSet "' + fieldSetName + '" contains a blank field path.'
                );
                continue;
            }
            List<String> parts = fieldPath.split('\\.');
            if (parts.size() == 1) {
                if (!ContextUtils.isFieldAccessible(baseObjType, parts[0])) {
                    addError(
                        record,
                        'TargetFieldSetName__c',
                        'FieldSet "' +
                            fieldSetName +
                            '": Field "' +
                            parts[0] +
                            '" is not accessible on ' +
                            baseObjType.getDescribe().getName() +
                            '.'
                    );
                }
            } else if (parts.size() == 2) {
                Map<String, Object> validation = ContextUtils.validateRelationshipField(
                    baseObjType,
                    parts[0],
                    parts[1],
                    'accessible'
                );
                if (!(Boolean) validation.get('isValid')) {
                    addError(
                        record,
                        'TargetFieldSetName__c',
                        'FieldSet "' + fieldSetName + '": ' + (String) validation.get('errorMessage')
                    );
                }
            } else if (parts.size() > 2) {
            } else {
                addError(
                    record,
                    'TargetFieldSetName__c',
                    'FieldSet "' + fieldSetName + '" contains malformed field path: ' + fieldPath
                );
            }
        }
    }

    /** Validates Link Type/Detail AND checks existence/access of Field/Relationship */
    private static void validateLinkLogicAndDetails(List<ContextGraphSource__c> records) {
        for (ContextGraphSource__c record : records) {
            if (
                !isDeclarative(record) ||
                record.SourceType__c != ANCHOR_RECORD ||
                String.isBlank(record.StartingSObjectApiName__c)
            ) {
                continue;
            }

            String linkType = String.isNotBlank(record.LinkType__c) ? record.LinkType__c : LINK_DIRECT;
            String linkDetail = record.LinkDetailApiName__c;
            SObjectType startSObjectType = ContextUtils.getSObjectType(record.StartingSObjectApiName__c);
            if (startSObjectType == null)
                continue;

            if (linkType == LINK_DIRECT && String.isNotBlank(linkDetail)) {
                addError(record, 'LinkDetailApiName__c', 'Link Detail should be blank when Link Type is Direct.');
            } else if ((linkType == LINK_PARENT || linkType == LINK_CHILD) && String.isBlank(linkDetail)) {
                addError(
                    record,
                    'LinkDetailApiName__c',
                    'Link Detail API Name is required when Link Type is ' + linkType + '.'
                );
            } else if (linkType == LINK_PARENT && String.isNotBlank(linkDetail)) {
                SObjectField lookupField = ContextUtils.getFieldToken(startSObjectType, linkDetail);
                if (lookupField == null) {
                    addError(
                        record,
                        'LinkDetailApiName__c',
                        'Parent Lookup field "' +
                            linkDetail +
                            '" not found on ' +
                            record.StartingSObjectApiName__c +
                            '.'
                    );
                } else if (lookupField.getDescribe().getType() != DisplayType.REFERENCE) {
                    addError(
                        record,
                        'LinkDetailApiName__c',
                        'Link Detail field "' +
                            linkDetail +
                            '" on ' +
                            record.StartingSObjectApiName__c +
                            ' is not a Reference (Lookup/Master-Detail) field.'
                    );
                } else if (!lookupField.getDescribe().isAccessible()) {
                    addError(
                        record,
                        'LinkDetailApiName__c',
                        'Parent Lookup field "' +
                            linkDetail +
                            '" on ' +
                            record.StartingSObjectApiName__c +
                            ' is not accessible.'
                    );
                }
            } else if (linkType == LINK_CHILD && String.isNotBlank(linkDetail)) {
                SObjectType targetSObjectType = ContextUtils.getSObjectType(record.TargetSObjectApiName__c);
                if (targetSObjectType == null) {
                    continue;
                }
                validateChildRelationshipExists(record, startSObjectType, targetSObjectType, linkDetail);
            }
        }
    }

    /** Validates JSON Syntax for specified fields AND Structure/Schema using Utils */
    private static void validateJsonFieldsSyntaxAndStructure(List<ContextGraphSource__c> records) {
        for (ContextGraphSource__c record : records) {
            if (isDeclarative(record)) {
                SObjectType targetType = ContextUtils.getSObjectType(record.TargetSObjectApiName__c);
                if (targetType != null && targetType.getDescribe().isQueryable()) {
                    if (String.isNotBlank(record.FilterBy__c)) {
                        ContextUtils.ContextParseResult filterResult = ContextUtils.parseAndValidateFilterBy(
                            record.FilterBy__c,
                            targetType
                        );
                        if (!filterResult.isValid) {
                            for (String errMsg : filterResult.errorMessages) {
                                addError(record, 'FilterBy__c', errMsg);
                            }
                        }
                    }

                    if (String.isNotBlank(record.OrderBy__c)) {
                        ContextUtils.ContextParseResult orderResult = ContextUtils.parseAndValidateOrderBy(
                            record.OrderBy__c,
                            targetType
                        );
                        if (!orderResult.isValid) {
                            for (String errMsg : orderResult.errorMessages) {
                                addError(record, 'OrderBy__c', errMsg);
                            }
                        }
                    }
                } else if (
                    record.TargetSObjectApiName__c != null &&
                    (String.isNotBlank(record.FilterBy__c) || String.isNotBlank(record.OrderBy__c))
                ) {
                    validateSingleJsonSyntax(record, record.FilterBy__c, 'FilterBy__c', 'Array or Map');
                    validateSingleJsonSyntax(record, record.OrderBy__c, 'OrderBy__c', 'Array');
                }
            } else if (isApex(record)) {
                validateSingleJsonSyntax(record, record.ProviderConfiguration__c, 'ProviderConfiguration__c', 'Any');
            }
        }
    }

    /** Checks existence and validity of the specified provider class */
    private static void validateProviderClass(ContextGraphSource__c record, String className) {
        if (String.isBlank(className))
            return;
        try {
            Type providerType = Type.forName(className);
            if (providerType == null) {
                addError(record, 'ProviderClassName__c', 'Apex Provider Class "' + className + '" not found.');
                return;
            }
            Object instance = providerType.newInstance();

            if (!(instance instanceof IAgentContextProvider)) {
                addError(
                    record,
                    'ProviderClassName__c',
                    'Apex Provider Class "' + className + '" does not implement IAgentContextProvider.'
                );
            }
        } catch (Exception e) {
            addError(
                record,
                'ProviderClassName__c',
                'Error verifying Apex Provider Class "' + className + '": ' + e.getMessage()
            );
        }
    }

    /** Validates Child Relationship Existence and Accessibility using ContextUtils */
    private static void validateChildRelationshipExists(
        ContextGraphSource__c record,
        SObjectType startSObjType,
        SObjectType targetSObjectType,
        String relationshipName
    ) {
        if (startSObjType == null || targetSObjectType == null || String.isBlank(relationshipName))
            return;

        Boolean found = false;
        SObjectField fkField = null;
        try {
            for (Schema.ChildRelationship cr : startSObjType.getDescribe().getChildRelationships()) {
                if (
                    cr.getChildSObject() == targetSObjectType &&
                    relationshipName.equalsIgnoreCase(cr.getRelationshipName())
                ) {
                    found = true;
                    fkField = cr.getField();
                    break;
                }
            }
        } catch (Exception e) {
            addError(
                record,
                'LinkDetailApiName__c',
                'Error describing child relationships for "' +
                    startSObjType.getDescribe().getName() +
                    '": ' +
                    e.getMessage()
            );
            return;
        }

        if (!found) {
            addError(
                record,
                'LinkDetailApiName__c',
                'Child Relationship Name "' +
                    relationshipName +
                    '" not found between parent "' +
                    startSObjType.getDescribe().getName() +
                    '" and child "' +
                    targetSObjectType.getDescribe().getName() +
                    '".'
            );
        } else if (fkField == null) {
            addError(
                record,
                'LinkDetailApiName__c',
                'Could not identify foreign key field for relationship "' + relationshipName + '".'
            );
        } else if (!ContextUtils.isFieldAccessible(targetSObjectType, fkField.getDescribe().getName())) {
            addError(
                record,
                'LinkDetailApiName__c',
                'Relationship "' +
                    relationshipName +
                    '" exists, but its foreign key field "' +
                    fkField.getDescribe().getName() +
                    '" on ' +
                    targetSObjectType.getDescribe().getName() +
                    ' is not accessible.'
            );
        }
    }

    /** Checks SourceDeveloperName uniqueness (Unchanged) */
    private static void validateDeveloperNameUniqueness(List<ContextGraphSource__c> recordsToCheck) {
        Set<String> devNames = new Set<String>();
        for (ContextGraphSource__c rec : recordsToCheck) {
            if (String.isNotBlank(rec.SourceDeveloperName__c))
                devNames.add(rec.SourceDeveloperName__c.toLowerCase());
        }
        if (recordsToCheck.isEmpty() || devNames.isEmpty())
            return;

        Map<String, Id> existingNamesMap = new Map<String, Id>();
        try {
            for (ContextGraphSource__c existing : [
                SELECT Id, SourceDeveloperName__c
                FROM ContextGraphSource__c
                WHERE SourceDeveloperName__c IN :devNames
            ]) {
                if (String.isNotBlank(existing.SourceDeveloperName__c)) {
                    existingNamesMap.put(existing.SourceDeveloperName__c.toLowerCase(), existing.Id);
                }
            }
        } catch (Exception e) {
            return;
        }

        Set<String> processedKeysInTrigger = new Set<String>();
        for (ContextGraphSource__c record : recordsToCheck) {
            if (String.isBlank(record.SourceDeveloperName__c))
                continue;
            String currentKey = record.SourceDeveloperName__c.toLowerCase();
            if (existingNamesMap.containsKey(currentKey) && existingNamesMap.get(currentKey) != record.Id) {
                addError(
                    record,
                    'SourceDeveloperName__c',
                    'Source Developer Name "' +
                        record.SourceDeveloperName__c +
                        '" is already used by record ' +
                        existingNamesMap.get(currentKey) +
                        '.'
                );
            }
            if (processedKeysInTrigger.contains(currentKey)) {
                addError(
                    record,
                    'SourceDeveloperName__c',
                    'Source Developer Name "' +
                        record.SourceDeveloperName__c +
                        '" is duplicated within the records being saved.'
                );
            }
            processedKeysInTrigger.add(currentKey);
        }
    }

    /** (Modified) Validates basic JSON syntax & Type - Does NOT use ContextUtils */
    private static Object validateSingleJsonSyntax(
        ContextGraphSource__c record,
        String jsonString,
        String fieldName,
        String expectedType
    ) {
        Object parsedJson = null;
        if (String.isNotBlank(jsonString)) {
            try {
                parsedJson = JSON.deserializeUntyped(jsonString);
                Boolean typeMatch = false;
                String actualTypeName = getJsonTypeName(parsedJson);

                switch on expectedType {
                    when 'Array' {
                        typeMatch = (actualTypeName == 'List');
                    }
                    when 'Map' {
                        typeMatch = (actualTypeName == 'Map');
                    }
                    when 'Array or Map' {
                        typeMatch = (actualTypeName == 'List' || actualTypeName == 'Map');
                    }
                    when 'Any' {
                        typeMatch = (actualTypeName != 'Unknown Type');
                    }
                }

                if (!typeMatch) {
                    addError(
                        record,
                        fieldName,
                        'JSON content is valid but not the expected type (' +
                            expectedType +
                            '). Found type: ' +
                            actualTypeName +
                            '.'
                    );
                    return null;
                }
            } catch (System.JSONException e) {
                addError(record, fieldName, 'Invalid JSON Syntax: ' + e.getMessage());
                return null;
            } catch (Exception ex) {
                addError(record, fieldName, 'Unexpected error validating JSON syntax/type: ' + ex.getMessage());

                return null;
            }
        }

        return parsedJson;
    }

    private static String getJsonTypeName(Object parsed) {
        if (parsed instanceof List<Object>)
            return 'List';
        if (parsed instanceof Map<String, Object>)
            return 'Map';
        if (parsed instanceof String)
            return 'String';
        if (parsed instanceof Boolean)
            return 'Boolean';
        if (
            parsed instanceof Integer ||
            parsed instanceof Double ||
            parsed instanceof Long ||
            parsed instanceof Decimal
        )
            return 'Number';
        if (parsed == null)
            return 'Null';
        return 'Unknown Type';
    }
    private static Boolean isDeclarative(ContextGraphSource__c record) {
        return String.isBlank(record.ImplementationType__c) || record.ImplementationType__c == IMPL_DECLARATIVE;
    }

    private static Boolean isApex(ContextGraphSource__c record) {
        return record.ImplementationType__c == IMPL_APEX;
    }

    private static void addError(ContextGraphSource__c record, String fieldName, String errorMessage) {
        SObject recordInTrigger = (record.Id == null ||
            !Trigger.isExecuting ||
            Trigger.newMap == null ||
            !Trigger.newMap.containsKey(record.Id))
            ? record
            : Trigger.newMap.get(record.Id);
        if (recordInTrigger != null) {
            try {
                recordInTrigger.addError(
                    Schema.SObjectType.ContextGraphSource__c.fields.getMap().get(fieldName.toLowerCase()),
                    errorMessage,
                    false
                );
            } catch (Exception e) {
                recordInTrigger.addError(errorMessage, false);
            }
        } else {
            record.addError(fieldName, errorMessage);
        }
    }
}
