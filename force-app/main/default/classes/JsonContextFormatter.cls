/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * JsonContextFormatter formats SObject data into clean JSON format optimized for modern LLM consumption.
 * Creates a structured JSON representation with organized object groups and field metadata.
 * Modern LLMs excel at parsing and understanding JSON structure, making this format
 * ideal for reliable data extraction and processing.
 */
public inherited sharing class JsonContextFormatter extends BaseContextFormatter implements IContextFormatter {
    private static final String FORMAT_STRATEGY = 'JSON';
    private static final String GENERATOR_NAME = 'JsonContextFormatter';

    public JsonContextFormatter() {
        super();
    }

    /**
     * Main entry point for formatting SObject data into JSON format for LLMs.
     *
     * @param records         List of SObjects to format for LLM context.
     * @param logPrefix       Logging prefix for debug messages.
     * @return                JSON formatted context string ready for LLM consumption.
     */
    public String formatContext(List<SObject> records, String logPrefix) {
        System.debug(logPrefix + 'formatContext called with records: ' + records);
        try {
            System.debug(logPrefix + 'Checking if records is null');
            if (records == null) {
                System.debug(logPrefix + 'Records is null, calling formatEmptyResult');
                return formatEmptyResult();
            }

            System.debug(logPrefix + 'Checking if records is empty');
            if (records.isEmpty()) {
                System.debug(logPrefix + 'Records is empty, calling formatEmptyResult');
                return formatEmptyResult();
            }

            System.debug(logPrefix + 'Records is not null or empty, processing records');

            // Group records by type for organized formatting
            Map<String, List<SObject>> recordsByType = groupRecordsByType(records);
            List<String> allFormattedBlocks = new List<String>();

            for (String sObjTypeName : recordsByType.keySet()) {
                List<SObject> sObjectList = recordsByType.get(sObjTypeName);
                String formattedBlock = formatAsJson(sObjectList, logPrefix);

                if (String.isNotBlank(formattedBlock)) {
                    allFormattedBlocks.add(formattedBlock);
                }
            }

            // For JSON, we want to return a single JSON structure, not multiple separate ones
            if (allFormattedBlocks.size() == 1) {
                return allFormattedBlocks[0];
            } else {
                // Combine multiple object groups into a single JSON array
                List<Object> jsonArray = new List<Object>();
                for (String block : allFormattedBlocks) {
                    try {
                        Object parsed = JSON.deserializeUntyped(block);
                        jsonArray.add(parsed);
                    } catch (Exception e) {
                        System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to parse JSON block: ' + e.getMessage());
                    }
                }

                try {
                    return JSON.serializePretty(jsonArray);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to serialize combined JSON: ' + e.getMessage());
                    return formatErrorResult('Failed to serialize combined JSON: ' + e.getMessage(), logPrefix);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatContext: ' + e.getMessage() + ' at line ' + e.getLineNumber());
            return formatErrorResult('Unexpected error: ' + e.getMessage(), logPrefix);
        }
    }

    /**
     * Formats SObjects into clean JSON format optimized for modern LLM consumption.
     * Creates a structured JSON representation with organized object groups and field metadata.
     * Modern LLMs excel at parsing and understanding JSON structure, making this format
     * ideal for reliable data extraction and processing.
     *
     * @param sObjectList   List of records of the same SObjectType to format.
     * @param logPrefix     Logging prefix for debug messages.
     * @return              JSON-formatted string with organized record data.
     */
    private String formatAsJson(List<SObject> sObjectList, String logPrefix) {
        try {
            System.debug(logPrefix + 'formatAsJson called with ' + sObjectList.size() + ' records');
            if (sObjectList.isEmpty()) {
                System.debug(logPrefix + 'sObjectList is empty, calling formatEmptyResult');
                return formatEmptyResult();
            }

            Schema.DescribeSObjectResult objectDescribe = sObjectList[0].getSObjectType().getDescribe();
            if (objectDescribe == null) {
                System.debug(logPrefix + 'objectDescribe is null, calling formatEmptyResult');
                return formatEmptyResult();
            }

            // Build JSON structure
            Map<String, Object> jsonStructure = new Map<String, Object>();

            // Add standardized metadata
            jsonStructure.put('metadata', createStandardMetadata(FORMAT_STRATEGY, GENERATOR_NAME));

            // Object metadata
            Map<String, Object> objectInfo = new Map<String, Object>();
            objectInfo.put('objectType', objectDescribe.getName());
            objectInfo.put('objectLabel', objectDescribe.getLabel());
            objectInfo.put('objectPluralLabel', objectDescribe.getLabelPlural());
            objectInfo.put('recordCount', sObjectList.size());
            jsonStructure.put('objectInfo', objectInfo);

            // Records array
            List<Object> recordsArray = new List<Object>();

            for (SObject record : sObjectList) {
                try {
                    Map<String, Object> recordMap = new Map<String, Object>();
                    Map<String, Object> fieldsMap = new Map<String, Object>();
                    Map<String, Object> childRelationshipsMap = new Map<String, Object>();

                    Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

                    // Handle child relationships separately
                    for (String fieldName : populatedFields.keySet()) {
                        Object value = populatedFields.get(fieldName);
                        if (value instanceof List<SObject>) {
                            List<SObject> childRecords = (List<SObject>) value;
                            if (!childRecords.isEmpty()) {
                                Object childJson = formatChildRelationshipAsJson(fieldName, childRecords, logPrefix);
                                if (childJson != null) {
                                    childRelationshipsMap.put(fieldName, childJson);
                                }
                            }
                        }
                    }

                    // Extract all accessible fields including relationship fields
                    Map<String, Object> allAccessibleFields = extractAllAccessibleFields(record, logPrefix);

                    for (String fieldLabel : allAccessibleFields.keySet()) {
                        Object value = allAccessibleFields.get(fieldLabel);

                        // Handle null values explicitly
                        if (value == null) {
                            fieldsMap.put(fieldLabel, null);
                            continue;
                        }

                        String displayValue = String.valueOf(value);

                        // Attempt to preserve data types for better JSON structure
                        Object finalValue = convertToAppropriateType(displayValue, value);
                        fieldsMap.put(fieldLabel, finalValue);
                    }

                    recordMap.put('fields', fieldsMap);
                    if (!childRelationshipsMap.isEmpty()) {
                        recordMap.put('childRelationships', childRelationshipsMap);
                    }

                    recordsArray.add(recordMap);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing record: ' + e.getMessage());
                    // Add error information to the record
                    Map<String, Object> errorRecord = new Map<String, Object>();
                    errorRecord.put('error', handleFormattingError('Error processing record: ' + e.getMessage(), logPrefix));
                    recordsArray.add(errorRecord);
                }
            }

            jsonStructure.put('records', recordsArray);

            // Convert to JSON string with proper formatting
            try {
                return JSON.serializePretty(jsonStructure);
            } catch (Exception e) {
                System.debug(
                    LoggingLevel.ERROR,
                    logPrefix + 'Failed to serialize JSON for object type ' + objectDescribe.getName() + ': ' + e.getMessage()
                );
                return formatErrorResult('Failed to serialize JSON: ' + e.getMessage(), logPrefix);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatAsJson: ' + e.getMessage());
            return formatErrorResult('Unexpected error in formatAsJson: ' + e.getMessage(), logPrefix);
        }
    }

    /**
     * Formats child relationship records as JSON structure within the parent record.
     *
     * @param relationshipName  The name of the child relationship field.
     * @param childRecords      List of child SObject records.
     * @param logPrefix         Logging prefix for debug messages.
     * @return                  JSON-compatible object for the child relationship section.
     */
    private Object formatChildRelationshipAsJson(String relationshipName, List<SObject> childRecords, String logPrefix) {
        try {
            if (childRecords == null || childRecords.isEmpty()) {
                return null;
            }

            SObject firstChild = childRecords[0];
            Schema.DescribeSObjectResult childDescribe = firstChild.getSObjectType().getDescribe();
            if (childDescribe == null) {
                return null;
            }

            Map<String, Object> childRelationshipStructure = new Map<String, Object>();

            // Child relationship metadata
            Map<String, Object> relationshipInfo = new Map<String, Object>();
            relationshipInfo.put('relationshipName', relationshipName);
            relationshipInfo.put('childObjectType', childDescribe.getName());
            relationshipInfo.put('childObjectLabel', childDescribe.getLabel());
            relationshipInfo.put('recordCount', childRecords.size());
            childRelationshipStructure.put('relationshipInfo', relationshipInfo);

            // Child records array
            List<Object> childRecordsArray = new List<Object>();

            for (SObject childRecord : childRecords) {
                try {
                    Map<String, Object> childRecordMap = new Map<String, Object>();
                    Map<String, Object> allAccessibleFields = extractAllAccessibleFields(childRecord, logPrefix);

                    for (String fieldLabel : allAccessibleFields.keySet()) {
                        Object fieldValue = allAccessibleFields.get(fieldLabel);

                        // Handle null values explicitly
                        if (fieldValue == null) {
                            childRecordMap.put(fieldLabel, null);
                            continue;
                        }

                        String displayValue = String.valueOf(fieldValue);

                        // Attempt to preserve data types for better JSON structure
                        Object finalValue = convertToAppropriateType(displayValue, fieldValue);
                        childRecordMap.put(fieldLabel, finalValue);
                    }

                    if (!childRecordMap.isEmpty()) {
                        childRecordsArray.add(childRecordMap);
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing child record: ' + e.getMessage());
                    // Add error information to the child record
                    Map<String, Object> errorChildRecord = new Map<String, Object>();
                    errorChildRecord.put('error', handleFormattingError('Error processing child record: ' + e.getMessage(), logPrefix));
                    childRecordsArray.add(errorChildRecord);
                }
            }

            childRelationshipStructure.put('records', childRecordsArray);
            return childRelationshipStructure;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in formatChildRelationshipAsJson: ' + e.getMessage());
            Map<String, Object> errorInfo = new Map<String, Object>();
            errorInfo.put('error', handleFormattingError('Error in child relationship formatting: ' + e.getMessage(), logPrefix));
            return errorInfo;
        }
    }

    /**
     * Format empty result with metadata
     */
    private String formatEmptyResult() {
        System.debug('formatEmptyResult called');
        try {
            Map<String, Object> emptyResult = new Map<String, Object>();
            emptyResult.put('metadata', createStandardMetadata(FORMAT_STRATEGY, GENERATOR_NAME));
            emptyResult.put('message', 'No records to format');
            String result = JSON.serializePretty(emptyResult);
            System.debug('formatEmptyResult returning: ' + result);
            return result;
        } catch (Exception e) {
            System.debug('Error in formatEmptyResult: ' + e.getMessage());
            return '{"error": "Failed to create empty result"}';
        }
    }

    /**
     * Format error result with structured error information
     */
    private String formatErrorResult(String errorMessage, String logPrefix) {
        try {
            Map<String, Object> errorResult = new Map<String, Object>();
            errorResult.put('metadata', createStandardMetadata(FORMAT_STRATEGY, GENERATOR_NAME));
            errorResult.put('error', handleFormattingError(errorMessage, logPrefix));
            return JSON.serializePretty(errorResult);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in formatErrorResult: ' + e.getMessage());
            return '{"error": "Failed to create error result"}';
        }
    }
}
