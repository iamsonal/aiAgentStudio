/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Standard Action: Updates a specific Salesforce record identified by ID.
 *              Extends BaseAgentAction for standardized execution flow and error handling.
 *              Expects flat argument structure from LLM: {"recordId": "...", "FieldName1": "NewValue1", ...}.
 *              Does not typically require ActionConfiguration.
 * @extends BaseAgentAction
 */
public class ActionUpdateRecord extends BaseAgentAction {
    private static final String ERR_CODE_INPUT = AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
    private static final String ERR_CODE_NOT_FOUND = AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND;
    private static final String ERR_CODE_PERMISSION = AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
    private static final String ERR_CODE_DML = AIAgentConstants.ERR_CODE_DML_ERROR;
    private static final String ERR_CODE_LOCKED = AIAgentConstants.ERR_CODE_RECORD_LOCKED;
    private static final String ERR_CODE_UNEXPECTED = AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;

    private static final String RECORD_ID_KEY = 'recordId';

    /**
     * @description Provides a specific log prefix for this action type.
     * @return String 'ActionUpdateRecord'
     */
    protected override String getLogPrefixName() {
        return 'ActionUpdateRecord';
    }

    /**
     * @description Parses the ActionConfiguration JSON. UpdateRecord generally doesn't need config,
     *              so this implementation is minimal. Override if config becomes necessary.
     * @param actionConfigurationJson The raw JSON string.
     * @param logPrefix Logging prefix.
     * @throws ValidationException if JSON is provided but invalid.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

    /**
     * @description Defines the structure for arguments specific to UpdateRecord.
     */
    class UpdateRecordParsedArguments extends BaseAgentAction.ParsedArguments {
        Id recordSObjectId;
        SObjectType targetSObjectType;
        Map<String, Object> updateData;

        public UpdateRecordParsedArguments(Id id, SObjectType objType, Map<String, Object> data) {
            this.recordSObjectId = id;
            this.targetSObjectType = objType;
            this.updateData = data;
        }
    }

    /**
     * @description Parses and validates the LLM arguments for UpdateRecord. Requires 'recordId' and fields to update.
     * @param argumentsJson Raw JSON string from the LLM (expected to be a map).
     * @param logPrefix Logging prefix.
     * @return UpdateRecordParsedArguments instance.
     * @throws ValidationException if arguments JSON is invalid, recordId is missing/invalid, or no update fields provided.
     */
    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        Map<String, Object> parsedLlmArgs;
        try {
            if (String.isBlank(argumentsJson)) {
                throw new ValidationException('Input arguments JSON cannot be blank for UpdateRecord.', null);
            }
            parsedLlmArgs = (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);

            if (parsedLlmArgs == null || parsedLlmArgs.isEmpty()) {
                throw new ValidationException('Input arguments map cannot be null or empty.', null);
            }
        } catch (Exception e) {
            throw new ValidationException('Failed to parse arguments JSON: ' + e.getMessage(), null);
        }

        String recordIdKeyFound = null;
        Object idObj = null;
        for (String key : parsedLlmArgs.keySet()) {
            if (RECORD_ID_KEY.equalsIgnoreCase(key)) {
                recordIdKeyFound = key;
                idObj = parsedLlmArgs.get(key);
                break;
            }
        }

        if (recordIdKeyFound == null) {
            throw new ValidationException('Missing required parameter: "' + RECORD_ID_KEY + '".', RECORD_ID_KEY);
        }

        if (!(idObj instanceof String) || String.isBlank((String) idObj)) {
            throw new ValidationException('Invalid value for "' + RECORD_ID_KEY + '": must be a non-blank string ID.', RECORD_ID_KEY);
        }
        String recordIdStr = (String) idObj;

        Id recordSObjectId;
        SObjectType targetSObjectType;
        try {
            recordSObjectId = Id.valueOf(recordIdStr);
            targetSObjectType = recordSObjectId.getSObjectType();
        } catch (System.StringException strEx) {
            throw new ValidationException('Invalid format for parameter "' + RECORD_ID_KEY + '": ' + recordIdStr, RECORD_ID_KEY);
        }

        Map<String, Object> updateData = new Map<String, Object>();
        for (String key : parsedLlmArgs.keySet()) {
            if (!key.equalsIgnoreCase(RECORD_ID_KEY)) {
                updateData.put(key, parsedLlmArgs.get(key));
            }
        }

        if (updateData.isEmpty()) {
            throw new ValidationException('No fields provided to update for record ID: ' + recordIdStr, null);
        }

        return new UpdateRecordParsedArguments(recordSObjectId, targetSObjectType, updateData);
    }

    /**
     * @description Core logic: prepares SObject with FLS checks, performs DML Update.
     * @param validatedArgs Parsed arguments (must be cast to UpdateRecordParsedArguments).
     * @param logPrefix Logging prefix.
     * @return ActionResult Result of the update operation.
     * @throws ActionSecurityException if user lacks necessary permissions.
     * @throws DmlException if DML fails (will be caught by base).
     */
    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        UpdateRecordParsedArguments args = (UpdateRecordParsedArguments) validatedArgs;
        SObject sObjectToUpdate;
        Map<String, Object> filteredData = null;

        try {
            SecurityUtils.checkObjectPermission(args.targetSObjectType, AccessType.UPDATABLE);

            try {
                filteredData = SObjectArgumentCoercionService.coerceArgumentTypesForSObject(
                    args.updateData,
                    args.targetSObjectType,
                    AccessType.UPDATABLE
                );
            } catch (SObjectArgumentCoercionService.InvalidArgumentTypeException typeEx) {
                throw new ValidationException(typeEx.getMessage(), null);
            } catch (SecurityUtils.ActionSecurityException secEx) {
                throw secEx;
            } catch (Exception coerceEx) {
                throw coerceEx;
            }

            if (filteredData.isEmpty()) {
                Set<String> originalFields = args.updateData.keySet();
                throw new SecurityUtils.ActionSecurityException(
                    'No updateable fields provided or permitted after security checks for record ' +
                        args.recordSObjectId +
                        '. Original fields: ' +
                        String.join(new List<String>(originalFields), ', ')
                );
            }

            Set<String> originalFields = args.updateData.keySet();
            Set<String> allowedFields = filteredData.keySet();
            Set<String> removedFields = new Set<String>(originalFields);
            removedFields.removeAll(allowedFields);
            if (!removedFields.isEmpty()) {
            }

            sObjectToUpdate = args.targetSObjectType.newSObject(args.recordSObjectId);
            for (String fieldName : filteredData.keySet()) {
                try {
                    sObjectToUpdate.put(fieldName, filteredData.get(fieldName));
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

        Database.SaveResult sr = Database.update(sObjectToUpdate, false);

        if (sr.isSuccess()) {
            String successMsg = 'Successfully updated record ' + args.recordSObjectId + '.';
            Map<String, Object> outputMap = new Map<String, Object>{ 'recordId' => args.recordSObjectId, 'message' => successMsg };
            String internalDetails =
                'Record updated. ID: ' +
                args.recordSObjectId +
                '. Fields updated: ' +
                String.join(new List<String>(filteredData.keySet()), ', ');

            return this.success(outputMap, internalDetails);
        } else {
            String primaryErrorCode = ERR_CODE_DML;
            if (!sr.getErrors().isEmpty()) {
                StatusCode sc = sr.getErrors()[0].getStatusCode();
                if (sc == StatusCode.UNABLE_TO_LOCK_ROW) {
                    primaryErrorCode = ERR_CODE_LOCKED;
                } else if (sc == StatusCode.INSUFFICIENT_ACCESS_OR_READONLY) {
                    primaryErrorCode = ERR_CODE_PERMISSION;
                }
            }
            return this.dmlError('Failed to update record ' + args.recordSObjectId + '.', sr.getErrors(), primaryErrorCode);
        }
    }
}
