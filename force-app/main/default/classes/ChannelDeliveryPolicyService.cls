/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Applies channel delivery behavior after the execution strategy
 * has already decided the turn is terminal and safe to finalize.
 */
public inherited sharing class ChannelDeliveryPolicyService {
    public class DeliveryResult {
        public Boolean isSuccess;
        public String outcome;
        public String statusMessage;
    }

    private static DeliveryResult successResult() {
        DeliveryResult result = new DeliveryResult();
        result.isSuccess = true;
        result.outcome = OrchestrationService.OUTCOME_COMPLETED;
        return result;
    }

    private static DeliveryResult failureResult(String message) {
        DeliveryResult result = new DeliveryResult();
        result.isSuccess = false;
        result.outcome = OrchestrationService.OUTCOME_FAILED;
        result.statusMessage = message;
        return result;
    }

    public DeliveryResult applyContentDelivery(OrchestrationContext context, String contentResponse, String logPrefix) {
        AIAgentDefinition__c agentDefinition = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
        InteractionRuntimeModels.IInteractionChannel adapter = RuntimeRegistryService.getChannelAdapter(agentDefinition, context.executionId);
        InteractionRuntimeModels.DeliveryDecision decision = adapter.determineDeliveryAction(agentDefinition, context, contentResponse, logPrefix);

        if (decision == null || decision.action == InteractionRuntimeModels.DeliveryAction.None) {
            return successResult();
        }

        DeliveryResult channelGuardResult = enforceSameChannelReply(agentDefinition, context, decision, logPrefix);
        if (channelGuardResult != null) {
            return channelGuardResult;
        }

        if (decision.action == InteractionRuntimeModels.DeliveryAction.Send) {
            Boolean sent = adapter.sendReply(contentResponse, context, logPrefix);
            if (!sent) {
                context.agentStateSvc.failTurn(
                    context.executionId,
                    context.turnIdentifier,
                    'Channel delivery failed for terminal response.',
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
                return failureResult('Channel delivery failed');
            }
            return successResult();
        }

        if (decision.action == InteractionRuntimeModels.DeliveryAction.Draft) {
            HITLGatewayService.ReviewArtifactResult reviewResult = HITLGatewayService.createDraftReviewArtifact(
                agentDefinition,
                adapter,
                context,
                contentResponse,
                logPrefix
            );
            if (!reviewResult.success) {
                context.agentStateSvc.failTurn(
                    context.executionId,
                    context.turnIdentifier,
                    'Channel review artifact creation failed: ' + reviewResult.errorMessage,
                    AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                    logPrefix
                );
                return failureResult('Channel review artifact creation failed');
            }
            return successResult();
        }

        if (decision.action == InteractionRuntimeModels.DeliveryAction.Suppress || decision.action == InteractionRuntimeModels.DeliveryAction.Handoff) {
            adapter.suppressReply(context, logPrefix);
            return successResult();
        }

        return successResult();
    }

    private DeliveryResult enforceSameChannelReply(
        AIAgentDefinition__c agentDefinition,
        OrchestrationContext context,
        InteractionRuntimeModels.DeliveryDecision decision,
        String logPrefix
    ) {
        if (agentDefinition.RequiresSameChannelReply__c != true) {
            return null;
        }

        List<AgentExecution__c> executions = [
            SELECT InteractionChannel__c, InteractionSession__c
            FROM AgentExecution__c
            WHERE Id = :context.executionId
            LIMIT 1
        ];
        if (executions.isEmpty() || executions[0].InteractionSession__c == null) {
            String message = 'Same-channel delivery requires a resolved interaction session.';
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, message, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            return failureResult(message);
        }

        List<InteractionSession__c> sessions = [
            SELECT Channel__c, ReplyRouteKey__c
            FROM InteractionSession__c
            WHERE Id = :executions[0].InteractionSession__c
            LIMIT 1
        ];
        if (sessions.isEmpty()) {
            String message = 'Same-channel delivery requires a persisted interaction session.';
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, message, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            return failureResult(message);
        }

        InteractionSession__c session = sessions[0];
        if (String.isNotBlank(decision.routeKey) && String.isNotBlank(session.ReplyRouteKey__c) && decision.routeKey != session.ReplyRouteKey__c) {
            String message = 'Delivery route does not match the originating interaction session.';
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, message, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            return failureResult(message);
        }

        if (
            String.isNotBlank(executions[0].InteractionChannel__c) &&
            String.isNotBlank(session.Channel__c) &&
            executions[0].InteractionChannel__c != session.Channel__c
        ) {
            String message = 'Execution channel diverged from the originating interaction session.';
            context.agentStateSvc.failTurn(context.executionId, context.turnIdentifier, message, AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            return failureResult(message);
        }

        return null;
    }
}
