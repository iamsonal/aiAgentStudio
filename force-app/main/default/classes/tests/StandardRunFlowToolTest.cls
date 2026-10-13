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
private class StandardRunFlowToolTest {
    private static final String ECHO_FLOW = 'StandardToolTestEchoFlow';

    private static AgentKernelModels.ToolRequest request(String config, String input) {
        AgentKernelModels.ToolRequest toolRequest = new AgentKernelModels.ToolRequest();
        toolRequest.toolName = 'flow_tool';
        toolRequest.input = input;
        toolRequest.implementationConfiguration = config;
        return toolRequest;
    }

    private static AgentKernelModels.ToolConfiguration configuration(String config) {
        AgentKernelModels.ToolConfiguration toolConfiguration = new AgentKernelModels.ToolConfiguration();
        toolConfiguration.toolName = 'flow_tool';
        toolConfiguration.implementationConfiguration = config;
        return toolConfiguration;
    }

    @IsTest
    static void runsEchoFlowAndReturnsOutputs() {
        AgentKernelModels.ToolResponse response = new StandardRunFlowTool()
            .execute(request('{"flowApiName":"' + ECHO_FLOW + '","allowSystemContext":true}', '{"echoInput":"hello"}'));

        System.assertEquals(true, response.isSuccess);
        Map<String, Object> output = (Map<String, Object>) JSON.deserializeUntyped(response.output);
        System.assertEquals('hello', output.get('echoOutput'));
    }

    @IsTest
    static void returnsRecordOutputsAsStructuredRecordSets() {
        AgentKernelModels.ToolResponse response = new StandardRunFlowTool()
            .execute(
                request('{"flowApiName":"StandardToolTestRecordFlow","allowSystemContext":true}', '{"nameInput":"Acme","descriptionInput":"Classified note"}')
            );

        System.assertEquals(true, response.isSuccess);
        System.assertEquals(null, response.output, 'Records must not bypass Core structured protection as plain output.');
        List<SObject> accounts = response.recordSets.get('accountOutput');
        System.assertEquals(1, accounts.size());
        System.assertEquals('Acme', accounts[0].get('Name'));
    }

    @IsTest
    static void rejectsMixedRecordAndScalarOutputs() {
        try {
            StandardRunFlowTool.returnsRecords('Mixed_Flow', new Map<String, Boolean>{ 'account' => true, 'status' => false });
            System.assert(false, 'Mixed outputs must be rejected before launch.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assert(expected.getMessage().contains('both record and non-record'));
        }
        System.assertEquals(true, StandardRunFlowTool.returnsRecords('Record_Flow', new Map<String, Boolean>{ 'account' => true }));
        System.assertEquals(false, StandardRunFlowTool.returnsRecords('Empty_Flow', new Map<String, Boolean>()));
    }

    @IsTest
    static void buildsItsInputsFromTheFlowsInputVariables() {
        AgentKernelModels.ToolAuthoring authoring = new StandardRunFlowTool().describe(configuration('{"flowApiName":"' + ECHO_FLOW + '"}'));
        System.assertEquals(null, authoring.problem);
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(authoring.inputSchema);
        Map<String, Object> echoInput = (Map<String, Object>) ((Map<String, Object>) schema.get('properties')).get('echoInput');
        System.assertEquals('string', echoInput.get('type'));
        System.assert(!schema.containsKey('required'), 'A Flow does not mark inputs required; the admin does with edits.');
        System.assertEquals(false, schema.get('additionalProperties'));
        System.assertEquals('flow', authoring.settings[0].type);
    }

    @IsTest
    static void explainsWhyAFlowCannotBuildInputs() {
        System.assert(
            new StandardRunFlowTool().describe(configuration('{"flowApiName":"No_Such_Flow_Anywhere"}')).problem.contains('was not found'),
            'An unknown Flow says what to fix.'
        );
    }

    @IsTest
    static void rejectsMissingConfiguration() {
        assertPermanent(null, '{}', 'implementation configuration');
        assertPermanent('{}', '{}', 'flowApiName');
        assertPermanent('{"flowApiName":"Has Spaces","allowSystemContext":true}', '{}', 'valid autolaunched flow API name');
    }

    @IsTest
    static void defaultModeFlowStillNeedsTheSystemAccessAcknowledgement() {
        // Started from Apex, a Default Mode flow runs with system object and field access.
        assertPermanent('{"flowApiName":"' + ECHO_FLOW + '"}', '{"echoInput":"hello"}', 'allowSystemContext');
        System.assert(
            !new StandardRunFlowTool().validateConfiguration(configuration('{"flowApiName":"' + ECHO_FLOW + '"}')).isEmpty(),
            'Saving the tool without the acknowledgement must fail.'
        );
    }

    @IsTest
    static void rejectsUnknownFlow() {
        assertPermanent('{"flowApiName":"No_Such_Flow_Anywhere","allowSystemContext":true}', '{}', 'was not found');
    }

    @IsTest
    static void rejectsNonObjectInput() {
        assertPermanent('{"flowApiName":"' + ECHO_FLOW + '","allowSystemContext":true}', 'not-json', 'must be a JSON object');
    }

    private static void assertPermanent(String config, String input, String expectedFragment) {
        Boolean rejected = false;
        try {
            new StandardRunFlowTool().execute(request(config, input));
        } catch (AgentKernelException.PermanentException expected) {
            rejected = expected.getMessage().contains(expectedFragment);
        }
        System.assert(rejected, 'Expected permanent rejection containing: ' + expectedFragment);
    }
}
