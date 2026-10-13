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
 * Resolves the effective execution policy from Core-owned guardrails, the
 * optional org data policy, and the agent's narrow execution overrides.
 */
public inherited sharing class AgentExecutionPolicyService {
    public static final String ORG_DATA_POLICY_RECORD = 'OrgDefaults';
    public static final Integer DEFAULT_MAX_RETRIES = 3;
    public static final Integer DEFAULT_PAYLOAD_RETENTION_DAYS = 30;
    public static final Integer DEFAULT_CONTEXT_CHARACTER_BUDGET = 8000;
    public static final Integer DEFAULT_MAX_TRUST_TOKENS_PER_RUN = 500;
    public static final Integer MAX_TRUST_TOKENS_PER_RUN_CEILING = 5000;

    @TestVisible
    private static Boolean testOverrideEnabled = false;
    @TestVisible
    private static Policy testOverride;

    public class Policy {
        public Integer maxRetries;
        public Integer retryBaseDelaySeconds;
        public Integer retryMaxDelaySeconds;
        public Integer retryJitterPercent;
        public Integer maxTrustTokensPerRun;
        public String payloadRetentionMode;
        public Integer payloadRetentionDays;
        public Integer recordRetentionDays;
        public Integer retainedPayloadCharacters;
        public String sensitiveJsonKeys;
        public Integer contextCharacterBudget;
    }

    public static Policy resolve() {
        return resolve(null);
    }

    public static Policy resolve(AgentDefinition__c definition) {
        if (testOverrideEnabled && testOverride != null) {
            return copy(testOverride);
        }
        AgentDataPolicy__mdt dataPolicy = AgentDataPolicy__mdt.getInstance(ORG_DATA_POLICY_RECORD);
        Policy policy = defaults();
        if (dataPolicy != null) {
            if (!String.isBlank(dataPolicy.PayloadRetentionMode__c)) {
                policy.payloadRetentionMode = dataPolicy.PayloadRetentionMode__c.trim();
            }
            if (dataPolicy.PayloadRetentionDays__c != null) {
                policy.payloadRetentionDays = Integer.valueOf(dataPolicy.PayloadRetentionDays__c);
            }
            if (dataPolicy.RecordRetentionDays__c != null) {
                policy.recordRetentionDays = Integer.valueOf(dataPolicy.RecordRetentionDays__c);
            }
        }
        if (definition != null && definition.MaxRetries__c != null) {
            policy.maxRetries = Integer.valueOf(definition.MaxRetries__c);
        }
        return policy;
    }

    public static Policy resolveForRun(AgentRun__c run) {
        if (testOverrideEnabled && testOverride != null) {
            return copy(testOverride);
        }
        Policy policy = defaults();
        if (run == null) {
            return policy;
        }
        if (run.MaxRetries__c != null) {
            policy.maxRetries = Integer.valueOf(run.MaxRetries__c);
        }
        if (!String.isBlank(run.PayloadRetentionMode__c)) {
            policy.payloadRetentionMode = run.PayloadRetentionMode__c;
        }
        if (run.PayloadRetentionDays__c != null) {
            policy.payloadRetentionDays = Integer.valueOf(run.PayloadRetentionDays__c);
        }
        if (run.RecordRetentionDays__c != null) {
            policy.recordRetentionDays = Integer.valueOf(run.RecordRetentionDays__c);
        }
        if (run.RetainedPayloadCharacters__c != null) {
            policy.retainedPayloadCharacters = Integer.valueOf(run.RetainedPayloadCharacters__c);
        }
        policy.sensitiveJsonKeys = run.SensitiveJsonKeys__c;
        return policy;
    }

    public static Policy defaults() {
        Policy policy = new Policy();
        policy.maxRetries = DEFAULT_MAX_RETRIES;
        policy.retryBaseDelaySeconds = RetryPolicyService.DEFAULT_BASE_SECONDS;
        policy.retryMaxDelaySeconds = RetryPolicyService.DEFAULT_MAX_SECONDS;
        policy.retryJitterPercent = RetryPolicyService.DEFAULT_JITTER_PERCENT;
        policy.maxTrustTokensPerRun = DEFAULT_MAX_TRUST_TOKENS_PER_RUN;
        policy.payloadRetentionMode = PayloadProtectionService.MODE_REDACTED;
        policy.payloadRetentionDays = DEFAULT_PAYLOAD_RETENTION_DAYS;
        policy.retainedPayloadCharacters = PayloadProtectionService.DEFAULT_RETAINED_CHARACTERS;
        policy.sensitiveJsonKeys = null;
        policy.contextCharacterBudget = DEFAULT_CONTEXT_CHARACTER_BUDGET;
        return policy;
    }

    public static PayloadProtectionService.Policy toPayloadPolicy(Policy policy) {
        Policy safe = policy == null ? defaults() : policy;
        PayloadProtectionService.Policy payload = new PayloadProtectionService.Policy();
        payload.mode = PayloadProtectionService.normalizeMode(safe.payloadRetentionMode);
        payload.retainedCharacters = PayloadProtectionService.normalizeLimit(safe.retainedPayloadCharacters);
        payload.sensitiveKeys = PayloadProtectionService.parseSensitiveKeys(safe.sensitiveJsonKeys);
        return payload;
    }

    public static void validate(Policy policy) {
        Policy safe = policy == null ? defaults() : policy;
        if (safe.maxRetries == null || safe.maxRetries < 0 || safe.maxRetries > 99) {
            throw new AgentKernelException.ConfigurationException('Max retries must be a whole number between 0 and 99.');
        }
        if (safe.payloadRetentionDays == null || safe.payloadRetentionDays < 0 || safe.payloadRetentionDays > 3650) {
            throw new AgentKernelException.ConfigurationException('Payload retention days must be a whole number between 0 and 3650.');
        }
        if (safe.maxTrustTokensPerRun == null || safe.maxTrustTokensPerRun < 1 || safe.maxTrustTokensPerRun > MAX_TRUST_TOKENS_PER_RUN_CEILING) {
            throw new AgentKernelException.ConfigurationException(
                'Max trust tokens per run must be a whole number between 1 and ' + MAX_TRUST_TOKENS_PER_RUN_CEILING + '.'
            );
        }
        if (safe.recordRetentionDays != null && (safe.recordRetentionDays < safe.payloadRetentionDays || safe.recordRetentionDays > 3650)) {
            throw new AgentKernelException.ConfigurationException(
                'Record retention days must be blank or a whole number from Payload Retention Days through 3650.'
            );
        }
        if (safe.contextCharacterBudget == null || safe.contextCharacterBudget < 0 || safe.contextCharacterBudget > AgentConfigService.MAX_CONTEXT_CHARACTERS) {
            throw new AgentKernelException.ConfigurationException(
                'Context character budget must be a whole number between 0 and ' + AgentConfigService.MAX_CONTEXT_CHARACTERS + '.'
            );
        }
        RetryPolicyService.validate(safe.retryBaseDelaySeconds, safe.retryMaxDelaySeconds, safe.retryJitterPercent);
        PayloadProtectionService.validatePolicy(toPayloadPolicy(safe), safe.sensitiveJsonKeys);
    }

    @TestVisible
    static void setTestOverride(Policy policy) {
        testOverrideEnabled = true;
        testOverride = policy == null ? null : copy(policy);
    }

    @TestVisible
    static void clearTestOverride() {
        testOverrideEnabled = false;
        testOverride = null;
    }

    private static Policy copy(Policy source) {
        Policy policy = defaults();
        if (source == null) {
            return policy;
        }
        if (source.maxRetries != null) {
            policy.maxRetries = source.maxRetries;
        }
        if (source.retryBaseDelaySeconds != null) {
            policy.retryBaseDelaySeconds = source.retryBaseDelaySeconds;
        }
        if (source.retryMaxDelaySeconds != null) {
            policy.retryMaxDelaySeconds = source.retryMaxDelaySeconds;
        }
        if (source.retryJitterPercent != null) {
            policy.retryJitterPercent = source.retryJitterPercent;
        }
        if (source.maxTrustTokensPerRun != null) {
            policy.maxTrustTokensPerRun = source.maxTrustTokensPerRun;
        }
        if (!String.isBlank(source.payloadRetentionMode)) {
            policy.payloadRetentionMode = source.payloadRetentionMode;
        }
        if (source.payloadRetentionDays != null) {
            policy.payloadRetentionDays = source.payloadRetentionDays;
        }
        policy.recordRetentionDays = source.recordRetentionDays;
        if (source.retainedPayloadCharacters != null) {
            policy.retainedPayloadCharacters = source.retainedPayloadCharacters;
        }
        policy.sensitiveJsonKeys = source.sensitiveJsonKeys;
        if (source.contextCharacterBudget != null) {
            policy.contextCharacterBudget = source.contextCharacterBudget;
        }
        return policy;
    }
}
