/**
 * Centralised notification service for all agent types.
 *
 * Call notify(executionId, EVENT_*) from any orchestrator or state-management class.
 * The service resolves the agent type from the execution record and dispatches to the
 * appropriate private handler. Unknown type/event combinations are silently ignored.
 *
 * Adding support for a new agent type or event: add a branch inside notify().
 */
public with sharing class AgentNotificationService {
    // ── Event constants ──────────────────────────────────────────────────────────
    public static final String EVENT_DRAFT_CREATED = 'DraftCreated';
    public static final String EVENT_TURN_COMPLETED = 'TurnCompleted';
    public static final String EVENT_EXECUTION_FAILED = 'ExecutionFailed';

    private static final String LOG_PREFIX = '[AgentNotificationService] ';

    // ── Public entry point ───────────────────────────────────────────────────────

    /**
     * Dispatches a notification for the given execution and event.
     * Swallows all exceptions so a notification failure never breaks the agent workflow.
     *
     * @param executionId  The AgentExecution__c record Id
     * @param event        One of the EVENT_* constants defined above
     */
    public static void notify(Id executionId, String event) {
        if (executionId == null || String.isBlank(event)) {
            return;
        }
        try {
            AgentExecution__c exec = [
                SELECT SourceRecordId__c, AIAgentDefinition__r.AgentType__c, AIAgentDefinition__r.DeveloperName__c
                FROM AgentExecution__c
                WHERE Id = :executionId
                LIMIT 1
            ];

            String agentType = exec.AIAgentDefinition__r?.AgentType__c;

            if (EVENT_DRAFT_CREATED.equals(event) && 'Email'.equals(agentType)) {
                handleEmailDraftCreated(exec);
            }
            // Future: add branches for TurnCompleted / ExecutionFailed per agent type as needed.
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                LOG_PREFIX + 'Unhandled exception for executionId=' + executionId + ', event=' + event + ': ' + e.getMessage() + '\n' + e.getStackTraceString()
            );
        }
    }

    // ── Private handlers ─────────────────────────────────────────────────────────

    /**
     * Notifies the record owner that an AI-drafted email reply is waiting for review.
     * Uses a Task for Case / Lead / Contact; falls back to a Chatter post for custom objects.
     */
    private static void handleEmailDraftCreated(AgentExecution__c exec) {
        Id sourceId = exec.SourceRecordId__c;
        if (sourceId == null) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'handleEmailDraftCreated: SourceRecordId__c is null, skipping.');
            return;
        }

        Schema.SObjectType sot = sourceId.getSObjectType();

        if (sot == Case.SObjectType || sot == Lead.SObjectType || sot == Contact.SObjectType) {
            createDraftReviewTask(sourceId, sot);
        } else {
            postDraftReviewChatter(sourceId);
        }
    }

    private static void createDraftReviewTask(Id sourceId, Schema.SObjectType sot) {
        try {
            String sotApiName = sot.getDescribe().getName();
            SObject record = Database.query('SELECT OwnerId, Name FROM ' + sotApiName + ' WHERE Id = :sourceId LIMIT 1');
            String taskSubject = 'Review AI draft reply — ' + sot.getDescribe().getLabel() + ': ' + (String) record.get('Name');

            insert new Task(
                Subject = taskSubject,
                // Case is a "What" (WhatId); Lead / Contact are "Who" (WhoId)
                WhatId = (sot == Case.SObjectType) ? sourceId : null,
                WhoId = (sot != Case.SObjectType) ? sourceId : null,
                OwnerId = (Id) record.get('OwnerId'),
                Status = 'Not Started',
                Priority = 'Normal',
                ActivityDate = Date.today()
            );

            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Review Task created for ' + sotApiName + ' owner: ' + record.get('OwnerId'));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Could not create review Task: ' + e.getMessage());
        }
    }

    private static void postDraftReviewChatter(Id sourceId) {
        try {
            ConnectApi.FeedItemInput fi = new ConnectApi.FeedItemInput();
            fi.subjectId = sourceId;
            ConnectApi.MessageBodyInput mb = new ConnectApi.MessageBodyInput();
            ConnectApi.TextSegmentInput ts = new ConnectApi.TextSegmentInput();
            ts.text = 'AI agent has drafted an email reply for this record. Please review and send.';
            mb.messageSegments = new List<ConnectApi.MessageSegmentInput>{ ts };
            fi.body = mb;
            ConnectApi.ChatterFeeds.postFeedElement(null, fi);
            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Chatter draft review notification posted on: ' + sourceId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Could not post Chatter review notification: ' + e.getMessage());
        }
    }
}
