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
 * Package-internal persistence protection for historical payloads. This is a
 * data-minimization boundary, not encryption from Salesforce administrators or
 * package system-mode code.
 */
public inherited sharing class PayloadProtectionService {
    public static final String MODE_FULL = 'Full';
    public static final String MODE_REDACTED = 'Redacted';
    public static final String MODE_METADATA_ONLY = 'Hash Only';
    public static final String MODE_NONE = 'None';
    public static final Integer DEFAULT_RETAINED_CHARACTERS = 32768;
    public static final Integer MAX_RETAINED_CHARACTERS = 131072;
    public static final Integer MAX_SENSITIVE_KEY_COUNT = 25;
    public static final Integer MAX_SENSITIVE_KEY_LENGTH = 80;
    private static final Integer MAX_REDACTION_DEPTH = 20;
    private static final Set<String> COMMON_SENSITIVE_KEYS = new Set<String>{
        'accesstoken',
        'apikey',
        'authorization',
        'clientsecret',
        'credential',
        'password',
        'refreshtoken',
        'secret',
        'ssn',
        'token'
    };

    public class Policy {
        public String mode;
        public Integer retainedCharacters;
        public Set<String> sensitiveKeys = new Set<String>();
    }

    public class ProtectionResult {
        public String protectedPayload;
        public String payloadHash;
        public Integer originalLength;
        public Boolean truncated = false;
        public Boolean redacted = false;
        public String mode;
    }

    public static Policy fromRun(AgentRun__c run) {
        Policy policy = new Policy();
        policy.mode = normalizeMode(run == null ? null : run.PayloadRetentionMode__c);
        policy.retainedCharacters = normalizeLimit(run == null ? null : run.RetainedPayloadCharacters__c);
        String configuredKeys = run == null ? null : run.SensitiveJsonKeys__c;
        policy.sensitiveKeys = parseSensitiveKeys(configuredKeys);
        if (!String.isBlank(configuredKeys) && !isValidSensitiveKeysConfiguration(configuredKeys)) {
            policy.mode = MODE_METADATA_ONLY;
        }
        return policy;
    }

    public static String normalizeMode(String configuredMode) {
        return String.isBlank(configuredMode) ? MODE_REDACTED : configuredMode.trim();
    }

    public static Integer normalizeLimit(Decimal configuredLimit) {
        return configuredLimit == null ? DEFAULT_RETAINED_CHARACTERS : Integer.valueOf(configuredLimit);
    }

    public static Set<String> parseSensitiveKeys(String configuredKeys) {
        Set<String> keys = new Set<String>();
        if (String.isBlank(configuredKeys)) {
            return keys;
        }
        try {
            Object parsed = JSON.deserializeUntyped(configuredKeys);
            if (!(parsed instanceof List<Object>)) {
                return keys;
            }
            for (Object value : (List<Object>) parsed) {
                if (value instanceof String && !String.isBlank((String) value)) {
                    keys.add(((String) value).trim().toLowerCase());
                }
            }
        } catch (Exception invalidSnapshot) {
            return keys;
        }
        return keys;
    }

    private static Boolean isValidSensitiveKeysConfiguration(String configuredKeys) {
        try {
            return JSON.deserializeUntyped(configuredKeys) instanceof List<Object>;
        } catch (Exception invalidConfiguration) {
            return false;
        }
    }

    public static ProtectionResult protect(String original, Policy policy) {
        return protect(original, policy, false);
    }

    /**
     * A run's final answer is the deliverable that retention governs. Redacted
     * mode still removes sensitive JSON keys, but keeps non-JSON answers, whose
     * detectable values the trust layer has already tokenized.
     */
    public static ProtectionResult protectFinalOutput(String original, Policy policy) {
        return protect(original, policy, true);
    }

    private static ProtectionResult protect(String original, Policy policy, Boolean retainNonJson) {
        Policy safePolicy = policy == null ? defaultPolicy() : policy;
        String safeMode = new Set<String>{ MODE_FULL, MODE_REDACTED, MODE_METADATA_ONLY, MODE_NONE }.contains(safePolicy.mode)
            ? safePolicy.mode
            : MODE_REDACTED;
        ProtectionResult result = new ProtectionResult();
        result.mode = safeMode;
        result.originalLength = safeMode == MODE_NONE ? null : (original == null ? 0 : original.length());
        if (original == null) {
            return result;
        }
        if (safeMode != MODE_NONE) {
            result.payloadHash = CanonicalJson.sha256(canonicalOriginal(original));
        }
        if (safeMode == MODE_NONE) {
            return result;
        }
        if (safeMode == MODE_METADATA_ONLY) {
            result.protectedPayload = JSON.serialize(
                new Map<String, Object>{ 'protectionMode' => MODE_METADATA_ONLY, 'originalLength' => result.originalLength }
            );
            return result;
        }
        String protectedValue;
        if (safeMode == MODE_REDACTED) {
            protectedValue = retainNonJson && !isJson(original) ? original : redact(original, safePolicy.sensitiveKeys);
            result.redacted = protectedValue != original;
        } else {
            protectedValue = original;
        }
        Integer retainedLimit = Math.max(0, Math.min(MAX_RETAINED_CHARACTERS, safePolicy.retainedCharacters));
        if (protectedValue.length() > retainedLimit) {
            protectedValue = protectedValue.substring(0, retainedLimit);
            result.truncated = true;
        }
        result.protectedPayload = protectedValue;
        return result;
    }

    public static void validatePolicy(Policy policy, String sensitiveJsonKeys) {
        String mode = normalizeMode(policy == null ? null : policy.mode);
        if (!new Set<String>{ MODE_FULL, MODE_REDACTED, MODE_METADATA_ONLY, MODE_NONE }.contains(mode)) {
            throw new AgentKernelException.ConfigurationException('Payload retention mode must be Full, Redacted, Hash Only, or None.');
        }
        Decimal retainedLimit = policy == null || policy.retainedCharacters == null ? DEFAULT_RETAINED_CHARACTERS : policy.retainedCharacters;
        if (retainedLimit != retainedLimit.setScale(0) || retainedLimit < 0 || retainedLimit > MAX_RETAINED_CHARACTERS) {
            throw new AgentKernelException.ConfigurationException(
                'Retained payload characters must be a whole number between 0 and ' + MAX_RETAINED_CHARACTERS + '.'
            );
        }
        validateSensitiveKeys(sensitiveJsonKeys);
    }

    private static void validateSensitiveKeys(String configuredKeys) {
        if (String.isBlank(configuredKeys)) {
            return;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(configuredKeys);
        } catch (Exception invalidJson) {
            throw new AgentKernelException.ConfigurationException('Sensitive JSON keys must be a valid JSON array.');
        }
        if (!(parsed instanceof List<Object>)) {
            throw new AgentKernelException.ConfigurationException('Sensitive JSON keys must be a JSON array.');
        }
        List<Object> values = (List<Object>) parsed;
        if (values.size() > MAX_SENSITIVE_KEY_COUNT) {
            throw new AgentKernelException.ConfigurationException('Sensitive JSON key count exceeds the package maximum.');
        }
        Set<String> uniqueKeys = new Set<String>();
        for (Object value : values) {
            if (!(value instanceof String) || String.isBlank((String) value)) {
                throw new AgentKernelException.ConfigurationException('Each sensitive JSON key must be a nonblank string.');
            }
            String normalized = ((String) value).trim().toLowerCase();
            if (normalized.length() > MAX_SENSITIVE_KEY_LENGTH) {
                throw new AgentKernelException.ConfigurationException('A sensitive JSON key exceeds the package length limit.');
            }
            if (uniqueKeys.contains(normalized)) {
                throw new AgentKernelException.ConfigurationException('Sensitive JSON keys must be unique ignoring case.');
            }
            uniqueKeys.add(normalized);
        }
    }

    private static String redact(String original, Set<String> configuredKeys) {
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(original);
        } catch (Exception malformedJson) {
            return '[REDACTED NON-JSON; length=' + original.length() + ']';
        }
        Set<String> sensitiveKeys = COMMON_SENSITIVE_KEYS.clone();
        if (configuredKeys != null) {
            for (String configuredKey : configuredKeys) {
                if (!String.isBlank(configuredKey)) {
                    sensitiveKeys.add(configuredKey.trim().toLowerCase());
                }
            }
        }
        try {
            return CanonicalJson.serialize(redactValue(parsed, sensitiveKeys, 0));
        } catch (Exception unsafeStructure) {
            return '[REDACTED UNSUPPORTED JSON; length=' + original.length() + ']';
        }
    }

    private static Object redactValue(Object value, Set<String> sensitiveKeys, Integer depth) {
        if (depth >= MAX_REDACTION_DEPTH) {
            return '[REDACTED DEPTH LIMIT]';
        }
        if (value instanceof Map<String, Object>) {
            Map<String, Object> source = (Map<String, Object>) value;
            Map<String, Object> protectedMap = new Map<String, Object>();
            for (String key : source.keySet()) {
                protectedMap.put(key, sensitiveKeys.contains(key.toLowerCase()) ? '[REDACTED]' : redactValue(source.get(key), sensitiveKeys, depth + 1));
            }
            return protectedMap;
        }
        if (value instanceof List<Object>) {
            List<Object> protectedList = new List<Object>();
            for (Object item : (List<Object>) value) {
                protectedList.add(redactValue(item, sensitiveKeys, depth + 1));
            }
            return protectedList;
        }
        return value;
    }

    private static Boolean isJson(String original) {
        try {
            JSON.deserializeUntyped(original);
            return true;
        } catch (Exception nonJson) {
            return false;
        }
    }

    private static String canonicalOriginal(String original) {
        try {
            return CanonicalJson.serialize(JSON.deserializeUntyped(original));
        } catch (Exception nonJson) {
            return original;
        }
    }

    private static Policy defaultPolicy() {
        Policy policy = new Policy();
        policy.mode = MODE_REDACTED;
        policy.retainedCharacters = DEFAULT_RETAINED_CHARACTERS;
        return policy;
    }
}
