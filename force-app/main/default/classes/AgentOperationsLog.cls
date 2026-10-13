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

/** Bounded, payload-free operational diagnostics; durable evidence remains authoritative. */
public class AgentOperationsLog {
    public static void recoveryPass(Integer requeued, Integer expiredWaits, Integer orphans, Integer capacityDeferred, Integer activeWorkerDeferred) {
        try {
            System.debug(
                LoggingLevel.INFO,
                JSON.serialize(
                    new Map<String, Object>{
                        'source' => 'AgentCore',
                        'code' => 'RECOVERY_PASS',
                        'requeued' => requeued,
                        'expiredWaits' => expiredWaits,
                        'orphans' => orphans,
                        'capacityDeferred' => capacityDeferred,
                        'activeWorkerDeferred' => activeWorkerDeferred,
                        'cpuMs' => Limits.getCpuTime(),
                        'soql' => Limits.getQueries(),
                        'dml' => Limits.getDmlStatements(),
                        'at' => System.now()
                    }
                )
            );
        } catch (Exception ignored) {
            // Logging must not change the lifecycle outcome.
        }
    }

    public static void emit(LoggingLevel level, String code, Id runId, Id commandId, Integer attempt, String operationKey) {
        try {
            Map<String, Object> entry = new Map<String, Object>{
                'source' => 'AgentCore',
                'code' => safeCode(code),
                'runId' => runId,
                'commandId' => commandId,
                'attempt' => attempt,
                'operationKeyHash' => String.isBlank(operationKey)
                    ? null
                    : EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(operationKey))),
                'cpuMs' => Limits.getCpuTime(),
                'soql' => Limits.getQueries(),
                'dml' => Limits.getDmlStatements(),
                'at' => System.now()
            };
            System.debug(level, JSON.serialize(entry));
        } catch (Exception ignored) {
            // Logging must not change the lifecycle outcome.
        }
    }

    /**
     * Publishes a durable, payload-free anomaly that survives the rollback of
     * the detecting transaction. Call only where no callout follows.
     */
    public static void signal(String code, Id runId, Id commandId, String exceptionType) {
        publish(new List<AgentOperationalSignal__e>{ event(code, runId, commandId, exceptionType) });
    }

    /** Builds one signal for publish; batch callers collect these and publish once. */
    public static AgentOperationalSignal__e event(String code, Id runId, Id commandId, String exceptionType) {
        return event(code, runId, commandId, exceptionType, null);
    }

    /** A signal about one approval or approval work item, so its issue can be grouped and resolved by it. */
    public static AgentOperationalSignal__e event(String code, Id runId, Id commandId, String exceptionType, Id subjectId) {
        return new AgentOperationalSignal__e(
            SubjectId__c = subjectId,
            Code__c = safeCode(code),
            RunId__c = runId,
            CommandId__c = commandId,
            ExceptionType__c = String.isBlank(exceptionType) ? null : exceptionType.left(255),
            OccurredAt__c = System.now()
        );
    }

    /** Publishes signals in one call, so a batch stays within the per-transaction publish limit. */
    public static void publish(List<AgentOperationalSignal__e> signals) {
        if (signals == null || signals.isEmpty()) {
            return;
        }
        for (AgentOperationalSignal__e signal : signals) {
            emit(LoggingLevel.WARN, signal.Code__c, signal.RunId__c, signal.CommandId__c, null, null);
        }
        try {
            EventBus.publish(signals);
        } catch (Exception ignored) {
            // Signalling must not change the lifecycle outcome.
        }
    }

    private static String safeCode(String code) {
        if (String.isBlank(code)) {
            return 'UNSPECIFIED';
        }
        String safe = code.replaceAll('[^A-Za-z0-9_]', '_').toUpperCase();
        return safe.length() > 80 ? safe.substring(0, 80) : safe;
    }
}
