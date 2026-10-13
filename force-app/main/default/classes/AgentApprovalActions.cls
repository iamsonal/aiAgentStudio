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
 * No-code decision surface for Agent Approvals: the Decide quick action and a
 * Flow action. Every call goes through AgentRunService, so Core enforces who
 * may decide and what happens next.
 */
global with sharing class AgentApprovalActions {
    /**
     * Headroom one decision needs: authorization, the run transition, and its
     * dispatch. A governor limit cannot be caught, so decisions stop early
     * instead of failing the whole Flow transaction.
     */
    @TestVisible
    private static Integer queriesPerDecision = 40;
    private static final Integer DML_PER_DECISION = 15;
    @TestVisible
    private static final String CAPACITY_DEFERRED = 'Not decided: this transaction has no capacity left for another decision. Decide it again in a new transaction.';

    global class DecisionRequest {
        @InvocableVariable(label='Approval ID' required=true)
        global Id approvalId;

        @InvocableVariable(label='Approved' description='True to let the tool run; false to reject it.' required=true)
        global Boolean approved;

        @InvocableVariable(label='Comment' description='Optional reason returned to the agent when the call is rejected. At most 1,000 characters are kept.')
        global String comment;
    }

    global class DecisionResult {
        @InvocableVariable(label='Next Command ID')
        global Id nextCommandId;

        @InvocableVariable(label='Decided' description='True when Agent Core recorded the decision.')
        global Boolean decided;

        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    /**
     * Decides as the running user; a relaying channel calls
     * AgentRunService.decideApproval with deciderId instead. Each request
     * succeeds or fails on its own, so one refused decision never fails the
     * others in the same Flow transaction.
     */
    @InvocableMethod(
        label='Decide Agent Approval'
        description='Approves or rejects Agent Approvals assigned to the running user or their queue. Returns an error per request instead of failing the flow, including for decisions this transaction has no capacity left to make.'
    )
    global static List<DecisionResult> decide(List<DecisionRequest> requests) {
        List<DecisionResult> results = new List<DecisionResult>();
        for (DecisionRequest request : requests == null ? new List<DecisionRequest>() : requests) {
            DecisionResult result = new DecisionResult();
            result.decided = false;
            results.add(result);
            if (!hasCapacityForDecision()) {
                result.errorMessage = CAPACITY_DEFERRED;
                continue;
            }
            Savepoint beforeDecision = Database.setSavepoint();
            try {
                result.nextCommandId = decideOne(request.approvalId, request.approved, request.comment);
                result.decided = true;
            } catch (Exception failure) {
                Database.rollback(beforeDecision);
                result.errorMessage = failure.getMessage();
            } finally {
                Database.releaseSavepoint(beforeDecision);
            }
        }
        return results;
    }

    @AuraEnabled
    public static String reviewInput(Id approvalId) {
        try {
            return AgentRunService.resolveApprovalInput(approvalId);
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    /**
     * What the approver decides: the change, its record, the agent's unverified
     * explanation, and the deadline; or, once decided, who decided and when.
     */
    @AuraEnabled
    public static AgentApprovalReview.Request reviewRequest(Id approvalId) {
        try {
            return AgentApprovalReview.load(approvalId);
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    @AuraEnabled
    public static void decideFromRecord(Id approvalId, Boolean approved, String comment) {
        try {
            decideOne(approvalId, approved, comment);
        } catch (Exception failure) {
            throw auraError(failure);
        }
    }

    private static Boolean hasCapacityForDecision() {
        return Limits.getLimitQueries() - Limits.getQueries() >= queriesPerDecision &&
            Limits.getLimitDmlStatements() - Limits.getDmlStatements() >= DML_PER_DECISION &&
            Limits.getQueueableJobs() < Limits.getLimitQueueableJobs();
    }

    private static Id decideOne(Id approvalId, Boolean approved, String comment) {
        AgentKernelModels.ApprovalDecision decision = new AgentKernelModels.ApprovalDecision();
        decision.approvalId = approvalId;
        decision.approved = approved;
        decision.comment = comment;
        return AgentRunService.decideApproval(decision);
    }

    private static AuraHandledException auraError(Exception failure) {
        AuraHandledException error = new AuraHandledException(failure.getMessage());
        error.setMessage(failure.getMessage());
        return error;
    }
}
