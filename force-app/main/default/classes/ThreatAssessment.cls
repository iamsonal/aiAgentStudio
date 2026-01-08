/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ThreatAssessment is the result DTO from PromptSafetyService analysis. It contains
 * the aggregated threat score, threat level classification, individual indicators
 * detected, and the recommended action based on the agent's configuration.
 *
 * Key Features:
 * - Aggregated scoring from multiple detection layers (pattern, heuristic, structural)
 * - Threat level classification (NONE, LOW, MEDIUM, HIGH, CRITICAL)
 * - Detailed threat indicators for audit and debugging
 * - Recommended action based on threat level and agent configuration
 * - Sanitized content when applicable
 *
 * Part of the Prompt Safety Trust Layer for AI safety.
 *
 * @example
 * ThreatAssessment assessment = safetyService.analyze(userMessage);
 * if (assessment.shouldBlock()) {
 *     // Block the request
 * } else if (assessment.hasSanitizedContent()) {
 *     userMessage = assessment.getSanitizedContent();
 * }
 */
public class ThreatAssessment {
    /**
     * Threat level enumeration representing the severity of detected threats.
     * Used to determine the appropriate response action.
     */
    public enum ThreatLevel {
        NONE, // No threat detected (score 0.0 - 0.2)
        LOW, // Minor suspicious patterns (score 0.2 - 0.4)
        MEDIUM, // Potential attack indicators (score 0.4 - 0.6)
        HIGH, // Likely attack attempt (score 0.6 - 0.8)
        CRITICAL // Definite attack attempt (score 0.8 - 1.0)
    }

    /**
     * Represents a single threat indicator detected during analysis.
     */
    public class ThreatIndicator {
        @AuraEnabled
        public String indicatorType { get; set; } // Pattern, Heuristic, Structural
        @AuraEnabled
        public String category { get; set; } // E.g., RoleManipulation, InstructionOverride
        @AuraEnabled
        public String name { get; set; } // Pattern name or heuristic name
        @AuraEnabled
        public String description { get; set; } // Human-readable description
        @AuraEnabled
        public Decimal score { get; set; } // Score contribution (0.0-1.0)
        @AuraEnabled
        public String matchedContent { get; set; } // The content that triggered this indicator (may be redacted)
        @AuraEnabled
        public Integer startIndex { get; set; } // Position in original text
        @AuraEnabled
        public Integer endIndex { get; set; } // End position in original text

        public ThreatIndicator() {
        }

        public ThreatIndicator(String indicatorType, String category, String name, String description, Decimal score) {
            this.indicatorType = indicatorType;
            this.category = category;
            this.name = name;
            this.description = description;
            this.score = score;
        }

        public ThreatIndicator withMatchDetails(String matchedContent, Integer startIndex, Integer endIndex) {
            this.matchedContent = matchedContent;
            this.startIndex = startIndex;
            this.endIndex = endIndex;
            return this;
        }
    }

    // =========================================================================
    // PROPERTIES
    // =========================================================================

    /** The aggregated threat score from all detection layers (0.0 to 1.0) */
    @AuraEnabled
    public Decimal overallScore { get; private set; }

    /** The classified threat level based on the overall score */
    @AuraEnabled
    public ThreatLevel level { get; private set; }

    /** String representation of threat level for serialization */
    @AuraEnabled
    public String levelName {
        get {
            return this.level != null ? this.level.name() : 'NONE';
        }
    }

    /** List of all threat indicators detected during analysis */
    @AuraEnabled
    public List<ThreatIndicator> indicators { get; private set; }

    /** The recommended action based on threat level and configuration */
    @AuraEnabled
    public String recommendedAction { get; private set; }

    /** Whether the input should be blocked based on the assessment */
    @AuraEnabled
    public Boolean blocked { get; private set; }

    /** Whether the input was flagged for review */
    @AuraEnabled
    public Boolean flagged { get; private set; }

    /** Sanitized content if applicable (original with threats neutralized) */
    private String sanitizedContent;

    /** Original content before analysis */
    private String originalContent;

    /** The configured threshold that was used for this assessment */
    @AuraEnabled
    public Decimal configuredThreshold { get; private set; }

    /** Processing time in milliseconds */
    @AuraEnabled
    public Long processingTimeMs { get; private set; }

    /** Safe message to return to user when blocked */
    private String safeBlockMessage;

    // =========================================================================
    // CONSTRUCTORS
    // =========================================================================

    /**
     * Private constructor - use factory methods.
     */
    private ThreatAssessment() {
        this.indicators = new List<ThreatIndicator>();
        this.overallScore = 0.0;
        this.level = ThreatLevel.NONE;
        this.blocked = false;
        this.flagged = false;
    }

    // =========================================================================
    // FACTORY METHODS
    // =========================================================================

    /**
     * Creates a safe (no threat) assessment.
     *
     * @param originalContent The original content that was analyzed
     * @return ThreatAssessment with NONE threat level
     */
    public static ThreatAssessment safe(String originalContent) {
        ThreatAssessment assessment = new ThreatAssessment();
        assessment.originalContent = originalContent;
        assessment.overallScore = 0.0;
        assessment.level = ThreatLevel.NONE;
        assessment.recommendedAction = 'ALLOW';
        return assessment;
    }

    /**
     * Creates an assessment with the specified score and indicators.
     *
     * @param originalContent The original content that was analyzed
     * @param score The aggregated threat score (0.0-1.0)
     * @param indicators List of detected threat indicators
     * @return ThreatAssessment with calculated threat level
     */
    public static ThreatAssessment fromAnalysis(String originalContent, Decimal score, List<ThreatIndicator> indicators) {
        ThreatAssessment assessment = new ThreatAssessment();
        assessment.originalContent = originalContent;
        assessment.overallScore = score != null ? Math.min(1.0, Math.max(0.0, score)) : 0.0;
        assessment.indicators = indicators != null ? indicators : new List<ThreatIndicator>();
        assessment.level = calculateThreatLevel(assessment.overallScore);
        return assessment;
    }

    // =========================================================================
    // PUBLIC METHODS
    // =========================================================================

    /**
     * Applies the configured response mode and threshold to determine actions.
     *
     * @param responseMode The configured response mode (Block, Sanitize, Flag, LogOnly)
     * @param threshold The score threshold for triggering action
     * @return This assessment with actions applied
     */
    public ThreatAssessment applyResponseMode(String responseMode, Decimal threshold) {
        this.configuredThreshold = threshold != null ? threshold : 0.6;

        Boolean exceedsThreshold = this.overallScore >= this.configuredThreshold;

        if (!exceedsThreshold) {
            this.recommendedAction = 'ALLOW';
            this.blocked = false;
            this.flagged = false;
            return this;
        }

        // Apply response mode
        if (responseMode == 'Block') {
            this.blocked = true;
            this.recommendedAction = 'BLOCK';
            this.safeBlockMessage = generateSafeBlockMessage();
        } else if (responseMode == 'Sanitize') {
            this.recommendedAction = 'SANITIZE';
            this.sanitizedContent = sanitizeContent(this.originalContent);
        } else if (responseMode == 'Flag') {
            this.flagged = true;
            this.recommendedAction = 'FLAG';
        } else {
            // LogOnly or unknown - allow but log
            this.recommendedAction = 'LOG';
        }

        return this;
    }

    /**
     * Sets the processing time for this assessment.
     *
     * @param ms Processing time in milliseconds
     * @return This assessment for method chaining
     */
    public ThreatAssessment withProcessingTime(Long ms) {
        this.processingTimeMs = ms;
        return this;
    }

    /**
     * Checks if the input should be blocked.
     *
     * @return True if the assessment indicates blocking
     */
    public Boolean shouldBlock() {
        return this.blocked == true;
    }

    /**
     * Checks if sanitized content is available.
     *
     * @return True if sanitized content was generated
     */
    public Boolean hasSanitizedContent() {
        return String.isNotBlank(this.sanitizedContent);
    }

    /**
     * Gets the sanitized content if available.
     *
     * @return Sanitized content, or original if not sanitized
     */
    public String getSanitizedContent() {
        return String.isNotBlank(this.sanitizedContent) ? this.sanitizedContent : this.originalContent;
    }

    /**
     * Gets a safe message to return to the user when blocked.
     *
     * @return User-friendly block message
     */
    public String getSafeMessage() {
        return String.isNotBlank(this.safeBlockMessage)
            ? this.safeBlockMessage
            : 'Your request could not be processed due to safety concerns. Please rephrase your question.';
    }

    /**
     * Checks if any threats were detected (regardless of action taken).
     *
     * @return True if any indicators were detected
     */
    public Boolean hasThreats() {
        return this.indicators != null && !this.indicators.isEmpty();
    }

    /**
     * Gets the count of threat indicators.
     *
     * @return Number of indicators detected
     */
    public Integer getIndicatorCount() {
        return this.indicators != null ? this.indicators.size() : 0;
    }

    /**
     * Gets indicators filtered by category.
     *
     * @param category The category to filter by
     * @return List of indicators in the specified category
     */
    public List<ThreatIndicator> getIndicatorsByCategory(String category) {
        List<ThreatIndicator> filtered = new List<ThreatIndicator>();
        if (this.indicators != null && String.isNotBlank(category)) {
            for (ThreatIndicator indicator : this.indicators) {
                if (indicator.category == category) {
                    filtered.add(indicator);
                }
            }
        }
        return filtered;
    }

    /**
     * Gets a summary of the assessment for logging/audit purposes.
     * Does not include potentially sensitive content.
     *
     * @return Map of summary statistics
     */
    public Map<String, Object> getSummary() {
        Map<String, Object> summary = new Map<String, Object>();
        summary.put('overallScore', this.overallScore);
        summary.put('threatLevel', this.levelName);
        summary.put('indicatorCount', this.getIndicatorCount());
        summary.put('recommendedAction', this.recommendedAction);
        summary.put('blocked', this.blocked);
        summary.put('flagged', this.flagged);
        summary.put('configuredThreshold', this.configuredThreshold);
        summary.put('processingTimeMs', this.processingTimeMs);

        // Summarize indicators by category (without sensitive content)
        Map<String, Integer> categoryCount = new Map<String, Integer>();
        if (this.indicators != null) {
            for (ThreatIndicator indicator : this.indicators) {
                String cat = indicator.category != null ? indicator.category : 'Unknown';
                Integer count = categoryCount.get(cat);
                categoryCount.put(cat, (count != null ? count : 0) + 1);
            }
        }
        summary.put('indicatorsByCategory', categoryCount);

        return summary;
    }

    // =========================================================================
    // PRIVATE HELPER METHODS
    // =========================================================================

    /**
     * Calculates the threat level based on the overall score.
     */
    private static ThreatLevel calculateThreatLevel(Decimal score) {
        if (score == null || score < 0.2) {
            return ThreatLevel.NONE;
        } else if (score < 0.4) {
            return ThreatLevel.LOW;
        } else if (score < 0.6) {
            return ThreatLevel.MEDIUM;
        } else if (score < 0.8) {
            return ThreatLevel.HIGH;
        } else {
            return ThreatLevel.CRITICAL;
        }
    }

    /**
     * Generates a safe, user-friendly block message based on the threat indicators.
     */
    private String generateSafeBlockMessage() {
        // Don't reveal specific detection details that could help attackers
        if (this.level == ThreatLevel.CRITICAL) {
            return 'Your message could not be processed. Please rephrase your question in a different way.';
        } else {
            return 'Your request triggered our safety systems. Please try asking your question differently.';
        }
    }

    /**
     * Sanitizes the content by neutralizing detected threats.
     * This is a basic implementation - subclasses can override for more sophisticated sanitization.
     */
    private String sanitizeContent(String content) {
        if (String.isBlank(content) || this.indicators == null || this.indicators.isEmpty()) {
            return content;
        }

        String sanitized = content;

        // Sort indicators by startIndex descending to process from end to start
        List<ThreatIndicator> sortedIndicators = new List<ThreatIndicator>();
        for (ThreatIndicator ind : this.indicators) {
            if (ind.startIndex != null && ind.endIndex != null && ind.startIndex >= 0 && ind.endIndex <= sanitized.length()) {
                sortedIndicators.add(ind);
            }
        }
        sortedIndicators.sort(new ThreatIndicatorComparator());

        // Replace detected threats with safe placeholder
        for (ThreatIndicator indicator : sortedIndicators) {
            if (indicator.startIndex != null && indicator.endIndex != null) {
                String before = sanitized.substring(0, indicator.startIndex);
                String after = sanitized.substring(indicator.endIndex);
                sanitized = before + '[REMOVED]' + after;
            }
        }

        return sanitized;
    }

    /**
     * Comparator to sort threat indicators by position (descending).
     */
    private class ThreatIndicatorComparator implements Comparator<ThreatIndicator> {
        public Integer compare(ThreatIndicator a, ThreatIndicator b) {
            Integer aStart = a.startIndex != null ? a.startIndex : 0;
            Integer bStart = b.startIndex != null ? b.startIndex : 0;
            return bStart - aStart; // Descending order
        }
    }

    /**
     * Override toString for debugging.
     */
    public override String toString() {
        return String.format(
            'ThreatAssessment[score={0}, level={1}, indicators={2}, action={3}]',
            new List<String>{ String.valueOf(this.overallScore), this.levelName, String.valueOf(this.getIndicatorCount()), this.recommendedAction }
        );
    }
}
