/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Posts messages to Chatter feeds with intelligent processing.
 *              Framework automatically handles parameter extraction, validation, security, and result wrapping.
 *              Configuration example: {"feedType": "Record", "targetId": "003..."}
 *
 *              MAINTAINS: Comprehensive security validation, topic handling, and ConnectApi integration.
 *              ENHANCED: Simplified interface while preserving all robustness features.
 * @extends BaseAgentAction
 */
public class ActionPostChatter extends BaseAgentAction {
    private static final String CONFIG_FEED_TYPE = 'feedType';
    private static final String CONFIG_TARGET_ID = 'targetId';

    private String feedType;
    private Id targetSObjectId;
    private String targetSObjectName;

    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction and validation.
     *              ENHANCED: Maintains comprehensive Chatter functionality while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        String text = (String) params.get('text');
        List<String> topics = (List<String>) params.get('topics');

        if (String.isBlank(text)) {
            throw new ValidationException('Text parameter cannot be blank for Chatter post', 'text');
        }

        validateChatterTargetAccess();

        ConnectApi.FeedElement feedElement = createChatterPost(text, topics);

        Long executionTime = System.currentTimeMillis() - startTime;

        return new ChatterResult(
            feedElement.id,
            'I have successfully posted the message to the ' + this.feedType + ' feed.',
            text.length(),
            topics != null ? topics.size() : 0
        );
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig == null || this.parsedActionConfig.isEmpty()) {
            throw new ValidationException('BackendConfiguration is required for ActionPostChatter.', null);
        }

        this.feedType = ParameterExtractionUtils.getRequiredString(this.parsedActionConfig, CONFIG_FEED_TYPE);
        this.targetSObjectId = ParameterExtractionUtils.getRequiredId(this.parsedActionConfig, CONFIG_TARGET_ID, null);
        this.targetSObjectName = this.targetSObjectId.getSObjectType().getDescribe().getName();

        validateFeedTypeConsistency();
    }

    /**
     * @description Validates feed type and target ID consistency
     */
    private void validateFeedTypeConsistency() {
        if (
            (this.feedType == 'User' &&
            this.targetSObjectName != 'User') ||
            (this.feedType == 'Group' &&
            this.targetSObjectName != 'CollaborationGroup') ||
            (this.feedType == 'Record' && (this.targetSObjectName == 'User' || this.targetSObjectName == 'CollaborationGroup'))
        ) {
            throw new ValidationException(
                'Mismatch between feedType "' + this.feedType + '" and targetId object type "' + this.targetSObjectName + '".',
                CONFIG_FEED_TYPE
            );
        }
    }

    /**
     * @description Validates user access to the Chatter target
     */
    private void validateChatterTargetAccess() {
        try {
            String query = 'SELECT Id FROM ' + this.targetSObjectName + ' WHERE Id = :targetId LIMIT 1';
            List<SObject> targetCheck = Database.queryWithBinds(
                query,
                new Map<String, Object>{ 'targetId' => this.targetSObjectId },
                AccessLevel.USER_MODE
            );

            if (targetCheck.isEmpty()) {
                throw new ActionSecurityException(
                    'Target ' + this.feedType + ' with ID ' + this.targetSObjectId + ' not found or user lacks access.'
                );
            }
        } catch (System.QueryException qe) {
            String enhancedMessage = 'Failed to validate access to Chatter target: ' + qe.getMessage();

            throw new ActionSecurityException(enhancedMessage);
        }
    }

    /**
     * @description Creates and posts Chatter message with enhanced error handling
     */
    private ConnectApi.FeedElement createChatterPost(String text, List<String> topics) {
        try {
            if (text.length() > 10000) {
                text = text.substring(0, 10000) + '... [truncated]';
            }

            ConnectApi.FeedItemInput feedItemInput = new ConnectApi.FeedItemInput();
            ConnectApi.MessageBodyInput messageBodyInput = new ConnectApi.MessageBodyInput();
            ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
            textSegment.text = text;
            messageBodyInput.messageSegments = new List<ConnectApi.MessageSegmentInput>{ textSegment };
            feedItemInput.body = messageBodyInput;
            feedItemInput.subjectId = this.targetSObjectId;

            if (topics != null && !topics.isEmpty()) {
                ConnectApi.FeedElementCapabilitiesInput capabilitiesInput = new ConnectApi.FeedElementCapabilitiesInput();
                ConnectApi.TopicsCapabilityInput topicsCapabilityInput = new ConnectApi.TopicsCapabilityInput();
                topicsCapabilityInput.topics = new List<String>();

                for (String topicName : topics) {
                    if (String.isNotBlank(topicName)) {
                        String cleanTopic = topicName.trim();

                        if (cleanTopic.length() <= 25) {
                            topicsCapabilityInput.topics.add(cleanTopic);
                        } else {
                        }
                    }
                }

                if (!topicsCapabilityInput.topics.isEmpty()) {
                    capabilitiesInput.topics = topicsCapabilityInput;
                    feedItemInput.capabilities = capabilitiesInput;
                }
            }

            return ConnectApi.ChatterFeeds.postFeedElement(Network.getNetworkId(), feedItemInput);
        } catch (ConnectApi.ConnectApiException cae) {
            String enhancedMessage = 'Chatter post failed: ' + cae.getMessage();

            throw new ValidationException(enhancedMessage, null);
        } catch (Exception ex) {
            String enhancedMessage = 'Unexpected error posting to Chatter: ' + ex.getMessage();

            throw new ValidationException(enhancedMessage, null);
        }
    }

    public class ChatterResult {
        public String feedElementId;
        public String message;
        public Integer messageLength;
        public Integer topicCount;
        public Map<String, Object> metadata;

        public ChatterResult(String feedElementId, String message, Integer messageLength, Integer topicCount) {
            this.feedElementId = feedElementId;
            this.message = message;
            this.messageLength = messageLength;
            this.topicCount = topicCount;
            this.metadata = new Map<String, Object>{
                'feedElementId' => feedElementId,
                'messageLength' => messageLength,
                'topicCount' => topicCount,
                'postSuccessful' => true
            };
        }
    }
}
