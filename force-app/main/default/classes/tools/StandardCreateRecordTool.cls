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
 * Standard tool: create one record of the configured SObject type.
 *
 * Standard tool type CreateRecord.
 *
 * ImplementationConfiguration__c (operator-only, never sent to the model):
 *   {"objectApiName": "Account", "defaultFieldValues": {"Description": "Created by AI Agent"}}
 * Optional recordTypeDeveloperName gives every new record that record type.
 * A Fixed Field Value may name a run value, such as {"ParentId": ":anchorId"}
 * to tie each new record to the run's record (see ToolRunValues).
 *
 * Tool input (model-visible, governed by the tool InputSchema__c closed
 * schema): a recordData object of field values, for example
 *   {"recordData": {"Name": "Acme", "Industry": "Technology"}}
 *
 * Security: object and per-field createability are checked for the execution
 * principal before any write, and the insert runs in user mode so sharing
 * and FLS fail closed. Unknown or non-writable fields are rejected with an
 * instructive permanent error the model can correct.
 *
 * Recovery contract: the tool only writes this org's records, so its tool
 * type has no external effects and Core runs it in a savepoint:
 * a rejected or interrupted insert is rolled back and reaches the model as
 * a failed call, and a lost worker is safe to repeat.
 */
public inherited sharing class StandardCreateRecordTool implements ITool, IRequesterFilteredTool, IToolAuthoring {
    public AgentKernelModels.ToolResponse execute(AgentKernelModels.ToolRequest request) {
        Map<String, Object> config = StandardToolSupport.configuration(request == null ? null : request.implementationConfiguration);
        String objectApiName = StandardToolSupport.requiredConfig(config, 'objectApiName', 'objectApiName');
        Map<String, Object> input = StandardToolSupport.objectInput(request == null ? null : request.input, 'Tool input');
        StandardToolSupport.assertOnlyInputKeys(input, new Set<String>{ 'recorddata' });
        Map<String, Object> modelValues = StandardToolSupport.requiredObjectProperty(input, 'recordData', 'Tool input');
        Schema.SObjectType objectType = StandardToolSupport.resolveObject(objectApiName);
        Map<String, Object> values = StandardToolSupport.mergeDefaultFieldValues(
            StandardToolSupport.fixedFieldValues(config, objectType, request),
            modelValues
        );
        if (values.isEmpty()) {
            throw StandardToolSupport.permanent('Tool input and defaultFieldValues must include at least one field value.');
        }
        Schema.RecordTypeInfo recordType = StandardToolSupport.chosenRecordType(objectType, config);
        if (recordType != null && !recordType.isAvailable()) {
            throw StandardToolSupport.permanent(
                'The ' +
                    recordType.getDeveloperName() +
                    ' record type of ' +
                    objectType.getDescribe().getName() +
                    ' is not assigned to the agent\'s user. Assign it through that user\'s profile or a permission set.'
            );
        }
        assertAllowedFields(StandardToolSchemas.writableFields(config, objectType, true), modelValues.keySet());
        ToolSecurity.assertCreateable(objectType);
        // Operator defaults are the admin's choice; the fields the model sets must be ones the requester could set.
        ToolSecurity.assertRequesterCanCreate(request.principal, objectType, modelValues.keySet());
        String canonicalName = objectType.getDescribe().getName();
        Map<String, Schema.SObjectField> fields = StandardToolSupport.fieldMap(objectType);
        SObject record = objectType.newSObject();
        for (String name : values.keySet()) {
            String key = name == null ? '' : name.trim().toLowerCase();
            if (!fields.containsKey(key)) {
                throw StandardToolSupport.permanent('Unknown field: ' + canonicalName + '.' + name + '.');
            }
            Schema.DescribeFieldResult describe = fields.get(key).getDescribe();
            if (!describe.isCreateable()) {
                throw StandardToolSupport.permanent('Field is not writable by the execution principal: ' + canonicalName + '.' + describe.getName() + '.');
            }
            Object value = StandardToolSupport.coerceValue(describe.getType(), values.get(name), describe.getName());
            if (describe.getName().equalsIgnoreCase('RecordTypeId')) {
                StandardToolSupport.assertActiveRecordType(objectType, value, describe.getName());
            }
            record.put(describe.getName(), value);
        }
        if (recordType != null) {
            record.put('RecordTypeId', recordType.getRecordTypeId());
        }
        try {
            insert as user record;
        } catch (DmlException denied) {
            throw StandardToolSupport.dmlFailure(canonicalName, 'created', denied);
        } catch (Exception ambiguous) {
            throw new AgentKernelException.OutcomeUnknownException('The create outcome could not be confirmed.');
        }
        return StandardToolSupport.success(JSON.serialize(new Map<String, Object>{ 'id' => record.Id }));
    }

    public List<String> validateConfiguration(AgentKernelModels.ToolConfiguration configuration) {
        try {
            Map<String, Object> config = StandardToolSupport.configuration(configuration == null ? null : configuration.implementationConfiguration);
            Schema.SObjectType objectType = StandardToolSupport.resolveObject(StandardToolSupport.requiredConfig(config, 'objectApiName', 'objectApiName'));
            StandardToolSupport.assertFixedFieldValues(objectType, config, true);
            StandardToolSupport.chosenRecordType(objectType, config);
            StandardToolSchemas.writableFields(config, objectType, true);
            return new List<String>();
        } catch (Exception invalid) {
            return StandardToolSupport.problems(invalid);
        }
    }

    public AgentKernelModels.ToolAuthoring describe(AgentKernelModels.ToolConfiguration configuration) {
        AgentKernelModels.ToolAuthoring authoring = new AgentKernelModels.ToolAuthoring();
        authoring.settings = StandardToolSchemas.recordSettings(true);
        try {
            authoring.inputSchema = StandardToolSchemas.recordInputs(configuration == null ? null : configuration.implementationConfiguration, true);
        } catch (Exception notYetBuildable) {
            authoring.problem = notYetBuildable.getMessage();
        }
        return authoring;
    }

    /** The model may set only the fields the admin listed. */
    public static void assertAllowedFields(List<Schema.DescribeFieldResult> allowed, Set<String> requested) {
        Set<String> names = new Set<String>();
        List<String> labels = new List<String>();
        for (Schema.DescribeFieldResult field : allowed) {
            names.add(field.getName().toLowerCase());
            labels.add(field.getName());
        }
        for (String name : requested) {
            if (name == null || !names.contains(name.trim().toLowerCase())) {
                throw StandardToolSupport.permanent('This tool may not set ' + name + '. Allowed fields: ' + String.join(labels, ', ') + '.');
            }
        }
    }
}
