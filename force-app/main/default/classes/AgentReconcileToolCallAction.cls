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
 * Flow action: Reconcile Agent Tool Call. Records what an operator found in the
 * outside system for the run's Unknown tool call. Needs Agent Kernel Operator
 * or Agent Kernel Admin; the run's own execution user is refused.
 */
global with sharing class AgentReconcileToolCallAction {
    global class Request {
        @InvocableVariable(label='Run ID' required=true)
        global Id runId;

        @InvocableVariable(label='Decision' description='ConfirmSucceeded, ConfirmFailed, or Retry.' required=true)
        global String decision;

        @InvocableVariable(label='Reason' description='What you checked in the outside system.' required=true)
        global String reason;

        @InvocableVariable(label='Confirmed Output' description='For ConfirmSucceeded: the call\'s result as a JSON object.')
        global String confirmedOutput;

        @InvocableVariable(label='Failure Message' description='For ConfirmFailed: what went wrong. The agent sees it.')
        global String failureMessage;

        @InvocableVariable(label='Safe to Retry' description='For Retry: true only when repeating the call cannot do the work twice.')
        global Boolean safeToRetry;

        @InvocableVariable(label='Pause Run' description='For ConfirmFailed: true to pause the run instead of telling the agent.')
        global Boolean pauseRun;
    }

    global class Result {
        @InvocableVariable(label='Status' description='The run status after the decision.')
        global String status;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Reconcile Agent Tool Call' description='Records what an outside system shows for a tool call whose outcome is Unknown.')
    global static List<Result> reconcile(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests == null ? new List<Request>() : requests) {
            Result result = new Result();
            results.add(result);
            try {
                result.status = AgentRunService.reconcileCurrentUnknown(
                        request.runId,
                        request.decision,
                        request.reason,
                        request.confirmedOutput,
                        request.failureMessage,
                        request.safeToRetry,
                        request.pauseRun
                    )
                    .runStatus;
            } catch (Exception failure) {
                result.errorMessage = failure.getMessage();
            }
        }
        return results;
    }
}
