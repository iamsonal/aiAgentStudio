/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * PIIMaskingService is the single public entry point for the PII Masking Trust Layer. It provides a
 * hybrid masking approach combining Schema-based masking (Salesforce Data Classification) with
 * Pattern-based masking (regex patterns) to ensure sensitive data never leaves the org in raw form
 * when communicating with external LLMs.
 *
 * This class is the ONLY class external callers should reference. The two implementation helpers —
 * PIIPatternMatcher (regex detection engine) and SchemaBasedMasker (field-classification engine) —
 * are internal support classes. Callers should never instantiate or hold direct references to them.
 * PIIMaskingSession is a companion value object that holds the bidirectional token map for a single
 * execution; callers may read statistics from it via getSession(), but should not manipulate it.
 *
 * Key Features:
 * - Hybrid masking: Schema-based for SObject fields, Pattern-based for free text
 * - Configurable masking modes: Hybrid, Schema-Only, Pattern-Only
 * - Session-scoped token mapping for consistent masking/unmasking
 * - Integration with LLM message payloads
 * - Audit logging support
 *
 * Data Flow:
 * 1. User message/context → maskText() or maskMessagePayload() → Masked content
 * 2. Send to LLM → Receive response
 * 3. LLM response → unmaskText() → Original values restored for user display
 *
 * @example
 * // Create service for an agent
 * AIAgentDefinition__c agent = [SELECT ... FROM AIAgentDefinition__c WHERE ...];
 * PIIMaskingService service = PIIMaskingService.createForAgent(agent);
 *
 * // Mask outbound content
 * String masked = service.maskText('My SSN is 123-45-6789');
 * // masked = 'My SSN is [SSN:001]'
 *
 * // Unmask response
 * String response = 'Found record for [SSN:001]';
 * String unmasked = service.unmaskText(response);
 * // unmasked = 'Found record for 123-45-6789'
 *
 * // Identify which fields on an SObject should be masked
 * Set<String> sensitiveFields = service.getMaskedFields(Contact.SObjectType);
 */
public inherited sharing class PIIMaskingService {
    // Masking mode constants
    public static final String MODE_HYBRID = 'HYBRID';
    public static final String MODE_SCHEMA_ONLY = 'SCHEMA_ONLY';
    public static final String MODE_PATTERN_ONLY = 'PATTERN_ONLY';
    private static final String PRESET_OFF = 'Off';
    private static final String PRESET_STANDARD = 'Standard';
    private static final String PRESET_STRICT = 'Strict';

    // Session for this service instance
    private PIIMaskingSession session;

    // Pattern matcher for regex-based detection
    private PIIPatternMatcher patternMatcher;

    // Schema-based masker for field classification
    private SchemaBasedMasker schemaMasker;

    // Current masking mode (one of MODE_HYBRID, MODE_SCHEMA_ONLY, MODE_PATTERN_ONLY)
    private String mode;

    // Configuration
    private Boolean isEnabled;
    private Boolean auditLoggingEnabled;

    // Logging prefix
    private static final String LOG_PREFIX = '[PIIMaskingService] ';

    /**
     * @description Creates a masking service with default configuration.
     * Uses Hybrid mode with default categories and classifications.
     */
    public PIIMaskingService() {
        this(MODE_HYBRID, null, null, null);
    }

    /**
     * @description Creates a masking service with specified mode and categories.
     *
     * @param maskingMode The masking mode to use (MODE_HYBRID, MODE_SCHEMA_ONLY, MODE_PATTERN_ONLY)
     * @param patternCategories Set of pattern categories to enable (null = all)
     * @param sensitiveClassifications Set of Data Classifications to mask (null = default)
     * @param executionId Optional execution ID for session tracking
     */
    public PIIMaskingService(String maskingMode, Set<String> patternCategories, Set<String> sensitiveClassifications, Id executionId) {
        this.mode = String.isNotBlank(maskingMode) ? maskingMode : MODE_HYBRID;
        this.isEnabled = true;
        this.auditLoggingEnabled = false;

        // Initialize session
        this.session = new PIIMaskingSession(executionId);

        // Initialize pattern matcher (for Hybrid and Pattern-Only modes)
        if (this.mode == MODE_HYBRID || this.mode == MODE_PATTERN_ONLY) {
            this.patternMatcher = new PIIPatternMatcher(patternCategories);
        }

        // Initialize schema masker (for Hybrid and Schema-Only modes)
        if (this.mode == MODE_HYBRID || this.mode == MODE_SCHEMA_ONLY) {
            this.schemaMasker = new SchemaBasedMasker(sensitiveClassifications);
        }

        System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Service initialized. Mode: ' + this.mode);
    }

    /**
     * @description Factory method to create a PIIMaskingService configured for an agent.
     * Reads configuration from AIAgentDefinition__c fields.
     *
     * @param agentConfig The agent definition record
     * @return Configured PIIMaskingService, or null if masking is disabled
     */
    public static PIIMaskingService createForAgent(AIAgentDefinition__c agentConfig) {
        return createForAgent(agentConfig, null);
    }

    /**
     * @description Factory method with execution context.
     *
     * @param agentConfig The agent definition record
     * @param executionId The execution ID for session tracking
     * @return Configured PIIMaskingService, or null if masking is disabled
     */
    public static PIIMaskingService createForAgent(AIAgentDefinition__c agentConfig, Id executionId) {
        if (agentConfig == null) {
            return null;
        }

        String preset = normalizePreset(agentConfig.PIIMaskingPreset__c);
        if (preset == PRESET_OFF) {
            System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'PII masking disabled by preset');
            return null;
        }

        String mode = MODE_HYBRID;
        Set<String> patternCategories = preset == PRESET_STANDARD ? new Set<String>{ 'Financial', 'Identity', 'Contact' } : null;
        Set<String> classifications = preset == PRESET_STANDARD
            ? new Set<String>{ 'Confidential', 'Restricted' }
            : new Set<String>{ 'Confidential', 'Restricted', 'MissionCritical', 'Internal' };

        PIIMaskingService service = new PIIMaskingService(mode, patternCategories, classifications, executionId);

        // Audit logging always on for preset-driven masking
        service.auditLoggingEnabled = true;

        System.debug(
            LoggingLevel.INFO,
            LOG_PREFIX +
                'Created service for agent: ' +
                agentConfig.DeveloperName__c +
                ', Preset: ' +
                preset +
                ', Mode: ' +
                mode +
                ', Audit: ' +
                service.auditLoggingEnabled
        );

        return service;
    }

    // =========================================================================
    // TEXT MASKING METHODS
    // =========================================================================

    /**
     * @description Masks PII in free text using pattern-based detection.
     * Use this for user messages and unstructured content.
     *
     * @param text The text to mask
     * @return Text with PII replaced by tokens
     */
    public String maskText(String text) {
        if (!this.isEnabled || String.isBlank(text)) {
            return text;
        }

        // Skip pattern masking if in Schema-Only mode
        if (this.mode == MODE_SCHEMA_ONLY) {
            return text;
        }

        if (this.patternMatcher == null) {
            return text;
        }

        // Find all matches
        List<PIIPatternMatcher.PIIMatch> matches = this.patternMatcher.findMatches(text);

        if (matches.isEmpty()) {
            return text;
        }

        // Replace matches using original indices (stable even if lengths change)
        List<PIIPatternMatcher.PIIMatch> orderedMatches = new List<PIIPatternMatcher.PIIMatch>();
        orderedMatches.addAll(matches);
        orderedMatches.sort(new PIIMatchAscendingComparator());

        List<String> parts = new List<String>();
        Integer lastIndex = 0;
        Integer textLength = text.length();

        for (PIIPatternMatcher.PIIMatch match : orderedMatches) {
            if (match == null) {
                continue;
            }
            if (match.startIndex < lastIndex || match.startIndex < 0 || match.endIndex < match.startIndex || match.endIndex > textLength) {
                System.debug(
                    LoggingLevel.WARN,
                    LOG_PREFIX +
                        'Skipping overlapping/invalid PII match [pattern=' +
                        match.patternName +
                        ', category=' +
                        match.category +
                        ']: start=' +
                        match.startIndex +
                        ', end=' +
                        match.endIndex +
                        ', lastIndex=' +
                        lastIndex +
                        ', textLength=' +
                        textLength
                );
                continue;
            }

            // Get or create token for this value
            String token = this.session.getOrCreateToken(match.matchedValue, extractPatternPrefix(match.maskFormat));
            parts.add(text.substring(lastIndex, match.startIndex));
            parts.add(token);
            lastIndex = match.endIndex;
        }

        if (lastIndex < textLength) {
            parts.add(text.substring(lastIndex));
        }

        String maskedText = String.join(parts, '');

        if (this.auditLoggingEnabled) {
            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Masked ' + matches.size() + ' PII instances in text');
        }

        return maskedText;
    }

    /**
     * @description Unmasks tokens in text, restoring original values.
     * Use this for LLM responses before displaying to users.
     *
     * @param maskedText Text containing masked tokens
     * @return Text with original values restored
     */
    public String unmaskText(String maskedText) {
        if (!this.isEnabled || String.isBlank(maskedText)) {
            return maskedText;
        }

        // Find all tokens in text using the token pattern
        System.Pattern tokenPattern = System.Pattern.compile(PIIMaskingSession.getTokenPattern());
        System.Matcher m = tokenPattern.matcher(maskedText);

        // Collect all token positions and values
        List<TokenReplacement> replacements = new List<TokenReplacement>();
        while (m.find()) {
            String token = m.group();
            String original = this.session.resolveToken(token);

            // Only add replacement if we found the original value
            if (original != token) {
                replacements.add(new TokenReplacement(m.start(), m.end(), token, original));
            }
        }

        if (replacements.isEmpty()) {
            return maskedText;
        }

        // Sort by position descending and replace
        replacements.sort(new TokenReplacementComparator());

        String unmaskedText = maskedText;
        for (TokenReplacement rep : replacements) {
            unmaskedText = unmaskedText.substring(0, rep.startIdx) + rep.originalValue + unmaskedText.substring(rep.endIdx);
        }

        if (this.auditLoggingEnabled) {
            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Unmasked ' + replacements.size() + ' tokens in response');
        }

        return unmaskedText;
    }

    // =========================================================================
    // MESSAGE PAYLOAD METHODS
    // =========================================================================

    /**
     * @description Masks PII in an LLM message payload (list of messages).
     * Processes the 'content' field of each message.
     *
     * @param messages The message payload to mask
     * @return New list with masked content
     */
    public List<Map<String, Object>> maskMessagePayload(List<Map<String, Object>> messages) {
        if (!this.isEnabled || messages == null || messages.isEmpty()) {
            return messages;
        }

        List<Map<String, Object>> maskedMessages = new List<Map<String, Object>>();

        for (Map<String, Object> message : messages) {
            Map<String, Object> maskedMessage = maskSingleMessage(message);
            maskedMessages.add(maskedMessage);
        }

        return maskedMessages;
    }

    /**
     * @description Masks PII in a single message map.
     */
    private Map<String, Object> maskSingleMessage(Map<String, Object> message) {
        if (message == null) {
            return message;
        }

        Map<String, Object> maskedMessage = new Map<String, Object>();

        for (String key : message.keySet()) {
            Object value = message.get(key);

            if ((key == 'content' || key == 'arguments') && value instanceof String) {
                // Mask text content and tool arguments
                maskedMessage.put(key, maskText((String) value));
            } else if (value instanceof List<Object>) {
                // Recursively handle lists (e.g., tool_calls)
                maskedMessage.put(key, maskList((List<Object>) value));
            } else if (value instanceof Map<String, Object>) {
                // Recursively handle nested maps
                maskedMessage.put(key, maskSingleMessage((Map<String, Object>) value));
            } else {
                // Pass through other values
                maskedMessage.put(key, value);
            }
        }

        return maskedMessage;
    }

    /**
     * @description Masks PII in a list of objects.
     */
    private List<Object> maskList(List<Object> items) {
        List<Object> maskedItems = new List<Object>();

        for (Object item : items) {
            if (item instanceof Map<String, Object>) {
                maskedItems.add(maskSingleMessage((Map<String, Object>) item));
            } else if (item instanceof String) {
                maskedItems.add(maskText((String) item));
            } else {
                maskedItems.add(item);
            }
        }

        return maskedItems;
    }

    // =========================================================================
    // SCHEMA-BASED MASKING METHODS
    // =========================================================================

    /**
     * @description Checks if a field should be masked based on Data Classification.
     *
     * @param dfr The field describe result
     * @return True if the field should be masked
     */
    public Boolean shouldMaskField(Schema.DescribeFieldResult dfr) {
        if (!this.isEnabled || this.mode == MODE_PATTERN_ONLY) {
            return false;
        }

        return this.schemaMasker != null && this.schemaMasker.shouldMaskField(dfr);
    }

    /**
     * @description Masks a field value using schema-based masking.
     *
     * @param value The field value
     * @param fieldName The field API name
     * @return The masked token or original value
     */
    public String maskFieldValue(Object value, String fieldName) {
        if (!this.isEnabled || value == null || this.schemaMasker == null) {
            return value != null ? String.valueOf(value) : null;
        }

        return this.schemaMasker.maskFieldValue(value, fieldName, this.session);
    }

    /**
     * @description Returns the set of field API names (as returned by Schema) that this service
     * would mask for the given SObject type. Delegates to the internal SchemaBasedMasker.
     * Returns an empty set when schema masking is disabled (Pattern-Only mode) or the service
     * has no schema masker configured.
     *
     * Prefer this method over holding a direct reference to SchemaBasedMasker.
     *
     * @param sObjectType The SObject type to inspect
     * @return Set of API field names that would be masked (may be empty, never null)
     */
    public Set<String> getMaskedFields(SObjectType sObjectType) {
        if (!this.isEnabled || this.mode == MODE_PATTERN_ONLY || this.schemaMasker == null || sObjectType == null) {
            return new Set<String>();
        }
        return this.schemaMasker.getMaskedFields(sObjectType);
    }

    // =========================================================================
    // SESSION AND STATISTICS
    // =========================================================================

    /**
     * @description Gets the masking session for this service.
     *
     * @return The PIIMaskingSession instance
     */
    public PIIMaskingSession getSession() {
        return this.session;
    }

    /**
     * @description Gets masking statistics for audit/logging purposes.
     *
     * @return Map of statistics (does not include actual PII values)
     */
    public Map<String, Object> getStatistics() {
        Map<String, Object> stats = this.session.getStatistics();
        stats.put('maskingMode', this.mode);
        stats.put('auditLoggingEnabled', this.auditLoggingEnabled);
        stats.put('patternCount', this.patternMatcher != null ? this.patternMatcher.getPatternCount() : 0);
        return stats;
    }

    /**
     * @description Checks if the service is enabled.
     *
     * @return True if masking is enabled
     */
    public Boolean isEnabled() {
        return this.isEnabled;
    }

    /**
     * @description Gets the current masking mode.
     *
     * @return The masking mode string (MODE_HYBRID, MODE_SCHEMA_ONLY, or MODE_PATTERN_ONLY)
     */
    public String getMode() {
        return this.mode;
    }

    // =========================================================================
    // HELPER METHODS
    // =========================================================================

    /**
     * @description Extracts the pattern prefix from a mask format string.
     * E.g., '[SSN:{index}]' → 'SSN'
     */
    private String extractPatternPrefix(String maskFormat) {
        if (String.isBlank(maskFormat)) {
            return 'PII';
        }

        // Remove brackets and {index}
        String prefix = maskFormat.replace('[', '').replace(']', '').replace(':{index}', '');
        return String.isNotBlank(prefix) ? prefix : 'PII';
    }

    private static String normalizePreset(String presetValue) {
        if (String.isBlank(presetValue)) {
            // Default to Off when not explicitly configured on the agent.
            return PRESET_OFF;
        }
        String normalized = presetValue.trim();
        if (normalized.equalsIgnoreCase(PRESET_OFF)) {
            return PRESET_OFF;
        }
        if (normalized.equalsIgnoreCase(PRESET_STRICT)) {
            return PRESET_STRICT;
        }
        return PRESET_STANDARD;
    }

    // =========================================================================
    // INNER CLASSES
    // =========================================================================

    /**
     * @description Helper class for token replacement tracking.
     */
    private class TokenReplacement {
        public Integer startIdx;
        public Integer endIdx;
        public String token;
        public String originalValue;

        public TokenReplacement(Integer start, Integer endPos, String tok, String original) {
            this.startIdx = start;
            this.endIdx = endPos;
            this.token = tok;
            this.originalValue = original;
        }
    }

    /**
     * @description Comparator to sort replacements by position (descending).
     */
    private class TokenReplacementComparator implements Comparator<TokenReplacement> {
        public Integer compare(TokenReplacement a, TokenReplacement b) {
            return b.startIdx - a.startIdx;
        }
    }

    /**
     * @description Comparator to sort PIIMatch objects by start index (ascending).
     * Ascending order allows stable rebuild of the masked string using original indices.
     */
    private class PIIMatchAscendingComparator implements Comparator<PIIPatternMatcher.PIIMatch> {
        public Integer compare(PIIPatternMatcher.PIIMatch a, PIIPatternMatcher.PIIMatch b) {
            if (a == null && b == null) {
                return 0;
            }
            if (a == null) {
                return 1;
            }
            if (b == null) {
                return -1;
            }
            return a.startIndex - b.startIndex;
        }
    }
}
