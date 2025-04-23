/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Common utility methods for the AI Agent Framework.
 */
public inherited sharing class FrameworkUtils {
    @TestVisible
    private static Map<String, List<String>> fieldSetCache = new Map<String, List<String>>();

    public static final String ERR_CODE_INPUT_VALIDATION_TYPE = 'INPUT_TYPE_INVALID';

    /**
     * @description Generates a Version 4 UUID.
     * @return String representing the UUID.
     */
    public static String generateUUID() {
        Blob b = Crypto.generateAesKey(128);
        String h = EncodingUtil.convertToHex(b);

        Integer variantValue = Math.mod(Math.abs(h.substring(16, 20).hashCode()), 4) + 8;
        String variantHex = variantValue.toString();

        String[] hexMap = new List<String>{ '8', '9', 'A', 'B' };
        variantHex = hexMap[variantValue - 8];

        return h.substring(0, 8) +
            '-' +
            h.substring(8, 12) +
            '-4' +
            h.substring(13, 16) +
            '-' +
            variantHex +
            h.substring(17, 20) +
            '-' +
            h.substring(20);
    }

    /**
     * @description Retrieves field paths from a FieldSet, using transaction cache.
     * @param sObjectType The SObject type.
     * @param fieldSetName The API name of the FieldSet.
     * @return List of field paths (e.g., 'Name', 'Account.Industry'), or null if FS not found.
     */
    public static List<String> getFieldsFromFieldSet(SObjectType sObjectType, String fieldSetName) {
        if (sObjectType == null || String.isBlank(fieldSetName)) {
            return null;
        }

        String cacheKey = sObjectType.getDescribe().getName() + ':' + fieldSetName;
        if (fieldSetCache.containsKey(cacheKey)) {
            return fieldSetCache.get(cacheKey);
        }

        List<String> fieldPaths = null;
        try {
            DescribeSObjectResult describeResult = sObjectType.getDescribe(SObjectDescribeOptions.DEFERRED);
            Map<String, FieldSet> fieldSetMap = describeResult.fieldSets.getMap();

            if (fieldSetMap.containsKey(fieldSetName)) {
                fieldPaths = new List<String>();
                for (FieldSetMember fsm : fieldSetMap.get(fieldSetName).getFields()) {
                    fieldPaths.add(fsm.getFieldPath());
                }
            } else {
            }
        } catch (Exception e) {
        }

        fieldSetCache.put(cacheKey, fieldPaths);
        return fieldPaths;
    }

    /**
     * @description Builds a SOQL query string to select specified fields for a given record ID.
     * @param sObjectType The SObject type.
     * @param fieldApiPaths List of field paths (e.g., 'Name', 'Account.Industry').
     * @param recordId The ID of the record to query.
     * @return The SOQL query string.
     * @throws IllegalArgumentException If any parameters are null or invalid.
     */
    public static String buildContextQuery(SObjectType sObjectType, List<String> fieldApiPaths, Id recordId) {
        if (sObjectType == null) {
            throw new IllegalArgumentException('SObjectType cannot be null for buildContextQuery.');
        }
        if (fieldApiPaths == null || fieldApiPaths.isEmpty()) {
            throw new IllegalArgumentException('fieldApiPaths cannot be null or empty for buildContextQuery.');
        }
        if (recordId == null) {
            throw new IllegalArgumentException('recordId cannot be null for buildContextQuery.');
        }

        if (recordId.getSObjectType() != sObjectType) {
            throw new IllegalArgumentException(
                'Record ID type mismatch: Expected ' +
                    sObjectType.getDescribe().getName() +
                    ' but got ' +
                    recordId.getSObjectType().getDescribe().getName()
            );
        }

        Set<String> fieldsToSelect = new Set<String>(fieldApiPaths);
        fieldsToSelect.add('Id');

        List<String> orderedFields = new List<String>(fieldsToSelect);
        orderedFields.sort();

        String joinedFields = String.join(orderedFields, ', ');
        String sObjectApiName = sObjectType.getDescribe().getName();

        String queryString = String.format(
            'SELECT {0} FROM {1} WHERE Id = :recordId LIMIT 1',
            new List<Object>{ joinedFields, sObjectApiName }
        );

        return queryString;
    }

    /**
     * @description Formats the accessible field data from a record into a string for the LLM.
     * @param record The SObject record (assumed FLS-checked).
     * @param requestedFields The original list of field paths requested (from FieldSet).
     * @return Formatted string (e.g., "Context (Account):..") or null if no accessible data.
     */
    public static String formatContextForLLM(SObject record, List<String> requestedFields) {
        if (record == null || requestedFields == null || requestedFields.isEmpty()) {
            return null;
        }

        List<String> formattedEntries = new List<String>();
        Set<String> processedPaths = new Set<String>();

        for (String fieldPath : requestedFields) {
            if (String.isBlank(fieldPath) || processedPaths.contains(fieldPath.toLowerCase()))
                continue;
            processedPaths.add(fieldPath.toLowerCase());

            Object value = getFieldValue(record, fieldPath);

            if (value != null && !(value instanceof String && String.isBlank((String) value))) {
                String formattedValue = String.valueOf(value);

                formattedEntries.add(fieldPath + ': ' + formattedValue);
            }
        }

        if (!formattedEntries.isEmpty()) {
            String sObjectName = record.getSObjectType().getDescribe().getName();
            return String.format(
                'Current Record Context ({0}):\n- {1}',
                new List<Object>{ sObjectName, String.join(formattedEntries, '\n- ') }
            );
        } else {
            return null;
        }
    }

    /**
     * @description Safely retrieves a field value, handling relationships and nulls.
     * @param currentRecord The record to start from.
     * @param fieldPath The full field path (e.g., 'Name', 'Account.Industry', 'Account.Owner.Name').
     * @return The field value (Object) or null if path is invalid, null encountered, or field inaccessible.
     */
    private static Object getFieldValue(SObject currentRecord, String fieldPath) {
        if (currentRecord == null || String.isBlank(fieldPath)) {
            return null;
        }

        List<String> parts = fieldPath.split('\\.');
        SObject tempRecord = currentRecord;
        Object result = null;

        try {
            for (Integer i = 0; i < parts.size(); i++) {
                String part = parts[i];
                if (tempRecord == null)
                    return null;

                if (i == parts.size() - 1) {
                    Map<String, Schema.SObjectField> fieldMap = tempRecord.getSObjectType()
                        .getDescribe()
                        .fields.getMap();
                    if (fieldMap.containsKey(part.toLowerCase())) {
                        Schema.DescribeFieldResult dfr = fieldMap.get(part.toLowerCase()).getDescribe();
                        if (dfr.isAccessible()) {
                            result = tempRecord.get(part);
                        } else {
                            result = null;
                        }
                    } else {
                        result = null;
                    }
                } else {
                    tempRecord = tempRecord.getSObject(part);
                }
            }
        } catch (Exception e) {
            result = null;
        }
        return result;
    }

    /**
     * @description Retrieves fields based on a FieldSet, queries the specified record,
     *              strips inaccessible fields, formats the accessible data with truncation,
     *              and returns it as a string suitable for LLM context.
     * @param recordId The ID of the record to query context from.
     * @param sobjType The SObjectType of the record.
     * @param fieldSetName The API name of the FieldSet to use for determining fields.
     * @param truncationLengthParam The maximum length for individual string field values in the output. Null or <= 0 uses DEFAULT_TRUNCATION_LENGTH.
     * @return Formatted string containing accessible record context, or null if no data/fieldset/record found or inaccessible.
     * @throws QueryException, other system exceptions.
     */
    public static String getAndFormatAccessibleContext(
        Id recordId,
        SObjectType sobjType,
        String fieldSetName,
        Integer truncationLengthParam
    ) {
        if (recordId == null || sobjType == null || String.isBlank(fieldSetName)) {
            return null;
        }

        List<String> fieldPaths = getFieldsFromFieldSet(sobjType, fieldSetName);

        if (fieldPaths == null) {
            return null;
        }
        if (fieldPaths.isEmpty()) {
            return null;
        }

        Set<String> fieldsToQuery = new Set<String>(fieldPaths);
        fieldsToQuery.add('Id');
        String queryString = buildContextQuery(sobjType, new List<String>(fieldsToQuery), recordId);
        List<SObject> records = Database.query(queryString);

        if (records.isEmpty()) {
            return null;
        }
        SObject record = records[0];

        SObjectAccessDecision decision = Security.stripInaccessible(AccessType.READABLE, new List<SObject>{ record });
        SObject accessibleRecord = decision.getRecords()[0];

        Integer maxLen;
        if (truncationLengthParam != null && truncationLengthParam > 0) {
            maxLen = truncationLengthParam;
        } else {
            maxLen = AIAgentFrameworkSettings.getDefaultContextTruncationLength();
        }
        List<String> formattedEntries = new List<String>();
        Set<String> processedPaths = new Set<String>();

        for (String fieldPath : fieldPaths) {
            if (String.isBlank(fieldPath) || processedPaths.contains(fieldPath.toLowerCase()))
                continue;
            processedPaths.add(fieldPath.toLowerCase());

            Object value = getFieldValue(accessibleRecord, fieldPath);

            if (value != null) {
                String stringValue;
                if (value instanceof String) {
                    stringValue = (String) value;
                    if (String.isNotBlank(stringValue)) {
                        if (stringValue.length() > maxLen) {
                            stringValue = stringValue.left(maxLen - 18) + '... [truncated]';
                        }
                        formattedEntries.add(fieldPath + ': ' + stringValue);
                    }
                } else {
                    stringValue = String.valueOf(value);

                    if (String.isNotBlank(stringValue) && stringValue != 'null') {
                        formattedEntries.add(fieldPath + ': ' + stringValue);
                    }
                }
            }
        }

        if (formattedEntries.isEmpty()) {
            return null;
        }

        String sObjectName = sobjType.getDescribe().getName();
        return String.format(
            'CONTEXT for related {0} record (ID: {1}):\n- {2}',
            new List<Object>{ sObjectName, recordId, String.join(formattedEntries, '\n- ') }
        );
    }

    /**
     * @description Constructs the message payload LIST formatted for LLM APIs (like OpenAI)
     *              from fetched history, agent config, and injected context.
     *              Handles roles (system, user, assistant, tool) and structure.
     * @param historySObjectsAsc List<ChatMessage__c> PRE-FETCHED & sorted ASC. Requires Id, Role__c, Content__c, AssistantToolCalls__c, ToolCallId__c fields.
     * @param agentConfig The AIAgentDefinition__c containing system prompt settings. Requires IncludeSystemPromptInHistory__c, SystemPrompt__c fields.
     * @param injectedContextString Optional pre-formatted context string to inject (usually as a system message).
     * @param loggingContext A string for prepending log messages (e.g., logPrefix from calling Queueable).
     * @return List<Map<String, Object>> The formatted message list ready for JSON serialization in the LLM API call body.
     * @throws FrameworkUtils.PayloadFormattingException for critical errors during formatting.
     */
    public static List<Map<String, Object>> formatLlmApiPayload(
        List<ChatMessage__c> historySObjectsAsc,
        AIAgentDefinition__c agentConfig,
        String injectedContextString,
        String loggingContext
    ) {
        String debugPrefix = String.isNotBlank(loggingContext) ? loggingContext : '[FrameworkUtils.PayloadUtil] ';

        if (agentConfig == null) {
            throw new PayloadFormattingException('Agent configuration cannot be null for payload formatting.');
        }

        List<Map<String, Object>> finalPayload = new List<Map<String, Object>>();
        Set<Id> processedToolMessageIds = new Set<Id>();

        Map<Id, List<String>> assistantToToolCallIdsMap = new Map<Id, List<String>>();
        Map<String, ChatMessage__c> toolCallIdToMessageMap = new Map<String, ChatMessage__c>();
        Set<Id> assistantMsgIdsWithToolCalls = new Set<Id>();

        if (historySObjectsAsc != null) {
            for (ChatMessage__c msg : historySObjectsAsc) {
                String role = msg.Role__c?.toLowerCase();

                if (role == 'assistant' && String.isNotBlank(msg.AssistantToolCalls__c)) {
                    List<String> requestedIds = parseToolCallIdsFromAssistantMessage(
                        msg.AssistantToolCalls__c,
                        msg.Id,
                        debugPrefix
                    );
                    if (!requestedIds.isEmpty()) {
                        assistantToToolCallIdsMap.put(msg.Id, requestedIds);
                        assistantMsgIdsWithToolCalls.add(msg.Id);
                    }
                } else if (role == 'tool' && String.isNotBlank(msg.ToolCallId__c)) {
                    if (toolCallIdToMessageMap.containsKey(msg.ToolCallId__c)) {
                    }
                    toolCallIdToMessageMap.put(msg.ToolCallId__c, msg);
                }
            }
        }

        if (agentConfig.IncludeSystemPromptInHistory__c == true && String.isNotBlank(agentConfig.SystemPrompt__c)) {
            addMessageMapToPayloadList(
                finalPayload,
                'system',
                agentConfig.SystemPrompt__c,
                null,
                null,
                debugPrefix,
                'Config System Prompt'
            );
        } else {
        }

        if (String.isNotBlank(injectedContextString)) {
            addMessageMapToPayloadList(
                finalPayload,
                'system',
                injectedContextString,
                null,
                null,
                debugPrefix,
                'Injected Context'
            );
        }

        if (historySObjectsAsc != null && !historySObjectsAsc.isEmpty()) {
            for (ChatMessage__c currentMsg : historySObjectsAsc) {
                if (currentMsg == null || String.isBlank(currentMsg.Role__c))
                    continue;

                String role = currentMsg.Role__c.toLowerCase();
                String msgKey = 'Msg ' + currentMsg.Id + ' (' + role + ')';

                if (role == 'tool' && processedToolMessageIds.contains(currentMsg.Id)) {
                    continue;
                }

                if (role == 'tool' && !processedToolMessageIds.contains(currentMsg.Id)) {
                    continue;
                }

                if (
                    role == 'user' ||
                    role == 'system' ||
                    (role == 'assistant' && !assistantMsgIdsWithToolCalls.contains(currentMsg.Id))
                ) {
                    addMessageMapToPayloadList(
                        finalPayload,
                        role,
                        currentMsg.Content__c,
                        null,
                        null,
                        debugPrefix,
                        msgKey
                    );
                } else if (role == 'assistant' && assistantMsgIdsWithToolCalls.contains(currentMsg.Id)) {
                    List<String> requestedToolCallIds = assistantToToolCallIdsMap.get(currentMsg.Id);

                    List<Object> parsedToolCallsForPayload = null;
                    try {
                        Object rawParsed = JSON.deserializeUntyped(currentMsg.AssistantToolCalls__c);
                        if (rawParsed instanceof List<Object>) {
                            parsedToolCallsForPayload = (List<Object>) rawParsed;
                        } else {
                            throw new JSONException('Tool calls field was not a List');
                        }
                    } catch (Exception pEx) {
                        throw new PayloadFormattingException(
                            'Corrupted AssistantToolCalls JSON detected for message ' + currentMsg.Id
                        );
                    }
                    addMessageMapToPayloadList(
                        finalPayload,
                        'assistant',
                        currentMsg.Content__c,
                        parsedToolCallsForPayload,
                        null,
                        debugPrefix,
                        msgKey
                    );

                    if (requestedToolCallIds != null && !requestedToolCallIds.isEmpty()) {
                        for (String toolCallId : requestedToolCallIds) {
                            ChatMessage__c toolResultMessage = toolCallIdToMessageMap.get(toolCallId);
                            if (toolResultMessage != null) {
                                String toolMsgKey =
                                    '  Tool Result Msg ' +
                                    toolResultMessage.Id +
                                    ' (for CallId ' +
                                    toolCallId +
                                    ')';

                                addMessageMapToPayloadList(
                                    finalPayload,
                                    'tool',
                                    toolResultMessage.Content__c,
                                    null,
                                    toolCallId,
                                    debugPrefix,
                                    toolMsgKey
                                );
                                processedToolMessageIds.add(toolResultMessage.Id);
                            } else {
                                String errMsg =
                                    debugPrefix +
                                    'Data Consistency Error: Tool result message not found for requested ToolCallId: ' +
                                    toolCallId +
                                    ' from Assistant Message ' +
                                    currentMsg.Id +
                                    '. Payload might be invalid.';

                                throw new PayloadFormattingException(
                                    'Missing required tool result message for ToolCallId: ' + toolCallId
                                );
                            }
                        }
                    }
                } else {
                }
            }
        }

        if (
            finalPayload.isEmpty() &&
            String.isBlank(injectedContextString) &&
            (agentConfig.IncludeSystemPromptInHistory__c != true || String.isBlank(agentConfig.SystemPrompt__c))
        ) {
        }

        return finalPayload;
    }

    /**
     * Helper method to parse tool call IDs from the AssistantToolCalls__c JSON field.
     */
    private static List<String> parseToolCallIdsFromAssistantMessage(
        String toolCallsJson,
        Id assistantMsgId,
        String debugPrefix
    ) {
        List<String> ids = new List<String>();
        if (String.isBlank(toolCallsJson)) {
            return ids;
        }
        try {
            Object parsed = JSON.deserializeUntyped(toolCallsJson);
            if (parsed instanceof List<Object>) {
                List<Object> toolCallList = (List<Object>) parsed;
                for (Object callObj : toolCallList) {
                    if (callObj instanceof Map<String, Object>) {
                        Map<String, Object> callMap = (Map<String, Object>) callObj;
                        Object idObj = callMap.get('id');
                        if (idObj instanceof String && String.isNotBlank((String) idObj)) {
                            ids.add((String) idObj);
                        } else {
                        }
                    } else {
                    }
                }
            } else {
                throw new JSONException('Tool calls field was not a List');
            }
        } catch (Exception e) {
            throw new PayloadFormattingException('Could not parse tool call IDs from message ' + assistantMsgId, e);
        }
        return ids;
    }

    /**
     * @description Helper method to safely add a message map to the payload list.
     *              Handles structure required by OpenAI-like LLM APIs.
     * @param payloadList The payload list to add the message to
     * @param role The role of the message (system, user, assistant, tool)
     * @param content The content of the message
     * @param toolCalls List of tool calls for assistant messages
     * @param toolCallId Tool call ID for tool messages
     * @param debugPrefix Prefix for debug messages
     * @param logContext Context for logging
     * @throws PayloadFormattingException If a critical error occurs during formatting
     */
    private static void addMessageMapToPayloadList(
        List<Map<String, Object>> payloadList,
        String role,
        String content,
        List<Object> toolCalls,
        String toolCallId,
        String debugPrefix,
        String logContext
    ) {
        if (String.isBlank(role)) {
            String errorMsg = debugPrefix + 'Cannot add message with blank role. Context: ' + logContext;

            throw new PayloadFormattingException(errorMsg);
        }

        String lowerCaseRole = role.toLowerCase().trim();
        Map<String, Object> messageMap = new Map<String, Object>{ 'role' => lowerCaseRole };
        Boolean addedSomething = false;

        Set<String> validRoles = new Set<String>{ 'system', 'user', 'assistant', 'tool' };
        if (!validRoles.contains(lowerCaseRole)) {
        }

        if (content != null) {
            messageMap.put('content', content);
            addedSomething = true;
        }

        if (toolCalls != null && !toolCalls.isEmpty()) {
            if (!'assistant'.equals(lowerCaseRole)) {
            }
            messageMap.put('tool_calls', toolCalls);
            addedSomething = true;
        }

        if (String.isNotBlank(toolCallId)) {
            if (!'tool'.equals(lowerCaseRole)) {
            }
            messageMap.put('tool_call_id', toolCallId);
            addedSomething = true;
        }

        if (!addedSomething && !('user'.equals(lowerCaseRole) || 'system'.equals(lowerCaseRole))) {
            return;
        }

        try {
            payloadList.add(messageMap);
        } catch (Exception e) {
            String errorMsg = debugPrefix + 'Failed to add message to payload: ' + e.getMessage();

            throw new PayloadFormattingException(errorMsg, e);
        }
    }

    public static ActionResult createSuccessResult(Object outputForLlm, String internalDetails) {
        return BaseAgentAction.createSuccessResult(outputForLlm, internalDetails);
    }

    public static ActionResult createErrorResult(String internalDetails, String errorCode) {
        return BaseAgentAction.createErrorResult(internalDetails, errorCode);
    }

    /**
     * @description Reverses the order of elements in a generic list.
     * @param originalList The list to reverse (can be List<Object>, List<SObject>, List<Map<String, Object>>, etc.).
     * @return A new list with elements in reverse order. Returns an empty list if input is null or empty.
     */
    @TestVisible
    public static List<Object> reverseList(List<Object> originalList) {
        List<Object> reversed = new List<Object>();
        if (originalList == null || originalList.isEmpty()) {
            return reversed;
        }

        for (Integer i = originalList.size() - 1; i >= 0; i--) {
            reversed.add(originalList.get(i));
        }
        return reversed;
    }

    @TestVisible
    private static void clearFieldSetCache() {
        fieldSetCache.clear();
    }

    public class PayloadFormattingException extends AIAgentException {
    }
}
