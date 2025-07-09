/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Apex Controller for the Chat Session Runtime Visualizer LWC.
 *              Queries OrchestrationLog__c records for a specific turn and processes
 *              them into a format suitable for timeline visualization. Also fetches recent turns for selection.
 */
public with sharing class ChatSessionVisualizerController {
    private static final Integer MAX_PAYLOAD_DISPLAY_LENGTH = 2000;
    private static final Integer MAX_TURNS_TO_FETCH = 50;

    public class VisualizationStep {
        @AuraEnabled
        public Integer sequence { get; set; }
        @AuraEnabled
        public String stepType { get; set; }
        @AuraEnabled
        public String status { get; set; }
        @AuraEnabled
        public Datetime timestamp { get; set; }
        @AuraEnabled
        public Long durationMillis { get; set; }
        @AuraEnabled
        public String details { get; set; }
        @AuraEnabled
        public String inputPayload { get; set; }
        @AuraEnabled
        public String outputPayload { get; set; }
        @AuraEnabled
        public String errorMessage { get; set; }
        @AuraEnabled
        public String errorCode { get; set; }
        @AuraEnabled
        public String toolCallId { get; set; }
        @AuraEnabled
        public Id chatMessageId { get; set; }
        @AuraEnabled
        public String capabilityName { get; set; }
        @AuraEnabled
        public String actionName { get; set; }
        @AuraEnabled
        public Id llmConfigId { get; set; }
        @AuraEnabled
        public String llmConfigName { get; set; }
        @AuraEnabled
        public Boolean hasInputPayload { get; set; }
        @AuraEnabled
        public Boolean hasOutputPayload { get; set; }
        @AuraEnabled
        public Boolean hasError { get; set; }
        @AuraEnabled
        public Boolean isJsonInput { get; set; }
        @AuraEnabled
        public Boolean isJsonOutput { get; set; }
    }

    /**
     * @description Retrieves and processes Orchestration Log records for a specific session turn.
     * @param sessionId The ID of the ChatSession__c.
     * @param turnIdentifier The Turn Identifier linking log entries.
     * @return List<VisualizationStep> Processed steps ready for LWC display.
     */
    @AuraEnabled(cacheable=true)
    public static List<VisualizationStep> getVisualizationData(Id sessionId, String turnIdentifier) {
        if (sessionId == null || String.isBlank(turnIdentifier)) {
            throw new AuraHandledException('Session ID and Turn Identifier are required.');
        }
        validateSessionAccess(sessionId);

        List<VisualizationStep> visualSteps = new List<VisualizationStep>();
        try {
            List<OrchestrationLog__c> logs = [
                SELECT
                    Sequence__c,
                    StepType__c,
                    Status__c,
                    Timestamp__c,
                    DurationMillis__c,
                    Details__c,
                    PayloadInput__c,
                    PayloadOutput__c,
                    ErrorMessage__c,
                    ErrorCode__c,
                    ToolCallId__c,
                    ChatMessage__c,
                    AgentCapability__c,
                    AgentCapability__r.CapabilityName__c,
                    AgentCapability__r.ImplementationType__c,
                    AgentCapability__r.StandardActionType__c,
                    LLMConfiguration__c,
                    LLMConfiguration__r.Name
                FROM OrchestrationLog__c
                WHERE ChatSession__c = :sessionId AND TurnIdentifier__c = :turnIdentifier
                WITH SECURITY_ENFORCED
                ORDER BY Sequence__c ASC, CreatedDate ASC
                LIMIT 500
            ];

            if (logs.isEmpty()) {
                return visualSteps;
            }

            for (OrchestrationLog__c log : logs) {
                VisualizationStep step = new VisualizationStep();
                step.sequence = Integer.valueOf(log.Sequence__c);
                step.stepType = log.StepType__c;
                step.status = log.Status__c;
                step.timestamp = log.Timestamp__c;
                step.durationMillis = log.DurationMillis__c?.longValue();
                step.details = log.Details__c;
                step.errorMessage = log.ErrorMessage__c;
                step.errorCode = log.ErrorCode__c;
                step.toolCallId = log.ToolCallId__c;
                step.chatMessageId = log.ChatMessage__c;
                step.llmConfigId = log.LLMConfiguration__c;
                step.llmConfigName = log.LLMConfiguration__r?.Name;

                if (log.AgentCapability__r != null) {
                    step.capabilityName = log.AgentCapability__r.CapabilityName__c;

                    step.actionName = getActionName(log.AgentCapability__r);
                }

                step.hasInputPayload = String.isNotBlank(log.PayloadInput__c);
                if (step.hasInputPayload) {
                    step.inputPayload = log.PayloadInput__c.abbreviate(MAX_PAYLOAD_DISPLAY_LENGTH);
                    step.isJsonInput = isJson(step.inputPayload);
                }
                step.hasOutputPayload = String.isNotBlank(log.PayloadOutput__c);
                if (step.hasOutputPayload) {
                    step.outputPayload = log.PayloadOutput__c.abbreviate(MAX_PAYLOAD_DISPLAY_LENGTH);
                    step.isJsonOutput = isJson(step.outputPayload);
                }
                step.hasError = (log.Status__c == 'Failure' || String.isNotBlank(log.ErrorMessage__c));

                visualSteps.add(step);
            }
        } catch (Exception e) {
            throw new AuraHandledException('Failed to retrieve orchestration details: ' + e.getMessage());
        }
        return visualSteps;
    }

    /**
     * @description Retrieves recent turn identifiers for a session. This method
     *              queries ChatMessage__c and does not depend on the action/capability model.
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getRecentTurns(Id sessionId) {
        if (sessionId == null)
            throw new AuraHandledException('Session ID is required.');
        validateSessionAccess(sessionId);

        List<Map<String, String>> turnOptions = new List<Map<String, String>>();
        try {
            List<ChatMessage__c> userMessages = [
                SELECT ExternalId__c, Timestamp__c
                FROM ChatMessage__c
                WHERE ChatSession__c = :sessionId AND Role__c = 'user' AND ExternalId__c != NULL
                WITH USER_MODE
                ORDER BY Timestamp__c DESC
                LIMIT :MAX_TURNS_TO_FETCH
            ];

            for (ChatMessage__c msg : userMessages) {
                turnOptions.add(new Map<String, String>{ 'label' => msg.Timestamp__c.format('yyyy-MM-dd HH:mm:ss'), 'value' => msg.ExternalId__c });
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error retrieving recent turns: ' + e.getMessage());
        }
        return turnOptions;
    }

    /**
     * @description (NEW) Helper method to create a user-friendly action name for the visualizer UI.
     * @param cap The AgentCapability__c record from the log's relationship.
     * @return A descriptive string like "Standard:CreateRecord" or "Apex:MyClassName".
     */
    private static String getActionName(AgentCapability__c cap) {
        if (cap == null)
            return 'Unknown Action';

        if ('Standard'.equalsIgnoreCase(cap.ImplementationType__c) && String.isNotBlank(cap.StandardActionType__c)) {
            return 'Standard: ' + cap.StandardActionType__c;
        } else if (String.isNotBlank(cap.ImplementationDetail__c)) {
            return cap.ImplementationType__c + ': ' + cap.ImplementationDetail__c;
        }
        return cap.ImplementationType__c;
    }

    /**
     * Basic check if user can access the Chat Session record.
     * Owner check is simple, but consider if other sharing is needed.
     */
    private static void validateSessionAccess(Id sessionId) {
        try {
            Integer count = [SELECT COUNT() FROM ChatSession__c WHERE Id = :sessionId WITH USER_MODE];
            if (count == 0) {
                throw new AuraHandledException('Chat session not found or access denied.');
            }
        } catch (Exception accessEx) {
            throw new AuraHandledException('Error verifying session access: ' + accessEx.getMessage());
        }
    }

    private static Boolean isJson(String str) {
        if (String.isBlank(str))
            return false;
        String trimmed = str.trim();
        return (trimmed.startsWith('{') && trimmed.endsWith('}')) || (trimmed.startsWith('[') && trimmed.endsWith(']'));
    }
}
