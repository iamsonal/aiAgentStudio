/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

 /**
 * @description
 * PromptInjectionGuard provides comprehensive protection against indirect prompt injection attacks
 * in AI Agent contexts. It analyzes text content for malicious patterns, sanitizes dangerous content,
 * and provides structured data formatting that prevents LLM prompt hijacking.
 *
 * Key Features:
 * - Pattern-based detection of common prompt injection techniques
 * - Configurable security policies via custom metadata
 * - Content sanitization with preservation of legitimate business data
 * - Structured output formatting that isolates user content from system prompts
 * - Comprehensive logging and monitoring of potential threats
 *
 * Security Approach:
 * - Defense in depth with multiple detection layers
 * - Fail-safe defaults (block suspicious content when in doubt)
 * - Configurable sensitivity levels for different data sources
 * - Audit trail for all security decisions
 */
public inherited sharing class PromptInjectionGuard {
    // Performance optimization: Content analysis result cache
    private static final Integer MAX_CACHE_SIZE = 1000;
    private static final Integer CACHE_TTL_MINUTES = 30;
    private static Map<String, CachedAnalysisResult> analysisCache = new Map<String, CachedAnalysisResult>();
    private static List<String> cacheAccessOrder = new List<String>(); // LRU tracking

    /**
     * Cached analysis result with TTL support
     */
    private class CachedAnalysisResult {
        public SecurityAnalysisResult result;
        public DateTime cachedAt;
        public Integer accessCount;

        public CachedAnalysisResult(SecurityAnalysisResult result) {
            this.result = result;
            this.cachedAt = System.now();
            this.accessCount = 1;
        }

        public Boolean isExpired() {
            return this.cachedAt.addMinutes(CACHE_TTL_MINUTES) < System.now();
        }

        public void recordAccess() {
            this.accessCount++;
        }
    }

    // Threat detection patterns (configurable via custom metadata)
    private static final List<String> HIGH_RISK_PATTERNS = new List<String>{
        '(?i)ignore\\s+(all\\s+)?(previous|above|prior)\\s+(instructions?|prompts?|rules?)',
        '(?i)(forget|disregard|override)\\s+(everything|all)\\s+(above|before|previous)',
        '(?i)you\\s+are\\s+(now|actually)\\s+a\\s+',
        '(?i)new\\s+(instructions?|task|role|persona)',
        '(?i)system\\s*:\\s*',
        '(?i)assistant\\s*:\\s*',
        '(?i)\\[\\s*(system|user|assistant)\\s*\\]',
        '(?i)act\\s+as\\s+(if\\s+you\\s+are\\s+)?a\\s+',
        '(?i)pretend\\s+(to\\s+be|you\\s+are)\\s+',
        '(?i)roleplay\\s+as\\s+',
        '(?i)\\*\\*\\*\\s*(new|updated)\\s+(instructions?|rules?)\\s*\\*\\*\\*'
    };

    private static final List<String> MEDIUM_RISK_PATTERNS = new List<String>{
        '(?i)\\b(execute|run|perform)\\s+(this|the\\s+following)\\s+(command|instruction|task)',
        '(?i)\\b(tell|show|give)\\s+me\\s+(everything|all)\\s+(about|from)',
        '(?i)\\b(reveal|expose|display)\\s+(all|any)\\s+(data|information|records)',
        '(?i)\\b(bypass|skip|ignore)\\s+(security|validation|checks?)',
        '(?i)\\b(admin|administrator|root|superuser)\\s+(access|privileges?|rights?)',
        '(?i)\\b(delete|remove|drop)\\s+(all|everything|database|table)',
        '(?i)\\b(grant|give)\\s+me\\s+(access|permission|rights?)'
    };

    // Content isolation markers
    private static final String SAFE_CONTENT_PREFIX = '[USER_DATA]';
    private static final String SAFE_CONTENT_SUFFIX = '[/USER_DATA]';

    /**
     * Security policy configuration loaded from custom metadata
     */
    public class SecurityPolicy {
        public String policyName;
        public String securityLevel; // STRICT, MODERATE, PERMISSIVE
        public Boolean enablePatternDetection;
        public Boolean enableContentIsolation;
        public Boolean enableAuditLogging;
        public Set<String> exemptFields;
        public Set<String> highRiskSObjects;

        public SecurityPolicy() {
            this.securityLevel = 'MODERATE';
            this.enablePatternDetection = true;
            this.enableContentIsolation = true;
            this.enableAuditLogging = true;
            this.exemptFields = new Set<String>();
            this.highRiskSObjects = new Set<String>();
        }
    }

    /**
     * Result of security analysis on content
     */
    public class SecurityAnalysisResult {
        public Boolean isSafe;
        public String riskLevel; // LOW, MEDIUM, HIGH, CRITICAL
        public List<String> detectedPatterns;
        public String sanitizedContent;
        public String isolatedContent;
        public Map<String, Object> metadata;

        public SecurityAnalysisResult() {
            this.isSafe = true;
            this.riskLevel = 'LOW';
            this.detectedPatterns = new List<String>();
            this.metadata = new Map<String, Object>();
        }

        /**
         * Creates a deep copy of this SecurityAnalysisResult for caching purposes
         *
         * @return A new SecurityAnalysisResult with copied values
         */
        public SecurityAnalysisResult deepCopy() {
            SecurityAnalysisResult copied = new SecurityAnalysisResult();
            copied.isSafe = this.isSafe;
            copied.riskLevel = this.riskLevel;
            copied.detectedPatterns = new List<String>(this.detectedPatterns);
            copied.sanitizedContent = this.sanitizedContent;
            copied.isolatedContent = this.isolatedContent;
            copied.metadata = new Map<String, Object>(this.metadata);
            return copied;
        }
    }

    private static SecurityPolicy defaultPolicy;
    private static Map<String, SecurityPolicy> policyCache = new Map<String, SecurityPolicy>();

    /**
     * Analyzes content for prompt injection threats and returns security assessment
     *
     * @param content The text content to analyze
     * @param fieldName The field name containing the content
     * @param sObjectType The SObject type containing the field
     * @param policyName Optional security policy name (uses default if null)
     * @return SecurityAnalysisResult with threat assessment and sanitized content
     */
    public static SecurityAnalysisResult analyzeContent(String content, String fieldName, String sObjectType, String policyName) {
        SecurityAnalysisResult result = new SecurityAnalysisResult();

        if (String.isBlank(content)) {
            return result; // Empty content is safe
        }

        SecurityPolicy policy = getSecurityPolicy(policyName);

        // Skip analysis for exempt fields
        if (policy.exemptFields.contains(fieldName?.toLowerCase())) {
            result.sanitizedContent = content;
            result.isolatedContent = content;
            return result;
        }

        // Check cache first for performance optimization
        String cacheKey = generateContentHash(content, fieldName, sObjectType, policyName);
        CachedAnalysisResult cachedResult = getCachedResult(cacheKey);

        if (cachedResult != null) {
            // Return cached result with updated isolation context
            result = cachedResult.result.deepCopy();

            // Re-apply isolation with current context (field/object may have changed)
            if (policy.enableContentIsolation) {
                result.isolatedContent = isolateContent(result.sanitizedContent, fieldName, sObjectType);
            } else {
                result.isolatedContent = result.sanitizedContent;
            }

            // Update cache access tracking
            updateCacheAccess(cacheKey);

            return result;
        }

        // Perform fresh analysis if not cached
        result = performSecurityAnalysis(content, fieldName, sObjectType, policy);

        // Cache the result for future use
        cacheAnalysisResult(cacheKey, result);

        // Log security events if enabled
        if (policy.enableAuditLogging && !result.isSafe) {
            logSecurityEvent(content, fieldName, sObjectType, result);

            // Record in monitoring service for alerting and metrics
            SecurityMonitoringService.recordPromptInjectionAttempt(result, fieldName, sObjectType, null);
        }

        // Record content sanitization events for monitoring
        if (policy.enableAuditLogging && !content.equals(result.sanitizedContent)) {
            SecurityMonitoringService.recordContentSanitization(content, result.sanitizedContent, fieldName, sObjectType, null);
        }

        return result;
    }

    /**
     * Performs the actual security analysis without caching logic
     *
     * @param content The text content to analyze
     * @param fieldName The field name containing the content
     * @param sObjectType The SObject type containing the field
     * @param policy The security policy to apply
     * @return SecurityAnalysisResult with threat assessment and sanitized content
     */
    private static SecurityAnalysisResult performSecurityAnalysis(String content, String fieldName, String sObjectType, SecurityPolicy policy) {
        SecurityAnalysisResult result = new SecurityAnalysisResult();

        // Perform pattern-based threat detection
        if (policy.enablePatternDetection) {
            detectMaliciousPatterns(content, result, policy);
        }

        // Apply content sanitization based on risk level
        result.sanitizedContent = sanitizeContent(content, result.riskLevel, policy);

        // Apply content isolation if enabled
        if (policy.enableContentIsolation) {
            result.isolatedContent = isolateContent(result.sanitizedContent, fieldName, sObjectType);
        } else {
            result.isolatedContent = result.sanitizedContent;
        }

        return result;
    }

    /**
     * Batch analyzes multiple field values for a single record
     *
     * @param fieldValues Map of field names to values
     * @param sObjectType The SObject type
     * @param policyName Optional security policy name
     * @return Map of field names to SecurityAnalysisResult
     */
    public static Map<String, SecurityAnalysisResult> analyzeRecord(Map<String, Object> fieldValues, String sObjectType, String policyName) {
        Map<String, SecurityAnalysisResult> results = new Map<String, SecurityAnalysisResult>();

        for (String fieldName : fieldValues.keySet()) {
            Object value = fieldValues.get(fieldName);
            if (value instanceof String) {
                results.put(fieldName, analyzeContent((String) value, fieldName, sObjectType, policyName));
            }
        }

        return results;
    }

    /**
     * Detects malicious patterns in content using regex matching
     */
    private static void detectMaliciousPatterns(String content, SecurityAnalysisResult result, SecurityPolicy policy) {
        Integer highRiskMatches = 0;
        Integer mediumRiskMatches = 0;

        for (String regex : HIGH_RISK_PATTERNS) {
            Matcher m = Pattern.compile(regex).matcher(content);
            if (m.find()) {
                result.detectedPatterns.add('HIGH_RISK: ' + regex);
                highRiskMatches++;
            }
        }

        for (String regex : MEDIUM_RISK_PATTERNS) {
            Matcher m = Pattern.compile(regex).matcher(content);
            if (m.find()) {
                result.detectedPatterns.add('MEDIUM_RISK: ' + regex);
                mediumRiskMatches++;
            }
        }

        // Determine overall risk level
        if (highRiskMatches > 0) {
            result.riskLevel = 'CRITICAL';
            result.isSafe = false;
        } else if (mediumRiskMatches >= 2) {
            result.riskLevel = 'HIGH';
            result.isSafe = false;
        } else if (mediumRiskMatches == 1) {
            result.riskLevel = 'MEDIUM';
            result.isSafe = policy.securityLevel != 'STRICT';
        }

        // Additional heuristics
        if (content.length() > 1000 && (highRiskMatches > 0 || mediumRiskMatches > 0)) {
            result.riskLevel = 'CRITICAL';
            result.isSafe = false;
        }

        result.metadata.put('highRiskMatches', highRiskMatches);
        result.metadata.put('mediumRiskMatches', mediumRiskMatches);
        result.metadata.put('contentLength', content.length());
    }

    /**
     * Sanitizes content based on risk level and security policy
     */
    private static String sanitizeContent(String content, String riskLevel, SecurityPolicy policy) {
        if (riskLevel == 'LOW') {
            return content; // No sanitization needed
        }

        String sanitized = content;

        if (riskLevel == 'MEDIUM') {
            // Light sanitization - remove obvious prompt markers
            sanitized = sanitized.replaceAll('(?i)\\[\\s*(system|user|assistant)\\s*\\]', '[REDACTED]');
            sanitized = sanitized.replaceAll('(?i)system\\s*:', 'System Note:');
            sanitized = sanitized.replaceAll('(?i)assistant\\s*:', 'Assistant Note:');
        } else if (riskLevel == 'HIGH' || riskLevel == 'CRITICAL') {
            if (policy.securityLevel == 'STRICT') {
                // Aggressive sanitization - replace with safe summary
                return '[CONTENT_BLOCKED: Potential security risk detected in user-provided content]';
            } else {
                // Moderate sanitization - neutralize dangerous patterns
                for (String pattern : HIGH_RISK_PATTERNS) {
                    sanitized = sanitized.replaceAll(pattern, '[REDACTED_INSTRUCTION]');
                }
                for (String pattern : MEDIUM_RISK_PATTERNS) {
                    sanitized = sanitized.replaceAll(pattern, '[REDACTED_COMMAND]');
                }
            }
        }

        return sanitized;
    }

    /**
     * Isolates content within safe markers to prevent prompt interpretation
     */
    private static String isolateContent(String content, String fieldName, String sObjectType) {
        return SAFE_CONTENT_PREFIX + ' Field: ' + fieldName + ' | Object: ' + sObjectType + ' | Content: ' + content + ' ' + SAFE_CONTENT_SUFFIX;
    }

    /**
     * Logs security events for monitoring and analysis
     */
    private static void logSecurityEvent(String originalContent, String fieldName, String sObjectType, SecurityAnalysisResult result) {
        try {
            // Create security event record (implement based on your logging strategy)
            System.debug(
                LoggingLevel.WARN,
                '[PromptInjectionGuard] SECURITY_EVENT: ' +
                    'RiskLevel=' +
                    result.riskLevel +
                    ', Field=' +
                    fieldName +
                    ', Object=' +
                    sObjectType +
                    ', Patterns=' +
                    result.detectedPatterns.size() +
                    ', ContentLength=' +
                    originalContent.length()
            );

            // TODO: Implement custom object logging if needed
            // SecurityEvent__c event = new SecurityEvent__c(
            //     EventType__c = 'PROMPT_INJECTION_ATTEMPT',
            //     RiskLevel__c = result.riskLevel,
            //     FieldName__c = fieldName,
            //     SObjectType__c = sObjectType,
            //     DetectedPatterns__c = String.join(result.detectedPatterns, '; '),
            //     UserId__c = UserInfo.getUserId(),
            //     EventTimestamp__c = System.now()
            // );
            // insert event;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[PromptInjectionGuard] Failed to log security event: ' + e.getMessage());
        }
    }

    /**
     * Retrieves security policy configuration
     */
    private static SecurityPolicy getSecurityPolicy(String policyName) {
        if (String.isBlank(policyName)) {
            policyName = 'DEFAULT';
        }

        if (policyCache.containsKey(policyName)) {
            return policyCache.get(policyName);
        }

        // Load from custom metadata (implement based on your metadata structure)
        SecurityPolicy policy = loadPolicyFromMetadata(policyName);
        policyCache.put(policyName, policy);
        return policy;
    }

    /**
     * Loads security policy from custom metadata
     */
    private static SecurityPolicy loadPolicyFromMetadata(String policyName) {
        SecurityPolicy policy = new SecurityPolicy();
        policy.policyName = policyName;

        try {
            List<SecurityPolicy__mdt> policies = [
                SELECT
                    SecurityLevel__c,
                    EnablePatternDetection__c,
                    EnableContentIsolation__c,
                    EnableAuditLogging__c,
                    ExemptFields__c,
                    HighRiskSObjects__c
                FROM SecurityPolicy__mdt
                WHERE DeveloperName = :policyName
                LIMIT 1
            ];

            if (!policies.isEmpty()) {
                SecurityPolicy__mdt mdtPolicy = policies[0];
                policy.securityLevel = mdtPolicy.SecurityLevel__c ?? 'MODERATE';
                policy.enablePatternDetection = mdtPolicy.EnablePatternDetection__c ?? true;
                policy.enableContentIsolation = mdtPolicy.EnableContentIsolation__c ?? true;
                policy.enableAuditLogging = mdtPolicy.EnableAuditLogging__c ?? true;

                if (String.isNotBlank(mdtPolicy.ExemptFields__c)) {
                    for (String field : mdtPolicy.ExemptFields__c.split(',')) {
                        policy.exemptFields.add(field.trim().toLowerCase());
                    }
                }

                if (String.isNotBlank(mdtPolicy.HighRiskSObjects__c)) {
                    for (String obj : mdtPolicy.HighRiskSObjects__c.split(',')) {
                        policy.highRiskSObjects.add(obj.trim().toLowerCase());
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[PromptInjectionGuard] Failed to load policy from metadata: ' + e.getMessage());
        }

        return policy;
    }

    /**
     * Clears the policy cache (for testing or configuration updates)
     */
    @TestVisible
    private static void clearPolicyCache() {
        policyCache.clear();
    }

    // ========================================
    // PERFORMANCE OPTIMIZATION: CACHING METHODS
    // ========================================

    /**
     * Generates a deterministic hash for content caching
     *
     * @param content The content to hash
     * @param fieldName The field name for context
     * @param sObjectType The SObject type for context
     * @param policyName The security policy name
     * @return SHA-256 hash string for cache key
     */
    private static String generateContentHash(String content, String fieldName, String sObjectType, String policyName) {
        // Create a composite string that includes all factors affecting analysis
        String composite = content + '|' + (fieldName ?? '') + '|' + (sObjectType ?? '') + '|' + (policyName ?? 'DEFAULT');

        // Generate SHA-256 hash for consistent, collision-resistant caching
        Blob contentBlob = Blob.valueOf(composite);
        Blob hashBlob = Crypto.generateDigest('SHA-256', contentBlob);
        return EncodingUtil.base64Encode(hashBlob);
    }

    /**
     * Retrieves cached analysis result if available and not expired
     *
     * @param cacheKey The cache key to lookup
     * @return CachedAnalysisResult if found and valid, null otherwise
     */
    private static CachedAnalysisResult getCachedResult(String cacheKey) {
        CachedAnalysisResult cached = analysisCache.get(cacheKey);

        if (cached == null) {
            return null; // Cache miss
        }

        if (cached.isExpired()) {
            // Remove expired entry
            analysisCache.remove(cacheKey);
            cacheAccessOrder.remove(cacheAccessOrder.indexOf(cacheKey));
            return null; // Cache expired
        }

        cached.recordAccess();
        return cached; // Cache hit
    }

    /**
     * Caches an analysis result with LRU eviction policy
     *
     * @param cacheKey The cache key
     * @param result The analysis result to cache
     */
    private static void cacheAnalysisResult(String cacheKey, SecurityAnalysisResult result) {
        // Don't cache results for very large content to avoid memory issues
        if (result.sanitizedContent != null && result.sanitizedContent.length() > 10000) {
            return;
        }

        // Implement LRU eviction if cache is full
        if (analysisCache.size() >= MAX_CACHE_SIZE && !analysisCache.containsKey(cacheKey)) {
            evictLeastRecentlyUsed();
        }

        // Cache the result
        CachedAnalysisResult cached = new CachedAnalysisResult(result);
        analysisCache.put(cacheKey, cached);

        // Update access order for LRU tracking
        updateCacheAccess(cacheKey);
    }

    /**
     * Updates cache access order for LRU tracking
     *
     * @param cacheKey The cache key that was accessed
     */
    private static void updateCacheAccess(String cacheKey) {
        // Remove from current position if exists
        Integer currentIndex = cacheAccessOrder.indexOf(cacheKey);
        if (currentIndex >= 0) {
            cacheAccessOrder.remove(currentIndex);
        }

        // Add to end (most recently used)
        cacheAccessOrder.add(cacheKey);
    }

    /**
     * Evicts the least recently used cache entry
     */
    private static void evictLeastRecentlyUsed() {
        if (!cacheAccessOrder.isEmpty()) {
            String lruKey = cacheAccessOrder.remove(0); // Remove first (oldest)
            analysisCache.remove(lruKey);
        }
    }

    /**
     * Clears expired entries from the cache (maintenance operation)
     */
    public static void cleanupExpiredCache() {
        List<String> expiredKeys = new List<String>();

        for (String key : analysisCache.keySet()) {
            CachedAnalysisResult cached = analysisCache.get(key);
            if (cached.isExpired()) {
                expiredKeys.add(key);
            }
        }

        // Remove expired entries
        for (String expiredKey : expiredKeys) {
            analysisCache.remove(expiredKey);
            Integer index = cacheAccessOrder.indexOf(expiredKey);
            if (index >= 0) {
                cacheAccessOrder.remove(index);
            }
        }

        System.debug(LoggingLevel.DEBUG, '[PromptInjectionGuard] Cleaned up ' + expiredKeys.size() + ' expired cache entries');
    }

    /**
     * Gets cache statistics for monitoring and optimization
     *
     * @return Map containing cache performance metrics
     */
    public static Map<String, Object> getCacheStatistics() {
        Map<String, Object> stats = new Map<String, Object>();

        stats.put('cacheSize', analysisCache.size());
        stats.put('maxCacheSize', MAX_CACHE_SIZE);
        stats.put('cacheTtlMinutes', CACHE_TTL_MINUTES);

        // Calculate cache utilization
        Decimal utilization = analysisCache.size() > 0 ? (Decimal.valueOf(analysisCache.size()) / MAX_CACHE_SIZE * 100).setScale(2) : 0;
        stats.put('cacheUtilization', utilization);

        // Count expired entries
        Integer expiredCount = 0;
        for (CachedAnalysisResult cached : analysisCache.values()) {
            if (cached.isExpired()) {
                expiredCount++;
            }
        }
        stats.put('expiredEntries', expiredCount);

        // Calculate access frequency distribution
        Map<String, Integer> accessDistribution = new Map<String, Integer>{
            'lowAccess' => 0, // 1-5 accesses
            'mediumAccess' => 0, // 6-20 accesses
            'highAccess' => 0 // 21+ accesses
        };

        for (CachedAnalysisResult cached : analysisCache.values()) {
            if (cached.accessCount <= 5) {
                accessDistribution.put('lowAccess', accessDistribution.get('lowAccess') + 1);
            } else if (cached.accessCount <= 20) {
                accessDistribution.put('mediumAccess', accessDistribution.get('mediumAccess') + 1);
            } else {
                accessDistribution.put('highAccess', accessDistribution.get('highAccess') + 1);
            }
        }
        stats.put('accessDistribution', accessDistribution);

        return stats;
    }

    /**
     * Clears all caches (for testing or maintenance)
     */
    @TestVisible
    private static void clearAllCaches() {
        analysisCache.clear();
        cacheAccessOrder.clear();
        policyCache.clear();
    }
}
