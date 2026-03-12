/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Context provider that injects the email conversation thread into
 * the agent's prompt automatically. Works with any Salesforce object that can
 * be the parent of EmailMessage records (Case, Lead, Contact, or custom objects).
 *
 * Unlike querying EmailMessages as a CaseContext sub-query (which uses DESC order
 * and has no body truncation), this provider:
 * - Returns messages in **ascending chronological order** so the LLM reads the
 *   thread from oldest to newest — the natural reading direction.
 * - **Truncates** TextBody to a configurable maximum length, preventing token bloat
 *   from long email chains.
 * - **Filters** outbound messages when not needed (configurable).
 * - Works for any parent object type, making it reusable across Case, Lead,
 *   Contact, and custom objects without changes.
 *
 * **Configuration (via AgentContextConfig__c.ImplementationConfigJson__c):**
 * ```json
 * {
 *   "maxMessages": 15,
 *   "maxBodyLength": 500,
 *   "includeOutbound": true
 * }
 * ```
 *
 * **Output:** Returns EmailMessage SObjects under the key `'EmailThread'`.
 * ContextFormattingService renders these fields for the LLM:
 * - Direction (Incoming = true/false → Inbound/Outbound)
 * - FromAddress / FromName
 * - ToAddress, CcAddress
 * - Subject
 * - MessageDate
 * - TextBody (truncated to maxBodyLength)
 *
 * **Registration:** Create an AgentContextConfig__c record per parent object type:
 * - ImplementationName__c = 'EmailThreadContext'
 * - ApplicableSObjectTypes__c = 'Case' (or 'Lead', 'Contact', etc.)
 * - RequiresRecordContext__c = true
 *
 * @implements IAgentContextProvider
 * @see CaseContext For full Case context including case fields, history, and comments
 */
public inherited sharing class EmailThreadContext implements IAgentContextProvider {
    private static final Integer DEFAULT_MAX_MESSAGES = 15;
    private static final Integer DEFAULT_MAX_BODY_LENGTH = 500;
    private static final Boolean DEFAULT_INCLUDE_OUTBOUND = true;

    /**
     * @description Retrieves the email thread for the given parent record IDs.
     * Messages are returned in ascending chronological order (oldest first) so the LLM
     * can follow the conversation naturally from beginning to end.
     *
     * @param anchorIds  Set of parent record IDs (Case, Lead, Contact, etc.)
     * @param userId     Current user ID (not used but required by interface)
     * @param configurationJson  Optional JSON: {"maxMessages": 15, "maxBodyLength": 500, "includeOutbound": true}
     * @return Map with single 'EmailThread' key containing EmailMessage records
     */
    public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();

        if (anchorIds == null || anchorIds.isEmpty()) {
            return result;
        }

        Integer maxMessages = DEFAULT_MAX_MESSAGES;
        Integer maxBodyLength = DEFAULT_MAX_BODY_LENGTH;
        Boolean includeOutbound = DEFAULT_INCLUDE_OUTBOUND;

        if (String.isNotBlank(configurationJson)) {
            try {
                Map<String, Object> config = (Map<String, Object>) JSON.deserializeUntyped(configurationJson);
                if (config.containsKey('maxMessages')) {
                    maxMessages = (Integer) config.get('maxMessages');
                }
                if (config.containsKey('maxBodyLength')) {
                    maxBodyLength = (Integer) config.get('maxBodyLength');
                }
                if (config.containsKey('includeOutbound')) {
                    includeOutbound = (Boolean) config.get('includeOutbound');
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, '[EmailThreadContext] Failed to parse configurationJson: ' + e.getMessage());
            }
        }

        try {
            List<EmailMessage> messages;
            if (includeOutbound) {
                messages = [
                    SELECT Id, Subject, TextBody, FromAddress, FromName, ToAddress, CcAddress, MessageDate, Incoming, Status, ParentId
                    FROM EmailMessage
                    WHERE ParentId IN :anchorIds
                    WITH USER_MODE
                    ORDER BY MessageDate ASC
                    LIMIT :maxMessages
                ];
            } else {
                messages = [
                    SELECT Id, Subject, TextBody, FromAddress, FromName, ToAddress, CcAddress, MessageDate, Incoming, Status, ParentId
                    FROM EmailMessage
                    WHERE ParentId IN :anchorIds AND Incoming = TRUE
                    WITH USER_MODE
                    ORDER BY MessageDate ASC
                    LIMIT :maxMessages
                ];
            }

            if (!messages.isEmpty()) {
                // Truncate body in-memory — prevents token bloat from long email chains.
                // This modifies the SObject field value in the heap; no DML is performed.
                for (EmailMessage msg : messages) {
                    if (String.isNotBlank(msg.TextBody) && msg.TextBody.length() > maxBodyLength) {
                        msg.TextBody = msg.TextBody.left(maxBodyLength) + '…';
                    }
                }

                result.put('EmailThread', messages);
            }

            System.debug(
                '[EmailThreadContext] Retrieved ' +
                    messages.size() +
                    ' message(s) for ' +
                    anchorIds.size() +
                    ' parent record(s). includeOutbound=' +
                    includeOutbound +
                    ', maxBodyLength=' +
                    maxBodyLength
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[EmailThreadContext] Error retrieving email thread: ' + e.getMessage());
        }

        return result;
    }
}
