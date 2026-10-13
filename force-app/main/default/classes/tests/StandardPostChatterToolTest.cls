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
private class StandardPostChatterToolTest {
    private static AgentKernelModels.ToolRequest request(String config, String input) {
        AgentKernelModels.ToolRequest toolRequest = new AgentKernelModels.ToolRequest();
        toolRequest.toolName = 'standard_post_chatter';
        toolRequest.implementationConfiguration = config;
        toolRequest.input = input;
        return toolRequest;
    }

    @IsTest
    static void rejectsInvalidConfigurationAndInputBeforePosting() {
        assertPermanent(null, '{"messageText":"Update"}', 'the run has none');
        assertPermanent('[]', '{"messageText":"Update"}', 'implementation configuration');
        assertPermanent('{"targetId":"not-an-id"}', '{"messageText":"Update"}', 'targetId must be the ID');
        assertPermanent('{"targetId":"001000000000000AAA"}', '{}', 'messageText');
        assertPermanent('{"targetId":"001000000000000AAA"}', '{"messageText":" ","topics":[]}', 'unsupported property');
    }

    @IsTest
    static void rejectsOversizedMessageBeforePosting() {
        String message = '';
        for (Integer index = 0; index < 10001; index++) {
            message += 'x';
        }
        assertPermanent('{"targetId":"001000000000000AAA"}', '{"messageText":"' + message + '"}', 'must not exceed');
    }

    @IsTest
    static void rejectsNonFeedTargetsWhenSaved() {
        AgentKernelModels.ToolConfiguration configuration = new AgentKernelModels.ToolConfiguration();
        configuration.implementationConfiguration = JSON.serialize(new Map<String, Object>{ 'targetId' => UserInfo.getProfileId() });
        List<String> problems = new StandardPostChatterTool().validateConfiguration(configuration);
        System.assertEquals(1, problems.size());
        System.assert(problems[0].contains('feed tracking'), 'A Profile is not a permitted Chatter target.');

        configuration.implementationConfiguration = null;
        System.assert(new StandardPostChatterTool().validateConfiguration(configuration).isEmpty(), 'A blank Post To posts to the run\'s record.');

        configuration.implementationConfiguration = '{"target":"Anchor Record"}';
        System.assert(
            new StandardPostChatterTool().validateConfiguration(configuration)[0].contains('Unknown setting target'),
            'The replaced target setting is named.'
        );
    }

    @IsTest
    static void describesOneOptionalPostToSetting() {
        AgentKernelModels.ToolAuthoring authoring = new StandardPostChatterTool().describe(new AgentKernelModels.ToolConfiguration());
        System.assertEquals(1, authoring.settings.size());
        AgentKernelModels.ToolSetting target = authoring.settings[0];
        System.assertEquals('record', target.type);
        System.assertEquals(new List<String>{ 'User', 'CollaborationGroup' }, target.recordObjects);
        System.assertEquals('The run\'s record', target.blankMeaning);
        System.assert(authoring.inputSchema.contains('messageText'));
    }

    private static void assertPermanent(String config, String input, String expectedFragment) {
        Boolean rejected = false;
        try {
            new StandardPostChatterTool().execute(request(config, input));
        } catch (AgentKernelException.PermanentException expected) {
            rejected = expected.getMessage().contains(expectedFragment);
        }
        System.assert(rejected, 'Expected permanent rejection containing: ' + expectedFragment);
    }
}
