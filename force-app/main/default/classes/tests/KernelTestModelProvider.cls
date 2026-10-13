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

@IsTest
public class KernelTestModelProvider implements IModelProvider {
    public static String mode = 'final';
    public static Integer invocationCount = 0;
    public static String finalOutput = '{"result":"test model output"}';
    public static String providerRequestId;
    public static Long durationMilliseconds;
    public static Long inputTokens;
    public static Long outputTokens;
    public static Long totalTokens;
    public static String toolCallId;
    public static String toolInput = '{"value":"test"}';
    public static List<AgentKernelModels.TranscriptEntry> lastTranscript;
    public static Boolean lastTranscriptTruncated;
    public static Integer lastCharacterBudget;
    public static Integer lastCharacterCount;
    public static String lastRequestJson;
    public static String nativeRequestEvidence;
    public static String nativeResponseEvidence;
    public static List<AgentKernelModels.ModelToolCall> toolCallsOverride;
    /** Scripted turns: each call returns the next response, so one run can make several different decisions. */
    public static List<AgentKernelModels.ModelResponse> script;
    /** Every request this provider received, in order. */
    public static List<String> requestLog = new List<String>();

    /** Adds a turn that asks for one tool call. */
    public static void scriptToolCall(String toolName, String toolInput) {
        AgentKernelModels.ModelToolCall call = new AgentKernelModels.ModelToolCall();
        call.toolName = toolName;
        call.toolInput = toolInput;
        call.toolCallId = 'scripted-call-' + (scriptLength() + 1);
        AgentKernelModels.ModelResponse response = new AgentKernelModels.ModelResponse();
        response.isSuccess = true;
        response.isFinal = false;
        response.toolCalls = new List<AgentKernelModels.ModelToolCall>{ call };
        addScripted(response);
    }

    /** Adds a turn that gives the final answer. */
    public static void scriptFinal(String output) {
        AgentKernelModels.ModelResponse response = new AgentKernelModels.ModelResponse();
        response.isSuccess = true;
        response.isFinal = true;
        response.output = output;
        addScripted(response);
    }

    /** Adds a turn where the provider rejects the request and asks for no retry. */
    public static void scriptProviderError(String errorCode, String errorMessage) {
        AgentKernelModels.ModelResponse response = new AgentKernelModels.ModelResponse();
        response.isSuccess = false;
        response.retryable = false;
        response.errorCode = errorCode;
        response.errorMessage = errorMessage;
        addScripted(response);
    }

    private static void addScripted(AgentKernelModels.ModelResponse response) {
        if (script == null) {
            script = new List<AgentKernelModels.ModelResponse>();
        }
        script.add(response);
    }

    private static Integer scriptLength() {
        return script == null ? 0 : script.size();
    }

    public AgentKernelModels.ModelResponse invoke(AgentKernelModels.ModelRequest request) {
        invocationCount++;
        lastTranscript = request.transcript;
        lastTranscriptTruncated = request.transcriptTruncated;
        lastCharacterBudget = request.characterBudget;
        lastCharacterCount = request.characterCount;
        lastRequestJson = JSON.serialize(request);
        requestLog.add(lastRequestJson);
        if (script != null) {
            System.assert(!script.isEmpty(), 'The model was called more often than the test scripted.');
            return script.remove(0);
        }
        AgentKernelModels.ModelResponse response = new AgentKernelModels.ModelResponse();
        response.providerRequestId = providerRequestId;
        response.durationMilliseconds = durationMilliseconds;
        response.inputTokens = inputTokens;
        response.outputTokens = outputTokens;
        response.totalTokens = totalTokens;
        response.nativeRequestEvidence = nativeRequestEvidence;
        response.nativeResponseEvidence = nativeResponseEvidence;
        if (mode == 'timeout') {
            throw new CalloutException('Read timed out');
        }
        if (mode == 'unexpectedException') {
            throw new AgentKernelException.ConfigurationException('Unexpected provider programming fault.');
        }
        if (mode == 'retry') {
            response.isSuccess = false;
            response.retryable = true;
            response.errorCode = 'TEST_RETRY';
            response.errorMessage = 'Retry requested by test provider.';
            return response;
        }
        if (mode == 'malformed') {
            response.isSuccess = true;
            return response;
        }
        response.isSuccess = true;
        if (toolCallsOverride != null) {
            response.isFinal = false;
            response.toolCalls = toolCallsOverride;
            return response;
        }
        if (mode == 'toolThenFinal' && invocationCount == 1) {
            response.isFinal = false;
            AgentKernelModels.ModelToolCall toolCall = new AgentKernelModels.ModelToolCall();
            toolCall.toolName = 'test_tool';
            toolCall.toolInput = toolInput;
            toolCall.toolCallId = toolCallId;
            response.toolCalls = new List<AgentKernelModels.ModelToolCall>{ toolCall };
            return response;
        }
        response.isFinal = true;
        response.output = finalOutput;
        return response;
    }
}
