/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Standard Action: Posts a message to a specified Chatter feed.
 *              Extends BaseAgentAction for standardized execution flow and error handling.
 *              Uses ConnectApi, supporting posts to Records, Users, or Groups.
 * @extends BaseAgentAction
 */
public class ActionPostChatter extends BaseAgentAction {
    private static final String ARG_FEED_TYPE = 'feedType';
    private static final String ARG_TARGET_ID = 'targetId';
    private static final String ARG_TEXT = 'text';
    private static final String ARG_TOPICS = 'topics';

    private static final String FEED_TYPE_RECORD = 'Record';
    private static final String FEED_TYPE_USER = 'User';
    private static final String FEED_TYPE_GROUP = 'Group';
    private static final Set<String> VALID_FEED_TYPES = new Set<String>{
        FEED_TYPE_RECORD,
        FEED_TYPE_USER,
        FEED_TYPE_GROUP
    };

    private static final String ERR_CODE_INPUT = AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
    private static final String ERR_CODE_INVALID_TARGET = 'INVALID_TARGET_ID';
    private static final String ERR_CODE_TARGET_INACCESSIBLE = AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
    private static final String ERR_CODE_CONNECT_API = AIAgentConstants.ERR_CODE_CONNECT_API_ERROR;
    private static final String ERR_CODE_UNEXPECTED = AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;

    /**
     * @description Provides a specific log prefix for this action type.
     * @return String 'ActionPostChatter'
     */
    protected override String getLogPrefixName() {
        return 'ActionPostChatter';
    }

    /**
     * @description Parses ActionConfiguration. PostChatter generally doesn't need config.
     * @param actionConfigurationJson The raw JSON string.
     * @param logPrefix Logging prefix.
     * @throws ValidationException if JSON is provided but invalid.
     */
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

    /**
     * @description Defines the structure for arguments specific to PostChatter.
     */
    class PostChatterParsedArguments extends BaseAgentAction.ParsedArguments {
        String feedType;
        Id targetSObjectId;
        String text;
        List<String> topics;
        String targetSObjectName;

        /**
         * @description Constructor that parses and validates JSON arguments
         * @param jsonArguments JSON string with arguments
         * @throws ValidationException If arguments are invalid
         */
        public PostChatterParsedArguments(String jsonArguments) {
            if (String.isBlank(jsonArguments)) {
                throw new ValidationException('Input arguments JSON cannot be blank.', null);
            }

            Map<String, Object> parsedArgs = (Map<String, Object>) JSON.deserializeUntyped(jsonArguments);

            this.feedType = ActionParamUtils.getRequiredString(parsedArgs, ARG_FEED_TYPE);
            if (!VALID_FEED_TYPES.contains(this.feedType)) {
                throw new ValidationException(
                    'Invalid value for parameter "' +
                        ARG_FEED_TYPE +
                        '". Must be one of: ' +
                        String.join(new List<String>(VALID_FEED_TYPES), ', '),
                    ARG_FEED_TYPE
                );
            }

            this.targetSObjectId = ActionParamUtils.getRequiredId(parsedArgs, ARG_TARGET_ID, null);
            this.targetSObjectName = determineSObjectTypeAndValidate(this.feedType, this.targetSObjectId);

            this.text = ActionParamUtils.getRequiredString(parsedArgs, ARG_TEXT);

            this.topics = ActionParamUtils.getOptionalStringList(parsedArgs, ARG_TOPICS);
        }

        /** Determine SObject API Name based on FeedType and validate ID matches */

        private String determineSObjectTypeAndValidate(String feedTypeParam, Id targetIdParam) {
            Schema.SObjectType idType = targetIdParam.getSObjectType();
            if (feedTypeParam == FEED_TYPE_USER) {
                if (idType == User.SObjectType)
                    return 'User';
                else
                    throw new ValidationException(
                        'Target ID ' + targetIdParam + ' is not a User ID, but feedType was "User".',
                        ARG_TARGET_ID
                    );
            } else if (feedTypeParam == FEED_TYPE_GROUP) {
                if (idType == CollaborationGroup.SObjectType)
                    return 'CollaborationGroup';
                else
                    throw new ValidationException(
                        'Target ID ' + targetIdParam + ' is not a CollaborationGroup ID, but feedType was "Group".',
                        ARG_TARGET_ID
                    );
            } else if (feedTypeParam == FEED_TYPE_RECORD) {
                if (idType == User.SObjectType || idType == CollaborationGroup.SObjectType) {
                    throw new ValidationException(
                        'Target ID ' +
                            targetIdParam +
                            ' is a User/Group ID, but feedType was "Record". Use feedType "User" or "Group" instead.',
                        ARG_TARGET_ID
                    );
                }
                return idType.getDescribe().getName();
            }
            throw new ValidationException('Internal Error: Invalid feedType: ' + feedTypeParam, ARG_FEED_TYPE);
        }
    }

    /**
     * @description Parses and validates the LLM arguments specific to PostChatter.
     * @param argumentsJson Raw JSON string from the LLM.
     * @param logPrefix Logging prefix.
     * @return PostChatterParsedArguments instance.
     * @throws ValidationException If arguments are invalid.
     */
    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(
        String argumentsJson,
        String logPrefix
    ) {
        try {
            return new PostChatterParsedArguments(argumentsJson);
        } catch (ActionParamUtils.ArgumentValidationException ave) {
            throw new ValidationException(ave.getMessage(), null);
        } catch (ValidationException ve) {
            throw ve;
        } catch (Exception e) {
            throw new ValidationException('Failed to parse/validate PostChatter arguments: ' + e.getMessage(), null);
        }
    }

    /**
     * @description Core logic: Verifies access, builds ConnectApi request, posts to feed.
     * @param validatedArgs Parsed arguments (must be cast).
     * @param logPrefix Logging prefix.
     * @return ActionResult Result of the post operation.
     * @throws ConnectApiException if the API call fails (will be mapped by base).
     * @throws QueryException if the access pre-check fails (will be mapped by base).
     * @throws ActionSecurityException for custom permission denied checks.
     */
    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        PostChatterParsedArguments args = (PostChatterParsedArguments) validatedArgs;

        try {
            String query = 'SELECT Id FROM ' + args.targetSObjectName + ' WHERE Id = :targetSObjectId LIMIT 1';
            Map<String, Object> bindMap = new Map<String, Object>{ 'targetSObjectId' => args.targetSObjectId };

            List<SObject> targetCheck = Database.queryWithBinds(query, bindMap, AccessLevel.USER_MODE);

            if (targetCheck.isEmpty()) {
                throw new ActionSecurityException(
                    'Target ' +
                        args.feedType +
                        ' with ID ' +
                        args.targetSObjectId +
                        ' not found or user lacks READ access.'
                );
            }
        } catch (System.QueryException qe) {
            throw qe;
        }

        ConnectApi.FeedItemInput feedItemInput = new ConnectApi.FeedItemInput();
        try {
            ConnectApi.MessageBodyInput messageBodyInput = new ConnectApi.MessageBodyInput();
            ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
            textSegment.text = args.text;
            messageBodyInput.messageSegments = new List<ConnectApi.MessageSegmentInput>{ textSegment };
            feedItemInput.body = messageBodyInput;
            feedItemInput.subjectId = args.targetSObjectId;

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
        } catch (Exception prepEx) {
            throw prepEx;
        }

        ConnectApi.FeedElement feedElement = ConnectApi.ChatterFeeds.postFeedElement(
            Network.getNetworkId(),
            feedItemInput
        );

        String successMsg = 'Posted to Chatter feed (' + args.feedType + ') successfully.';
        Map<String, Object> outputMap = new Map<String, Object>{
            'isSuccess' => true,
            'message' => successMsg,
            'feedElementId' => feedElement.id
        };

        return this.success(outputMap, 'Chatter post created. ID: ' + feedElement.id);
    }
}
