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
 * Best-effort, non-sensitive lifecycle notification publisher. Durable kernel
 * records remain authoritative if publication is unavailable.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class AgentLifecyclePublisher {
    public class Notification {
        public AgentRun__c run;
        public String transition;
        public Decimal sequence;
        public String operationKey;
    }

    @TestVisible
    private static Integer lastPublishFailures = 0;
    /** Transitions handed to the event bus in this transaction, for tests; events cannot be queried. */
    @TestVisible
    private static List<String> publishedTransitions = new List<String>();

    public static Integer lastPublishFailureCount() {
        return lastPublishFailures;
    }

    public static void publish(AgentRun__c run, String transition, Decimal sequence, String operationKey) {
        Notification notification = new Notification();
        notification.run = run;
        notification.transition = transition;
        notification.sequence = sequence;
        notification.operationKey = operationKey;
        publishBatch(new List<Notification>{ notification });
    }

    public static void publishBatch(List<Notification> notifications) {
        List<AgentLifecycleEvent__e> events = new List<AgentLifecycleEvent__e>();
        List<Id> runIdsByEvent = new List<Id>();
        try {
            for (Notification item : notifications == null ? new List<Notification>() : notifications) {
                if (item == null || item.run == null || String.isBlank(item.transition)) {
                    continue;
                }
                Map<String, Object> fields = item.run.getPopulatedFieldsAsMap();
                events.add(
                    new AgentLifecycleEvent__e(
                        RunId__c = bounded(String.valueOf(item.run.Id), 18),
                        DefinitionId__c = bounded(stringValue(fields.get('AgentDefinition__c')), 18),
                        Transition__c = bounded(item.transition, 80),
                        EventSequence__c = item.sequence,
                        RunRevision__c = (Decimal) fields.get('Revision__c'),
                        RunStatus__c = bounded(stringValue(fields.get('Status__c')), 40),
                        OperationKey__c = bounded(item.operationKey, 255),
                        ErrorCode__c = bounded(stringValue(fields.get('ErrorCode__c')), 80),
                        OccurredAt__c = System.now()
                    )
                );
                runIdsByEvent.add(item.run.Id);
            }
            if (events.isEmpty()) {
                lastPublishFailures = 0;
                return;
            }
            if (!Schema.sObjectType.AgentLifecycleEvent__e.isCreateable()) {
                lastPublishFailures = events.size();
                recordFailures(new Set<Id>(runIdsByEvent));
                AgentOperationsLog.emit(LoggingLevel.WARN, 'LIFECYCLE_EVENT_CREATE_DENIED', null, null, events.size(), null);
                return;
            }
            List<Database.SaveResult> results = EventBus.publish(events);
            if (Test.isRunningTest()) {
                for (AgentLifecycleEvent__e event : events) {
                    publishedTransitions.add(event.Transition__c);
                }
            }
            lastPublishFailures = 0;
            if (results == null) {
                return;
            }
            Set<Id> failedRunIds = new Set<Id>();
            Integer resultIndex = 0;
            for (Database.SaveResult result : results) {
                if (result == null || result.isSuccess()) {
                    resultIndex++;
                    continue;
                }
                lastPublishFailures++;
                Id failedRunId = resultIndex < runIdsByEvent.size() ? runIdsByEvent[resultIndex] : null;
                if (resultIndex < runIdsByEvent.size()) {
                    failedRunIds.add(failedRunId);
                }
                resultIndex++;
                AgentOperationsLog.emit(LoggingLevel.WARN, 'LIFECYCLE_PUBLISH_FAILED', failedRunId, null, null, null);
            }
            recordFailures(failedRunIds);
        } catch (Exception ignored) {
            lastPublishFailures = events.isEmpty() ? 1 : events.size();
            recordFailures(new Set<Id>(runIdsByEvent));
            AgentOperationsLog.emit(LoggingLevel.WARN, 'LIFECYCLE_PUBLISH_EXCEPTION', null, null, lastPublishFailures, null);
        }
    }

    private static void recordFailures(Set<Id> runIds) {
        if (runIds == null || runIds.isEmpty()) {
            return;
        }
        try {
            List<AgentRun__c> updates = new List<AgentRun__c>();
            for (AgentRun__c run : [
                SELECT Id, LifecyclePublishFailureCount__c
                FROM AgentRun__c
                WHERE Id IN :runIds
                WITH SYSTEM_MODE
                FOR UPDATE
            ]) {
                updates.add(
                    new AgentRun__c(
                        Id = run.Id,
                        LifecyclePublishFailureCount__c = (run.LifecyclePublishFailureCount__c == null ? 0 : run.LifecyclePublishFailureCount__c) + 1,
                        LastLifecyclePublishFailureAt__c = System.now()
                    )
                );
            }
            AgentLifecycleStore.updateRuns(updates);
        } catch (Exception persistenceFailure) {
            AgentOperationsLog.emit(LoggingLevel.WARN, 'LIFECYCLE_FAILURE_TELEMETRY_PERSIST_FAILED', null, null, runIds.size(), null);
        }
    }

    private static String bounded(String value, Integer maximum) {
        if (String.isBlank(value)) {
            return null;
        }
        String safe = value.replace('\r', ' ').replace('\n', ' ').trim();
        return safe.length() > maximum ? safe.substring(0, maximum) : safe;
    }

    private static String stringValue(Object value) {
        return value == null ? null : String.valueOf(value);
    }
}
