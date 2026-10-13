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
 * Runs a run's next Only This Org tool calls in the current transaction, in
 * the model's order, each with its own lease, savepoint, and outcome. DML may
 * follow a callout, but no callout may follow DML, so a worker calls this
 * after its own callout and outside calls keep their own job. It stops at the
 * first call that cannot run here or at low headroom (40% of any limit left),
 * and the worker's finalizer dispatches whatever command is current after the
 * single commit. A limit error loses the worker's whole transaction, so only a
 * worker whose own command may repeat calls this.
 */
public without sharing class InPlaceToolRunner {
    /** Share of each governor limit kept free before another tool call runs in this transaction. */
    private static final Decimal RESERVE = 0.4;
    /** Tests set how many headroom checks pass before headroom runs out. */
    @TestVisible
    private static Integer headroomChecksForTest;

    public static void runNext(Id runId, Map<String, AgentTool__c> toolsByName, Id workerJobId, CommandContinuationFinalizer continuationFinalizer) {
        while (true) {
            List<AgentRun__c> runs = [
                SELECT Id, Status__c, CurrentCommand__c
                FROM AgentRun__c
                WHERE Id = :runId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (runs.isEmpty() || runs[0].Status__c != AgentKernelModels.RUN_STATUS_RUNNING || runs[0].CurrentCommand__c == null) {
                return;
            }
            AgentCommand__c next = [
                SELECT Id, CommandType__c, ToolName__c, ExpectedRunRevision__c, OperationKey__c, DispatchToken__c
                FROM AgentCommand__c
                WHERE Id = :runs[0].CurrentCommand__c
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            AgentTool__c tool = next.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL &&
                next.ToolName__c != null
                ? toolsByName.get(next.ToolName__c.toLowerCase())
                : null;
            if (tool == null || AgentToolTypeService.effects(tool) != AgentToolTypeService.EFFECTS_IN_ORG || !hasHeadroom()) {
                return;
            }
            CommandLeaseService.Result lease = CommandLeaseService.tryLease(
                runId,
                next.Id,
                next.ExpectedRunRevision__c,
                next.OperationKey__c,
                next.DispatchToken__c
            );
            if (lease.outcome != CommandLeaseService.Outcome.Leased) {
                return;
            }
            // The admitted Effects are what the call runs under; the tool type may have changed since the check above.
            if (!AgentToolTypeService.runsInSavepoint(lease.command)) {
                CommandLeaseService.releaseUndeliveredLease(next.Id, lease.command.LeaseToken__c);
                return;
            }
            CommandDeliveryTracker.recordJob(next.Id, workerJobId);
            new ToolCommandExecutor(runId, next.Id, lease.command.ExpectedRunRevision__c, lease.command.OperationKey__c, lease.command.LeaseToken__c)
                .run(workerJobId, continuationFinalizer);
        }
    }

    /** The run's tools keyed by lower-case API name, as runNext looks them up. */
    public static Map<String, AgentTool__c> byName(List<AgentTool__c> tools) {
        Map<String, AgentTool__c> result = new Map<String, AgentTool__c>();
        for (AgentTool__c tool : tools) {
            result.put(tool.DeveloperName__c.toLowerCase(), tool);
        }
        return result;
    }

    private static Boolean hasHeadroom() {
        if (headroomChecksForTest != null) {
            headroomChecksForTest--;
            return headroomChecksForTest >= 0;
        }
        return ExtensionExecutionGuard.hasRequiredHeadroom() &&
            withinReserve(Limits.getQueries(), Limits.getLimitQueries()) &&
            withinReserve(Limits.getDmlStatements(), Limits.getLimitDmlStatements()) &&
            withinReserve(Limits.getCpuTime(), Limits.getLimitCpuTime()) &&
            withinReserve(Limits.getHeapSize(), Limits.getLimitHeapSize());
    }

    private static Boolean withinReserve(Integer used, Integer limitValue) {
        return used <= limitValue * (1 - RESERVE);
    }
}
