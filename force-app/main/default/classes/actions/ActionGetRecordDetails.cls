/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Generic record retrieval action with flexible field selection and identifier lookups.
 * @ActionLabel Get Record Details
 * @ActionDescription Retrieves any Salesforce record by ID or unique identifier field
 * @ActionRequiresSObject true
 * @ActionIsActive true
 * @ActionHasVariants true
 * @ActionVariant field_list | Field List | Specify field API names directly in the backend configuration
 * @ActionVariant fieldset | FieldSet | Use a Salesforce FieldSet defined in Object Manager to control which fields are returned
 *
 * @extends BaseAgentAction
 */
public with sharing class ActionGetRecordDetails extends BaseAgentAction {
    private ConfigDTO config;

    /**
     * DTO for base parameters (used for metadata generation only)
     * Actual parameters are dynamically generated based on identifierFields configuration
     */
    public class ArgumentsDTO {
        /**
         * @FieldLabel Record ID
         * @FieldType salesforce-id
         * @FieldRequired false
         * @FieldPlaceholder 001000000000000AAA
         * @FieldHelp The 18-character Salesforce ID (most reliable, always unique).
         */
        public String Id;
    }

    /**
     * DTO for strongly-typed backend configuration (admin-configured)
     */
    public class ConfigDTO {
        /**
         * @FieldSystem true
         * @FieldLabel Variant
         * @FieldType string
         * @FieldHelp Field retrieval mode: "field_list" (explicit field array) or "fieldset" (Salesforce FieldSet). Managed by the variant picker UI.
         */
        public String variant;

        /**
         * @FieldLabel Object API Name
         * @FieldType string
         * @FieldRequired true
         * @FieldPlaceholder Case
         * @FieldHelp Required: The API name of the SObject type (e.g., Account, Case). Used for identifier field lookups and validation.
         */
        public String objectApiName;

        /**
         * @FieldLabel Default Fields
         * @FieldType array
         * @FieldVariant field_list
         * @FieldPlaceholder ["Id", "Name", "Status"]
         * @FieldHelp Array of field API names to retrieve (e.g., ["Id", "Name", "Status"]). Use this for quick configuration without creating a FieldSet.
         */
        public List<String> defaultFields;

        /**
         * @FieldLabel FieldSet Name
         * @FieldType string
         * @FieldVariant fieldset
         * @FieldDisplayType fieldset
         * @FieldPlaceholder AI_Agent_Details
         * @FieldHelp Developer name of the FieldSet to use for field selection (e.g., "AI_Agent_Details"). Create FieldSets in Setup > Object Manager > [Object] > Field Sets.
         */
        public String fieldSetName;
    }

    /**
     * @description
     * Main entry point: Retrieves a record by any configured identifier field.
     *
     * Steps:
     *   1. Parse parameters to find which identifier was provided
     *   2. Validate object API name is configured
     *   3. Build WHERE clause based on identifier field
     *   4. Get fields from FieldSet (or use defaults)
     *   5. Verify read permission on object
     *   6. Build and execute dynamic SOQL with FLS enforcement
     *   7. Return record data with metadata
     *
     * @param params Map<String, Object> - Contains ONE identifier field (Id, CaseNumber, etc.)
     * @return ActionOutcome with record data, object type, and optional URL
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Validate object API name is configured (required for identifier lookups)
        if (String.isBlank(config.objectApiName)) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Configuration error: "objectApiName" is required',
                'Provide the object API name in configuration (e.g., {"objectApiName": "Case"})'
            );
        }

        // Get SObjectType from configured object name
        SObjectType sObjectType = Schema.getGlobalDescribe().get(config.objectApiName);
        if (sObjectType == null) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, 'Invalid object API name: ' + config.objectApiName);
        }

        DescribeSObjectResult objDescribe = sObjectType.getDescribe();
        String objectApiName = objDescribe.getName();

        // Check object-level read permission
        if (!objDescribe.isAccessible()) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                'Access Denied: You do not have permission to read ' + objectApiName + ' records.',
                'Contact your Salesforce administrator to request read access to ' + objectApiName + ' records.'
            );
        }

        // Determine which identifier field was provided by looping through all parameters
        String identifierField = null;
        Object identifierValue = null;

        for (String paramKey : params.keySet()) {
            Object paramValue = params.get(paramKey);
            if (paramValue != null) {
                identifierField = paramKey;
                identifierValue = paramValue;
                break; // Use first non-null parameter
            }
        }

        if (identifierField == null) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Missing identifier parameter. No valid parameter provided.',
                'Provide one identifier field (e.g., {"Id": "001..."} or {"CaseNumber": "00001234"}). Check the Parameters schema for available options.'
            );
        }

        // Validate only one parameter was provided
        Integer paramCount = 0;
        for (Object paramValue : params.values()) {
            if (paramValue != null) {
                paramCount++;
            }
        }

        if (paramCount > 1) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Multiple identifier parameters provided. Expected exactly one.',
                'Provide only ONE identifier field. You provided ' + paramCount + ' fields.'
            );
        }

        System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] Using identifier: ' + identifierField + ' = ' + identifierValue);

        // Convert identifier value to string for SOQL binding
        String identifierValueStr = String.valueOf(identifierValue);

        // Guard: if no variant is set but both field-selection modes are configured, the intent is ambiguous
        Boolean hasDefaultFields = config.defaultFields != null && !config.defaultFields.isEmpty();
        Boolean hasFieldSetName = String.isNotBlank(config.fieldSetName);
        if (String.isBlank(config.variant) && hasDefaultFields && hasFieldSetName) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Ambiguous configuration: both "fieldSetName" and "defaultFields" are set without a variant.',
                'Set "variant" to "fieldset" to use the FieldSet, or to "field_list" to use the defaultFields array.'
            );
        }

        // Get fields from FieldSet or defaultFields based on configured variant
        Set<String> fieldsToQuery = new Set<String>{ 'Id' }; // Always include Id

        if ('fieldset'.equals(config.variant)) {
            if (String.isBlank(config.fieldSetName)) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'Configuration error: "fieldSetName" is required for the fieldset variant.',
                    'Provide a FieldSet developer name (e.g., "AI_Agent_Details") in the backend configuration.'
                );
            }
            List<String> fieldSetFields = getFieldsFromFieldSet(sObjectType, config.fieldSetName);
            if (fieldSetFields.isEmpty()) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'FieldSet "' + config.fieldSetName + '" not found on object ' + objectApiName,
                    'The configured FieldSet does not exist. Available FieldSets can be found in Setup > Object Manager > ' +
                        objectApiName +
                        ' > Field Sets. Create the FieldSet or update the configuration.'
                );
            }
            fieldsToQuery.addAll(fieldSetFields);
            System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] Using FieldSet: ' + config.fieldSetName + ', Fields: ' + fieldSetFields.size());
        } else {
            // field_list variant (default)
            if (config.defaultFields == null || config.defaultFields.isEmpty()) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                    'Configuration error: "defaultFields" is required for the field_list variant.',
                    'Provide an array of field API names (e.g., ["Id", "Name", "Status"]) in the backend configuration.'
                );
            }
            fieldsToQuery.addAll(config.defaultFields);
            System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] Using defaultFields: ' + config.defaultFields);
        }

        // Validate identifier field is a real, accessible field (prevents injection)
        if (identifierField.contains('.')) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid identifier field: ' + identifierField,
                'Identifier field must be a direct field on ' + objectApiName + ' (e.g., "Id", "CaseNumber").'
            );
        }

        SObjectField identifierToken = Utils.getFieldToken(sObjectType, identifierField);
        if (identifierToken == null) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Unknown identifier field "' + identifierField + '" for object ' + objectApiName,
                'Use a valid identifier field for ' + objectApiName + ' (e.g., "Id", "CaseNumber").'
            );
        }

        DescribeFieldResult identifierDescribe = identifierToken.getDescribe();
        if (!identifierDescribe.isAccessible()) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                'Access Denied: You do not have permission to read field ' + identifierDescribe.getName(),
                'Contact your Salesforce administrator to request read access to ' + identifierDescribe.getName() + '.'
            );
        }

        String identifierFieldApiName = identifierDescribe.getName();

        // Filter fields based on FLS
        List<String> accessibleFields = new List<String>();
        List<String> inaccessibleFields = new List<String>();
        Map<String, SObjectField> fieldMap = Utils.getObjectFields(sObjectType);

        for (String fieldName : fieldsToQuery) {
            // Handle relationship fields (e.g., Account.Name)
            if (fieldName.contains('.')) {
                // For now, include relationship fields as-is (SOQL will handle accessibility)
                accessibleFields.add(fieldName);
                continue;
            }

            SObjectField field = fieldMap.get(fieldName.toLowerCase());
            if (field == null) {
                System.debug(LoggingLevel.WARN, '[ActionGetRecordDetails] Field not found: ' + fieldName + ' on ' + objectApiName);
                continue;
            }

            DescribeFieldResult fieldDescribe = field.getDescribe();
            if (fieldDescribe.isAccessible()) {
                accessibleFields.add(fieldDescribe.getName()); // Use API name from describe
            } else {
                inaccessibleFields.add(fieldName);
            }
        }

        if (accessibleFields.isEmpty()) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                'No accessible fields found for ' + objectApiName + '. Cannot retrieve record data.'
            );
        }

        if (!inaccessibleFields.isEmpty()) {
            System.debug(LoggingLevel.WARN, '[ActionGetRecordDetails] Fields removed due to FLS: ' + inaccessibleFields);
        }

        // Build and execute dynamic SOQL
        String soql =
            'SELECT ' +
            String.join(accessibleFields, ', ') +
            ' FROM ' +
            objectApiName +
            ' WHERE ' +
            identifierFieldApiName +
            ' = :identifierValueStr' +
            ' LIMIT 10'; // Get up to 10 in case of non-unique fields

        System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] Executing SOQL: ' + soql);

        try {
            List<SObject> results = Database.queryWithBinds(soql, new Map<String, Object>{ 'identifierValueStr' => identifierValueStr }, AccessLevel.USER_MODE);

            if (results.isEmpty()) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND,
                    'Record not found with ' + identifierField + ' = ' + identifierValueStr,
                    'No record exists with the provided identifier. Verify the value is correct.'
                );
            }

            // Warn if multiple matches found
            if (results.size() > 1) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ActionGetRecordDetails] Multiple records found (' +
                        results.size() +
                        ') for ' +
                        identifierField +
                        ' = ' +
                        identifierValueStr +
                        '. Returning first match.'
                );
            }

            SObject record = results[0];

            // Apply stripInaccessible as defense-in-depth
            SObjectAccessDecision decision = Security.stripInaccessible(AccessType.READABLE, new List<SObject>{ record });
            SObject sanitizedRecord = decision.getRecords()[0];

            // Build response
            Map<String, Object> recordData = sanitizedRecord.getPopulatedFieldsAsMap();

            Map<String, Object> response = new Map<String, Object>{
                'record' => recordData,
                'objectType' => objectApiName,
                'recordId' => String.valueOf(record.Id),
                'matchedBy' => identifierFieldApiName
            };

            // Include warnings
            if (results.size() > 1) {
                response.put('multipleMatchesWarning', 'Multiple records matched. Returned first of ' + results.size() + ' matches.');
            }

            if (!decision.getRemovedFields().isEmpty()) {
                System.debug(LoggingLevel.WARN, '[ActionGetRecordDetails] Security.stripInaccessible removed fields: ' + decision.getRemovedFields());
                response.put('fieldAccessWarning', 'Some fields were removed due to field-level security. Fields: ' + decision.getRemovedFields());
            }

            Long duration = System.currentTimeMillis() - startTime;
            System.debug(
                LoggingLevel.INFO,
                '[ActionGetRecordDetails] Success. Record retrieved in ' + duration + 'ms via ' + identifierField + '. Fields: ' + accessibleFields.size()
            );

            return ActionOutcome.success(response);
        } catch (QueryException qe) {
            return ActionOutcome.fromException(qe);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionGetRecordDetails] Unexpected error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return ActionOutcome.fromException(e);
        }
    }

    /**
     * @description
     * Retrieves field API names from a FieldSet.
     *
     * @param sObjectType The SObjectType to get the FieldSet from
     * @param fieldSetName The developer name of the FieldSet
     * @return List of field API names, or empty list if FieldSet not found
     */
    private List<String> getFieldsFromFieldSet(SObjectType sObjectType, String fieldSetName) {
        List<String> fields = new List<String>();

        try {
            DescribeSObjectResult objDescribe = sObjectType.getDescribe();
            Map<String, Schema.FieldSet> fieldSetMap = objDescribe.fieldSets.getMap();

            Schema.FieldSet fieldSet = fieldSetMap.get(fieldSetName);
            if (fieldSet == null) {
                System.debug(LoggingLevel.WARN, '[ActionGetRecordDetails] FieldSet not found: ' + fieldSetName + ' on ' + objDescribe.getName());
                return fields;
            }

            for (Schema.FieldSetMember member : fieldSet.getFields()) {
                fields.add(member.getFieldPath()); // Use getFieldPath() to support relationship fields
            }

            System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] FieldSet "' + fieldSetName + '" contains ' + fields.size() + ' fields');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionGetRecordDetails] Error reading FieldSet: ' + e.getMessage());
        }

        return fields;
    }

    /**
     * @description
     * Parses and validates action configuration from JSON.
     * Called by BaseAgentAction.execute() before executeAction().
     *
     * @param actionConfigurationJson JSON configuration string
     * @param logPrefix Prefix for debug logging
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        // Initialize config with defaults
        this.config = new ConfigDTO();

        if (String.isNotBlank(actionConfigurationJson)) {
            try {
                Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

                this.config.variant = ActionConfigUtils.getOptionalString(configMap, 'variant');
                this.config.objectApiName = ActionConfigUtils.getOptionalString(configMap, 'objectApiName');
                this.config.fieldSetName = ActionConfigUtils.getOptionalString(configMap, 'fieldSetName');
                this.config.defaultFields = ActionConfigUtils.getOptionalStringList(configMap, 'defaultFields');

                System.debug(
                    LoggingLevel.DEBUG,
                    '[ActionGetRecordDetails] Configuration parsed. Variant: ' +
                        config.variant +
                        ', FieldSet: ' +
                        config.fieldSetName +
                        ', DefaultFields: ' +
                        config.defaultFields +
                        ', ObjectApiName: ' +
                        config.objectApiName
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ActionGetRecordDetails] Failed to parse configuration JSON: ' + e.getMessage() + '. Using defaults.');
            }
        }
    }
}
