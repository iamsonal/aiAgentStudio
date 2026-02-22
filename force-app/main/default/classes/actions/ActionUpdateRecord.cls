/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Updates Salesforce records with FLS checks and validation.
 * @ActionLabel Update Record
 * @ActionDescription Updates an existing Salesforce record with field-level security checks
 * @ActionRequiresSObject true
 * @ActionIsActive true
 *
 * @extends BaseAgentAction
 */
public with sharing class ActionUpdateRecord extends BaseAgentAction {
    private ConfigDTO config;

    public class ArgumentsDTO {
        /**
         * @FieldLabel Record ID
         * @FieldType salesforce-id
         * @FieldRequired true
         * @FieldPlaceholder 001000000000000AAA
         * @FieldHelp The 18-character Salesforce ID of the record to update
         */
        public String recordId;

        /**
         * @FieldLabel Record Data
         * @FieldType object
         * @FieldRequired true
         * @FieldHelp Field names and new values for the fields to update
         */
        public Map<String, Object> recordData;
    }

    /**
     * DTO for strongly-typed backend configuration (admin-configured)
     */
    public class ConfigDTO {
        /**
         * @FieldLabel Object API Name
         * @FieldType string
         * @FieldPlaceholder Account
         * @FieldHelp Optional: The API name of the SObject being updated (e.g., Account, Contact). When specified, validates that recordId matches this object type.
         */
        public String objectApiName;

        /**
         * @FieldLabel Default Field Values
         * @FieldType object
         * @FieldHelp Optional default values to set on all updated records. These are merged with AI-provided values.
         */
        public Map<String, Object> defaultFieldValues;
    }

    /**
     * @description
     * Main entry point: Executes a secure, validated update using strongly-typed DTOs.
     *
     * Expected Parameter Format:
     *   Nested recordData object: {"recordId": "500...", "recordData": {"Priority": "High", "Status": "Closed"}}
     *
     * Steps:
     *   1. Extracts recordId and nested recordData from parameters
     *   2. Validates recordId and extracts SObjectType
     *   3. Checks object-level update permission (FLS)
     *   4. Performs type coercion and field-level security checks on update fields
     *   5. Executes the DML update and returns a structured result
     *
     * @param params Map<String, Object> - Raw parameters with recordId and nested recordData
     * @return ActionOutcome<UpdateResult> with update confirmation, updated fields, and metadata, or error information
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();

        // Extract recordId
        Object recordIdObj = params.get('recordId');
        if (recordIdObj == null) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Missing required parameter: "recordId"',
                'Expected: 18-character Salesforce ID (e.g., 001000000000001AAA) or 15-character ID (e.g., 001000000000001)'
            );
        }

        try {
            if (recordIdObj instanceof Id) {
                args.recordId = String.valueOf(recordIdObj);
            } else {
                args.recordId = String.valueOf(recordIdObj);
            }
        } catch (Exception e) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid recordId format: ' + recordIdObj,
                'Expected: 18-character Salesforce ID (e.g., 001000000000001AAA) or 15-character ID (e.g., 001000000000001)'
            );
        }

        // Extract recordData from nested structure
        // Expected format: {"recordId": "...", "recordData": {"Field1": "value1", "Field2": "value2"}}
        if (params.containsKey('recordData') && params.get('recordData') instanceof Map<String, Object>) {
            args.recordData = (Map<String, Object>) params.get('recordData');
        } else {
            args.recordData = new Map<String, Object>();
        }

        // Merge default and user-supplied field values
        Map<String, Object> finalData = new Map<String, Object>();
        if (config.defaultFieldValues != null) {
            finalData.putAll(config.defaultFieldValues);
        }
        if (!args.recordData.isEmpty()) {
            finalData.putAll(args.recordData); // AI values override defaults
        }

        // Validate DTO
        if (finalData.isEmpty()) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'No field data provided in recordData for record ID: ' + args.recordId);
        }

        // Convert to Id and get SObjectType
        Id recordId;
        try {
            recordId = Id.valueOf(args.recordId);
        } catch (Exception e) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid ID format for recordId: ' + args.recordId,
                'Expected: 18-character Salesforce ID (e.g., 001000000000001AAA) or 15-character ID (e.g., 001000000000001)'
            );
        }
        SObjectType targetSObjectType = recordId.getSObjectType();

        // Validate objectApiName if configured
        if (String.isNotBlank(config.objectApiName)) {
            String actualObjectApiName = targetSObjectType.getDescribe().getName();
            if (!actualObjectApiName.equalsIgnoreCase(config.objectApiName)) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'Object API name mismatch: Expected "' + config.objectApiName + '" but recordId "' + recordId + '" is for "' + actualObjectApiName + '"',
                    'Ensure the recordId matches the configured objectApiName "' + config.objectApiName + '"'
                );
            }
        }

        // Explicit object-level update permission check
        try {
            Utils.checkObjectPermission(targetSObjectType, AccessType.UPDATABLE);
        } catch (Utils.ActionSecurityException ase) {
            System.debug(LoggingLevel.ERROR, '[ActionUpdateRecord] User lacks update permission for ' + targetSObjectType + ': ' + ase.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ase.getMessage());
        }

        Map<String, Object> typedData;
        try {
            // Coerce types and enforce field-level security (FLS) using merged field data
            typedData = TypeCoercionService.coerceArgumentTypesForSObject(finalData, targetSObjectType, AccessType.UPDATABLE);
        } catch (TypeCoercionService.TypeCoercionException typeEx) {
            // Extract auto-generated correction guidance to help LLM self-correct format errors
            if (String.isNotBlank(typeEx.correctionGuidance)) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, typeEx.getMessage(), typeEx.correctionGuidance);
            }
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, typeEx.getMessage());
        } catch (Utils.ActionSecurityException secEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, secEx.getMessage());
        }

        if (typedData.isEmpty()) {
            Set<String> originalFields = finalData.keySet();
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                'No updatable fields provided after security checks for record ' +
                    recordId +
                    '. Original fields: ' +
                    String.join(new List<String>(originalFields), ', ')
            );
        }

        // Track and log fields filtered out by FLS for auditability
        Set<String> allowedFields = typedData.keySet();
        Set<String> removedFieldsForFLS = new Set<String>(finalData.keySet());
        removedFieldsForFLS.removeAll(allowedFields);
        if (!removedFieldsForFLS.isEmpty()) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionUpdateRecord] FLS enforcement: The following fields were excluded from update for record ' +
                    recordId +
                    ': ' +
                    String.join(new List<String>(removedFieldsForFLS), ', ')
            );
        }

        // Create and populate SObject for update (fields already validated)
        SObject recordToUpdate = targetSObjectType.newSObject(recordId);
        for (String fieldName : typedData.keySet()) {
            recordToUpdate.put(fieldName, typedData.get(fieldName));
        }

        // Defense-in-depth: Use Security.stripInaccessible() as final verification layer
        // This ensures Salesforce native FLS enforcement catches any edge cases in manual checks
        SObjectAccessDecision decision = Security.stripInaccessible(AccessType.UPDATABLE, new List<SObject>{ recordToUpdate });

        // Log any discrepancies between manual FLS checks and stripInaccessible results
        Map<String, Set<String>> decisionRemovedFields = decision.getRemovedFields();
        String objectName = targetSObjectType.getDescribe().getName();
        if (!decisionRemovedFields.isEmpty() && decisionRemovedFields.containsKey(objectName)) {
            Set<String> strippedFields = decisionRemovedFields.get(objectName);
            if (!strippedFields.isEmpty()) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ActionUpdateRecord] SECURITY AUDIT: stripInaccessible() removed fields that passed manual FLS checks. ' +
                        'This indicates a potential bug in TypeCoercionService. Record: ' +
                        recordId +
                        ', Fields: ' +
                        String.join(new List<String>(strippedFields), ', ')
                );
            }
        }

        // Perform DML update with enhanced error handling and context
        Database.SaveResult saveResult = Database.update(decision.getRecords()[0], false, AccessLevel.USER_MODE);

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(
            LoggingLevel.INFO,
            '[ActionUpdateRecord] Record update for ' +
                recordId +
                ' completed in ' +
                executionTime +
                'ms. Updated fields: ' +
                String.join(new List<String>(typedData.keySet()), ', ')
        );

        if (saveResult.isSuccess()) {
            System.debug(LoggingLevel.DEBUG, '[ActionUpdateRecord] Update succeeded for record ' + recordId);
            return ActionOutcome.success(
                new UpdateResult(recordId.toString(), 'Successfully updated record ' + recordId + '.', new List<String>(typedData.keySet()))
            );
        } else {
            Database.Error error = saveResult.getErrors()[0];
            String enhancedMessage = enhanceUpdateErrorMessage(error, recordId, typedData);
            System.debug(LoggingLevel.ERROR, '[ActionUpdateRecord] Update failed for record ' + recordId + ': ' + enhancedMessage);

            // Return appropriate error code based on failure type
            String errorCode = AIAgentConstants.ERR_CODE_DML_ERROR;
            if (error.getStatusCode() == StatusCode.UNABLE_TO_LOCK_ROW) {
                errorCode = AIAgentConstants.ERR_CODE_RECORD_LOCKED;
            } else if (error.getStatusCode() == StatusCode.INSUFFICIENT_ACCESS_OR_READONLY) {
                errorCode = AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
            } else if (
                error.getStatusCode() == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION ||
                error.getStatusCode() == StatusCode.REQUIRED_FIELD_MISSING ||
                error.getStatusCode() == StatusCode.STRING_TOO_LONG ||
                error.getStatusCode() == StatusCode.DUPLICATE_VALUE
            ) {
                errorCode = AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
            }

            return ActionOutcome.failure(errorCode, enhancedMessage);
        }
    }

    /**
     * @description
     * Parses action configuration JSON using strongly-typed ConfigDTO.
     * Configuration is optional - if not provided, uses defaults.
     *
     * @param actionConfigurationJson JSON string with configuration options
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

                // Extract objectApiName if provided
                if (configMap.containsKey('objectApiName')) {
                    this.config.objectApiName = (String) configMap.get('objectApiName');
                }

                // Handle defaultFieldValues
                Object defaultFieldsObj = configMap.get('defaultFieldValues');
                if (defaultFieldsObj instanceof Map<String, Object>) {
                    this.config.defaultFieldValues = (Map<String, Object>) defaultFieldsObj;
                } else {
                    this.config.defaultFieldValues = new Map<String, Object>();
                }

                if (String.isNotBlank(this.config.objectApiName)) {
                    System.debug(LoggingLevel.DEBUG, '[ActionUpdateRecord] Configured to validate updates against object type: ' + this.config.objectApiName);
                }

                if (!this.config.defaultFieldValues.isEmpty()) {
                    System.debug(
                        LoggingLevel.DEBUG,
                        '[ActionUpdateRecord] Loaded ' + this.config.defaultFieldValues.size() + ' default field values from configuration.'
                    );
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[ActionUpdateRecord] Failed to parse configuration JSON: ' + e.getMessage() + '. Using defaults.');
            }
        }

        // Initialize defaultFieldValues if null
        if (config.defaultFieldValues == null) {
            config.defaultFieldValues = new Map<String, Object>();
        }
    }

    /**
     * @description
     * Enhances DML error messages with contextual information for better troubleshooting.
     * Adds details about lock status, permissions, and fields involved.
     *
     * @param error The Database.Error from the failed DML operation
     * @param recordId The record ID that failed to update
     * @param typedData The field data that was attempted to be updated
     * @return String with enhanced error message and context
     */
    private String enhanceUpdateErrorMessage(Database.Error error, Id recordId, Map<String, Object> typedData) {
        String enhanced = 'Failed to update record ' + recordId + ': ' + error.getMessage();

        if (error.getStatusCode() == StatusCode.UNABLE_TO_LOCK_ROW) {
            enhanced +=
                ' | The record is currently locked by another process. ' +
                'This typically means the record is in an approval process or being edited by another user. ' +
                'Please try again in a few moments.';
        } else if (error.getStatusCode() == StatusCode.INSUFFICIENT_ACCESS_OR_READONLY) {
            enhanced += ' | User lacks update permission or field is read-only.';
        }

        enhanced += ' | Fields attempted: ' + String.join(new List<String>(typedData.keySet()), ', ');

        if (!error.getFields().isEmpty()) {
            enhanced += ' | Problem fields: ' + String.join(error.getFields(), ', ');
        }

        return enhanced;
    }

    /**
     * @description
     * Result wrapper for successful record update operations.
     * Provides structured data for both user display and LLM processing.
     *
     * @property recordId The ID of the updated record
     * @property message User-facing confirmation message
     * @property updatedFields List of updated field names
     * @property metadata Additional context for LLMs and downstream consumers
     */
    public class UpdateResult {
        public String recordId;
        public String message; // Framework uses this for user display
        public List<String> updatedFields;
        public Map<String, Object> metadata; // Additional context for LLMs

        public UpdateResult(String recordId, String message, List<String> updatedFields) {
            this.recordId = recordId;
            this.message = message;
            this.updatedFields = updatedFields;
            this.metadata = new Map<String, Object>{ 'recordId' => recordId, 'fieldsUpdated' => updatedFields.size(), 'fieldNames' => updatedFields };
        }
    }
}
