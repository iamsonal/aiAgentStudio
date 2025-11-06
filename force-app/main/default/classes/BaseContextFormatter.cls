/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * BaseContextFormatter provides common functionality for all context formatter implementations.
 * It handles schema caching through the SchemaUtils service and provides utility methods for
 * field extraction and relationship handling.
 */
public virtual inherited sharing class BaseContextFormatter {
    // Constants for metadata
    private static final String METADATA_VERSION = '1.0';

    public BaseContextFormatter() {
        // Default constructor
    }

    /**
     * Groups a list of SObjects by their SObjectType name.
     *
     * @param records   List of SObjects to group.
     * @return          Map from SObjectType name to list of SObjects.
     */
    protected Map<String, List<SObject>> groupRecordsByType(List<SObject> records) {
        Map<String, List<SObject>> mapByType = new Map<String, List<SObject>>();
        for (SObject record : records) {
            String typeName = record.getSObjectType().getDescribe().getName();
            if (!mapByType.containsKey(typeName)) {
                mapByType.put(typeName, new List<SObject>());
            }
            mapByType.get(typeName).add(record);
        }
        return mapByType;
    }

    /**
     * Finds the primary display field for a record, prioritizing common display fields.
     *
     * @param populatedFields   Set of populated field API names.
     * @param objectDescribe    DescribeSObjectResult for the SObjectType.
     * @return                  The API name of the primary display field, or 'Id' if none found.
     */
    protected String findPrimaryDisplayField(Set<String> populatedFields, Schema.DescribeSObjectResult objectDescribe) {
        List<String> preferredFields = new List<String>{ 'Name', 'Subject', 'CaseNumber', 'Title' };
        Set<String> populatedFieldsLower = new Set<String>();
        for (String f : populatedFields) {
            populatedFieldsLower.add(f.toLowerCase());
        }

        Map<String, SObjectField> fieldMap = SchemaUtils.getObjectFields(objectDescribe.getSObjectType());

        for (String preferred : preferredFields) {
            if (populatedFieldsLower.contains(preferred.toLowerCase())) {
                SObjectField fieldToken = fieldMap.get(preferred.toLowerCase());
                if (fieldToken != null && fieldToken.getDescribe().isAccessible()) {
                    return fieldToken.getDescribe().getName();
                }
            }
        }
        return 'Id';
    }

    /**
     * Gets the field label for a given field name using schema information.
     *
     * @param fieldName         The API name of the field.
     * @param objectDescribe    The DescribeSObjectResult for the object containing the field.
     * @return                  The field label, or the field name if label cannot be determined.
     */
    protected String getFieldLabel(String fieldName, Schema.DescribeSObjectResult objectDescribe) {
        if (objectDescribe == null || String.isBlank(fieldName)) {
            System.debug('[BaseContextFormatter] objectDescribe is null or fieldName is blank');
            return fieldName;
        }

        Map<String, SObjectField> fieldMap = SchemaUtils.getObjectFields(objectDescribe.getSObjectType());
        return getFieldLabelFromFieldMap(fieldName, fieldMap);
    }

    /**
     * Gets the field label using a pre-fetched field map.
     * Use this overload in loops to avoid redundant schema lookups.
     *
     * @param fieldName  The API name of the field.
     * @param fieldMap   Pre-fetched field map for the object.
     * @return           The field label, or the field name if label cannot be determined.
     */
    protected String getFieldLabelFromFieldMap(String fieldName, Map<String, SObjectField> fieldMap) {
        if (fieldMap == null || String.isBlank(fieldName)) {
            return fieldName;
        }

        SObjectField fieldToken = fieldMap.get(fieldName.toLowerCase());

        if (fieldToken != null && fieldToken.getDescribe().isAccessible()) {
            String label = fieldToken.getDescribe().getLabel();
            return label;
        }

        System.debug('[BaseContextFormatter] Could not find label for ' + fieldName + ', returning fieldName');
        return fieldName; // Fallback to API name if label cannot be determined
    }

    /**
     * Extracts all accessible field values from an SObject, including relationship fields.
     * This method handles both direct fields and relationship traversal.
     *
     * @param record     The SObject record to extract fields from.
     * @param logPrefix  Logging prefix for debug messages.
     * @return           Map of field labels to their values.
     */
    protected Map<String, Object> extractAllAccessibleFields(SObject record, String logPrefix) {
        System.debug(logPrefix + '[BaseContextFormatter] extractAllAccessibleFields called with record: ' + record);
        Map<String, Object> allFields = new Map<String, Object>();

        if (record == null) {
            System.debug(logPrefix + '[BaseContextFormatter] Record is null, returning empty map');
            return allFields;
        }

        // Start with direct populated fields
        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
        System.debug(logPrefix + '[BaseContextFormatter] Populated fields: ' + populatedFields);
        Schema.DescribeSObjectResult recordDescribe = record.getSObjectType().getDescribe();

        // Fetch field map once for performance optimization
        Map<String, SObjectField> fieldMap = SchemaUtils.getObjectFields(recordDescribe.getSObjectType());

        // Process each populated field
        for (String fieldName : populatedFields.keySet()) {
            Object fieldValue = populatedFields.get(fieldName);
            System.debug(logPrefix + '[BaseContextFormatter] Processing field ' + fieldName + ' with value: ' + fieldValue);

            // Skip child relationship lists (they're handled separately)
            if (fieldValue instanceof List<SObject>) {
                System.debug(logPrefix + '[BaseContextFormatter] Skipping child relationship list for field: ' + fieldName);
                continue;
            }

            // For direct fields, add them with proper labels
            if (!(fieldValue instanceof SObject)) {
                String fieldLabel = getFieldLabelFromFieldMap(fieldName, fieldMap);
                allFields.put(fieldLabel, fieldValue);
                System.debug(
                    logPrefix + '[BaseContextFormatter] Added direct field ' + fieldName + ' with label ' + fieldLabel + ' and value ' + fieldValue
                );
            } else {
                // For relationship fields, we need to traverse and extract accessible fields
                SObject relatedRecord = (SObject) fieldValue;
                String relationshipLabel = getFieldLabelFromFieldMap(fieldName, fieldMap);
                System.debug(logPrefix + '[BaseContextFormatter] Processing relationship field ' + fieldName + ' with label ' + relationshipLabel);
                Map<String, Object> relatedFields = extractRelatedFields(relatedRecord, relationshipLabel, logPrefix);
                allFields.putAll(relatedFields);
                System.debug(logPrefix + '[BaseContextFormatter] Added related fields: ' + relatedFields);
            }
        }

        System.debug(logPrefix + '[BaseContextFormatter] Final extracted fields: ' + allFields);
        return allFields;
    }

    /**
     * Recursively extracts fields from related SObjects, building human-readable field labels.
     *
     * @param relatedRecord  The related SObject to extract fields from.
     * @param pathPrefix     The current label path prefix (e.g., "Price Book Entry").
     * @param logPrefix      Logging prefix for debug messages.
     * @return               Map of field label paths to their values.
     */
    protected Map<String, Object> extractRelatedFields(SObject relatedRecord, String pathPrefix, String logPrefix) {
        System.debug(logPrefix + '[BaseContextFormatter] extractRelatedFields called with pathPrefix: ' + pathPrefix);
        Map<String, Object> relatedFields = new Map<String, Object>();

        if (relatedRecord == null) {
            System.debug(logPrefix + '[BaseContextFormatter] Related record is null, returning empty map');
            return relatedFields;
        }

        try {
            Map<String, Object> relatedPopulatedFields = relatedRecord.getPopulatedFieldsAsMap();
            System.debug(logPrefix + '[BaseContextFormatter] Related populated fields: ' + relatedPopulatedFields);
            Schema.DescribeSObjectResult relatedDescribe = relatedRecord.getSObjectType().getDescribe();

            // Fetch field map once for performance optimization
            Map<String, SObjectField> relatedFieldMap = SchemaUtils.getObjectFields(relatedDescribe.getSObjectType());

            for (String fieldName : relatedPopulatedFields.keySet()) {
                Object fieldValue = relatedPopulatedFields.get(fieldName);
                System.debug(logPrefix + '[BaseContextFormatter] Processing related field ' + fieldName + ' with value: ' + fieldValue);

                // Skip child relationship lists
                if (fieldValue instanceof List<SObject>) {
                    System.debug(logPrefix + '[BaseContextFormatter] Skipping child relationship list for related field: ' + fieldName);
                    continue;
                }

                String fieldLabel = getFieldLabelFromFieldMap(fieldName, relatedFieldMap);
                String fullLabelPath = pathPrefix + ' → ' + fieldLabel;
                System.debug(logPrefix + '[BaseContextFormatter] Full label path: ' + fullLabelPath);

                if (!(fieldValue instanceof SObject)) {
                    // Direct field value
                    relatedFields.put(fullLabelPath, fieldValue);
                    System.debug(logPrefix + '[BaseContextFormatter] Added related direct field ' + fullLabelPath + ' with value ' + fieldValue);
                } else {
                    // Nested relationship - recurse (but limit depth to prevent infinite loops)
                    if (pathPrefix.split('→').size() < 3) {
                        // Limit to 3 levels deep
                        SObject nestedRecord = (SObject) fieldValue;
                        Map<String, Object> nestedFields = extractRelatedFields(nestedRecord, fullLabelPath, logPrefix);
                        relatedFields.putAll(nestedFields);
                        System.debug(logPrefix + '[BaseContextFormatter] Added nested fields: ' + nestedFields);
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to extract fields from related record at path ' + pathPrefix + ': ' + e.getMessage());
        }

        System.debug(logPrefix + '[BaseContextFormatter] Final related fields: ' + relatedFields);
        return relatedFields;
    }

    /**
     * Converts a string value back to its appropriate data type for better serialization.
     * This helps maintain proper data types in output rather than everything being strings.
     *
     * @param stringValue  The string representation of the value.
     * @param originalValue The original field value for type inference.
     * @return             The value converted to appropriate type.
     */
    protected Object convertToAppropriateType(String stringValue, Object originalValue) {
        if (String.isBlank(stringValue)) {
            return stringValue;
        }

        // If original value was already a primitive type, try to preserve it
        if (originalValue instanceof Boolean) {
            return originalValue;
        }
        if (originalValue instanceof Integer || originalValue instanceof Long) {
            return originalValue;
        }
        if (originalValue instanceof Decimal || originalValue instanceof Double) {
            return originalValue;
        }
        if (originalValue instanceof Date || originalValue instanceof Datetime) {
            return originalValue;
        }

        // For string values, attempt intelligent conversion
        // Boolean detection
        if ('true'.equalsIgnoreCase(stringValue) || 'false'.equalsIgnoreCase(stringValue)) {
            return Boolean.valueOf(stringValue);
        }

        // Number detection (be conservative to avoid false positives)
        if (stringValue.isNumeric()) {
            try {
                if (stringValue.contains('.')) {
                    return Decimal.valueOf(stringValue);
                } else {
                    return Integer.valueOf(stringValue);
                }
            } catch (Exception e) {
                // If conversion fails, return as string
                return stringValue;
            }
        }

        // Default to string
        return stringValue;
    }

    /**
     * Creates standardized metadata for formatter output
     *
     * @param formatStrategy The formatting approach used
     * @param generatorName The name of the generator class
     * @return Map containing standardized metadata
     */
    protected Map<String, Object> createStandardMetadata(String formatStrategy, String generatorName) {
        System.debug('createStandardMetadata called with formatStrategy: ' + formatStrategy + ', generatorName: ' + generatorName);
        Map<String, Object> metadata = new Map<String, Object>();
        metadata.put('format', formatStrategy);
        metadata.put('generatedAt', Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        metadata.put('generator', generatorName);
        metadata.put('version', METADATA_VERSION);
        metadata.put('description', 'Structured ' + formatStrategy + ' representation of Salesforce SObject data for LLM consumption');
        System.debug('createStandardMetadata returning: ' + metadata);
        return metadata;
    }

    /**
     * Handles errors gracefully and returns structured error information
     *
     * @param errorMessage The error message
     * @param logPrefix Logging prefix for debug messages
     * @return Map containing structured error information
     */
    protected Map<String, Object> handleFormattingError(String errorMessage, String logPrefix) {
        System.debug(LoggingLevel.ERROR, logPrefix + 'Formatting error: ' + errorMessage);

        Map<String, Object> errorInfo = new Map<String, Object>();
        errorInfo.put('error', true);
        errorInfo.put('message', errorMessage);
        errorInfo.put('timestamp', Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        errorInfo.put('severity', 'warning');
        errorInfo.put('suggestion', 'Check the input data and try again');

        return errorInfo;
    }
}
