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
 * Optional subscriber helper for enforcing object and field access inside
 * business-data tools. It does not replace explicit sharing declarations.
 */
global inherited sharing class ToolSecurity {
    global static void assertReadable(Schema.SObjectType objectType) {
        assertType(objectType);
        if (!objectType.getDescribe().isAccessible()) {
            throw new AgentKernelException.PermanentException('The execution principal cannot read the requested object.');
        }
    }

    global static void assertCreateable(Schema.SObjectType objectType) {
        assertType(objectType);
        if (!objectType.getDescribe().isCreateable()) {
            throw new AgentKernelException.PermanentException('The execution principal cannot create the requested object.');
        }
    }

    global static void assertUpdateable(Schema.SObjectType objectType) {
        assertType(objectType);
        if (!objectType.getDescribe().isUpdateable()) {
            throw new AgentKernelException.PermanentException('The execution principal cannot update the requested object.');
        }
    }

    global static void assertFieldsReadable(Schema.SObjectType objectType, List<String> fieldApiNames) {
        assertType(objectType);
        Map<String, Schema.SObjectField> fields = new Map<String, Schema.SObjectField>();
        for (String apiName : objectType.getDescribe().fields.getMap().keySet()) {
            fields.put(apiName.toLowerCase(), objectType.getDescribe().fields.getMap().get(apiName));
        }
        for (String fieldApiName : normalizedFields(fieldApiNames)) {
            if (!fields.containsKey(fieldApiName) || !fields.get(fieldApiName).getDescribe().isAccessible()) {
                throw new AgentKernelException.PermanentException('The execution principal cannot read one or more requested fields.');
            }
        }
    }

    global static List<SObject> stripReadable(List<SObject> records) {
        return records == null ? new List<SObject>() : Security.stripInaccessible(System.AccessType.READABLE, records, true).getRecords();
    }

    global static List<SObject> stripCreateable(List<SObject> records) {
        return records == null ? new List<SObject>() : Security.stripInaccessible(System.AccessType.CREATABLE, records, true).getRecords();
    }

    global static List<SObject> stripUpdateable(List<SObject> records) {
        return records == null ? new List<SObject>() : Security.stripInaccessible(System.AccessType.UPDATABLE, records, true).getRecords();
    }

    /**
     * Requester checks for attended runs of agents with an identity. The tool runs as
     * the execution user; when a person started the run in their own
     * request (principal.attendedByUserId), a tool must not read or change
     * what that person could not. Each check is a no-op for other runs.
     * Record data returned as recordSets is already filtered by Core.
     */
    /**
     * The records the person an attended run works for may read, in their
     * original order; all records when nobody attends the run. Use it before
     * a tool writes record data into a text output.
     */
    global static List<SObject> requesterReadable(AgentKernelModels.ExecutionPrincipal principal, List<SObject> records) {
        if (principal == null || principal.attendedByUserId == null || records == null || records.isEmpty()) {
            return records;
        }
        Set<Id> ids = new Set<Id>();
        for (SObject record : records) {
            if (record != null && record.Id != null) {
                ids.add(record.Id);
            }
        }
        Set<Id> readable = AttendedAccessService.readableRecordIds(principal.attendedByUserId, ids);
        // A clone keeps the caller's list type, so a List<Case> stays castable to List<Case>.
        List<SObject> result = records.clone();
        result.clear();
        for (SObject record : records) {
            if (record != null && readable.contains(record.Id)) {
                result.add(record);
            }
        }
        return result;
    }

    global static void assertRequesterCanRead(AgentKernelModels.ExecutionPrincipal principal, Id recordId) {
        AttendedAccessService.assertCanRead(requesterOf(principal), recordId);
    }

    global static void assertRequesterCanEdit(AgentKernelModels.ExecutionPrincipal principal, Id recordId, Set<String> fieldApiNames) {
        AttendedAccessService.assertCanEdit(requesterOf(principal), recordId, fieldApiNames);
    }

    global static void assertRequesterCanCreate(AgentKernelModels.ExecutionPrincipal principal, Schema.SObjectType objectType, Set<String> fieldApiNames) {
        assertType(objectType);
        AttendedAccessService.assertCanCreate(requesterOf(principal), objectType, fieldApiNames);
    }

    private static Id requesterOf(AgentKernelModels.ExecutionPrincipal principal) {
        return principal == null ? null : principal.attendedByUserId;
    }

    private static void assertType(Schema.SObjectType objectType) {
        if (objectType == null) {
            throw new AgentKernelException.PermanentException('An object type is required for tool security validation.');
        }
    }

    private static List<String> normalizedFields(List<String> fieldApiNames) {
        if (fieldApiNames == null || fieldApiNames.isEmpty()) {
            throw new AgentKernelException.PermanentException('At least one field is required for tool security validation.');
        }
        List<String> result = new List<String>();
        for (String fieldApiName : fieldApiNames) {
            if (String.isBlank(fieldApiName)) {
                throw new AgentKernelException.PermanentException('Field API names must be nonblank.');
            }
            result.add(fieldApiName.trim().toLowerCase());
        }
        return result;
    }
}
