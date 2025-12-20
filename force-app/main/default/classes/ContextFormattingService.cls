/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ContextFormattingService provides unified context formatting for SObject data into various formats
 * optimized for LLM (Large Language Model) consumption. Supports JSON, XML, and Structured Text formats
 * using a single service with internal strategy handling.
 */
public inherited sharing class ContextFormattingService {
    // Constants for metadata
    private static final String METADATA_VERSION = '1.0';

    public ContextFormattingService() {
        // Default constructor
    }

    /**
     * Main entry point for formatting SObject data based on the specified format strategy.
     * Routes to the appropriate internal formatting method based on strategy.
     *
     * @param records         List of SObjects to format for LLM context.
     * @param logPrefix       Logging prefix for debug messages.
     * @param formatStrategy  The format strategy to use: 'JSON', 'XML', or 'Structured Text'
     * @return                Formatted context string ready for LLM consumption.
     */
    public String formatContext(List<SObject> records, String logPrefix, String formatStrategy) {
        System.debug(logPrefix + 'ContextFormattingService.formatContext called with strategy: ' + formatStrategy);

        if (String.isBlank(formatStrategy)) {
            formatStrategy = 'Structured Text'; // Default fallback
        }

        switch on formatStrategy {
            when 'JSON' {
                return formatAsJson(records, logPrefix);
            }
            when 'XML' {
                return formatAsXml(records, logPrefix);
            }
            when 'Structured Text' {
                return formatAsStructuredText(records, logPrefix);
            }
            when else {
                System.debug(LoggingLevel.WARN, logPrefix + 'Unknown format strategy: ' + formatStrategy + '. Defaulting to Structured Text.');
                return formatAsStructuredText(records, logPrefix);
            }
        }
    }

    // ===================================================================================
    // JSON FORMATTING
    // ===================================================================================

    /**
     * Formats SObjects into clean JSON format optimized for modern LLM consumption.
     * Creates a structured JSON representation with organized object groups and field metadata.
     */
    private String formatAsJson(List<SObject> records, String logPrefix) {
        try {
            System.debug(logPrefix + 'formatAsJson called with records: ' + records);
            if (records == null || records.isEmpty()) {
                return formatEmptyResultJson();
            }

            // Group records by type for organized formatting
            Map<String, List<SObject>> recordsByType = groupRecordsByType(records);
            List<String> allFormattedBlocks = new List<String>();

            for (String sObjTypeName : recordsByType.keySet()) {
                List<SObject> sObjectList = recordsByType.get(sObjTypeName);
                String formattedBlock = formatSObjectListAsJson(sObjectList, logPrefix);

                if (String.isNotBlank(formattedBlock)) {
                    allFormattedBlocks.add(formattedBlock);
                }
            }

            // For JSON, we want to return a single JSON structure
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
                    return formatErrorResultJson('Failed to serialize combined JSON: ' + e.getMessage(), logPrefix);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatAsJson: ' + e.getMessage());
            return formatErrorResultJson('Unexpected error: ' + e.getMessage(), logPrefix);
        }
    }

    private String formatSObjectListAsJson(List<SObject> sObjectList, String logPrefix) {
        try {
            if (sObjectList.isEmpty()) {
                return formatEmptyResultJson();
            }

            Schema.DescribeSObjectResult objectDescribe = sObjectList[0].getSObjectType().getDescribe();
            if (objectDescribe == null) {
                return formatEmptyResultJson();
            }

            // Build JSON structure
            Map<String, Object> jsonStructure = new Map<String, Object>();

            // Add standardized metadata
            jsonStructure.put('metadata', createStandardMetadata('JSON', 'ContextFormattingService'));

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
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to serialize JSON: ' + e.getMessage());
                return formatErrorResultJson('Failed to serialize JSON: ' + e.getMessage(), logPrefix);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatSObjectListAsJson: ' + e.getMessage());
            return formatErrorResultJson('Unexpected error: ' + e.getMessage(), logPrefix);
        }
    }

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

                        if (fieldValue == null) {
                            childRecordMap.put(fieldLabel, null);
                            continue;
                        }

                        String displayValue = String.valueOf(fieldValue);
                        Object finalValue = convertToAppropriateType(displayValue, fieldValue);
                        childRecordMap.put(fieldLabel, finalValue);
                    }

                    if (!childRecordMap.isEmpty()) {
                        childRecordsArray.add(childRecordMap);
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing child record: ' + e.getMessage());
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

    private String formatEmptyResultJson() {
        try {
            Map<String, Object> emptyResult = new Map<String, Object>();
            emptyResult.put('metadata', createStandardMetadata('JSON', 'ContextFormattingService'));
            emptyResult.put('message', 'No records to format');
            return JSON.serializePretty(emptyResult);
        } catch (Exception e) {
            return '{"error": "Failed to create empty result"}';
        }
    }

    private String formatErrorResultJson(String errorMessage, String logPrefix) {
        try {
            Map<String, Object> errorResult = new Map<String, Object>();
            errorResult.put('metadata', createStandardMetadata('JSON', 'ContextFormattingService'));
            errorResult.put('error', handleFormattingError(errorMessage, logPrefix));
            return JSON.serializePretty(errorResult);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in formatErrorResultJson: ' + e.getMessage());
            return '{"error": "Failed to create error result"}';
        }
    }

    // ===================================================================================
    // XML FORMATTING
    // ===================================================================================

    /**
     * Formats SObjects into structured XML format optimized for LLM consumption.
     */
    private String formatAsXml(List<SObject> records, String logPrefix) {
        try {
            if (records == null || records.isEmpty()) {
                return formatEmptyResultXml();
            }

            // Add XML declaration and root element
            String xmlResult = '<?xml version="1.0" encoding="UTF-8"?>\n';
            xmlResult +=
                '<context_data format="XML" generatedAt="' +
                Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') +
                '" generator="ContextFormattingService" version="1.0">\n';

            // Add metadata section
            xmlResult += '  <metadata>\n';
            xmlResult += '    <description>Structured XML representation of Salesforce SObject data for LLM consumption</description>\n';
            xmlResult += '    <formatting_strategy>XML</formatting_strategy>\n';
            xmlResult += '  </metadata>\n';

            // Group records by type
            Map<String, List<SObject>> recordsByType = groupRecordsByType(records);
            List<String> allFormattedBlocks = new List<String>();

            for (String sObjTypeName : recordsByType.keySet()) {
                List<SObject> sObjectList = recordsByType.get(sObjTypeName);
                String formattedBlock = formatSObjectListAsXml(sObjectList, logPrefix);

                if (String.isNotBlank(formattedBlock)) {
                    allFormattedBlocks.add(formattedBlock);
                }
            }

            xmlResult += String.join(allFormattedBlocks, '\n\n');
            xmlResult += '\n</context_data>';

            return xmlResult;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatAsXml: ' + e.getMessage());
            return formatErrorResultXml('Unexpected error: ' + e.getMessage(), logPrefix);
        }
    }

    private String formatSObjectListAsXml(List<SObject> sObjectList, String logPrefix) {
        try {
            if (sObjectList.isEmpty()) {
                return '';
            }

            Schema.DescribeSObjectResult objectDescribe = sObjectList[0].getSObjectType().getDescribe();
            if (objectDescribe == null) {
                return '';
            }

            List<String> recordXmlBlocks = new List<String>();
            for (SObject record : sObjectList) {
                try {
                    List<String> fieldXmlTags = new List<String>();
                    List<String> childRelationshipXml = new List<String>();
                    Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

                    // Handle child relationships separately
                    for (String fieldName : populatedFields.keySet()) {
                        Object value = populatedFields.get(fieldName);
                        if (value instanceof List<SObject>) {
                            List<SObject> childRecords = (List<SObject>) value;
                            if (!childRecords.isEmpty()) {
                                String childXml = formatChildRelationshipAsXml(fieldName, childRecords, logPrefix);
                                if (String.isNotBlank(childXml)) {
                                    childRelationshipXml.add(childXml);
                                }
                            }
                        }
                    }

                    // Extract all accessible fields
                    Map<String, Object> allAccessibleFields = extractAllAccessibleFields(record, logPrefix);

                    for (String fieldLabel : allAccessibleFields.keySet()) {
                        Object value = allAccessibleFields.get(fieldLabel);
                        String displayValue = (value == null) ? '' : String.valueOf(value);
                        fieldXmlTags.add('    <field label="' + fieldLabel.escapeHtml4() + '">' + displayValue.escapeHtml4() + '</field>');
                    }

                    // Combine main record fields with child relationships
                    List<String> recordParts = new List<String>();
                    recordParts.addAll(fieldXmlTags);
                    recordParts.addAll(childRelationshipXml);

                    if (!recordParts.isEmpty()) {
                        recordXmlBlocks.add('  <record>\n' + String.join(recordParts, '\n') + '\n  </record>');
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing record: ' + e.getMessage());
                    recordXmlBlocks.add('  <record>\n    <error message="' + e.getMessage().escapeHtml4() + '" />\n  </record>');
                }
            }

            if (recordXmlBlocks.isEmpty()) {
                return '';
            }

            String finalBlock = '<object_group label="' + objectDescribe.getLabelPlural().escapeHtml4() + '">\n';
            finalBlock += '  <object_info api_name="' + objectDescribe.getName() + '" label="' + objectDescribe.getLabel().escapeHtml4() + '" />\n';
            finalBlock += String.join(recordXmlBlocks, '\n');
            finalBlock += '\n</object_group>';

            return finalBlock;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatSObjectListAsXml: ' + e.getMessage());
            return '<error message="' + e.getMessage().escapeHtml4() + '" />';
        }
    }

    private String formatChildRelationshipAsXml(String relationshipName, List<SObject> childRecords, String logPrefix) {
        try {
            if (childRecords == null || childRecords.isEmpty()) {
                return '';
            }

            SObject firstChild = childRecords[0];
            Schema.DescribeSObjectResult childDescribe = firstChild.getSObjectType().getDescribe();
            if (childDescribe == null) {
                return '';
            }

            List<String> childRecordXml = new List<String>();
            for (SObject childRecord : childRecords) {
                try {
                    List<String> childFieldXml = new List<String>();
                    Map<String, Object> allAccessibleFields = extractAllAccessibleFields(childRecord, logPrefix);

                    for (String fieldLabel : allAccessibleFields.keySet()) {
                        Object fieldValue = allAccessibleFields.get(fieldLabel);
                        String displayValue = (fieldValue == null) ? '' : String.valueOf(fieldValue);
                        childFieldXml.add('        <field label="' + fieldLabel.escapeHtml4() + '">' + displayValue.escapeHtml4() + '</field>');
                    }

                    if (!childFieldXml.isEmpty()) {
                        childRecordXml.add('      <child_record>\n' + String.join(childFieldXml, '\n') + '\n      </child_record>');
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing child record: ' + e.getMessage());
                    childRecordXml.add(
                        '      <child_record>\n        <error message="' + e.getMessage().escapeHtml4() + '" />\n      </child_record>'
                    );
                }
            }

            if (childRecordXml.isEmpty()) {
                return '';
            }

            return '    <child_relationship name="' +
                relationshipName.escapeHtml4() +
                '" object_type="' +
                childDescribe.getName() +
                '" object_label="' +
                childDescribe.getLabel().escapeHtml4() +
                '">\n' +
                String.join(childRecordXml, '\n') +
                '\n' +
                '    </child_relationship>';
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in formatChildRelationshipAsXml: ' + e.getMessage());
            return '    <child_relationship_error message="' +
                e.getMessage().escapeHtml4() +
                '" relationship="' +
                relationshipName.escapeHtml4() +
                '" />';
        }
    }

    private String formatEmptyResultXml() {
        String xmlResult = '<?xml version="1.0" encoding="UTF-8"?>\n';
        xmlResult +=
            '<context_data format="XML" generatedAt="' +
            Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') +
            '" generator="ContextFormattingService" version="1.0">\n';
        xmlResult += '  <metadata>\n';
        xmlResult += '    <description>Structured XML representation of Salesforce SObject data for LLM consumption</description>\n';
        xmlResult += '    <message>No records to format</message>\n';
        xmlResult += '  </metadata>\n';
        xmlResult += '</context_data>';
        return xmlResult;
    }

    private String formatErrorResultXml(String errorMessage, String logPrefix) {
        String xmlResult = '<?xml version="1.0" encoding="UTF-8"?>\n';
        xmlResult +=
            '<context_data format="XML" generatedAt="' +
            Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') +
            '" generator="ContextFormattingService" version="1.0">\n';
        xmlResult += '  <metadata>\n';
        xmlResult += '    <description>Structured XML representation of Salesforce SObject data for LLM consumption</description>\n';
        xmlResult += '    <error message="' + errorMessage.escapeHtml4() + '" />\n';
        xmlResult += '  </metadata>\n';
        xmlResult += '</context_data>';
        return xmlResult;
    }

    // ===================================================================================
    // STRUCTURED TEXT FORMATTING
    // ===================================================================================

    /**
     * Formats SObjects into readable Markdown-style structured text.
     */
    private String formatAsStructuredText(List<SObject> records, String logPrefix) {
        try {
            if (records == null || records.isEmpty()) {
                return formatEmptyResultStructuredText();
            }

            // Add metadata header
            String result = formatMetadataHeaderStructuredText();

            // Group records by type
            Map<String, List<SObject>> recordsByType = groupRecordsByType(records);
            List<String> allFormattedBlocks = new List<String>();

            for (String sObjTypeName : recordsByType.keySet()) {
                List<SObject> sObjectList = recordsByType.get(sObjTypeName);
                String formattedBlock = formatSObjectListAsStructuredText(sObjectList, logPrefix);

                if (String.isNotBlank(formattedBlock)) {
                    allFormattedBlocks.add(formattedBlock);
                }
            }

            result += String.join(allFormattedBlocks, '\n\n');
            result += '\n\n---\nEND OF CONTEXT DATA\n---';

            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatAsStructuredText: ' + e.getMessage());
            return formatErrorResultStructuredText('Unexpected error: ' + e.getMessage(), logPrefix);
        }
    }

    private String formatSObjectListAsStructuredText(List<SObject> sObjectList, String logPrefix) {
        try {
            if (sObjectList.isEmpty()) {
                return '';
            }

            Schema.DescribeSObjectResult objectDescribe = sObjectList[0].getSObjectType().getDescribe();
            if (objectDescribe == null) {
                return '';
            }

            // Create section header
            String groupHeader = '## ' + objectDescribe.getLabelPlural() + ' (' + sObjectList.size() + ' Records)';
            List<String> recordBlocks = new List<String>();

            for (SObject record : sObjectList) {
                try {
                    List<String> fieldEntries = new List<String>();
                    List<String> childRelationshipBlocks = new List<String>();
                    Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

                    // Identify primary display field
                    String primaryDisplayFieldApiName = findPrimaryDisplayField(populatedFields.keySet(), objectDescribe);

                    if (String.isNotBlank(primaryDisplayFieldApiName) && populatedFields.get(primaryDisplayFieldApiName) != null) {
                        String primaryValue = String.valueOf(populatedFields.get(primaryDisplayFieldApiName));
                        fieldEntries.add('**' + primaryValue + '**');
                    }

                    // Extract all accessible fields
                    Map<String, Object> allAccessibleFields = extractAllAccessibleFields(record, logPrefix);

                    // Handle child relationships separately
                    for (String fieldName : populatedFields.keySet()) {
                        Object value = populatedFields.get(fieldName);
                        if (value instanceof List<SObject>) {
                            List<SObject> childRecords = (List<SObject>) value;
                            if (!childRecords.isEmpty()) {
                                String childBlock = formatChildRelationshipStructuredText(fieldName, childRecords, logPrefix);
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
                        // Skip primary field already used as title
                        String primaryFieldLabel = '';
                        if (String.isNotBlank(primaryDisplayFieldApiName)) {
                            primaryFieldLabel = getFieldLabel(primaryDisplayFieldApiName, objectDescribe);
                        }

                        if (fieldLabel.equalsIgnoreCase(primaryFieldLabel)) {
                            continue;
                        }

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
                        recordBlocks.add(String.join(recordParts, '\n\n'));
                    }
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, logPrefix + 'Error processing record: ' + e.getMessage());
                    recordBlocks.add('**Error processing record**: ' + e.getMessage());
                }
            }

            if (recordBlocks.isEmpty()) {
                return '';
            }

            return groupHeader + '\n\n' + String.join(recordBlocks, '\n\n---\n\n');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatSObjectListAsStructuredText: ' + e.getMessage());
            return '**Error in formatSObjectListAsStructuredText**: ' + e.getMessage();
        }
    }

    private String formatChildRelationshipStructuredText(String relationshipName, List<SObject> childRecords, String logPrefix) {
        try {
            if (childRecords == null || childRecords.isEmpty()) {
                return '';
            }

            String childHeader = '### ' + relationshipName + ' (' + childRecords.size() + ' items)';
            List<String> childRecordBlocks = new List<String>();

            for (SObject childRecord : childRecords) {
                try {
                    List<String> childFieldEntries = new List<String>();
                    Map<String, Object> allAccessibleFields = extractAllAccessibleFields(childRecord, logPrefix);

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
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in formatChildRelationshipStructuredText: ' + e.getMessage());
            return '### ' + relationshipName + ' (Error: ' + e.getMessage() + ')';
        }
    }

    private String formatMetadataHeaderStructuredText() {
        String header = '---\n';
        header += 'METADATA\n';
        header += 'Format: Structured Text\n';
        header += 'Generated At: ' + Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '\n';
        header += 'Generator: ContextFormattingService\n';
        header += 'Version: 1.0\n';
        header += 'Description: Human-readable structured text representation of Salesforce SObject data for LLM consumption\n';
        header += '---\n\n';
        return header;
    }

    private String formatEmptyResultStructuredText() {
        String result = formatMetadataHeaderStructuredText();
        result += 'No records to format\n';
        result += '\n---\nEND OF CONTEXT DATA\n---';
        return result;
    }

    private String formatErrorResultStructuredText(String errorMessage, String logPrefix) {
        String result = formatMetadataHeaderStructuredText();
        result += '**Error**: ' + errorMessage + '\n';
        result += '**Timestamp**: ' + Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '\n';
        result += '**Severity**: Warning\n';
        result += '**Suggestion**: Check the input data and try again\n';
        result += '\n---\nEND OF CONTEXT DATA\n---';
        return result;
    }

    // ===================================================================================
    // UTILITY METHODS
    // ===================================================================================

    /**
     * Groups a list of SObjects by their SObjectType name.
     *
     * @param records   List of SObjects to group.
     * @return          Map from SObjectType name to list of SObjects.
     */
    private Map<String, List<SObject>> groupRecordsByType(List<SObject> records) {
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
    private String findPrimaryDisplayField(Set<String> populatedFields, Schema.DescribeSObjectResult objectDescribe) {
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
    private String getFieldLabel(String fieldName, Schema.DescribeSObjectResult objectDescribe) {
        if (objectDescribe == null || String.isBlank(fieldName)) {
            System.debug('[ContextFormattingService] objectDescribe is null or fieldName is blank');
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
    private String getFieldLabelFromFieldMap(String fieldName, Map<String, SObjectField> fieldMap) {
        if (fieldMap == null || String.isBlank(fieldName)) {
            return fieldName;
        }

        SObjectField fieldToken = fieldMap.get(fieldName.toLowerCase());

        if (fieldToken != null && fieldToken.getDescribe().isAccessible()) {
            String label = fieldToken.getDescribe().getLabel();
            return label;
        }

        System.debug('[ContextFormattingService] Could not find label for ' + fieldName + ', returning fieldName');
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
    private Map<String, Object> extractAllAccessibleFields(SObject record, String logPrefix) {
        System.debug(logPrefix + '[ContextFormattingService] extractAllAccessibleFields called with record: ' + record);
        Map<String, Object> allFields = new Map<String, Object>();

        if (record == null) {
            System.debug(logPrefix + '[ContextFormattingService] Record is null, returning empty map');
            return allFields;
        }

        // Start with direct populated fields
        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
        System.debug(logPrefix + '[ContextFormattingService] Populated fields: ' + populatedFields);
        Schema.DescribeSObjectResult recordDescribe = record.getSObjectType().getDescribe();

        // Fetch field map once for performance optimization
        Map<String, SObjectField> fieldMap = SchemaUtils.getObjectFields(recordDescribe.getSObjectType());

        // Process each populated field
        for (String fieldName : populatedFields.keySet()) {
            Object fieldValue = populatedFields.get(fieldName);
            System.debug(logPrefix + '[ContextFormattingService] Processing field ' + fieldName + ' with value: ' + fieldValue);

            // Skip child relationship lists (they're handled separately)
            if (fieldValue instanceof List<SObject>) {
                System.debug(logPrefix + '[ContextFormattingService] Skipping child relationship list for field: ' + fieldName);
                continue;
            }

            // For direct fields, add them with proper labels
            if (!(fieldValue instanceof SObject)) {
                String fieldLabel = getFieldLabelFromFieldMap(fieldName, fieldMap);
                allFields.put(fieldLabel, fieldValue);
                System.debug(
                    logPrefix +
                        '[ContextFormattingService] Added direct field ' +
                        fieldName +
                        ' with label ' +
                        fieldLabel +
                        ' and value ' +
                        fieldValue
                );
            } else {
                // For relationship fields, we need to traverse and extract accessible fields
                SObject relatedRecord = (SObject) fieldValue;
                String relationshipLabel = getFieldLabelFromFieldMap(fieldName, fieldMap);
                System.debug(
                    logPrefix + '[ContextFormattingService] Processing relationship field ' + fieldName + ' with label ' + relationshipLabel
                );
                Map<String, Object> relatedFields = extractRelatedFields(relatedRecord, relationshipLabel, logPrefix);
                allFields.putAll(relatedFields);
                System.debug(logPrefix + '[ContextFormattingService] Added related fields: ' + relatedFields);
            }
        }

        System.debug(logPrefix + '[ContextFormattingService] Final extracted fields: ' + allFields);
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
    private Map<String, Object> extractRelatedFields(SObject relatedRecord, String pathPrefix, String logPrefix) {
        System.debug(logPrefix + '[ContextFormattingService] extractRelatedFields called with pathPrefix: ' + pathPrefix);
        Map<String, Object> relatedFields = new Map<String, Object>();

        if (relatedRecord == null) {
            System.debug(logPrefix + '[ContextFormattingService] Related record is null, returning empty map');
            return relatedFields;
        }

        try {
            Map<String, Object> relatedPopulatedFields = relatedRecord.getPopulatedFieldsAsMap();
            System.debug(logPrefix + '[ContextFormattingService] Related populated fields: ' + relatedPopulatedFields);
            Schema.DescribeSObjectResult relatedDescribe = relatedRecord.getSObjectType().getDescribe();

            // Fetch field map once for performance optimization
            Map<String, SObjectField> relatedFieldMap = SchemaUtils.getObjectFields(relatedDescribe.getSObjectType());

            for (String fieldName : relatedPopulatedFields.keySet()) {
                Object fieldValue = relatedPopulatedFields.get(fieldName);
                System.debug(logPrefix + '[ContextFormattingService] Processing related field ' + fieldName + ' with value: ' + fieldValue);

                // Skip child relationship lists
                if (fieldValue instanceof List<SObject>) {
                    System.debug(logPrefix + '[ContextFormattingService] Skipping child relationship list for related field: ' + fieldName);
                    continue;
                }

                String fieldLabel = getFieldLabelFromFieldMap(fieldName, relatedFieldMap);
                String fullLabelPath = pathPrefix + ' → ' + fieldLabel;
                System.debug(logPrefix + '[ContextFormattingService] Full label path: ' + fullLabelPath);

                if (!(fieldValue instanceof SObject)) {
                    // Direct field value
                    relatedFields.put(fullLabelPath, fieldValue);
                    System.debug(logPrefix + '[ContextFormattingService] Added related direct field ' + fullLabelPath + ' with value ' + fieldValue);
                } else {
                    // Nested relationship - recurse (but limit depth to prevent infinite loops)
                    if (pathPrefix.split('→').size() < 3) {
                        // Limit to 3 levels deep
                        SObject nestedRecord = (SObject) fieldValue;
                        Map<String, Object> nestedFields = extractRelatedFields(nestedRecord, fullLabelPath, logPrefix);
                        relatedFields.putAll(nestedFields);
                        System.debug(logPrefix + '[ContextFormattingService] Added nested fields: ' + nestedFields);
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to extract fields from related record at path ' + pathPrefix + ': ' + e.getMessage());
        }

        System.debug(logPrefix + '[ContextFormattingService] Final related fields: ' + relatedFields);
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
    private Object convertToAppropriateType(String stringValue, Object originalValue) {
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
    private Map<String, Object> createStandardMetadata(String formatStrategy, String generatorName) {
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
    private Map<String, Object> handleFormattingError(String errorMessage, String logPrefix) {
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
