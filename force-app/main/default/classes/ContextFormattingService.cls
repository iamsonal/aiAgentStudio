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
public inherited sharing class ContextFormattingService extends BaseContextFormatter {
    private static final String METADATA_VERSION = '1.0';

    public ContextFormattingService() {
        super();
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
}
