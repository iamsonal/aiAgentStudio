/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionUpdateRecord: Robust, secure, and flexible record update action for Salesforce.
 *
 * This class provides a highly configurable and secure mechanism for updating Salesforce records.
 * It performs deep parameter validation, type coercion, field-level security (FLS) enforcement, and record lock detection.
 * Supports custom record ID parameter names via configuration, and delivers detailed error and audit context for troubleshooting and compliance.
 *
 * Key Features:
 *   - Validates and extracts record IDs, supporting custom parameter names.
 *   - Performs field-level security checks and type coercion for all update fields.
 *   - Detects and reports record lock status before attempting DML.
 *   - Provides detailed debug output and error messages for maintainability and auditability.
 *   - Returns structured, LLM-friendly results for downstream processing.
 *
 * Configuration Example: {"recordIdParameter": "customIdField"} (optional)
 * Parameters Example: {"recordId": "003...", "FieldName1": "NewValue1", ...}
 *
 * @extends BaseAgentAction
 */
public class ActionUpdateRecord extends BaseAgentAction {
    private static final String CONFIG_KEY_RECORD_ID_PARAM = 'recordIdParameter';
    private String recordIdParameterName = 'recordId';

    /**
     * @description
     * Main entry point: Executes a secure, validated update of a Salesforce record.
     *
     * Steps:
     *   1. Validates and extracts the record ID (supports custom parameter name).
     *   2. Extracts and validates update fields, excluding the record ID.
     *   3. Checks object-level update permission (FLS).
     *   4. Detects record lock status and aborts if locked.
     *   5. Performs type coercion and field-level security checks on update fields.
     *   6. Executes the DML update and returns a structured result.
     *
     * @param params Map<String, Object> containing record ID and field updates.
     * @return UpdateResult with update confirmation, updated fields, and metadata.
     * @throws ValidationException if parameters are missing or invalid.
     * @throws SecurityUtils.ActionSecurityException if user lacks update permission.
     * @throws DmlException if the update fails.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Validate and extract the record ID (supports custom parameter name)
        Id recordId = validateAndExtractRecordId(params);
        SObjectType targetSObjectType = recordId.getSObjectType();

        // Extract and validate update fields (excluding record ID)
        Map<String, Object> updateData = extractUpdateFields(params, recordId);

        // Explicit object-level update permission check
        try {
            SecurityUtils.checkObjectPermission(targetSObjectType, AccessType.UPDATABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
            System.debug(LoggingLevel.ERROR, '[ActionUpdateRecord] User lacks update permission for ' + targetSObjectType + ': ' + ase.getMessage());
            throw ase;
        }

        // Proactively check for record locks to provide actionable error messages
        try {
            if (Approval.isLocked(recordId)) {
                throw new ValidationException('Record is locked and cannot be updated: ' + recordId, this.recordIdParameterName);
            }
        } catch (Exception lockCheckEx) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionUpdateRecord] Unable to determine lock status for record ' + recordId + ': ' + lockCheckEx.getMessage()
            );
        }

        Map<String, Object> typedData;
        try {
            // Coerce types and enforce field-level security (FLS)
            typedData = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(updateData, targetSObjectType, AccessType.UPDATABLE);
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException typeEx) {
            throw new ValidationException(typeEx.getMessage(), null);
        } catch (SecurityUtils.ActionSecurityException secEx) {
            throw secEx;
        }

        if (typedData.isEmpty()) {
            Set<String> originalFields = updateData.keySet();
            throw new ActionSecurityException(
                'No updatable fields provided after security checks for record ' +
                    recordId +
                    '. Original fields: ' +
                    String.join(new List<String>(originalFields), ', ')
            );
        }

        // Track and log fields filtered out by FLS for auditability
        Set<String> originalFields = updateData.keySet();
        Set<String> allowedFields = typedData.keySet();
        Set<String> removedFields = new Set<String>(originalFields);
        removedFields.removeAll(allowedFields);
        if (!removedFields.isEmpty()) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionUpdateRecord] FLS enforcement: The following fields were excluded from update for record ' +
                    recordId +
                    ': ' +
                    String.join(new List<String>(removedFields), ', ')
            );
        }

        // Create and populate SObject for update (fields already validated)
        SObject recordToUpdate = targetSObjectType.newSObject(recordId);
        for (String fieldName : typedData.keySet()) {
            recordToUpdate.put(fieldName, typedData.get(fieldName));
        }

        // Perform DML update with enhanced error handling and context
        Database.SaveResult result = Database.update(recordToUpdate, false);

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

        if (result.isSuccess()) {
            System.debug(LoggingLevel.DEBUG, '[ActionUpdateRecord] Update succeeded for record ' + recordId);
            return new UpdateResult(recordId.toString(), 'Successfully updated record ' + recordId + '.', new List<String>(typedData.keySet()));
        } else {
            String enhancedMessage = enhanceUpdateErrorMessage(result.getErrors()[0], recordId, typedData);
            System.debug(LoggingLevel.ERROR, '[ActionUpdateRecord] Update failed for record ' + recordId + ': ' + enhancedMessage);
            throw new DmlException(enhancedMessage);
        }
    }

    /**
     * @description
     * Parses action configuration JSON to support custom record ID parameter names.
     * If a custom parameter name is provided, it is used for record ID extraction.
     *
     * @param actionConfigurationJson JSON string with configuration options
     * @param logPrefix Prefix for debug logging
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        String customParamName = ActionConfigUtils.getOptionalString(this.parsedActionConfig, CONFIG_KEY_RECORD_ID_PARAM);

        if (String.isNotBlank(customParamName)) {
            this.recordIdParameterName = customParamName;
            System.debug(
                LoggingLevel.INFO,
                '[ActionUpdateRecord] Using custom record ID parameter from config: "' + this.recordIdParameterName + '"'
            );
        }
    }

    /**
     * @description
     * Validates and extracts the record ID from parameters, supporting custom parameter names.
     * Throws ValidationException if the parameter is missing or invalid.
     *
     * @param params Map containing the record ID parameter
     * @return Id of the record to update
     * @throws ValidationException if the record ID is missing or invalid
     */
    private Id validateAndExtractRecordId(Map<String, Object> params) {
        Object idObj = params.get(this.recordIdParameterName);

        if (idObj == null) {
            throw new ValidationException('Missing required parameter: "' + this.recordIdParameterName + '"', this.recordIdParameterName);
        }

        if (idObj instanceof Id) {
            return (Id) idObj;
        }

        if (idObj instanceof String && String.isNotBlank((String) idObj)) {
            try {
                return Id.valueOf((String) idObj);
            } catch (System.StringException strEx) {
                throw new ValidationException('Invalid ID format for "' + this.recordIdParameterName + '": ' + idObj, this.recordIdParameterName);
            }
        }

        throw new ValidationException('Parameter "' + this.recordIdParameterName + '" must be a valid Salesforce ID', this.recordIdParameterName);
    }

    /**
     * @description
     * Extracts field update data from parameters, excluding the record ID parameter.
     * Throws ValidationException if no update fields are provided.
     *
     * @param params Full parameter map
     * @param recordId The record ID for context in error messages
     * @return Map<String, Object> of field names to update values
     * @throws ValidationException if no update fields are provided
     */
    private Map<String, Object> extractUpdateFields(Map<String, Object> params, Id recordId) {
        Map<String, Object> updateData = new Map<String, Object>();

        for (String key : params.keySet()) {
            if (!key.equalsIgnoreCase(this.recordIdParameterName)) {
                updateData.put(key, params.get(key));
            }
        }

        if (updateData.isEmpty()) {
            throw new ValidationException('No fields provided to update for record ID: ' + recordId, null);
        }

        return updateData;
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
            enhanced += ' | The record is currently locked by another process.';
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
