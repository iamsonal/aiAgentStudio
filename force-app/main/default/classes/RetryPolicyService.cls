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
 * Package-internal deterministic exponential retry policy.
 * Backoff parameters are engine-fixed; only maxRetries is org-configurable.
 */
public inherited sharing class RetryPolicyService {
    public static final Integer DEFAULT_BASE_SECONDS = 60;
    public static final Integer DEFAULT_MAX_SECONDS = 900;
    public static final Integer DEFAULT_JITTER_PERCENT = 20;
    public static final Integer MIN_BASE_SECONDS = 1;
    public static final Integer MAX_BASE_SECONDS = 3600;
    public static final Integer MAX_DELAY_SECONDS = 86400;
    public static final Integer MAX_JITTER_PERCENT = 50;

    public class Decision {
        public Integer delaySeconds;
        public Integer exponentialSeconds;
        public Integer completedAttemptCount;
        public Boolean retryAfterApplied;
    }

    public static void validate(Integer baseSeconds, Integer maxSeconds, Integer jitterPercent) {
        Integer safeBase = whole(baseSeconds, DEFAULT_BASE_SECONDS, 'Retry base delay');
        Integer safeMax = whole(maxSeconds, DEFAULT_MAX_SECONDS, 'Retry max delay');
        Integer safeJitter = whole(jitterPercent, DEFAULT_JITTER_PERCENT, 'Retry jitter percent');
        if (safeBase < MIN_BASE_SECONDS || safeBase > MAX_BASE_SECONDS) {
            throw new AgentKernelException.ConfigurationException('Retry base delay seconds must be a whole number between 1 and 3600.');
        }
        if (safeMax < safeBase || safeMax > MAX_DELAY_SECONDS) {
            throw new AgentKernelException.ConfigurationException('Retry max delay seconds must be between the retry base delay and 86400.');
        }
        if (safeJitter < 0 || safeJitter > MAX_JITTER_PERCENT) {
            throw new AgentKernelException.ConfigurationException('Retry jitter percent must be a whole number between 0 and 50.');
        }
    }

    public static Decision compute(String operationKey, Integer completedAttemptCount, Integer retryAfterSeconds) {
        return compute(DEFAULT_BASE_SECONDS, DEFAULT_MAX_SECONDS, DEFAULT_JITTER_PERCENT, operationKey, completedAttemptCount, retryAfterSeconds);
    }

    public static Decision compute(
        Integer baseSeconds,
        Integer maxSeconds,
        Integer jitterPercent,
        String operationKey,
        Integer completedAttemptCount,
        Integer retryAfterSeconds
    ) {
        validate(baseSeconds, maxSeconds, jitterPercent);
        Integer safeBase = value(baseSeconds, DEFAULT_BASE_SECONDS);
        Integer safeMax = value(maxSeconds, DEFAULT_MAX_SECONDS);
        Integer safeJitter = value(jitterPercent, DEFAULT_JITTER_PERCENT);
        Integer attempt = Math.max(1, completedAttemptCount == null ? 1 : completedAttemptCount);

        Long exponential = safeBase;
        for (Integer index = 1; index < attempt && exponential < safeMax; index++) {
            exponential = exponential > safeMax / 2 ? safeMax : exponential * 2;
        }
        Integer cappedExponential = exponential > safeMax ? safeMax : Integer.valueOf(String.valueOf(exponential));
        Integer jitterRange = Integer.valueOf(Math.floor(Decimal.valueOf(cappedExponential) * safeJitter / 100));
        Integer jitter = deterministicOffset(operationKey, attempt, jitterRange);
        Integer jittered = Math.max(0, Math.min(safeMax, cappedExponential + jitter));
        Integer validHint = retryAfterSeconds == null || retryAfterSeconds < 0 ? null : Math.min(safeMax, retryAfterSeconds);

        Decision result = new Decision();
        result.completedAttemptCount = attempt;
        result.exponentialSeconds = cappedExponential;
        result.retryAfterApplied = validHint != null && validHint > jittered;
        result.delaySeconds = validHint == null ? jittered : Math.max(validHint, jittered);
        return result;
    }

    private static Integer deterministicOffset(String operationKey, Integer attempt, Integer range) {
        if (range <= 0) {
            return 0;
        }
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(String.valueOf(operationKey) + ':' + attempt));
        String prefix = EncodingUtil.convertToHex(digest).substring(0, 7).toLowerCase();
        Long bucket = 0;
        String digits = '0123456789abcdef';
        for (Integer index = 0; index < prefix.length(); index++) {
            bucket = bucket * 16 + digits.indexOf(prefix.substring(index, index + 1));
        }
        Integer width = range * 2 + 1;
        return Integer.valueOf(Math.mod(bucket, width)) - range;
    }

    private static Integer whole(Decimal configured, Integer fallback, String label) {
        Decimal candidate = configured == null ? fallback : configured;
        if (candidate != candidate.setScale(0)) {
            throw new AgentKernelException.ConfigurationException(label + ' must be a whole number.');
        }
        return Integer.valueOf(candidate);
    }

    private static Integer value(Decimal configured, Integer fallback) {
        return configured == null ? fallback : Integer.valueOf(configured);
    }
}
