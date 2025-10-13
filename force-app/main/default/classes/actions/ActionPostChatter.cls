/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionPostChatter is a robust Apex action for posting messages to Chatter feeds with comprehensive validation, topic support, and security enforcement.
 *
 * Responsibilities:
 *   - Validates feed type, target access, and message content before posting.
 *   - Handles text length limits, topic processing, and integrates with ConnectApi for Chatter functionality.
 *   - Returns structured, LLM-friendly result data and meaningful error messages for downstream use.
 *
 * Scope:
 *   - Strictly focused on secure, flexible Chatter posting for any supported feed type and target.
 *   - Designed for maintainability, extensibility, and clarity, with detailed debug output and robust error handling.
 *
 * @extends BaseAgentAction
 */
public class ActionPostChatter extends BaseAgentAction {
    private static final String CONFIG_FEED_TYPE = 'feedType';
    private static final String CONFIG_TARGET_ID = 'targetId';

    private String feedType;
    private Id targetSObjectId;
    private String targetSObjectName;

    /**
     * @description
     * Main entry point for Chatter posting. Validates parameters, enforces security, creates the Chatter post, and processes topics.
     *
     * @param params Map<String, Object> - Must include 'text' (String), may include 'topics' (List<String>).
     * @return Result<ChatterResult> - Contains post confirmation and metadata or error information.
     *
     * Side effects: Logs key steps, errors, and performance metrics for troubleshooting and monitoring.
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Framework automatically validates required text parameter
        String text = (String) params.get('text');
        List<String> topics = (List<String>) params.get('topics');

        if (String.isBlank(text)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Text parameter cannot be blank for Chatter post');
        }

        ActionOutcome targetValidationResult = validateChatterTargetAccess();
        if (!targetValidationResult.isSuccess) {
            return targetValidationResult;
        }

        System.debug(LoggingLevel.INFO, '[ActionPostChatter] Posting to ' + this.feedType + ' feed. Target ID: ' + this.targetSObjectId);
        System.debug(
            LoggingLevel.DEBUG,
            '[ActionPostChatter] Message length: ' + text.length() + ' characters. Topics: ' + (topics != null ? topics.size() : 0)
        );

        ActionOutcome chatterResult = createChatterPost(text, topics);
        if (!chatterResult.isSuccess) {
            return chatterResult;
        }
        ConnectApi.FeedElement feedElement = (ConnectApi.FeedElement) chatterResult.data;

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(LoggingLevel.INFO, '[ActionPostChatter] Chatter post completed in ' + executionTime + ' ms.');

        return ActionOutcome.success(
            new ChatterResult(
                feedElement.id,
                'I have successfully posted the message to the ' + this.feedType + ' feed.',
                text.length(),
                topics != null ? topics.size() : 0
            )
        );
    }

    /**
     * @description
     * Parses and validates the action configuration JSON. Extracts feed type and target, and checks for consistency.
     *
     * @param actionConfigurationJson String - The JSON configuration string.
     * @param logPrefix String - Prefix for log output.
     * @throws ValidationException if required configuration is missing or invalid.
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);

        if (this.parsedActionConfig == null || this.parsedActionConfig.isEmpty()) {
            throw new ValidationException('BackendConfiguration is required for ActionPostChatter.', null);
        }

        this.feedType = ActionConfigUtils.getRequiredString(this.parsedActionConfig, CONFIG_FEED_TYPE);
        this.targetSObjectId = ActionConfigUtils.getRequiredId(this.parsedActionConfig, CONFIG_TARGET_ID, null);
        this.targetSObjectName = this.targetSObjectId.getSObjectType().getDescribe().getName();

        validateFeedTypeConsistency();

        System.debug(
            LoggingLevel.DEBUG,
            '[ActionPostChatter] Configuration parsed. FeedType: ' + this.feedType + ', Target: ' + this.targetSObjectId
        );
    }

    /**
     * @description
     * Validates that feed type matches the target object type for consistency.
     * Prevents mismatched configurations like User feed with Group target.
     *
     * @throws ValidationException if feed type and target object type are inconsistent.
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
     * @description
     * Validates that the user has access to the Chatter target before attempting to post.
     * Performs a security check to ensure the target exists and is accessible.
     *
     * @return ActionOutcome indicating success or failure with access violation details.
     */
    private ActionOutcome validateChatterTargetAccess() {
        try {
            String query = 'SELECT Id FROM ' + this.targetSObjectName + ' WHERE Id = :targetId LIMIT 1';
            List<SObject> targetCheck = Database.queryWithBinds(
                query,
                new Map<String, Object>{ 'targetId' => this.targetSObjectId },
                AccessLevel.USER_MODE
            );
            if (targetCheck.isEmpty()) {
                System.debug(
                    LoggingLevel.ERROR,
                    '[ActionPostChatter] Target ' + this.feedType + ' with ID ' + this.targetSObjectId + ' not found or user lacks access.'
                );
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                    'Target ' + this.feedType + ' with ID ' + this.targetSObjectId + ' not found or user lacks access.'
                );
            }
            return ActionOutcome.success();
        } catch (System.QueryException qe) {
            String enhancedMessage = 'Failed to validate access to Chatter target: ' + qe.getMessage();
            System.debug(LoggingLevel.ERROR, '[ActionPostChatter] ' + enhancedMessage);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, enhancedMessage);
        }
    }

    /**
     * @description
     * Parses text for mention syntax {@UserId} or {@005xxx} and builds message segments.
     * Supports mentioning users and groups with the syntax: {@UserId} or {@GroupId}.
     *
     * @param text The text containing potential mentions
     * @return List of message segments with text and mention segments
     */
    private List<ConnectApi.MessageSegmentInput> parseMentions(String text) {
        List<ConnectApi.MessageSegmentInput> segments = new List<ConnectApi.MessageSegmentInput>();

        if (String.isBlank(text)) {
            return segments;
        }

        // Pattern to match {@...} where ... is a 15 or 18 character Salesforce ID or user reference
        Pattern mentionPattern = Pattern.compile('\\{@([^}]+)\\}');
        Matcher matcher = mentionPattern.matcher(text);

        Integer lastEnd = 0;
        Set<Id> validatedIds = new Set<Id>();

        while (matcher.find()) {
            // Add text before the mention
            if (matcher.start() > lastEnd) {
                String textBefore = text.substring(lastEnd, matcher.start());
                if (String.isNotBlank(textBefore)) {
                    ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
                    textSegment.text = textBefore;
                    segments.add(textSegment);
                }
            }

            String mentionValue = matcher.group(1);
            Id mentionId = null;

            // Try to parse as ID
            try {
                mentionId = Id.valueOf(mentionValue);

                // Validate the ID is for a User or CollaborationGroup
                Schema.SObjectType sObjType = mentionId.getSObjectType();
                if (sObjType == Schema.User.SObjectType || sObjType == Schema.CollaborationGroup.SObjectType) {
                    // Validate user/group exists and is accessible
                    if (!validatedIds.contains(mentionId) && validateMentionTarget(mentionId, sObjType)) {
                        validatedIds.add(mentionId);
                    }

                    if (validatedIds.contains(mentionId)) {
                        // Add mention segment
                        ConnectApi.MentionSegmentInput mentionSegment = new ConnectApi.MentionSegmentInput();
                        mentionSegment.id = mentionId;
                        segments.add(mentionSegment);
                    } else {
                        // Invalid or inaccessible mention, add as plain text
                        ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
                        textSegment.text = '{@' + mentionValue + '}';
                        segments.add(textSegment);
                    }
                } else {
                    // Not a User or Group, add as plain text
                    System.debug(LoggingLevel.WARN, '[ActionPostChatter] Mention target is not a User or Group: ' + mentionId);
                    ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
                    textSegment.text = '{@' + mentionValue + '}';
                    segments.add(textSegment);
                }
            } catch (Exception e) {
                // Not a valid ID, add as plain text
                System.debug(LoggingLevel.DEBUG, '[ActionPostChatter] Invalid mention ID format: ' + mentionValue);
                ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
                textSegment.text = '{@' + mentionValue + '}';
                segments.add(textSegment);
            }

            lastEnd = matcher.end();
        }

        // Add remaining text after last mention
        if (lastEnd < text.length()) {
            String remainingText = text.substring(lastEnd);
            if (String.isNotBlank(remainingText)) {
                ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
                textSegment.text = remainingText;
                segments.add(textSegment);
            }
        }

        // If no mentions were found, return simple text segment
        if (segments.isEmpty()) {
            ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
            textSegment.text = text;
            segments.add(textSegment);
        }

        return segments;
    }

    /**
     * @description
     * Validates that the mentioned user or group exists and is accessible.
     *
     * @param mentionId The ID of the user or group to mention
     * @param sObjType  The SObject type (User or CollaborationGroup)
     * @return True if the mention target is valid and accessible
     */
    private Boolean validateMentionTarget(Id mentionId, Schema.SObjectType sObjType) {
        try {
            String objectName = sObjType.getDescribe().getName();
            String query = 'SELECT Id FROM ' + objectName + ' WHERE Id = :mentionId WITH USER_MODE LIMIT 1';
            List<SObject> results = Database.query(query);

            if (results.isEmpty()) {
                System.debug(LoggingLevel.WARN, '[ActionPostChatter] Mention target not found or not accessible: ' + mentionId);
                return false;
            }

            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionPostChatter] Error validating mention target ' + mentionId + ': ' + e.getMessage());
            return false;
        }
    }

    /**
     * @description
     * Creates and posts a Chatter message with text validation, topic processing, and mention support.
     *
     * @param text String - Message text to post (can include {@UserId} mention syntax).
     * @param topics List<String> - Optional list of topics to associate with the post.
     * @return ActionOutcome<ConnectApi.FeedElement> - The posted message or error information.
     */
    private ActionOutcome createChatterPost(String text, List<String> topics) {
        try {
            if (text.length() > 10000) {
                System.debug(LoggingLevel.WARN, '[ActionPostChatter] Message text exceeded 10000 characters. Truncating.');
                text = text.substring(0, 10000) + '... [truncated]';
            }

            // Create feed item input
            ConnectApi.FeedItemInput feedItemInput = new ConnectApi.FeedItemInput();
            ConnectApi.MessageBodyInput messageBodyInput = new ConnectApi.MessageBodyInput();

            // Parse text for mentions and build appropriate message segments
            List<ConnectApi.MessageSegmentInput> messageSegments = parseMentions(text);
            messageBodyInput.messageSegments = messageSegments;

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
                            System.debug(LoggingLevel.WARN, '[ActionPostChatter] Topic too long (skipped): ' + cleanTopic);
                        }
                    }
                }

                if (!topicsCapabilityInput.topics.isEmpty()) {
                    capabilitiesInput.topics = topicsCapabilityInput;
                    feedItemInput.capabilities = capabilitiesInput;
                }
            }

            return ActionOutcome.success(ConnectApi.ChatterFeeds.postFeedElement(Network.getNetworkId(), feedItemInput));
        } catch (ConnectApi.ConnectApiException cae) {
            String enhancedMessage = 'Chatter post failed: ' + cae.getMessage();
            System.debug(LoggingLevel.ERROR, '[ActionPostChatter] Chatter post failed: ' + enhancedMessage);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, enhancedMessage);
        } catch (Exception ex) {
            String enhancedMessage = 'Unexpected error posting to Chatter: ' + ex.getMessage();
            System.debug(LoggingLevel.ERROR, '[ActionPostChatter] Unexpected error: ' + enhancedMessage);
            System.debug(LoggingLevel.DEBUG, '[ActionPostChatter] Exception stack trace: ' + ex.getStackTraceString());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, enhancedMessage);
        }
    }

    /**
     * @description
     * Result wrapper for successful Chatter post operations. Provides structured data for both user display and LLM processing.
     *
     * Fields:
     *   - feedElementId: String - The ID of the posted Chatter feed element.
     *   - message: String - User-facing message summarizing the result.
     *   - messageLength: Integer - Length of the posted message.
     *   - topicCount: Integer - Number of topics associated with the post.
     *   - metadata: Map<String, Object> - Additional context for downstream consumers.
     */
    public class ChatterResult {
        public String feedElementId;
        public String message; // Framework uses this for user display
        public Integer messageLength;
        public Integer topicCount;
        public Map<String, Object> metadata; // Additional context for LLMs

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
