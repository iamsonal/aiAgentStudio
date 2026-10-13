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
 * Core approval authority. Chooses the approver for a waiting tool call, owns
 * the Agent Approval record that mirrors the wait, and decides who may act on
 * it. Approval channels deliver requests and relay decisions; they never
 * decide eligibility for Core-assigned approvals.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class AgentApprovalService {
    public static final String RELAY_PERMISSION = 'AgentKernelApprovalRelay';
    public static final Integer DEFAULT_TIMEOUT_HOURS = 24;
    public static final Integer MAX_TIMEOUT_HOURS = 168;
    private static final Integer MAX_MEMBERSHIP_DEPTH = 5;
    private static final Integer MAX_ROLE_DEPTH = 10;

    private static Boolean coreWrite = false;
    /** Lifecycle transition published when an administrator gives a pending approval a new owner. */
    public static final String TRANSITION_APPROVAL_REASSIGNED = 'ApprovalReassigned';

    private static final Set<String> APPROVER_TYPES = new Set<String>{
        AgentKernelModels.APPROVER_USER,
        AgentKernelModels.APPROVER_QUEUE,
        AgentKernelModels.APPROVER_ANCHOR_OWNER,
        AgentKernelModels.APPROVER_REQUESTER_MANAGER,
        AgentKernelModels.APPROVER_DELIVERY_CHANNEL
    };

    /** The resolved assignment and deadline for one approval, fixed when the wait begins. */
    public class Request {
        public String reason;
        public Datetime expiresAt;
        public Id ownerId;
        public String approverType;
        public String expiryAction;
        /** The tool whose call waits; recorded on the approval so routing and reports need no tool names. */
        public Id toolId;
    }

    /** A wait that cannot be assigned to an eligible approver; the run pauses instead of waiting unseen. */
    public class AssignmentException extends Exception {
    }

    /** Who decided, and which channel user relayed it when the decider acted elsewhere. */
    public class Authorization {
        public Id deciderId;
        public Id relayedById;
    }

    /**
     * Resolves the approver from the policy override or the tool's typed
     * settings. Runs as the execution user inside the tool worker.
     */
    public static Request request(AgentRun__c run, AgentTool__c tool, String reason, Integer policyTimeoutSeconds, Id policyApproverId) {
        Request result = new Request();
        result.toolId = tool.Id;
        result.reason = String.isBlank(reason) ? 'Tool configuration requires approval.' : reason;
        result.expiryAction = String.isBlank(tool.ApprovalExpiryAction__c) ? AgentKernelModels.APPROVAL_EXPIRY_DENY : tool.ApprovalExpiryAction__c;
        Integer timeoutSeconds = policyTimeoutSeconds != null
            ? policyTimeoutSeconds
            : (tool.ApprovalTimeoutHours__c == null ? DEFAULT_TIMEOUT_HOURS : tool.ApprovalTimeoutHours__c.intValue()) * 3600;
        result.expiresAt = System.now().addSeconds(timeoutSeconds);

        if (policyApproverId != null) {
            result.approverType = policyApproverId.getSObjectType() == User.SObjectType ? AgentKernelModels.APPROVER_USER : AgentKernelModels.APPROVER_QUEUE;
            result.ownerId = policyApproverId;
        } else {
            result.approverType = tool.ApproverType__c;
            Boolean hasFallbackQueue = result.approverType == AgentKernelModels.APPROVER_ANCHOR_OWNER && !String.isBlank(tool.ApproverQueue__c);
            try {
                result.ownerId = configuredOwner(run, tool);
            } catch (AssignmentException noOwner) {
                if (!hasFallbackQueue) {
                    throw noOwner;
                }
            }
            if (
                result.approverType == AgentKernelModels.APPROVER_ANCHOR_OWNER &&
                !String.isBlank(tool.ApproverQueue__c) &&
                !anchorOwnerCanDecide(run, result.ownerId)
            ) {
                // The owner cannot decide: the tool's fallback queue checks the call instead of pausing the run.
                Map<String, Id> fallback = approvalQueues(new Set<String>{ tool.ApproverQueue__c.trim() });
                result.approverType = AgentKernelModels.APPROVER_QUEUE;
                result.ownerId = fallback.isEmpty() ? null : fallback.values()[0];
            }
        }
        if (result.approverType == AgentKernelModels.APPROVER_DELIVERY_CHANNEL) {
            return result;
        }
        if (result.ownerId == null) {
            throw new AssignmentException('No approver could be resolved for tool ' + tool.DeveloperName__c + ' (' + result.approverType + ').');
        }
        if (result.ownerId.getSObjectType() == User.SObjectType) {
            assertEligibleUser(run, result.ownerId);
        } else if (result.ownerId.getSObjectType() == Group.SObjectType) {
            if (!queueSupportsApprovals(result.ownerId)) {
                throw new AssignmentException('The approver queue must be a queue that supports Agent Approval records.');
            }
            if (!hasEligibleMember(run, result.ownerId)) {
                throw new AssignmentException('The approver queue has no active member with Agent Kernel Human Decision who may decide this call.');
            }
        } else {
            throw new AssignmentException('An approver must be a User or a Queue.');
        }
        return result;
    }

    /** Inserts the Agent Approval for a wait the kernel has just persisted. */
    public static AgentApproval__c open(AgentRun__c run, AgentCommand__c command, Request request) {
        AgentApproval__c approval = new AgentApproval__c(
            AgentRun__c = run.Id,
            AgentCommand__c = command.Id,
            AgentTool__c = request.toolId,
            ToolName__c = command.ToolName__c,
            // A policy may build its reason from record data, so it is stored like any other protected text.
            Reason__c = bounded(protectedText(run.Id, bounded(request.reason, 255)), 255),
            Status__c = AgentKernelModels.APPROVAL_STATUS_PENDING,
            ApproverType__c = request.approverType,
            RequestedBy__c = run.InitiatingUser__c,
            ExpiresAt__c = request.expiresAt,
            ExpiryAction__c = request.expiryAction,
            RunRevision__c = run.Revision__c
        );
        // A Delivery Channel approval has no Core-assigned approver; the requester owns it
        // rather than the execution user that inserts it, which never decides or relays.
        approval.OwnerId = request.ownerId != null ? request.ownerId : run.InitiatingUser__c;
        write(new List<AgentApproval__c>{ approval }, true);
        return approval;
    }

    public static AgentApproval__c lock(Id approvalId) {
        List<AgentApproval__c> approvals = [
            SELECT
                Id,
                OwnerId,
                AgentRun__c,
                AgentCommand__c,
                Status__c,
                ApproverType__c,
                RequestedBy__c,
                ExpiresAt__c,
                ExpiryAction__c,
                RunRevision__c,
                DecidedBy__c
            FROM AgentApproval__c
            WHERE Id = :approvalId
            WITH SYSTEM_MODE
            LIMIT 1
            FOR UPDATE
        ];
        if (approvals.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent approval was not found.');
        }
        return approvals[0];
    }

    /**
     * A direct decider must hold Human Decision and be the owner or a direct
     * member of the owning queue. A relay must hold Approval Relay and name an
     * active decider with Human Decision; Core still checks assignment unless
     * the approval is routed by a Delivery Channel. Neither may be the run's
     * execution user, and the requester decides only when allowed.
     */
    public static Authorization authorize(AgentApproval__c approval, AgentRun__c run, Id requestedDeciderId) {
        Id callerId = UserInfo.getUserId();
        if (isExecutionPrincipal(run, callerId)) {
            throw new AgentKernelException.AuthorizationException('The execution user cannot decide or relay approvals for its own runs.');
        }
        Authorization result = new Authorization();
        if (requestedDeciderId != null && requestedDeciderId != callerId) {
            if (!isRelayAuthorized()) {
                throw new AgentKernelException.AuthorizationException(
                    'Only an approval channel user with Agent Kernel Approval Relay can record another user\'s decision.'
                );
            }
            if (!AgentHumanDecisionGuard.isAuthorizedUser(requestedDeciderId)) {
                throw new AgentKernelException.AuthorizationException('The decider must be an active user with Agent Kernel Human Decision permission.');
            }
            result.deciderId = requestedDeciderId;
            result.relayedById = callerId;
        } else {
            if (approval.ApproverType__c == AgentKernelModels.APPROVER_DELIVERY_CHANNEL) {
                throw new AgentKernelException.AuthorizationException('This approval is decided through its approval channel.');
            }
            AgentHumanDecisionGuard.assertAuthorized();
            result.deciderId = callerId;
        }
        if (isExecutionPrincipal(run, result.deciderId)) {
            throw new AgentKernelException.AuthorizationException('The execution user cannot decide an approval.');
        }
        if (approval.ApproverType__c != AgentKernelModels.APPROVER_DELIVERY_CHANNEL && !isAssignee(approval.OwnerId, result.deciderId)) {
            throw new AgentKernelException.AuthorizationException('Only the assigned approver or a member of the assigned queue can decide this approval.');
        }
        // The channel's process shares the approval with its reviewers; a relay cannot name anyone else.
        if (
            approval.ApproverType__c == AgentKernelModels.APPROVER_DELIVERY_CHANNEL &&
            !AttendedAccessService.readableRecordIds(result.deciderId, new Set<Id>{ approval.Id }).contains(approval.Id)
        ) {
            throw new AgentKernelException.AuthorizationException('The decider must be able to read this approval.');
        }
        return result;
    }

    /**
     * Returns the plaintext input of a pending approval to a reviewer who could
     * decide it. Delivery Channel approvals are reviewable by any Human Decision
     * holder who can read the record, because the channel grants that access.
     */
    public static String resolveInput(Id approvalId) {
        AgentApproval__c approval = lock(approvalId);
        if (approval.Status__c != AgentKernelModels.APPROVAL_STATUS_PENDING) {
            throw new AgentKernelException.InvalidTransitionException('Only a pending approval has input to review.');
        }
        assertReviewer(approval);
        return TrustService.resolveWaitingToolInput(approval.AgentRun__c, approval.AgentCommand__c);
    }

    /** Refuses anyone who could not decide this approval. */
    public static void assertReviewer(AgentApproval__c approval) {
        AgentHumanDecisionGuard.assertAuthorized();
        Boolean reviewable = approval.ApproverType__c == AgentKernelModels.APPROVER_DELIVERY_CHANNEL
            ? [SELECT COUNT() FROM AgentApproval__c WHERE Id = :approval.Id WITH USER_MODE] == 1
            : isAssignee(approval.OwnerId, UserInfo.getUserId());
        if (!reviewable) {
            throw new AgentKernelException.AuthorizationException('This request is assigned to other approvers. Only they can see and decide it.');
        }
    }

    public static void close(AgentApproval__c approval, String status, Authorization authorization, String comment) {
        AgentApproval__c closed = new AgentApproval__c(Id = approval.Id, Status__c = status, ClosedAt__c = System.now());
        if (authorization != null) {
            closed.DecidedBy__c = authorization.deciderId;
            closed.RelayedBy__c = authorization.relayedById;
        }
        closed.DecisionComment__c = bounded(comment, 2000);
        write(new List<AgentApproval__c>{ closed }, false);
    }

    /** Closes the pending approvals of commands whose wait ended without a decision. */
    public static void closePending(Set<Id> commandIds, String status) {
        if (commandIds == null || commandIds.isEmpty()) {
            return;
        }
        List<AgentApproval__c> closed = new List<AgentApproval__c>();
        for (AgentApproval__c approval : [
            SELECT Id
            FROM AgentApproval__c
            WHERE AgentCommand__c IN :commandIds AND Status__c = :AgentKernelModels.APPROVAL_STATUS_PENDING
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            closed.add(new AgentApproval__c(Id = approval.Id, Status__c = status, ClosedAt__c = System.now()));
        }
        write(closed, false);
    }

    /** Pending approvals of the given commands, keyed by command, locked for an expiry transition. */
    public static Map<Id, AgentApproval__c> pendingByCommand(Set<Id> commandIds) {
        Map<Id, AgentApproval__c> result = new Map<Id, AgentApproval__c>();
        if (commandIds == null || commandIds.isEmpty()) {
            return result;
        }
        for (AgentApproval__c approval : [
            SELECT Id, AgentCommand__c, ExpiryAction__c
            FROM AgentApproval__c
            WHERE AgentCommand__c IN :commandIds AND Status__c = :AgentKernelModels.APPROVAL_STATUS_PENDING
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            result.put(approval.AgentCommand__c, approval);
        }
        return result;
    }

    /** Closes already-loaded pending approvals without another query. */
    public static void closeAll(List<AgentApproval__c> approvals, String status) {
        List<AgentApproval__c> closed = new List<AgentApproval__c>();
        for (AgentApproval__c approval : approvals) {
            closed.add(new AgentApproval__c(Id = approval.Id, Status__c = status, ClosedAt__c = System.now()));
        }
        write(closed, false);
    }

    /**
     * Clears the narrative of approvals whose run passed its payload deadline.
     * Who decided, the outcome, and the times stay. A blank
     * Reason marks a purged approval, because Core always sets one.
     */
    public static void purgeForRetention(List<AgentApproval__c> approvals) {
        if (approvals == null || approvals.isEmpty()) {
            return;
        }
        List<AgentApproval__c> purged = new List<AgentApproval__c>();
        for (AgentApproval__c approval : approvals) {
            purged.add(new AgentApproval__c(Id = approval.Id, Reason__c = null, DecisionComment__c = null));
        }
        coreWrite = true;
        try {
            Database.update(purged, AccessLevel.SYSTEM_MODE);
        } finally {
            coreWrite = false;
        }
    }

    /** Deletes approvals of runs the record-retention job is deleting. */
    public static void deleteForRetention(List<AgentApproval__c> approvals) {
        if (approvals == null || approvals.isEmpty()) {
            return;
        }
        coreWrite = true;
        try {
            Database.delete(approvals, AccessLevel.SYSTEM_MODE);
        } finally {
            coreWrite = false;
        }
    }

    /**
     * Only Core creates, decides, and closes approvals. Administrators may
     * reassign a pending approval by changing its owner; nothing else changes.
     */
    public static void guard(List<AgentApproval__c> records, Map<Id, AgentApproval__c> previousById, Boolean isDelete) {
        if (coreWrite) {
            return;
        }
        List<AgentApproval__c> reassigned = new List<AgentApproval__c>();
        for (AgentApproval__c record : records) {
            if (previousById == null || isDelete) {
                record.addError('Agent Approvals are created, decided, and deleted only by Agent Core.');
                continue;
            }
            AgentApproval__c previous = previousById.get(record.Id);
            Map<String, Object> current = record.getPopulatedFieldsAsMap();
            Boolean rejected = false;
            for (String fieldName : current.keySet()) {
                if (fieldName == 'OwnerId' || fieldName == 'LastModifiedDate' || fieldName == 'LastModifiedById' || fieldName == 'SystemModstamp') {
                    continue;
                }
                if (current.get(fieldName) != previous.get(fieldName)) {
                    record.addError('Only the owner of a pending Agent Approval can be changed; decide it with the Decide action.');
                    rejected = true;
                    break;
                }
            }
            if (record.OwnerId != previous.OwnerId && previous.Status__c != AgentKernelModels.APPROVAL_STATUS_PENDING) {
                record.addError('Only a pending Agent Approval can be reassigned.');
            } else if (record.OwnerId != previous.OwnerId && previous.ApproverType__c == AgentKernelModels.APPROVER_DELIVERY_CHANNEL) {
                // The channel decides who reviews it, and the owner's access is what a relay checks.
                record.addError('An Approval Process approval is routed by its approval process; reassign it there.');
            } else if (record.OwnerId != previous.OwnerId && !rejected) {
                reassigned.add(record);
            }
        }
        reassigned = eligibleReassignments(reassigned, previousById);
        publishReassigned(reassigned);
    }

    /**
     * Keeps reassignments whose new owner could decide the call, as Core
     * checks when it assigns one; rejects the rest at save, so an approval
     * never waits for someone who cannot decide it.
     */
    private static List<AgentApproval__c> eligibleReassignments(List<AgentApproval__c> reassigned, Map<Id, AgentApproval__c> previousById) {
        if (reassigned.isEmpty()) {
            return reassigned;
        }
        Set<Id> runIds = new Set<Id>();
        Set<Id> userOwnerIds = new Set<Id>();
        for (AgentApproval__c record : reassigned) {
            runIds.add(previousById.get(record.Id).AgentRun__c);
            if (record.OwnerId.getSObjectType() == User.SObjectType) {
                userOwnerIds.add(record.OwnerId);
            }
        }
        Map<Id, AgentRun__c> runs = new Map<Id, AgentRun__c>(
            [SELECT Id, ExecutionIdentity__c, ExpectedPrincipalUser__c, ResolvedPrincipalUser__c FROM AgentRun__c WHERE Id IN :runIds WITH SYSTEM_MODE]
        );
        Set<Id> deciders = AgentHumanDecisionGuard.usersWithDecisionAuthority(userOwnerIds);
        List<AgentApproval__c> accepted = new List<AgentApproval__c>();
        for (AgentApproval__c record : reassigned) {
            AgentRun__c run = runs.get(previousById.get(record.Id).AgentRun__c);
            String problem;
            if (run == null) {
                problem = 'The approval\'s run was not found.';
            } else if (record.OwnerId.getSObjectType() == User.SObjectType) {
                if (isExecutionPrincipal(run, record.OwnerId)) {
                    problem = 'The execution user cannot be the approver.';
                } else if (!deciders.contains(record.OwnerId)) {
                    problem = 'The new approver must be an active user with Agent Kernel Human Decision permission.';
                }
            } else if (record.OwnerId.getSObjectType() == Group.SObjectType) {
                if (!queueSupportsApprovals(record.OwnerId)) {
                    problem = 'The new approver queue must list Agent Approval as a supported object.';
                } else if (!hasEligibleMember(run, record.OwnerId)) {
                    problem = 'The new approver queue has no active member with Agent Kernel Human Decision who may decide this call.';
                }
            } else {
                problem = 'An approver must be a User or a Queue.';
            }
            if (problem == null) {
                accepted.add(record);
            } else {
                record.OwnerId.addError(problem);
            }
        }
        return accepted;
    }

    /**
     * Tells delivery packages that a pending approval has a new owner, so they
     * can notify the new approver. The event publishes immediately, so a save
     * that fails later can still announce it; subscribers re-read the pending
     * approval and its owner before notifying anyone.
     */
    private static void publishReassigned(List<AgentApproval__c> approvals) {
        List<AgentLifecyclePublisher.Notification> notifications = new List<AgentLifecyclePublisher.Notification>();
        for (AgentApproval__c approval : approvals) {
            AgentLifecyclePublisher.Notification notification = new AgentLifecyclePublisher.Notification();
            notification.run = new AgentRun__c(Id = approval.AgentRun__c, Status__c = AgentKernelModels.RUN_STATUS_WAITING);
            notification.transition = TRANSITION_APPROVAL_REASSIGNED;
            notifications.add(notification);
        }
        if (!notifications.isEmpty()) {
            AgentLifecyclePublisher.publishBatch(notifications);
        }
    }

    /** Who may decide each approval directly, for delivery packages that message approvers. */
    public class Deciders {
        public List<Id> userIds = new List<Id>();
        /** True when more people may decide than were returned. */
        public Boolean capped = false;
    }

    /**
     * The active users who may decide each Core-assigned approval: its owner, or
     * the members of its owning queue, who hold Human Decision and are not the
     * run's service user. Delivery Channel approvals have none. At most
     * maxPerApproval users per approval, in a stable order.
     */
    public static Map<Id, Deciders> eligibleDeciders(List<AgentApproval__c> approvals, Integer maxPerApproval) {
        Map<Id, Deciders> result = new Map<Id, Deciders>();
        Set<Id> runIds = new Set<Id>();
        for (AgentApproval__c approval : approvals == null ? new List<AgentApproval__c>() : approvals) {
            runIds.add(approval.AgentRun__c);
        }
        Map<Id, AgentRun__c> runs = new Map<Id, AgentRun__c>(
            [SELECT Id, ExecutionIdentity__c, ExpectedPrincipalUser__c, ResolvedPrincipalUser__c FROM AgentRun__c WHERE Id IN :runIds WITH SYSTEM_MODE]
        );
        Map<Id, Set<Id>> candidatesByApproval = new Map<Id, Set<Id>>();
        Map<Id, Set<Id>> membersByQueue = new Map<Id, Set<Id>>();
        Set<Id> allCandidates = new Set<Id>();
        for (AgentApproval__c approval : approvals == null ? new List<AgentApproval__c>() : approvals) {
            Set<Id> candidates = new Set<Id>();
            AgentRun__c run = runs.get(approval.AgentRun__c);
            if (run != null && approval.OwnerId != null && approval.ApproverType__c != AgentKernelModels.APPROVER_DELIVERY_CHANNEL) {
                if (approval.OwnerId.getSObjectType() == User.SObjectType) {
                    candidates.add(approval.OwnerId);
                } else if (approval.OwnerId.getSObjectType() == Group.SObjectType) {
                    if (!membersByQueue.containsKey(approval.OwnerId)) {
                        membersByQueue.put(approval.OwnerId, queueMemberIds(approval.OwnerId));
                    }
                    candidates.addAll(membersByQueue.get(approval.OwnerId));
                }
                candidates.remove(run.ExpectedPrincipalUser__c);
                candidates.remove(run.ResolvedPrincipalUser__c);
            }
            candidatesByApproval.put(approval.Id, candidates);
            allCandidates.addAll(candidates);
        }
        Set<Id> eligible = AgentHumanDecisionGuard.usersWithDecisionAuthority(allCandidates);
        Integer limitPerApproval = Math.max(1, maxPerApproval == null ? 1 : maxPerApproval);
        for (Id approvalId : candidatesByApproval.keySet()) {
            List<Id> ordered = new List<Id>();
            for (Id candidate : candidatesByApproval.get(approvalId)) {
                if (eligible.contains(candidate)) {
                    ordered.add(candidate);
                }
            }
            ordered.sort();
            Deciders deciders = new Deciders();
            for (Integer index = 0; index < Math.min(limitPerApproval, ordered.size()); index++) {
                deciders.userIds.add(ordered[index]);
            }
            deciders.capped = ordered.size() > limitPerApproval;
            result.put(approvalId, deciders);
        }
        return result;
    }

    /** Save-time rules for a tool's approval settings. */
    public static void validateTools(List<AgentTool__c> records) {
        Set<Id> approverUserIds = new Set<Id>();
        Set<String> queueNames = new Set<String>();
        for (AgentTool__c record : records) {
            String error = settingsError(record);
            if (error != null) {
                record.addError(error);
                continue;
            }
            if (record.ApproverType__c == AgentKernelModels.APPROVER_USER) {
                approverUserIds.add(record.ApproverUser__c);
            } else if (record.ApproverType__c == AgentKernelModels.APPROVER_QUEUE) {
                queueNames.add(record.ApproverQueue__c.trim());
            } else if (record.ApproverType__c == AgentKernelModels.APPROVER_ANCHOR_OWNER && !String.isBlank(record.ApproverQueue__c)) {
                queueNames.add(record.ApproverQueue__c.trim());
            }
        }
        Map<String, Id> queuesByName = approvalQueues(queueNames);
        Set<Id> eligibleUserIds = new Set<Id>();
        for (Id userId : approverUserIds) {
            if (AgentHumanDecisionGuard.isAuthorizedUser(userId)) {
                eligibleUserIds.add(userId);
            }
        }
        for (AgentTool__c record : records) {
            if (
                record.ApproverType__c == AgentKernelModels.APPROVER_USER &&
                record.ApproverUser__c != null &&
                !eligibleUserIds.contains(record.ApproverUser__c)
            ) {
                record.ApproverUser__c.addError('The approver must be an active user with Agent Kernel Human Decision permission.');
            }
            Boolean namesQueue =
                record.ApproverType__c == AgentKernelModels.APPROVER_QUEUE ||
                record.ApproverType__c == AgentKernelModels.APPROVER_ANCHOR_OWNER;
            if (namesQueue && !String.isBlank(record.ApproverQueue__c)) {
                Id queueId = queuesByName.get(record.ApproverQueue__c.trim().toLowerCase());
                if (queueId == null) {
                    record.ApproverQueue__c.addError('Enter the API name of a queue that lists Agent Approval as a supported object.');
                }
            }
        }
    }

    public static Boolean isRelayAuthorized() {
        return FeatureManagement.checkPermission(RELAY_PERMISSION);
    }

    private static String settingsError(AgentTool__c record) {
        String approverType = record.ApproverType__c;
        if (record.RequiresApproval__c == true && String.isBlank(approverType)) {
            return 'Choose an Approver Type for a tool that requires approval.';
        }
        if (!String.isBlank(approverType) && !APPROVER_TYPES.contains(approverType)) {
            return 'Approver Type is invalid.';
        }
        if (approverType == AgentKernelModels.APPROVER_USER && record.ApproverUser__c == null) {
            return 'Select the Approver User.';
        }
        if (approverType != AgentKernelModels.APPROVER_USER && record.ApproverUser__c != null) {
            return 'Approver User applies only when Approver Type is User.';
        }
        if (approverType == AgentKernelModels.APPROVER_QUEUE && String.isBlank(record.ApproverQueue__c)) {
            return 'Enter the Approver Queue API name.';
        }
        if (
            approverType != AgentKernelModels.APPROVER_QUEUE &&
            approverType != AgentKernelModels.APPROVER_ANCHOR_OWNER &&
            !String.isBlank(record.ApproverQueue__c)
        ) {
            return 'Approver Queue applies only when Approver Type is Queue, or Anchor Record Owner as its fallback queue.';
        }
        if (
            record.ApprovalTimeoutHours__c != null &&
            (record.ApprovalTimeoutHours__c < 1 ||
            record.ApprovalTimeoutHours__c > MAX_TIMEOUT_HOURS ||
            record.ApprovalTimeoutHours__c != record.ApprovalTimeoutHours__c.intValue())
        ) {
            return 'Approval Timeout must be a whole number of hours from 1 to ' + MAX_TIMEOUT_HOURS + '.';
        }
        if (String.isBlank(approverType) && record.ApprovalTimeoutHours__c != null) {
            return 'Approval settings apply only when an Approver Type is chosen.';
        }
        return null;
    }

    private static Id configuredOwner(AgentRun__c run, AgentTool__c tool) {
        String approverType = tool.ApproverType__c;
        if (String.isBlank(approverType)) {
            throw new AssignmentException('Tool ' + tool.DeveloperName__c + ' has no Approver Type, and the authorization policy named no approver.');
        }
        if (approverType == AgentKernelModels.APPROVER_USER) {
            return tool.ApproverUser__c;
        }
        if (approverType == AgentKernelModels.APPROVER_QUEUE) {
            Map<String, Id> queues = approvalQueues(new Set<String>{ tool.ApproverQueue__c == null ? '' : tool.ApproverQueue__c.trim() });
            return queues.isEmpty() ? null : queues.values()[0];
        }
        if (approverType == AgentKernelModels.APPROVER_ANCHOR_OWNER) {
            return anchorOwner(run.AnchorRecordId__c);
        }
        if (approverType == AgentKernelModels.APPROVER_REQUESTER_MANAGER) {
            List<User> requesters = [SELECT ManagerId FROM User WHERE Id = :run.InitiatingUser__c WITH SYSTEM_MODE LIMIT 1];
            return requesters.isEmpty() ? null : requesters[0].ManagerId;
        }
        if (approverType == AgentKernelModels.APPROVER_DELIVERY_CHANNEL) {
            return null;
        }
        throw new AssignmentException('Approver Type is invalid.');
    }

    private static Id anchorOwner(String anchorRecordId) {
        if (String.isBlank(anchorRecordId)) {
            throw new AssignmentException('Anchor Record Owner approval needs a run started with an anchor record.');
        }
        Id anchorId = Id.valueOf(anchorRecordId);
        Schema.DescribeSObjectResult describe = anchorId.getSObjectType().getDescribe();
        if (!describe.fields.getMap().containsKey('ownerid')) {
            throw new AssignmentException('The anchor record\'s object has no owner.');
        }
        List<SObject> anchors = Database.queryWithBinds(
            'SELECT OwnerId FROM ' + describe.getName() + ' WHERE Id = :anchorId LIMIT 1',
            new Map<String, Object>{ 'anchorId' => anchorId },
            AccessLevel.SYSTEM_MODE
        );
        return anchors.isEmpty() ? null : (Id) anchors[0].get('OwnerId');
    }

    /**
     * Whether the anchor's owner may decide this run's call: a queue that lists
     * Agent Approval and has an eligible member, or an active user with Human
     * Decision who is not the run's service user. A Case queue usually lists
     * only Case, so its calls go to the tool's fallback queue.
     */
    private static Boolean anchorOwnerCanDecide(AgentRun__c run, Id ownerId) {
        if (ownerId == null) {
            return false;
        }
        if (ownerId.getSObjectType() == Group.SObjectType) {
            return queueSupportsApprovals(ownerId) && hasEligibleMember(run, ownerId);
        }
        if (ownerId.getSObjectType() != User.SObjectType) {
            return false;
        }
        return !isExecutionPrincipal(run, ownerId) && AgentHumanDecisionGuard.isAuthorizedUser(ownerId);
    }

    private static void assertEligibleUser(AgentRun__c run, Id userId) {
        if (isExecutionPrincipal(run, userId)) {
            throw new AssignmentException('The execution user cannot be the approver.');
        }
        if (!AgentHumanDecisionGuard.isAuthorizedUser(userId)) {
            throw new AssignmentException('The resolved approver is inactive or lacks Agent Kernel Human Decision permission.');
        }
    }

    private static Boolean isExecutionPrincipal(AgentRun__c run, Id userId) {
        return userId != null &&
            ExecutionIdentityService.usesIdentity(run) &&
            (userId == run.ExpectedPrincipalUser__c ||
            userId == run.ResolvedPrincipalUser__c);
    }

    private static Boolean isAssignee(Id ownerId, Id userId) {
        if (ownerId == null || userId == null) {
            return false;
        }
        if (ownerId == userId) {
            return true;
        }
        return ownerId.getSObjectType() == Group.SObjectType && queueMemberIds(ownerId).contains(userId);
    }

    /**
     * Active users who are members of a queue directly or through public
     * groups, roles, or roles and subordinates, as Salesforce resolves queue
     * membership. Nesting is expanded to MAX_MEMBERSHIP_DEPTH levels.
     */
    private static Set<Id> queueMemberIds(Id queueId) {
        Set<Id> userIds = new Set<Id>();
        Set<Id> roleIds = new Set<Id>();
        Set<Id> subordinateRoleIds = new Set<Id>();
        Set<Id> visitedGroupIds = new Set<Id>{ queueId };
        Set<Id> frontier = new Set<Id>{ queueId };
        for (Integer depth = 0; depth < MAX_MEMBERSHIP_DEPTH && !frontier.isEmpty(); depth++) {
            Set<Id> nestedGroupIds = new Set<Id>();
            for (GroupMember member : [SELECT UserOrGroupId FROM GroupMember WHERE GroupId IN :frontier WITH SYSTEM_MODE]) {
                if (member.UserOrGroupId.getSObjectType() == User.SObjectType) {
                    userIds.add(member.UserOrGroupId);
                } else if (!visitedGroupIds.contains(member.UserOrGroupId)) {
                    nestedGroupIds.add(member.UserOrGroupId);
                }
            }
            frontier = new Set<Id>();
            for (Group nested : [SELECT Id, Type, RelatedId FROM Group WHERE Id IN :nestedGroupIds WITH SYSTEM_MODE]) {
                visitedGroupIds.add(nested.Id);
                if (nested.Type == 'Role') {
                    roleIds.add(nested.RelatedId);
                } else if (nested.Type == 'RoleAndSubordinates' || nested.Type == 'RoleAndSubordinatesInternal') {
                    subordinateRoleIds.add(nested.RelatedId);
                } else if (nested.Type == 'Regular') {
                    frontier.add(nested.Id);
                }
            }
        }
        Set<Id> parentRoleIds = subordinateRoleIds.clone();
        roleIds.addAll(subordinateRoleIds);
        for (Integer depth = 0; depth < MAX_ROLE_DEPTH && !parentRoleIds.isEmpty(); depth++) {
            Set<Id> childRoleIds = new Map<Id, UserRole>([SELECT Id FROM UserRole WHERE ParentRoleId IN :parentRoleIds AND Id NOT IN :roleIds WITH SYSTEM_MODE])
                .keySet();
            roleIds.addAll(childRoleIds);
            parentRoleIds = childRoleIds;
        }
        if (!roleIds.isEmpty()) {
            userIds.addAll(new Map<Id, User>([SELECT Id FROM User WHERE UserRoleId IN :roleIds AND IsActive = TRUE WITH SYSTEM_MODE]).keySet());
        }
        return userIds;
    }

    /**
     * A queue can decide a call only when a member other than the run's
     * service user holds Human Decision.
     * Checked when the call waits, because staffing changes after save.
     */
    private static Boolean hasEligibleMember(AgentRun__c run, Id queueId) {
        Set<Id> candidates = queueMemberIds(queueId);
        candidates.remove(run.ExpectedPrincipalUser__c);
        candidates.remove(run.ResolvedPrincipalUser__c);
        return !AgentHumanDecisionGuard.usersWithDecisionAuthority(candidates).isEmpty();
    }

    private static Boolean queueSupportsApprovals(Id queueId) {
        return [
                SELECT COUNT()
                FROM QueueSobject
                WHERE QueueId = :queueId AND Queue.Type = 'Queue' AND SobjectType = 'AgentApproval__c'
                WITH SYSTEM_MODE
            ] > 0;
    }

    private static Map<String, Id> approvalQueues(Set<String> developerNames) {
        Map<String, Id> result = new Map<String, Id>();
        if (developerNames.isEmpty()) {
            return result;
        }
        for (QueueSobject supported : [
            SELECT QueueId, Queue.DeveloperName
            FROM QueueSobject
            WHERE Queue.DeveloperName IN :developerNames AND Queue.Type = 'Queue' AND SobjectType = 'AgentApproval__c'
            WITH SYSTEM_MODE
        ]) {
            result.put(supported.Queue.DeveloperName.toLowerCase(), supported.QueueId);
        }
        return result;
    }

    private static void write(List<AgentApproval__c> approvals, Boolean isInsert) {
        if (approvals.isEmpty()) {
            return;
        }
        coreWrite = true;
        try {
            if (isInsert) {
                Database.insert(approvals, AccessLevel.SYSTEM_MODE);
            } else {
                Database.update(approvals, AccessLevel.SYSTEM_MODE);
            }
        } finally {
            coreWrite = false;
        }
    }

    private static String protectedText(Id runId, String value) {
        if (!TrustService.needsProtection(new List<String>{ value })) {
            return value;
        }
        TrustService.ProtectionContext context = TrustService.openForAuthorizedTransition(runId);
        String protectedValue = TrustService.protect(context, value);
        TrustService.save(context);
        return protectedValue;
    }

    private static String bounded(String value, Integer maximum) {
        return value == null || value.length() <= maximum ? value : value.substring(0, maximum);
    }
}
