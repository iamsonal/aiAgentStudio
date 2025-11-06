/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * StructuredTextContextFormatter formats SObject data into readable Markdown-style structured text.
 * Creates grouped sections with clear record separation and field labels.
 * Handles child relationships by formatting them as nested sections.
 */
public inherited sharing class StructuredTextContextFormatter extends BaseContextFormatter implements IContextFormatter {
    private static final String FORMAT_STRATEGY = 'Structured Text';
    private static final String GENERATOR_NAME = 'StructuredTextContextFormatter';

    public StructuredTextContextFormatter() {
        super();
    }

    /**
     * Main entry point for formatting SObject data into structured text format for LLMs.
     *
     * @param records         List of SObjects to format for LLM context.
     * @param logPrefix       Logging prefix for debug messages.
     * @return                Structured text formatted context string ready for LLM consumption.
     */
    public String formatContext(List<SObject> records, String logPrefix) {
        try {
            System.debug(logPrefix + 'formatContext called with records: ' + records);
            if (records == null || records.isEmpty()) {
                System.debug(logPrefix + 'Records is null or empty, returning empty string');
                return formatEmptyResult();
            }

            // Add metadata header
            String result = formatMetadataHeader();

            // Group records by type for organized formatting
            Map<String, List<SObject>> recordsByType = groupRecordsByType(records);
            System.debug(logPrefix + 'Records grouped by type: ' + recordsByType);
            List<String> allFormattedBlocks = new List<String>();

            for (String sObjTypeName : recordsByType.keySet()) {
                List<SObject> sObjectList = recordsByType.get(sObjTypeName);
                System.debug(logPrefix + 'Formatting ' + sObjectList.size() + ' records of type ' + sObjTypeName);
                String formattedBlock = formatAsStructuredText(sObjectList, logPrefix);

                if (String.isNotBlank(formattedBlock)) {
                    allFormattedBlocks.add(formattedBlock);
                }
            }

            result += String.join(allFormattedBlocks, '\n\n');
            result += '\n\n---\nEND OF CONTEXT DATA\n---';

            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatContext: ' + e.getMessage());
            return formatErrorResult('Unexpected error: ' + e.getMessage(), logPrefix);
        }
    }

    /**
     * Formats SObjects into readable Markdown-style structured text.
     * Creates grouped sections with clear record separation and field labels.
     * Handles child relationships by formatting them as nested sections.
     *
     * @param sObjectList   List of records of the same SObjectType to format.
     * @param logPrefix     Logging prefix for debug messages.
     * @return              Markdown-formatted string with organized record data.
     */
    private String formatAsStructuredText(List<SObject> sObjectList, String logPrefix) {
        try {
            System.debug(logPrefix + 'formatAsStructuredText called with ' + sObjectList.size() + ' records');
            if (sObjectList.isEmpty())
                return '';

            Schema.DescribeSObjectResult objectDescribe = sObjectList[0].getSObjectType().getDescribe();
            System.debug(logPrefix + 'Object describe: ' + objectDescribe);
            if (objectDescribe == null)
                return '';

            Set<String> allFieldNames = new Set<String>();
            for (SObject record : sObjectList) {
                allFieldNames.addAll(record.getPopulatedFieldsAsMap().keySet());
            }
            System.debug(logPrefix + 'All field names: ' + allFieldNames);

            // Create section header with object information
            String groupHeader = '## ' + objectDescribe.getLabelPlural() + ' (' + sObjectList.size() + ' Records)';
            System.debug(logPrefix + 'Group header: ' + groupHeader);
            List<String> recordBlocks = new List<String>();

            for (SObject record : sObjectList) {
                try {
                    System.debug(logPrefix + 'Processing record: ' + record);
                    List<String> fieldEntries = new List<String>();
                    List<String> childRelationshipBlocks = new List<String>();
                    Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
                    System.debug(logPrefix + 'Populated fields: ' + populatedFields);

                    // Identify primary display field for record title
                    String primaryDisplayFieldApiName = findPrimaryDisplayField(populatedFields.keySet(), objectDescribe);
                    System.debug(logPrefix + 'Primary display field: ' + primaryDisplayFieldApiName);

                    if (String.isNotBlank(primaryDisplayFieldApiName) && populatedFields.get(primaryDisplayFieldApiName) != null) {
                        String primaryValue = String.valueOf(populatedFields.get(primaryDisplayFieldApiName));
                        fieldEntries.add('**' + primaryValue + '**');
                        System.debug(logPrefix + 'Added primary field entry: ' + primaryValue);
                    }

                    // Extract all accessible fields including relationship fields
                    Map<String, Object> allAccessibleFields = extractAllAccessibleFields(record, logPrefix);
                    System.debug(logPrefix + 'All accessible fields: ' + allAccessibleFields);

                    // Handle child relationships separately
                    for (String fieldName : populatedFields.keySet()) {
                        Object value = populatedFields.get(fieldName);
                        if (value instanceof List<SObject>) {
                            List<SObject> childRecords = (List<SObject>) value;
                            if (!childRecords.isEmpty()) {
                                String childBlock = formatChildRelationship(fieldName, childRecords, logPrefix);
                                if (String.isNotBlank(childBlock)) {
                                    childRelationshipBlocks.add(childBlock);
                                }
                            }
                        }
                    }

                    // Sort field labels for consistent output
                    List<String> sortedFieldLabels = new List<String>(allAccessibleFields.keySet());
                    sortedFieldLabels.sort();

                    for (String fieldLabel : sortedFieldLabels) {
                        // Skip primary field already used as title (compare by label)
                        String primaryFieldLabel = '';
                        if (String.isNotBlank(primaryDisplayFieldApiName)) {
                            primaryFieldLabel = getFieldLabel(primaryDisplayFieldApiName, objectDescribe);
                        }

                        if (fieldLabel.equalsIgnoreCase(primaryFieldLabel))
                            continue;

                        Object value = allAccessibleFields.get(fieldLabel);
                        String displayValue = (value == null) ? '[Not Set]' : String.valueOf(value).replace('\n', ' ').replace('\r', '');

                        fieldEntries.add(fieldLabel + ': ' + displayValue);
                    }

                    // Combine main record fields with child relationships
                    List<String> recordParts = new List<String>();
                    if (!fieldEntries.isEmpty()) {
                        recordParts.add(String.join(fieldEntries, '\n'));
                    }
                    if (!childRelationshipBlocks.isEmpty()) {
                        recordParts.addAll(childRelationshipBlocks);
                    }

                    if (!recordParts.isEmpty()) {
                        String recordBlock = String.join(recordParts, '\n\n');
                        recordBlocks.add(recordBlock);
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing record: ' + e.getMessage());
                    recordBlocks.add('**Error processing record**: ' + e.getMessage());
                }
            }

            if (recordBlocks.isEmpty())
                return '';

            // Combine record blocks with clear separators
            String result = groupHeader + '\n\n' + String.join(recordBlocks, '\n\n---\n\n');
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatAsStructuredText: ' + e.getMessage());
            return '**Error in formatAsStructuredText**: ' + e.getMessage();
        }
    }

    /**
     * Formats child relationship records as a nested section within the parent record.
     *
     * @param relationshipName  The name of the child relationship field.
     * @param childRecords      List of child SObject records.
     * @param logPrefix         Logging prefix for debug messages.
     * @return                  Formatted string for the child relationship section.
     */
    private String formatChildRelationship(String relationshipName, List<SObject> childRecords, String logPrefix) {
        try {
            if (childRecords == null || childRecords.isEmpty()) {
                return '';
            }

            // Create header for child relationship section
            String childHeader = '### ' + relationshipName + ' (' + childRecords.size() + ' items)';
            List<String> childRecordBlocks = new List<String>();

            for (SObject childRecord : childRecords) {
                try {
                    List<String> childFieldEntries = new List<String>();
                    Map<String, Object> allAccessibleFields = extractAllAccessibleFields(childRecord, logPrefix);

                    // Sort field labels for consistent output
                    List<String> sortedFieldLabels = new List<String>(allAccessibleFields.keySet());
                    sortedFieldLabels.sort();

                    for (String fieldLabel : sortedFieldLabels) {
                        Object fieldValue = allAccessibleFields.get(fieldLabel);
                        String displayValue = (fieldValue == null) ? '[Not Set]' : String.valueOf(fieldValue).replace('\n', ' ').replace('\r', '');

                        childFieldEntries.add('  ' + fieldLabel + ': ' + displayValue);
                    }

                    if (!childFieldEntries.isEmpty()) {
                        childRecordBlocks.add(String.join(childFieldEntries, '\n'));
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing child record: ' + e.getMessage());
                    childRecordBlocks.add('  **Error processing child record**: ' + e.getMessage());
                }
            }

            if (childRecordBlocks.isEmpty()) {
                return '';
            }

            return childHeader + '\n' + String.join(childRecordBlocks, '\n\n');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in formatChildRelationship: ' + e.getMessage());
            return '### ' + relationshipName + ' (Error: ' + e.getMessage() + ')';
        }
    }

    /**
     * Format metadata header for structured text
     */
    private String formatMetadataHeader() {
        String header = '---\n';
        header += 'METADATA\n';
        header += 'Format: ' + FORMAT_STRATEGY + '\n';
        header += 'Generated At: ' + Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '\n';
        header += 'Generator: ' + GENERATOR_NAME + '\n';
        header += 'Version: 1.0\n';
        header += 'Description: Human-readable structured text representation of Salesforce SObject data for LLM consumption\n';
        header += '---\n\n';
        return header;
    }

    /**
     * Format empty result with metadata
     */
    private String formatEmptyResult() {
        String result = formatMetadataHeader();
        result += 'No records to format\n';
        result += '\n---\nEND OF CONTEXT DATA\n---';
        return result;
    }

    /**
     * Format error result with structured error information
     */
    private String formatErrorResult(String errorMessage, String logPrefix) {
        String result = formatMetadataHeader();
        result += '**Error**: ' + errorMessage + '\n';
        result += '**Timestamp**: ' + Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '\n';
        result += '**Severity**: Warning\n';
        result += '**Suggestion**: Check the input data and try again\n';
        result += '\n---\nEND OF CONTEXT DATA\n---';
        return result;
    }
}
