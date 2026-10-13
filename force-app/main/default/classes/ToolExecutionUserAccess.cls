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
 * Checks that an agent's execution user can read, create,
 * or edit what a standard record tool's configuration names. Runs when a tool
 * is saved and in the Validate report, so a missing permission shows up at
 * setup instead of failing the tool in a run. Custom Apex and Flow tools are
 * not checked: Core cannot see what they read. Agents without an identity are not
 * checked: nobody knows in advance who will run them.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ToolExecutionUserAccess {
    private static final String QUERY_RECORDS = 'StandardQueryRecordsTool';
    private static final String CREATE_RECORD = 'StandardCreateRecordTool';
    private static final String UPDATE_RECORD = 'StandardUpdateRecordTool';

    /** The active execution user of each agent with an identity among the ids; agents without one are left out. */
    public static Map<Id, User> executionUsers(Set<Id> definitionIds) {
        Map<Id, User> result = new Map<Id, User>();
        if (definitionIds == null || definitionIds.isEmpty()) {
            return result;
        }
        Map<Id, Id> identityByDefinition = new Map<Id, Id>();
        for (AgentDefinition__c definition : [
            SELECT Id, ExecutionIdentity__c
            FROM AgentDefinition__c
            WHERE Id IN :definitionIds
            WITH SYSTEM_MODE
        ]) {
            if (ExecutionIdentityService.usesIdentity(definition)) {
                identityByDefinition.put(definition.Id, definition.ExecutionIdentity__c);
            }
        }
        if (identityByDefinition.isEmpty()) {
            return result;
        }
        Map<Id, User> userByIdentity = new Map<Id, User>();
        Set<Id> identityIds = new Set<Id>(identityByDefinition.values());
        for (AgentExecutionIdentity__c identity : [
            SELECT Id, PrincipalUser__c, PrincipalUser__r.Name, PrincipalUser__r.IsActive
            FROM AgentExecutionIdentity__c
            WHERE Id IN :identityIds AND IsActive__c = TRUE
            WITH SYSTEM_MODE
        ]) {
            if (identity.PrincipalUser__r != null && identity.PrincipalUser__r.IsActive == true) {
                userByIdentity.put(identity.Id, new User(Id = identity.PrincipalUser__c, LastName = identity.PrincipalUser__r.Name));
            }
        }
        for (Id definitionId : identityByDefinition.keySet()) {
            User principal = userByIdentity.get(identityByDefinition.get(definitionId));
            if (principal != null) {
                result.put(definitionId, principal);
            }
        }
        return result;
    }

    /**
     * What the execution user lacks for this tool, as one admin-readable
     * message, or null when nothing is missing or the tool is not checked.
     */
    public static String problem(AgentTool__c tool, User executionUser) {
        if (tool == null || executionUser == null) {
            return null;
        }
        AgentToolType__mdt toolType = AgentToolTypeService.toolType(tool);
        String toolClass = toolType == null || toolType.ToolClass__c == null ? null : toolType.ToolClass__c.trim();
        if (toolClass != QUERY_RECORDS && toolClass != CREATE_RECORD && toolClass != UPDATE_RECORD) {
            return null;
        }
        List<String> lines = new List<String>();
        if (toolClass == QUERY_RECORDS) {
            StandardQueryRecordsTool.Query query;
            try {
                query = StandardQueryRecordsTool.read(tool.ImplementationConfiguration__c);
            } catch (Exception unreadable) {
                // The tool's own validation reports a bad query.
                return null;
            }
            Map<Schema.SObjectType, Set<String>> fieldsByObject = new Map<Schema.SObjectType, Set<String>>{ query.objectType => new Set<String>() };
            for (StandardQueryRecordsTool.FieldRef ref : query.fieldsRead()) {
                if (!fieldsByObject.containsKey(ref.ownerType)) {
                    fieldsByObject.put(ref.ownerType, new Set<String>());
                }
                fieldsByObject.get(ref.ownerType).add(ref.field.getName());
            }
            for (Schema.SObjectType objectType : fieldsByObject.keySet()) {
                addMissing(lines, 'read', executionUser.Id, objectType, fieldsByObject.get(objectType), AttendedAccessService.Operation.READABLE);
            }
        } else {
            Map<String, Object> config;
            Schema.SObjectType objectType;
            try {
                config = StandardToolSupport.configuration(tool.ImplementationConfiguration__c);
                objectType = StandardToolSupport.resolveObject(StandardToolSupport.requiredConfig(config, 'objectApiName', 'objectApiName'));
            } catch (Exception unreadable) {
                // The tool's own validation reports a bad configuration.
                return null;
            }
            if (toolClass == CREATE_RECORD) {
                addMissing(
                    lines,
                    'create',
                    executionUser.Id,
                    objectType,
                    names(config, new List<String>{ 'fields' }),
                    AttendedAccessService.Operation.CREATABLE
                );
            } else {
                addMissing(lines, 'read', executionUser.Id, objectType, new Set<String>(), AttendedAccessService.Operation.READABLE);
                addMissing(lines, 'edit', executionUser.Id, objectType, names(config, new List<String>{ 'fields' }), AttendedAccessService.Operation.EDITABLE);
            }
        }
        if (lines.isEmpty()) {
            return null;
        }
        return 'The agent\'s execution user (' +
            executionUser.LastName +
            ') cannot ' +
            String.join(lines, '; cannot ') +
            '. Give that user access in a permission set, or leave those fields out of the tool.';
    }

    private static void addMissing(
        List<String> lines,
        String verb,
        Id userId,
        Schema.SObjectType objectType,
        Set<String> fields,
        AttendedAccessService.Operation needed
    ) {
        List<String> missing = AttendedAccessService.missingAccess(userId, objectType, fields, needed);
        if (!missing.isEmpty()) {
            lines.add(verb + ' ' + String.join(missing, ', '));
        }
    }

    /** Field names listed under the keys, as a single name or a list. */
    private static Set<String> names(Map<String, Object> config, List<String> keys) {
        Set<String> result = new Set<String>();
        for (String key : keys) {
            Object value = config.get(key);
            if (value instanceof String && !String.isBlank((String) value)) {
                result.add(((String) value).trim());
            } else if (value instanceof List<Object>) {
                for (Object item : (List<Object>) value) {
                    if (item instanceof String && !String.isBlank((String) item)) {
                        result.add(((String) item).trim());
                    }
                }
            }
        }
        return result;
    }
}
