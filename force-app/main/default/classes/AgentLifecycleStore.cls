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
 * Single system-mode persistence boundary for Agent Core lifecycle records.
 * Callers still enforce sharing at façades; this class never applies
 * stripInaccessible to kernel-owned run, command, or event writes.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class AgentLifecycleStore {
    @TestVisible
    private static Boolean failNextCommandUpdateForTest = false;
    @TestVisible
    private static Boolean failNextRunUpdateForTest = false;

    private static final Set<String> COMMAND_UPDATE_EXCLUSIONS = new Set<String>{
        'AgentRun__c',
        'CreatedById',
        'CreatedDate',
        'LastModifiedById',
        'LastModifiedDate',
        'LastReferencedDate',
        'LastViewedDate',
        'SystemModstamp'
    };

    public static void insertRuns(List<AgentRun__c> runs) {
        if (isEmpty(runs)) {
            return;
        }
        try {
            Database.insert(runs, AccessLevel.SYSTEM_MODE);
        } catch (DmlException failure) {
            throw normalized('RUN_INSERT_FAILED', failure);
        }
    }

    public static void updateRuns(List<AgentRun__c> runs) {
        if (isEmpty(runs)) {
            return;
        }
        if (failNextRunUpdateForTest) {
            failNextRunUpdateForTest = false;
            throw new AgentKernelException.PersistenceException('RUN_UPDATE_FAILED');
        }
        try {
            Database.update(runs, AccessLevel.SYSTEM_MODE);
        } catch (DmlException failure) {
            throw normalized('RUN_UPDATE_FAILED', failure);
        }
    }

    public static void insertCommands(List<AgentCommand__c> commands) {
        if (isEmpty(commands)) {
            return;
        }
        try {
            Database.insert(commands, AccessLevel.SYSTEM_MODE);
        } catch (DmlException failure) {
            throw normalized('COMMAND_INSERT_FAILED', failure);
        }
    }

    public static void updateCommands(List<AgentCommand__c> commands) {
        if (isEmpty(commands)) {
            return;
        }
        List<AgentCommand__c> sparse = new List<AgentCommand__c>();
        for (AgentCommand__c command : commands) {
            if (command != null) {
                sparse.add(sparseCommand(command));
            }
        }
        if (!sparse.isEmpty()) {
            if (failNextCommandUpdateForTest) {
                failNextCommandUpdateForTest = false;
                throw new AgentKernelException.PersistenceException('COMMAND_UPDATE_FAILED');
            }
            try {
                Database.update(sparse, AccessLevel.SYSTEM_MODE);
            } catch (DmlException failure) {
                throw normalized('COMMAND_UPDATE_FAILED', failure);
            }
        }
    }

    public static void insertEvents(List<AgentEvent__c> events) {
        if (isEmpty(events)) {
            return;
        }
        try {
            Database.insert(events, AccessLevel.SYSTEM_MODE);
        } catch (DmlException failure) {
            throw normalized('EVENT_INSERT_FAILED', failure);
        }
    }

    public static void updateEvents(List<AgentEvent__c> events) {
        if (isEmpty(events)) {
            return;
        }
        try {
            Database.update(events, AccessLevel.SYSTEM_MODE);
        } catch (DmlException failure) {
            throw normalized('EVENT_UPDATE_FAILED', failure);
        }
    }

    public static void insertInvocations(List<AgentInvocation__c> invocations) {
        if (isEmpty(invocations)) {
            return;
        }
        try {
            Database.insert(invocations, AccessLevel.SYSTEM_MODE);
        } catch (DmlException failure) {
            throw normalized('INVOCATION_INSERT_FAILED', failure);
        }
    }

    public static void updateInvocations(List<AgentInvocation__c> invocations) {
        if (isEmpty(invocations)) {
            return;
        }
        try {
            Database.update(invocations, AccessLevel.SYSTEM_MODE);
        } catch (DmlException failure) {
            throw normalized('INVOCATION_UPDATE_FAILED', failure);
        }
    }

    private static AgentCommand__c sparseCommand(AgentCommand__c source) {
        AgentCommand__c target = new AgentCommand__c();
        Map<String, Object> fields = source.getPopulatedFieldsAsMap();
        for (String fieldName : fields.keySet()) {
            if (COMMAND_UPDATE_EXCLUSIONS.contains(fieldName)) {
                continue;
            }
            target.put(fieldName, fields.get(fieldName));
        }
        return target;
    }

    private static Boolean isEmpty(List<SObject> records) {
        return records == null || records.isEmpty();
    }

    private static AgentKernelException.PersistenceException normalized(String code, DmlException failure) {
        String status = failure.getNumDml() > 0 ? String.valueOf(failure.getDmlStatusCode(0)) : 'UNKNOWN';
        AgentKernelException.PersistenceException normalizedFailure = new AgentKernelException.PersistenceException(code + ':' + status);
        normalizedFailure.statusCode = status;
        return normalizedFailure;
    }
}
