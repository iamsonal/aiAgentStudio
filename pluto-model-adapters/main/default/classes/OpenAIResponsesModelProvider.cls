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
 * Agent Core model adapter for the OpenAI Responses API, at OpenAI or any
 * endpoint that serves the same API, such as Azure OpenAI. The Named
 * Credential's URL carries the host and any base path; this class adds
 * /v1/responses. Error codes keep the OPENAI_API_ prefix, which names the API
 * shape, while messages describe "the model endpoint".
 *
 * Select it on an Agent Model record: Model Adapter Class
 * OpenAIResponsesModelProvider, the OpenAI model identifier, and a Named
 * Credential whose URL is https://api.openai.com and whose External Credential
 * sends Authorization: Bearer <API key>.
 *
 * Request shape:
 * - Only the agent's instructions, operator guidance, and Core's feedback on a
 *   rejected answer are trusted: instructions and developer messages. Context,
 *   the original input, tool results, and people's replies are untrusted data in
 *   user messages and function call outputs.
 * - store is false: OpenAI keeps no copy of the conversation, and Core's
 *   transcript stays the conversation of record. Reasoning models reason afresh
 *   each turn; no reasoning items are replayed.
 * - max_output_tokens caps output and reasoning at the Agent Model's Max
 *   Output Tokens, or 8,000 when it is blank, so a turn finishes inside the
 *   120-second callout limit; a longer answer is reported as
 *   MODEL_OUTPUT_TRUNCATED.
 * - When the agent takes one tool call per turn, parallel_tool_calls is false.
 * - A tool, and the final answer's output schema, use strict mode when the
 *   schema meets its rules (every object closed and listing all its properties
 *   as required); otherwise the schema guides the model and Core validates it.
 * - A string format OpenAI does not know fails the whole request, so it is
 *   replaced: Core's salesforce-id by a pattern and a description hint, uri
 *   by a hint. Core still validates every tool input against the full schema.
 *
 * Evidence: the request is stored as sent. The response is stored without what
 * OpenAI repeats from the request (instructions, tools, answer schema, and
 * settings) and without encrypted reasoning, which Core never replays: only
 * the id, status, model, times, output, usage, and any error.
 *
 * Errors: 408, 429, and 5xx are retryable and honour retry-after; other
 * statuses, a refusal, and a truncated answer are not, and Core pauses the run
 * with the error code for an operator.
 */
global inherited sharing class OpenAIResponsesModelProvider implements IModelProvider {
    /**
     * Output and reasoning tokens together when the Agent Model sets no Max
     * Output Tokens. A non-streaming turn must finish in
     * the 120-second callout limit; at this size it does on typical models, and a
     * timeout is retried, so a larger cap would repeat a turn that cannot finish.
     */
    @TestVisible
    private static final Integer MAX_OUTPUT_TOKENS = 8000;

    global AgentKernelModels.ModelResponse invoke(AgentKernelModels.ModelRequest request) {
        if (request == null || String.isBlank(request.namedCredential) || String.isBlank(request.modelName)) {
            throw new AgentKernelException.PermanentException('The Agent Model needs a Named Credential and a model identifier.');
        }
        HttpRequest callout = new HttpRequest();
        callout.setEndpoint('callout:' + request.namedCredential + '/v1/responses');
        callout.setMethod('POST');
        callout.setHeader('Content-Type', 'application/json');
        callout.setTimeout(Math.max(1, Math.min(120, request.timeoutSeconds == null ? 120 : request.timeoutSeconds)) * 1000);
        String requestBody = JSON.serialize(requestBody(request));
        callout.setBody(requestBody);
        Long startedAt = System.now().getTime();
        HttpResponse response;
        try {
            response = new Http().send(callout);
        } catch (CalloutException failure) {
            throw new AgentKernelException.RetryableException('The model endpoint could not be reached.');
        }
        Long duration = System.now().getTime() - startedAt;
        Integer status = response.getStatusCode();
        if (status < 200 || status >= 300) {
            return httpFailure(response, duration, requestBody);
        }
        return parse(response, duration, requestBody);
    }

    private static Map<String, Object> requestBody(AgentKernelModels.ModelRequest request) {
        List<Object> input = new List<Object>();
        for (AgentKernelModels.ContextItem item : request.contexts == null ? new List<AgentKernelModels.ContextItem>() : request.contexts) {
            input.add(message('user', '<context source="' + attributeText(item.sourceName) + '">\n' + elementText(item.content) + '\n</context>'));
        }
        for (AgentKernelModels.TranscriptEntry entry : request.transcript == null ? new List<AgentKernelModels.TranscriptEntry>() : request.transcript) {
            input.add(transcriptItem(entry));
        }
        Map<String, Object> body = new Map<String, Object>{
            'model' => request.modelName.trim(),
            'instructions' => nonBlank(request.instructions),
            'input' => input,
            'store' => false,
            'max_output_tokens' => request.maxOutputTokens == null || request.maxOutputTokens < 1 ? MAX_OUTPUT_TOKENS : request.maxOutputTokens
        };
        if (request.tools != null && !request.tools.isEmpty()) {
            List<Object> tools = new List<Object>();
            for (AgentKernelModels.ToolDefinition tool : request.tools) {
                Object parameters = forOpenAI(JSON.deserializeUntyped(tool.inputSchema));
                tools.add(
                    new Map<String, Object>{
                        'type' => 'function',
                        'name' => tool.developerName,
                        'description' => tool.description,
                        'parameters' => parameters,
                        'strict' => isStrictCompatible(parameters)
                    }
                );
            }
            body.put('tools', tools);
            // Sent only with tools. Absent, the model may call several.
            if (request.allowMultipleToolCalls == false) {
                body.put('parallel_tool_calls', false);
            }
        }
        if (!String.isBlank(request.outputSchema)) {
            Object schema = forOpenAI(JSON.deserializeUntyped(request.outputSchema));
            body.put(
                'text',
                new Map<String, Object>{
                    'format' => new Map<String, Object>{
                        'type' => 'json_schema',
                        'name' => 'agent_answer',
                        'strict' => isStrictCompatible(schema),
                        'schema' => schema
                    }
                }
            );
        }
        return body;
    }

    private static Map<String, Object> transcriptItem(AgentKernelModels.TranscriptEntry entry) {
        if (entry.type == AgentKernelModels.TRANSCRIPT_TOOL_CALL) {
            return new Map<String, Object>{
                'type' => 'function_call',
                'call_id' => entry.toolCallId,
                'name' => entry.toolName,
                'arguments' => String.isBlank(entry.content) ? '{}' : entry.content
            };
        }
        if (entry.type == AgentKernelModels.TRANSCRIPT_TOOL_RESULT) {
            return new Map<String, Object>{ 'type' => 'function_call_output', 'call_id' => entry.toolCallId, 'output' => nonBlank(entry.content) };
        }
        if (entry.type == AgentKernelModels.TRANSCRIPT_ASSISTANT_OUTPUT) {
            return message('assistant', entry.content);
        }
        if (entry.type == AgentKernelModels.TRANSCRIPT_OPERATOR_GUIDANCE) {
            return message('developer', 'Operator guidance:\n' + entry.content);
        }
        if (entry.type == AgentKernelModels.TRANSCRIPT_MODEL_FEEDBACK) {
            return message('developer', 'Your previous response was rejected:\n' + entry.content);
        }
        // The original input and people's replies are data from records and people.
        return message('user', entry.content);
    }

    /** Record text cannot close or fake the context delimiter; JSON quotes stay readable. */
    private static String elementText(String value) {
        return value == null ? null : value.replace('<', '&lt;');
    }

    private static String attributeText(String value) {
        return value == null ? null : value.replace('<', '&lt;').replace('"', '&quot;');
    }

    private static Map<String, Object> message(String role, String content) {
        return new Map<String, Object>{ 'role' => role, 'content' => nonBlank(content) };
    }

    private static String nonBlank(String value) {
        return String.isBlank(value) ? '(empty)' : value;
    }

    /** String formats OpenAI accepts in a schema. Any other format fails the request with HTTP 400. */
    private static final Set<String> OPENAI_FORMATS = new Set<String>{ 'date-time', 'time', 'date', 'duration', 'email', 'hostname', 'ipv4', 'ipv6', 'uuid' };

    /** Pluto's Salesforce record Id, as a pattern OpenAI enforces in strict mode. */
    @TestVisible
    private static final String SALESFORCE_ID_PATTERN = '^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$';
    @TestVisible
    private static final String SALESFORCE_ID_HINT = 'A 15- or 18-character Salesforce record Id.';
    @TestVisible
    private static final String URI_HINT = 'An absolute URL, such as https://example.com/path.';

    /**
     * The schema in a form OpenAI accepts. A format OpenAI does not know
     * fails the whole request, so it is replaced: salesforce-id by a pattern
     * and a description hint, uri by a hint, and any other by nothing. Core
     * still checks every value against the full schema. Property names are
     * kept, even one named format.
     */
    @TestVisible
    private static Object forOpenAI(Object node) {
        if (node instanceof List<Object>) {
            List<Object> items = new List<Object>();
            for (Object item : (List<Object>) node) {
                items.add(forOpenAI(item));
            }
            return items;
        }
        if (!(node instanceof Map<String, Object>)) {
            return node;
        }
        Map<String, Object> schema = (Map<String, Object>) node;
        Map<String, Object> result = new Map<String, Object>();
        for (String key : schema.keySet()) {
            Object value = schema.get(key);
            if (key == 'format' && value instanceof String && !OPENAI_FORMATS.contains((String) value)) {
                continue;
            }
            if (key == 'properties' && value instanceof Map<String, Object>) {
                Map<String, Object> properties = new Map<String, Object>();
                for (String name : ((Map<String, Object>) value).keySet()) {
                    properties.put(name, forOpenAI(((Map<String, Object>) value).get(name)));
                }
                result.put(key, properties);
            } else {
                result.put(key, forOpenAI(value));
            }
        }
        Object format = schema.get('format');
        if (format == 'salesforce-id') {
            result.put('pattern', SALESFORCE_ID_PATTERN);
            withHint(result, SALESFORCE_ID_HINT);
        } else if (format == 'uri') {
            withHint(result, URI_HINT);
        }
        return result;
    }

    private static void withHint(Map<String, Object> schema, String guidance) {
        String description = schema.get('description') instanceof String ? (String) schema.get('description') : null;
        if (String.isBlank(description)) {
            schema.put('description', guidance);
        } else if (!description.contains(guidance)) {
            schema.put('description', description + ' ' + guidance);
        }
    }

    /** Strict mode needs every object closed and every property required. */
    @TestVisible
    private static Boolean isStrictCompatible(Object node) {
        if (node instanceof List<Object>) {
            for (Object item : (List<Object>) node) {
                if (!isStrictCompatible(item)) {
                    return false;
                }
            }
            return true;
        }
        if (!(node instanceof Map<String, Object>)) {
            return true;
        }
        Map<String, Object> schema = (Map<String, Object>) node;
        if (schema.get('type') == 'object') {
            Map<String, Object> properties = schema.get('properties') instanceof Map<String, Object>
                ? (Map<String, Object>) schema.get('properties')
                : new Map<String, Object>();
            Set<String> required = new Set<String>();
            for (Object name : schema.get('required') instanceof List<Object> ? (List<Object>) schema.get('required') : new List<Object>()) {
                required.add(String.valueOf(name));
            }
            if (schema.get('additionalProperties') != false || !required.containsAll(properties.keySet())) {
                return false;
            }
        }
        for (Object value : schema.values()) {
            if (!isStrictCompatible(value)) {
                return false;
            }
        }
        return true;
    }

    private static AgentKernelModels.ModelResponse parse(HttpResponse response, Long duration, String requestBody) {
        Map<String, Object> envelope;
        try {
            envelope = (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
        } catch (Exception malformed) {
            throw new AgentKernelException.PermanentException('The model endpoint returned a response that is not JSON.');
        }
        if (envelope == null) {
            throw new AgentKernelException.PermanentException('The model endpoint returned an empty response.');
        }
        AgentKernelModels.ModelResponse result = new AgentKernelModels.ModelResponse();
        result.durationMilliseconds = duration;
        result.providerRequestId = (String) envelope.get('id');
        result.nativeRequestEvidence = requestBody;
        result.nativeResponseEvidence = replyEvidence(envelope);
        addUsage(result, envelope.get('usage') instanceof Map<String, Object> ? (Map<String, Object>) envelope.get('usage') : null);
        if (envelope.get('status') == 'failed' || envelope.get('error') instanceof Map<String, Object>) {
            // A response can fail after HTTP 200; a server error is worth another attempt.
            Map<String, Object> error = envelope.get('error') instanceof Map<String, Object>
                ? (Map<String, Object>) envelope.get('error')
                : new Map<String, Object>();
            String code = error.get('code') instanceof String ? ((String) error.get('code')).toUpperCase() : 'FAILED';
            AgentKernelModels.ModelResponse failed = declined(result, 'OPENAI_RESPONSE_' + code, 'The model endpoint reported a failed response.');
            failed.retryable = code == 'SERVER_ERROR' || code == 'RATE_LIMIT_EXCEEDED';
            return failed;
        }
        if (envelope.get('status') == 'incomplete') {
            Map<String, Object> details = envelope.get('incomplete_details') instanceof Map<String, Object>
                ? (Map<String, Object>) envelope.get('incomplete_details')
                : new Map<String, Object>();
            return details.get('reason') == 'content_filter'
                ? declined(result, 'MODEL_REFUSED', 'The model declined this request.')
                : declined(result, 'MODEL_OUTPUT_TRUNCATED', 'The answer exceeded the output token limit.');
        }
        List<String> texts = new List<String>();
        List<AgentKernelModels.ModelToolCall> toolCalls = new List<AgentKernelModels.ModelToolCall>();
        for (Object raw : envelope.get('output') instanceof List<Object> ? (List<Object>) envelope.get('output') : new List<Object>()) {
            if (!(raw instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> item = (Map<String, Object>) raw;
            if (item.get('type') == 'function_call') {
                AgentKernelModels.ModelToolCall toolCall = new AgentKernelModels.ModelToolCall();
                toolCall.toolCallId = item.get('call_id') instanceof String ? (String) item.get('call_id') : null;
                toolCall.toolName = item.get('name') instanceof String ? (String) item.get('name') : null;
                toolCall.toolInput = item.get('arguments') instanceof String ? (String) item.get('arguments') : null;
                toolCalls.add(toolCall);
            } else if (item.get('type') == 'message') {
                for (Object part : item.get('content') instanceof List<Object> ? (List<Object>) item.get('content') : new List<Object>()) {
                    if (!(part instanceof Map<String, Object>)) {
                        continue;
                    }
                    Map<String, Object> content = (Map<String, Object>) part;
                    if (content.get('type') == 'refusal') {
                        return declined(result, 'MODEL_REFUSED', 'The model declined this request.');
                    }
                    if (content.get('type') == 'output_text' && content.get('text') instanceof String) {
                        texts.add((String) content.get('text'));
                    }
                }
            }
        }
        result.isSuccess = true;
        if (!toolCalls.isEmpty()) {
            result.isFinal = false;
            result.toolCalls = toolCalls;
        } else {
            result.isFinal = true;
            result.output = texts.isEmpty() ? null : String.join(texts, '');
        }
        return result;
    }

    /** The parts of a response that are the reply, in a fixed order. */
    private static final List<String> REPLY_FIELDS = new List<String>{
        'id',
        'status',
        'model',
        'created_at',
        'completed_at',
        'error',
        'incomplete_details',
        'output',
        'usage'
    };

    /** The response without what it repeats from the request and without encrypted reasoning. */
    @TestVisible
    private static String replyEvidence(Map<String, Object> envelope) {
        JSONGenerator reply = JSON.createGenerator(false);
        reply.writeStartObject();
        for (String field : REPLY_FIELDS) {
            Object value = envelope.get(field);
            if (value == null) {
                continue;
            }
            if (field == 'output' && value instanceof List<Object>) {
                for (Object item : (List<Object>) value) {
                    if (item instanceof Map<String, Object>) {
                        ((Map<String, Object>) item).remove('encrypted_content');
                    }
                }
            }
            reply.writeObjectField(field, value);
        }
        reply.writeEndObject();
        return reply.getAsString();
    }

    private static AgentKernelModels.ModelResponse declined(AgentKernelModels.ModelResponse result, String code, String message) {
        result.isSuccess = false;
        result.retryable = false;
        result.errorCode = code;
        result.errorMessage = message;
        return result;
    }

    private static AgentKernelModels.ModelResponse httpFailure(HttpResponse response, Long duration, String requestBody) {
        Integer status = response.getStatusCode();
        AgentKernelModels.ModelResponse result = new AgentKernelModels.ModelResponse();
        result.isSuccess = false;
        result.retryable = status == 408 || status == 429 || status >= 500;
        result.errorCode = 'OPENAI_API_' + status + errorCode(response.getBody());
        result.errorMessage = status == 401 ||
            status == 403
            ? 'The model endpoint refused the credential (HTTP ' + status + '). Check the API key on the Agent Model\'s External Credential.'
            : 'The model endpoint returned HTTP ' + status + '.';
        result.durationMilliseconds = duration;
        result.providerRequestId = response.getHeader('x-request-id');
        result.nativeRequestEvidence = requestBody;
        result.nativeResponseEvidence = response.getBody();
        String retryAfter = response.getHeader('retry-after');
        if (retryAfter != null && retryAfter.isNumeric()) {
            result.retryAfterSeconds = Integer.valueOf(retryAfter);
        }
        return result;
    }

    /** The API error code or type, such as _RATE_LIMIT_EXCEEDED, so operators see why without reading the payload. */
    private static String errorCode(String body) {
        try {
            Object error = ((Map<String, Object>) JSON.deserializeUntyped(body)).get('error');
            if (!(error instanceof Map<String, Object>)) {
                return '';
            }
            Object code = ((Map<String, Object>) error).get('code');
            Object type = ((Map<String, Object>) error).get('type');
            Object value = code instanceof String ? code : type;
            return value instanceof String ? '_' + ((String) value).toUpperCase() : '';
        } catch (Exception unreadable) {
            return '';
        }
    }

    private static void addUsage(AgentKernelModels.ModelResponse result, Map<String, Object> usage) {
        if (usage == null) {
            return;
        }
        result.inputTokens = wholeNumber(usage.get('input_tokens'));
        result.outputTokens = wholeNumber(usage.get('output_tokens'));
        result.totalTokens = wholeNumber(usage.get('total_tokens'));
    }

    private static Long wholeNumber(Object value) {
        if (value instanceof Integer || (value instanceof Decimal && ((Decimal) value).scale() == 0)) {
            Long count = Long.valueOf(String.valueOf(value));
            return count >= 0 ? count : null;
        }
        return null;
    }
}
