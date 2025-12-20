/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionGetRecordDetails: Generic record retrieval action with flexible field selection.
 *
 * This action provides two ways to configure field selection:
 * 1. **FieldSets** (Declarative) - Admin-friendly, reusable across capabilities
 * 2. **defaultFields** (JSON Array) - Quick configuration without creating FieldSets
 *
 * Field Selection Options (Mutually Exclusive):
 *   Option 1: FieldSet-based (declarative, reusable)
 *     - Create FieldSet in Setup > Object Manager > [Object] > Field Sets
 *     - Config: {"fieldSetName": "AI_Agent_Details"}
 *     - Best for: Production orgs, multiple capabilities, admin control
 *
 *   Option 2: Array-based (quick, inline)
 *     - Specify field API names directly in configuration
 *     - Config: {"defaultFields": ["Id", "Name", "Status", "Priority"]}
 *     - Best for: Prototyping, testing, simple use cases
 *
 * Parameter Format:
 *   Simple: {"recordId": "001XXXXXXXXXXXX"}
 *   AI only needs to provide the record ID - field selection is handled in configuration.
 *
 * Configuration Schema:
 *   {
 *     "fieldSetName": "AI_Agent_Details",     // Option 1: FieldSet name (XOR with defaultFields)
 *     "defaultFields": ["Id", "Name"],        // Option 2: Field array (XOR with fieldSetName)
 *     "objectApiName": "Case",                // Optional: Validates record type
 *   }
 *
 * Security Architecture:
 *   - Respects object-level read permissions
 *   - Enforces field-level security on all fields
 *   - Uses Security.stripInaccessible() to filter inaccessible fields
 *   - Returns clear error messages for permission issues
 *
 * @ActionLabel Get Record Details
 * @ActionDescription Retrieves any Salesforce record by ID using FieldSets for declarative field selection
 * @ActionRequiresSObject true
 * @ActionIsActive true
 * @ActionGuidance
 * <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif; line-height: 1.6;"><div style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 16px; border-radius: 8px 8px 0 0; margin: -8px -8px 16px -8px;"><h2 style="margin: 0; font-size: 18px; font-weight: 600;">🔍 Get Record Details</h2><p style="margin: 4px 0 0 0; font-size: 13px; opacity: 0.95;">Generic record retrieval with flexible field selection (FieldSets or JSON array)</p></div><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">⚙️ Configuration</h3><div style="background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin: 12px 0;"><table style="width: 100%; font-size: 13px;"><tr><td style="padding: 8px; border-bottom: 1px solid #e9ecef; width: 30%;"><strong style="color: #495057;">fieldSetName</strong><br/><span style="font-size: 11px; color: #28a745;">Option 1</span></td><td style="padding: 8px; border-bottom: 1px solid #e9ecef; color: #6c757d;">Name of the FieldSet to use (e.g., "AI_Agent_Details"). <strong>Mutually exclusive with defaultFields.</strong><br/><span style="font-size: 12px; font-style: italic;">Best for: Production, reusable configs. Create in Setup &gt; Object Manager &gt; [Object] &gt; Field Sets</span></td></tr><tr><td style="padding: 8px; border-bottom: 1px solid #e9ecef;"><strong style="color: #495057;">defaultFields</strong><br/><span style="font-size: 11px; color: #28a745;">Option 2</span></td><td style="padding: 8px; border-bottom: 1px solid #e9ecef; color: #6c757d;">Array of field API names (e.g., ["Id", "Name", "Status"]). <strong>Mutually exclusive with fieldSetName.</strong><br/><code style="background: #f1f3f5; padding: 2px 6px; border-radius: 3px; font-size: 11px;">["Id", "CaseNumber", "Subject", "Status"]</code><br/><span style="font-size: 12px; font-style: italic;">Best for: Prototyping, testing, simple use cases</span></td></tr><tr><td style="padding: 8px;"><strong style="color: #495057;">objectApiName</strong><br/><span style="font-size: 11px; color: #6c757d;">Optional</span></td><td style="padding: 8px; color: #6c757d;">Expected object type (e.g., "Case"). Validates record ID matches this type for better error messages.</td></tr></table></div><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">📋 Runtime Parameters</h3><p style="margin: 8px 0; font-size: 13px; color: #6c757d;">The AI will provide this parameter when calling this action:</p><div style="background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin: 12px 0;"><table style="width: 100%; font-size: 13px;"><tr><td style="padding: 8px; width: 30%;"><strong style="color: #495057;">recordId</strong><br/><span style="font-size: 11px; color: #dc3545;">Required</span></td><td style="padding: 8px; color: #6c757d;">The 18-character (or 15-character) Salesforce ID. Works with any standard or custom object.<br/><code style="background: #f1f3f5; padding: 2px 6px; border-radius: 3px; font-size: 11px;">001XXXXXXXXXXXX</code></td></tr></table></div><div style="background: #d1ecf1; border-left: 4px solid #17a2b8; padding: 12px; margin: 12px 0; border-radius: 4px;"><p style="margin: 0; font-size: 13px; color: #0c5460;"><strong>⚡ Choose Your Approach:</strong><br/>• <strong>FieldSets</strong> = Declarative, admin-friendly, reusable across capabilities<br/>• <strong>defaultFields</strong> = Quick setup, inline config, no FieldSet creation needed<br/><em>You must provide exactly one (not both).</em></p></div><div style="background: #e7f1ff; border-left: 4px solid #0066cc; padding: 12px; margin: 12px 0; border-radius: 4px;"><p style="margin: 0; font-size: 13px; color: #004085;"><strong>🔒 Security:</strong> Respects object-level and field-level security. Fields the running user cannot access will be automatically filtered out. The AI receives only data the user has permission to view.</p></div></div>
 *
 * @extends BaseAgentAction
 */
public class ActionGetRecordDetails extends BaseAgentAction {
    private ConfigDTO config;

    /**
     * DTO for strongly-typed arguments (AI-provided parameters at runtime)
     */
    public class ArgumentsDTO {
        /**
         * @FieldLabel Record ID
         * @FieldType salesforce-id
         * @FieldRequired true
         * @FieldPlaceholder 001000000000000AAA
         * @FieldHelp The 18-character Salesforce ID of the record to retrieve
         */
        public String recordId;
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
         * @FieldPlaceholder Account
         * @FieldHelp Optional: The API name of the expected SObject type (e.g., Account, Case). When specified, validates that recordId matches this object type.
         */
        public String objectApiName;
    }

    /**
     * @description
     * Main entry point: Retrieves a record by ID using FieldSet-based field selection.
     *
     * Steps:
     *   1. Validate and parse recordId
     *   2. Determine SObjectType from recordId
     *   3. Validate object type if configured
     *   4. Get fields from FieldSet (or use defaults)
     *   5. Verify read permission on object
     *   6. Build and execute dynamic SOQL with FLS enforcement
     *   7. Return record data with metadata
     *
     * @param params Map<String, Object> - Raw parameters with recordId
     * @return ActionOutcome with record data, object type, and optional URL
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Deserialize arguments
        ArgumentsDTO args = new ArgumentsDTO();
        Object recordIdObj = params.get('recordId');

        if (recordIdObj == null) {
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Missing required parameter: "recordId"',
                'Expected: 18-character Salesforce ID (e.g., 001000000000001AAA) or 15-character ID (e.g., 001000000000001)'
            );
        }

        try {
            args.recordId = String.valueOf(recordIdObj);
        } catch (Exception e) {
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid recordId format: ' + recordIdObj,
                'Expected: 18-character Salesforce ID (e.g., 001000000000001AAA) or 15-character ID (e.g., 001000000000001)'
            );
        }

        // Convert to Id and get SObjectType
        Id recordId;
        SObjectType sObjectType;
        try {
            recordId = Id.valueOf(args.recordId);
            sObjectType = recordId.getSObjectType();
        } catch (Exception e) {
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid Salesforce ID: ' + args.recordId,
                'The provided ID is not a valid Salesforce record identifier. Ensure it is a 15 or 18 character ID.'
            );
        }

        if (sObjectType == null) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Unable to determine object type from record ID: ' + args.recordId
            );
        }

        String objectApiName = sObjectType.getDescribe().getName();
        System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] Record ID: ' + recordId + ', Object Type: ' + objectApiName);

        // Validate object type if configured
        if (String.isNotBlank(config.objectApiName)) {
            if (!objectApiName.equalsIgnoreCase(config.objectApiName)) {
                return ActionOutcome.failureWithGuidance(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'Record ID type mismatch. Expected: ' + config.objectApiName + ', Actual: ' + objectApiName,
                    'The provided record ID belongs to a different object type than configured. Please provide a valid ' +
                        config.objectApiName +
                        ' record ID.'
                );
            }
        }

        // Check object-level read permission
        DescribeSObjectResult objDescribe = sObjectType.getDescribe();
        if (!objDescribe.isAccessible()) {
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                'Access Denied: You do not have permission to read ' + objectApiName + ' records.',
                'Contact your Salesforce administrator to request read access to ' + objectApiName + ' records.'
            );
        }

        // Validate configuration: either fieldSetName OR defaultFields must be provided (XOR)
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

        if (hasFieldSet) {
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
        String soql = 'SELECT ' + String.join(accessibleFields, ', ') + ' FROM ' + objectApiName + ' WHERE Id = :recordId LIMIT 1';
        System.debug(LoggingLevel.INFO, '[ActionGetRecordDetails] Executing SOQL: ' + soql);

        try {
            List<SObject> results = Database.query(soql);

            if (results.isEmpty()) {
                return ActionOutcome.failureWithGuidance(
                    AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND,
                    'Record not found: ' + recordId,
                    'The record with ID ' + recordId + ' does not exist or has been deleted. Verify the ID is correct.'
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
                'recordId' => String.valueOf(recordId)
            };

            // Include metadata about removed fields if any
            if (!decision.getRemovedFields().isEmpty()) {
                System.debug(LoggingLevel.WARN, '[ActionGetRecordDetails] Security.stripInaccessible removed fields: ' + decision.getRemovedFields());
                response.put('fieldAccessWarning', 'Some fields were removed due to field-level security. Fields: ' + decision.getRemovedFields());
            }

            Long duration = System.currentTimeMillis() - startTime;
            System.debug(
                LoggingLevel.INFO,
                '[ActionGetRecordDetails] Success. Record retrieved in ' + duration + 'ms. Fields: ' + accessibleFields.size()
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
