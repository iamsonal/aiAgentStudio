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
 * Limits an attended run of an agent with an identity to what the person it works for
 * can see and change. The execution user executes the run's tools; when a
 * person started the run in their own request, Core also applies that
 * person's record sharing and field access, so an agent never gives someone
 * data or changes they could not get or make themselves.
 *
 * Checks use the platform's effective-access views (UserRecordAccess,
 * UserEntityAccess, UserFieldAccess), which include profiles, permission
 * sets, groups, muting, and sharing.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class AttendedAccessService {
    /** Requests a person makes directly: Lightning, Visualforce, API, and anonymous Apex. */
    private static final Set<System.Quiddity> ATTENDED_REQUESTS = new Set<System.Quiddity>{
        System.Quiddity.AURA,
        System.Quiddity.VF,
        System.Quiddity.REMOTE_ACTION,
        System.Quiddity.QUICK_ACTION,
        System.Quiddity.REST,
        System.Quiddity.SOAP,
        System.Quiddity.INVOCABLE_ACTION,
        System.Quiddity.ANONYMOUS
    };
    private static final Integer RECORD_ACCESS_BATCH = 200;
    private static final String REQUESTER_DENIED = 'The person this run works for cannot ';
    private static final String PARENT_LIMITED = 'The parent run is limited to one person\'s access, and a run started from it keeps that limit. ';

    /** The requester of a background continuation of their own start. */
    private static Id continuedRequesterId;
    @TestVisible
    private static Boolean attendedForTest;
    private static Map<String, Boolean> fieldAccessCache = new Map<String, Boolean>();
    private static Map<String, UserEntityAccess> entityAccessCache = new Map<String, UserEntityAccess>();

    public enum Operation {
        READABLE,
        CREATABLE,
        EDITABLE
    }

    /**
     * The user a new run of an agent with an identity works for, or null when nobody
     * started it in their own request: scheduled, batch, queued, future,
     * Apex trigger, and platform-event starts run as automation. A flow that a
     * person's save triggers runs in their request, so it is attended; the
     * starter can never choose otherwise.
     */
    public static Id attendedRequester() {
        if (attendedForTest != null) {
            return attendedForTest ? UserInfo.getUserId() : null;
        }
        if (continuedRequesterId != null) {
            return continuedRequesterId == UserInfo.getUserId() ? continuedRequesterId : null;
        }
        if (System.isBatch() || System.isFuture() || System.isQueueable() || System.isScheduled() || Trigger.isExecuting) {
            return null;
        }
        return ATTENDED_REQUESTS.contains(Request.getCurrent().getQuiddity()) ? UserInfo.getUserId() : null;
    }

    /**
     * The person a new run is limited to (AttendedBy__c). A person's own
     * request limits a run of an agent with an identity to their access. A link to a parent run never widens access:
     * when the parent is limited to a person, the child is limited to the same
     * person, whoever starts it, and a start that would act for anyone else
     * is refused.
     */
    public static Id attendedByForStart(Boolean usesIdentity, Id parentRunId) {
        Boolean delegated = usesIdentity == true;
        Id requesterId = attendedRequester();
        Id parentPersonId = parentRunId == null ? null : parentPerson(parentRunId);
        if (parentPersonId == null) {
            return delegated ? requesterId : null;
        }
        if (!delegated) {
            // A run without an identity executes as its starter, so only the parent's person may start it.
            if (UserInfo.getUserId() != parentPersonId) {
                throw new AgentKernelException.AuthorizationException(
                    PARENT_LIMITED + 'Only that person can start a run of an agent without an Agent Execution Identity from it.'
                );
            }
            return null;
        }
        if (requesterId != null && requesterId != parentPersonId) {
            throw new AgentKernelException.AuthorizationException(PARENT_LIMITED + 'Only that person or automation can start a run from it.');
        }
        return parentPersonId;
    }

    /** The person a run is limited to: its attended person, or the starter of a run without an identity; null for automation. */
    private static Id parentPerson(Id parentRunId) {
        List<AgentRun__c> parents = [
            SELECT AttendedBy__c, ExecutionIdentity__c, InitiatingUser__c
            FROM AgentRun__c
            WHERE Id = :parentRunId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (parents.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent run was not found.');
        }
        AgentRun__c parent = parents[0];
        if (parent.AttendedBy__c != null) {
            return parent.AttendedBy__c;
        }
        return ExecutionIdentityService.usesIdentity(parent) ? null : parent.InitiatingUser__c;
    }

    /** Keeps a person's own start attended when it finishes in a background continuation. */
    public static void continueFor(Id requesterId) {
        continuedRequesterId = requesterId;
    }

    /** The Ids among recordIds that the user can read; Ids of other objects the platform cannot check are excluded. */
    public static Set<Id> readableRecordIds(Id userId, Set<Id> recordIds) {
        Set<Id> readable = new Set<Id>();
        List<Id> pending = new List<Id>(recordIds == null ? new Set<Id>() : recordIds);
        for (Integer offset = 0; offset < pending.size(); offset += RECORD_ACCESS_BATCH) {
            List<Id> chunk = new List<Id>();
            for (Integer index = offset; index < Math.min(pending.size(), offset + RECORD_ACCESS_BATCH); index++) {
                chunk.add(pending[index]);
            }
            for (UserRecordAccess access : [
                SELECT RecordId, HasReadAccess
                FROM UserRecordAccess
                WHERE UserId = :userId AND RecordId IN :chunk
                WITH SYSTEM_MODE
            ]) {
                if (access.HasReadAccess) {
                    readable.add(access.RecordId);
                }
            }
        }
        return readable;
    }

    /** Field API names (as given) that the user may read, create, or edit on the object. */
    public static Set<String> permittedFields(Id userId, Schema.SObjectType objectType, Set<String> fieldApiNames, Operation needed) {
        Set<String> permitted = new Set<String>();
        if (objectType == null || fieldApiNames == null || fieldApiNames.isEmpty() || !hasObjectAccess(userId, objectType, needed)) {
            return permitted;
        }
        Schema.DescribeSObjectResult describe = objectType.getDescribe();
        Map<String, Schema.SObjectField> fields = describe.fields.getMap();
        Map<String, String> requestedByCanonical = new Map<String, String>();
        Set<String> uncached = new Set<String>();
        for (String requested : fieldApiNames) {
            Schema.SObjectField field = requested == null ? null : fields.get(requested.trim().toLowerCase());
            if (field == null) {
                continue;
            }
            Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
            if (!fieldDescribe.isPermissionable()) {
                // Object access governs fields without their own field-level security.
                permitted.add(requested);
                continue;
            }
            String canonical = fieldDescribe.getName();
            requestedByCanonical.put(canonical, requested);
            if (!fieldAccessCache.containsKey(cacheKey(userId, describe.getName(), canonical, needed))) {
                uncached.add(canonical);
            }
        }
        if (!uncached.isEmpty()) {
            loadFieldAccess(userId, describe.getName(), uncached);
        }
        for (String canonical : requestedByCanonical.keySet()) {
            if (fieldAccessCache.get(cacheKey(userId, describe.getName(), canonical, needed)) == true) {
                permitted.add(requestedByCanonical.get(canonical));
            }
        }
        return permitted;
    }

    /**
     * What the user lacks to read, create, or edit these fields on the object:
     * the object name when the object itself is missing, else each field as
     * Object.Field. Unknown field names are left to the tool's own validation.
     */
    public static List<String> missingAccess(Id userId, Schema.SObjectType objectType, Set<String> fieldApiNames, Operation needed) {
        String objectName = objectType.getDescribe().getName();
        if (!hasObjectAccess(userId, objectType, needed)) {
            return new List<String>{ objectName };
        }
        List<String> missing = new List<String>();
        Set<String> requested = fieldApiNames == null ? new Set<String>() : fieldApiNames;
        Set<String> permitted = permittedFields(userId, objectType, requested, needed);
        Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
        for (String fieldApiName : requested) {
            if (fieldApiName != null && fields.containsKey(fieldApiName.trim().toLowerCase()) && !permitted.contains(fieldApiName)) {
                missing.add(objectName + '.' + fields.get(fieldApiName.trim().toLowerCase()).getDescribe().getName());
            }
        }
        return missing;
    }

    /** Fails a standard tool's change when the requester could not make it; a no-op for runs nobody attends. */
    public static void assertCanEdit(Id userId, Id recordId, Set<String> fieldApiNames) {
        if (userId == null) {
            return;
        }
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :userId AND RecordId = :recordId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (access.isEmpty() || !access[0].HasEditAccess) {
            throw new AgentKernelException.PermanentException(REQUESTER_DENIED + 'edit this record, so the agent may not change it for them.');
        }
        assertFields(userId, recordId.getSObjectType(), fieldApiNames, Operation.EDITABLE);
    }

    public static void assertCanCreate(Id userId, Schema.SObjectType objectType, Set<String> fieldApiNames) {
        if (userId == null) {
            return;
        }
        if (!hasObjectAccess(userId, objectType, Operation.CREATABLE)) {
            throw new AgentKernelException.PermanentException(
                REQUESTER_DENIED + 'create ' + objectType.getDescribe().getName() + ' records, so the agent may not create one for them.'
            );
        }
        assertFields(userId, objectType, fieldApiNames, Operation.CREATABLE);
    }

    public static void assertCanRead(Id userId, Id recordId) {
        if (userId == null) {
            return;
        }
        if (!readableRecordIds(userId, new Set<Id>{ recordId }).contains(recordId)) {
            throw new AgentKernelException.PermanentException(REQUESTER_DENIED + 'see this record, so the agent may not act on it for them.');
        }
    }

    private static void assertFields(Id userId, Schema.SObjectType objectType, Set<String> fieldApiNames, Operation needed) {
        if (fieldApiNames == null || fieldApiNames.isEmpty()) {
            return;
        }
        Set<String> permitted = permittedFields(userId, objectType, fieldApiNames, needed);
        Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
        for (String fieldApiName : fieldApiNames) {
            // Unknown field names are left to the tool's own validation message.
            if (fieldApiName != null && fields.containsKey(fieldApiName.trim().toLowerCase()) && !permitted.contains(fieldApiName)) {
                throw new AgentKernelException.PermanentException(
                    REQUESTER_DENIED +
                        (needed == Operation.CREATABLE ? 'set ' : 'change ') +
                        objectType.getDescribe().getName() +
                        '.' +
                        fieldApiName +
                        '. Leave that field out.'
                );
            }
        }
    }

    private static Boolean hasObjectAccess(Id userId, Schema.SObjectType objectType, Operation needed) {
        String objectName = objectType.getDescribe().getName();
        String key = userId + ':' + objectName;
        if (!entityAccessCache.containsKey(key)) {
            List<UserEntityAccess> rows = [
                SELECT IsReadable, IsCreatable, IsUpdatable
                FROM UserEntityAccess
                WHERE User.Id = :userId AND EntityDefinition.QualifiedApiName = :objectName
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            entityAccessCache.put(key, rows.isEmpty() ? null : rows[0]);
        }
        UserEntityAccess entity = entityAccessCache.get(key);
        if (entity == null) {
            return false;
        }
        return needed == Operation.READABLE ? entity.IsReadable : (needed == Operation.CREATABLE ? entity.IsCreatable : entity.IsUpdatable);
    }

    private static void loadFieldAccess(Id userId, String objectName, Set<String> canonicalFields) {
        Map<String, String> fieldByDurableId = new Map<String, String>();
        for (FieldDefinition definition : [
            SELECT DurableId, QualifiedApiName
            FROM FieldDefinition
            WHERE EntityDefinition.QualifiedApiName = :objectName AND QualifiedApiName IN :canonicalFields
            WITH SYSTEM_MODE
        ]) {
            fieldByDurableId.put(definition.DurableId + '.' + userId, definition.QualifiedApiName);
        }
        for (String canonical : canonicalFields) {
            // A field the platform does not report is treated as inaccessible.
            for (Operation each : Operation.values()) {
                fieldAccessCache.put(cacheKey(userId, objectName, canonical, each), false);
            }
        }
        if (fieldByDurableId.isEmpty()) {
            return;
        }
        Set<String> durableIds = fieldByDurableId.keySet();
        for (UserFieldAccess row : [
            SELECT DurableId, IsAccessible, IsCreatable, IsUpdatable
            FROM UserFieldAccess
            WHERE DurableId IN :durableIds
            WITH SYSTEM_MODE
        ]) {
            String canonical = fieldByDurableId.get(row.DurableId);
            fieldAccessCache.put(cacheKey(userId, objectName, canonical, Operation.READABLE), row.IsAccessible);
            fieldAccessCache.put(cacheKey(userId, objectName, canonical, Operation.CREATABLE), row.IsCreatable);
            fieldAccessCache.put(cacheKey(userId, objectName, canonical, Operation.EDITABLE), row.IsUpdatable);
        }
    }

    private static String cacheKey(Id userId, String objectName, String fieldName, Operation needed) {
        return userId + ':' + objectName + '.' + fieldName + ':' + needed.name();
    }
}
