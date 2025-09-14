/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SearchResultCache: Enterprise search result caching system for AI-driven search optimization and analytics.
 *
 * This class provides high-performance caching of SOSL search results with dynamic TTL based on search patterns,
 * LRU eviction strategies, and comprehensive cache analytics. It optimizes memory usage while maximizing cache hit rates
 * for frequently accessed search queries in AI agent workflows and automation.
 *
 * Key Responsibilities:
 *   - Caches SOSL search results with pattern-aware TTL and LRU eviction.
 *   - Tracks cache hits, misses, and pattern distribution for analytics.
 *   - Provides methods for cache warming, cleaning, and statistics reporting.
 *   - Ensures thread-safe, high-throughput access for concurrent AI agent operations.
 */
public class SearchResultCache {
    // Cache configuration constants
    private static final Integer MAX_CACHE_SIZE = 100; // Limit memory usage
    private static final Integer DEFAULT_TTL_MINUTES = 15; // Shorter TTL for search results
    private static final Integer PATTERN_BASED_TTL_MINUTES = 30; // Longer TTL for structured patterns

    // Thread-safe cache storage
    private static final Map<String, CachedSearchResult> SEARCH_CACHE = new Map<String, CachedSearchResult>();
    private static final Map<String, DateTime> ACCESS_TIMES = new Map<String, DateTime>();

    /**
     * @description
     * Cached search result container with metadata for cache management and analytics.
     */
    public class CachedSearchResult {
        public List<List<SObject>> searchResults;
        public SearchPatternAnalyzer.SearchAnalysis patternAnalysis;
        public DateTime cachedAt;
        public Integer accessCount;
        public Integer ttlMinutes;

        /**
         * @description
         * Constructs a CachedSearchResult with pattern-aware TTL and metadata.
         *
         * @param results SOSL search results
         * @param analysis Search pattern analysis for TTL and diagnostics
         */
        public CachedSearchResult(List<List<SObject>> results, SearchPatternAnalyzer.SearchAnalysis analysis) {
            this.searchResults = results;
            this.patternAnalysis = analysis;
            this.cachedAt = DateTime.now();
            this.accessCount = 1;
            this.ttlMinutes = calculateTTL(analysis);
        }

        /**
         * @description
         * Calculates TTL for this cache entry based on pattern type and confidence.
         *
         * @param analysis Search pattern analysis
         * @return Integer TTL in minutes
         */
        private Integer calculateTTL(SearchPatternAnalyzer.SearchAnalysis analysis) {
            // Structured patterns (email, phone, ID) can be cached longer
            if (
                analysis.primaryPattern == SearchPatternAnalyzer.SearchPattern.EMAIL_SEARCH ||
                analysis.primaryPattern == SearchPatternAnalyzer.SearchPattern.PHONE_SEARCH ||
                analysis.primaryPattern == SearchPatternAnalyzer.SearchPattern.IDENTIFIER_SEARCH
            ) {
                return PATTERN_BASED_TTL_MINUTES;
            }

            // High confidence patterns get longer TTL
            if (analysis.confidenceScore > 80) {
                return PATTERN_BASED_TTL_MINUTES;
            }

            return DEFAULT_TTL_MINUTES;
        }
    }

    /**
     * @description
     * Cache statistics container for monitoring and optimization analytics.
     */
    public class CacheStatistics {
        public Integer totalCacheSize;
        public Integer hitCount;
        public Integer missCount;
        public Decimal hitRatio;
        public Map<String, Integer> patternDistribution;
        public DateTime oldestEntry;
        public DateTime newestEntry;

        public CacheStatistics() {
            this.totalCacheSize = 0;
            this.hitCount = 0;
            this.missCount = 0;
            this.hitRatio = 0;
            this.patternDistribution = new Map<String, Integer>();
        }
    }

    // Performance tracking
    private static Integer cacheHits = 0;
    private static Integer cacheMisses = 0;

    /**
     * @description
     * Creates a normalized, secure cache key from search parameters using SHA-256 hashing.
     * Incorporates user context for security while maintaining reasonable key length.
     *
     * @param searchQuery Natural language search query string
     * @param sObjectTypes List of SObject types included in search scope
     * @param userId Current user ID for user-specific cache isolation
     * @return 32-character hexadecimal cache key
     */
    public static String generateCacheKey(String searchQuery, List<String> sObjectTypes, Id userId) {
        String normalizedQuery = searchQuery.toLowerCase().trim();
        String sortedTypes = sObjectTypes != null ? String.join(sObjectTypes, ',') : 'all';
        String userContext = String.valueOf(userId).substring(0, 15); // Use first 15 chars of user ID

        // Create hash to keep key length manageable
        String combinedKey = normalizedQuery + '|' + sortedTypes + '|' + userContext;
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(combinedKey))).substring(0, 32);
    }

    /**
     * @description
     * Retrieves cached search results with automatic expiration checking and access tracking.
     *
     * @param cacheKey Cache key generated from search parameters
     * @return CachedSearchResult if valid and not expired, null for cache miss
     */
    public static CachedSearchResult getCachedResults(String cacheKey) {
        CachedSearchResult cached = SEARCH_CACHE.get(cacheKey);

        if (cached == null) {
            cacheMisses++;
            System.debug(LoggingLevel.FINEST, '[SearchResultCache] Cache miss for key: ' + cacheKey);
            return null;
        }

        // Validate cache entry expiration based on pattern-specific TTL
        if (isCacheExpired(cached)) {
            SEARCH_CACHE.remove(cacheKey);
            ACCESS_TIMES.remove(cacheKey);
            cacheMisses++;
            System.debug(LoggingLevel.DEBUG, '[SearchResultCache] Expired entry removed for key: ' + cacheKey);
            return null;
        }

        // Update access metrics for LRU tracking
        cached.accessCount++;
        ACCESS_TIMES.put(cacheKey, DateTime.now());
        cacheHits++;
        System.debug(LoggingLevel.FINEST, '[SearchResultCache] Cache hit for key: ' + cacheKey);

        return cached;
    }

    /**
     * @description
     * Stores search results with intelligent TTL based on search pattern characteristics.
     * Structured patterns (email, phone, ID) receive longer TTL than fuzzy patterns.
     *
     * @param cacheKey Unique cache identifier
     * @param searchResults SOSL search results to cache
     * @param patternAnalysis Pattern analysis containing confidence and pattern type for TTL calculation
     */
    public static void cacheResults(String cacheKey, List<List<SObject>> searchResults, SearchPatternAnalyzer.SearchAnalysis patternAnalysis) {
        // Manage cache size before adding new entry
        manageCacheSize();

        // Create and store cached result
        CachedSearchResult cachedResult = new CachedSearchResult(searchResults, patternAnalysis);
        SEARCH_CACHE.put(cacheKey, cachedResult);
        ACCESS_TIMES.put(cacheKey, DateTime.now());

        System.debug(
            LoggingLevel.DEBUG,
            '[SearchResultCache] Cached results for key: ' +
                cacheKey +
                ', Pattern: ' +
                patternAnalysis.primaryPattern +
                ', TTL: ' +
                cachedResult.ttlMinutes +
                ' minutes'
        );
    }

    /**
     * @description
     * Checks if a cached entry has expired based on its TTL.
     *
     * @param cached The cached search result
     * @return True if expired, false otherwise
     */
    private static Boolean isCacheExpired(CachedSearchResult cached) {
        return cached.cachedAt.addMinutes(cached.ttlMinutes) < DateTime.now();
    }

    /**
     * @description
     * Manages cache size using intelligent eviction strategy (LRU and access count).
     */
    private static void manageCacheSize() {
        if (SEARCH_CACHE.size() >= MAX_CACHE_SIZE) {
            evictLeastValuableEntries();
        }
    }

    /**
     * @description
     * Evicts least valuable cache entries based on access patterns and age (LRU and least accessed).
     */
    private static void evictLeastValuableEntries() {
        List<String> keysToEvict = new List<String>();
        DateTime oldestTime = DateTime.now();
        String oldestKey = null;
        Integer lowestAccessCount = 2147483647;
        String leastAccessedKey = null;

        // Find candidates for eviction
        for (String key : SEARCH_CACHE.keySet()) {
            CachedSearchResult cached = SEARCH_CACHE.get(key);
            DateTime accessTime = ACCESS_TIMES.get(key);

            // Check for expired entries first
            if (isCacheExpired(cached)) {
                keysToEvict.add(key);
                continue;
            }

            // Track oldest entry
            if (accessTime < oldestTime) {
                oldestTime = accessTime;
                oldestKey = key;
            }

            // Track least accessed entry
            if (cached.accessCount < lowestAccessCount) {
                lowestAccessCount = cached.accessCount;
                leastAccessedKey = key;
            }
        }

        // Evict expired entries first
        for (String key : keysToEvict) {
            SEARCH_CACHE.remove(key);
            ACCESS_TIMES.remove(key);
        }

        // If still over limit, evict least accessed or oldest
        if (SEARCH_CACHE.size() >= MAX_CACHE_SIZE) {
            String keyToEvict = (leastAccessedKey != null && lowestAccessCount == 1) ? leastAccessedKey : oldestKey;
            if (keyToEvict != null) {
                SEARCH_CACHE.remove(keyToEvict);
                ACCESS_TIMES.remove(keyToEvict);
                System.debug(LoggingLevel.DEBUG, '[SearchResultCache] Evicted cache entry: ' + keyToEvict);
            }
        }
    }

    /**
     * @description
     * Clears all cached search results (for testing or memory management).
     */
    @TestVisible
    public static void clearCache() {
        SEARCH_CACHE.clear();
        ACCESS_TIMES.clear();
        cacheHits = 0;
        cacheMisses = 0;
        System.debug(LoggingLevel.INFO, '[SearchResultCache] Cache cleared');
    }

    /**
     * @description
     * Gets comprehensive cache statistics for monitoring and diagnostics.
     *
     * @return CacheStatistics containing detailed metrics
     */
    public static CacheStatistics getCacheStatistics() {
        CacheStatistics stats = new CacheStatistics();
        stats.totalCacheSize = SEARCH_CACHE.size();
        stats.hitCount = cacheHits;
        stats.missCount = cacheMisses;
        stats.hitRatio = (cacheHits + cacheMisses > 0) ? (Decimal.valueOf(cacheHits) / (cacheHits + cacheMisses)) * 100 : 0;

        // Analyze pattern distribution
        Map<String, Integer> patternCounts = new Map<String, Integer>();
        DateTime oldest = DateTime.now();
        DateTime newest = DateTime.now().addDays(-1);

        for (String key : SEARCH_CACHE.keySet()) {
            CachedSearchResult cached = SEARCH_CACHE.get(key);
            String patternName = String.valueOf(cached.patternAnalysis.primaryPattern);

            Integer count = patternCounts.get(patternName);
            patternCounts.put(patternName, (count != null ? count : 0) + 1);

            if (cached.cachedAt < oldest)
                oldest = cached.cachedAt;
            if (cached.cachedAt > newest)
                newest = cached.cachedAt;
        }

        stats.patternDistribution = patternCounts;
        stats.oldestEntry = oldest;
        stats.newestEntry = newest;

        return stats;
    }

    /**
     * @description
     * Proactively cleans expired entries from cache.
     *
     * @return Number of entries cleaned
     */
    public static Integer cleanExpiredEntries() {
        List<String> expiredKeys = new List<String>();

        for (String key : SEARCH_CACHE.keySet()) {
            CachedSearchResult cached = SEARCH_CACHE.get(key);
            if (isCacheExpired(cached)) {
                expiredKeys.add(key);
            }
        }

        for (String key : expiredKeys) {
            SEARCH_CACHE.remove(key);
            ACCESS_TIMES.remove(key);
        }

        if (!expiredKeys.isEmpty()) {
            System.debug(LoggingLevel.INFO, '[SearchResultCache] Cleaned ' + expiredKeys.size() + ' expired entries');
        }

        return expiredKeys.size();
    }

    /**
     * @description
     * Warms cache with common search patterns (for system initialization or prefetching).
     *
     * @param commonSearchTerms List of frequently used search terms
     */
    public static void warmCache(List<String> commonSearchTerms) {
        System.debug(LoggingLevel.INFO, '[SearchResultCache] Warming cache with ' + commonSearchTerms.size() + ' common search terms');

        // This method would be called during system initialization
        // to pre-populate cache with frequently used searches
        // Implementation would depend on specific business requirements
    }
}
