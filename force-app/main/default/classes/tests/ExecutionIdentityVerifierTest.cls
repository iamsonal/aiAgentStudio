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

@IsTest
private class ExecutionIdentityVerifierTest {
    @TestSetup
    static void createIdentity() {
        // Records are created here so each test's callout runs before any DML in its own transaction.
        User principal = AgentKernelTestFactory.servicePrincipalUser();
        AgentKernelTestFactory.serviceUser(principal.Id);
        AgentKernelTestFactory.grant(new List<String>{ AgentKernelTestFactory.ADMIN });
    }

    @IsTest
    static void credentialThatLandsOnTheSelectedUserIsVerified() {
        AgentExecutionIdentity__c identity = identity();
        Test.setMock(HttpCalloutMock.class, new ProbeMock(200, probe(identity.PrincipalUser__c, true, false)));

        AgentExecutionIdentityVerifier.Result result;
        // Setup records count as pending work; a mock callout after DML must run inside startTest and stopTest.
        Test.startTest();
        System.runAs(AgentKernelTestFactory.self()) {
            result = AgentExecutionIdentityVerifier.verify(identity.Id);
        }
        Test.stopTest();

        System.assertEquals(true, result.verified);
        System.assertEquals(AgentExecutionIdentityVerifier.VERIFIED, result.message);
        AgentExecutionIdentity__c stored = identity();
        System.assertNotEquals(null, stored.VerifiedAt__c);
        System.assertEquals(AgentExecutionIdentityVerifier.VERIFIED, stored.VerificationResult__c);
    }

    @IsTest
    static void credentialThatLandsOnAnotherUserFailsAndShowsInHealth() {
        AgentExecutionIdentity__c identity = identity();
        Test.setMock(HttpCalloutMock.class, new ProbeMock(200, probe(UserInfo.getUserId(), true, false)));

        AgentExecutionIdentityVerifier.Result result;
        Test.startTest();
        System.runAs(AgentKernelTestFactory.self()) {
            result = AgentExecutionIdentityVerifier.verify(identity.Id);
        }
        Test.stopTest();

        System.assertEquals(false, result.verified);
        System.assert(result.message.contains('different user'), result.message);
        AgentExecutionIdentity__c stored = identity();
        System.assertEquals(null, stored.VerifiedAt__c);
        System.assert(stored.VerificationResult__c.contains('different user'));
        AgentKernelHealthService.HealthReport report = AgentKernelHealthService.getHealth(new AgentKernelHealthService.HealthRequest());
        System.assertEquals(1, report.failedExecutionIdentities);
        System.assert(AgentKernelTestFactory.healthCount(report, AgentKernelHealthService.ACTION_IDENTITIES, 'failedExecutionIdentities') > 0);
    }

    @IsTest
    static void userWithoutServicePrincipalOrWithApprovalAuthorityFails() {
        AgentExecutionIdentity__c identity = identity();
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new ProbeMock(200, probe(identity.PrincipalUser__c, false, false)));
        System.runAs(AgentKernelTestFactory.self()) {
            System.assert(AgentExecutionIdentityVerifier.probe(identity).contains('lacks Agent Kernel Service Principal'));
        }
        Test.setMock(HttpCalloutMock.class, new ProbeMock(200, probe(identity.PrincipalUser__c, true, true)));
        System.runAs(AgentKernelTestFactory.self()) {
            System.assert(AgentExecutionIdentityVerifier.probe(identity).contains('Human Decision'));
        }
        Test.stopTest();
    }

    @IsTest
    static void refusedOrFailedSignInIsExplained() {
        AgentExecutionIdentity__c identity = identity();
        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new ProbeMock(403, '{}'));
        System.assert(AgentExecutionIdentityVerifier.probe(identity).contains('Assign Agent Kernel Service Principal'));
        Test.setMock(HttpCalloutMock.class, new ProbeMock(401, '{}'));
        System.assert(AgentExecutionIdentityVerifier.probe(identity).contains('HTTP 401'));
        Test.setMock(HttpCalloutMock.class, new ProbeMock(-1, null));
        System.assert(AgentExecutionIdentityVerifier.probe(identity).contains('could not sign in'));
        Test.stopTest();
    }

    @IsTest
    static void verifyRequiresRunControl() {
        AgentExecutionIdentity__c identity = identity();
        User plain = AgentKernelTestFactory.userWith(new List<String>());
        System.runAs(plain) {
            try {
                AgentExecutionIdentityVerifier.verify(identity.Id);
                System.assert(false, 'Verify needs Agent Kernel Admin or Operator.');
            } catch (AgentKernelException.AuthorizationException expected) {
                System.assert(expected.getMessage().contains('Admin or Operator'));
            }
        }
    }

    @IsTest
    static void changingTheCredentialClearsAnEarlierResult() {
        AgentExecutionIdentity__c identity = identity();
        ExecutionIdentityService.testNamedCredentials = new Set<String>{ AgentKernelTestFactory.TEST_LOOPBACK, 'Other_Loopback' };
        update new AgentExecutionIdentity__c(Id = identity.Id, VerifiedAt__c = System.now(), VerificationResult__c = AgentExecutionIdentityVerifier.VERIFIED);
        System.assertNotEquals(null, identity().VerifiedAt__c, 'Storing a result alone keeps it.');

        update new AgentExecutionIdentity__c(Id = identity.Id, LoopbackNamedCredential__c = 'Other_Loopback');

        AgentExecutionIdentity__c stored = identity();
        System.assertEquals(null, stored.VerifiedAt__c);
        System.assert(stored.VerificationResult__c.contains('Run Verify'));
    }

    @IsTest
    static void probeReportsTheCallersOwnIdentity() {
        ExecutionIdentityProbeRest.Probe probe = ExecutionIdentityProbeRest.whoAmI();
        System.assertEquals(UserInfo.getUserId(), probe.userId);
        System.assertNotEquals(null, probe.mayDispatch);
        System.assertNotEquals(null, probe.holdsApprovalAuthority);
    }

    private static AgentExecutionIdentity__c identity() {
        // Statics reset between setup and each test; the save rule checks the credential exists.
        if (ExecutionIdentityService.testNamedCredentials == null) {
            ExecutionIdentityService.testNamedCredentials = new Set<String>{ AgentKernelTestFactory.TEST_LOOPBACK };
        }
        return [
            SELECT Id, PrincipalUser__c, LoopbackNamedCredential__c, VerifiedAt__c, VerificationResult__c
            FROM AgentExecutionIdentity__c
            WHERE LoopbackNamedCredential__c = :AgentKernelTestFactory.TEST_LOOPBACK OR LoopbackNamedCredential__c = 'Other_Loopback'
            LIMIT 1
        ];
    }

    private static String probe(Id userId, Boolean mayDispatch, Boolean holdsApprovalAuthority) {
        return JSON.serialize(new Map<String, Object>{ 'userId' => userId, 'mayDispatch' => mayDispatch, 'holdsApprovalAuthority' => holdsApprovalAuthority });
    }

    private class ProbeMock implements HttpCalloutMock {
        private final Integer status;
        private final String body;

        ProbeMock(Integer status, String body) {
            this.status = status;
            this.body = body;
        }

        public HttpResponse respond(HttpRequest request) {
            System.assert(request.getEndpoint().endsWith('/services/apexrest/agent-core/v1/whoami'));
            if (status < 0) {
                throw new CalloutException('Unable to sign in.');
            }
            HttpResponse response = new HttpResponse();
            response.setStatusCode(status);
            response.setBody(body);
            return response;
        }
    }
}
