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
 * Performs the durable, DML-only command lease transition. Callers choose how
 * to dispatch a leased worker; this service never performs a callout or enqueues.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class CommandLeaseService {
    public static final Integer LEASE_SECONDS = 300;

    public enum Outcome {
        Leased,
        Deferred,
        Noop
    }

    public class Result {
        public Outcome outcome;
        public AgentRun__c run;
        public AgentCommand__c command;
        public Integer delayMinutes;
    }

    public class ServicePrincipalLeaseRequest {
        public Id runId;
        public Id commandId;
        public Decimal expectedRevision;
        public String operationKey;
        public String dispatchToken;
    }

    /**
     * Fuses loopback identity acceptance and command leasing for a bounded
     * batch of runs with an identity. Runs and commands are each locked once so the
     * query count does not grow with the number of envelopes.
     */
    public static List<Result> tryLeaseServicePrincipalBatch(List<ServicePrincipalLeaseRequest> requests) {
        return leaseBatch(requests, true);
    }

    /**
     * Leases a bounded batch of commands whose runs already run as the
     * current user, with the same constant query and DML cost, so a bulk
     * start or recovery pass reaches each worker in one hop.
     */
    public static List<Result> tryLeaseCurrentUserBatch(List<ServicePrincipalLeaseRequest> requests) {
        return leaseBatch(requests, false);
    }

    private static List<Result> leaseBatch(List<ServicePrincipalLeaseRequest> requests, Boolean acceptsLoopbackIdentity) {
        List<Result> results = new List<Result>();
        if (requests == null || requests.isEmpty()) {
            return results;
        }
        Set<Id> runIds = new Set<Id>();
        Set<Id> commandIds = new Set<Id>();
        for (ServicePrincipalLeaseRequest request : requests) {
            if (request != null && request.runId != null && request.commandId != null) {
                runIds.add(request.runId);
                commandIds.add(request.commandId);
            }
        }
        Map<Id, AgentRun__c> runsById = lockRuns(runIds);
        for (ServicePrincipalLeaseRequest request : requests) {
            if (request != null && !runsById.containsKey(request.runId)) {
                commandIds.remove(request.commandId);
            }
        }
        Map<Id, AgentCommand__c> commandsById = new Map<Id, AgentCommand__c>(
            [
                SELECT
                    Id,
                    AgentRun__c,
                    CommandType__c,
                    Status__c,
                    ExpectedRunRevision__c,
                    OperationKey__c,
                    DispatchToken__c,
                    AttemptNumber__c,
                    AvailableAt__c,
                    LeaseToken__c,
                    LeaseExpiresAt__c,
                    RecoveryCheckAt__c,
                    ToolName__c,
                    AdmittedEffects__c,
                    AdmittedToolBindingHash__c,
                    WorkerJobId__c,
                    WorkerEnqueuedAt__c
                FROM AgentCommand__c
                WHERE Id IN :commandIds
                WITH SYSTEM_MODE
                FOR UPDATE
            ]
        );
        Datetime nowValue = System.now();
        Id currentPrincipal = UserInfo.getUserId();
        Map<Id, AgentRun__c> runsToUpdate = new Map<Id, AgentRun__c>();
        Map<Id, AgentCommand__c> commandsToUpdate = new Map<Id, AgentCommand__c>();
        Set<Id> toolRunIds = new Set<Id>();
        for (AgentCommand__c candidate : commandsById.values()) {
            if (candidate.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL) {
                toolRunIds.add(candidate.AgentRun__c);
            }
        }
        Map<Id, List<AgentTool__c>> toolsByRun = AgentRunConfigurationService.getToolsByRunIds(toolRunIds);
        Set<Id> processedCommandIds = new Set<Id>();
        for (ServicePrincipalLeaseRequest request : requests) {
            Result result = new Result();
            result.outcome = Outcome.Noop;
            results.add(result);
            AgentRun__c run = request == null ? null : runsById.get(request.runId);
            AgentCommand__c command = request == null ? null : commandsById.get(request.commandId);
            Boolean valid = acceptsLoopbackIdentity
                ? isCurrentServicePrincipalRequest(request, run, command, currentPrincipal)
                : isCurrentUserRequest(request, run, command);
            if (!valid || processedCommandIds.contains(command.Id)) {
                continue;
            }
            result.run = run;
            result.command = command;
            processedCommandIds.add(command.Id);
            if (
                acceptsLoopbackIdentity &&
                (run.ResolvedPrincipalUser__c == null ||
                run.ExecutionContextStatus__c != ExecutionIdentityService.CONTEXT_ESTABLISHED)
            ) {
                run.ResolvedPrincipalUser__c = currentPrincipal;
                run.ExecutionContextStatus__c = ExecutionIdentityService.CONTEXT_ESTABLISHED;
                runsToUpdate.put(run.Id, run);
            }
            if (command.AvailableAt__c != null && command.AvailableAt__c > nowValue) {
                result.outcome = Outcome.Deferred;
                result.delayMinutes = Integer.valueOf(Math.ceil(Decimal.valueOf(command.AvailableAt__c.getTime() - nowValue.getTime()) / 60000));
                continue;
            }
            command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
            command.LeaseToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
            command.LeaseExpiresAt__c = nowValue.addSeconds(LEASE_SECONDS);
            command.RecoveryCheckAt__c = command.LeaseExpiresAt__c;
            command.AttemptNumber__c = (command.AttemptNumber__c == null ? 0 : command.AttemptNumber__c) + 1;
            admitTool(command, toolsByRun.get(run.Id));
            commandsToUpdate.put(command.Id, command);
            result.outcome = Outcome.Leased;
        }
        if (!runsToUpdate.isEmpty()) {
            AgentLifecycleStore.updateRuns(runsToUpdate.values());
        }
        if (!commandsToUpdate.isEmpty()) {
            List<AgentCommand__c> leaseUpdates = new List<AgentCommand__c>();
            for (AgentCommand__c command : commandsToUpdate.values()) {
                leaseUpdates.add(
                    new AgentCommand__c(
                        Id = command.Id,
                        Status__c = command.Status__c,
                        LeaseToken__c = command.LeaseToken__c,
                        LeaseExpiresAt__c = command.LeaseExpiresAt__c,
                        RecoveryCheckAt__c = command.RecoveryCheckAt__c,
                        AdmittedEffects__c = command.AdmittedEffects__c,
                        AdmittedToolBindingHash__c = command.AdmittedToolBindingHash__c,
                        AttemptNumber__c = command.AttemptNumber__c,
                        WorkerJobId__c = null,
                        WorkerEnqueuedAt__c = null
                    )
                );
            }
            AgentLifecycleStore.updateCommands(leaseUpdates);
        }
        return results;
    }

    /**
     * Locks the batch's runs in one query. When another transaction holds one
     * of them, each run is locked on its own so the held run waits for the
     * next recovery pass instead of failing the whole batch.
     */
    private static Map<Id, AgentRun__c> lockRuns(Set<Id> runIds) {
        try {
            return new Map<Id, AgentRun__c>(queryRunsForUpdate(runIds));
        } catch (QueryException batchLockUnavailable) {
            Map<Id, AgentRun__c> runsById = new Map<Id, AgentRun__c>();
            for (Id runId : runIds) {
                try {
                    runsById.putAll(queryRunsForUpdate(new Set<Id>{ runId }));
                } catch (QueryException lockUnavailable) {
                    AgentOperationsLog.emit(LoggingLevel.WARN, 'DISPATCH_RUN_LOCKED', runId, null, null, null);
                }
            }
            return runsById;
        }
    }

    private static List<AgentRun__c> queryRunsForUpdate(Set<Id> runIds) {
        return [
            SELECT
                Id,
                InitiatingUser__c,
                ExecutionIdentity__c,
                LoopbackNamedCredential__c,
                ExpectedPrincipalUser__c,
                ResolvedPrincipalUser__c,
                ExecutionContextStatus__c,
                Status__c,
                Revision__c,
                CurrentCommand__c
            FROM AgentRun__c
            WHERE Id IN :runIds
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
    }

    public static Result tryLease(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String dispatchToken) {
        Result result = new Result();
        result.outcome = Outcome.Noop;
        List<AgentRun__c> runs = [
            SELECT
                Id,
                InitiatingUser__c,
                ExecutionIdentity__c,
                LoopbackNamedCredential__c,
                ExpectedPrincipalUser__c,
                ResolvedPrincipalUser__c,
                ExecutionContextStatus__c,
                Status__c,
                Revision__c,
                CurrentCommand__c
            FROM AgentRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (runs.isEmpty()) {
            return result;
        }
        AgentRun__c run = runs[0];
        ExecutionIdentityService.assertEstablishedBusinessPrincipal(run);
        List<AgentCommand__c> commands = [
            SELECT
                Id,
                AgentRun__c,
                CommandType__c,
                Status__c,
                ExpectedRunRevision__c,
                OperationKey__c,
                DispatchToken__c,
                AttemptNumber__c,
                AvailableAt__c,
                LeaseToken__c,
                LeaseExpiresAt__c,
                RecoveryCheckAt__c,
                ToolName__c,
                AdmittedEffects__c,
                AdmittedToolBindingHash__c,
                WorkerJobId__c,
                WorkerEnqueuedAt__c
            FROM AgentCommand__c
            WHERE Id = :commandId AND AgentRun__c = :run.Id
            WITH SYSTEM_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (commands.isEmpty()) {
            return result;
        }
        AgentCommand__c command = commands[0];
        if (
            run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING ||
            run.CurrentCommand__c != command.Id ||
            run.Revision__c != expectedRevision ||
            run.Revision__c != command.ExpectedRunRevision__c ||
            String.isBlank(operationKey) ||
            !operationKey.equals(command.OperationKey__c) ||
            String.isBlank(dispatchToken) ||
            !dispatchToken.equals(command.DispatchToken__c) ||
            !new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING }.contains(command.Status__c)
        ) {
            return result;
        }
        result.run = run;
        result.command = command;
        Datetime nowValue = System.now();
        if (command.AvailableAt__c != null && command.AvailableAt__c > nowValue) {
            result.outcome = Outcome.Deferred;
            result.delayMinutes = Integer.valueOf(Math.ceil(Decimal.valueOf(command.AvailableAt__c.getTime() - nowValue.getTime()) / 60000));
            return result;
        }
        command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
        command.LeaseToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128));
        command.LeaseExpiresAt__c = nowValue.addSeconds(LEASE_SECONDS);
        command.RecoveryCheckAt__c = command.LeaseExpiresAt__c;
        command.AttemptNumber__c = (command.AttemptNumber__c == null ? 0 : command.AttemptNumber__c) + 1;
        if (command.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL) {
            admitTool(command, AgentRunConfigurationService.getTools(run.Id));
        }
        AgentLifecycleStore.updateCommands(
            new List<AgentCommand__c>{
                new AgentCommand__c(
                    Id = command.Id,
                    Status__c = command.Status__c,
                    LeaseToken__c = command.LeaseToken__c,
                    LeaseExpiresAt__c = command.LeaseExpiresAt__c,
                    RecoveryCheckAt__c = command.RecoveryCheckAt__c,
                    AdmittedEffects__c = command.AdmittedEffects__c,
                    AdmittedToolBindingHash__c = command.AdmittedToolBindingHash__c,
                    AttemptNumber__c = command.AttemptNumber__c,
                    WorkerJobId__c = null,
                    WorkerEnqueuedAt__c = null
                )
            }
        );
        result.outcome = Outcome.Leased;
        return result;
    }

    public static void releaseUndeliveredLease(Id commandId, String expectedLeaseToken) {
        if (commandId == null || String.isBlank(expectedLeaseToken)) {
            return;
        }
        List<AgentCommand__c> commands = [
            SELECT Id, Status__c, LeaseToken__c, LeaseExpiresAt__c, RecoveryCheckAt__c, WorkerJobId__c, WorkerEnqueuedAt__c
            FROM AgentCommand__c
            WHERE Id = :commandId
            WITH SYSTEM_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (
            commands.isEmpty() ||
            commands[0].Status__c != AgentKernelModels.COMMAND_STATUS_LEASED ||
            !expectedLeaseToken.equals(commands[0].LeaseToken__c) ||
            commands[0].WorkerJobId__c != null
        ) {
            return;
        }
        AgentLifecycleStore.updateCommands(
            new List<AgentCommand__c>{
                new AgentCommand__c(
                    Id = commands[0].Id,
                    Status__c = AgentKernelModels.COMMAND_STATUS_PENDING,
                    LeaseToken__c = null,
                    LeaseExpiresAt__c = null,
                    RecoveryCheckAt__c = null,
                    WorkerJobId__c = null,
                    WorkerEnqueuedAt__c = null
                )
            }
        );
    }

    private static void admitTool(AgentCommand__c command, List<AgentTool__c> tools) {
        if (command.CommandType__c != AgentKernelModels.COMMAND_TYPE_TOOL || command.AdmittedToolBindingHash__c != null) {
            return;
        }
        for (AgentTool__c tool : tools == null ? new List<AgentTool__c>() : tools) {
            if (tool.DeveloperName__c.equalsIgnoreCase(command.ToolName__c) && AgentToolTypeService.toolType(tool) != null) {
                AgentToolTypeService.admit(command, tool);
                return;
            }
        }
    }

    private static Boolean isCurrentUserRequest(ServicePrincipalLeaseRequest request, AgentRun__c run, AgentCommand__c command) {
        return request != null &&
            run != null &&
            command != null &&
            ExecutionIdentityService.runsAsCurrentUser(run) &&
            run.Status__c == AgentKernelModels.RUN_STATUS_RUNNING &&
            run.CurrentCommand__c == command.Id &&
            run.Revision__c == request.expectedRevision &&
            command.AgentRun__c == run.Id &&
            new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING }.contains(command.Status__c) &&
            command.ExpectedRunRevision__c == run.Revision__c &&
            !String.isBlank(request.operationKey) &&
            request.operationKey.equals(command.OperationKey__c) &&
            !String.isBlank(request.dispatchToken) &&
            request.dispatchToken.equals(command.DispatchToken__c);
    }

    private static Boolean isCurrentServicePrincipalRequest(
        ServicePrincipalLeaseRequest request,
        AgentRun__c run,
        AgentCommand__c command,
        Id currentPrincipal
    ) {
        return request != null &&
            run != null &&
            command != null &&
            ExecutionIdentityService.usesIdentity(run) &&
            run.ExpectedPrincipalUser__c == currentPrincipal &&
            run.Status__c == AgentKernelModels.RUN_STATUS_RUNNING &&
            run.CurrentCommand__c == command.Id &&
            run.Revision__c == request.expectedRevision &&
            !String.isBlank(run.LoopbackNamedCredential__c) &&
            (run.ResolvedPrincipalUser__c == null ||
            run.ResolvedPrincipalUser__c == currentPrincipal) &&
            command.AgentRun__c == run.Id &&
            new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING }.contains(command.Status__c) &&
            command.ExpectedRunRevision__c == run.Revision__c &&
            command.ExpectedRunRevision__c == request.expectedRevision &&
            !String.isBlank(request.operationKey) &&
            request.operationKey.equals(command.OperationKey__c) &&
            !String.isBlank(request.dispatchToken) &&
            request.dispatchToken.equals(command.DispatchToken__c);
    }
}
