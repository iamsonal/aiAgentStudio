/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * EmailOrchestrator handles email-triggered agent executions.
 * This orchestrator:
 *   - Creates AgentExecution__c and ExecutionStep__c records for email content
 *   - Always uses Queueable for async processing (no Platform Events needed)
 *   - Processes email content, attachments, and metadata
 *
 * Async Strategy:
 *   - Always uses Queueable (EmailQueueable) for stateful, sequential processing
 */
public class EmailOrchestrator implements IAgentOrchestrator {
    private final AIAgentDefinition__c agentDef;
    private static final String LOG_PREFIX = '[EmailOrch] ';

    public EmailOrchestrator(AIAgentDefinition__c agentDefinition) {
        if (agentDefinition == null) {
            throw new AgentOrchestratorException('Agent definition is required for EmailOrchestrator');
        }
        this.agentDef = agentDefinition;
    }

    /**
     * Initiates an email-triggered execution. Creates the AgentExecution__c record and related steps,
     * then enqueues EmailQueueable for processing.
     */
    public AgentExecutionService.ExecutionResult initiate(String agentDeveloperName, AgentExecutionService.ExecutionPayload payload) {
        String logPrefix = LOG_PREFIX + '[Agent:' + agentDeveloperName + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Initiating email execution');

        try {
            // Validate email-specific fields
            if (String.isBlank(payload.emailSubject) && String.isBlank(payload.emailBody)) {
                throw new AgentOrchestratorException('Email subject or body is required for email execution');
            }

            // Create execution metadata
            Map<String, Object> emailMetadata = new Map<String, Object>{
                'emailSubject' => payload.emailSubject,
                'fromAddress' => payload.emailFromAddress,
                'toAddress' => payload.emailToAddress,
                'ccAddresses' => payload.emailCcAddresses,
                'hasAttachments' => payload.emailAttachments != null && !payload.emailAttachments.isEmpty(),
                'attachmentCount' => payload.emailAttachments != null ? payload.emailAttachments.size() : 0,
                'receivedTime' => Datetime.now()
            };

            // Create AgentExecution__c record
            ExecutionContextService executionContextService = new ExecutionContextService();
            Id executionId = executionContextService.createExecution(
                'Email',
                agentDef.Id,
                payload.triggerSource,
                JSON.serialize(emailMetadata),
                payload.sourceRecordId,
                payload.userId,
                payload.serviceUserId
            );

            // Create ExecutionStep__c records for email content
            ExecutionStepService executionStepService = new ExecutionStepService();
            String turnIdentifier = generateTurnIdentifier();

            // Update execution with turn identifier
            executionContextService.updateStatus(
                executionId,
                'Processing',
                AIAgentConstants.STATUS_PROCESSING,
                turnIdentifier,
                'Processing inbound email'
            );

            // Create main email content step
            String emailContent = buildEmailContent(payload);
            executionStepService.createStep(
                executionId,
                'TriggerInput',
                'Email',
                emailContent,
                'Email',
                turnIdentifier,
                1,
                null,
                null,
                null,
                null,
                JSON.serialize(emailMetadata),
                false
            );

            // Create attachment steps if present
            if (payload.emailAttachments != null) {
                for (Integer i = 0; i < payload.emailAttachments.size(); i++) {
                    AgentExecutionService.EmailAttachment attachment = payload.emailAttachments[i];

                    Map<String, Object> attachmentMetadata = new Map<String, Object>{
                        'fileName' => attachment.fileName,
                        'contentType' => attachment.contentType,
                        'fileSize' => attachment.fileSize,
                        'attachmentIndex' => i
                    };

                    executionStepService.createStep(
                        executionId,
                        'TriggerInput',
                        'Attachment',
                        'Attachment: ' + attachment.fileName + ' (' + attachment.contentType + ', ' + attachment.fileSize + ' bytes)',
                        'Attachment',
                        turnIdentifier,
                        1,
                        null,
                        null,
                        null,
                        null,
                        JSON.serialize(attachmentMetadata),
                        false
                    );
                }
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Created execution ' + executionId + ' with email content');

            // Enqueue EmailQueueable for async processing
            EmailQueueable queueable = new EmailQueueable(
                executionId,
                agentDef.Id,
                agentDef.LLMConfiguration__c,
                turnIdentifier,
                payload.userId,
                emailContent
            );

            Id jobId = System.enqueueJob(queueable);
            System.debug(LoggingLevel.INFO, logPrefix + 'Enqueued EmailQueueable job: ' + jobId + ' for execution: ' + executionId);

            return new AgentExecutionService.ExecutionResult(executionId, AIAgentConstants.STATUS_PROCESSING, 'Processing email');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error initiating email execution: ' + e.getMessage());
            throw new AgentOrchestratorException('Failed to initiate email execution: ' + e.getMessage());
        }
    }

    /**
     * Processes async results for email executions.
     */
    public void processAsyncResult(Id executionId, Map<String, Object> asyncPayload) {
        String logPrefix = LOG_PREFIX + '[Exec:' + executionId + '] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing async result');
        // For email agents, async processing happens entirely in EmailQueueable
        System.debug(LoggingLevel.INFO, logPrefix + 'Async result processed');
    }

    /**
     * Builds formatted email content for agent processing.
     */
    private String buildEmailContent(AgentExecutionService.ExecutionPayload payload) {
        List<String> contentParts = new List<String>();

        contentParts.add('Email Subject: ' + (payload.emailSubject ?? ''));
        contentParts.add('From: ' + (payload.emailFromAddress ?? ''));
        contentParts.add('To: ' + (payload.emailToAddress ?? ''));

        if (payload.emailCcAddresses != null && !payload.emailCcAddresses.isEmpty()) {
            contentParts.add('CC: ' + String.join(payload.emailCcAddresses, ', '));
        }

        contentParts.add('Received: ' + Datetime.now().format());
        contentParts.add('\n--- Email Body ---');

        if (String.isNotBlank(payload.emailBody)) {
            contentParts.add(payload.emailBody);
        }

        if (payload.emailAttachments != null && !payload.emailAttachments.isEmpty()) {
            contentParts.add('\n--- Attachments ---');
            for (AgentExecutionService.EmailAttachment attachment : payload.emailAttachments) {
                contentParts.add('- ' + attachment.fileName + ' (' + attachment.contentType + ', ' + attachment.fileSize + ' bytes)');
            }
        }

        return String.join(contentParts, '\n');
    }

    /**
     * Generates a unique turn identifier.
     */
    private String generateTurnIdentifier() {
        return 'email_turn_' + Datetime.now().getTime() + '_' + Math.round(Math.random() * 1000);
    }
}
