/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Integration layer for the OpenAI Chat Completions API. Extends BaseProviderAdapter for OpenAI-specific request formatting and response parsing.
 */
public inherited sharing class OpenAIProviderAdapter extends BaseProviderAdapter {
    private static final String LOG_PREFIX = '[OpenAIAdapter] ';
    private static final Integer DEFAULT_TIMEOUT_MS = 120000;

    public class OpenAIParseException extends AIAgentException.ProviderException {
    }

    protected override String getLogPrefix() {
        return LOG_PREFIX;
    }
    @TestVisible
    protected override HttpRequest buildProviderRequest(
        LLMConfiguration__c llmConfig,
        List<Map<String, Object>> openAIMessages,
        List<Map<String, Object>> openAITools,
        AIAgentDefinition__c agentConfig
    ) {
        validateConfiguration(llmConfig);
        validateMessages(openAIMessages);

        HttpRequest req = new HttpRequest();
        String endpoint = 'callout:' + llmConfig.NamedCredential__c + '/v1/chat/completions';
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json; charset=utf-8');

        Map<String, Object> body = new Map<String, Object>{ 'model' => llmConfig.DefaultModelIdentifier__c, 'messages' => openAIMessages };

        if (llmConfig.DefaultTemperature__c != null) {
            body.put('temperature', llmConfig.DefaultTemperature__c);
        }
        if (llmConfig.MaxResponseTokens__c != null) {
            body.put('max_tokens', llmConfig.MaxResponseTokens__c.intValue());
        }

        if (openAITools != null && !openAITools.isEmpty()) {
            body.put('tools', openAITools);
            body.put('tool_choice', 'auto');
            Boolean allowParallel = (agentConfig != null && agentConfig.EnableParallelToolCalling__c == true);
            body.put('parallel_tool_calls', allowParallel);
            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Parallel tool calling enabled: ' + allowParallel);
        }
        req.setBody(JSON.serialize(body));
        Integer timeoutMs = llmConfig.TimeoutMs__c != null ? llmConfig.TimeoutMs__c.intValue() : DEFAULT_TIMEOUT_MS;
        req.setTimeout(timeoutMs);
        System.debug(LoggingLevel.DEBUG, req.getBody());
        System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'HTTP request prepared. Payload size: ' + req.getBody().length() + ' characters.');
        return req;
    }

    @TestVisible
    protected override ProviderResult parseProviderResponse(String responseBody, String modelIdentifier, Long calloutDurationMs) {
        Map<String, Object> responseMap = parseJsonResponse(responseBody, LOG_PREFIX);

        String content = null;
        List<Map<String, String>> parsedActions = new List<Map<String, String>>();
        String rawToolCallsListJson = null;
        String rawAssistantMessageWithActionsJson = null;

        try {
            if (responseMap.get('choices') instanceof List<Object>) {
                List<Object> choices = (List<Object>) responseMap.get('choices');
                if (!choices.isEmpty() && choices[0] instanceof Map<String, Object>) {
                    Map<String, Object> choice = (Map<String, Object>) choices[0];
                    if (choice.get('message') instanceof Map<String, Object>) {
                        Map<String, Object> message = (Map<String, Object>) choice.get('message');
                        rawAssistantMessageWithActionsJson = JSON.serialize(message);
                        if (message.get('content') instanceof String) {
                            content = (String) message.get('content');
                        }
                        if (message.get('tool_calls') instanceof List<Object>) {
                            List<Object> rawToolCallsList = (List<Object>) message.get('tool_calls');
                            if (!rawToolCallsList.isEmpty()) {
                                rawToolCallsListJson = JSON.serialize(rawToolCallsList);
                                parsedActions = parseStructuredToolCalls(rawToolCallsList);
                                System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Parsed ' + parsedActions.size() + ' function call(s) from OpenAI response.');
                            }
                        }
                    } else {
                        throw new OpenAIParseException('OpenAI response choice missing required "message" object.');
                    }
                } else {
                    System.debug(LoggingLevel.WARN, LOG_PREFIX + 'OpenAI response contains empty or invalid choices array.');
                }
            } else {
                throw new OpenAIParseException('OpenAI response missing required "choices" list.');
            }

            ProviderResult result = new ProviderResult(
                content,
                null,
                null,
                null,
                parsedActions,
                rawToolCallsListJson,
                rawAssistantMessageWithActionsJson,
                modelIdentifier,
                calloutDurationMs
            );

            if (responseMap.get('usage') instanceof Map<String, Object>) {
                extractTokenUsage((Map<String, Object>) responseMap.get('usage'), result, LOG_PREFIX);
            } else {
                System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Token usage block missing in OpenAI response.');
            }

            return result;
        } catch (OpenAIParseException pex) {
            throw new AIAgentException.ProviderException('Failed to parse OpenAI response: ' + pex.getMessage(), pex);
        } catch (Exception e) {
            if (e instanceof AIAgentException.ProviderException) {
                throw e;
            }
            throw new AIAgentException.ProviderException('Unexpected error during OpenAI response parsing: ' + e.getMessage(), e);
        }
    }

    /**
     * @description Calls the OpenAI Moderation API (/v1/moderations) using the same Named Credential
     * as the chat completions endpoint. No new credentials or third-party services required.
     *
     * The block decision is based solely on the API's `flagged` boolean — OpenAI's authoritative
     * determination using its per-category internal thresholds. OpenAI's thresholds vary by category
     * and are not publicly documented, so the `flagged` boolean is the most accurate signal available.
     *
     * Preset behaviour:
     *   Standard → block if `flagged == true`
     *   Off      → returns null (no check performed)
     *
     * Fails open: any API error returns ThreatAssessment.safe() so agent execution is never
     * blocked by a transient moderation API failure.
     */
    public override ThreatAssessment checkMessageSafety(String userMessage, LLMConfiguration__c llmConfig, AIAgentDefinition__c agentConfig) {
        String preset = normalizePromptSafetyPreset(agentConfig?.PromptSafetyPreset__c);
        if (preset == PRESET_OFF) {
            return null;
        }

        if (String.isBlank(userMessage)) {
            return ThreatAssessment.safe(userMessage);
        }

        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + llmConfig.NamedCredential__c + '/v1/moderations');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json; charset=utf-8');
            req.setBody(JSON.serialize(new Map<String, Object>{ 'input' => userMessage }));
            req.setTimeout(15000);
            System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Moderation request body: ' + req.getBody());

            HttpResponse res = new Http().send(req);
            System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Moderation response (' + res.getStatusCode() + '): ' + res.getBody());

            if (res.getStatusCode() != 200) {
                System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Moderation API returned HTTP ' + res.getStatusCode() + '. Failing open.');
                return ThreatAssessment.safe(userMessage);
            }

            Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> results = (List<Object>) responseMap.get('results');
            if (results == null || results.isEmpty()) {
                return ThreatAssessment.safe(userMessage);
            }

            Map<String, Object> result = (Map<String, Object>) results[0];

            // The flagged boolean is OpenAI's authoritative determination. If not flagged, we are done.
            Boolean apiFlag = result.get('flagged') instanceof Boolean ? (Boolean) result.get('flagged') : false;
            if (!apiFlag) {
                System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Moderation check: clean (flagged=false).');
                return ThreatAssessment.safe(userMessage);
            }

            // Build indicators only for categories OpenAI itself flagged
            Map<String, Object> categories = result.get('categories') instanceof Map<String, Object>
                ? (Map<String, Object>) result.get('categories')
                : new Map<String, Object>();
            Map<String, Object> categoryScores = result.get('category_scores') instanceof Map<String, Object>
                ? (Map<String, Object>) result.get('category_scores')
                : new Map<String, Object>();

            Decimal maxScore = 0.0;
            List<ThreatAssessment.ThreatIndicator> indicators = new List<ThreatAssessment.ThreatIndicator>();
            for (String cat : categoryScores.keySet()) {
                if (Boolean.valueOf(String.valueOf(categories.get(cat))) != true) {
                    continue;
                }
                Object scoreObj = categoryScores.get(cat);
                Decimal score = scoreObj != null ? Decimal.valueOf(String.valueOf(scoreObj)) : 0.0;
                if (score > maxScore) {
                    maxScore = score;
                }
                indicators.add(
                    new ThreatAssessment.ThreatIndicator(
                        'Moderation',
                        mapModerationCategoryToGroup(cat),
                        cat,
                        'OpenAI Moderation API flagged: ' + cat + ' (score: ' + score.setScale(4) + ')',
                        score
                    )
                );
            }

            // Pass threshold 0.0: block decision is already authoritative from apiFlag above.
            ThreatAssessment assessment = ThreatAssessment.fromAnalysis(userMessage, maxScore, indicators);
            assessment.applyResponseMode('Block', 0.0);

            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Moderation check: blocked. maxScore=' + maxScore.setScale(4) + ', indicators=' + indicators.size());

            return assessment;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Moderation check threw exception: ' + e.getMessage() + '. Failing open.');
            return ThreatAssessment.safe(userMessage);
        }
    }

    private static String mapModerationCategoryToGroup(String category) {
        if (category.startsWith('hate')) {
            return 'Hate';
        }
        if (category.startsWith('harassment')) {
            return 'Harassment';
        }
        if (category.startsWith('self-harm')) {
            return 'SelfHarm';
        }
        if (category.startsWith('sexual')) {
            return 'Sexual';
        }
        if (category.startsWith('violence')) {
            return 'Violence';
        }
        return 'Other';
    }

    @TestVisible
    private List<Map<String, String>> parseStructuredToolCalls(List<Object> rawToolCallsList) {
        List<Map<String, String>> actions = new List<Map<String, String>>();
        for (Object callObj : rawToolCallsList) {
            if (callObj instanceof Map<String, Object>) {
                Map<String, Object> callMap = (Map<String, Object>) callObj;
                if ('function'.equalsIgnoreCase(String.valueOf(callMap.get('type'))) && callMap.get('function') instanceof Map<String, Object>) {
                    String toolCallId = String.valueOf(callMap.get('id'));
                    Map<String, Object> funcMap = (Map<String, Object>) callMap.get('function');
                    String funcName = String.valueOf(funcMap.get('name'));
                    Object argsObj = funcMap.get('arguments');
                    String argsJson = (argsObj instanceof String) ? (String) argsObj : null;
                    if (String.isNotBlank(toolCallId) && String.isNotBlank(funcName) && argsJson != null) {
                        actions.add(new Map<String, String>{ 'id' => toolCallId, 'name' => funcName, 'arguments' => argsJson });
                    } else {
                        System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Malformed tool call skipped: missing id, name, or arguments.');
                    }
                } else {
                    System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Non-function tool call skipped: type=' + callMap.get('type'));
                }
            } else {
                System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Invalid tool call format encountered in OpenAI response.');
            }
        }
        return actions;
    }
}
