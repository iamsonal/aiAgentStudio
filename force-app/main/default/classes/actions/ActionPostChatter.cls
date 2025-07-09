/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Standard Action: Posts a message to a specified Chatter feed.
 *              Extends BaseAgentAction for standardized execution flow and error handling.
 *              Uses ConnectApi, supporting posts to Records, Users, or Groups.
 * @extends BaseAgentAction
 */
public class ActionPostChatter extends BaseAgentAction {
    private static final String ARG_TEXT = 'text';
    private static final String ARG_TOPICS = 'topics';

    private static final String CONFIG_FEED_TYPE = 'feedType';
    private static final String CONFIG_TARGET_ID = 'targetId';

    private String feedType;
    private Id targetSObjectId;
    private String targetSObjectName;

    /**
     * @description Provides a specific log prefix for this action type.
     * @return String 'ActionPostChatter'
     */
    protected override String getLogPrefixName() {
        return 'ActionPostChatter';
    }

    /**
     * @description Parses ActionConfiguration to get feedType and targetId.
     * @param actionConfigurationJson The raw JSON string from BackendConfiguration__c.
     * @param logPrefix Logging prefix.
     * @throws ValidationException if config is invalid or missing required keys.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig == null || this.parsedActionConfig.isEmpty()) {
            throw new ValidationException('BackendConfiguration is required for ActionPostChatter.', null);
        }

        this.feedType = ParameterExtractionUtils.getRequiredString(this.parsedActionConfig, CONFIG_FEED_TYPE);
        this.targetSObjectId = ParameterExtractionUtils.getRequiredId(this.parsedActionConfig, CONFIG_TARGET_ID, null);

        this.targetSObjectName = this.targetSObjectId.getSObjectType().getDescribe().getName();
        if (
            (this.feedType == 'User' &&
            this.targetSObjectName != 'User') ||
            (this.feedType == 'Group' &&
            this.targetSObjectName != 'CollaborationGroup') ||
            (this.feedType == 'Record' && (this.targetSObjectName == 'User' || this.targetSObjectName == 'CollaborationGroup'))
        ) {
            throw new ValidationException(
                'Mismatch between configured feedType "' + this.feedType + '" and targetId object type "' + this.targetSObjectName + '".',
                null
            );
        }
    }

    /**
     * @description (MODIFIED) Defines arguments expected from the LLM. Now only 'text' and 'topics'.
     */
    class PostChatterParsedArguments extends BaseAgentAction.ParsedArguments {
        String text;
        List<String> topics;

        public PostChatterParsedArguments(String jsonArguments) {
            if (String.isBlank(jsonArguments)) {
                throw new ValidationException('Input arguments JSON cannot be blank.', null);
            }

            Map<String, Object> parsedArgs = (Map<String, Object>) JSON.deserializeUntyped(jsonArguments);

            this.text = ParameterExtractionUtils.getRequiredString(parsedArgs, ARG_TEXT);

            this.topics = ParameterExtractionUtils.getOptionalStringList(parsedArgs, ARG_TOPICS);
        }
    }

    /**
     * @description (MODIFIED) Parses the LLM arguments (now just text/topics).
     */
    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        try {
            return new PostChatterParsedArguments(argumentsJson);
        } catch (ParameterExtractionUtils.ArgumentValidationException ave) {
            throw new ValidationException(ave.getMessage(), null);
        } catch (Exception e) {
            throw new ValidationException('Failed to parse/validate PostChatter arguments: ' + e.getMessage(), null);
        }
    }

    /**
     * @description (MODIFIED) Core logic now uses instance variables from backend config.
     */
    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        PostChatterParsedArguments args = (PostChatterParsedArguments) validatedArgs;

        Id currentTargetId = this.targetSObjectId;
        String currentFeedType = this.feedType;
        String currentTargetObjectName = this.targetSObjectName;

        try {
            String query = 'SELECT Id FROM ' + currentTargetObjectName + ' WHERE Id = :targetId LIMIT 1';
            List<SObject> targetCheck = Database.queryWithBinds(
                query,
                new Map<String, Object>{ 'targetId' => currentTargetId },
                AccessLevel.USER_MODE
            );
            if (targetCheck.isEmpty()) {
                throw new ActionSecurityException(
                    'Target ' + currentFeedType + ' with ID ' + currentTargetId + ' not found or user lacks READ access.'
                );
            }
        } catch (System.QueryException qe) {
            throw qe;
        }

        ConnectApi.FeedItemInput feedItemInput = new ConnectApi.FeedItemInput();
        ConnectApi.MessageBodyInput messageBodyInput = new ConnectApi.MessageBodyInput();
        ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
        textSegment.text = args.text;
        messageBodyInput.messageSegments = new List<ConnectApi.MessageSegmentInput>{ textSegment };
        feedItemInput.body = messageBodyInput;

        feedItemInput.subjectId = currentTargetId;

        if (args.topics != null && !args.topics.isEmpty()) {
            ConnectApi.FeedElementCapabilitiesInput capabilitiesInput = new ConnectApi.FeedElementCapabilitiesInput();
            ConnectApi.TopicsCapabilityInput topicsCapabilityInput = new ConnectApi.TopicsCapabilityInput();
            topicsCapabilityInput.topics = new List<String>();
            for (String topicName : args.topics) {
                if (String.isNotBlank(topicName)) {
                    topicsCapabilityInput.topics.add(topicName.trim());
                }
            }
            if (!topicsCapabilityInput.topics.isEmpty()) {
                capabilitiesInput.topics = topicsCapabilityInput;
                feedItemInput.capabilities = capabilitiesInput;
            }
        }

        ConnectApi.FeedElement feedElement = ConnectApi.ChatterFeeds.postFeedElement(Network.getNetworkId(), feedItemInput);

        String successMsg = 'I have successfully posted the message to the ' + currentFeedType + ' feed.';
        Map<String, Object> dataPayload = new Map<String, Object>{ 'feedElementId' => feedElement.id };
        String internalDetails = 'Chatter post created. ID: ' + feedElement.id;

        return this.success(dataPayload, successMsg, internalDetails);
    }
}
