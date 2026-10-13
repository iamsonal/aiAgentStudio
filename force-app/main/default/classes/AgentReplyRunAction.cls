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
 * Flow action: Reply to Agent Run. Sends a person's next message to a
 * conversational run (Wait for Reply set) that is waiting for them, so a
 * record-page or screen flow can hold a conversation without Apex. The
 * running user must have started the run or hold Agent Kernel Run Control;
 * Core looks up the run's revision itself.
 */
global with sharing class AgentReplyRunAction {
    global class Request {
        @InvocableVariable(label='Run ID' required=true)
        global Id runId;

        @InvocableVariable(label='Message' description='The person\'s next message to the agent.' required=true)
        global String message;
    }

    global class Result {
        @InvocableVariable(label='Status' description='The run status after the reply: Running while the agent answers, or Paused when its budget is spent.')
        global String status;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Reply to Agent Run'
        description='Sends a person\'s next message to a conversational agent run that is waiting for their reply. Read the answer with Get Agent Run Result.'
    )
    global static List<Result> reply(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests == null ? new List<Request>() : requests) {
            Result result = new Result();
            results.add(result);
            Savepoint beforeReply = Database.setSavepoint();
            try {
                if (request == null || String.isBlank(request.message)) {
                    throw new AgentKernelException.InvalidTransitionException('Enter the message to send to the agent.');
                }
                AgentKernelModels.RunRecord run = AgentRunService.getRun(request.runId);
                if (run.continuationMode != AgentKernelModels.CONTINUATION_CONVERSATION) {
                    throw new AgentKernelException.InvalidTransitionException(
                        'This run is not waiting for a person\'s reply. Only an agent with Wait for Reply set takes replies.'
                    );
                }
                AgentKernelModels.ResumeRequest resume = new AgentKernelModels.ResumeRequest();
                resume.runId = request.runId;
                resume.expectedRunRevision = run.revision;
                resume.payload = JSON.serialize(new Map<String, Object>{ 'message' => request.message });
                AgentRunService.resume(resume);
                result.status = AgentRunService.getRun(request.runId).status;
            } catch (Exception failure) {
                Database.rollback(beforeReply);
                result.errorMessage = failure.getMessage();
            } finally {
                Database.releaseSavepoint(beforeReply);
            }
        }
        return results;
    }
}
