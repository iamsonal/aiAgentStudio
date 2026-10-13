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

/** Flow action: Dismiss Agent Operational Issue. Needs Agent Kernel Operator or Agent Kernel Admin. */
global with sharing class AgentDismissIssueAction {
    global class Request {
        @InvocableVariable(label='Issue ID' required=true)
        global Id issueId;

        @InvocableVariable(label='Reason' description='What you did about the issue. Kept on the issue.' required=true)
        global String reason;
    }

    global class Result {
        @InvocableVariable(label='Dismissed' description='True when the issue was open and is now closed.')
        global Boolean dismissed;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(label='Dismiss Agent Operational Issue' description='Closes an open issue you handled, with a reason.')
    global static List<Result> dismiss(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests == null ? new List<Request>() : requests) {
            Result result = new Result();
            result.dismissed = false;
            results.add(result);
            try {
                result.dismissed = AgentOperationalIssues.dismiss(new Set<Id>{ request.issueId }, request.reason) == 1;
            } catch (Exception failure) {
                result.errorMessage = failure.getMessage();
            }
        }
        return results;
    }
}
