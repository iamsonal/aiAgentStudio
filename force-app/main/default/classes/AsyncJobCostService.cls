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
 * Centralizes conservative Queueable capacity estimates for an agent definition.
 * Estimates are operational guidance, not an org-wide async-limit reservation.
 */
public inherited sharing class AsyncJobCostService {
    public static final Integer JOBS_PER_COMMAND = 1;
    public static final Integer MAXIMUM_INITIATING_USER_CHAIN_DEPTH = 100;
    public static final Integer MAXIMUM_JOBS_PER_RUN = 100;

    public class Estimate {
        public Integer configuredMaxCommands;
        public Integer jobsPerCommand;
        public Integer baseJobsPerRun;
        public Integer retryFreeJobsPerRun;
        public Integer worstCaseJobsPerRun;
        public Boolean exceedsMaximumJobsPerRun;
        public Integer requiredInitiatingUserStackDepth;
        public Boolean exceedsInitiatingUserChainDepth;
    }

    /**
     * Retries are budgeted per operation, so the worst case multiplies them by
     * every configured command. The supported-maximum gate applies to the
     * retry-free path; exhausted retries fail or pause the run. Chain-depth
     * admission reserves one operation's retries so nested runs stay admissible.
     */
    public static Estimate estimate(AgentDefinition__c definition) {
        Integer models = integerValue(definition == null ? null : definition.MaxModelCalls__c);
        Integer tools = integerValue(definition == null ? null : definition.MaxToolCalls__c);
        Integer retries = integerValue(AgentExecutionPolicyService.resolve(definition).maxRetries);
        Boolean delegatedPrincipal = definition != null && ExecutionIdentityService.usesIdentity(definition);
        Estimate result = new Estimate();
        result.configuredMaxCommands = models + tools;
        result.jobsPerCommand = JOBS_PER_COMMAND;
        result.baseJobsPerRun = result.configuredMaxCommands + (delegatedPrincipal ? 1 : 0);
        Integer jobsPerRetry = delegatedPrincipal ? 2 : 1 + initiatingUserDelayHops();
        Integer retryJobs = retries * result.configuredMaxCommands * jobsPerRetry;
        Integer approvalReentryJobs = tools * (delegatedPrincipal ? 2 : 1);
        result.retryFreeJobsPerRun = result.baseJobsPerRun + approvalReentryJobs;
        result.worstCaseJobsPerRun = result.retryFreeJobsPerRun + retryJobs;
        result.exceedsMaximumJobsPerRun = result.retryFreeJobsPerRun > MAXIMUM_JOBS_PER_RUN;
        Integer initiatingUserChainDepth = result.configuredMaxCommands + retries * 2;
        result.requiredInitiatingUserStackDepth = Math.min(MAXIMUM_INITIATING_USER_CHAIN_DEPTH, initiatingUserChainDepth);
        result.exceedsInitiatingUserChainDepth = initiatingUserChainDepth > MAXIMUM_INITIATING_USER_CHAIN_DEPTH;
        return result;
    }

    /** Retries of runs without an identity hop every ten minutes until due; delegated retries park at no cost. */
    private static Integer initiatingUserDelayHops() {
        return Integer.valueOf(Math.ceil(Decimal.valueOf(RetryPolicyService.DEFAULT_MAX_SECONDS) / 600));
    }

    private static Integer integerValue(Decimal value) {
        return value == null ? 0 : Math.max(0, Integer.valueOf(value));
    }
}
