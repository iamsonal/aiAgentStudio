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

@IsTest
private class ExtensionExecutionGuardTest {
    private static final String ASYNC_MARKER = 'Extension guard async marker';

    @IsTest
    static void detectsObservableAsyncEffects() {
        Test.startTest();
        ExtensionExecutionGuard.Boundary boundary = ExtensionExecutionGuard.open();
        System.enqueueJob(new AsyncProbe());
        futureProbe();
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setTargetObjectId(UserInfo.getUserId());
        message.setSaveAsActivity(false);
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message }, false);

        ExtensionExecutionGuard.Result result = ExtensionExecutionGuard.close(boundary);
        Test.stopTest();

        System.assertEquals(true, result.enqueuedQueueable);
        System.assertEquals(true, result.enqueuedFuture);
        System.assertEquals(true, result.sentEmail);
        System.assertEquals(true, result.performedProhibitedAsync());
    }

    @IsTest
    static void detectsImmediatelyPublishedEvents() {
        ExtensionExecutionGuard.Boundary boundary = ExtensionExecutionGuard.open();
        EventBus.publish(new AgentOperationalSignal__e(Code__c = 'EXTENSION_PROBE', OccurredAt__c = System.now()));
        ExtensionExecutionGuard.Result result = ExtensionExecutionGuard.close(boundary);

        System.assertEquals(true, result.publishedImmediateEvent, 'A rollback cannot retract an immediately published event.');
        System.assertEquals(true, result.performedProhibitedAsync());

        ExtensionExecutionGuard.Boundary quiet = ExtensionExecutionGuard.open();
        ExtensionExecutionGuard.Result clean = ExtensionExecutionGuard.close(quiet);
        System.assertEquals(false, clean.publishedImmediateEvent);
        System.assertEquals(false, clean.performedProhibitedAsync());
    }

    @IsTest
    static void revertsExtensionDmlAndSpendsNoRollbackWhenNothingWasWritten() {
        ExtensionExecutionGuard.Boundary writer = ExtensionExecutionGuard.open();
        insert new Account(Name = ASYNC_MARKER);
        ExtensionExecutionGuard.Result wrote = ExtensionExecutionGuard.close(writer);
        System.assertEquals(true, wrote.performedDml);
        System.assertEquals(0, [SELECT COUNT() FROM Account WHERE Name = :ASYNC_MARKER], 'Extension DML must be rolled back.');

        Integer dmlBefore = Limits.getDmlStatements();
        ExtensionExecutionGuard.Result clean = ExtensionExecutionGuard.close(ExtensionExecutionGuard.open());
        System.assertEquals(false, clean.performedDml);
        System.assertEquals(dmlBefore + 2, Limits.getDmlStatements(), 'A boundary without writes costs only its savepoint and release.');
    }

    @IsTest
    static void reserveCheckFailsClosedBeforeExtensionExecution() {
        ExtensionExecutionGuard.forceInsufficientHeadroomForTest = true;
        try {
            ExtensionExecutionGuard.open();
            System.assert(false, 'An extension must not start without lifecycle headroom.');
        } catch (AgentKernelException.PermanentException expected) {
            System.assertEquals('EXTENSION_GOVERNOR_RESERVE_EXHAUSTED', expected.getMessage());
        } finally {
            ExtensionExecutionGuard.forceInsufficientHeadroomForTest = false;
        }
    }

    @future
    private static void futureProbe() {
        insert new Account(Name = ASYNC_MARKER);
    }

    private class AsyncProbe implements Queueable {
        public void execute(QueueableContext context) {
            insert new Account(Name = ASYNC_MARKER);
        }
    }
}
