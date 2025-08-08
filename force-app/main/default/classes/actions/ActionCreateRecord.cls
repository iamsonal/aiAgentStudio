/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Creates Salesforce records with intelligent field processing.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *              ActionConfiguration example: {"objectApiName": "Contact", "defaultFieldValues": {"LeadSource": "Web"}}
 *
 *              MAINTAINS: Comprehensive security checks, FLS validation, and detailed error handling.
 *              ENHANCED: Simplified interface while preserving all robustness features.
 * @extends BaseAgentAction
 */
public class ActionCreateRecord extends BaseAgentAction {
    private static final String CONFIG_KEY_OBJECT_API_NAME = 'objectApiName';
    private static final String CONFIG_KEY_DEFAULT_VALUES = 'defaultFieldValues';

    private String objectApiName;
    private SObjectType targetSObjectType;
    private Map<String, Object> defaultValues = new Map<String, Object>();

    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction, validation, and security.
     *              ENHANCED: Maintains comprehensive security and validation while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        Map<String, Object> finalData = new Map<String, Object>();
        finalData.putAll(this.defaultValues);
        finalData.putAll(params);

        if (finalData.isEmpty()) {
            throw new ValidationException('No field data provided for record creation', null);
        }

        try {
            SecurityUtils.checkObjectPermission(this.targetSObjectType, AccessType.CREATABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
            throw ase;
        }

        Map<String, Object> typedData;
        try {
            typedData = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(finalData, this.targetSObjectType, AccessType.CREATABLE);
        } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException typeEx) {
            throw new ValidationException(typeEx.getMessage(), null);
        } catch (SecurityUtils.ActionSecurityException secEx) {
            throw secEx;
        }

        if (typedData.isEmpty()) {
            Set<String> originalFields = finalData.keySet();
            throw new ActionSecurityException(
                'No creatable fields provided after security checks. Original fields: ' + String.join(new List<String>(originalFields), ', ')
            );
        }

        Set<String> originalFields = finalData.keySet();
        Set<String> allowedFields = typedData.keySet();
        Set<String> removedFields = new Set<String>(originalFields);
        removedFields.removeAll(allowedFields);
        if (!removedFields.isEmpty()) {
        }

        SObject newRecord = this.targetSObjectType.newSObject();
        for (String fieldName : typedData.keySet()) {
            newRecord.put(fieldName, typedData.get(fieldName));
        }

        Database.SaveResult result = Database.insert(newRecord, false);

        Long executionTime = System.currentTimeMillis() - startTime;

        if (result.isSuccess()) {
            return new CreateResult(
                result.getId(),
                'Successfully created ' + this.objectApiName + ' record with ID ' + result.getId() + '.',
                new List<String>(typedData.keySet())
            );
        } else {
            String enhancedMessage = enhanceCreateErrorMessage(result.getErrors()[0], typedData);

            throw new DmlException(enhancedMessage);
        }
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (!this.parsedActionConfig.containsKey(CONFIG_KEY_OBJECT_API_NAME)) {
            throw new ValidationException('ActionConfiguration must contain "' + CONFIG_KEY_OBJECT_API_NAME + '"', CONFIG_KEY_OBJECT_API_NAME);
        }

        this.objectApiName = (String) this.parsedActionConfig.get(CONFIG_KEY_OBJECT_API_NAME);
        if (String.isBlank(this.objectApiName)) {
            throw new ValidationException('objectApiName cannot be blank', CONFIG_KEY_OBJECT_API_NAME);
        }

        this.targetSObjectType = Schema.getGlobalDescribe().get(this.objectApiName.toLowerCase());
        if (this.targetSObjectType == null) {
            throw new ValidationException('Invalid SObject API Name: ' + this.objectApiName, CONFIG_KEY_OBJECT_API_NAME);
        }

        if (this.parsedActionConfig.containsKey(CONFIG_KEY_DEFAULT_VALUES)) {
            Object defaultsObj = this.parsedActionConfig.get(CONFIG_KEY_DEFAULT_VALUES);
            if (defaultsObj instanceof Map<String, Object>) {
                this.defaultValues = (Map<String, Object>) defaultsObj;
            }
        }
    }

    /**
     * @description Enhances DML error messages with context for better debugging
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

    public class CreateResult {
        public String recordId;
        public String message;
        public List<String> fieldsSet;
        public Map<String, Object> metadata;

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
