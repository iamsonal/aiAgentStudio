/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * PIIMaskingSession maintains the bidirectional mapping between original PII values and their masked tokens
 * for a single agent execution. This is a critical component of the PII Masking Trust Layer.
 *
 * Key Features:
 * - Deterministic: Same value always produces the same token within a session
 * - Bidirectional: Supports both masking (value → token) and unmasking (token → value)
 * - Session-scoped: Mappings exist only in memory during execution (no persistent storage)
 * - Thread-safe: Safe for use within a single Apex transaction
 *
 * Security Considerations:
 * - Never persists PII mappings to database
 * - Mappings are discarded when the session object is garbage collected
 * - Token format prevents collision with actual data
 *
 * @example
 * PIIMaskingSession session = new PIIMaskingSession();
 * String token1 = session.getOrCreateToken('123-45-6789', 'SSN');         // Returns [SSN:001]
 * String token2 = session.getOrCreateToken('123-45-6789', 'SSN');         // Returns [SSN:001] (same value, same token)
 * String token3 = session.getOrCreateToken('123-45-6789', 'PHONE');       // Returns [SSN:001]  (same value, different detector → still same token)
 * String token4 = session.getOrCreateToken('987-65-4321', 'SSN');         // Returns [SSN:002]  (different value → new token)
 * String original = session.resolveToken('[SSN:001]');                     // Returns '123-45-6789'
 */
public inherited sharing class PIIMaskingSession {
    // Bidirectional mappings
    private Map<String, String> valueToToken; // Original value → masked token
    private Map<String, String> tokenToValue; // Masked token → original value

    // Token counter for generating unique token indices
    private Integer tokenCounter;

    // Session metadata
    private Id executionId;
    private Datetime createdAt;

    // Statistics for audit logging
    private Integer totalMaskingOperations;
    private Integer totalUnmaskingOperations;
    private Map<String, Integer> maskCountByPattern;

    /**
     * @description Creates a new masking session without an execution context.
     * Use this for standalone masking operations.
     */
    public PIIMaskingSession() {
        this(null);
    }

    /**
     * @description Creates a new masking session linked to a specific agent execution.
     * @param execId The AgentExecution__c ID for context tracking
     */
    public PIIMaskingSession(Id execId) {
        this.valueToToken = new Map<String, String>();
        this.tokenToValue = new Map<String, String>();
        this.tokenCounter = 0;
        this.executionId = execId;
        this.createdAt = Datetime.now();
        this.totalMaskingOperations = 0;
        this.totalUnmaskingOperations = 0;
        this.maskCountByPattern = new Map<String, Integer>();
    }

    /**
     * @description Gets an existing token for a value or creates a new one.
     * This is the primary method for masking PII values.
     *
     * @param originalValue The original PII value to mask
     * @param patternName The name of the pattern that matched (e.g., 'SSN', 'CreditCard')
     * @return The masked token (e.g., '[SSN:001]')
     */
    public String getOrCreateToken(String originalValue, String patternName) {
        if (String.isBlank(originalValue)) {
            return originalValue;
        }

        String lookupKey = createLookupKey(originalValue);

        // Check if we already have a token for this value
        if (this.valueToToken.containsKey(lookupKey)) {
            return this.valueToToken.get(lookupKey);
        }

        // Generate new token
        this.tokenCounter++;
        String token = formatToken(patternName, this.tokenCounter);

        // Store bidirectional mapping
        this.valueToToken.put(lookupKey, token);
        this.tokenToValue.put(token, originalValue);

        // Update statistics
        this.totalMaskingOperations++;
        Integer patternCount = this.maskCountByPattern.get(patternName);
        this.maskCountByPattern.put(patternName, (patternCount == null ? 0 : patternCount) + 1);

        return token;
    }

    /**
     * @description Resolves a token back to its original value.
     * This is the primary method for unmasking PII values in LLM responses.
     *
     * @param token The masked token (e.g., '[SSN:001]')
     * @return The original PII value, or the token itself if not found
     */
    public String resolveToken(String token) {
        if (String.isBlank(token)) {
            return token;
        }

        if (this.tokenToValue.containsKey(token)) {
            this.totalUnmaskingOperations++;
            return this.tokenToValue.get(token);
        }

        // Token not found - return as-is (might be text that looks like a token but isn't)
        return token;
    }

    /**
     * @description Checks if a given string is a known token in this session.
     *
     * @param possibleToken The string to check
     * @return True if this is a valid token in the session
     */
    public Boolean isKnownToken(String possibleToken) {
        return String.isNotBlank(possibleToken) && this.tokenToValue.containsKey(possibleToken);
    }

    /**
     * @description Checks if a value has already been masked in this session.
     *
     * @param originalValue The original value to check
     * @param patternName The pattern name for the lookup
     * @return True if this value has already been masked
     */
    public Boolean hasTokenForValue(String originalValue, String patternName) {
        if (String.isBlank(originalValue)) {
            return false;
        }
        String lookupKey = createLookupKey(originalValue);
        return this.valueToToken.containsKey(lookupKey);
    }

    /**
     * @description Gets the token for a value if it exists, without creating a new one.
     *
     * @param originalValue The original value to look up
     * @param patternName The pattern name for the lookup
     * @return The token if found, null otherwise
     */
    public String getExistingToken(String originalValue, String patternName) {
        if (String.isBlank(originalValue)) {
            return null;
        }
        String lookupKey = createLookupKey(originalValue);
        return this.valueToToken.get(lookupKey);
    }

    /**
     * @description Gets session statistics for audit logging.
     * Does not include actual PII values - only counts and patterns.
     *
     * @return A map containing session statistics
     */
    public Map<String, Object> getStatistics() {
        return new Map<String, Object>{
            'executionId' => this.executionId,
            'createdAt' => this.createdAt,
            'uniqueValuesmasked' => this.tokenToValue.size(),
            'totalMaskingOperations' => this.totalMaskingOperations,
            'totalUnmaskingOperations' => this.totalUnmaskingOperations,
            'maskCountByPattern' => this.maskCountByPattern.clone()
        };
    }

    /**
     * @description Gets the number of unique values that have been masked.
     *
     * @return The count of unique masked values
     */
    public Integer getUniqueMaskedCount() {
        return this.tokenToValue.size();
    }

    /**
     * @description Gets the execution ID associated with this session.
     *
     * @return The AgentExecution__c ID, or null if not linked
     */
    public Id getExecutionId() {
        return this.executionId;
    }

    /**
     * @description Clears all mappings from the session.
     * Use with caution - any subsequent unmask operations will fail.
     */
    public void clear() {
        this.valueToToken.clear();
        this.tokenToValue.clear();
        this.tokenCounter = 0;
        this.maskCountByPattern.clear();
    }

    // =========================================================================
    // PRIVATE HELPER METHODS
    // =========================================================================

    /**
     * @description Creates a lookup key based solely on the raw value.
     * Value-only deduplication ensures that the same string detected by both
     * schema-based and pattern-based maskers always resolves to one token,
     * preventing duplicate tokens for the same PII value in the LLM payload.
     */
    private String createLookupKey(String value) {
        return value;
    }

    /**
     * @description Formats a token with the pattern name and index.
     * Format: [PATTERN:NNN] where NNN is zero-padded to a minimum of 3 digits
     * (e.g. 001–999) and grows naturally beyond that (e.g. 1000, 1001 …).
     * The token-matching regex accepts 3 or more digits, so tokens beyond 999
     * unmask correctly without any code change.
     */
    private String formatToken(String patternName, Integer index) {
        String prefix = String.isNotBlank(patternName) ? patternName : 'PII';
        String paddedIndex = String.valueOf(index).leftPad(3, '0');
        return '[' + prefix + ':' + paddedIndex + ']';
    }

    /**
     * @description Gets the regex pattern to match tokens generated by this service.
     * Matches tokens like [SSN:001], [EMAIL:042], [FIELD_PHONE__C:1000], etc.
     * The \d{3,} quantifier accepts 3 or more digits, so tokens beyond index 999
     * (which produce 4+ digit suffixes) are matched and unmasked correctly.
     *
     * @return Regex pattern string for token matching
     */
    public static String getTokenPattern() {
        return '\\[[A-Z0-9_]+:\\d{3,}\\]';
    }
}
