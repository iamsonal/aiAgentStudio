/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Represents the basic outcome of an LLM call.
 *              Contains content, token usage, and info about requested actions.
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

    public ProviderResult(
        String c,
        Integer p,
        Integer compl,
        Integer t,
        List<Map<String, String>> actions,
        String rawToolCalls,
        String rawAssistantMsg
    ) {
        this.content = c;
        this.promptTokens = p;
        this.completionTokens = compl;
        this.totalTokens = t;
        this.requestedActions = actions != null ? actions : new List<Map<String, String>>();
        this.rawToolCallsJson = rawToolCalls;
        this.rawAssistantMessageWithActionsJson = rawAssistantMsg;
    }

    public ProviderResult() {
        this.requestedActions = new List<Map<String, String>>();
    }
}
