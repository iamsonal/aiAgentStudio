/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description High-performance schema caching utility for enterprise AI agent systems.
 *              Provides thread-safe caching of SObject field metadata to reduce describe calls.
 *              Implements LRU-style cache management with configurable limits.
 */
public class SchemaCache {
    private static final Integer MAX_CACHE_SIZE = 50;
    private static final Integer CACHE_TTL_MINUTES = 60;

    private static final Map<String, CachedFieldMap> FIELD_CACHE = new Map<String, CachedFieldMap>();
    private static final Map<String, CachedDescribe> DESCRIBE_CACHE = new Map<String, CachedDescribe>();

    private static final Map<String, DateTime> ACCESS_TIMES = new Map<String, DateTime>();

    /**
     * @description Cached field map container with metadata
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
     * @description Cached describe result container
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
     * @description Gets field map for SObjectType with caching
     * @param sObjType The SObjectType to get fields for
     * @return Map of field API names to SObjectField tokens
     */
    public static Map<String, Schema.SObjectField> getFieldMap(SObjectType sObjType) {
        String typeName = sObjType.getDescribe().getName().toLowerCase();

        CachedFieldMap cached = FIELD_CACHE.get(typeName);
        if (cached != null && !isCacheExpired(cached.cachedAt)) {
            cached.accessCount++;
            ACCESS_TIMES.put(typeName, DateTime.now());
            return cached.fieldMap;
        }

        Map<String, Schema.SObjectField> fieldMap = sObjType.getDescribe(SObjectDescribeOptions.DEFERRED).fields.getMap();

        manageCacheSize();

        FIELD_CACHE.put(typeName, new CachedFieldMap(fieldMap));
        ACCESS_TIMES.put(typeName, DateTime.now());

        return fieldMap;
    }

    /**
     * @description Gets describe result for SObjectType with caching
     * @param sObjType The SObjectType to describe
     * @return DescribeSObjectResult
     */
    public static Schema.DescribeSObjectResult getDescribe(SObjectType sObjType) {
        String typeName = sObjType.getDescribe().getName().toLowerCase();

        CachedDescribe cached = DESCRIBE_CACHE.get(typeName);
        if (cached != null && !isCacheExpired(cached.cachedAt)) {
            cached.accessCount++;
            ACCESS_TIMES.put(typeName + '_desc', DateTime.now());
            return cached.describeResult;
        }

        Schema.DescribeSObjectResult describeResult = sObjType.getDescribe(SObjectDescribeOptions.DEFERRED);

        manageCacheSize();

        DESCRIBE_CACHE.put(typeName, new CachedDescribe(describeResult));
        ACCESS_TIMES.put(typeName + '_desc', DateTime.now());

        return describeResult;
    }

    /**
     * @description Checks if a cached entry has expired
     * @param cachedAt The timestamp when the entry was cached
     * @return True if expired, false otherwise
     */
    private static Boolean isCacheExpired(DateTime cachedAt) {
        return cachedAt.addMinutes(CACHE_TTL_MINUTES) < DateTime.now();
    }

    /**
     * @description Manages cache size using LRU eviction strategy
     */
    private static void manageCacheSize() {
        if (FIELD_CACHE.size() >= MAX_CACHE_SIZE) {
            evictLeastRecentlyUsed();
        }
    }

    /**
     * @description Evicts least recently used cache entries
     */
    private static void evictLeastRecentlyUsed() {
        DateTime oldestTime = DateTime.now();
        String oldestKey = null;

        for (String key : ACCESS_TIMES.keySet()) {
            DateTime accessTime = ACCESS_TIMES.get(key);
            if (accessTime < oldestTime) {
                oldestTime = accessTime;
                oldestKey = key;
            }
        }

        if (oldestKey != null) {
            if (oldestKey.endsWith('_desc')) {
                String typeName = oldestKey.replace('_desc', '');
                DESCRIBE_CACHE.remove(typeName);
            } else {
                FIELD_CACHE.remove(oldestKey);
            }
            ACCESS_TIMES.remove(oldestKey);
        }
    }

    /**
     * @description Clears all cached data (for testing or memory management)
     */
    @TestVisible
    public static void clearCache() {
        FIELD_CACHE.clear();
        DESCRIBE_CACHE.clear();
        ACCESS_TIMES.clear();
    }

    /**
     * @description Gets cache statistics for monitoring
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
