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

/** Flow action: Cancel Agent Run. The running user must have started the run or hold Agent Kernel Run Control. */
global with sharing class AgentCancelRunAction {
    global class Request {
        @InvocableVariable(label='Run ID' required=true)
        global Id runId;

        @InvocableVariable(label='Reason' description='Why the run is cancelled.')
        global String reason;
    }

    global class Result {
        @InvocableVariable(label='Status' description='The run status after the request; Cancelled, or unchanged while a running step finishes.')
        global String status;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Cancel Agent Run' description='Cancels a run that has not finished.')
    global static List<Result> cancel(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests == null ? new List<Request>() : requests) {
            Result result = new Result();
            results.add(result);
            try {
                AgentKernelModels.RunRecord run = AgentRunService.getRun(request.runId);
                AgentRunService.cancel(request.runId, run.revision, request.reason);
                result.status = AgentRunService.getRun(request.runId).status;
            } catch (Exception failure) {
                result.errorMessage = failure.getMessage();
            }
        }
        return results;
    }
}
