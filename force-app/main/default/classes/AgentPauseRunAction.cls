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

/** Flow action: Pause Agent Run. Needs Agent Kernel Operator or Agent Kernel Admin. */
global with sharing class AgentPauseRunAction {
    global class Request {
        @InvocableVariable(label='Run ID' required=true)
        global Id runId;

        @InvocableVariable(label='Reason' description='Why the run is paused. Shown on the run.')
        global String reason;
    }

    global class Result {
        @InvocableVariable(label='Status' description='The run status after the request.')
        global String status;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Pause Agent Run' description='Pauses a running run before its next step starts. Rescue it to continue.')
    global static List<Result> pause(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests == null ? new List<Request>() : requests) {
            Result result = new Result();
            results.add(result);
            try {
                AgentRunService.pause(request.runId, AgentRunService.getRun(request.runId).revision, request.reason);
                result.status = AgentRunService.getRun(request.runId).status;
            } catch (Exception failure) {
                result.errorMessage = failure.getMessage();
            }
        }
        return results;
    }
}
