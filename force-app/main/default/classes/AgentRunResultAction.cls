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
 * Flow action: Get Agent Run Result. Returns status and, for a succeeded run or a
 * conversation waiting for the person's reply, the latest answer. Anyone who can
 * read the run gets the answer with protected values as tokens; only Agent Kernel
 * Trust Resolver holders get the real values, and that is audited.
 * Bulk-safe: each batch of up to 200 requests costs a fixed number of queries and one audit write.
 */
global with sharing class AgentRunResultAction {
    private static final Integer BATCH_SIZE = 200;

    global class Request {
        @InvocableVariable(label='Run ID' required=true)
        global Id runId;
    }

    global class Result {
        @InvocableVariable(label='Status' description='Running, Waiting, Paused, Succeeded, Failed, or Cancelled.')
        global String status;

        @InvocableVariable(
            label='Output'
            description='Final answer of a succeeded run, or the latest answer of a conversation waiting for a reply. Protected values stay as tokens such as {{EMAIL_1_9f2c61ab}} unless the running user has Agent Kernel Trust Resolver.'
        )
        global String output;

        @InvocableVariable(label='Error Code')
        global String errorCode;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Get Agent Run Result'
        description='Returns the status of a run and its answer: the final answer of a succeeded run, or the latest answer of a conversation waiting for a reply.'
    )
    global static List<Result> getResult(List<Request> requests) {
        List<Request> received = requests == null ? new List<Request>() : requests;
        List<Result> results = new List<Result>();
        for (Integer index = 0; index < received.size(); index++) {
            results.add(new Result());
        }
        for (Integer offset = 0; offset < received.size(); offset += BATCH_SIZE) {
            Integer last = Math.min(received.size(), offset + BATCH_SIZE);
            try {
                fill(received, results, offset, last);
            } catch (Exception failure) {
                for (Integer index = offset; index < last; index++) {
                    results[index].errorMessage = failure.getMessage();
                }
            }
        }
        return results;
    }

    private static void fill(List<Request> requests, List<Result> results, Integer first, Integer last) {
        Set<Id> runIds = new Set<Id>();
        for (Integer index = first; index < last; index++) {
            Id runId = requests[index] == null ? null : requests[index].runId;
            if (runId != null) {
                runIds.add(runId);
            }
        }
        Map<Id, AgentKernelModels.RunRecord> runs = AgentRunService.getRuns(runIds);
        Set<Id> answered = new Set<Id>();
        for (AgentKernelModels.RunRecord run : runs.values()) {
            if (TrustService.hasResolvableAnswer(run.status, run.continuationMode)) {
                answered.add(run.id);
            }
        }
        Boolean canResolve = TrustService.isFinalOutputResolutionPermitted();
        Map<Id, TrustService.FinalOutput> outputs = canResolve && !answered.isEmpty()
            ? TrustService.resolveFinalOutputs(answered)
            : new Map<Id, TrustService.FinalOutput>();
        for (Integer index = first; index < last; index++) {
            Result result = results[index];
            Id runId = requests[index] == null ? null : requests[index].runId;
            AgentKernelModels.RunRecord run = runId == null ? null : runs.get(runId);
            if (run == null) {
                result.errorMessage = runId == null ? 'Run ID is required.' : 'Agent run was not found.';
                continue;
            }
            result.status = run.status;
            result.errorCode = run.errorCode;
            result.errorMessage = run.errorMessage;
            if (!answered.contains(runId)) {
                continue;
            }
            if (!canResolve) {
                // Reading the run is enough for the answer; revealing protected values is not.
                result.output = run.output;
                continue;
            }
            TrustService.FinalOutput output = outputs.get(runId);
            if (output != null && output.failure != null) {
                result.errorMessage = output.failure.getMessage();
            } else if (output != null) {
                result.output = output.output;
            }
        }
    }
}
