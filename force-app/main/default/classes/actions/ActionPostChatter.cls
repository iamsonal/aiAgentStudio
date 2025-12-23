/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionPostChatter is a high-performance Apex action for posting messages to Chatter feeds using strongly-typed DTOs.
 *
 * Responsibilities:
 *   - Uses DTOs for type-safe argument and configuration handling
 *   - Validates feed type, target access, and message content before posting
 *   - Handles text length limits, topic processing, and integrates with ConnectApi for Chatter functionality
 *   - Returns structured, LLM-friendly result data and meaningful error messages for downstream use
 *
 * Architecture:
 *   - ArgumentsDTO: Strongly-typed with text and topics
 *   - ConfigDTO: Strongly-typed configuration with feedType and targetId
 *   - Uses native JSON.deserialize() for high-performance type conversion
 *
 * @ActionLabel Post Chatter
 * @ActionDescription Posts a message to a Chatter feed with support for mentions and topics
 * @ActionRequiresSObject false
 * @ActionIsActive true
 * @ActionGuidance
 * <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif; line-height: 1.6;"><div style="background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%); color: white; padding: 16px; border-radius: 8px 8px 0 0; margin: -8px -8px 16px -8px;"><h2 style="margin: 0; font-size: 18px; font-weight: 600;">💬 Post to Chatter</h2><p style="margin: 4px 0 0 0; font-size: 13px; opacity: 0.95;">Post messages to Chatter feeds (record, user, or group)</p></div><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">⚙️ Configuration Options</h3><div style="background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin: 12px 0;"><table style="width: 100%; font-size: 13px;"><tr><td style="padding: 8px; border-bottom: 1px solid #e9ecef; width: 30%;"><strong style="color: #495057;">Default Target ID</strong><br/><span style="font-size: 11px; color: #6c757d;">Optional</span></td><td style="padding: 8px; border-bottom: 1px solid #e9ecef; color: #6c757d;">Default Salesforce ID for the feed target (record, user, or group). Can be overridden at runtime.<br/><code style="background: #f1f3f5; padding: 2px 6px; border-radius: 3px; font-size: 11px;">"005..." (User) or "001..." (Record) or "0F9..." (Group)</code></td></tr><tr><td style="padding: 8px;"><strong style="color: #495057;">Message Template</strong><br/><span style="font-size: 11px; color: #6c757d;">Optional</span></td><td style="padding: 8px; color: #6c757d;">Optional message template with placeholders for AI to fill in. Leave blank to let AI compose freely.</td></tr></table></div><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">📋 Runtime Parameters</h3><p style="margin: 8px 0; font-size: 13px; color: #6c757d;">The AI will provide these parameters when calling this action:</p><div style="background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin: 12px 0;"><table style="width: 100%; font-size: 13px;"><tr><td style="padding: 8px; border-bottom: 1px solid #e9ecef; width: 30%;"><strong style="color: #495057;">targetId</strong><br/><span style="font-size: 11px; color: #dc3545;">Required*</span></td><td style="padding: 8px; border-bottom: 1px solid #e9ecef; color: #6c757d;">18-character Salesforce ID of the target feed. Can be a record ID, user ID (005), or group ID (0F9).<br/><span style="font-size: 11px; font-style: italic;">*Not required if Default Target ID is configured</span></td></tr><tr><td style="padding: 8px;"><strong style="color: #495057;">message</strong><br/><span style="font-size: 11px; color: #dc3545;">Required</span></td><td style="padding: 8px; color: #6c757d;">Message text (max 10,000 characters). Can include @mentions and #topics.<br/><code style="background: #f1f3f5; padding: 2px 6px; border-radius: 3px; font-size: 11px;">"Case escalated {@005xxx} please review"</code></td></tr></table></div><h3 style="font-size: 15px; color: #212529; margin: 16px 0 8px 0; border-bottom: 2px solid #e9ecef; padding-bottom: 4px;">✨ Message Formatting</h3><div style="background: white; border: 1px solid #dee2e6; border-radius: 6px; padding: 12px; margin: 12px 0;"><table style="width: 100%; font-size: 13px;"><tr><td style="padding: 8px; border-bottom: 1px solid #e9ecef; width: 30%;"><strong style="color: #495057;">@Mentions</strong></td><td style="padding: 8px; border-bottom: 1px solid #e9ecef; color: #6c757d;">Use <code style="background: #f1f3f5; padding: 2px 6px; border-radius: 3px; font-size: 11px;">{@005xxxxxxxxxxxxxxx}</code> to mention users or groups. The mentioned user will be notified.</td></tr><tr><td style="padding: 8px; border-bottom: 1px solid #e9ecef;"><strong style="color: #495057;">#Topics</strong></td><td style="padding: 8px; border-bottom: 1px solid #e9ecef; color: #6c757d;">Add hashtags (max 25 characters each) for categorization: <code style="background: #f1f3f5; padding: 2px 6px; border-radius: 3px; font-size: 11px;">#Escalation #Urgent</code></td></tr><tr><td style="padding: 8px;"><strong style="color: #495057;">URLs</strong></td><td style="padding: 8px; color: #6c757d;">URLs are automatically converted to clickable links in the Chatter post.</td></tr></table></div></div>
 *
 * @extends BaseAgentAction
 */
public class ActionPostChatter extends BaseAgentAction {
    // Feed type constants - SINGLE SOURCE OF TRUTH
    private static final String FEED_TYPE_USER = 'User';
    private static final String FEED_TYPE_GROUP = 'Group';
    private static final String FEED_TYPE_RECORD = 'Record';

    private ConfigDTO config;
    private Id targetSObjectId;
    private String targetSObjectName;

    /**
     * DTO for strongly-typed arguments (AI-provided parameters at runtime)
     */
    public class ArgumentsDTO {
        /**
         * @FieldLabel Message Text
         * @FieldType string
         * @FieldRequired true
         * @FieldMaxLength 10000
         * @FieldHelp The text content of the Chatter post (max 10,000 characters). Use {@UserId} syntax for mentions.
         */
        public String messageText;

        /**
         * @FieldLabel Topics
         * @FieldType array
         * @FieldHelp Optional list of topics/hashtags to associate with the post
         */
        public List<String> topics;
    }

    /**
     * DTO for strongly-typed backend configuration (admin-configured)
     */
    public class ConfigDTO {
        /**
         * @FieldLabel Feed Type
         * @FieldType string
         * @FieldRequired true
         * @FieldPicklistValues User,Group,Record
         * @FieldHelp Type of Chatter feed: User, Group, or Record
         */
        public String feedType;

        /**
         * @FieldLabel Target ID
         * @FieldType salesforce-id
         * @FieldRequired true
         * @FieldPlaceholder 005000000000000AAA
         * @FieldHelp Salesforce ID of the User, Group, or Record to post to
         */
        public String targetId;
    }

    /**
     * @description
     * Main entry point for Chatter posting using strongly-typed DTOs.
     * Validates parameters, enforces security, creates the Chatter post, and processes topics.
     *
     * @param params Map<String, Object> - Raw parameters (deserialized into ArgumentsDTO for type safety)
     * @return ActionOutcome<ChatterResult> - Contains post confirmation and metadata or error information
     *
     * Side effects: Logs key steps, errors, and performance metrics for troubleshooting and monitoring
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();
        args.messageText = (String) params.get('messageText');
        args.topics = ActionConfigUtils.getOptionalStringList(params, 'topics');

        // Validate required DTO parameters
        if (String.isBlank(args.messageText)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'messageText parameter cannot be blank for Chatter post');
        }

        ActionOutcome targetValidationResult = validateChatterTargetAccess();
        if (!targetValidationResult.isSuccess) {
            return targetValidationResult;
        }

        System.debug(LoggingLevel.INFO, '[ActionPostChatter] Posting to ' + config.feedType + ' feed. Target ID: ' + targetSObjectId);
        System.debug(LoggingLevel.DEBUG, '[ActionPostChatter] Message length: ' + args.messageText.length() + ' characters. Topics: ' + args.topics.size());

        ActionOutcome chatterResult = createChatterPost(args.messageText, args.topics);
        if (!chatterResult.isSuccess) {
            return chatterResult;
        }
        ConnectApi.FeedElement feedElement = (ConnectApi.FeedElement) chatterResult.data;

        Long executionTime = System.currentTimeMillis() - startTime;
        System.debug(LoggingLevel.INFO, '[ActionPostChatter] Chatter post completed in ' + executionTime + ' ms.');

        return ActionOutcome.success(
            new ChatterResult(
                feedElement.id,
                'I have successfully posted the message to the ' + config.feedType + ' feed.',
                args.messageText.length(),
                args.topics.size()
            )
        );
    }

    /**
     * @description
     * Parses and validates the action configuration JSON using strongly-typed ConfigDTO.
     * Extracts feed type and target, and checks for consistency.
     *
     * @param actionConfigurationJson String - The JSON configuration string
     * @param logPrefix String - Prefix for log output
     * @throws ValidationException if required configuration is missing or invalid
     */
    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        // Parse config using hybrid approach for consistency
        try {
            if (String.isBlank(actionConfigurationJson)) {
                throw new ValidationException('Configuration JSON is required', null);
            }

            // First deserialize as untyped map
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

            // Then manually populate ConfigDTO
            this.config = new ConfigDTO();
            this.config.feedType = (String) configMap.get('feedType');
            this.config.targetId = (String) configMap.get('targetId');
        } catch (Exception e) {
            throw new ValidationException('Invalid configuration JSON: ' + e.getMessage(), e);
        }

        // Validate required fields
        if (String.isBlank(config.feedType)) {
            throw new ValidationException('feedType is required in configuration', 'feedType');
        }
        if (String.isBlank(config.targetId)) {
            throw new ValidationException('targetId is required in configuration', 'targetId');
        }

        // Convert targetId to Id type
        try {
            this.targetSObjectId = Id.valueOf(config.targetId);
            this.targetSObjectName = this.targetSObjectId.getSObjectType().getDescribe().getName();
        } catch (Exception e) {
            throw new ValidationException('Invalid targetId format: ' + config.targetId, 'targetId', e);
        }

        validateFeedTypeConsistency();

        System.debug(LoggingLevel.DEBUG, '[ActionPostChatter] Configuration parsed. FeedType: ' + config.feedType + ', Target: ' + targetSObjectId);
    }

    /**
     * @description
     * Validates that feed type matches the target object type for consistency.
     * Prevents mismatched configurations like User feed with Group target.
     *
     * @throws ValidationException if feed type and target object type are inconsistent
     */
    private void validateFeedTypeConsistency() {
        if (
            (config.feedType == FEED_TYPE_USER &&
            targetSObjectName != 'User') ||
            (config.feedType == FEED_TYPE_GROUP &&
            targetSObjectName != 'CollaborationGroup') ||
            (config.feedType == FEED_TYPE_RECORD && (targetSObjectName == 'User' || targetSObjectName == 'CollaborationGroup'))
        ) {
            throw new ValidationException(
                'Mismatch between feedType "' + config.feedType + '" and targetId object type "' + targetSObjectName + '".',
                'feedType'
            );
        }
    }

    /**
     * @description
     * Validates that the user has access to the Chatter target before attempting to post.
     * Performs a security check to ensure the target exists and is accessible.
     *
     * @return ActionOutcome indicating success or failure with access violation details
     */
    private ActionOutcome validateChatterTargetAccess() {
        try {
            String query = 'SELECT Id FROM ' + targetSObjectName + ' WHERE Id = :targetId LIMIT 1';
            List<SObject> targetCheck = Database.queryWithBinds(query, new Map<String, Object>{ 'targetId' => targetSObjectId }, AccessLevel.USER_MODE);
            if (targetCheck.isEmpty()) {
                System.debug(
                    LoggingLevel.ERROR,
                    '[ActionPostChatter] Target ' + config.feedType + ' with ID ' + targetSObjectId + ' not found or user lacks access.'
                );
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                    'Target ' + config.feedType + ' with ID ' + targetSObjectId + ' not found or user lacks access.'
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
     * @param messageText String - Message text to post (can include {@UserId} mention syntax).
     * @param topics List<String> - Optional list of topics to associate with the post.
     * @return ActionOutcome<ConnectApi.FeedElement> - The posted message or error information.
     */
    private ActionOutcome createChatterPost(String messageText, List<String> topics) {
        try {
            if (messageText.length() > 10000) {
                System.debug(LoggingLevel.WARN, '[ActionPostChatter] Message text exceeded 10000 characters. Truncating.');
                messageText = messageText.substring(0, 10000) + '... [truncated]';
            }

            // Create feed item input
            ConnectApi.FeedItemInput feedItemInput = new ConnectApi.FeedItemInput();
            ConnectApi.MessageBodyInput messageBodyInput = new ConnectApi.MessageBodyInput();

            // Parse messageText for mentions and build appropriate message segments
            List<ConnectApi.MessageSegmentInput> messageSegments = parseMentions(messageText);
            messageBodyInput.messageSegments = messageSegments;

            feedItemInput.body = messageBodyInput;
            feedItemInput.subjectId = targetSObjectId;

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

    /**
     * @description
     * Returns all supported feed types for this action.
     * Single source of truth for feed type names.
     */
    private static List<String> getAllFeedTypes() {
        return new List<String>{ FEED_TYPE_USER, FEED_TYPE_GROUP, FEED_TYPE_RECORD };
    }
}
