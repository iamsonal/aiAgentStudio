/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Data transfer object that encapsulates the full outcome of an LLM API call. Includes content, token usage, and tool requests.
 */
public class ProviderResult {
    @AuraEnabled
    public String content { get; set; }
    @AuraEnabled
    public Integer promptTokens { get; set; }
    @AuraEnabled
    public Integer completionTokens { get; set; }
    @AuraEnabled
    public Integer totalTokens { get; set; }
    @AuraEnabled
    public List<Map<String, String>> requestedActions { get; set; }
    public String rawToolCallsJson { get; set; }
    public String rawAssistantMessageWithActionsJson { get; set; }
    @AuraEnabled
    public String modelIdentifier { get; set; }
    @AuraEnabled
    public Long llmCalloutDurationMs { get; set; }
    public ProviderResult(
        String content,
        Integer promptTokens,
        Integer completionTokens,
        Integer totalTokens,
        List<Map<String, String>> actions,
        String rawToolCalls,
        String rawAssistantMsg,
        String modelIdentifier,
        Long llmCalloutDurationMs
    ) {
        this.content = content;
        this.promptTokens = promptTokens;
        this.completionTokens = completionTokens;
        this.totalTokens = totalTokens;
        this.requestedActions = actions != null ? actions : new List<Map<String, String>>();
        this.rawToolCallsJson = rawToolCalls;
        this.rawAssistantMessageWithActionsJson = rawAssistantMsg;
        this.modelIdentifier = modelIdentifier;
        this.llmCalloutDurationMs = llmCalloutDurationMs;
    }

    public ProviderResult() {
        this.requestedActions = new List<Map<String, String>>();
    }
}
