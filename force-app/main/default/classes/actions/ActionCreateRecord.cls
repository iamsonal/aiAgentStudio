/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionCreateRecord is a robust, extensible Apex action for creating Salesforce records with intelligent field processing and comprehensive security validation.
 *
 * Responsibilities:
 *   - Extracts and validates parameters for record creation, supporting both user-supplied and default field values.
 *   - Performs type coercion and field-level security (FLS) checks before DML operations.
 *   - Handles DML errors with enhanced, context-rich messages for troubleshooting.
 *   - Provides detailed debug output for security, field filtering, and performance analysis.
 *
 * Scope:
 *   - Focused on secure, flexible record creation for any SObject type specified in configuration.
 *   - Designed for maintainability and clarity, with clear extension points and runtime diagnostics.
 *
 * Configuration Example: {"objectApiName": "Contact", "defaultFieldValues": {"LeadSource": "Web"}}
 * Parameters: Field name-value pairs for the record to create.
 *
 * @extends BaseAgentAction
 */
public class ActionCreateRecord extends BaseAgentAction {
    private static final String CONFIG_KEY_OBJECT_API_NAME = 'objectApiName';
    private static final String CONFIG_KEY_DEFAULT_VALUES = 'defaultFieldValues';

    private String objectApiName;
    private SObjectType targetSObjectType;
    private Map<String, Object> defaultValues = new Map<String, Object>();

    /**
     * @description
     * Main entry point for record creation. Merges default and user-supplied field values, performs security and type validation,
     * and executes the DML insert. Returns a structured result or throws detailed exceptions on error.
     *
     * @param params Map<String, Object> - Field name-value pairs for the new record.
     * @return CreateResult - Contains the new record ID, message, and metadata.
     * @throws ValidationException if no field data is provided or if type coercion fails.
     * @throws ActionSecurityException if no creatable fields remain after FLS checks.
     * @throws DmlException if the DML operation fails.
     *
     * Side effects: Logs security, FLS, and performance information for audit and troubleshooting.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Merge default and user-supplied field values
        Map<String, Object> finalData = new Map<String, Object>();
        finalData.putAll(this.defaultValues);
        finalData.putAll(params);

        if (finalData.isEmpty()) {
            throw new ValidationException('No field data provided for record creation', null);
        }

        // Explicitly check object-level create permission
        try {
            SecurityUtils.checkObjectPermission(this.targetSObjectType, AccessType.CREATABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Security check failed for object ' + this.objectApiName + ': ' + ase.getMessage());
            throw ase;
        }

        // Coerce types and check field-level security (FLS)
        Map<String, Object> typedData;
        try {
            typedData = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(finalData, this.targetSObjectType, AccessType.CREATABLE);
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException typeEx) {
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Type coercion failed: ' + typeEx.getMessage());
            throw new ValidationException(typeEx.getMessage(), null);
        } catch (SecurityUtils.ActionSecurityException secEx) {
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Field-level security check failed: ' + secEx.getMessage());
            throw secEx;
        }

        if (typedData.isEmpty()) {
            Set<String> originalFields = finalData.keySet();
            System.debug(
                LoggingLevel.WARN,
                '[ActionCreateRecord] All provided fields were filtered out by FLS. Original fields: ' +
                String.join(new List<String>(originalFields), ', ')
            );
            throw new ActionSecurityException(
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

        // Insert the record and handle DML errors
        Database.SaveResult result = Database.insert(newRecord, false);

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(LoggingLevel.INFO, '[ActionCreateRecord] Record creation for ' + this.objectApiName + ' completed in ' + executionTime + ' ms.');

        if (result.isSuccess()) {
            System.debug(LoggingLevel.DEBUG, '[ActionCreateRecord] Successfully created record with ID: ' + result.getId());
            return new CreateResult(
                result.getId(),
                'Successfully created ' + this.objectApiName + ' record with ID ' + result.getId() + '.',
                new List<String>(typedData.keySet())
            );
        } else {
            String enhancedMessage = enhanceCreateErrorMessage(result.getErrors()[0], typedData);
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Record creation failed for ' + this.objectApiName + ': ' + enhancedMessage);
            throw new DmlException(enhancedMessage);
        }
    }

    /**
     * @description
     * Parses and validates the action configuration JSON. Extracts the target SObject type and any default field values.
     * Logs the number of default values loaded for transparency.
     *
     * @param actionConfigurationJson String - The JSON configuration string.
     * @param logPrefix String - Prefix for log output.
     * @throws ValidationException if required configuration is missing or invalid.
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        this.objectApiName = ActionConfigUtils.getRequiredString(this.parsedActionConfig, CONFIG_KEY_OBJECT_API_NAME);

        this.targetSObjectType = SchemaUtils.getSObjectType(this.objectApiName);
        if (this.targetSObjectType == null) {
            throw new ValidationException('Invalid SObject API Name in configuration: ' + this.objectApiName, CONFIG_KEY_OBJECT_API_NAME);
        }

        this.defaultValues = ActionConfigUtils.getOptionalMap(this.parsedActionConfig, CONFIG_KEY_DEFAULT_VALUES);

        if (!this.defaultValues.isEmpty()) {
            System.debug(
                LoggingLevel.DEBUG,
                '[ActionCreateRecord] Loaded ' + this.defaultValues.size() + ' default field values from configuration.'
            );
        }
    }

    /**
     * @description
     * Enhances DML error messages with contextual information for better troubleshooting.
     *
     * @param error Database.Error - The error from the failed DML operation.
     * @param typedData Map<String, Object> - The field data that was attempted to be inserted.
     * @return String - Enhanced error message with context and field information.
     */
    private String enhanceCreateErrorMessage(Database.Error error, Map<String, Object> typedData) {
        String enhanced = 'Failed to create ' + this.objectApiName + ' record: ' + error.getMessage();

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
