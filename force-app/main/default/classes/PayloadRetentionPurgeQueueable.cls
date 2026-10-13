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
 * Continues bounded payload retention work across independent transactions.
 * One sequential job at a time, so a backlog never crowds the org async queue.
 * The daily budget of 101 passes clears about 10,000 runs' payloads and
 * deletes about 5,000 expired runs; the next daily tick resumes any remainder.
 */
public without sharing class PayloadRetentionPurgeQueueable implements Queueable {
    private static final Integer MAXIMUM_PASSES = 100;
    private Integer remainingPasses;
    @TestVisible
    private static Boolean captureContinuationForTest = false;
    @TestVisible
    private static Integer capturedContinuationPasses;

    public PayloadRetentionPurgeQueueable() {
        this(MAXIMUM_PASSES);
    }

    @TestVisible
    private PayloadRetentionPurgeQueueable(Integer remainingPasses) {
        this.remainingPasses = Math.max(1, Math.min(MAXIMUM_PASSES, remainingPasses == null ? MAXIMUM_PASSES : remainingPasses));
    }

    public void execute(QueueableContext context) {
        PayloadRetentionPurgeService.PurgeResult result = PayloadRetentionPurgeService.purge(100);
        PayloadRetentionPurgeService.DeletionResult deletion = PayloadRetentionPurgeService.deleteExpiredRecords(
            PayloadRetentionPurgeService.MAX_RUNS_DELETED_PER_PASS
        );
        if ((result.hasMore || deletion.hasMore) && remainingPasses > 1) {
            enqueueContinuation(remainingPasses - 1);
        }
    }

    private static void enqueueContinuation(Integer nextRemainingPasses) {
        if (captureContinuationForTest) {
            capturedContinuationPasses = nextRemainingPasses;
            return;
        }
        System.enqueueJob(new PayloadRetentionPurgeQueueable(nextRemainingPasses));
    }
}
