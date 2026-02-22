/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Creates Salesforce records with FLS checks and validation.
 * @ActionLabel Create Record
 * @ActionDescription Creates a new Salesforce record with field-level security checks and validation
 * @ActionRequiresSObject true
 * @ActionIsActive true
 * @extends BaseAgentAction
 */
public with sharing class ActionCreateRecord extends BaseAgentAction {
    private ConfigDTO config;
    private SObjectType targetSObjectType;
    @TestVisible
    private static Map<String, NameFieldInfo> nameFieldInfoCache = new Map<String, NameFieldInfo>();
    @TestVisible
    private static List<RecordType> mockRecordTypeQueryResult;

    @TestVisible
    private class NameFieldInfo {
        public String apiName;
        public String label;

        public NameFieldInfo(String apiName, String label) {
            this.apiName = apiName;
            this.label = label;
        }
    }

    public class ArgumentsDTO {
        /**
         * @FieldLabel Record Data
         * @FieldType object
         * @FieldRequired true
         * @FieldHelp Field names and values for the record to create
         */
        public Map<String, Object> recordData;
    }

    public class ConfigDTO {
        /**
         * @FieldLabel Object API Name
         * @FieldType string
         * @FieldRequired true
         * @FieldPlaceholder Account
         * @FieldHelp The API name of the SObject to create (e.g., Account, Contact, CustomObject__c)
         */
        public String objectApiName;

        /**
         * @FieldLabel Default Field Values
         * @FieldType object
         * @FieldHelp Optional default values to set on all created records
         */
        public Map<String, Object> defaultFieldValues;
    }

    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        ArgumentsDTO args = new ArgumentsDTO();
        if (params.containsKey('recordData') && params.get('recordData') instanceof Map<String, Object>) {
            args.recordData = (Map<String, Object>) params.get('recordData');
        } else {
            args.recordData = params;
        }
        Map<String, Object> finalData = new Map<String, Object>();
        if (config.defaultFieldValues != null) {
            finalData.putAll(config.defaultFieldValues);
        }
        if (!args.recordData.isEmpty()) {
            finalData.putAll(args.recordData);
        }

        if (finalData.isEmpty()) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'No field data provided for record creation');
        }

        if (finalData.containsKey('RecordTypeId') && finalData.get('RecordTypeId') != null) {
            ActionOutcome rtValidation = validateRecordTypeAccess(finalData.get('RecordTypeId'));
            if (!rtValidation.isSuccess) {
                return rtValidation;
            }
        }

        try {
            Utils.checkObjectPermission(this.targetSObjectType, AccessType.CREATABLE);
        } catch (Utils.ActionSecurityException ase) {
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Security check failed for object ' + config.objectApiName + ': ' + ase.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ase.getMessage());
        }

        Map<String, Object> typedData;
        try {
            typedData = TypeCoercionService.coerceArgumentTypesForSObject(finalData, this.targetSObjectType, AccessType.CREATABLE);
        } catch (TypeCoercionService.TypeCoercionException typeEx) {
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Type coercion failed: ' + typeEx.getMessage());
            if (String.isNotBlank(typeEx.correctionGuidance)) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, typeEx.getMessage(), typeEx.correctionGuidance);
            }
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, typeEx.getMessage());
        } catch (Utils.ActionSecurityException secEx) {
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Field-level security check failed: ' + secEx.getMessage());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, secEx.getMessage());
        }

        if (typedData.isEmpty()) {
            Set<String> originalFields = finalData.keySet();
            System.debug(
                LoggingLevel.WARN,
                '[ActionCreateRecord] All provided fields were filtered out by FLS. Original fields: ' + String.join(new List<String>(originalFields), ', ')
            );
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                'No creatable fields provided after security checks. Original fields: ' + String.join(new List<String>(originalFields), ', ')
            );
        }

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

        SObject newRecord = this.targetSObjectType.newSObject();
        for (String fieldName : typedData.keySet()) {
            newRecord.put(fieldName, typedData.get(fieldName));
        }

        SObjectAccessDecision decision = Security.stripInaccessible(AccessType.CREATABLE, new List<SObject>{ newRecord });

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

        Database.SaveResult saveResult = Database.insert(decision.getRecords()[0], false, AccessLevel.USER_MODE);

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(LoggingLevel.INFO, '[ActionCreateRecord] Record creation for ' + config.objectApiName + ' completed in ' + executionTime + ' ms.');

        if (saveResult.isSuccess()) {
            System.debug(LoggingLevel.DEBUG, '[ActionCreateRecord] Successfully created record with ID: ' + saveResult.getId());

            Map<String, String> nameFieldInfo = queryNameFieldWithLabel(saveResult.getId());
            String nameFieldValue = nameFieldInfo?.get('value');
            String nameFieldLabel = nameFieldInfo?.get('label');

            String successMessage = 'Successfully created ' + config.objectApiName + ' record with ID ' + saveResult.getId();
            if (String.isNotBlank(nameFieldValue) && String.isNotBlank(nameFieldLabel)) {
                successMessage += ' (' + nameFieldLabel + ': ' + nameFieldValue + ')';
            } else if (String.isNotBlank(nameFieldValue)) {
                successMessage += ' (' + nameFieldValue + ')';
            }
            successMessage += '.';

            return ActionOutcome.success(
                new CreateResult(saveResult.getId(), successMessage, new List<String>(typedData.keySet()), nameFieldValue, nameFieldLabel)
            );
        } else {
            String enhancedMessage = enhanceCreateErrorMessage(saveResult.getErrors()[0], typedData);
            System.debug(LoggingLevel.ERROR, '[ActionCreateRecord] Record creation failed for ' + config.objectApiName + ': ' + enhancedMessage);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_DML_ERROR, enhancedMessage);
        }
    }

    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        try {
            if (String.isBlank(actionConfigurationJson)) {
                throw new ValidationException('Configuration JSON is required', null);
            }

            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

            this.config = new ConfigDTO();
            this.config.objectApiName = (String) configMap.get('objectApiName');

            Object defaultFieldsObj = configMap.get('defaultFieldValues');
            if (defaultFieldsObj instanceof Map<String, Object>) {
                this.config.defaultFieldValues = (Map<String, Object>) defaultFieldsObj;
            } else {
                this.config.defaultFieldValues = new Map<String, Object>();
            }
        } catch (Exception e) {
            throw new ValidationException('Invalid configuration JSON: ' + e.getMessage(), null, e);
        }

        if (String.isBlank(config.objectApiName)) {
            throw new ValidationException('objectApiName is required in configuration', 'objectApiName');
        }

        this.targetSObjectType = Utils.getSObjectType(config.objectApiName);
        if (this.targetSObjectType == null) {
            throw new ValidationException('Invalid SObject API Name in configuration: ' + config.objectApiName, 'objectApiName');
        }

        if (config.defaultFieldValues == null) {
            config.defaultFieldValues = new Map<String, Object>();
        }

        if (!config.defaultFieldValues.isEmpty()) {
            System.debug(LoggingLevel.DEBUG, '[ActionCreateRecord] Loaded ' + config.defaultFieldValues.size() + ' default field values from configuration.');
        }
    }

    @SuppressWarnings('PMD.ApexSOQLInjection')
    private Map<String, String> queryNameFieldWithLabel(Id recordId) {
        try {
            String cacheKey = String.isNotBlank(config.objectApiName) ? config.objectApiName.toLowerCase() : null;
            String nameFieldApiName;
            String nameFieldLabel;

            if (cacheKey != null && nameFieldInfoCache.containsKey(cacheKey)) {
                NameFieldInfo cachedInfo = nameFieldInfoCache.get(cacheKey);
                if (cachedInfo == null) {
                    System.debug(LoggingLevel.DEBUG, '[ActionCreateRecord] Name field cache hit (null) for object: ' + config.objectApiName);
                    return null;
                }
                nameFieldApiName = cachedInfo.apiName;
                nameFieldLabel = cachedInfo.label;
            } else {
                List<String> objectNames = new List<String>{ config.objectApiName };
                List<FieldDefinition> nameFields = [
                    SELECT QualifiedApiName, Label
                    FROM FieldDefinition
                    WHERE EntityDefinition.QualifiedApiName IN :objectNames AND IsNameField = TRUE
                    LIMIT 1
                ];

                if (nameFields.isEmpty()) {
                    System.debug(LoggingLevel.DEBUG, '[ActionCreateRecord] No Name field found for object: ' + config.objectApiName);
                    if (cacheKey != null) {
                        nameFieldInfoCache.put(cacheKey, null);
                    }
                    return null;
                }

                nameFieldApiName = nameFields[0].QualifiedApiName;
                nameFieldLabel = nameFields[0].Label;
                if (cacheKey != null) {
                    nameFieldInfoCache.put(cacheKey, new NameFieldInfo(nameFieldApiName, nameFieldLabel));
                }
            }

            String soql = 'SELECT ' + nameFieldApiName + ' FROM ' + config.objectApiName + ' WHERE Id = :recordId WITH USER_MODE LIMIT 1';
            List<SObject> records = Database.query(soql);

            if (!records.isEmpty() && records[0].get(nameFieldApiName) != null) {
                return new Map<String, String>{ 'value' => String.valueOf(records[0].get(nameFieldApiName)), 'label' => nameFieldLabel };
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ActionCreateRecord] Failed to query Name field: ' + e.getMessage());
        }

        return null;
    }

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

    private ActionOutcome validateRecordTypeAccess(Object recordTypeIdObj) {
        Id recordTypeId;

        try {
            if (recordTypeIdObj instanceof Id) {
                recordTypeId = (Id) recordTypeIdObj;
            } else if (recordTypeIdObj instanceof String) {
                recordTypeId = Id.valueOf((String) recordTypeIdObj);
            } else {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'RecordTypeId must be a valid Salesforce ID',
                    'Expected: 18-character Salesforce ID (e.g., 012000000000001AAA) or 15-character ID (e.g., 012000000000001)'
                );
            }
        } catch (Exception e) {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                'Invalid RecordTypeId format: ' + recordTypeIdObj,
                'Expected: 18-character Salesforce ID (e.g., 012000000000001AAA) or 15-character ID (e.g., 012000000000001)'
            );
        }

        String sObjectTypeName = recordTypeId.getSObjectType().getDescribe().getName();
        if (sObjectTypeName != 'RecordType') {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'The provided ID is not a RecordType ID: ' + recordTypeId);
        }

        try {
            List<RecordType> recordTypes;
            if (Test.isRunningTest() && mockRecordTypeQueryResult != null) {
                recordTypes = mockRecordTypeQueryResult;
            } else {
                recordTypes = [
                    SELECT Id, DeveloperName, Name, IsActive
                    FROM RecordType
                    WHERE Id = :recordTypeId AND SObjectType = :config.objectApiName
                    WITH USER_MODE
                    LIMIT 1
                ];
            }

            if (recordTypes.isEmpty()) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'RecordType ' + recordTypeId + ' does not exist or is not valid for object ' + config.objectApiName
                );
            }

            RecordType rt = recordTypes[0];

            if (!rt.IsActive) {
                System.debug(LoggingLevel.WARN, '[ActionCreateRecord] Attempting to use inactive RecordType: ' + rt.DeveloperName + ' (' + recordTypeId + ')');
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

    public class CreateResult {
        public String recordId;
        public String message; // Framework uses this for user display
        public List<String> fieldsSet;
        public String recordName; // Name field value (e.g., Case Number, Account Name)
        public String recordNameLabel; // Name field label (e.g., "Case Number", "Account Name")
        public Map<String, Object> metadata; // Additional context for LLMs

        public CreateResult(String recordId, String message, List<String> fieldsSet, String recordName, String recordNameLabel) {
            this.recordId = recordId;
            this.message = message;
            this.fieldsSet = fieldsSet;
            this.recordName = recordName;
            this.recordNameLabel = recordNameLabel;
            this.metadata = new Map<String, Object>{
                'recordId' => recordId,
                'recordName' => recordName,
                'recordNameLabel' => recordNameLabel,
                'fieldsSet' => fieldsSet.size(),
                'fieldNames' => fieldsSet,
                'creationSuccessful' => true
            };
        }
    }
}
