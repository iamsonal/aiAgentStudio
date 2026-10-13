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
 * Applies DTO-wide bounds immediately after an extension returns and before
 * trust scanning, evidence serialization, or lifecycle persistence.
 */
public inherited sharing class ExtensionResponseValidator {
    private static final Integer MAX_STRING_CHARACTERS = 131072;
    private static final Integer MAX_TOTAL_CHARACTERS = 262144;
    // This is a defensive DTO ceiling. The model worker owns the stricter
    // per-turn product limit so it can return TOOL_BATCH_LIMIT_EXCEEDED.
    private static final Integer MAX_TOOL_CALLS = 50;
    private static final Integer MAX_RECORD_SETS = 10;
    private static final Integer MAX_RECORDS = 200;

    public static void validateModel(AgentKernelModels.ModelResponse response) {
        if (response == null) {
            return;
        }
        Integer totalCharacters = 0;
        totalCharacters += characters(response.output, 'Model output');
        totalCharacters += characters(response.providerRequestId, 'Model provider request ID');
        totalCharacters += characters(response.errorCode, 'Model error code');
        totalCharacters += characters(response.errorMessage, 'Model error message');
        totalCharacters += characters(response.nativeRequestEvidence, 'Model native request evidence');
        totalCharacters += characters(response.nativeResponseEvidence, 'Model native response evidence');
        List<AgentKernelModels.ModelToolCall> toolCalls = response.toolCalls == null ? new List<AgentKernelModels.ModelToolCall>() : response.toolCalls;
        if (toolCalls.size() > MAX_TOOL_CALLS) {
            reject('Model tool-call collection exceeds the supported count.');
        }
        for (AgentKernelModels.ModelToolCall toolCall : toolCalls) {
            if (toolCall == null) {
                continue;
            }
            totalCharacters += characters(toolCall.toolName, 'Model tool name');
            totalCharacters += characters(toolCall.toolInput, 'Model tool input');
            totalCharacters += characters(toolCall.toolCallId, 'Model tool-call ID');
        }
        validateTotal(totalCharacters, 'Model response');
    }

    public static void validateTool(AgentKernelModels.ToolResponse response) {
        if (response == null) {
            return;
        }
        Integer totalCharacters = 0;
        totalCharacters += characters(response.output, 'Tool output');
        totalCharacters += characters(response.externalReference, 'Tool external reference');
        totalCharacters += characters(response.errorCode, 'Tool error code');
        totalCharacters += characters(response.errorMessage, 'Tool error message');
        totalCharacters += characters(response.waitingReason, 'Tool waiting reason');
        totalCharacters += characters(response.resumeJsonSchema, 'Tool resume schema');
        totalCharacters += characters(response.nativeRequestEvidence, 'Tool native request evidence');
        totalCharacters += characters(response.nativeResponseEvidence, 'Tool native response evidence');
        if (response.recordSets != null) {
            if (response.recordSets.size() > MAX_RECORD_SETS) {
                reject('Tool record-set collection exceeds the supported count.');
            }
            Integer recordCount = 0;
            for (String setName : response.recordSets.keySet()) {
                totalCharacters += characters(setName, 'Tool record-set name');
                List<SObject> records = response.recordSets.get(setName);
                recordCount += records == null ? 0 : records.size();
                if (recordCount > MAX_RECORDS) {
                    reject('Tool structured output exceeds the supported record count.');
                }
            }
        }
        validateTotal(totalCharacters, 'Tool response');
    }

    private static Integer characters(String value, String label) {
        Integer length = value == null ? 0 : value.length();
        if (length > MAX_STRING_CHARACTERS) {
            reject(label + ' exceeds the supported length.');
        }
        return length;
    }

    private static void validateTotal(Integer totalCharacters, String label) {
        if (totalCharacters > MAX_TOTAL_CHARACTERS) {
            reject(label + ' exceeds the aggregate supported length.');
        }
    }

    private static void reject(String message) {
        throw new AgentKernelException.PermanentException(message);
    }
}
