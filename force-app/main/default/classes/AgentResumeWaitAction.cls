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
 * Flow action: Resume Agent Wait. An outside system's answer to a tool that is
 * waiting for it. The resume key the tool handed out is the authority, so the
 * integration user needs no Run Control and no run revision; the key works
 * only while that call's wait is the run's current one.
 */
global with sharing class AgentResumeWaitAction {
    global class Request {
        @InvocableVariable(label='Resume Key' description='The key the waiting tool gave the outside system. Treat it as a secret.' required=true)
        global String resumeKey;

        @InvocableVariable(label='Payload' description='The outside system\'s answer as JSON that matches the wait\'s resume schema.' required=true)
        global String payload;
    }

    global class Result {
        @InvocableVariable(label='Resumed' description='True when the run continues with this answer.')
        global Boolean resumed;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Resume Agent Wait' description='Gives a waiting agent tool the outside system\'s answer, using the resume key the tool handed out.')
    global static List<Result> resume(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests == null ? new List<Request>() : requests) {
            Result result = new Result();
            result.resumed = false;
            results.add(result);
            Savepoint beforeResume = Database.setSavepoint();
            try {
                AgentRunService.resumeWait(request == null ? null : request.resumeKey, request == null ? null : request.payload);
                result.resumed = true;
            } catch (Exception failure) {
                Database.rollback(beforeResume);
                result.errorMessage = failure.getMessage();
            } finally {
                Database.releaseSavepoint(beforeResume);
            }
        }
        return results;
    }
}
