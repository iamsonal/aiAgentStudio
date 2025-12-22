/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionGetRecordDetails: Generic record retrieval action with flexible field selection and identifier lookups.
 *
 * This action provides two ways to configure field selection:
 * 1. **FieldSets** (Declarative) - Admin-friendly, reusable across capabilities
 * 2. **defaultFields** (JSON Array) - Quick configuration without creating FieldSets
 *
 * Identifier Lookup:
 *   AI can provide ANY field defined in the Parameters schema:
 *   - Id: Direct record lookup (fastest, most reliable)
 *   - CaseNumber: Find case by case number
 *   - ContactEmail: Find contact by email
 *   - Any field you define in ArgumentsDTO
 *
 * Parameter Format:
 *   {"Id": "001XXXXXXXXXXXX"}           // Direct ID lookup
 *   {"CaseNumber": "00001234"}          // Case number lookup
 *   {"ContactEmail": "john@example.com"} // Email lookup
 *
 * Configuration Schema:
 *   {
 *     "objectApiName": "Case",                              // Required: Object type
 *     "defaultFields": ["Id", "CaseNumber", "Subject"]      // Fields to return
 *   }
 *
 * Adding New Identifier Fields:
 *   1. Add field to ArgumentsDTO with proper annotations
 *   2. Run generate-action-metadata.js script
 *   3. Deploy metadata - AI will see the new parameter option
 *
 * Security Architecture:
 *   - Respects object-level read permissions
 *   - Enforces field-level security on all fields
 *   - Uses Security.stripInaccessible() to filter inaccessible fields
 *   - Returns clear error messages for permission issues
 *
 * @ActionLabel Get Record Details
 * @ActionDescription Retrieves any Salesforce record by ID or unique identifier field
 * @ActionRequiresSObject true
 * @ActionIsActive true
 * @ActionGuidance
 * <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif; line-height: 1.6;"><div style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 16px; border-radius: 8px 8px 0 0; margin: -8px -8px 16px -8px;"><h2 style="margin: 0; font-size: 18px; font-weight: 600;">🔍 Get Record Details</h2><p style="margin: 4px 0 0 0; font-size: 13px; opacity: 0.95;">Generic record retrieval with flexible field selection and smart identifier lookups</p></div><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">⚙️ Configuration</h3><div style="background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin: 12px 0;"><table style="width: 100%; font-size: 13px;"><tr><td style="padding: 8px; border-bottom: 1px solid #e9ecef; width: 30%;"><strong style="color: #495057;">objectApiName</strong><br/><span style="font-size: 11px; color: #dc3545;">Required</span></td><td style="padding: 8px; border-bottom: 1px solid #e9ecef; color: #6c757d;">The API name of the object type (e.g., "Case", "Account"). This is required for identifier field lookups.</td></tr><tr><td style="padding: 8px; border-bottom: 1px solid #e9ecef;"><strong style="color: #495057;">defaultFields</strong></td><td style="padding: 8px; border-bottom: 1px solid #e9ecef; color: #6c757d;">Array of field API names to retrieve (e.g., ["Id", "Name", "Status"]).<br/><code style="background: #f1f3f5; padding: 2px 6px; border-radius: 3px; font-size: 11px;">["Id", "CaseNumber", "Subject", "Status"]</code></td></tr></table></div><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">📋 Runtime Parameters</h3><p style="margin: 8px 0; font-size: 13px; color: #6c757d;">AI provides ONE parameter from the Parameters schema:</p><div style="background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin: 12px 0;"><code style="background: #f1f3f5; padding: 8px; display: block; border-radius: 3px; font-size: 12px;">{"Id": "001XXXXXXXXXXXX"}</code><code style="background: #f1f3f5; padding: 8px; display: block; border-radius: 3px; font-size: 12px; margin-top: 8px;">{"CaseNumber": "00001234"}</code></div><div style="background: #d1ecf1; border-left: 4px solid #17a2b8; padding: 12px; margin: 12px 0; border-radius: 4px;"><p style="margin: 0; font-size: 13px; color: #0c5460;"><strong>💡 Adding Identifier Fields:</strong> Add fields to ArgumentsDTO with annotations, run generate-action-metadata.js, and deploy. The AI will automatically see new lookup options!</p></div><div style="background: #fff3cd; border-left: 4px solid #ffc107; padding: 12px; margin: 12px 0; border-radius: 4px;"><p style="margin: 0; font-size: 13px; color: #856404;"><strong>💡 Best Practice:</strong> Use <strong>Id</strong> when available (fastest). Use other identifiers when the user provides human-readable values like case numbers or email addresses.</p></div><div style="background: #e7f1ff; border-left: 4px solid #0066cc; padding: 12px; margin: 12px 0; border-radius: 4px;"><p style="margin: 0; font-size: 13px; color: #004085;"><strong>🔒 Security:</strong> Respects object-level and field-level security. Fields the running user cannot access will be automatically filtered out. The AI receives only data the user has permission to view.</p></div></div>
 *
 * @extends BaseAgentAction
 */
public class ActionGetRecordDetails extends BaseAgentAction {
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
         * @FieldLabel FieldSet Name
         * @FieldType string
         * @FieldDisplayType fieldset
         * @FieldPlaceholder AI_Agent_Details
         * @FieldHelp Name of the FieldSet to use for field selection (e.g., "AI_Agent_Details"). Mutually exclusive with defaultFields. Create FieldSets in Setup > Object Manager > [Object] > Field Sets.
         */
        public String fieldSetName;

        /**
         * @FieldLabel Default Fields
         * @FieldType array
         * @FieldPlaceholder ["Id", "Name", "Status"]
         * @FieldHelp Array of field API names to retrieve (e.g., ["Id", "Name", "Status"]). Mutually exclusive with fieldSetName. Use this for quick configuration without creating a FieldSet.
         */
        public List<String> defaultFields;

        /**
         * @FieldLabel Object API Name
         * @FieldType string
         * @FieldRequired true
         * @FieldPlaceholder Case
         * @FieldHelp Required: The API name of the SObject type (e.g., Account, Case). Used for identifier field lookups and validation.
         */
        public String objectApiName;
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
            return ActionOutcome.failureWithGuidance(
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
            return ActionOutcome.failureWithGuidance(
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
            return ActionOutcome.failureWithGuidance(
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
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Multiple identifier parameters provided. Expected exactly one.',
                'Provide only ONE identifier field. You provided ' + paramCount + ' fields.'
            );
        }

        System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] Using identifier: ' + identifierField + ' = ' + identifierValue);

        // Convert identifier value to string for SOQL binding
        String identifierValueStr = String.valueOf(identifierValue);

        // Validate configuration: either fieldSetName OR defaultFields must be provided
        Boolean hasFieldSet = String.isNotBlank(config.fieldSetName);
        Boolean hasDefaultFields = config.defaultFields != null && !config.defaultFields.isEmpty();

        if (!hasFieldSet && !hasDefaultFields) {
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Configuration error: Either "fieldSetName" or "defaultFields" must be provided.',
                'Provide a FieldSet name (e.g., {"fieldSetName": "AI_Agent_Details"}) OR an array of field API names (e.g., {"defaultFields": ["Id", "Name", "Status"]}).'
            );
        }

        if (hasFieldSet && hasDefaultFields) {
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Configuration error: Both "fieldSetName" and "defaultFields" are provided. Use only one.',
                'Choose either a FieldSet (fieldSetName) OR a field list (defaultFields), not both.'
            );
        }

        // Get fields from FieldSet or defaultFields
        Set<String> fieldsToQuery = new Set<String>{ 'Id' }; // Always include Id

        if (!String.isBlank(config.fieldSetName)) {
            // Use FieldSet
            List<String> fieldSetFields = getFieldsFromFieldSet(sObjectType, config.fieldSetName);
            if (fieldSetFields.isEmpty()) {
                return ActionOutcome.failureWithGuidance(
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
            // Use defaultFields
            fieldsToQuery.addAll(config.defaultFields);
            System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] Using defaultFields: ' + config.defaultFields);
        }

        // Filter fields based on FLS
        List<String> accessibleFields = new List<String>();
        List<String> inaccessibleFields = new List<String>();
        Map<String, SObjectField> fieldMap = objDescribe.fields.getMap();

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
            identifierField +
            ' = :identifierValueStr' +
            ' LIMIT 10'; // Get up to 10 in case of non-unique fields

        System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] Executing SOQL: ' + soql);

        try {
            List<SObject> results = Database.query(soql);

            if (results.isEmpty()) {
                return ActionOutcome.failureWithGuidance(
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
                'matchedBy' => identifierField
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
                '[ActionGetRecordDetails] Success. Record retrieved in ' +
                    duration +
                    'ms via ' +
                    identifierField +
                    '. Fields: ' +
                    accessibleFields.size()
            );

            return ActionOutcome.success(response);
        } catch (QueryException qe) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Query failed: ' + qe.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionGetRecordDetails] Unexpected error: ' + e.getMessage() + '\n' + e.getStackTraceString());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Failed to retrieve record: ' + e.getMessage());
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
                // Deserialize as untyped map to handle optional fields
                Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

                // Extract fieldSetName if provided
                if (configMap.containsKey('fieldSetName')) {
                    this.config.fieldSetName = (String) configMap.get('fieldSetName');
                }

                // Extract defaultFields if provided
                if (configMap.containsKey('defaultFields')) {
                    Object defaultFieldsObj = configMap.get('defaultFields');
                    if (defaultFieldsObj instanceof List<Object>) {
                        this.config.defaultFields = new List<String>();
                        for (Object item : (List<Object>) defaultFieldsObj) {
                            this.config.defaultFields.add(String.valueOf(item));
                        }
                    }
                }

                // Extract objectApiName if provided
                if (configMap.containsKey('objectApiName')) {
                    this.config.objectApiName = (String) configMap.get('objectApiName');
                }

                System.debug(
                    LoggingLevel.DEBUG,
                    '[ActionGetRecordDetails] Configuration parsed. FieldSet: ' +
                        config.fieldSetName +
                        ', DefaultFields: ' +
                        config.defaultFields +
                        ', ObjectApiName: ' +
                        config.objectApiName
                );
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ActionGetRecordDetails] Failed to parse configuration JSON: ' + e.getMessage() + '. Using defaults.'
                );
            }
        }
    }
}
