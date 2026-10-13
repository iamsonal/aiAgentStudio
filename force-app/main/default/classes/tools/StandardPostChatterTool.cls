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
 * Standard tool: post one text message to a Chatter feed.
 *
 * Standard tool type PostChatter.
 *
 * ImplementationConfiguration__c (operator-only, never sent to the model):
 *   {"targetId": "0F9..."} to post to a user, Chatter group, or feed-tracked
 *   record. Blank, or no targetId, posts to the run's record.
 *
 * Tool input (model-visible, governed by the closed InputSchema__c):
 *   {"messageText": "A concise update for the configured feed."}
 *
 * Recovery contract: a post is a record in this org, so the tool type has no
 * external effects and Core runs it in a savepoint. A Connect API rejection
 * is permanent; a failed or lost post is rolled back and safe to repeat.
 */
public inherited sharing class StandardPostChatterTool implements ITool, IRequesterFilteredTool, IToolAuthoring {
    private static final Integer MAX_MESSAGE_CHARACTERS = 10000;

    public AgentKernelModels.ToolResponse execute(AgentKernelModels.ToolRequest request) {
        Map<String, Object> config = configurationOf(request == null ? null : request.implementationConfiguration);
        Map<String, Object> input = objectOf(request == null ? null : request.input, 'Tool input');
        for (String key : input.keySet()) {
            if (key != 'messageText') {
                throw permanent('Tool input contains an unsupported property: ' + key + '.');
            }
        }
        String messageText = input.get('messageText') instanceof String ? ((String) input.get('messageText')).trim() : null;
        if (String.isBlank(messageText)) {
            throw permanent('Tool input must include a non-blank messageText.');
        }
        if (messageText.length() > MAX_MESSAGE_CHARACTERS) {
            throw permanent('messageText must not exceed ' + MAX_MESSAGE_CHARACTERS + ' characters.');
        }
        Id targetId = targetId(config, request);
        assertVisible(targetId);
        ToolSecurity.assertRequesterCanRead(request.principal, targetId);

        ConnectApi.TextSegmentInput text = new ConnectApi.TextSegmentInput();
        text.text = messageText;
        ConnectApi.MessageBodyInput body = new ConnectApi.MessageBodyInput();
        body.messageSegments = new List<ConnectApi.MessageSegmentInput>{ text };
        ConnectApi.FeedItemInput feedItem = new ConnectApi.FeedItemInput();
        feedItem.subjectId = targetId;
        feedItem.body = body;
        try {
            ConnectApi.FeedElement result = ConnectApi.ChatterFeeds.postFeedElement(Network.getNetworkId(), feedItem);
            if (result == null || String.isBlank(result.id)) {
                throw new AgentKernelException.OutcomeUnknownException('The Chatter post outcome could not be confirmed.');
            }
            return success(JSON.serialize(new Map<String, Object>{ 'feedElementId' => result.id }));
        } catch (ConnectApi.ConnectApiException rejected) {
            throw permanent('The Chatter post was rejected: ' + rejected.getMessage().left(500));
        } catch (AgentKernelException.OutcomeUnknownException uncertain) {
            throw uncertain;
        } catch (Exception ambiguous) {
            throw new AgentKernelException.OutcomeUnknownException('The Chatter post outcome could not be confirmed.');
        }
    }

    public List<String> validateConfiguration(AgentKernelModels.ToolConfiguration configuration) {
        try {
            Id configured = configuredTargetId(configurationOf(configuration == null ? null : configuration.implementationConfiguration));
            if (configured != null) {
                assertFeedTarget(configured);
            }
            return new List<String>();
        } catch (Exception invalid) {
            return new List<String>{ invalid.getMessage() };
        }
    }

    /** The input is always the message; the one setting chooses where it is posted. */
    public AgentKernelModels.ToolAuthoring describe(AgentKernelModels.ToolConfiguration configuration) {
        AgentKernelModels.ToolAuthoring authoring = new AgentKernelModels.ToolAuthoring();
        AgentKernelModels.ToolSetting target = new AgentKernelModels.ToolSetting(
            'targetId',
            'Post To',
            'record',
            false,
            'Where the post goes. A record other than a user or group needs feed tracking.'
        );
        target.recordObjects = new List<String>{ 'User', 'CollaborationGroup' };
        target.blankMeaning = 'The run\'s record';
        authoring.settings.add(target);
        authoring.inputSchema = StandardToolSchemas.chatterInputs(MAX_MESSAGE_CHARACTERS);
        return authoring;
    }

    private static Id targetId(Map<String, Object> config, AgentKernelModels.ToolRequest request) {
        Id configured = configuredTargetId(config);
        if (configured == null) {
            Id anchorId = request == null || request.principal == null ? null : request.principal.anchorRecordId;
            if (anchorId == null) {
                throw permanent('This tool posts to the run\'s record, but the run has none. Set Post To on the tool, or start the run on a record.');
            }
            assertFeedTarget(anchorId);
            return anchorId;
        }
        assertFeedTarget(configured);
        return configured;
    }

    /** The configured target, or null for the run's record. */
    private static Id configuredTargetId(Map<String, Object> config) {
        for (String key : config.keySet()) {
            if (key != 'targetId') {
                throw permanent('Unknown setting ' + key + '. Post to Chatter has one setting, targetId.');
            }
        }
        Object value = config.get('targetId');
        if (value == null || (value instanceof String && String.isBlank((String) value))) {
            return null;
        }
        try {
            return Id.valueOf(String.valueOf(value).trim());
        } catch (Exception invalid) {
            throw permanent('targetId must be the ID of a user, Chatter group, or feed-tracked record.');
        }
    }

    private static void assertFeedTarget(Id targetId) {
        Schema.DescribeSObjectResult describe = targetId.getSObjectType().getDescribe();
        String objectApiName = describe.getName();
        if (objectApiName != 'User' && objectApiName != 'CollaborationGroup' && !describe.isFeedEnabled()) {
            throw permanent('The Chatter target must be a User, a Chatter group, or a record with feed tracking enabled.');
        }
    }

    private static void assertVisible(Id targetId) {
        List<SObject> visible;
        try {
            visible = Database.query('SELECT Id FROM ' + targetId.getSObjectType().getDescribe().getName() + ' WHERE Id = :targetId WITH USER_MODE LIMIT 1');
        } catch (Exception inaccessible) {
            visible = new List<SObject>();
        }
        if (visible.isEmpty()) {
            throw permanent('The Chatter target was not found or is not visible to the execution principal.');
        }
    }

    private static Map<String, Object> configurationOf(String value) {
        return String.isBlank(value) ? new Map<String, Object>() : objectOf(value, 'Tool implementation configuration');
    }

    private static Map<String, Object> objectOf(String value, String label) {
        try {
            Object parsed = String.isBlank(value) ? null : JSON.deserializeUntyped(value);
            if (parsed instanceof Map<String, Object>) {
                return (Map<String, Object>) parsed;
            }
        } catch (Exception ignored) {
        }
        throw permanent(label + ' must be a JSON object.');
    }

    private static AgentKernelModels.ToolResponse success(String output) {
        AgentKernelModels.ToolResponse response = new AgentKernelModels.ToolResponse();
        response.isSuccess = true;
        response.outcomeUnknown = false;
        response.output = output;
        return response;
    }

    private static AgentKernelException.PermanentException permanent(String message) {
        return new AgentKernelException.PermanentException(message.left(2000));
    }
}
