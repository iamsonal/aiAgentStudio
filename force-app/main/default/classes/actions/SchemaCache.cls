/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SchemaCache: Enterprise schema metadata caching system for high-performance AI and automation.
 *
 * This class provides intelligent caching of SObject field maps and describe results with LRU eviction,
 * TTL-based expiration, and memory-efficient storage. It reduces expensive describe calls through strategic caching
 * with configurable size limits and automatic cleanup mechanisms, supporting high-throughput AI agent and automation workloads.
 *
 * Key Responsibilities:
 *   - Caches SObject field maps and describe results for rapid access.
 *   - Implements LRU eviction and TTL expiration for memory efficiency.
 *   - Provides cache statistics and management utilities for diagnostics and testing.
 *   - Ensures thread-safe, high-performance access for concurrent AI agent operations.
 */
public class SchemaCache {
    // Cache configuration
    private static final Integer MAX_CACHE_SIZE = 50; // Limit memory usage
    private static final Integer CACHE_TTL_MINUTES = 60; // Cache time-to-live

    // Thread-safe cache storage
    private static final Map<String, CachedFieldMap> FIELD_CACHE = new Map<String, CachedFieldMap>();
    private static final Map<String, CachedDescribe> DESCRIBE_CACHE = new Map<String, CachedDescribe>();

    // Access tracking for LRU eviction
    private static final Map<String, DateTime> ACCESS_TIMES = new Map<String, DateTime>();

    /**
     * @description
     * Cached field map container with metadata for cache management and diagnostics.
     */
    private class CachedFieldMap {
        public Map<String, Schema.SObjectField> fieldMap;
        public DateTime cachedAt;
        public Integer accessCount;

        public CachedFieldMap(Map<String, Schema.SObjectField> fieldMap) {
            this.fieldMap = fieldMap;
            this.cachedAt = DateTime.now();
            this.accessCount = 1;
        }
    }

    /**
     * @description
     * Cached describe result container with metadata for cache management and diagnostics.
     */
    private class CachedDescribe {
        public Schema.DescribeSObjectResult describeResult;
        public DateTime cachedAt;
        public Integer accessCount;

        public CachedDescribe(Schema.DescribeSObjectResult describeResult) {
            this.describeResult = describeResult;
            this.cachedAt = DateTime.now();
            this.accessCount = 1;
        }
    }

    /**
     * @description
     * Retrieves field metadata map with intelligent caching and automatic cache management.
     *
     * @param sObjType SObjectType to retrieve field information for
     * @return Map of lowercase field API names to SObjectField tokens
     */
    public static Map<String, Schema.SObjectField> getFieldMap(SObjectType sObjType) {
        String typeName = sObjType.getDescribe().getName().toLowerCase();

        // Attempt cache retrieval with expiration check
        CachedFieldMap cached = FIELD_CACHE.get(typeName);
        if (cached != null && !isCacheExpired(cached.cachedAt)) {
            cached.accessCount++;
            ACCESS_TIMES.put(typeName, DateTime.now());
            System.debug(LoggingLevel.FINEST, '[SchemaCache] Field map cache hit for ' + typeName);
            return cached.fieldMap;
        }

        // Cache miss - retrieve fresh schema data
        Map<String, Schema.SObjectField> fieldMap = sObjType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();

        // Ensure cache size limits before adding new entry
        manageCacheSize();

        // Store in cache with access tracking
        FIELD_CACHE.put(typeName, new CachedFieldMap(fieldMap));
        ACCESS_TIMES.put(typeName, DateTime.now());
        System.debug(LoggingLevel.DEBUG, '[SchemaCache] Cached field map for ' + typeName + ' (' + fieldMap.size() + ' fields)');

        return fieldMap;
    }

    /**
     * @description
     * Retrieves SObject describe result with caching and automatic expiration management.
     *
     * @param sObjType SObjectType to get describe information for
     * @return DescribeSObjectResult with comprehensive object metadata
     */
    public static Schema.DescribeSObjectResult getDescribe(SObjectType sObjType) {
        String typeName = sObjType.getDescribe().getName().toLowerCase();

        // Check cache with expiration validation
        CachedDescribe cached = DESCRIBE_CACHE.get(typeName);
        if (cached != null && !isCacheExpired(cached.cachedAt)) {
            cached.accessCount++;
            ACCESS_TIMES.put(typeName + '_desc', DateTime.now());
            System.debug(LoggingLevel.FINEST, '[SchemaCache] Describe cache hit for ' + typeName);
            return cached.describeResult;
        }

        // Cache miss - perform fresh describe call
        Schema.DescribeSObjectResult describeResult = sObjType.getDescribe(SObjectDescribeOptions.DEFERRED);

        // Maintain cache size limits
        manageCacheSize();

        // Store result with tracking metadata
        DESCRIBE_CACHE.put(typeName, new CachedDescribe(describeResult));
        ACCESS_TIMES.put(typeName + '_desc', DateTime.now());
        System.debug(LoggingLevel.DEBUG, '[SchemaCache] Cached describe result for ' + typeName);

        return describeResult;
    }

    /**
     * @description
     * Checks if a cached entry has expired based on TTL configuration.
     *
     * @param cachedAt The timestamp when the entry was cached
     * @return True if expired, false otherwise
     */
    private static Boolean isCacheExpired(DateTime cachedAt) {
        return cachedAt.addMinutes(CACHE_TTL_MINUTES) < DateTime.now();
    }

    /**
     * @description
     * Manages cache size using LRU eviction strategy to maintain memory efficiency.
     */
    private static void manageCacheSize() {
        if (FIELD_CACHE.size() >= MAX_CACHE_SIZE) {
            evictLeastRecentlyUsed();
        }
    }

    /**
     * @description
     * Implements LRU eviction strategy to maintain cache size limits while preserving frequently accessed entries.
     */
    private static void evictLeastRecentlyUsed() {
        // Find the oldest access time for LRU eviction
        DateTime oldestTime = DateTime.now();
        String oldestKey = null;

        for (String key : ACCESS_TIMES.keySet()) {
            DateTime accessTime = ACCESS_TIMES.get(key);
            if (accessTime < oldestTime) {
                oldestTime = accessTime;
                oldestKey = key;
            }
        }

        // Evict least recently used entry to free cache space
        if (oldestKey != null) {
            if (oldestKey.endsWith('_desc')) {
                String typeName = oldestKey.replace('_desc', '');
                DESCRIBE_CACHE.remove(typeName);
                System.debug(LoggingLevel.DEBUG, '[SchemaCache] Evicted describe cache for ' + typeName);
            } else {
                FIELD_CACHE.remove(oldestKey);
                System.debug(LoggingLevel.DEBUG, '[SchemaCache] Evicted field cache for ' + oldestKey);
            }
            ACCESS_TIMES.remove(oldestKey);
        }
    }

    /**
     * @description
     * Clears all cached data (for testing or memory management).
     */
    @TestVisible
    public static void clearCache() {
        FIELD_CACHE.clear();
        DESCRIBE_CACHE.clear();
        ACCESS_TIMES.clear();
    }

    /**
     * @description
     * Gets cache statistics for monitoring and diagnostics.
     *
     * @return Map containing cache metrics
     */
    public static Map<String, Object> getCacheStats() {
        return new Map<String, Object>{
            'fieldCacheSize' => FIELD_CACHE.size(),
            'describeCacheSize' => DESCRIBE_CACHE.size(),
            'maxCacheSize' => MAX_CACHE_SIZE,
            'cacheTtlMinutes' => CACHE_TTL_MINUTES
        };
    }
}
