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

@IsTest(SeeAllData=false)
private class ExtensionResponseValidatorTest {
    @IsTest
    static void rejectsOversizedModelAndToolResponsesBeforePersistence() {
        String oversized = ''.leftPad(131073, 'x');
        AgentKernelModels.ModelResponse modelResponse = new AgentKernelModels.ModelResponse();
        modelResponse.output = oversized;
        assertRejectedModel(modelResponse);

        AgentKernelModels.ToolResponse toolResponse = new AgentKernelModels.ToolResponse();
        toolResponse.outcomeUnknown = true;
        toolResponse.errorMessage = oversized;
        assertRejectedTool(toolResponse);
    }

    @IsTest
    static void rejectsOversizedCollectionsAndAcceptsBoundedResponses() {
        AgentKernelModels.ModelResponse modelResponse = new AgentKernelModels.ModelResponse();
        modelResponse.toolCalls = new List<AgentKernelModels.ModelToolCall>();
        for (Integer index = 0; index < 51; index++) {
            modelResponse.toolCalls.add(new AgentKernelModels.ModelToolCall());
        }
        assertRejectedModel(modelResponse);

        AgentKernelModels.ToolResponse toolResponse = new AgentKernelModels.ToolResponse();
        toolResponse.output = '{"ok":true}';
        ExtensionResponseValidator.validateTool(toolResponse);
    }

    private static void assertRejectedModel(AgentKernelModels.ModelResponse response) {
        try {
            ExtensionResponseValidator.validateModel(response);
            System.assert(false, 'Expected oversized model response rejection.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assert(expected.getMessage().contains('supported'));
        }
    }

    private static void assertRejectedTool(AgentKernelModels.ToolResponse response) {
        try {
            ExtensionResponseValidator.validateTool(response);
            System.assert(false, 'Expected oversized tool response rejection.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assert(expected.getMessage().contains('supported'));
        }
    }
}
