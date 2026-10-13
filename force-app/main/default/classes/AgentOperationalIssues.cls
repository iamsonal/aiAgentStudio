/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * Durable, admin-visible record of failures that need a person. Every
 * AgentOperationalSignal__e becomes, or adds to, one open Agent Operational
 * Issue per code and subject, so nothing an admin must act on lives only in a
 * platform event. Issues hold codes, record IDs, and counts, never content.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class AgentOperationalIssues {
    public static final String STATUS_OPEN = 'Open';
    public static final String STATUS_RESOLVED = 'Resolved';
    public static final String STATUS_DISMISSED = 'Dismissed';
    /** Closed issues are deleted this many days after they close. */
    public static final Integer CLOSED_RETENTION_DAYS = 30;
    private static final Integer MAINTENANCE_LIMIT = 2000;
    private static final Integer MAX_DELIVERY_RETRIES = 4;
    @TestVisible
    private static Boolean failRecordForTest = false;
    @TestVisible
    private static Integer retriesForTest;
    private static final String RUN_CONTROL_PERMISSION = 'AgentKernelRunControl';
    private static final String RECOVERED = 'Agent Core saw the subject recover.';

    /** One plain next step per signal code. Every code published in this repository has one. */
    @TestVisible
    private static final Map<String, String> NEXT_STEPS = new Map<String, String>{
        'FLOW_START_LOST' => 'Start the named agent again for the named record, with the same Correlation Key if one was used.',
        'FLOW_START_FAILED' => 'Fix the reason in Detail, such as agent sharing or the Agent Execution Identity, then start the run again.',
        'WORKER_FAILED' => 'Recovery retries the step on its own. If the run paused, open it and rescue or cancel it.',
        'WORKER_FAILURE_RECOVERY_FAILED' => 'Open the run. Run recovery from Agent Core Health; if the run paused, rescue or cancel it.',
        'DISPATCH_RETRY_FAILED' => 'Check the Agent Execution Identity with Verify. Recovery redispatches the step within 10 minutes.',
        'RECOVERY_ITEM_FAILED' => 'Recovery skips this item for 15 minutes. If it keeps failing, open the run and rescue or cancel it.',
        'AGENT_HITL_RELAY_FAILED' => 'Check the relay user and its Named Credential, then retry the relay from this issue.',
        'AGENT_HITL_RELAY_REFUSED' => 'Core refused the decision. Check that the reviewer may decide this approval, then retry the relay.',
        'AGENT_APPROVAL_NOTICE_FAILED' => 'Check the approval notification integration and its Named Credential, then resend the notice through that integration. The approval still waits in Salesforce.',
        'CHANNEL_SUBSCRIBER_NOT_PRINCIPAL' => 'Configure the message subscriber to run as the integration message processing user. Follow the installed integration setup instructions.'
    };
    private static final String DEFAULT_NEXT_STEP = 'Open the related run or record, fix the cause, then dismiss this issue.';

    public static String nextStep(String code) {
        return NEXT_STEPS.containsKey(code) ? NEXT_STEPS.get(code) : DEFAULT_NEXT_STEP;
    }

    @TestVisible
    private static Set<String> knownCodes() {
        return NEXT_STEPS.keySet();
    }

    /**
     * Platform event subscriber. A failed batch is redelivered a few times, so a
     * locked row or a passing platform error does not lose an issue.
     */
    public static void handleSignals(List<AgentOperationalSignal__e> signals) {
        try {
            if (Test.isRunningTest() && failRecordForTest) {
                throw new AgentKernelException.PersistenceException('Simulated issue write failure.');
            }
            record(signals);
        } catch (Exception failure) {
            Integer retries = retriesForTest != null
                ? retriesForTest
                : (Test.isRunningTest() ? MAX_DELIVERY_RETRIES : EventBus.TriggerContext.currentContext().retries);
            if (retries < MAX_DELIVERY_RETRIES) {
                throw new EventBus.RetryableException('Agent Operational Issues could not be recorded; retrying.');
            }
            AgentOperationsLog.emit(LoggingLevel.ERROR, 'OPERATIONAL_ISSUE_RECORD_FAILED', null, null, signals == null ? 0 : signals.size(), null);
        }
    }

    /** Records the signals as issues. Repeats of an open issue add to its count. */
    public static void record(List<AgentOperationalSignal__e> signals) {
        Map<String, AgentOperationalIssue__c> byKey = new Map<String, AgentOperationalIssue__c>();
        Set<Id> workerCommandIds = new Set<Id>();
        for (AgentOperationalSignal__e signal : signals == null ? new List<AgentOperationalSignal__e>() : signals) {
            String code = String.isBlank(signal.Code__c) ? 'UNSPECIFIED' : signal.Code__c;
            String subject = subjectKey(signal);
            String key = (code + ':' + subject).left(255);
            Datetime seenAt = signal.OccurredAt__c == null ? System.now() : signal.OccurredAt__c;
            AgentOperationalIssue__c issue = byKey.get(key);
            if (issue == null) {
                issue = new AgentOperationalIssue__c(
                    Code__c = code,
                    SubjectKey__c = subject,
                    OpenKey__c = key,
                    RunId__c = validId(signal.RunId__c),
                    CommandId__c = validId(signal.CommandId__c),
                    SubjectId__c = validId(signal.SubjectId__c),
                    Detail__c = String.isBlank(signal.ExceptionType__c) ? null : signal.ExceptionType__c.left(255),
                    NextStep__c = nextStep(code),
                    OccurrenceCount__c = 0,
                    FirstSeenAt__c = seenAt,
                    LastSeenAt__c = seenAt,
                    Status__c = STATUS_OPEN
                );
                byKey.put(key, issue);
            }
            issue.OccurrenceCount__c += 1;
            if (seenAt > issue.LastSeenAt__c) {
                issue.LastSeenAt__c = seenAt;
            }
            if (code == 'WORKER_FAILED' && issue.CommandId__c != null) {
                workerCommandIds.add(issue.CommandId__c);
            }
        }
        if (byKey.isEmpty()) {
            return;
        }
        Set<String> keys = byKey.keySet();
        for (AgentOperationalIssue__c existing : [
            SELECT Id, OpenKey__c, OccurrenceCount__c, FirstSeenAt__c, LastSeenAt__c
            FROM AgentOperationalIssue__c
            WHERE OpenKey__c IN :keys
            WITH SYSTEM_MODE
            FOR UPDATE
        ]) {
            AgentOperationalIssue__c incoming = byKey.get(existing.OpenKey__c);
            incoming.Id = existing.Id;
            incoming.OccurrenceCount__c += existing.OccurrenceCount__c == null ? 0 : existing.OccurrenceCount__c;
            incoming.FirstSeenAt__c = existing.FirstSeenAt__c;
            if (existing.LastSeenAt__c != null && existing.LastSeenAt__c > incoming.LastSeenAt__c) {
                incoming.LastSeenAt__c = existing.LastSeenAt__c;
            }
        }
        // A worker failure recovery already handled needs nobody; it is kept, closed, as history.
        Set<Id> stillLeased = leasedCommands(workerCommandIds);
        for (AgentOperationalIssue__c issue : byKey.values()) {
            if (issue.Code__c == 'WORKER_FAILED' && issue.CommandId__c != null && !stillLeased.contains(issue.CommandId__c)) {
                close(issue, STATUS_RESOLVED, null, RECOVERED);
            }
        }
        Database.upsert(byKey.values(), true, AccessLevel.SYSTEM_MODE);
    }

    /** Closes the open issues with these codes about these subjects, because Core saw them recover. */
    public static Integer resolve(Set<String> codes, Set<String> subjectIds) {
        if (codes == null || codes.isEmpty() || subjectIds == null || subjectIds.isEmpty()) {
            return 0;
        }
        Set<String> keys = new Set<String>();
        for (String code : codes) {
            for (String subjectId : subjectIds) {
                if (subjectId != null) {
                    keys.add(code + ':' + subjectId);
                }
            }
        }
        List<AgentOperationalIssue__c> issues = [
            SELECT Id, OpenKey__c
            FROM AgentOperationalIssue__c
            WHERE OpenKey__c IN :keys
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        for (AgentOperationalIssue__c issue : issues) {
            close(issue, STATUS_RESOLVED, null, RECOVERED);
        }
        Database.update(issues, AccessLevel.SYSTEM_MODE);
        return issues.size();
    }

    /** An operator closes issues they handled. Needs Agent Kernel Operator or Admin and a reason. */
    public static Integer dismiss(Set<Id> issueIds, String reason) {
        if (!FeatureManagement.checkPermission(RUN_CONTROL_PERMISSION)) {
            throw new AgentKernelException.AuthorizationException('Dismissing an Agent Operational Issue needs Agent Kernel Operator or Agent Kernel Admin.');
        }
        if (String.isBlank(reason)) {
            throw new AgentKernelException.InvalidTransitionException('Enter why the issue is closed.');
        }
        if (issueIds == null || issueIds.isEmpty()) {
            return 0;
        }
        List<AgentOperationalIssue__c> issues = [
            SELECT Id, OpenKey__c
            FROM AgentOperationalIssue__c
            WHERE Id IN :issueIds AND Status__c = :STATUS_OPEN
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        for (AgentOperationalIssue__c issue : issues) {
            close(issue, STATUS_DISMISSED, UserInfo.getUserId(), reason.trim().left(255));
        }
        Database.update(issues, AccessLevel.SYSTEM_MODE);
        return issues.size();
    }

    /**
     * Daily upkeep from the retention schedule: resolves worker failures whose
     * command recovery has moved on, and deletes issues closed more than 30 days ago.
     */
    public static Integer maintain() {
        List<AgentOperationalIssue__c> openWorkerIssues = [
            SELECT Id, OpenKey__c, CommandId__c
            FROM AgentOperationalIssue__c
            WHERE Status__c = :STATUS_OPEN AND Code__c = 'WORKER_FAILED' AND CommandId__c != NULL
            WITH SYSTEM_MODE
            LIMIT :MAINTENANCE_LIMIT
        ];
        Set<Id> commandIds = new Set<Id>();
        for (AgentOperationalIssue__c issue : openWorkerIssues) {
            commandIds.add(issue.CommandId__c);
        }
        Set<Id> stillLeased = leasedCommands(commandIds);
        List<AgentOperationalIssue__c> settled = new List<AgentOperationalIssue__c>();
        for (AgentOperationalIssue__c issue : openWorkerIssues) {
            if (!stillLeased.contains(issue.CommandId__c)) {
                close(issue, STATUS_RESOLVED, null, RECOVERED);
                settled.add(issue);
            }
        }
        Database.update(settled, AccessLevel.SYSTEM_MODE);
        Datetime cutoff = System.now().addDays(-CLOSED_RETENTION_DAYS);
        List<AgentOperationalIssue__c> expired = [
            SELECT Id
            FROM AgentOperationalIssue__c
            WHERE Status__c != :STATUS_OPEN AND ClosedAt__c < :cutoff
            WITH SYSTEM_MODE
            LIMIT :MAINTENANCE_LIMIT
        ];
        Database.delete(expired, AccessLevel.SYSTEM_MODE);
        return expired.size();
    }

    /** Open issues by code, for Health. Counts only issues the caller can see. */
    public static Map<String, Integer> openCountsByCode() {
        Map<String, Integer> counts = new Map<String, Integer>();
        try {
            for (AggregateResult row : [
                SELECT Code__c code, COUNT(Id) total
                FROM AgentOperationalIssue__c
                WHERE Status__c = :STATUS_OPEN
                WITH USER_MODE
                GROUP BY Code__c
                LIMIT 200
            ]) {
                counts.put((String) row.get('code'), (Integer) row.get('total'));
            }
        } catch (Exception inaccessible) {
            // A caller without issue access sees no issue counts.
        }
        return counts;
    }

    /** Subject: the approval or work item, else the command, else the run, else a hash of the detail, else the org. */
    @TestVisible
    private static String subjectKey(AgentOperationalSignal__e signal) {
        for (String candidate : new List<String>{ signal.SubjectId__c, signal.CommandId__c, signal.RunId__c }) {
            String id = validId(candidate);
            if (id != null) {
                return id;
            }
        }
        if (!String.isBlank(signal.ExceptionType__c)) {
            return 'd' + EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(signal.ExceptionType__c))).left(40);
        }
        return 'org';
    }

    private static void close(AgentOperationalIssue__c issue, String status, Id closedBy, String reason) {
        issue.Status__c = status;
        issue.OpenKey__c = null;
        issue.ClosedAt__c = System.now();
        issue.ClosedBy__c = closedBy;
        issue.CloseReason__c = reason;
    }

    private static Set<Id> leasedCommands(Set<Id> commandIds) {
        if (commandIds.isEmpty()) {
            return new Set<Id>();
        }
        return new Map<Id, AgentCommand__c>(
                [
                    SELECT Id
                    FROM AgentCommand__c
                    WHERE Id IN :commandIds AND Status__c = :AgentKernelModels.COMMAND_STATUS_LEASED
                    WITH SYSTEM_MODE
                ]
            )
            .keySet();
    }

    private static String validId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return String.valueOf(Id.valueOf(value.trim()));
        } catch (Exception malformed) {
            return null;
        }
    }
}
