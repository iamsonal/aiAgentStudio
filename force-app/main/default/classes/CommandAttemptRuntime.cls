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
 * Package-internal runtime for the protocol shared by leased command attempts.
 * Workers retain ownership of adapter request/response semantics and telemetry
 * shape; this runtime owns the durable attempt boundary around those semantics.
 */
public without sharing class CommandAttemptRuntime {
    private final Id runId;
    private final Id commandId;
    private final Decimal expectedRevision;
    private final String operationKey;
    private final String leaseToken;
    private final Integer completedAttemptCount;
    private final String invocationType;
    private final String providerToolCallId;
    private final CommandContinuationFinalizer continuationFinalizer;

    private AgentExecutionPolicyService.Policy executionPolicy;
    private TrustService.ProtectionContext trustContext;
    private Datetime invocationStartedAt;
    private InvocationEvidenceService.Usage invocationUsageAtStart;
    private String invocationRequestJson;
    private String invocationResponseJson;
    private String nativeRequestEvidence;
    private String nativeResponseEvidence;
    private AgentKernelModels.OperationalTelemetry telemetry;
    private AgentModel__mdt model;
    private String configurationHash;
    @TestVisible
    private static Boolean failSettlementForTest = false;
    /** Settlements that succeed before failSettlementForTest fails one, so a test can crash a later step of the same job. */
    @TestVisible
    private static Integer settlementsBeforeFailureForTest = 0;

    public CommandAttemptRuntime(
        Id runId,
        Id commandId,
        Decimal expectedRevision,
        String operationKey,
        String leaseToken,
        Integer completedAttemptCount,
        String invocationType,
        String providerToolCallId,
        CommandContinuationFinalizer continuationFinalizer
    ) {
        this.runId = runId;
        this.commandId = commandId;
        this.expectedRevision = expectedRevision;
        this.operationKey = operationKey;
        this.leaseToken = leaseToken;
        this.completedAttemptCount = completedAttemptCount;
        this.invocationType = invocationType;
        this.providerToolCallId = providerToolCallId;
        this.continuationFinalizer = continuationFinalizer;
    }

    public void configureExecutionPolicy(AgentExecutionPolicyService.Policy executionPolicy) {
        this.executionPolicy = executionPolicy;
    }

    public void adoptTrustContext(TrustService.ProtectionContext trustContext) {
        this.trustContext = trustContext;
    }

    public String protect(String content) {
        if (!TrustService.needsProtection(new List<String>{ content })) {
            return content;
        }
        ensureTrustContext();
        return TrustService.protect(trustContext, content);
    }

    /** Protects the model's own output; values it wrote itself stay usable by any tool. */
    public String protectModelOutput(String content) {
        if (!TrustService.needsProtection(new List<String>{ content })) {
            return content;
        }
        ensureTrustContext();
        return TrustService.protect(trustContext, content, true);
    }

    /**
     * Protects a value read back from this run's commands. Tokens in it were
     * validated when written, so only raw detectable values are re-protected.
     */
    public String protectStored(String content) {
        if (!TrustService.containsDetectableValue(content)) {
            return content;
        }
        ensureTrustContext();
        return TrustService.protect(trustContext, content);
    }

    public String protectRecordSets(Map<String, List<SObject>> recordSets) {
        ensureTrustContext();
        return TrustService.protectRecordSets(trustContext, recordSets);
    }

    public void setInvocationRequest(String requestJson) {
        invocationRequestJson = requestJson;
    }

    public Long startInvocation() {
        invocationStartedAt = System.now();
        invocationUsageAtStart = new InvocationEvidenceService.Usage();
        return invocationStartedAt.getTime();
    }

    public void setNativeEvidence(String requestEvidence, String responseEvidence) {
        nativeRequestEvidence = requestEvidence;
        nativeResponseEvidence = responseEvidence;
    }

    public void protectNativeEvidence() {
        nativeRequestEvidence = protect(nativeRequestEvidence);
        nativeResponseEvidence = protect(nativeResponseEvidence);
    }

    public void setInvocationResponse(String responseJson) {
        invocationResponseJson = responseJson;
    }

    public void setTelemetry(AgentKernelModels.OperationalTelemetry telemetry) {
        this.telemetry = telemetry;
    }

    public void setModel(AgentModel__mdt selectedModel) {
        model = selectedModel;
    }

    public void setConfigurationHash(String hash) {
        configurationHash = hash;
    }

    public void scheduleRetry(String errorCode, String errorMessage, Integer retryAfterSeconds, List<Object> contextSourceMetadata) {
        errorMessage = protect(errorMessage);
        saveTrustMappings();
        recordEvidence('Retry Requested', errorCode, errorMessage);
        RetryPolicyService.Decision retryDecision = executionPolicy == null
            ? RetryPolicyService.compute(operationKey, completedAttemptCount, retryAfterSeconds)
            : RetryPolicyService.compute(
                  executionPolicy.retryBaseDelaySeconds,
                  executionPolicy.retryMaxDelaySeconds,
                  executionPolicy.retryJitterPercent,
                  operationKey,
                  completedAttemptCount,
                  retryAfterSeconds
              );
        AgentKernelModels.RetryRequest retryRequest = new AgentKernelModels.RetryRequest();
        retryRequest.runId = runId;
        retryRequest.commandId = commandId;
        retryRequest.expectedRevision = expectedRevision;
        retryRequest.operationKey = operationKey;
        retryRequest.leaseToken = leaseToken;
        retryRequest.errorCode = errorCode;
        retryRequest.errorMessage = errorMessage;
        retryRequest.delaySeconds = retryDecision.delaySeconds;
        retryRequest.telemetry = telemetry;
        retryRequest.contextSources = contextSourceMetadata;
        retryRequest.exponentialSeconds = retryDecision.exponentialSeconds;
        retryRequest.retryAfterApplied = retryDecision.retryAfterApplied;
        retryRequest.completedAttemptCount = retryDecision.completedAttemptCount;
        retryRequest.configurationHash = configurationHash;
        Boolean scheduled = AgentKernel.scheduleRetry(retryRequest);
        if (scheduled) {
            continuationFinalizer.prepare(commandId);
        }
    }

    public void submit(AgentKernelModels.CommandOutcome outcome) {
        outcome.payload = protect(outcome.payload);
        saveTrustMappings();
        recordEvidence(evidenceOutcome(outcome), outcome.errorCode, outcome.errorMessage);
        outcome.leaseToken = leaseToken;
        outcome.configurationHash = configurationHash;
        if (Test.isRunningTest() && failSettlementForTest && settlementsBeforeFailureForTest-- <= 0) {
            throw new AgentKernelException.PersistenceException('SETTLEMENT_TEST_FAILURE');
        }
        AgentKernel.applyOutcome(outcome);
        if (outcome.nextCommandId != null) {
            continuationFinalizer.prepare(outcome.nextCommandId);
        }
    }

    private void ensureTrustContext() {
        if (trustContext == null) {
            trustContext = TrustService.open(runId);
        }
    }

    private void saveTrustMappings() {
        if (trustContext != null) {
            TrustService.save(trustContext);
        }
    }

    private void recordEvidence(String outcome, String errorCode, String errorMessage) {
        if (invocationStartedAt == null || String.isBlank(invocationRequestJson)) {
            return;
        }
        InvocationEvidenceService.Capture capture = new InvocationEvidenceService.Capture();
        capture.runId = runId;
        capture.commandId = commandId;
        capture.commandRevision = expectedRevision;
        // Production leases start at one. Direct-worker tests may synthesize a
        // lease without incrementing the command attempt count.
        capture.attemptNumber = completedAttemptCount == null || completedAttemptCount < 1 ? 1 : completedAttemptCount;
        capture.invocationType = invocationType;
        capture.outcome = outcome;
        capture.operationKey = operationKey;
        capture.providerToolCallId = providerToolCallId;
        capture.startedAt = invocationStartedAt;
        capture.usageAtStart = invocationUsageAtStart;
        capture.requestJson = invocationRequestJson;
        capture.responseJson = invocationResponseJson;
        capture.nativeRequestEvidence = nativeRequestEvidence;
        capture.nativeResponseEvidence = nativeResponseEvidence;
        capture.telemetry = telemetry;
        capture.model = model;
        capture.configurationHash = configurationHash;
        capture.errorCode = errorCode;
        capture.errorMessage = errorMessage;
        InvocationEvidenceService.record(capture);
        invocationStartedAt = null;
        invocationUsageAtStart = null;
    }

    private static String evidenceOutcome(AgentKernelModels.CommandOutcome outcome) {
        if (outcome.commandStatus == AgentKernelModels.COMMAND_STATUS_UNKNOWN) {
            return 'Unknown';
        }
        if (outcome.runStatus == AgentKernelModels.RUN_STATUS_WAITING) {
            return 'Waiting';
        }
        return outcome.commandStatus == AgentKernelModels.COMMAND_STATUS_SUCCEEDED ? 'Succeeded' : 'Failed';
    }
}
