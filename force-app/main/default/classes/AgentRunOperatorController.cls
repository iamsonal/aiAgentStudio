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
 * No-code operator surface for scenario 11: the Operate action on an Agent Run
 * and the Agent Core Health card. Each action reads the run's current revision
 * and operation key itself, so an operator supplies only the run and their own
 * guidance or evidence. Every call goes through AgentRunService, so Core still
 * enforces who may act and which transitions are legal.
 */
public with sharing class AgentRunOperatorController {
    private static final Set<String> TERMINAL = new Set<String>{
        AgentKernelModels.RUN_STATUS_SUCCEEDED,
        AgentKernelModels.RUN_STATUS_FAILED,
        AgentKernelModels.RUN_STATUS_CANCELLED
    };

    /** What the operator sees on the run and which actions apply to it now. */
    @AuraEnabled
    public static Map<String, Object> getRunView(Id runId) {
        try {
            AgentKernelModels.RunRecord run = AgentRunService.getRun(runId);
            AgentCommand__c current = command(run.currentCommandId);
            AgentCommand__c unknown = unknownCommand(runId);
            Boolean terminal = TERMINAL.contains(run.status);
            // Only the starter of a run without an identity can carry it on; offer nobody else a button that must fail.
            Boolean mayContinue = AgentKernel.mayContinue(run.executionIdentityId, run.initiatingActorId);
            Boolean queued =
                current != null &&
                (current.Status__c == AgentKernelModels.COMMAND_STATUS_PENDING ||
                current.Status__c == AgentKernelModels.COMMAND_STATUS_RETRY_WAITING);
            return new Map<String, Object>{
                'status' => run.status,
                'errorCode' => run.errorCode,
                'errorMessage' => run.errorMessage,
                'waitingReason' => run.waitingReason,
                'waitExpiresAt' => run.waitExpiresAt,
                'revision' => run.revision,
                'unknownToolName' => unknown == null ? null : unknown.ToolName__c,
                'canRescue' => run.status == AgentKernelModels.RUN_STATUS_PAUSED &&
                unknown == null &&
                mayContinue,
                'rescueBlockedReason' => mayContinue ? null : AgentKernel.INITIATING_USER_CONTINUE_REFUSED,
                'budget' => AgentKernel.budgetStanding(runId),
                'agentId' => run.agentDefinitionId,
                'canPause' => run.status == AgentKernelModels.RUN_STATUS_RUNNING && queued,
                // A paused run's Unknown call passed its deadline; cancelling leaves it unknown and never retries it.
                'canCancel' => !terminal && (unknown == null || run.status == AgentKernelModels.RUN_STATUS_PAUSED),
                'canReconcile' => unknown != null && ExecutionIdentityService.canReconcile(),
                // Confirm Failed with pause settles the call without continuing, so it stays open to every operator.
                'canReconcileContinue' => unknown != null &&
                ExecutionIdentityService.canReconcile() &&
                mayContinue
            };
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    @AuraEnabled
    public static Id rescue(Id runId, String guidance) {
        try {
            AgentKernelModels.RescueRequest request = new AgentKernelModels.RescueRequest();
            request.runId = runId;
            request.expectedRunRevision = AgentRunService.getRun(runId).revision;
            request.guidance = guidance;
            return AgentRunService.rescue(request);
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    @AuraEnabled
    public static void pause(Id runId, String reason) {
        try {
            AgentRunService.pause(runId, AgentRunService.getRun(runId).revision, reason);
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    @AuraEnabled
    public static void cancel(Id runId, String reason) {
        try {
            AgentRunService.cancel(runId, AgentRunService.getRun(runId).revision, reason);
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    /**
     * Records what the operator verified at the target system for the run's
     * Unknown tool call. decision is ConfirmSucceeded, ConfirmFailed, or Retry.
     */
    @AuraEnabled
    public static String reconcile(
        Id runId,
        String decision,
        String reason,
        String confirmedOutput,
        String failureMessage,
        Boolean safeToRetry,
        Boolean pauseRun
    ) {
        try {
            return AgentRunService.reconcileCurrentUnknown(runId, decision, reason, confirmedOutput, failureMessage, safeToRetry, pauseRun).runStatus;
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    /** The caller-visible health report as plain data for the Agent Core Health card. */
    @AuraEnabled
    public static Map<String, Object> getHealth(Integer lookbackHours) {
        try {
            AgentKernelHealthService.HealthRequest request = new AgentKernelHealthService.HealthRequest();
            request.lookbackHours = lookbackHours == null ? 24 : lookbackHours;
            return (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(AgentKernelHealthService.getHealth(request)));
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    /** Installs or repairs every Agent Core schedule as the current user, who becomes the schedule owner. */
    @AuraEnabled
    public static void installSchedules() {
        try {
            AgentCoreSchedules.install();
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    /** Verify on an Agent Execution Identity: signs in through its Named Credential and stores the result. */
    @AuraEnabled
    public static Map<String, Object> verifyExecutionIdentity(Id identityId) {
        try {
            AgentExecutionIdentityVerifier.Result result = AgentExecutionIdentityVerifier.verify(identityId);
            return new Map<String, Object>{ 'verified' => result.verified, 'message' => result.message };
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    /** Runs one bounded recovery pass now. */
    @AuraEnabled
    public static void runRecoveryNow() {
        try {
            CommandLeaseRecoveryScheduler.runNow();
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    private static AgentCommand__c command(Id commandId) {
        if (commandId == null) {
            return null;
        }
        List<AgentCommand__c> commands = [SELECT Id, Status__c FROM AgentCommand__c WHERE Id = :commandId WITH USER_MODE LIMIT 1];
        return commands.isEmpty() ? null : commands[0];
    }

    private static AgentCommand__c unknownCommand(Id runId) {
        List<AgentCommand__c> commands = [
            SELECT Id, OperationKey__c, ToolName__c
            FROM AgentCommand__c
            WHERE AgentRun__c = :runId AND Status__c = :AgentKernelModels.COMMAND_STATUS_UNKNOWN
            WITH USER_MODE
            LIMIT 1
        ];
        return commands.isEmpty() ? null : commands[0];
    }

    private static AuraHandledException auraError(Exception failure) {
        AuraHandledException error = new AuraHandledException(failure.getMessage());
        error.setMessage(failure.getMessage());
        return error;
    }
}
