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

/** Flow action: Rescue Agent Run. Needs Agent Kernel Operator or Agent Kernel Admin. */
global with sharing class AgentRescueRunAction {
    global class Request {
        @InvocableVariable(label='Run ID' required=true)
        global Id runId;

        @InvocableVariable(label='Guidance' description='What the agent should do differently. Reaches the model as operator guidance.')
        global String guidance;
    }

    global class Result {
        @InvocableVariable(label='Next Command ID' description='The step the run continues with.')
        global Id nextCommandId;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Rescue Agent Run' description='Continues a paused run, optionally with your guidance.')
    global static List<Result> rescue(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests == null ? new List<Request>() : requests) {
            Result result = new Result();
            results.add(result);
            try {
                AgentKernelModels.RescueRequest rescue = new AgentKernelModels.RescueRequest();
                rescue.runId = request.runId;
                rescue.expectedRunRevision = AgentRunService.getRun(request.runId).revision;
                rescue.guidance = request.guidance;
                result.nextCommandId = AgentRunService.rescue(rescue);
            } catch (Exception failure) {
                result.errorMessage = failure.getMessage();
            }
        }
        return results;
    }
}
