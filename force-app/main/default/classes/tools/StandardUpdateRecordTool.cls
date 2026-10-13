/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * Standard tool: update one record of the configured SObject type.
 *
 * Standard tool type UpdateRecord.
 *
 * ImplementationConfiguration__c (operator-only, never sent to the model):
 *   {"objectApiName": "Case", "fields": ["Priority"], "anchorRecordOnly": true,
 *    "defaultFieldValues": {"OwnerId": ":initiatingUserId"}}
 * "anchorRecordOnly": true updates only the run's anchor record, and the
 * model supplies only recordData. Use it for agents that read customer text,
 * which could otherwise steer the agent to another record. A Fixed Field
 * Value may name a run value, such as :initiatingUserId (see ToolRunValues).
 *
 * Tool input (model-visible, governed by the tool InputSchema__c closed
 * schema): the record id plus a recordData object of field values, for example
 *   {"recordId": "500...", "recordData": {"Priority": "High"}}
 *
 * Security: the record is read first in user mode (missing or invisible
 * records fail as permanent errors), then object and per-field
 * updateability are checked for the execution principal, and the update
 * runs in user mode so sharing and FLS fail closed.
 *
 * Recovery contract: the tool only writes this org's records, so its tool
 * type has no external effects and Core runs it in a savepoint:
 * a rejected or interrupted update is rolled back and reaches the model as
 * a failed call, and a lost worker is safe to repeat.
 */
public inherited sharing class StandardUpdateRecordTool implements ITool, IRequesterFilteredTool, IToolAuthoring {
    public AgentKernelModels.ToolResponse execute(AgentKernelModels.ToolRequest request) {
        Map<String, Object> config = StandardToolSupport.configuration(request == null ? null : request.implementationConfiguration);
        String objectApiName = StandardToolSupport.requiredConfig(config, 'objectApiName', 'objectApiName');
        Boolean anchorOnly = StandardToolSupport.anchorRecordOnly(config);
        Map<String, Object> input = StandardToolSupport.objectInput(request == null ? null : request.input, 'Tool input');
        StandardToolSupport.assertOnlyInputKeys(input, anchorOnly ? new Set<String>{ 'recorddata' } : new Set<String>{ 'recordid', 'recorddata' });
        Map<String, Object> modelValues = StandardToolSupport.requiredObjectProperty(input, 'recordData', 'Tool input');
        Schema.SObjectType objectType = StandardToolSupport.resolveObject(objectApiName);
        Map<String, Object> values = StandardToolSupport.mergeDefaultFieldValues(
            StandardToolSupport.fixedFieldValues(config, objectType, request),
            modelValues
        );
        if (values.isEmpty()) {
            throw StandardToolSupport.permanent('Tool input and defaultFieldValues must include at least one field value besides recordId.');
        }
        Id recordId = anchorOnly ? StandardToolSupport.anchorRecordId(request, objectType) : modelRecordId(input);
        StandardCreateRecordTool.assertAllowedFields(StandardToolSchemas.writableFields(config, objectType, false), modelValues.keySet());
        ToolSecurity.assertUpdateable(objectType);
        String canonicalName = objectType.getDescribe().getName();
        List<SObject> existing = Database.queryWithBinds(
            'SELECT Id FROM ' + canonicalName + ' WHERE Id = :recordId LIMIT 1',
            new Map<String, Object>{ 'recordId' => recordId },
            AccessLevel.USER_MODE
        );
        if (existing.isEmpty()) {
            throw StandardToolSupport.permanent('The ' + canonicalName + ' record was not found or is not visible to the execution principal.');
        }
        // Operator defaults are the admin's choice; the fields the model sets must be ones the requester could change.
        ToolSecurity.assertRequesterCanEdit(request.principal, recordId, modelValues.keySet());
        Map<String, Schema.SObjectField> fields = StandardToolSupport.fieldMap(objectType);
        SObject record = objectType.newSObject();
        record.put('Id', recordId);
        for (String name : values.keySet()) {
            String key = name == null ? '' : name.trim().toLowerCase();
            if (!fields.containsKey(key)) {
                throw StandardToolSupport.permanent('Unknown field: ' + canonicalName + '.' + key + '.');
            }
            Schema.DescribeFieldResult describe = fields.get(key).getDescribe();
            if (!describe.isUpdateable()) {
                throw StandardToolSupport.permanent('Field is not writable by the execution principal: ' + canonicalName + '.' + describe.getName() + '.');
            }
            Object value = StandardToolSupport.coerceValue(describe.getType(), values.get(name), describe.getName());
            if (describe.getName().equalsIgnoreCase('RecordTypeId')) {
                StandardToolSupport.assertActiveRecordType(objectType, value, describe.getName());
            }
            record.put(describe.getName(), value);
        }
        try {
            update as user record;
        } catch (DmlException denied) {
            throw StandardToolSupport.dmlFailure(canonicalName, 'updated', denied);
        } catch (Exception ambiguous) {
            throw new AgentKernelException.OutcomeUnknownException('The update outcome could not be confirmed.');
        }
        return StandardToolSupport.success(JSON.serialize(new Map<String, Object>{ 'id' => record.Id }));
    }

    public List<String> validateConfiguration(AgentKernelModels.ToolConfiguration configuration) {
        try {
            Map<String, Object> config = StandardToolSupport.configuration(configuration == null ? null : configuration.implementationConfiguration);
            Schema.SObjectType objectType = StandardToolSupport.resolveObject(StandardToolSupport.requiredConfig(config, 'objectApiName', 'objectApiName'));
            StandardToolSupport.anchorRecordOnly(config);
            StandardToolSupport.assertFixedFieldValues(objectType, config, false);
            StandardToolSchemas.writableFields(config, objectType, false);
            return new List<String>();
        } catch (Exception invalid) {
            return StandardToolSupport.problems(invalid);
        }
    }

    public AgentKernelModels.ToolAuthoring describe(AgentKernelModels.ToolConfiguration configuration) {
        AgentKernelModels.ToolAuthoring authoring = new AgentKernelModels.ToolAuthoring();
        authoring.settings = StandardToolSchemas.recordSettings(false);
        try {
            authoring.inputSchema = StandardToolSchemas.recordInputs(configuration == null ? null : configuration.implementationConfiguration, false);
        } catch (Exception notYetBuildable) {
            authoring.problem = notYetBuildable.getMessage();
        }
        return authoring;
    }

    private static Id modelRecordId(Map<String, Object> input) {
        String recordIdText = StandardToolSupport.stringOf(input.get('recordId'));
        if (String.isBlank(recordIdText)) {
            throw StandardToolSupport.permanent('Tool input must include recordId.');
        }
        try {
            return (Id) recordIdText.trim();
        } catch (Exception invalidId) {
            throw StandardToolSupport.permanent('Tool input recordId is invalid.');
        }
    }
}
