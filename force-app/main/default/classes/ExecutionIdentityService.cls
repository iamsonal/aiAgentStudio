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
 * Resolves execution identity once at run creation and enforces the persisted
 * snapshot at every later dispatch boundary.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ExecutionIdentityService {
    public static final String CONTEXT_PENDING = 'Pending';
    public static final String CONTEXT_ESTABLISHED = 'Established';
    private static final String API_NAME_PATTERN = '^[A-Za-z][A-Za-z0-9_]*$';
    private static final String RUN_CONTROL_PERMISSION = 'AgentKernelRunControl';

    /** Platform users that belong to no one; an agent without an identity would act with their access. */
    private static final Set<String> UNOWNED_USER_TYPES = new Set<String>{ 'AutomatedProcess', 'Guest' };

    @TestVisible
    private static Set<String> testNamedCredentials;
    @TestVisible
    private static String userTypeForTest;

    public class Snapshot {
        public Id initiatingActorId;
        public String loopbackNamedCredential;
        public Id expectedPrincipalId;
        public Id executionIdentityId;
        public Id resolvedPrincipalId;
        public String contextStatus;
    }

    /** Whether a run acts as its Agent Execution Identity's user; otherwise it acts as the user who started it. */
    public static Boolean usesIdentity(AgentRun__c run) {
        return run != null && run.ExecutionIdentity__c != null;
    }

    /** Whether an agent's runs act as its Agent Execution Identity's user; otherwise they act as whoever starts them. */
    public static Boolean usesIdentity(AgentDefinition__c definition) {
        return definition != null && definition.ExecutionIdentity__c != null;
    }

    /**
     * Whether the current user already is the user the run acts as, so its next
     * step can be leased here without a loopback: the starter of a run without
     * an identity, or the established execution user of a run with one.
     */
    public static Boolean runsAsCurrentUser(AgentRun__c run) {
        Id currentUserId = UserInfo.getUserId();
        if (!usesIdentity(run)) {
            return run != null && run.InitiatingUser__c == currentUserId;
        }
        return run.ExecutionContextStatus__c == CONTEXT_ESTABLISHED && run.ResolvedPrincipalUser__c == currentUserId;
    }

    /**
     * An agent without an identity runs as whoever starts it, so it refuses
     * starts by users that belong to no one: scheduled and event-triggered
     * flows run as the Automated Process user, and sites as a guest.
     */
    public static void assertMayStart(AgentDefinition__c definition) {
        if (usesIdentity(definition)) {
            return;
        }
        String userType = userTypeForTest != null ? userTypeForTest : UserInfo.getUserType();
        if (UNOWNED_USER_TYPES.contains(userType)) {
            throw new AgentKernelException.ConfigurationException(
                'Agent ' +
                    definition.DeveloperName__c +
                    ' has no Agent Execution Identity, so it runs as the user who starts it. Scheduled flows, event-triggered flows, and site guests ' +
                    'can\'t start it. Set an Agent Execution Identity on the agent to start it from automation.'
            );
        }
    }

    public static Snapshot snapshotForStart(Id executionIdentityId) {
        Id actorId = UserInfo.getUserId();
        Snapshot result = new Snapshot();
        result.initiatingActorId = actorId;
        if (executionIdentityId == null) {
            result.expectedPrincipalId = actorId;
            result.resolvedPrincipalId = actorId;
            result.contextStatus = CONTEXT_ESTABLISHED;
            return result;
        }

        List<AgentExecutionIdentity__c> identities = [
            SELECT Id, PrincipalUser__c, PrincipalUser__r.IsActive, LoopbackNamedCredential__c, IsActive__c
            FROM AgentExecutionIdentity__c
            WHERE Id = :executionIdentityId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (identities.size() != 1 || identities[0].IsActive__c != true || identities[0].PrincipalUser__r.IsActive != true) {
            throw new AgentKernelException.ConfigurationException('The selected Agent Execution Identity must be active and have an active user.');
        }
        result.executionIdentityId = identities[0].Id;
        result.loopbackNamedCredential = identities[0].LoopbackNamedCredential__c.trim();
        result.expectedPrincipalId = identities[0].PrincipalUser__c;
        result.contextStatus = CONTEXT_PENDING;
        // The starter already is the identity's user, so the run needs no loopback to become it.
        if (actorId == result.expectedPrincipalId) {
            result.resolvedPrincipalId = actorId;
            result.contextStatus = CONTEXT_ESTABLISHED;
        }
        return result;
    }

    /** A Verify result describes one user and credential; changing either clears it, and a new identity starts unverified. */
    public static void clearStaleVerification(List<AgentExecutionIdentity__c> identities, Map<Id, AgentExecutionIdentity__c> previousById) {
        for (AgentExecutionIdentity__c identity : identities) {
            AgentExecutionIdentity__c previous = previousById == null ? null : previousById.get(identity.Id);
            if (
                previous == null ||
                previous.PrincipalUser__c != identity.PrincipalUser__c ||
                previous.LoopbackNamedCredential__c != identity.LoopbackNamedCredential__c
            ) {
                identity.VerifiedAt__c = null;
                identity.VerificationResult__c = previous == null ? null : 'Not verified since the user or Named Credential changed. Run Verify.';
            }
        }
    }

    /** Rejects an Agent Execution Identity whose user is inactive or whose Named Credential does not exist. */
    public static void validateIdentities(List<AgentExecutionIdentity__c> identities) {
        Set<Id> userIds = new Set<Id>();
        Set<String> credentialNames = new Set<String>();
        for (AgentExecutionIdentity__c identity : identities) {
            userIds.add(identity.PrincipalUser__c);
            String credential = String.isBlank(identity.LoopbackNamedCredential__c) ? null : identity.LoopbackNamedCredential__c.trim();
            if (credential == null || !Pattern.matches(API_NAME_PATTERN, credential)) {
                identity.addError(AgentExecutionIdentity__c.LoopbackNamedCredential__c, 'Enter the API name of an existing Named Credential.');
                continue;
            }
            identity.LoopbackNamedCredential__c = credential;
            credentialNames.add(credential);
        }
        Set<Id> activeUserIds = new Map<Id, User>([SELECT Id FROM User WHERE Id IN :userIds AND IsActive = TRUE WITH SYSTEM_MODE]).keySet();
        Set<String> existingCredentials = new Set<String>();
        if (Test.isRunningTest() && testNamedCredentials != null) {
            existingCredentials.addAll(testNamedCredentials);
        } else if (!credentialNames.isEmpty()) {
            for (NamedCredential credential : [SELECT DeveloperName FROM NamedCredential WHERE DeveloperName IN :credentialNames WITH SYSTEM_MODE]) {
                existingCredentials.add(credential.DeveloperName);
            }
        }
        Set<Id> approvalAuthorityUserIds = AgentHumanDecisionGuard.usersWithApprovalAuthority(activeUserIds);
        for (AgentExecutionIdentity__c identity : identities) {
            if (!activeUserIds.contains(identity.PrincipalUser__c)) {
                identity.addError(AgentExecutionIdentity__c.PrincipalUser__c, 'Select an active user.');
            }
            if (approvalAuthorityUserIds.contains(identity.PrincipalUser__c)) {
                identity.addError(
                    AgentExecutionIdentity__c.PrincipalUser__c,
                    'The execution identity\'s selected user runs the tools its agents choose, so it must not hold Agent Kernel Human Decision or Agent Kernel Approval Relay.'
                );
            }
            if (credentialNames.contains(identity.LoopbackNamedCredential__c) && !existingCredentials.contains(identity.LoopbackNamedCredential__c)) {
                identity.addError(AgentExecutionIdentity__c.LoopbackNamedCredential__c, 'No Named Credential with this API name exists.');
            }
        }
    }

    public static void assertExpectedPrincipal(AgentRun__c run) {
        if (run == null || run.ExpectedPrincipalUser__c == null || run.ExpectedPrincipalUser__c != UserInfo.getUserId()) {
            throw new AgentKernelException.ConfigurationException('The current user is not the run\'s execution user.');
        }
    }

    public static void assertCurrentActor(AgentRun__c run) {
        if (run == null || run.InitiatingUser__c == null) {
            throw new AgentKernelException.ConfigurationException('The run has no execution identity snapshot.');
        }
        if (!usesIdentity(run) && run.InitiatingUser__c != UserInfo.getUserId()) {
            throw new AgentKernelException.ConfigurationException(
                'A run of an agent without an Agent Execution Identity runs only as the user who started it.'
            );
        }
        if (usesIdentity(run) && String.isBlank(run.LoopbackNamedCredential__c)) {
            throw new AgentKernelException.ConfigurationException('The run has no snapshotted loopback Named Credential.');
        }
    }

    public static void assertCanCancel(AgentRun__c run) {
        assertIdentitySnapshot(run);
        if (isInitiatingActor(run) || hasRunControlPermission()) {
            return;
        }
        throw new AgentKernelException.ConfigurationException('The current user is not authorized to cancel this Agent Core run.');
    }

    public static void assertCanResume(AgentRun__c run) {
        assertIdentitySnapshot(run);
        if (isInitiatingActor(run)) {
            return;
        }
        if (usesIdentity(run) && hasRunControlPermission()) {
            return;
        }
        throw new AgentKernelException.ConfigurationException('The current user is not authorized to resume this Agent Core run.');
    }

    public static void assertCanAdminister(AgentRun__c run) {
        assertIdentitySnapshot(run);
        if (hasRunControlPermission()) {
            return;
        }
        throw new AgentKernelException.ConfigurationException('Agent Kernel Run Control permission is required to pause or rescue a run.');
    }

    /**
     * Confirming what an Unknown tool call did is an operator's check of the
     * outside system: it needs Run Control, and the run's own execution user
     * may never settle its own call.
     */
    public static void assertCanReconcile(AgentRun__c run) {
        assertIdentitySnapshot(run);
        Id callerId = UserInfo.getUserId();
        if (usesIdentity(run) && (callerId == run.ExpectedPrincipalUser__c || callerId == run.ResolvedPrincipalUser__c)) {
            throw new AgentKernelException.ConfigurationException('The execution user is not authorized to reconcile its own run.');
        }
        if (!hasRunControlPermission()) {
            throw new AgentKernelException.ConfigurationException(
                'The current user is not authorized to reconcile Agent Core work. Assign Agent Kernel Operator or Agent Kernel Admin.'
            );
        }
    }

    public static Boolean canReconcile() {
        return hasRunControlPermission();
    }

    public static void assertEstablishedBusinessPrincipal(AgentRun__c run) {
        assertCurrentActor(run);
        if (!usesIdentity(run)) {
            return;
        }
        assertExpectedPrincipal(run);
        if (
            run.ExecutionContextStatus__c != CONTEXT_ESTABLISHED ||
            run.ResolvedPrincipalUser__c == null ||
            run.ResolvedPrincipalUser__c != UserInfo.getUserId()
        ) {
            throw new AgentKernelException.ConfigurationException('Business work is not running as the run\'s execution user.');
        }
    }

    /**
     * True when an execution user about to run a model-chosen tool holds
     * decision or relay authority. Save-time validation cannot see grants added
     * later; the platform's effective check covers profiles, groups, and muting.
     */
    public static Boolean principalHoldsApprovalAuthority(AgentRun__c run) {
        return usesIdentity(run) && (AgentHumanDecisionGuard.isAuthorized() || AgentApprovalService.isRelayAuthorized());
    }

    private static void assertIdentitySnapshot(AgentRun__c run) {
        if (run == null || run.InitiatingUser__c == null) {
            throw new AgentKernelException.ConfigurationException('The run has no valid execution identity snapshot.');
        }
    }

    private static Boolean isInitiatingActor(AgentRun__c run) {
        return run.InitiatingUser__c == UserInfo.getUserId();
    }

    private static Boolean hasRunControlPermission() {
        return FeatureManagement.checkPermission(RUN_CONTROL_PERMISSION);
    }
}
