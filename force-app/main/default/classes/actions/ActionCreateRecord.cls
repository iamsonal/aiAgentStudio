/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionCreateRecord is a robust, high-performance Apex action for creating Salesforce records using strongly-typed DTOs.
 *
 * Responsibilities:
 *   - Uses DTOs for type-safe argument and configuration handling
 *   - Performs proactive FLS checks to provide AI-friendly error messages before DML
 *   - Applies Security.stripInaccessible() as defense-in-depth verification layer
 *   - Handles DML errors with enhanced, context-rich messages for troubleshooting
 *   - Provides detailed debug output for security, field filtering, and performance analysis
 *
 * Security Architecture:
 *   - Proactive FLS checks via TypeCoercionService provide clear, actionable errors for AI agents
 *   - Security.stripInaccessible() serves as final verification and catches edge cases
 *   - Logs discrepancies between manual and native FLS checks for audit and debugging
 *
 * Architecture:
 *   - ArgumentsDTO: Contains Map<String, Object> for dynamic SObject fields
 *   - ConfigDTO: Strongly-typed configuration with objectApiName and defaultFieldValues
 *   - Uses native JSON.deserialize() for high-performance type conversion
 *   - Leverages TypeCoercionService for FLS checks and SObject field coercion
 *
 * @extends BaseAgentAction
 */
public class ActionCreateRecord extends BaseAgentAction {
    private ConfigDTO config;
    private SObjectType targetSObjectType;

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        public Map<String, Object> fields;
    }

    /**
     * DTO for strongly-typed backend configuration
     */
    public class ConfigDTO {
        public String objectApiName;
        public Map<String, Object> defaultFieldValues;
    }

    /**
     * @description
     * Main entry point for record creation using strongly-typed DTOs.
     * Deserializes params into ArgumentsDTO, merges with default values, performs security and type validation,
     * and executes the DML insert. Returns a structured result or failure information.
     *
     * @param params Map<String, Object> - Raw parameters (deserialized into ArgumentsDTO for type safety)
     * @return ActionOutcome<CreateResult> - Contains the new record ID and metadata, or error information
     *
     * Side effects: Logs security, FLS, and performance information for audit and troubleshooting
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();
        if (params.containsKey('fields') && params.get('fields') instanceof Map<String, Object>) {
            args.fields = (Map<String, Object>) params.get('fields');
        } else {
            args.fields = new Map<String, Object>();
        }

        // Merge default and user-supplied field values
        Map<String, Object> finalData = new Map<String, Object>();
        if (config.defaultFieldValues != null) {
            finalData.putAll(config.defaultFieldValues);
        }
        if (!args.fields.isEmpty()) {
            finalData.putAll(args.fields);
        }

        if (finalData.isEmpty()) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'No field data provided for record creation');
        }

        // Validate RecordType if specified
        if (finalData.containsKey('RecordTypeId') && finalData.get('RecordTypeId') != null) {
            ActionOutcome rtValidation = validateRecordTypeAccess(finalData.get('RecordTypeId'));
            if (!rtValidation.isSuccess) {
                return rtValidation;
            }
        }

        // Explicitly check object-level create permission
        try {
            SecurityUtils.checkObjectPermission(this.targetSObjectType, AccessType.CREATABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
            System.debug(
                LoggingLevel.ERROR,
                '[ActionCreateRecord] Security check failed for object ' + config.objectApiName + ': ' + ase.getMessage()
            );
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ase.getMessage());
        }

        // Coerce types and check field-level security (FLS)
        Map<String, Object> typedData;
        try {
            typedData = TypeCoercionService.coerceArgumentTypesForSObject(finalData, this.targetSObjectType, AccessType.CREATABLE);
        } catch (TypeCoercionService.TypeCoercionException typeEx) {
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Type coercion failed: ' + typeEx.getMessage());
            // Extract auto-generated correction guidance to help LLM self-correct format errors
            if (String.isNotBlank(typeEx.correctionGuidance)) {
                return ActionOutcome.failureWithGuidance(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, typeEx.getMessage(), typeEx.correctionGuidance);
            }
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, typeEx.getMessage());
        } catch (SecurityUtils.ActionSecurityException secEx) {
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Field-level security check failed: ' + secEx.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, secEx.getMessage());
        }

        if (typedData.isEmpty()) {
            Set<String> originalFields = finalData.keySet();
            System.debug(
                LoggingLevel.WARN,
                '[ActionCreateRecord] All provided fields were filtered out by FLS. Original fields: ' +
                String.join(new List<String>(originalFields), ', ')
            );
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                'No creatable fields provided after security checks. Original fields: ' + String.join(new List<String>(originalFields), ', ')
            );
        }

        // Log fields filtered by FLS for audit and troubleshooting
        Set<String> originalFields = finalData.keySet();
        Set<String> allowedFields = typedData.keySet();
        Set<String> removedFields = new Set<String>(originalFields);
        removedFields.removeAll(allowedFields);
        if (!removedFields.isEmpty()) {
            System.debug(
                LoggingLevel.WARN,
                '[ActionCreateRecord] The following fields were removed by FLS: ' + String.join(new List<String>(removedFields), ', ')
            );
        }

        // Populate SObject with validated, allowed fields
        SObject newRecord = this.targetSObjectType.newSObject();
        for (String fieldName : typedData.keySet()) {
            newRecord.put(fieldName, typedData.get(fieldName));
        }

        // Defense-in-depth: Use Security.stripInaccessible() as final verification layer
        // This ensures Salesforce native FLS enforcement catches any edge cases in manual checks
        SObjectAccessDecision decision = Security.stripInaccessible(AccessType.CREATABLE, new List<SObject>{ newRecord });

        // Log any discrepancies between manual FLS checks and stripInaccessible results
        Map<String, Set<String>> decisionRemovedFields = decision.getRemovedFields();
        if (!decisionRemovedFields.isEmpty() && decisionRemovedFields.containsKey(config.objectApiName)) {
            Set<String> strippedFields = decisionRemovedFields.get(config.objectApiName);
            if (!strippedFields.isEmpty()) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ActionCreateRecord] SECURITY AUDIT: stripInaccessible() removed fields that passed manual FLS checks. ' +
                        'This indicates a potential bug in TypeCoercionService. Fields: ' +
                        String.join(new List<String>(strippedFields), ', ')
                );
            }
        }

        // Insert the record and handle DML errors
        Database.SaveResult saveResult = Database.insert(decision.getRecords()[0], false);

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(
            LoggingLevel.INFO,
            '[ActionCreateRecord] Record creation for ' + config.objectApiName + ' completed in ' + executionTime + ' ms.'
        );

        if (saveResult.isSuccess()) {
            System.debug(LoggingLevel.DEBUG, '[ActionCreateRecord] Successfully created record with ID: ' + saveResult.getId());
            return ActionOutcome.success(
                new CreateResult(
                    saveResult.getId(),
                    'Successfully created ' + config.objectApiName + ' record with ID ' + saveResult.getId() + '.',
                    new List<String>(typedData.keySet())
                )
            );
        } else {
            String enhancedMessage = enhanceCreateErrorMessage(saveResult.getErrors()[0], typedData);
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Record creation failed for ' + config.objectApiName + ': ' + enhancedMessage);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_DML_ERROR, enhancedMessage);
        }
    }

    /**
     * @description
     * Parses and validates the action configuration JSON using strongly-typed ConfigDTO.
     * Extracts the target SObject type and any default field values.
     * Logs the number of default values loaded for transparency.
     *
     * @param actionConfigurationJson String - The JSON configuration string
     * @param logPrefix String - Prefix for log output
     * @throws ValidationException if required configuration is missing or invalid
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        // Parse config using hybrid approach for Map<String, Object> compatibility
        try {
            if (String.isBlank(actionConfigurationJson)) {
                throw new ValidationException('Configuration JSON is required', null);
            }

            // First deserialize as untyped map to handle Map<String, Object> properly
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

            // Then manually populate ConfigDTO
            this.config = new ConfigDTO();
            this.config.objectApiName = (String) configMap.get('objectApiName');

            // Handle defaultFieldValues
            Object defaultFieldsObj = configMap.get('defaultFieldValues');
            if (defaultFieldsObj instanceof Map<String, Object>) {
                this.config.defaultFieldValues = (Map<String, Object>) defaultFieldsObj;
            } else {
                this.config.defaultFieldValues = new Map<String, Object>();
            }
        } catch (Exception e) {
            throw new ValidationException('Invalid configuration JSON: ' + e.getMessage(), e);
        }

        // Validate required fields
        if (String.isBlank(config.objectApiName)) {
            throw new ValidationException('objectApiName is required in configuration', 'objectApiName');
        }

        this.targetSObjectType = SchemaUtils.getSObjectType(config.objectApiName);
        if (this.targetSObjectType == null) {
            throw new ValidationException('Invalid SObject API Name in configuration: ' + config.objectApiName, 'objectApiName');
        }

        // Initialize defaultFieldValues if null
        if (config.defaultFieldValues == null) {
            config.defaultFieldValues = new Map<String, Object>();
        }

        if (!config.defaultFieldValues.isEmpty()) {
            System.debug(
                LoggingLevel.DEBUG,
                '[ActionCreateRecord] Loaded ' + config.defaultFieldValues.size() + ' default field values from configuration.'
            );
        }
    }

    /**
     * @description
     * Enhances DML error messages with contextual information for better troubleshooting.
     *
     * @param error Database.Error - The error from the failed DML operation
     * @param typedData Map<String, Object> - The field data that was attempted to be inserted
     * @return String - Enhanced error message with context and field information
     */
    private String enhanceCreateErrorMessage(Database.Error error, Map<String, Object> typedData) {
        String enhanced = 'Failed to create ' + config.objectApiName + ' record: ' + error.getMessage();

        if (error.getStatusCode() == StatusCode.REQUIRED_FIELD_MISSING) {
            enhanced += ' | Missing required field(s).';
        } else if (error.getStatusCode() == StatusCode.FIELD_CUSTOM_VALIDATION_EXCEPTION) {
            enhanced += ' | Custom validation rule failed.';
        } else if (error.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
            enhanced += ' | Duplicate value detected.';
        } else if (error.getStatusCode() == StatusCode.STRING_TOO_LONG) {
            enhanced += ' | Field value exceeds maximum length.';
        }

        enhanced += ' | Fields attempted: ' + String.join(new List<String>(typedData.keySet()), ', ');

        if (!error.getFields().isEmpty()) {
            enhanced += ' | Problem fields: ' + String.join(error.getFields(), ', ');
        }

        return enhanced;
    }

    /**
     * @description
     * Validates that the specified RecordType exists for this object and that the user has access to create records with it.
     *
     * @param recordTypeIdObj Object - The RecordTypeId value (could be String or Id).
     * @return ActionOutcome - Success if RecordType is valid and accessible, failure otherwise.
     */
    private ActionOutcome validateRecordTypeAccess(Object recordTypeIdObj) {
        Id recordTypeId;

        // Convert to Id if needed
        try {
            if (recordTypeIdObj instanceof Id) {
                recordTypeId = (Id) recordTypeIdObj;
            } else if (recordTypeIdObj instanceof String) {
                recordTypeId = Id.valueOf((String) recordTypeIdObj);
            } else {
                return ActionOutcome.failureWithGuidance(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'RecordTypeId must be a valid Salesforce ID',
                    'Expected: 18-character Salesforce ID (e.g., 012000000000001AAA) or 15-character ID (e.g., 012000000000001)'
                );
            }
        } catch (Exception e) {
            return ActionOutcome.failureWithGuidance(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid RecordTypeId format: ' + recordTypeIdObj,
                'Expected: 18-character Salesforce ID (e.g., 012000000000001AAA) or 15-character ID (e.g., 012000000000001)'
            );
        }

        // Validate the RecordType ID is for a RecordType object
        String sObjectTypeName = recordTypeId.getSObjectType().getDescribe().getName();
        if (sObjectTypeName != 'RecordType') {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'The provided ID is not a RecordType ID: ' + recordTypeId);
        }

        // Query the RecordType to validate it exists and belongs to this object
        try {
            List<RecordType> recordTypes = [
                SELECT Id, DeveloperName, Name, IsActive
                FROM RecordType
                WHERE Id = :recordTypeId AND SObjectType = :config.objectApiName
                WITH USER_MODE
                LIMIT 1
            ];

            if (recordTypes.isEmpty()) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'RecordType ' + recordTypeId + ' does not exist or is not valid for object ' + config.objectApiName
                );
            }

            RecordType rt = recordTypes[0];

            if (!rt.IsActive) {
                System.debug(
                    LoggingLevel.WARN,
                    '[ActionCreateRecord] Attempting to use inactive RecordType: ' + rt.DeveloperName + ' (' + recordTypeId + ')'
                );
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'RecordType "' + rt.Name + '" (' + rt.DeveloperName + ') is not active and cannot be used for record creation'
                );
            }

            System.debug(
                LoggingLevel.DEBUG,
                '[ActionCreateRecord] RecordType validated: ' + rt.DeveloperName + ' (' + recordTypeId + ') for object ' + config.objectApiName
            );

            return ActionOutcome.success();
        } catch (System.QueryException qe) {
            // This could happen if user doesn't have access to RecordType object or the specific record
            String errorMsg = 'Unable to access RecordType ' + recordTypeId + '. ';
            if (qe.getMessage().containsIgnoreCase('insufficient access') || qe.getMessage().containsIgnoreCase('security')) {
                errorMsg += 'User may lack permission to access this RecordType.';
            } else {
                errorMsg += qe.getMessage();
            }
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] RecordType validation failed: ' + errorMsg);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, errorMsg);
        }
    }

    /**
     * @description
     * Result wrapper for successful record creation operations. Provides structured data for both user display and LLM processing.
     *
     * Fields:
     *   - recordId: String - The Salesforce record Id of the newly created record.
     *   - message: String - User-facing message summarizing the result.
     *   - fieldsSet: List<String> - List of fields that were set on the new record.
     *   - metadata: Map<String, Object> - Additional context for downstream consumers.
     */
    public class CreateResult {
        public String recordId;
        public String message; // Framework uses this for user display
        public List<String> fieldsSet;
        public Map<String, Object> metadata; // Additional context for LLMs

        public CreateResult(String recordId, String message, List<String> fieldsSet) {
            this.recordId = recordId;
            this.message = message;
            this.fieldsSet = fieldsSet;
            this.metadata = new Map<String, Object>{
                'recordId' => recordId,
                'fieldsSet' => fieldsSet.size(),
                'fieldNames' => fieldsSet,
                'creationSuccessful' => true
            };
        }
    }
}
