/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * QueryResult: Standardized result wrapper for QueryService operations
 *
 * This class provides a consistent return type for query execution, replacing
 * framework-specific ActionOutcome with a generic, reusable result object.
 *
 * Usage Pattern:
 *
 * Success:
 *   QueryResult result = QueryResult.success(records);
 *   if (result.isSuccess) {
 *       List<SObject> records = result.records;
 *       // Process records
 *   }
 *
 * Failure:
 *   QueryResult result = QueryResult.failure('INVALID_FIELD', 'Field does not exist');
 *   if (!result.isSuccess) {
 *       System.debug(result.errorCode + ': ' + result.errorMessage);
 *   }
 *
 * @group QueryService Package
 */
public class QueryResult {
    /**
     * Indicates whether the operation was successful
     */
    public Boolean isSuccess { get; private set; }

    /**
     * List of SObject records returned by the query (null if failed)
     */
    public List<SObject> records { get; private set; }

    /**
     * Error code if operation failed (null if successful)
     * Common codes: INVALID_FIELD, FLS_VIOLATION, SOQL_ERROR, INPUT_VALIDATION
     */
    public String errorCode { get; private set; }

    /**
     * Human-readable error message if operation failed (null if successful)
     */
    public String errorMessage { get; private set; }

    /**
     * Additional contextual data about the result (optional)
     */
    public Map<String, Object> metadata { get; private set; }

    /**
     * Private constructor - use factory methods instead
     */
    private QueryResult() {
        this.metadata = new Map<String, Object>();
    }

    /**
     * Creates a successful query result with records
     *
     * @param records List of SObject records from the query
     * @return QueryResult indicating success
     */
    public static QueryResult success(List<SObject> records) {
        QueryResult result = new QueryResult();
        result.isSuccess = true;
        result.records = records != null ? records : new List<SObject>();
        result.errorCode = null;
        result.errorMessage = null;
        return result;
    }

    /**
     * Creates a failed query result with error details
     *
     * @param errorCode Short error code (e.g., 'INVALID_FIELD')
     * @param errorMessage Detailed error message
     * @return QueryResult indicating failure
     */
    public static QueryResult failure(String errorCode, String errorMessage) {
        QueryResult result = new QueryResult();
        result.isSuccess = false;
        result.records = null;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        return result;
    }

    /**
     * Adds metadata to the result for additional context
     *
     * @param key Metadata key
     * @param value Metadata value
     * @return QueryResult (for method chaining)
     */
    public QueryResult withMetadata(String key, Object value) {
        if (this.metadata == null) {
            this.metadata = new Map<String, Object>();
        }
        this.metadata.put(key, value);
        return this;
    }

    /**
     * Returns a string representation of the result
     *
     * @return String summary of the result
     */
    public override String toString() {
        if (isSuccess) {
            return 'QueryResult[SUCCESS: ' + (records != null ? records.size() : 0) + ' records]';
        } else {
            return 'QueryResult[FAILURE: ' + errorCode + ' - ' + errorMessage + ']';
        }
    }
}

