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
public class OpenAIProviderAdapter extends BaseProviderAdapter {
    private static final String LOG_PREFIX = '[OpenAIAdapter] ';

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

        if (openAITools != null && !openAITools.isEmpty()) {
            body.put('tools', openAITools);
            body.put('tool_choice', 'auto');
            Boolean allowParallel = (agentConfig != null && agentConfig.EnableParallelToolCalling__c == true);
            body.put('parallel_tool_calls', allowParallel);
            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Parallel tool calling enabled: ' + allowParallel);
        }
        req.setBody(JSON.serialize(body));
        req.setTimeout(120000);
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
