/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * PromptSafetyService is the core orchestrator for the Prompt Safety Trust Layer. It provides
 * multi-layered detection of jailbreak attempts and prompt injection attacks to protect AI
 * agents from malicious user inputs.
 *
 * Key Features:
 * - Multi-layered detection: Pattern-based, Heuristic, and Structural analysis
 * - Configurable response modes: Block, Sanitize, Flag, Log Only
 * - Configurable threat thresholds per agent
 * - Category filtering to enable/disable specific detection patterns
 * - Audit logging support for compliance and debugging
 * - Factory method for easy agent configuration
 *
 * Detection Layers:
 * 1. Pattern-Based (JailbreakPatternMatcher): Regex patterns from JailbreakPattern__mdt
 * 2. Heuristic (PromptHeuristicAnalyzer): Semantic analysis of instruction patterns
 * 3. Structural (PromptStructureAnalyzer): Content structure, encoding, N-gram similarity
 *
 * Response Modes:
 * - Block: Reject the request entirely with a safe error message
 * - Sanitize: Remove/neutralize detected threats and continue
 * - Flag: Mark for human review but continue processing
 * - LogOnly: Record threat details but take no action
 *
 * Part of the Prompt Safety Trust Layer for AI safety.
 *
 * @example
 * // Create service for an agent
 * AIAgentDefinition__c agent = [SELECT ... FROM AIAgentDefinition__c WHERE ...];
 * PromptSafetyService service = PromptSafetyService.createForAgent(agent);
 *
 * // Check user message
 * ThreatAssessment assessment = service.checkMessage(userMessage);
 * if (assessment.shouldBlock()) {
 *     // Block the request
 *     return assessment.getSafeMessage();
 * }
 */
public inherited sharing class PromptSafetyService {
    // Response mode constants
    public static final String MODE_BLOCK = 'Block';
    public static final String MODE_SANITIZE = 'Sanitize';
    public static final String MODE_FLAG = 'Flag';
    public static final String MODE_LOG_ONLY = 'LogOnly';
    private static final String PRESET_OFF = 'Off';
    private static final String PRESET_STANDARD = 'Standard';
    private static final String PRESET_STRICT = 'Strict';

    // Detection layer weight constants
    private static final Decimal WEIGHT_PATTERN = 0.4;
    private static final Decimal WEIGHT_HEURISTIC = 0.35;
    private static final Decimal WEIGHT_STRUCTURAL = 0.25;
    private static final Decimal DEFAULT_THRESHOLD = 0.6;
    private static final Decimal EARLY_EXIT_PATTERN_SCORE = 0.85;

    @TestVisible
    private static Map<String, CacheEntry> messageCache = new Map<String, CacheEntry>();

    // Detection layers
    private JailbreakPatternMatcher patternMatcher;
    private PromptHeuristicAnalyzer heuristicAnalyzer;
    private PromptStructureAnalyzer structureAnalyzer;

    // Configuration
    private Boolean isEnabled;
    private String responseMode;
    private Decimal threshold;
    private Boolean auditLoggingEnabled;
    private Id executionId;
    private class CacheEntry {
        public Decimal overallScore;
        public List<ThreatAssessment.ThreatIndicator> indicators;
        public Boolean earlyExit;
    }

    // Logging prefix
    private static final String LOG_PREFIX = '[PromptSafetyService] ';

    /**
     * @description Creates a safety service with default configuration.
     * Uses Block mode with 0.6 threshold and all pattern categories.
     */
    public PromptSafetyService() {
        this(MODE_BLOCK, 0.6, null, null);
    }

    /**
     * @description Creates a safety service with specified configuration.
     *
     * @param responseMode The response mode (Block, Sanitize, Flag, LogOnly)
     * @param threshold The threat score threshold for triggering action (0.0-1.0)
     * @param patternCategories Set of pattern categories to enable (null = all)
     * @param executionId Optional execution ID for context tracking
     */
    public PromptSafetyService(String responseMode, Decimal threshold, Set<String> patternCategories, Id executionId) {
        this.isEnabled = true;
        this.responseMode = String.isNotBlank(responseMode) ? responseMode : MODE_BLOCK;
        this.threshold = normalizeThreshold(threshold);
        this.executionId = executionId;
        this.auditLoggingEnabled = false;

        // Initialize detection layers
        this.patternMatcher = new JailbreakPatternMatcher(patternCategories);
        this.heuristicAnalyzer = new PromptHeuristicAnalyzer();
        this.structureAnalyzer = new PromptStructureAnalyzer();

        System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Service initialized. Mode: ' + this.responseMode + ', Threshold: ' + this.threshold);
    }

    /**
     * @description Factory method to create a PromptSafetyService configured for an agent.
     * Reads configuration from AIAgentDefinition__c fields.
     *
     * @param agentConfig The agent definition record
     * @return Configured PromptSafetyService, or null if safety is disabled
     */
    public static PromptSafetyService createForAgent(AIAgentDefinition__c agentConfig) {
        return createForAgent(agentConfig, null);
    }

    /**
     * @description Factory method with execution context.
     *
     * @param agentConfig The agent definition record
     * @param executionId The execution ID for context tracking
     * @return Configured PromptSafetyService, or null if safety is disabled
     */
    public static PromptSafetyService createForAgent(AIAgentDefinition__c agentConfig, Id executionId) {
        if (agentConfig == null) {
            return null;
        }

        String preset = normalizePreset(agentConfig.PromptSafetyPreset__c);
        if (preset == PRESET_OFF) {
            System.debug(LoggingLevel.DEBUG, LOG_PREFIX + 'Prompt safety disabled by preset');
            return null;
        }

        String mode = preset == PRESET_STRICT ? MODE_BLOCK : MODE_LOG_ONLY;
        Decimal threshold = DEFAULT_THRESHOLD;
        Set<String> patternCategories = preset == PRESET_STANDARD ? getStandardPatternCategories() : null;

        PromptSafetyService service = new PromptSafetyService(mode, threshold, patternCategories, executionId);

        // Audit logging always on for preset-driven safety
        service.auditLoggingEnabled = true;

        System.debug(
            LoggingLevel.INFO,
            LOG_PREFIX + 'Created service for agent: ' + agentConfig.DeveloperName__c + ', Preset: ' + preset + ', Mode: ' + mode + ', Threshold: ' + threshold
        );

        return service;
    }

    // =========================================================================
    // MESSAGE CHECKING METHODS
    // =========================================================================

    /**
     * @description Checks a user message for jailbreak/injection attempts.
     * This is the primary method for message safety analysis.
     *
     * @param message The user message to check
     * @return ThreatAssessment containing analysis results and recommended action
     */
    public ThreatAssessment checkMessage(String message) {
        Long startTime = System.currentTimeMillis();

        if (!this.isEnabled || String.isBlank(message)) {
            return ThreatAssessment.safe(message);
        }

        CacheEntry cached = getCachedAssessment(message);
        if (cached != null) {
            ThreatAssessment assessment = ThreatAssessment.fromAnalysis(message, cached.overallScore, cloneIndicators(cached.indicators));
            assessment.withEarlyExit(cached.earlyExit);
            assessment.applyResponseMode(this.responseMode, this.threshold);
            Long processingTime = System.currentTimeMillis() - startTime;
            assessment.withProcessingTime(processingTime);
            if (this.auditLoggingEnabled) {
                logAssessment(assessment);
            }
            return assessment;
        }

        // Run all detection layers
        List<ThreatAssessment.ThreatIndicator> allIndicators = new List<ThreatAssessment.ThreatIndicator>();

        // Layer 1: Pattern-based detection
        Decimal patternScore = runPatternDetection(message, allIndicators);

        // Early exit for high-confidence pattern detection
        Boolean earlyExit = shouldEarlyExit(patternScore);

        // Layer 2: Heuristic analysis
        Decimal heuristicScore = 0.0;
        if (!earlyExit) {
            heuristicScore = runHeuristicAnalysis(message, allIndicators);
        }

        // Layer 3: Structural analysis
        Decimal structuralScore = 0.0;
        if (!earlyExit) {
            structuralScore = runStructuralAnalysis(message, allIndicators);
        }

        // Calculate aggregate score
        // If we early-exit on high-confidence pattern detection, use the pattern score directly
        // so the response mode can block as expected.
        Decimal aggregateScore = earlyExit
            ? (patternScore != null ? Math.min(1.0, patternScore) : 0.0)
            : calculateAggregateScore(patternScore, heuristicScore, structuralScore);

        // Create threat assessment
        ThreatAssessment assessment = ThreatAssessment.fromAnalysis(message, aggregateScore, allIndicators);
        if (earlyExit) {
            assessment.withEarlyExit(true);
        }

        cacheAssessment(message, assessment);

        // Apply response mode
        assessment.applyResponseMode(this.responseMode, this.threshold);

        // Set processing time
        Long processingTime = System.currentTimeMillis() - startTime;
        assessment.withProcessingTime(processingTime);

        // Audit logging
        if (this.auditLoggingEnabled) {
            logAssessment(assessment);
        }

        System.debug(
            LoggingLevel.INFO,
            LOG_PREFIX +
                'Message checked. Score: ' +
                aggregateScore +
                ', Level: ' +
                assessment.levelName +
                ', Action: ' +
                assessment.recommendedAction +
                ', Time: ' +
                processingTime +
                'ms'
        );

        return assessment;
    }

    /**
     * @description Quick check if a message contains any threats.
     * More efficient than full checkMessage() when you only need a boolean result.
     *
     * @param message The user message to check
     * @return True if any threat indicators are detected
     */
    public Boolean containsThreats(String message) {
        if (!this.isEnabled || String.isBlank(message)) {
            return false;
        }

        // Quick pattern check first (fastest)
        if (this.patternMatcher.containsJailbreakPattern(message)) {
            return true;
        }

        // Full analysis for more sophisticated detection
        ThreatAssessment assessment = checkMessage(message);
        return assessment.hasThreats();
    }

    // =========================================================================
    // DETECTION LAYER METHODS
    // =========================================================================

    /**
     * @description Runs pattern-based detection and adds indicators.
     */
    private Decimal runPatternDetection(String message, List<ThreatAssessment.ThreatIndicator> indicators) {
        List<JailbreakPatternMatcher.PatternMatch> matches = this.patternMatcher.findMatches(message);

        for (JailbreakPatternMatcher.PatternMatch match : matches) {
            ThreatAssessment.ThreatIndicator indicator = new ThreatAssessment.ThreatIndicator(
                'Pattern',
                match.category,
                match.patternName,
                match.description != null ? match.description : 'Pattern match: ' + match.patternName,
                match.severity
            );
            indicator.withMatchDetails(redactIfNeeded(match.matchedValue), match.startIndex, match.endIndex);
            indicators.add(indicator);
        }

        return this.patternMatcher.calculateAggregatedSeverity(matches);
    }

    /**
     * @description Runs heuristic analysis and adds indicators.
     */
    private Decimal runHeuristicAnalysis(String message, List<ThreatAssessment.ThreatIndicator> indicators) {
        PromptHeuristicAnalyzer.AnalysisResult result = this.heuristicAnalyzer.analyze(message);

        if (result.indicators != null) {
            indicators.addAll(result.indicators);
        }

        return result.aggregatedScore;
    }

    /**
     * @description Runs structural analysis and adds indicators.
     */
    private Decimal runStructuralAnalysis(String message, List<ThreatAssessment.ThreatIndicator> indicators) {
        PromptStructureAnalyzer.AnalysisResult result = this.structureAnalyzer.analyze(message);

        if (result.indicators != null) {
            indicators.addAll(result.indicators);
        }

        return result.aggregatedScore;
    }

    /**
     * @description Calculates the weighted aggregate score from all layers.
     */
    private Decimal calculateAggregateScore(Decimal patternScore, Decimal heuristicScore, Decimal structuralScore) {
        // Weighted combination
        Decimal weightedSum =
            (patternScore != null ? patternScore : 0) * WEIGHT_PATTERN +
            (heuristicScore != null ? heuristicScore : 0) * WEIGHT_HEURISTIC +
            (structuralScore != null ? structuralScore : 0) * WEIGHT_STRUCTURAL;

        // Normalize by total weight
        Decimal totalWeight = WEIGHT_PATTERN + WEIGHT_HEURISTIC + WEIGHT_STRUCTURAL;
        Decimal normalizedScore = weightedSum / totalWeight;

        // Boost if multiple layers detect threats (ensemble effect)
        Integer detectingLayers = 0;
        if (patternScore != null && patternScore > 0.3)
            detectingLayers++;
        if (heuristicScore != null && heuristicScore > 0.3)
            detectingLayers++;
        if (structuralScore != null && structuralScore > 0.3)
            detectingLayers++;

        if (detectingLayers >= 2) {
            // Boost score by 20% if multiple layers agree
            normalizedScore = normalizedScore * 1.2;
        }

        return Math.min(1.0, normalizedScore);
    }

    // =========================================================================
    // CONFIGURATION AND STATUS METHODS
    // =========================================================================

    /**
     * @description Checks if the service is enabled.
     *
     * @return True if safety checking is enabled
     */
    public Boolean isEnabled() {
        return this.isEnabled;
    }

    /**
     * @description Gets the current response mode.
     *
     * @return The response mode (Block, Sanitize, Flag, LogOnly)
     */
    public String getResponseMode() {
        return this.responseMode;
    }

    /**
     * @description Gets the current threat threshold.
     *
     * @return The threshold value (0.0-1.0)
     */
    public Decimal getThreshold() {
        return this.threshold;
    }

    /**
     * @description Gets whether audit logging is enabled for this service.
     */
    public Boolean isAuditLoggingEnabled() {
        return this.auditLoggingEnabled;
    }

    /**
     * @description Gets service statistics for monitoring.
     *
     * @return Map of statistics
     */
    public Map<String, Object> getStatistics() {
        return new Map<String, Object>{
            'enabled' => this.isEnabled,
            'responseMode' => this.responseMode,
            'threshold' => this.threshold,
            'auditLogging' => this.auditLoggingEnabled,
            'patternCount' => this.patternMatcher.getPatternCount(),
            'executionId' => this.executionId
        };
    }

    // =========================================================================
    // HELPER METHODS
    // =========================================================================

    /**
     * @description Parses response mode from string.
     */
    private static String parseResponseMode(String modeString) {
        if (String.isBlank(modeString)) {
            return MODE_BLOCK;
        }

        String normalized = modeString.trim();

        if (normalized.equalsIgnoreCase('Sanitize')) {
            return MODE_SANITIZE;
        } else if (normalized.equalsIgnoreCase('Flag') || normalized.containsIgnoreCase('Review')) {
            return MODE_FLAG;
        } else if (normalized.equalsIgnoreCase('LogOnly') || normalized.equalsIgnoreCase('Log Only')) {
            return MODE_LOG_ONLY;
        }

        System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Unknown prompt safety mode "' + modeString + '". Defaulting to Block.');
        return MODE_BLOCK;
    }

    private static String normalizePreset(String presetValue) {
        if (String.isBlank(presetValue)) {
            return PRESET_STANDARD;
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

    private static Set<String> getStandardPatternCategories() {
        return new Set<String>{ 'RoleManipulation', 'InstructionOverride', 'PromptLeaking' };
    }

    /**
     * @description Parses a semicolon-separated multi-select picklist value to a Set.
     */
    private static Set<String> parseMultiSelectPicklist(String picklistValue) {
        if (String.isBlank(picklistValue)) {
            return null;
        }

        Set<String> values = new Set<String>();
        for (String value : picklistValue.split(';')) {
            String trimmed = value.trim();
            if (String.isNotBlank(trimmed)) {
                values.add(trimmed);
            }
        }

        return values.isEmpty() ? null : values;
    }

    /**
     * @description Redacts sensitive matched content for logging.
     */
    private String redactIfNeeded(String matchedValue) {
        if (String.isBlank(matchedValue)) {
            return matchedValue;
        }

        // Truncate long matches
        if (matchedValue.length() > 50) {
            return matchedValue.substring(0, 47) + '...';
        }

        return matchedValue;
    }

    /**
     * @description Logs assessment details for audit purposes.
     */
    private void logAssessment(ThreatAssessment assessment) {
        Map<String, Object> summary = assessment.getSummary();
        System.debug(LoggingLevel.INFO, LOG_PREFIX + 'AUDIT: ' + JSON.serialize(summary));
    }

    /**
     * @description Normalizes threat threshold to a safe range.
     */
    private static Decimal normalizeThreshold(Decimal rawThreshold) {
        if (rawThreshold == null) {
            return DEFAULT_THRESHOLD;
        }
        if (rawThreshold < 0 || rawThreshold > 1) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Invalid threshold value (' + rawThreshold + '). Falling back to default: ' + DEFAULT_THRESHOLD);
            return DEFAULT_THRESHOLD;
        }
        return rawThreshold;
    }

    /**
     * @description Determines if we can early-exit after pattern detection.
     */
    private Boolean shouldEarlyExit(Decimal patternScore) {
        return patternScore != null && patternScore >= EARLY_EXIT_PATTERN_SCORE;
    }

    private CacheEntry getCachedAssessment(String message) {
        String cacheKey = buildCacheKey(message);
        return messageCache.get(cacheKey);
    }

    private void cacheAssessment(String message, ThreatAssessment assessment) {
        String cacheKey = buildCacheKey(message);
        CacheEntry entry = new CacheEntry();
        entry.overallScore = assessment.overallScore;
        entry.indicators = cloneIndicators(assessment.indicators);
        entry.earlyExit = assessment.earlyExit == true;
        messageCache.put(cacheKey, entry);
    }

    private String buildCacheKey(String message) {
        String categoriesKey = '';
        Set<String> enabledCategories = this.patternMatcher.getEnabledCategories();
        if (enabledCategories != null && !enabledCategories.isEmpty()) {
            List<String> sorted = new List<String>(enabledCategories);
            sorted.sort();
            categoriesKey = String.join(sorted, ',');
        }

        String rawKey = String.valueOf(this.executionId) + '|' + this.responseMode + '|' + this.threshold + '|' + categoriesKey + '|' + message;
        Blob hashBlob = Crypto.generateDigest('SHA-256', Blob.valueOf(rawKey));
        return EncodingUtil.convertToHex(hashBlob);
    }

    private List<ThreatAssessment.ThreatIndicator> cloneIndicators(List<ThreatAssessment.ThreatIndicator> indicators) {
        List<ThreatAssessment.ThreatIndicator> cloned = new List<ThreatAssessment.ThreatIndicator>();
        if (indicators == null) {
            return cloned;
        }
        for (ThreatAssessment.ThreatIndicator indicator : indicators) {
            if (indicator == null) {
                continue;
            }
            ThreatAssessment.ThreatIndicator copy = new ThreatAssessment.ThreatIndicator(
                indicator.indicatorType,
                indicator.category,
                indicator.name,
                indicator.description,
                indicator.score
            );
            copy.matchedContent = indicator.matchedContent;
            copy.startIndex = indicator.startIndex;
            copy.endIndex = indicator.endIndex;
            cloned.add(copy);
        }
        return cloned;
    }

    @TestVisible
    private static void clearMessageCache() {
        messageCache.clear();
    }

    @TestVisible
    private static Integer getMessageCacheSize() {
        return messageCache.size();
    }
}
