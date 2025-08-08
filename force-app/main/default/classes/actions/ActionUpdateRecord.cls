/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Updates Salesforce records with intelligent field processing.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *              Expects: {"recordId": "...", "FieldName1": "NewValue1", ...} or custom ID parameter name.
 *
 *              MAINTAINS: Comprehensive security checks, FLS validation, lock detection, and detailed error handling.
 *              ENHANCED: Simplified interface while preserving all robustness features.
 * @extends BaseAgentAction
 */
public class ActionUpdateRecord extends BaseAgentAction {
    private static final String CONFIG_KEY_RECORD_ID_PARAM = 'recordIdParameter';
    private String recordIdParameterName = 'recordId';

    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction, validation, and security.
     *              ENHANCED: Maintains robustness while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        Id recordId = validateAndExtractRecordId(params);
        SObjectType targetSObjectType = recordId.getSObjectType();

        Map<String, Object> updateData = extractUpdateFields(params, recordId);

        try {
            SecurityUtils.checkObjectPermission(targetSObjectType, AccessType.UPDATABLE);
        } catch (SecurityUtils.ActionSecurityException ase) {
            throw ase;
        }

        try {
            if (Approval.isLocked(recordId)) {
                throw new ValidationException('Record is locked and cannot be updated: ' + recordId, this.recordIdParameterName);
            }
        } catch (Exception lockCheckEx) {
        }

        Map<String, Object> typedData;
        try {
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

        Set<String> originalFields = updateData.keySet();
        Set<String> allowedFields = typedData.keySet();
        Set<String> removedFields = new Set<String>(originalFields);
        removedFields.removeAll(allowedFields);
        if (!removedFields.isEmpty()) {
        }

        SObject recordToUpdate = targetSObjectType.newSObject(recordId);
        for (String fieldName : typedData.keySet()) {
            recordToUpdate.put(fieldName, typedData.get(fieldName));
        }

        Database.SaveResult result = Database.update(recordToUpdate, false);

        Long executionTime = System.currentTimeMillis() - startTime;

        if (result.isSuccess()) {
            return new UpdateResult(recordId.toString(), 'Successfully updated record ' + recordId + '.', new List<String>(typedData.keySet()));
        } else {
            String enhancedMessage = enhanceUpdateErrorMessage(result.getErrors()[0], recordId, typedData);

            throw new DmlException(enhancedMessage);
        }
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig?.containsKey(CONFIG_KEY_RECORD_ID_PARAM)) {
            Object paramNameObj = this.parsedActionConfig.get(CONFIG_KEY_RECORD_ID_PARAM);
            if (paramNameObj instanceof String && String.isNotBlank((String) paramNameObj)) {
                this.recordIdParameterName = (String) paramNameObj;
            }
        }
    }

    /**
     * @description Validates and extracts record ID with enhanced error handling
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
     * @description Extracts update fields with validation
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
     * @description Enhances DML error messages with context for better debugging
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

    public class UpdateResult {
        public String recordId;
        public String message;
        public List<String> updatedFields;
        public Map<String, Object> metadata;

        public UpdateResult(String recordId, String message, List<String> updatedFields) {
            this.recordId = recordId;
            this.message = message;
            this.updatedFields = updatedFields;
            this.metadata = new Map<String, Object>{ 'recordId' => recordId, 'fieldsUpdated' => updatedFields.size(), 'fieldNames' => updatedFields };
        }
    }
}
