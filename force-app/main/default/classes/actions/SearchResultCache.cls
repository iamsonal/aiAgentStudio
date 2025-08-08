/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description High-performance search result caching system for enterprise AI agents.
 *              Implements intelligent caching strategies with pattern-aware TTL management
 *              and memory-efficient storage for frequently accessed search results.
 */
public class SearchResultCache {
    private static final Integer MAX_CACHE_SIZE = 100;
    private static final Integer DEFAULT_TTL_MINUTES = 15;
    private static final Integer PATTERN_BASED_TTL_MINUTES = 30;

    private static final Map<String, CachedSearchResult> SEARCH_CACHE = new Map<String, CachedSearchResult>();
    private static final Map<String, DateTime> ACCESS_TIMES = new Map<String, DateTime>();

    /**
     * @description Cached search result container with metadata
     */
    public class CachedSearchResult {
        public List<List<SObject>> searchResults;
        public SearchPatternAnalyzer.SearchAnalysis patternAnalysis;
        public DateTime cachedAt;
        public Integer accessCount;
        public Integer ttlMinutes;

        public CachedSearchResult(List<List<SObject>> results, SearchPatternAnalyzer.SearchAnalysis analysis) {
            this.searchResults = results;
            this.patternAnalysis = analysis;
            this.cachedAt = DateTime.now();
            this.accessCount = 1;
            this.ttlMinutes = calculateTTL(analysis);
        }

        private Integer calculateTTL(SearchPatternAnalyzer.SearchAnalysis analysis) {
            if (
                analysis.primaryPattern == SearchPatternAnalyzer.SearchPattern.EMAIL_SEARCH ||
                analysis.primaryPattern == SearchPatternAnalyzer.SearchPattern.PHONE_SEARCH ||
                analysis.primaryPattern == SearchPatternAnalyzer.SearchPattern.IDENTIFIER_SEARCH
            ) {
                return PATTERN_BASED_TTL_MINUTES;
            }

            if (analysis.confidenceScore > 80) {
                return PATTERN_BASED_TTL_MINUTES;
            }

            return DEFAULT_TTL_MINUTES;
        }
    }

    /**
     * @description Cache statistics for monitoring and optimization
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
            this.patternDistribution = new Map<String, Integer>();
        }
    }

    private static Integer cacheHits = 0;
    private static Integer cacheMisses = 0;

    /**
     * @description Generates cache key from search parameters
     * @param searchQuery The search query string
     * @param sObjectTypes List of SObject types to search
     * @param userId Current user ID for user-specific caching
     * @return Normalized cache key
     */
    public static String generateCacheKey(String searchQuery, List<String> sObjectTypes, Id userId) {
        String normalizedQuery = searchQuery.toLowerCase().trim();
        String sortedTypes = sObjectTypes != null ? String.join(sObjectTypes, ',') : 'all';
        String userContext = String.valueOf(userId).substring(0, 15);

        String combinedKey = normalizedQuery + '|' + sortedTypes + '|' + userContext;
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(combinedKey))).substring(0, 32);
    }

    /**
     * @description Retrieves cached search results if available and not expired
     * @param cacheKey The cache key to lookup
     * @return CachedSearchResult if found and valid, null otherwise
     */
    public static CachedSearchResult getCachedResults(String cacheKey) {
        CachedSearchResult cached = SEARCH_CACHE.get(cacheKey);

        if (cached == null) {
            cacheMisses++;
            return null;
        }

        if (isCacheExpired(cached)) {
            SEARCH_CACHE.remove(cacheKey);
            ACCESS_TIMES.remove(cacheKey);
            cacheMisses++;
            return null;
        }

        cached.accessCount++;
        ACCESS_TIMES.put(cacheKey, DateTime.now());
        cacheHits++;

        return cached;
    }

    /**
     * @description Caches search results with pattern-aware TTL
     * @param cacheKey The cache key
     * @param searchResults The search results to cache
     * @param patternAnalysis The pattern analysis for TTL calculation
     */
    public static void cacheResults(String cacheKey, List<List<SObject>> searchResults, SearchPatternAnalyzer.SearchAnalysis patternAnalysis) {
        manageCacheSize();

        CachedSearchResult cachedResult = new CachedSearchResult(searchResults, patternAnalysis);
        SEARCH_CACHE.put(cacheKey, cachedResult);
        ACCESS_TIMES.put(cacheKey, DateTime.now());
    }

    /**
     * @description Checks if a cached entry has expired based on its TTL
     * @param cached The cached search result
     * @return True if expired, false otherwise
     */
    private static Boolean isCacheExpired(CachedSearchResult cached) {
        return cached.cachedAt.addMinutes(cached.ttlMinutes) < DateTime.now();
    }

    /**
     * @description Manages cache size using intelligent eviction strategy
     */
    private static void manageCacheSize() {
        if (SEARCH_CACHE.size() >= MAX_CACHE_SIZE) {
            evictLeastValuableEntries();
        }
    }

    /**
     * @description Evicts least valuable cache entries based on access patterns and age
     */
    private static void evictLeastValuableEntries() {
        List<String> keysToEvict = new List<String>();
        DateTime oldestTime = DateTime.now();
        String oldestKey = null;
        Integer lowestAccessCount = 2147483647;
        String leastAccessedKey = null;

        for (String key : SEARCH_CACHE.keySet()) {
            CachedSearchResult cached = SEARCH_CACHE.get(key);
            DateTime accessTime = ACCESS_TIMES.get(key);

            if (isCacheExpired(cached)) {
                keysToEvict.add(key);
                continue;
            }

            if (accessTime < oldestTime) {
                oldestTime = accessTime;
                oldestKey = key;
            }

            if (cached.accessCount < lowestAccessCount) {
                lowestAccessCount = cached.accessCount;
                leastAccessedKey = key;
            }
        }

        for (String key : keysToEvict) {
            SEARCH_CACHE.remove(key);
            ACCESS_TIMES.remove(key);
        }

        if (SEARCH_CACHE.size() >= MAX_CACHE_SIZE) {
            String keyToEvict = (leastAccessedKey != null && lowestAccessCount == 1) ? leastAccessedKey : oldestKey;
            if (keyToEvict != null) {
                SEARCH_CACHE.remove(keyToEvict);
                ACCESS_TIMES.remove(keyToEvict);
            }
        }
    }

    /**
     * @description Clears all cached search results (for testing or memory management)
     */
    @TestVisible
    public static void clearCache() {
        SEARCH_CACHE.clear();
        ACCESS_TIMES.clear();
        cacheHits = 0;
        cacheMisses = 0;
    }

    /**
     * @description Gets comprehensive cache statistics for monitoring
     * @return CacheStatistics containing detailed metrics
     */
    public static CacheStatistics getCacheStatistics() {
        CacheStatistics stats = new CacheStatistics();
        stats.totalCacheSize = SEARCH_CACHE.size();
        stats.hitCount = cacheHits;
        stats.missCount = cacheMisses;
        stats.hitRatio = (cacheHits + cacheMisses > 0) ? (Decimal.valueOf(cacheHits) / (cacheHits + cacheMisses)) * 100 : 0;

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
     * @description Proactively cleans expired entries from cache
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
        }

        return expiredKeys.size();
    }

    /**
     * @description Warms cache with common search patterns (for system initialization)
     * @param commonSearchTerms List of frequently used search terms
     */
    public static void warmCache(List<String> commonSearchTerms) {
    }
}
