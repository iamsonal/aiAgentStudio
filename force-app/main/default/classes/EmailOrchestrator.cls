/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Orchestrator for email-based agent executions. Handles email thread continuity
 * by maintaining the same AgentExecution__c across an email thread (similar to Conversational agent).
 * Automatically sends email replies when LLM generates a content-only response.
 *
 * **Polymorphic Design**: Works with any Salesforce object that has EmailMessage relationship:
 * - Email-to-Case (support inquiries)
 * - Email-to-Lead (sales inquiries)
 * - Email-to-Contact (customer communications)
 * - Custom objects (warranty claims, partner requests, etc.)
 *
 * **Key Characteristics:**
 * - **Thread Continuity**: Same AgentExecution__c across email thread (via email ThreadIdentifier)
 * - **Auto-Send**: Sends email reply via Messaging.sendEmail() on content response
 * - **Multi-Turn**: Each email in thread is a new turn within same execution
 * - **Async Dispatch**: Uses queueable chain like Conversational agent
 * - **Proper Threading**: Uses email.ThreadIdentifier for email client thread grouping
 *
 * **Execution Flow:**
 * 1. Receive payload with sourceRecordId (any object with EmailMessage)
 * 2. Find existing execution by ThreadIdentifier__c, or create new
 * 3. Process email content through LLM
 * 4. On content response: send email reply automatically
 * 5. Complete turn
 *
 * **Expected Payload Structure:**
 * - userMessage: Email body text
 * - sourceRecordId: Parent record ID (Case, Lead, Contact, or custom object)
 * - triggerPayload: JSON with {fromAddress, subject, threadIdentifier, messageId, parentType}
 *
 * @see ConversationalOrchestrator For similar multi-turn pattern
 */
public class EmailOrchestrator extends BaseAgentOrchestrator {
    private static final String LOG_PREFIX = '[EmailOrch] ';

    // Email-specific system prompt additions
    private static final String EMAIL_GUIDELINES =
        '\n\n# EMAIL RESPONSE GUIDELINES\n\n' +
        'You are drafting an email reply to a customer. Follow these guidelines:\n\n' +
        '## Content:\n' +
        '- Address the customer\'s question or concern directly\n' +
        '- Be professional, helpful, and empathetic\n' +
        '- Keep responses concise but complete\n' +
        '- If you cannot resolve the issue, explain why and suggest next steps\n\n' +
        '## Format:\n' +
        '- Start with a simple greeting (e.g., "Hi," or "Hello,")\n' +
        '- Write your response body\n' +
        '- End with a simple closing like "Best regards," or "Thank you,"\n' +
        '- Do NOT include:\n' +
        '  - Your name or signature block (added automatically by the system)\n' +
        '  - Email headers (To, From, Subject)\n' +
        '  - Internal system details or technical jargon\n' +
        '  - Placeholders like [Your Name] or [Company Name]';

    public EmailOrchestrator() {
    }

    public EmailOrchestrator(AIAgentDefinition__c agentDefinition) {
        configure(agentDefinition);
    }

    /**
     * @description Starts email agent execution. Finds existing execution by ThreadIdentifier
     * or creates a new one, then dispatches async processing.
     *
     * @param agentDeveloperName The agent developer name
     * @param payload The execution payload containing email data
     * @return ExecutionResult with execution ID and status
     */
    public override AgentExecutionService.ExecutionResult start(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting email execution');

        try {
            // Resolve sourceRecordId from sourceRecordIds if needed (Flow sets sourceRecordIds)
            if (payload.sourceRecordId == null && payload.sourceRecordIds != null && !payload.sourceRecordIds.isEmpty()) {
                payload.sourceRecordId = payload.sourceRecordIds[0];
                System.debug(LoggingLevel.INFO, logPrefix + 'Resolved sourceRecordId from sourceRecordIds: ' + payload.sourceRecordId);
            }

            // Validate sourceRecordId exists (supports any object with EmailMessage relationship)
            if (payload.sourceRecordId == null) {
                throw new AIAgentException.OrchestrationException('Email Agent requires sourceRecordId for the parent record with associated EmailMessage');
            }

            // Query EmailMessage and build trigger metadata (polymorphic - works with any object)
            Map<String, Object> triggerMetadata = buildTriggerMetadataFromRecord(payload, logPrefix);
            String threadIdentifier = (String) triggerMetadata.get('threadIdentifier');

            if (String.isBlank(threadIdentifier)) {
                throw new AIAgentException.OrchestrationException(
                    'No thread identifier found on EmailMessage. Email threading may not be configured correctly.'
                );
            }

            // Validate required fields
            if (String.isBlank(payload.userMessage)) {
                throw new AIAgentException.OrchestrationException('User message (email body) is required for email execution');
            }

            // Generate turn identifier if not provided
            if (String.isBlank(payload.turnIdentifier)) {
                payload.turnIdentifier = UUID.randomUUID().toString();
            }

            // Find or create execution by thread identifier
            Id executionId = findOrCreateExecution(payload, threadIdentifier, triggerMetadata, logPrefix);

            System.debug(LoggingLevel.INFO, logPrefix + 'Using execution: ' + executionId + ' for thread: ' + threadIdentifier);

            // Dispatch async processing
            enqueueQueueable(executionId, payload, logPrefix);

            return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Processing email');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error initiating email execution: ' + e.getMessage() + '\n' + e.getStackTraceString());
            throw new AIAgentException.OrchestrationException('Failed to start email execution: ' + e.getMessage());
        }
    }

    /**
     * @description Finds existing execution by ThreadIdentifier or creates a new one.
     * This enables thread continuity - same execution across email thread.
     *
     * @param payload The execution payload
     * @param threadIdentifier The email thread identifier
     * @param triggerMetadata Parsed trigger metadata
     * @param logPrefix Log prefix for debugging
     * @return The execution ID (existing or newly created)
     */
    private Id findOrCreateExecution(
        AgentExecutionService.ExecutionPayload payload,
        String threadIdentifier,
        Map<String, Object> triggerMetadata,
        String logPrefix
    ) {
        // Look for existing execution with this thread identifier
        List<AgentExecution__c> existingExecutions = [
            SELECT Id, ProcessingStatus__c, CurrentTurnIdentifier__c
            FROM AgentExecution__c
            WHERE ThreadIdentifier__c = :threadIdentifier AND AIAgentDefinition__c = :agentDefinition.Id
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];

        if (!existingExecutions.isEmpty()) {
            AgentExecution__c existing = existingExecutions[0];

            // Check if execution is busy
            if (existing.ProcessingStatus__c == AIAgentConstants.STATUS_PROCESSING) {
                throw new AIAgentException.OrchestrationException(
                    'Email thread execution is currently processing. Please wait for the current turn to complete.'
                );
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Found existing execution for thread: ' + threadIdentifier);

            // Update execution for new turn
            AgentStateService agentStateSvc = new AgentStateService();
            agentStateSvc.updateStatus(existing.Id, 'Processing', AIAgentConstants.STATUS_PROCESSING, payload.turnIdentifier, 'Processing new email in thread');

            // Update trigger payload with latest email metadata
            existing.TriggerPayload__c = JSON.serialize(triggerMetadata);
            update existing;

            return existing.Id;
        }

        // Create new execution
        System.debug(LoggingLevel.INFO, logPrefix + 'Creating new execution for thread: ' + threadIdentifier);

        AgentStateService agentStateService = new AgentStateService();
        String subject = (String) triggerMetadata.get('subject');
        String executionLabel = 'Email - ' + (String.isNotBlank(subject) ? subject.abbreviate(50) : Datetime.now().format('MM/dd HH:mm:ss'));

        Id executionId = agentStateService.createExecution(
            'Email',
            agentDefinition.Id,
            payload.triggerSource,
            executionLabel,
            payload.sourceRecordId,
            payload.userId,
            payload.serviceUserId
        );

        // Set thread identifier on the new execution
        AgentExecution__c newExecution = [SELECT Id, ThreadIdentifier__c, TriggerPayload__c FROM AgentExecution__c WHERE Id = :executionId LIMIT 1];
        newExecution.ThreadIdentifier__c = threadIdentifier;
        newExecution.TriggerPayload__c = JSON.serialize(triggerMetadata);
        update newExecution;

        return executionId;
    }

    /**
     * @description Queries the most recent incoming EmailMessage for the source record and builds trigger metadata.
     * Polymorphic design: Works with any object that has EmailMessage relationship (Case, Lead, Contact, custom objects).
     * Uses email.ThreadIdentifier for proper email client threading, with fallback to record ID.
     * Also enriches the payload with email body and sets service user context.
     *
     * @param payload The execution payload to enrich
     * @param logPrefix Log prefix for debugging
     * @return Map containing email metadata (fromAddress, ccAddresses, subject, threadIdentifier, parentType, etc.)
     */
    private Map<String, Object> buildTriggerMetadataFromRecord(AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        Id recordId = payload.sourceRecordId;

        // Query the most recent incoming EmailMessage for this record
        // ParentId is polymorphic - works with Case, Lead, Contact, etc.
        List<EmailMessage> emails = [
            SELECT
                Id,
                FromAddress,
                FromName,
                ToAddress,
                CcAddress,
                BccAddress,
                Subject,
                TextBody,
                HtmlBody,
                ThreadIdentifier,
                MessageIdentifier,
                MessageDate,
                Incoming,
                ParentId
            FROM EmailMessage
            WHERE ParentId = :recordId AND Incoming = TRUE
            ORDER BY MessageDate DESC
            LIMIT 1
        ];

        if (emails.isEmpty()) {
            throw new AIAgentException.OrchestrationException(
                'No incoming EmailMessage found for record: ' + recordId + '. Email Agent requires an email to process.'
            );
        }

        EmailMessage email = emails[0];
        System.debug(LoggingLevel.INFO, logPrefix + 'Found EmailMessage: ' + email.Id + ' for record: ' + recordId);

        // Extract ONLY the new content from email body, stripping quoted reply history
        // Email clients append previous conversation like: "> On Date, Agent wrote: ..."
        if (String.isBlank(payload.userMessage)) {
            String rawBody = String.isNotBlank(email.TextBody) ? email.TextBody : email.HtmlBody?.stripHtmlTags();
            payload.userMessage = extractNewEmailContent(rawBody, logPrefix);
        }

        // Set service user context - Email agents should run as a service user
        // Use the current running user as service user (Flow runs as automated process user)
        if (payload.serviceUserId == null) {
            payload.serviceUserId = UserInfo.getUserId();
            System.debug(LoggingLevel.INFO, logPrefix + 'Set service user context: ' + payload.serviceUserId);
        }

        // Use email ThreadIdentifier for proper email client threading
        // Falls back to record ID if ThreadIdentifier is not available
        String threadIdentifier = String.isNotBlank(email.ThreadIdentifier) ? email.ThreadIdentifier : String.valueOf(recordId);
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Thread identifier: ' + threadIdentifier + (String.isNotBlank(email.ThreadIdentifier) ? ' (from email)' : ' (fallback to record ID)')
        );

        // Parse CC addresses into a list (CcAddress is semicolon-separated)
        List<String> ccAddresses = parseCcAddresses(email.CcAddress);
        if (!ccAddresses.isEmpty()) {
            System.debug(LoggingLevel.INFO, logPrefix + 'Found ' + ccAddresses.size() + ' CC recipients');
        }

        // Build and return trigger metadata
        Map<String, Object> triggerMetadata = new Map<String, Object>{
            'emailMessageId' => email.Id,
            'fromAddress' => email.FromAddress,
            'fromName' => email.FromName,
            'toAddress' => email.ToAddress,
            'ccAddresses' => ccAddresses,
            'subject' => cleanSubject(email.Subject),
            'threadIdentifier' => threadIdentifier,
            'messageId' => email.MessageIdentifier,
            'messageDate' => email.MessageDate,
            'parentId' => email.ParentId,
            'parentType' => recordId.getSObjectType().getDescribe().getName()
        };

        System.debug(LoggingLevel.INFO, logPrefix + 'Built trigger metadata for ' + triggerMetadata.get('parentType') + ': ' + recordId);
        return triggerMetadata;
    }

    /**
     * @description Parses CC addresses from the semicolon-separated CcAddress field.
     *
     * @param ccAddress The raw CcAddress string (semicolon-separated)
     * @return List of individual CC email addresses
     */
    private List<String> parseCcAddresses(String ccAddress) {
        List<String> addresses = new List<String>();

        if (String.isBlank(ccAddress)) {
            return addresses;
        }

        // CcAddress can be semicolon or comma separated
        for (String addr : ccAddress.split('[;,]')) {
            String trimmed = addr.trim();
            if (String.isNotBlank(trimmed)) {
                addresses.add(trimmed);
            }
        }

        return addresses;
    }

    /**
     * @description Extracts only the NEW content from an email body, removing quoted reply history.
     * Email clients typically append previous conversation with markers like:
     * - "On [Date], [Name] wrote:" (Gmail, Apple Mail)
     * - "From: ... Sent: ... To: ... Subject:" (Outlook)
     * - Lines starting with ">" (quote markers)
     * - "-----Original Message-----" (Outlook)
     *
     * @param rawBody The full email body text
     * @param logPrefix Log prefix for debugging
     * @return The extracted new content only
     */
    private String extractNewEmailContent(String rawBody, String logPrefix) {
        if (String.isBlank(rawBody)) {
            return rawBody;
        }

        String content = rawBody;

        // Pattern 1: Gmail/Apple Mail style - "On [Date], [Name] wrote:"
        Pattern gmailPattern = Pattern.compile('(?i)\\s*On .+wrote:\\s*$');
        Matcher gmailMatcher = gmailPattern.matcher(content);
        if (gmailMatcher.find()) {
            content = content.substring(0, gmailMatcher.start()).trim();
        }

        // Pattern 2: Outlook style - "From: ... Sent: ... To: ..."
        Pattern outlookPattern = Pattern.compile('(?i)\\s*From:\\s*.+\\s*Sent:\\s*.+\\s*To:\\s*');
        Matcher outlookMatcher = outlookPattern.matcher(content);
        if (outlookMatcher.find()) {
            content = content.substring(0, outlookMatcher.start()).trim();
        }

        // Pattern 3: "-----Original Message-----" or similar dividers
        Pattern dividerPattern = Pattern.compile('(?i)\\s*-{3,}\\s*(Original Message|Forwarded message)\\s*-{3,}');
        Matcher dividerMatcher = dividerPattern.matcher(content);
        if (dividerMatcher.find()) {
            content = content.substring(0, dividerMatcher.start()).trim();
        }

        // Pattern 4: Remove lines starting with ">" (quoted text)
        // Split by lines and filter
        List<String> lines = content.split('\n');
        List<String> newLines = new List<String>();
        for (String line : lines) {
            String trimmedLine = line.trim();
            // Skip lines that are quote markers
            if (!trimmedLine.startsWith('>') && !trimmedLine.startsWith('&gt;')) {
                newLines.add(line);
            }
        }
        content = String.join(newLines, '\n').trim();

        // Pattern 5: Salesforce thread token in subject area that might leak into body
        Pattern threadTokenPattern = Pattern.compile('\\[ thread::.+:: \\]');
        content = threadTokenPattern.matcher(content).replaceAll('').trim();

        // Trust the regex extraction - if a split point was found, use the extracted content
        System.debug(LoggingLevel.INFO, logPrefix + 'Extracted email content: ' + content.length() + ' chars from original ' + rawBody.length() + ' chars');

        return content;
    }

    /**
     * @description Cleans the email subject by removing Salesforce thread tokens and normalizing.
     *
     * @param subject The raw email subject
     * @return Cleaned subject without thread tokens
     */
    private String cleanSubject(String subject) {
        if (String.isBlank(subject)) {
            return subject;
        }

        // Remove Salesforce thread token: [ thread::TOKEN:: ]
        Pattern threadTokenPattern = Pattern.compile('\\s*\\[ thread::.+:: \\]\\s*');
        String cleaned = threadTokenPattern.matcher(subject).replaceAll('').trim();

        // Remove Salesforce ID prefix if present (e.g., "0BZo0000000KyjG Sandbox:")
        Pattern sandboxPattern = Pattern.compile('^[a-zA-Z0-9]{15,18}\\s+Sandbox:\\s*');
        cleaned = sandboxPattern.matcher(cleaned).replaceFirst('').trim();

        return cleaned;
    }

    // ===================================================================================
    // LLM CUSTOMIZATION HOOKS
    // ===================================================================================

    /**
     * @description Injects email-specific instructions into the system prompt.
     * Ensures LLM generates proper email responses.
     */
    public override String buildSystemPromptAdditions(OrchestrationContext context) {
        return EMAIL_GUIDELINES;
    }

    /**
     * @description Handles email-specific behavior after content response.
     * Sends the email reply when LLM generates a content-only response.
     */
    public override String evaluateToolOutcome(OrchestrationContext context, List<ToolCallResponseHandler.ToolExecutionResult> toolResults, String scenario) {
        String logPrefix = context.logPrefix + '[EmailCompletion] ';

        // Handle content-only response - this is when we send the email
        if (scenario == 'CONTENT_ONLY_RESPONSE') {
            System.debug(LoggingLevel.INFO, logPrefix + 'Content-only response received, sending email reply');

            try {
                // Get the LLM response content
                String emailBody = context.llmResult?.assistantMessageData?.content;
                if (String.isBlank(emailBody)) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'No content to send as email');
                    return null; // Let default handling continue
                }

                // Send the email
                Boolean sent = sendEmailReply(emailBody, context, logPrefix);

                if (sent) {
                    System.debug(LoggingLevel.INFO, logPrefix + 'Email reply sent successfully');
                    // Log the email sent event
                    logEmailSent(context, emailBody, logPrefix);
                } else {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Email sending returned false');
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to send email: ' + e.getMessage() + '\n' + e.getStackTraceString());
                // Don't fail the execution - log the error but let the turn complete
                // The response is still saved in ExecutionStep__c
            }

            return null; // Let default completion handling continue
        }

        // For other scenarios, use default behavior
        return null;
    }

    /**
     * @description Sends an email reply using Messaging.SingleEmailMessage.
     * Uses OrgWideEmailAddress to send from the same address the customer originally contacted.
     * Preserves CC recipients from the original email to maintain conversation continuity.
     *
     * @param body The email body text
     * @param context The orchestration context
     * @param logPrefix Log prefix for debugging
     * @return True if email was sent successfully
     */
    private Boolean sendEmailReply(String body, OrchestrationContext context, String logPrefix) {
        // Get trigger metadata from execution
        AgentExecution__c execution = [
            SELECT TriggerPayload__c, SourceRecordId__c
            FROM AgentExecution__c
            WHERE Id = :context.executionId
            LIMIT 1
        ];

        Map<String, Object> triggerMetadata = String.isNotBlank(execution.TriggerPayload__c)
            ? (Map<String, Object>) JSON.deserializeUntyped(execution.TriggerPayload__c)
            : new Map<String, Object>();

        String toAddress = (String) triggerMetadata.get('fromAddress'); // Customer's email
        String fromAddress = (String) triggerMetadata.get('toAddress'); // Company's Email-to-Case address
        String subject = (String) triggerMetadata.get('subject');
        String messageId = (String) triggerMetadata.get('messageId');

        // Get CC addresses - critical for business continuity when customer CCs others
        List<Object> ccAddressesRaw = (List<Object>) triggerMetadata.get('ccAddresses');
        List<String> ccAddresses = new List<String>();
        if (ccAddressesRaw != null) {
            for (Object addr : ccAddressesRaw) {
                if (addr != null) {
                    ccAddresses.add(String.valueOf(addr));
                }
            }
        }

        if (String.isBlank(toAddress)) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Cannot send email: fromAddress not found in trigger payload');
            return false;
        }

        // Build email
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ toAddress });

        // Set CC addresses - preserve all original CC recipients
        if (!ccAddresses.isEmpty()) {
            // Filter out the company's own address from CC (avoid sending to ourselves)
            List<String> filteredCcAddresses = new List<String>();
            for (String cc : ccAddresses) {
                if (String.isNotBlank(fromAddress) && !cc.equalsIgnoreCase(fromAddress)) {
                    filteredCcAddresses.add(cc);
                } else if (String.isBlank(fromAddress)) {
                    filteredCcAddresses.add(cc);
                }
            }
            if (!filteredCcAddresses.isEmpty()) {
                email.setCcAddresses(filteredCcAddresses);
                System.debug(LoggingLevel.INFO, logPrefix + 'Including ' + filteredCcAddresses.size() + ' CC recipients');
            }
        }

        // Set subject - add "Re:" only if not already present
        String replySubject = buildReplySubject(subject);
        email.setSubject(replySubject);

        email.setPlainTextBody(body);
        email.setSaveAsActivity(true); // Creates EmailMessage record

        // Set FROM address via OrgWideEmailAddress (send from the address customer originally contacted)
        if (String.isNotBlank(fromAddress)) {
            setFromAddress(email, fromAddress, logPrefix);
        }

        // Set record association - works with any object that has EmailMessage
        if (execution.SourceRecordId__c != null) {
            Id sourceRecordId = execution.SourceRecordId__c;
            Schema.SObjectType sObjectType = sourceRecordId.getSObjectType();
            String objectName = sObjectType.getDescribe().getName();

            // setTargetObjectId: Only for Lead and Contact
            // setWhatId: For Case, Account, Opportunity, and all custom objects
            if (sObjectType == Lead.SObjectType || sObjectType == Contact.SObjectType) {
                email.setTargetObjectId(execution.SourceRecordId__c);
                System.debug(LoggingLevel.INFO, logPrefix + 'Set TargetObjectId for ' + objectName);
            } else {
                // Works for Case, Account, Opportunity, Campaign, Contract, and custom objects
                email.setWhatId(execution.SourceRecordId__c);
                System.debug(LoggingLevel.INFO, logPrefix + 'Set WhatId for ' + objectName);
            }
        }

        // Set In-Reply-To header for proper email thread grouping
        if (String.isNotBlank(messageId)) {
            email.setInReplyTo(messageId);
        }

        // Send
        try {
            Messaging.SendEmailResult[] results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
            if (results[0].isSuccess()) {
                System.debug(
                    LoggingLevel.INFO,
                    logPrefix + 'Email sent successfully to: ' + toAddress + (ccAddresses.isEmpty() ? '' : ' (CC: ' + String.join(ccAddresses, ', ') + ')')
                );
                return true;
            } else {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Email send failed: ' + results[0].getErrors());
                return false;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Messaging.sendEmail failed: ' + e.getMessage());
            return false;
        }
    }

    /**
     * @description Builds the reply subject, adding "Re:" only if not already present.
     *
     * @param originalSubject The original email subject
     * @return The reply subject
     */
    private String buildReplySubject(String originalSubject) {
        if (String.isBlank(originalSubject)) {
            return 'Re: Your inquiry';
        }

        // Check if subject already starts with "Re:" (case-insensitive)
        if (originalSubject.toLowerCase().startsWith('re:')) {
            return originalSubject; // Already has "Re:", don't add another
        }

        return 'Re: ' + originalSubject;
    }

    /**
     * @description Sets the FROM address on the email using OrgWideEmailAddress.
     * This ensures the reply comes from the same address the customer originally contacted.
     *
     * @param email The email message to configure
     * @param fromAddress The address to send from
     * @param logPrefix Log prefix for debugging
     */
    private void setFromAddress(Messaging.SingleEmailMessage email, String fromAddress, String logPrefix) {
        try {
            // Look up OrgWideEmailAddress for the FROM address
            List<OrgWideEmailAddress> oweaList = [
                SELECT Id, Address, DisplayName
                FROM OrgWideEmailAddress
                WHERE Address = :fromAddress
                LIMIT 1
            ];

            if (!oweaList.isEmpty()) {
                email.setOrgWideEmailAddressId(oweaList[0].Id);
                System.debug(LoggingLevel.INFO, logPrefix + 'Set FROM address via OrgWideEmailAddress: ' + fromAddress);
            } else {
                System.debug(LoggingLevel.WARN, logPrefix + 'No OrgWideEmailAddress found for: ' + fromAddress + '. Email will be sent from running user.');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to set FROM address: ' + e.getMessage());
        }
    }

    /**
     * @description Logs the email sent event to the decision logger.
     */
    private void logEmailSent(OrchestrationContext context, String emailBody, String logPrefix) {
        try {
            if (context.decisionLogger != null) {
                context.decisionLogger.log(
                    IDecisionStepLogger.EventType.TOOL_RESULT,
                    new List<Object>{ 'email_sent', 'Email reply sent to customer', true, emailBody.abbreviate(500) }
                );
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to log email sent event: ' + e.getMessage());
        }
    }

    // ===================================================================================
    // ASYNC EXECUTION
    // ===================================================================================

    /**
     * @description Executes LLM processing for email agents when invoked from a queueable job.
     * Very similar to ConversationalOrchestrator.runAsync().
     */
    public override void runAsync(Map<String, Object> payload, String logPrefix) {
        System.debug(LoggingLevel.INFO, logPrefix + 'Executing Email job');

        // Extract and validate required payload fields
        Id executionId = getRequiredId(payload, 'executionId', logPrefix);
        Id originalUserId = getRequiredId(payload, 'originalUserId', logPrefix);
        Id executionUserId = getRequiredId(payload, 'executionUserId', logPrefix);
        Id agentDefinitionId = getRequiredId(payload, 'agentDefinitionId', logPrefix);
        Id llmConfigurationId = getRequiredId(payload, 'llmConfigurationId', logPrefix);
        String turnIdentifier = getRequiredString(payload, 'turnIdentifier', logPrefix);
        String userMessage = getRequiredString(payload, 'userMessage', logPrefix);

        // Extract optional fields
        Id currentRecordId = (Id) payload.get('currentRecordId');

        System.debug(LoggingLevel.INFO, logPrefix + 'Starting LLM processing for turn: ' + turnIdentifier + ', Exec: ' + executionId);

        // Initialize decision logger
        IDecisionStepLogger.ILogger decisionLogger = IDecisionStepLogger.create(executionId, turnIdentifier, originalUserId);

        try {
            // Get user and agent names for dynamic description
            String userName = getUserName(originalUserId);
            String agentName = getAgentName(agentDefinitionId);

            decisionLogger.log(IDecisionStepLogger.EventType.USER_INPUT, new List<Object>{ userMessage, userName, agentName });

            // Prepare user message data
            LLMInteractionService.MessageData currentUserMessageData = new LLMInteractionService.MessageData();
            currentUserMessageData.role = AIAgentConstants.ROLE_USER;
            currentUserMessageData.content = userMessage;

            // Enable deferred DML mode
            TransactionContext txnCtx = TransactionContext.getInstance();
            txnCtx.enableDeferredDMLMode();
            txnCtx.incrementLLMCallCount();
            txnCtx.capturePreToolLimits();
            txnCtx.setHasPreExistingExecution(true);

            OrchestrationService orchestrationSvc = new OrchestrationService();
            String outcome;
            Integer currentTurnCount = 1;

            // Multi-LLM loop
            do {
                LLMInteractionService interactionService = new LLMInteractionService(
                    executionId,
                    originalUserId,
                    agentDefinitionId,
                    llmConfigurationId,
                    turnIdentifier,
                    currentTurnCount,
                    currentRecordId,
                    false,
                    decisionLogger
                );

                // Execute LLM interaction
                LLMInteractionService.LLMInteractionResult llmResult = interactionService.prepareAndCallLLM(
                    currentTurnCount == 1 ? currentUserMessageData : null
                );

                if (llmResult == null) {
                    throw new AIAgentException.OrchestrationException('LLMInteractionService returned a null result');
                }

                // Process LLM result
                outcome = orchestrationSvc.processLlmResult(
                    llmResult,
                    executionId,
                    originalUserId,
                    executionUserId,
                    agentDefinitionId,
                    turnIdentifier,
                    currentTurnCount,
                    currentTurnCount == 1 ? currentUserMessageData : null,
                    currentRecordId,
                    decisionLogger
                );

                System.debug(LoggingLevel.INFO, logPrefix + 'LLM call ' + txnCtx.getLLMCallCount() + ' completed. Outcome: ' + outcome);

                // If immediate follow-up is needed, prepare for next iteration
                if (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP) {
                    currentTurnCount++;
                    txnCtx.incrementLLMCallCount();
                    txnCtx.capturePreToolLimits();
                }
            } while (outcome == OrchestrationService.OUTCOME_IMMEDIATE_FOLLOWUP);

            System.debug(LoggingLevel.INFO, logPrefix + 'LLM processing completed. Final outcome: ' + outcome);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'ERROR: LLM processing failed. Exception: ' + e.getMessage() + '\nStack: ' + e.getStackTraceString());

            try {
                AgentStateService ass = new AgentStateService();
                ass.failTurn(executionId, turnIdentifier, 'LLM processing failed: ' + e.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, logPrefix);
            } catch (Exception failEx) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'CRITICAL: Failed to update execution state: ' + failEx.getMessage());
            }
        } finally {
            if (TransactionContext.getInstance().isDeferredDMLMode()) {
                TransactionContext.getInstance().commitBuffer();
                TransactionContext.getInstance().disableDeferredDMLMode();
            }
            decisionLogger.commitSteps();
        }
    }

    // ===================================================================================
    // RESUME IMPLEMENTATION
    // ===================================================================================

    /**
     * @description Determines resume point for email executions.
     */
    protected override BaseAgentOrchestrator.ResumePoint determineResumePoint(
        Id executionId,
        AgentExecution__c execution,
        BaseAgentOrchestrator.ResumeOptions options,
        String logPrefix
    ) {
        BaseAgentOrchestrator.ResumePoint resumePoint = new BaseAgentOrchestrator.ResumePoint();
        resumePoint.lastTurnCount = getLastTurnCount(executionId);
        resumePoint.turnCount = 1;

        Boolean shouldRetryTool = options?.retryFailedTool;

        if (shouldRetryTool == null) {
            Map<String, Object> failedTool = findLastFailedTool(executionId, logPrefix);
            shouldRetryTool = (failedTool != null);

            if (shouldRetryTool) {
                resumePoint.toolCallId = (String) failedTool.get('toolCallId');
                resumePoint.toolName = (String) failedTool.get('toolName');
            }
        } else if (shouldRetryTool == true) {
            Map<String, Object> failedTool = findLastFailedTool(executionId, logPrefix);
            if (failedTool != null) {
                resumePoint.toolCallId = (String) failedTool.get('toolCallId');
                resumePoint.toolName = (String) failedTool.get('toolName');
            } else {
                shouldRetryTool = false;
            }
        }

        resumePoint.resumeType = shouldRetryTool ? BaseAgentOrchestrator.ResumeType.RETRY_FAILED_TOOL : BaseAgentOrchestrator.ResumeType.LLM_CONTINUE;
        return resumePoint;
    }

    /**
     * @description Executes resume for email executions.
     */
    protected override AgentExecutionService.ExecutionResult executeResume(
        Id executionId,
        AgentExecution__c execution,
        String newTurnIdentifier,
        BaseAgentOrchestrator.ResumePoint resumePoint,
        BaseAgentOrchestrator.ResumeOptions options,
        String logPrefix
    ) {
        AgentStateService agentStateSvc = new AgentStateService();
        agentStateSvc.updateStatus(executionId, 'Processing', AIAgentConstants.STATUS_PROCESSING, newTurnIdentifier, 'Resuming email execution');

        // Continue with LLM call (simplified - full retry logic can be added later)
        agentStateSvc.resumeForFollowUpLlmCall(executionId, newTurnIdentifier, null, logPrefix);

        AgentJobEnqueuer enqueuer = new AgentJobEnqueuer();
        enqueuer.enqueueFollowUp(
            executionId,
            execution.User__c,
            agentDefinition.Id,
            newTurnIdentifier,
            resumePoint.turnCount,
            logPrefix,
            false,
            execution.SourceRecordId__c
        );

        return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Resuming with LLM call');
    }

    // ===================================================================================
    // HELPER METHODS
    // ===================================================================================

    /**
     * @description Enqueues a Queueable job for email processing.
     */
    private void enqueueQueueable(Id executionId, AgentExecutionService.ExecutionPayload payload, String logPrefix) {
        Map<String, Object> queueablePayload = new Map<String, Object>{
            'executionId' => executionId,
            'originalUserId' => payload.userId,
            'executionUserId' => payload.userId,
            'agentDefinitionId' => agentDefinition.Id,
            'llmConfigurationId' => agentDefinition.LLMConfiguration__c,
            'turnIdentifier' => payload.turnIdentifier,
            'currentRecordId' => payload.currentRecordId,
            'userMessage' => payload.userMessage
        };

        UnifiedAgentQueueable queueable = new UnifiedAgentQueueable(UnifiedAgentQueueable.JOB_TYPE_EMAIL, queueablePayload);

        Id jobId = System.enqueueJob(queueable);
        System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued UnifiedAgentQueueable job (Email type): ' + jobId + ' for execution: ' + executionId);
    }

    private String getRequiredString(Map<String, Object> payload, String fieldName, String logPrefix) {
        if (!payload.containsKey(fieldName) || payload.get(fieldName) == null) {
            throw new AIAgentException.OrchestrationException('Required field missing from payload: ' + fieldName);
        }
        return (String) payload.get(fieldName);
    }

    private Id getRequiredId(Map<String, Object> payload, String fieldName, String logPrefix) {
        if (!payload.containsKey(fieldName) || payload.get(fieldName) == null) {
            throw new AIAgentException.OrchestrationException('Required field missing from payload: ' + fieldName);
        }
        return (Id) payload.get(fieldName);
    }

    private String getUserName(Id userId) {
        try {
            if (userId != null) {
                User user = [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
                return user.Name;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'Could not retrieve user name for ID: ' + userId);
        }
        return 'User';
    }

    private String getAgentName(Id agentDefinitionId) {
        return AIAgentConfigService.getAgentName(agentDefinitionId);
    }
}
