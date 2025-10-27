/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionUpdateRecord: High-performance, secure record update action using strongly-typed DTOs.
 *
 * This class provides a highly configurable and secure mechanism for updating Salesforce records.
 * It performs deep parameter validation, type coercion, field-level security (FLS) enforcement, and record lock detection.
 * Supports custom record ID parameter names via configuration, and delivers detailed error and audit context for troubleshooting and compliance.
 *
 * Security Architecture:
 *   - Proactive FLS checks via TypeCoercionService provide clear, actionable errors for AI agents
 *   - Security.stripInaccessible() serves as final verification and catches edge cases
 *   - Logs discrepancies between manual and native FLS checks for audit and debugging
 *
 * Architecture:
 *   - ArgumentsDTO: Strongly-typed with recordId and Map<String, Object> for dynamic fields
 *   - ConfigDTO: Optional configuration for custom recordId parameter name
 *   - Uses native JSON.deserialize() for high-performance type conversion
 *   - Leverages TypeCoercionService for FLS checks and SObject field coercion
 *
 * @extends BaseAgentAction
 */
public class ActionUpdateRecord extends BaseAgentAction {
    private ConfigDTO config;

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        public String recordId;
        public Map<String, Object> fields;
    }

    /**
     * DTO for strongly-typed backend configuration (currently no config needed)
     */
    public class ConfigDTO {
        // Reserved for future configuration options
    }

    /**
     * @description
     * Main entry point: Executes a secure, validated update using strongly-typed DTOs.
     *
     * Steps:
     *   1. Deserializes params into ArgumentsDTO for type safety
     *   2. Validates recordId and extracts SObjectType
     *   3. Checks object-level update permission (FLS)
     *   4. Performs type coercion and field-level security checks on update fields
     *   5. Executes the DML update and returns a structured result
     *
     * @param params Map<String, Object> - Raw parameters (deserialized into ArgumentsDTO for type safety)
     * @return ActionOutcome<UpdateResult> with update confirmation, updated fields, and metadata, or error information
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();

        // Extract recordId
        Object recordIdObj = params.get('recordId');
        if (recordIdObj == null) {
            return ActionOutcome.failureWithGuidance(
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
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid recordId format: ' + recordIdObj,
                'Expected: 18-character Salesforce ID (e.g., 001000000000001AAA) or 15-character ID (e.g., 001000000000001)'
            );
        }

        // Extract fields
        if (params.containsKey('fields') && params.get('fields') instanceof Map<String, Object>) {
            args.fields = (Map<String, Object>) params.get('fields');
        } else {
            args.fields = new Map<String, Object>();
        }

        // Validate DTO
        if (args.fields.isEmpty()) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'No fields provided to update for record ID: ' + args.recordId);
        }

        // Convert to Id and get SObjectType
        Id recordId;
        try {
            recordId = Id.valueOf(args.recordId);
        } catch (Exception e) {
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid ID format for recordId: ' + args.recordId,
                'Expected: 18-character Salesforce ID (e.g., 001000000000001AAA) or 15-character ID (e.g., 001000000000001)'
            );
        }
        SObjectType targetSObjectType = recordId.getSObjectType();

        // Explicit object-level update permission check
        try {
            SecurityUtils.checkObjectPermission(targetSObjectType, AccessType.UPDATABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
            System.debug(LoggingLevel.ERROR, '[ActionUpdateRecord] User lacks update permission for ' + targetSObjectType + ': ' + ase.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ase.getMessage());
        }

        Map<String, Object> typedData;
        try {
            // Coerce types and enforce field-level security (FLS) using DTO fields
            typedData = TypeCoercionService.coerceArgumentTypesForSObject(args.fields, targetSObjectType, AccessType.UPDATABLE);
        } catch (TypeCoercionService.TypeCoercionException typeEx) {
            // Extract auto-generated correction guidance to help LLM self-correct format errors
            if (String.isNotBlank(typeEx.correctionGuidance)) {
                return ActionOutcome.failureWithGuidance(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, typeEx.getMessage(), typeEx.correctionGuidance);
            }
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, typeEx.getMessage());
        } catch (SecurityUtils.ActionSecurityException secEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, secEx.getMessage());
        }

        if (typedData.isEmpty()) {
            Set<String> originalFields = args.fields.keySet();
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
        Set<String> removedFieldsForFLS = new Set<String>(args.fields.keySet());
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
        Database.SaveResult saveResult = Database.update(decision.getRecords()[0], false);

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
        // Initialize empty config (no configuration options currently supported)
        this.config = new ConfigDTO();

        // Log if any config was provided (currently ignored)
        if (String.isNotBlank(actionConfigurationJson)) {
            System.debug(
                LoggingLevel.DEBUG,
                '[ActionUpdateRecord] Configuration provided but no config options are currently supported for DTO-based implementation.'
            );
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
