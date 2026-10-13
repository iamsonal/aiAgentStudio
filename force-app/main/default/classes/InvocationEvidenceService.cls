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
 * Persists one protected, immutable evidence row per model or tool invocation
 * attempt. Capture occurs after extension execution so it adds no Queueable or
 * DML-before-callout boundary.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class InvocationEvidenceService {
    /**
     * Identifies the current Apex transaction. Statics reset in every
     * transaction, so the value differs per Queueable job. The platform request
     * ID does not: chained async jobs keep the request ID that started them.
     */
    @TestVisible
    private static final String TRANSACTION_ID = UUID.randomUUID().toString();

    /** Governor counters at one moment. The difference between two is what ran in between. */
    public class Usage {
        public final Integer cpuMilliseconds = Limits.getCpuTime();
        public final Integer queries = Limits.getQueries();
        public final Integer dmlStatements = Limits.getDmlStatements();
    }

    public class Capture {
        public Id runId;
        public Id commandId;
        public Decimal commandRevision;
        public Integer attemptNumber;
        public String invocationType;
        public String outcome;
        public String operationKey;
        public String providerToolCallId;
        public Datetime startedAt;
        /** Counters when the call started. Without it, usage is left blank. */
        public Usage usageAtStart;
        public String requestJson;
        public String responseJson;
        public String nativeRequestEvidence;
        public String nativeResponseEvidence;
        public AgentKernelModels.OperationalTelemetry telemetry;
        public AgentModel__mdt model;
        public String configurationHash;
        public String errorCode;
        public String errorMessage;
    }

    public static Id record(Capture capture) {
        Usage usageAtEnd = new Usage();
        validate(capture);
        AgentRun__c run = [
            SELECT PayloadRetentionMode__c, RetainedPayloadCharacters__c, SensitiveJsonKeys__c
            FROM AgentRun__c
            WHERE Id = :capture.runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        PayloadProtectionService.Policy policy = PayloadProtectionService.fromRun(run);
        PayloadProtectionService.ProtectionResult requestEvidence = PayloadProtectionService.protect(capture.requestJson, policy);
        PayloadProtectionService.ProtectionResult responseEvidence = PayloadProtectionService.protect(capture.responseJson, policy);
        String nativeEnvelope = nativeEnvelope(capture.nativeRequestEvidence, capture.nativeResponseEvidence);
        PayloadProtectionService.ProtectionResult nativeEvidence = PayloadProtectionService.protect(nativeEnvelope, policy);
        AgentKernelModels.OperationalTelemetry telemetry = capture.telemetry == null ? new AgentKernelModels.OperationalTelemetry() : capture.telemetry;
        AgentModel__mdt model = capture.invocationType == 'Model' ? capture.model : null;
        AgentModelService.Estimate estimate = AgentModelService.estimate(model, telemetry.inputTokens, telemetry.outputTokens);
        Datetime completedAt = System.now();
        AgentInvocation__c invocation = new AgentInvocation__c(
            AgentRun__c = capture.runId,
            AgentCommand__c = capture.commandId,
            InvocationKey__c = String.valueOf(capture.commandId) + ':' + String.valueOf(capture.attemptNumber),
            AttemptNumber__c = capture.attemptNumber,
            CommandRevision__c = capture.commandRevision,
            InvocationType__c = capture.invocationType,
            Outcome__c = capture.outcome,
            OperationKey__c = capture.operationKey,
            ProviderToolCallId__c = bounded(capture.providerToolCallId, 255),
            StartedAt__c = capture.startedAt,
            CompletedAt__c = completedAt,
            DurationMs__c = nonnegative(telemetry.durationMilliseconds),
            CpuTimeMs__c = capture.usageAtStart == null ? null : usageAtEnd.cpuMilliseconds - capture.usageAtStart.cpuMilliseconds,
            SoqlQueries__c = capture.usageAtStart == null ? null : usageAtEnd.queries - capture.usageAtStart.queries,
            DmlStatements__c = capture.usageAtStart == null ? null : usageAtEnd.dmlStatements - capture.usageAtStart.dmlStatements,
            TransactionId__c = TRANSACTION_ID,
            InputTokens__c = nonnegative(telemetry.inputTokens),
            OutputTokens__c = nonnegative(telemetry.outputTokens),
            TotalTokens__c = nonnegative(telemetry.totalTokens),
            Model__c = model == null ? null : model.DeveloperName,
            ModelAdapterClass__c = model == null ? null : bounded(model.ModelAdapterClass__c, 255),
            ModelIdentifier__c = model == null ? null : bounded(model.ModelIdentifier__c, 255),
            EstimatedCostUSD__c = estimate == null ? null : estimate.amountUsd,
            AppliedInputPricePerMillion__c = estimate == null ? null : estimate.inputPricePerMillion,
            AppliedOutputPricePerMillion__c = estimate == null ? null : estimate.outputPricePerMillion,
            ProviderRequestId__c = bounded(telemetry.providerRequestId, 255),
            ExternalReference__c = bounded(PayloadProtectionService.protect(telemetry.externalReference, policy).protectedPayload, 255),
            ErrorCode__c = bounded(capture.errorCode, 100),
            ErrorMessage__c = bounded(PayloadProtectionService.protect(capture.errorMessage, policy).protectedPayload, 32768),
            Request__c = requestEvidence.protectedPayload,
            Response__c = responseEvidence.protectedPayload,
            NativeEvidence__c = nativeEvidence.protectedPayload,
            RequestHash__c = requestEvidence.payloadHash,
            ResponseHash__c = responseEvidence.payloadHash,
            NativeEvidenceHash__c = nativeEvidence.payloadHash,
            PayloadProtectionMode__c = policy.mode,
            ConfigurationHash__c = capture.configurationHash,
            EvidenceMetadata__c = evidenceMetadata(requestEvidence, responseEvidence, nativeEvidence)
        );
        AgentLifecycleStore.insertInvocations(new List<AgentInvocation__c>{ invocation });
        AgentOperationsLog.emit(
            capture.outcome == 'Failed' || capture.outcome == 'Unknown' ? LoggingLevel.WARN : LoggingLevel.INFO,
            'INVOCATION_' + capture.invocationType + '_' + capture.outcome,
            capture.runId,
            capture.commandId,
            capture.attemptNumber,
            capture.operationKey
        );
        return invocation.Id;
    }

    public static Boolean isAuthorizedPurgeTransition(AgentInvocation__c oldRecord, AgentInvocation__c newRecord) {
        if (
            !PayloadRetentionPurgeService.isInvocationPurgeAuthorized() ||
            newRecord.PayloadPurgedAt__c == null ||
            newRecord.Request__c != null ||
            newRecord.Response__c != null ||
            newRecord.NativeEvidence__c != null ||
            newRecord.ErrorMessage__c != null ||
            newRecord.ExternalReference__c != null
        ) {
            return false;
        }
        Map<String, Object> oldValues = new Map<String, Object>(oldRecord.getPopulatedFieldsAsMap());
        Map<String, Object> newValues = new Map<String, Object>(newRecord.getPopulatedFieldsAsMap());
        for (
            String mutableField : new Set<String>{
                'Request__c',
                'Response__c',
                'NativeEvidence__c',
                'ErrorMessage__c',
                'ExternalReference__c',
                'PayloadPurgedAt__c'
            }
        ) {
            oldValues.remove(mutableField);
            newValues.remove(mutableField);
        }
        if (oldValues.keySet() != newValues.keySet()) {
            return false;
        }
        for (String fieldName : oldValues.keySet()) {
            if (String.valueOf(oldValues.get(fieldName)) != String.valueOf(newValues.get(fieldName))) {
                return false;
            }
        }
        return true;
    }

    private static void validate(Capture capture) {
        if (
            capture == null ||
            capture.runId == null ||
            capture.commandId == null ||
            capture.commandRevision == null ||
            capture.attemptNumber == null ||
            capture.attemptNumber < 1 ||
            String.isBlank(capture.operationKey) ||
            String.isBlank(capture.requestJson) ||
            capture.startedAt == null
        ) {
            throw new AgentKernelException.InvalidTransitionException('Complete invocation evidence identity and request are required.');
        }
        if (!new Set<String>{ 'Model', 'Tool' }.contains(capture.invocationType)) {
            throw new AgentKernelException.InvalidTransitionException('Invocation evidence type is invalid.');
        }
        if (!new Set<String>{ 'Succeeded', 'Failed', 'Retry Requested', 'Waiting', 'Unknown' }.contains(capture.outcome)) {
            throw new AgentKernelException.InvalidTransitionException('Invocation evidence outcome is invalid.');
        }
    }

    private static String nativeEnvelope(String requestEvidence, String responseEvidence) {
        if (String.isBlank(requestEvidence) && String.isBlank(responseEvidence)) {
            return null;
        }
        return JSON.serialize(
            new Map<String, Object>{ 'request' => structuredNativeEvidence(requestEvidence), 'response' => structuredNativeEvidence(responseEvidence) }
        );
    }

    private static Object structuredNativeEvidence(String evidence) {
        if (String.isBlank(evidence)) {
            return null;
        }
        try {
            return JSON.deserializeUntyped(evidence);
        } catch (Exception invalidEvidence) {
            return '[OMITTED NON-JSON NATIVE EVIDENCE; length=' + evidence.length() + ']';
        }
    }

    private static String evidenceMetadata(
        PayloadProtectionService.ProtectionResult requestEvidence,
        PayloadProtectionService.ProtectionResult responseEvidence,
        PayloadProtectionService.ProtectionResult nativeEvidence
    ) {
        return JSON.serialize(
            new Map<String, Object>{
                'request' => protectionMetadata(requestEvidence),
                'response' => protectionMetadata(responseEvidence),
                'nativeEvidence' => protectionMetadata(nativeEvidence)
            }
        );
    }

    private static Map<String, Object> protectionMetadata(PayloadProtectionService.ProtectionResult result) {
        return new Map<String, Object>{ 'originalLength' => result.originalLength, 'redacted' => result.redacted, 'truncated' => result.truncated };
    }

    private static Long nonnegative(Long value) {
        return value != null && value >= 0 ? value : null;
    }

    private static String bounded(String value, Integer maximumLength) {
        if (String.isBlank(value)) {
            return null;
        }
        String normalized = value.replace('\r', ' ').replace('\n', ' ').trim();
        return normalized.length() > maximumLength ? normalized.substring(0, maximumLength) : normalized;
    }
}
