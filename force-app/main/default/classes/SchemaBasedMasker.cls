/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Internal implementation class for PIIMaskingService. Uses Salesforce's native Data Classification
 * (Compliance Categorization) to identify sensitive SObject fields that should be masked before
 * sending payloads to external LLMs.
 *
 * *** DO NOT instantiate or reference this class directly from outside the PII subsystem.
 * All callers should go through PIIMaskingService, which is the sole public entry point. ***
 *
 * Concretely: PIIMaskingService.shouldMaskField() and PIIMaskingService.maskFieldValue() delegate
 * to this class internally. ContextFormattingService uses PIIMaskingService.getMaskedFields() to
 * obtain the field set — it never holds a direct reference to SchemaBasedMasker.
 *
 * Salesforce Data Classifications:
 * - Confidential:   Highly sensitive data (SSN, financial data)
 * - Restricted:     Limited access data
 * - MissionCritical: Business critical data
 * - Internal:       Internal use only
 * - Public:         No restrictions
 */
public inherited sharing class SchemaBasedMasker {
    // Set of classifications that trigger masking
    private Set<String> sensitiveClassifications;

    // Cache for field classifications: ObjectName.FieldName -> SecurityClassification
    private static Map<String, String> fieldClassificationCache = new Map<String, String>();

    // Track which objects have been loaded to avoid repeated queries
    private static Set<String> loadedObjects = new Set<String>();

    // Default sensitive classifications if none specified
    private static final Set<String> DEFAULT_SENSITIVE_CLASSIFICATIONS = new Set<String>{ 'Confidential', 'Restricted' };

    // Fallback field name patterns for when classification isn't set.
    // Uses regex word boundaries to prevent false positives.
    //
    // Pattern Matching Strategy:
    // - Uses word boundaries (\\b) to match whole words or underscore-separated segments
    // - Prevents false matches like 'ssn' matching 'Classness__c' or 'dob' matching 'Adobe_Sign_Id__c'
    // - Case-insensitive matching via (?i) flag in regex
    //
    // Example Patterns:
    // - '\\bssn\\b' matches 'SSN__c', 'Contact_SSN__c' but NOT 'Classness__c'
    // - '\\bdob\\b' matches 'DOB__c', 'Customer_DOB__c' but NOT 'Adobe_Id__c'
    // - '\\bein\\b' matches 'EIN__c', 'Tax_EIN__c' but NOT 'Protein__c'
    private static Map<String, Pattern> fallbackSensitivePatterns;

    static {
        // Initialize regex patterns with word boundaries and case-insensitive flag (?i)
        fallbackSensitivePatterns = new Map<String, Pattern>{
            'ssn' => Pattern.compile('(?i)\\b(ssn|socialsecurity|social_security)\\b'),
            'tax' => Pattern.compile('(?i)\\b(taxid|tax_id|ein|itin)\\b'),
            'credit' => Pattern.compile('(?i)\\b(creditcard|credit_card|cardnumber|card_number)\\b'),
            'bank' => Pattern.compile('(?i)\\b(bankaccount|bank_account|routingnumber|routing_number)\\b'),
            'license' => Pattern.compile('(?i)\\b(driverslicense|drivers_license|passport)\\b'),
            'birth' => Pattern.compile('(?i)\\b(dateofbirth|date_of_birth|dob|birthdate)\\b')
        };
    }

    // Whether to use fallback pattern matching
    private Boolean useFallbackPatterns;

    /**
     * @description Creates a masker using the default sensitive classifications.
     * Default: Confidential and Restricted fields are masked.
     */
    public SchemaBasedMasker() {
        this(DEFAULT_SENSITIVE_CLASSIFICATIONS);
    }

    /**
     * @description Creates a masker with specific classifications that trigger masking.
     * @param classifications Set of classification names (e.g., {'Confidential', 'Restricted'})
     */
    public SchemaBasedMasker(Set<String> classifications) {
        this.sensitiveClassifications = classifications != null && !classifications.isEmpty() ? classifications : DEFAULT_SENSITIVE_CLASSIFICATIONS;
        this.useFallbackPatterns = true; // Enable fallback by default
    }

    /**
     * @description Enable or disable fallback pattern matching for fields without classification.
     * @param enabled True to enable fallback matching
     * @return This masker instance for method chaining
     */
    public SchemaBasedMasker withFallbackPatterns(Boolean enabled) {
        this.useFallbackPatterns = enabled;
        return this;
    }

    /**
     * @description Checks if a field should be masked based on its Data Classification.
     *
     * @param dfr The DescribeFieldResult for the field to check
     * @return True if the field's classification matches one of the sensitive classifications
     */
    public Boolean shouldMaskField(Schema.DescribeFieldResult dfr) {
        if (dfr == null) {
            return false;
        }

        String objectName = dfr.getSObjectField().getDescribe().getSObjectType().getDescribe().getName();
        String fieldName = dfr.getName();

        return shouldMaskField(objectName, fieldName);
    }

    /**
     * @description Checks if a field should be masked by SObject type and field name.
     *
     * @param sObjectType The SObject type containing the field
     * @param fieldName The API name of the field
     * @return True if the field should be masked
     */
    public Boolean shouldMaskField(SObjectType sObjectType, String fieldName) {
        if (sObjectType == null || String.isBlank(fieldName)) {
            return false;
        }

        String objectName = sObjectType.getDescribe().getName();
        return shouldMaskField(objectName, fieldName);
    }

    /**
     * @description Checks if a field should be masked by object name and field name.
     *
     * @param objectName The API name of the SObject
     * @param fieldName The API name of the field
     * @return True if the field should be masked
     */
    public Boolean shouldMaskField(String objectName, String fieldName) {
        if (String.isBlank(objectName) || String.isBlank(fieldName)) {
            return false;
        }

        // Ensure field classifications are loaded for this object
        loadFieldClassifications(objectName);

        // Check cache for classification
        String cacheKey = objectName.toLowerCase() + '.' + fieldName.toLowerCase();
        String classification = fieldClassificationCache.get(cacheKey);

        // If classification is set, check if it's sensitive
        if (String.isNotBlank(classification)) {
            return this.sensitiveClassifications.contains(classification);
        }

        // Fallback to pattern matching if enabled and no classification
        if (this.useFallbackPatterns) {
            return matchesFallbackPattern(fieldName);
        }

        return false;
    }

    /**
     * @description Masks a field value and returns the token.
     * Uses 'FIELD_fieldName' as the pattern name for session tracking.
     *
     * @param value The field value to mask
     * @param fieldName The API name of the field (used in token generation)
     * @param session The masking session to use for token generation
     * @return The masked token, or the original value if null/blank
     */
    public String maskFieldValue(Object value, String fieldName, PIIMaskingSession session) {
        if (value == null || session == null) {
            return value != null ? String.valueOf(value) : null;
        }

        String stringValue = String.valueOf(value);
        if (String.isBlank(stringValue)) {
            return stringValue;
        }

        // Use field name as the pattern name for consistent token format
        String patternName = 'FIELD_' + (String.isNotBlank(fieldName) ? fieldName.toUpperCase() : 'UNKNOWN');
        return session.getOrCreateToken(stringValue, patternName);
    }

    /**
     * @description Gets the set of classifications configured for this masker.
     *
     * @return Set of classification names that trigger masking
     */
    public Set<String> getSensitiveClassifications() {
        return this.sensitiveClassifications.clone();
    }

    /**
     * @description Gets the default set of sensitive classifications.
     *
     * @return The default classifications (Confidential, Restricted)
     */
    public static Set<String> getDefaultSensitiveClassifications() {
        return DEFAULT_SENSITIVE_CLASSIFICATIONS.clone();
    }

    /**
     * @description Gets all available Salesforce Data Classification values.
     *
     * @return Set of all possible classification values
     */
    public static Set<String> getAllClassificationValues() {
        return new Set<String>{ 'Confidential', 'Restricted', 'MissionCritical', 'Internal', 'Public' };
    }

    /**
     * @description Analyzes an SObject and returns a map of field names to their classifications.
     * Useful for debugging and understanding what fields will be masked.
     *
     * @param sObjectType The SObject type to analyze
     * @return Map of field API names to their Data Classification values
     */
    public Map<String, String> analyzeObjectClassifications(SObjectType sObjectType) {
        Map<String, String> results = new Map<String, String>();

        if (sObjectType == null) {
            return results;
        }

        String objectName = sObjectType.getDescribe().getName();
        loadFieldClassifications(objectName);

        String prefix = objectName.toLowerCase() + '.';
        for (String cacheKey : fieldClassificationCache.keySet()) {
            if (cacheKey.startsWith(prefix)) {
                String classification = fieldClassificationCache.get(cacheKey);
                if (String.isNotBlank(classification)) {
                    String fieldName = cacheKey.substring(prefix.length());
                    results.put(fieldName, classification);
                }
            }
        }

        return results;
    }

    /**
     * @description Gets fields from an SObject type that would be masked by this masker.
     *
     * @param sObjectType The SObject type to analyze
     * @return Set of field API names that would be masked
     */
    public Set<String> getMaskedFields(SObjectType sObjectType) {
        Set<String> maskedFields = new Set<String>();

        if (sObjectType == null) {
            return maskedFields;
        }

        String objectName = sObjectType.getDescribe().getName();
        Map<String, Schema.SObjectField> fieldMap = sObjectType.getDescribe().fields.getMap();

        for (String fieldName : fieldMap.keySet()) {
            if (shouldMaskField(objectName, fieldName)) {
                maskedFields.add(fieldMap.get(fieldName).getDescribe().getName());
            }
        }

        return maskedFields;
    }

    /**
     * @description Clears the field classification cache.
     * Useful for testing or when classifications have been updated.
     */
    @TestVisible
    public static void clearCache() {
        fieldClassificationCache.clear();
        loadedObjects.clear();
    }

    // =========================================================================
    // PRIVATE METHODS
    // =========================================================================

    /**
     * @description Loads field classifications for an object from FieldDefinition.
     * Results are cached for performance.
     */
    private void loadFieldClassifications(String objectName) {
        if (String.isBlank(objectName) || loadedObjects.contains(objectName.toLowerCase())) {
            return;
        }

        try {
            // Query FieldDefinition for security classifications
            // Note: FieldDefinition requires the EntityDefinition ID or DeveloperName
            List<FieldDefinition> fields = [
                SELECT QualifiedApiName, SecurityClassification
                FROM FieldDefinition
                WHERE EntityDefinition.QualifiedApiName = :objectName
            ];

            for (FieldDefinition fd : fields) {
                String cacheKey = objectName.toLowerCase() + '.' + fd.QualifiedApiName.toLowerCase();
                fieldClassificationCache.put(cacheKey, fd.SecurityClassification);
            }

            loadedObjects.add(objectName.toLowerCase());

            System.debug(LoggingLevel.DEBUG, '[SchemaBasedMasker] Loaded ' + fields.size() + ' field classifications for ' + objectName);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[SchemaBasedMasker] Failed to load field classifications for ' + objectName + ': ' + e.getMessage());
            // Mark as loaded to avoid repeated failed queries
            loadedObjects.add(objectName.toLowerCase());
        }
    }

    /**
     * @description Checks if a field name matches any fallback sensitive patterns using regex word boundaries.
     * This prevents false positives like 'ssn' matching 'Classness__c' or 'dob' matching 'Adobe_Sign_Id__c'.
     */
    private Boolean matchesFallbackPattern(String fieldName) {
        if (String.isBlank(fieldName)) {
            return false;
        }

        // Check each pattern category
        for (Pattern p : fallbackSensitivePatterns.values()) {
            Matcher m = p.matcher(fieldName);
            if (m.find()) {
                return true;
            }
        }

        return false;
    }
}
