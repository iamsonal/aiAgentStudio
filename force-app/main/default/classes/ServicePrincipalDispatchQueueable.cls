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
 * Performs only the internal Named Credential callout. The receiving REST
 * transaction validates durable identity and starts a new Queueable chain.
 * A failed hop is retried once a minute later, so a transient loopback fault
 * does not leave an attended run waiting for scheduled recovery.
 */
public without sharing class ServicePrincipalDispatchQueueable implements Queueable, Database.AllowsCallouts {
    public static final Integer MAX_RETRIES = 1;
    private final Id runId;
    private final Id commandId;
    private final Decimal expectedRevision;
    private final String operationKey;
    private final String dispatchToken;
    private final String namedCredential;
    private final Integer retryNumber;
    @TestVisible
    private static String preparedEndpointForTest;
    @TestVisible
    private static String preparedBodyForTest;

    public ServicePrincipalDispatchQueueable(
        Id runId,
        Id commandId,
        Decimal expectedRevision,
        String operationKey,
        String dispatchToken,
        String namedCredential
    ) {
        this(runId, commandId, expectedRevision, operationKey, dispatchToken, namedCredential, 0);
    }

    private ServicePrincipalDispatchQueueable(
        Id runId,
        Id commandId,
        Decimal expectedRevision,
        String operationKey,
        String dispatchToken,
        String namedCredential,
        Integer retryNumber
    ) {
        this.retryNumber = retryNumber;
        this.runId = runId;
        this.commandId = commandId;
        this.expectedRevision = expectedRevision;
        this.operationKey = operationKey;
        this.dispatchToken = dispatchToken;
        this.namedCredential = namedCredential;
        if (Test.isRunningTest()) {
            preparedEndpointForTest = endpoint();
            preparedBodyForTest = requestBody();
        }
    }

    public void execute(QueueableContext context) {
        if (
            runId == null ||
            commandId == null ||
            expectedRevision == null ||
            String.isBlank(operationKey) ||
            String.isBlank(dispatchToken) ||
            String.isBlank(namedCredential)
        ) {
            return;
        }
        if (context != null) {
            System.attachFinalizer(new RetryFinalizer(this));
        }
        HttpRequest request = new HttpRequest();
        request.setMethod('POST');
        request.setEndpoint(endpoint());
        request.setHeader('Content-Type', 'application/json');
        request.setTimeout(20000);
        request.setBody(requestBody());
        HttpResponse response = new Http().send(request);
        Integer status = response.getStatusCode();
        if (status >= 200 && status < 300) {
            return;
        }
        if (status == 409) {
            // A newer transition already moved the run on; there is nothing to deliver.
            return;
        }
        if (status == 401 || status == 403) {
            // The credential signed in as a user who may not run this command. Repeating the hop
            // cannot help; recovery redispatches with backoff and then pauses the run.
            CommandDeliveryTracker.recordAnomaly(commandId, 'DISPATCH_REFUSED_' + status);
            AgentOperationsLog.emit(LoggingLevel.ERROR, 'DISPATCH_REFUSED', runId, commandId, status, operationKey);
            return;
        }
        throw new AgentKernelException.RetryableException('Internal service-principal dispatch was not accepted.');
    }

    /**
     * Requeues a failed hop once. The receiving endpoint revalidates run,
     * revision, operation key, and dispatch token, so a hop that raced a newer
     * transition is rejected there; scheduled recovery remains the backstop.
     */
    @TestVisible
    private Id retryAfterFailure() {
        if (retryNumber >= MAX_RETRIES || !isStillDispatchable()) {
            return null;
        }
        CommandDeliveryTracker.recordAnomaly(commandId, 'DISPATCH_RETRIED');
        AgentOperationsLog.emit(LoggingLevel.WARN, 'DISPATCH_RETRIED', runId, commandId, retryNumber + 1, operationKey);
        AsyncOptions options = new AsyncOptions();
        options.MinimumQueueableDelayInMinutes = 1;
        options.DuplicateSignature = QueueableDuplicateSignature.Builder()
            .addString('principal-retry')
            .addId(commandId)
            .addString(String.valueOf(expectedRevision))
            .build();
        try {
            return System.enqueueJob(
                new ServicePrincipalDispatchQueueable(runId, commandId, expectedRevision, operationKey, dispatchToken, namedCredential, retryNumber + 1),
                options
            );
        } catch (DuplicateMessageException duplicateRetry) {
            return null;
        }
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private Boolean isStillDispatchable() {
        List<AgentRun__c> runs = [
            SELECT Status__c, Revision__c, CurrentCommand__c, CurrentCommand__r.Status__c
            FROM AgentRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return !runs.isEmpty() &&
            runs[0].Status__c == AgentKernelModels.RUN_STATUS_RUNNING &&
            runs[0].CurrentCommand__c == commandId &&
            runs[0].Revision__c == expectedRevision &&
            new Set<String>{ AgentKernelModels.COMMAND_STATUS_PENDING, AgentKernelModels.COMMAND_STATUS_RETRY_WAITING }
                .contains(runs[0].CurrentCommand__r.Status__c);
    }

    public class RetryFinalizer implements Finalizer {
        private final ServicePrincipalDispatchQueueable hop;

        public RetryFinalizer(ServicePrincipalDispatchQueueable hop) {
            this.hop = hop;
        }

        public void execute(FinalizerContext context) {
            if (context == null || context.getResult() == ParentJobResult.SUCCESS) {
                return;
            }
            try {
                hop.retryAfterFailure();
            } catch (Exception retryFailure) {
                AgentOperationsLog.signal('DISPATCH_RETRY_FAILED', hop.runId, hop.commandId, retryFailure.getTypeName());
            }
        }
    }

    private String endpoint() {
        return 'callout:' + namedCredential + '/services/apexrest/agent-core/v1/dispatch';
    }

    private String requestBody() {
        return JSON.serialize(
            new Map<String, Object>{
                'runId' => runId,
                'commandId' => commandId,
                'expectedRevision' => expectedRevision,
                'operationKey' => operationKey,
                'dispatchToken' => dispatchToken
            }
        );
    }
}
