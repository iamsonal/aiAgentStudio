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
 * Verify for an Agent Execution Identity. It signs in through the identity's
 * Named Credential, as the person verifying, and checks that the credential
 * lands on the selected user, that the user may run Core's loopback, and that
 * it holds no approval authority. The result is stored on the identity, so a
 * wrong credential shows up at setup instead of as a stuck run.
 *
 * The callout runs as the caller, so it also proves the caller may use the
 * credential. People who start runs of agents with an identity need the same access.
 */
global with sharing class AgentExecutionIdentityVerifier {
    public static final String VERIFIED = 'Verified';
    private static final String RUN_CONTROL_PERMISSION = 'AgentKernelRunControl';
    private static final Integer TIMEOUT_MILLISECONDS = 20000;

    global class Result {
        @InvocableVariable(label='Verified' description='True when the Named Credential signs in as the selected user and that user can run Core work.')
        global Boolean verified;

        @InvocableVariable(label='Message' description='Verified, or the problem found and how to fix it.')
        global String message;
    }

    global class Request {
        @InvocableVariable(label='Agent Execution Identity ID' required=true)
        global Id identityId;
    }

    @InvocableMethod(
        label='Verify Agent Execution Identity'
        description='Signs in through the identity\'s Named Credential and checks that it lands on the selected user. Run it before any record changes in the same transaction.'
    )
    global static List<Result> verify(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests == null ? new List<Request>() : requests) {
            results.add(verify(request == null ? null : request.identityId));
        }
        return results;
    }

    /** Verifies one identity and stores the outcome on it. */
    global static Result verify(Id identityId) {
        if (!FeatureManagement.checkPermission(RUN_CONTROL_PERMISSION)) {
            throw new AgentKernelException.AuthorizationException('Agent Kernel Admin or Operator access is required to verify an execution identity.');
        }
        List<AgentExecutionIdentity__c> identities = [
            SELECT Id, PrincipalUser__c, LoopbackNamedCredential__c
            FROM AgentExecutionIdentity__c
            WHERE Id = :identityId
            WITH USER_MODE
            LIMIT 1
        ];
        if (identities.isEmpty()) {
            throw new AgentKernelException.NotFoundException('The Agent Execution Identity was not found or is not visible to you.');
        }
        AgentExecutionIdentity__c identity = identities[0];
        Result result = new Result();
        result.message = probe(identity);
        result.verified = result.message == VERIFIED;
        // Not all-or-none: an identity that save-time rules now reject (for example, its user gained
        // approval authority) still gets its answer back, and the rule's own error shows on its next save.
        Database.update(
            new AgentExecutionIdentity__c(
                Id = identity.Id,
                VerifiedAt__c = result.verified ? System.now() : null,
                VerificationResult__c = result.message.left(255)
            ),
            false,
            AccessLevel.SYSTEM_MODE
        );
        AgentOperationsLog.emit(
            result.verified ? LoggingLevel.INFO : LoggingLevel.WARN,
            result.verified ? 'EXECUTION_IDENTITY_VERIFIED' : 'EXECUTION_IDENTITY_UNVERIFIED',
            null,
            null,
            null,
            null
        );
        return result;
    }

    @TestVisible
    private static String probe(AgentExecutionIdentity__c identity) {
        HttpRequest request = new HttpRequest();
        request.setMethod('GET');
        request.setEndpoint('callout:' + identity.LoopbackNamedCredential__c + '/services/apexrest/agent-core/v1/whoami');
        request.setTimeout(TIMEOUT_MILLISECONDS);
        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (CalloutException failure) {
            return 'The Named Credential could not sign in, or you may not use it. Check its External Credential and your principal access, then verify again.';
        }
        Integer status = response.getStatusCode();
        if (status == 401) {
            return 'The Named Credential could not sign in (HTTP 401). Check its certificate and that the user is pre-authorized for the app.';
        }
        if (status == 403 || status == 404) {
            return 'The credential signs in, but that user cannot reach Agent Core. Assign Agent Kernel Service Principal to the selected user.';
        }
        if (status < 200 || status >= 300) {
            return 'Agent Core could not be reached through the credential (HTTP ' + status + '). Try again later.';
        }
        Map<String, Object> body;
        try {
            body = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
        } catch (Exception unreadable) {
            return 'The credential returned an unexpected response. Check that its URL is this org\'s My Domain URL.';
        }
        String signedInAs = body.get('userId') instanceof String ? (String) body.get('userId') : null;
        if (signedInAs == null || signedInAs != String.valueOf(identity.PrincipalUser__c)) {
            return 'The credential signs in as a different user (' + signedInAs + '), not the selected user. Fix the credential or select that user.';
        }
        if (body.get('mayDispatch') != true) {
            return 'The credential signs in as the selected user, but the user lacks Agent Kernel Service Principal. Assign it.';
        }
        if (body.get('holdsApprovalAuthority') == true) {
            return 'The selected user holds Agent Kernel Human Decision or Approval Relay. Remove them; an execution user never approves.';
        }
        return VERIFIED;
    }
}
