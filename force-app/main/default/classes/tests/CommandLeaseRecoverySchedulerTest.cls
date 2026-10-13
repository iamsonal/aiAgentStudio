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

@IsTest(SeeAllData=false)
private class CommandLeaseRecoverySchedulerTest {
    @IsTest
    static void installIsIdempotentAndRemoveIsSafe() {
        Test.startTest();
        Id firstJobId = CommandLeaseRecoveryScheduler.install();
        Id secondJobId = CommandLeaseRecoveryScheduler.install();
        System.assertEquals(firstJobId, secondJobId);
        System.assertEquals(firstJobId, CommandLeaseRecoveryScheduler.getInstalledJobId());
        Integer removed = CommandLeaseRecoveryScheduler.remove();
        Integer removedAgain = CommandLeaseRecoveryScheduler.remove();
        Test.stopTest();

        System.assertEquals(6, removed);
        System.assertEquals(0, removedAgain);
        System.assertEquals(null, CommandLeaseRecoveryScheduler.getInstalledJobId());
    }

    @IsTest
    static void scheduledEntryPointInvokesFocusedRecovery() {
        CommandLeaseRecoveryScheduler.lastRecoveryResult = null;

        Test.startTest();
        new CommandLeaseRecoveryScheduler().execute(null);
        Test.stopTest();

        System.assertNotEquals(null, CommandLeaseRecoveryScheduler.lastRecoveryResult);
        System.assertEquals(0, CommandLeaseRecoveryScheduler.lastRecoveryResult.requeued);
    }

    @IsTest
    static void installRepairsAPartialScheduleSet() {
        CommandLeaseRecoveryScheduler.remove();
        System.schedule('Agent Core - Lease Recovery - 10', '0 10 * * * ?', new CommandLeaseRecoveryScheduler());

        Id primaryJobId = CommandLeaseRecoveryScheduler.install();

        System.assertNotEquals(null, primaryJobId);
        System.assertEquals(primaryJobId, CommandLeaseRecoveryScheduler.getInstalledJobId());
        System.assertEquals(6, CommandLeaseRecoveryScheduler.remove());
    }
}
