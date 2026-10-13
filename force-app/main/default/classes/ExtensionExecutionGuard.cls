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
 * Isolates query-only subscriber extensions from the worker transaction.
 * Every boundary is released before Core performs callouts or lifecycle DML,
 * and rolled back first when the extension wrote anything. Direct extension
 * DML is reverted; governor counters also let
 * callers reject observable callout and asynchronous activity. Email and
 * immediately published events are detected after they escaped, not undone.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
public without sharing class ExtensionExecutionGuard {
    public static final Integer RESERVED_QUERIES = 10;
    public static final Integer RESERVED_QUERY_ROWS = 1000;
    public static final Integer RESERVED_CPU_MILLISECONDS = 1000;
    public static final Integer RESERVED_HEAP_BYTES = 262144;
    public static final Integer MAX_EXTENSION_QUERIES = 10;
    public static final Integer MAX_EXTENSION_QUERY_ROWS = 2000;
    public static final Integer MAX_EXTENSION_CPU_MILLISECONDS = 2000;
    public static final Integer MAX_EXTENSION_HEAP_GROWTH_BYTES = 524288;
    @TestVisible
    private static Boolean forceInsufficientHeadroomForTest = false;
    /** Open boundaries. A nested boundary measures only; the outermost owns the savepoint and rollback. */
    private static Integer openDepth = 0;

    public class Boundary {
        private Savepoint savepoint;
        private Boolean open = false;
        private Integer dmlStatements;
        private Integer dmlRows;
        private Integer callouts;
        private Integer queueableJobs;
        private Integer futureCalls;
        private Integer emailInvocations;
        private Integer publishImmediateDml;
        private Integer queries;
        private Integer queryRows;
        private Integer cpuMilliseconds;
        private Integer heapBytes;
    }

    public class Result {
        public Boolean performedDml;
        public Boolean performedCallout;
        public Boolean enqueuedQueueable;
        public Boolean enqueuedFuture;
        public Boolean sentEmail;
        public Boolean publishedImmediateEvent;
        public Boolean budgetExceeded;

        public Boolean performedProhibitedAsync() {
            return enqueuedQueueable || enqueuedFuture || sentEmail || publishedImmediateEvent;
        }
    }

    public static Boundary open() {
        if (!hasRequiredHeadroom()) {
            throw new AgentKernelException.PermanentException('EXTENSION_GOVERNOR_RESERVE_EXHAUSTED');
        }
        Boundary boundary = new Boundary();
        if (openDepth == 0) {
            boundary.savepoint = Database.setSavepoint();
        }
        openDepth++;
        boundary.open = true;
        boundary.dmlStatements = Limits.getDmlStatements();
        boundary.dmlRows = Limits.getDmlRows();
        boundary.callouts = Limits.getCallouts();
        boundary.queueableJobs = Limits.getQueueableJobs();
        boundary.futureCalls = Limits.getFutureCalls();
        boundary.emailInvocations = Limits.getEmailInvocations();
        boundary.publishImmediateDml = Limits.getPublishImmediateDML();
        boundary.queries = Limits.getQueries();
        boundary.queryRows = Limits.getQueryRows();
        boundary.cpuMilliseconds = Limits.getCpuTime();
        boundary.heapBytes = Limits.getHeapSize();
        return boundary;
    }

    public static Result close(Boundary boundary) {
        if (boundary == null || boundary.open != true) {
            throw new AgentKernelException.ConfigurationException('Extension execution boundary is missing.');
        }
        Result result = new Result();
        result.performedDml = Limits.getDmlStatements() != boundary.dmlStatements || Limits.getDmlRows() != boundary.dmlRows;
        result.performedCallout = Limits.getCallouts() != boundary.callouts;
        result.enqueuedQueueable = Limits.getQueueableJobs() != boundary.queueableJobs;
        result.enqueuedFuture = Limits.getFutureCalls() != boundary.futureCalls;
        result.sentEmail = Limits.getEmailInvocations() != boundary.emailInvocations;
        result.publishedImmediateEvent = Limits.getPublishImmediateDML() != boundary.publishImmediateDml;
        result.budgetExceeded =
            Limits.getQueries() - boundary.queries > MAX_EXTENSION_QUERIES ||
            Limits.getQueryRows() - boundary.queryRows > MAX_EXTENSION_QUERY_ROWS ||
            Limits.getCpuTime() - boundary.cpuMilliseconds > MAX_EXTENSION_CPU_MILLISECONDS ||
            Limits.getHeapSize() - boundary.heapBytes > MAX_EXTENSION_HEAP_GROWTH_BYTES ||
            !hasRequiredHeadroom();
        if (boundary.savepoint != null) {
            // Each savepoint call counts as a DML statement. Roll back only when
            // the extension wrote something; the release must always run, or a
            // later callout fails.
            if (result.performedDml) {
                Database.rollback(boundary.savepoint);
            }
            Database.releaseSavepoint(boundary.savepoint);
            boundary.savepoint = null;
        }
        boundary.open = false;
        openDepth = Math.max(0, openDepth - 1);
        return result;
    }

    public static Boolean hasRequiredHeadroom() {
        return !forceInsufficientHeadroomForTest &&
            Limits.getLimitQueries() - Limits.getQueries() >= RESERVED_QUERIES &&
            Limits.getLimitQueryRows() - Limits.getQueryRows() >= RESERVED_QUERY_ROWS &&
            Limits.getLimitCpuTime() - Limits.getCpuTime() >= RESERVED_CPU_MILLISECONDS &&
            Limits.getLimitHeapSize() - Limits.getHeapSize() >= RESERVED_HEAP_BYTES;
    }
}
