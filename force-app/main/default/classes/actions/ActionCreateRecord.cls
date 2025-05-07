/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Standard Action: Creates a Salesforce record of a type specified in the Action Configuration.
 *              Extends BaseAgentAction for standardized execution flow and error handling.
 *              Expects flat argument structure from LLM. Uses FrameworkUtils for security and type coercion.
 * @extends BaseAgentAction
 */
public class ActionCreateRecord extends BaseAgentAction {
    private static final String CONFIG_KEY_OBJECT_API_NAME = 'objectApiName';
    private static final String CONFIG_KEY_DEFAULT_VALUES = 'defaultFieldValues';

    private static final String ERR_CODE_CONFIG = AIAgentConstants.ERR_CODE_CONFIG_ERROR;
    private static final String ERR_CODE_INPUT = AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
    private static final String ERR_CODE_PERMISSION = AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
    private static final String ERR_CODE_DML = AIAgentConstants.ERR_CODE_DML_ERROR;
    private static final String ERR_CODE_UNEXPECTED = AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;

    private String objectApiName;
    private SObjectType targetSObjectType;
    private Map<String, Object> defaultValues = new Map<String, Object>();

    /**
     * @description Provides a specific log prefix for this action type.
     * @return String 'ActionCreateRecord'
     */
    protected override String getLogPrefixName() {
        return 'ActionCreateRecord';
    }

    /**
     * @description Parses the ActionConfiguration JSON required for CreateRecord (objectApiName, optional defaultValues).
     * @param actionConfigurationJson The raw JSON string.
     * @param logPrefix Logging prefix.
     * @throws ValidationException if JSON is invalid or required config 'objectApiName' is missing/invalid.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig == null || !this.parsedActionConfig.containsKey(CONFIG_KEY_OBJECT_API_NAME)) {
            throw new ValidationException(
                'ActionConfiguration JSON is required and must contain "' + CONFIG_KEY_OBJECT_API_NAME + '".',
                CONFIG_KEY_OBJECT_API_NAME
            );
        }

        Object apiNameObj = this.parsedActionConfig.get(CONFIG_KEY_OBJECT_API_NAME);
        if (!(apiNameObj instanceof String) || String.isBlank((String) apiNameObj)) {
            throw new ValidationException(
                'Required property "' + CONFIG_KEY_OBJECT_API_NAME + '" in ActionConfiguration must be a non-blank String.',
                CONFIG_KEY_OBJECT_API_NAME
            );
        }
        this.objectApiName = (String) apiNameObj;

        this.targetSObjectType = Schema.getGlobalDescribe().get(this.objectApiName.toLowerCase());
        if (this.targetSObjectType == null) {
            throw new ValidationException('Invalid SObject API Name configured: ' + this.objectApiName, CONFIG_KEY_OBJECT_API_NAME);
        }

        if (this.parsedActionConfig.get(CONFIG_KEY_DEFAULT_VALUES) instanceof Map<String, Object>) {
            this.defaultValues = (Map<String, Object>) this.parsedActionConfig.get(CONFIG_KEY_DEFAULT_VALUES);
        }
    }

    /**
     * @description Defines the structure for arguments specific to CreateRecord.
     */
    class CreateRecordParsedArguments extends BaseAgentAction.ParsedArguments {
        Map<String, Object> llmRecordData;

        public CreateRecordParsedArguments(Map<String, Object> data) {
            this.llmRecordData = data;
        }
    }

    /**
     * @description Parses and validates the LLM arguments (the fields/values for the new record).
     * @param argumentsJson Raw JSON string from the LLM (expected to be a map).
     * @param logPrefix Logging prefix.
     * @return CreateRecordParsedArguments instance.
     * @throws ValidationException if arguments JSON is invalid or empty (when no defaults exist).
     */
    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        Map<String, Object> llmRecordData;
        try {
            if (String.isBlank(argumentsJson)) {
                throw new ValidationException('Input arguments JSON cannot be blank for CreateRecord.', null);
            }
            llmRecordData = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);

            if (llmRecordData == null) {
                throw new ValidationException('Input arguments map cannot be null for CreateRecord.', null);
            }
        } catch (Exception e) {
            throw new ValidationException(
                'Failed to parse or validate input arguments JSON: ' + e.getMessage() + '. Received JSON: ' + argumentsJson,
                null
            );
        }
        return new CreateRecordParsedArguments(llmRecordData);
    }

    /**
     * @description Core logic: prepares SObject with merged defaults/LLM args, applies security, performs DML Insert.
     * @param validatedArgs Parsed arguments (must be cast to CreateRecordParsedArguments).
     * @param logPrefix Logging prefix.
     * @return ActionResult Result of the create operation.
     * @throws ActionSecurityException if user lacks necessary permissions.
     * @throws DmlException if DML fails (will be caught by base).
     */
    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        CreateRecordParsedArguments args = (CreateRecordParsedArguments) validatedArgs;
        SObject newSObject;
        Map<String, Object> finalDataToSet = new Map<String, Object>();
        Map<String, Object> filteredData = null;

        try {
            finalDataToSet.putAll(this.defaultValues);
            finalDataToSet.putAll(args.llmRecordData);

            if (finalDataToSet.isEmpty()) {
                throw new ValidationException('No field data provided after combining defaults and input.', null);
            }

            SecurityUtils.checkObjectPermission(this.targetSObjectType, AccessType.CREATABLE);

            Map<String, Object> typedData;
            try {
                typedData = ActionParamUtils.coerceArgumentTypesForSObject(finalDataToSet, this.targetSObjectType, AccessType.CREATABLE);
            } catch (ActionParamUtils.InvalidArgumentTypeException typeEx) {
                throw new ValidationException(typeEx.getMessage(), null);
            } catch (SecurityUtils.ActionSecurityException secEx) {
                throw secEx;
            } catch (Exception coerceEx) {
                throw coerceEx;
            }

            filteredData = typedData;

            if (filteredData.isEmpty()) {
                String msg = 'No creatable fields provided/permitted after combining defaults, input, and FLS checks.';

                throw new SecurityUtils.ActionSecurityException(msg);
            }

            newSObject = this.targetSObjectType.newSObject();
            for (String fieldName : filteredData.keySet()) {
                try {
                    newSObject.put(fieldName, filteredData.get(fieldName));
                } catch (Exception putEx) {
                    throw putEx;
                }
            }
        } catch (SecurityUtils.ActionSecurityException se) {
            throw se;
        } catch (ValidationException ve) {
            throw ve;
        } catch (Exception prepEx) {
            throw prepEx;
        }

        Database.SaveResult sr = Database.insert(newSObject, false);

        if (sr.isSuccess()) {
            String newRecordId = sr.getId();
            String successMsg = 'Successfully created ' + this.objectApiName + ' record.';
            Map<String, Object> outputMap = new Map<String, Object>{ 'recordId' => newRecordId, 'message' => successMsg };
            String internalDetails =
                'Record created. ID: ' +
                newRecordId +
                '. Fields Set: ' +
                String.join(new List<String>(filteredData.keySet()), ', ');

            return this.success(outputMap, internalDetails);
        } else {
            return this.dmlError('Failed to create ' + this.objectApiName + ' record.', sr.getErrors(), ERR_CODE_DML);
        }
    }
}
