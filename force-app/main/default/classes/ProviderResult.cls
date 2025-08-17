/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ProviderResult is a data transfer object (DTO) that encapsulates the full outcome of a Large Language Model (LLM) API call.
 * It provides a structured representation of the LLM's response, including generated content, token usage metrics,
 * requested tool actions, and raw JSON payloads for downstream processing, auditing, and debugging.
 *
 * Responsibilities:
 *   - Store LLM response content and token accounting
 *   - Track tool/action requests made by the LLM
 *   - Preserve raw JSON for traceability and advanced analysis
 *   - Serve as a transport object between orchestration, logging, and UI layers
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

    /**
     * Constructs a ProviderResult with all LLM response data.
     *
     * @param content         The text content returned by the LLM.
     * @param promptTokens    Number of tokens used in the prompt/input.
     * @param completionTokens Number of tokens generated in the completion/output.
     * @param totalTokens     Total tokens consumed (prompt + completion).
     * @param actions         List of tool/action requests made by the LLM.
     * @param rawToolCalls    Raw JSON string of tool calls from the LLM response.
     * @param rawAssistantMsg Raw JSON string of the complete assistant message.
     */
    public ProviderResult(
        String content,
        Integer promptTokens,
        Integer completionTokens,
        Integer totalTokens,
        List<Map<String, String>> actions,
        String rawToolCalls,
        String rawAssistantMsg
    ) {
        this.content = content;
        this.promptTokens = promptTokens;
        this.completionTokens = completionTokens;
        this.totalTokens = totalTokens;
        this.requestedActions = actions != null ? actions : new List<Map<String, String>>();
        this.rawToolCallsJson = rawToolCalls;
        this.rawAssistantMessageWithActionsJson = rawAssistantMsg;
    }

    /**
     * Default constructor. Initializes requestedActions to an empty list.
     */
    public ProviderResult() {
        this.requestedActions = new List<Map<String, String>>();
    }
}
