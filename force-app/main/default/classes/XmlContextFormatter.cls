/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * XmlContextFormatter formats SObject data into structured XML format optimized for LLM consumption.
 * Creates hierarchical XML structure with object and field information, handling child relationships
 * by including them as nested XML sections.
 */
public inherited sharing class XmlContextFormatter extends BaseContextFormatter implements IContextFormatter {
    private static final String FORMAT_STRATEGY = 'XML';
    private static final String GENERATOR_NAME = 'XmlContextFormatter';

    public XmlContextFormatter() {
        super();
    }

    /**
     * Main entry point for formatting SObject data into XML format for LLMs.
     *
     * @param records         List of SObjects to format for LLM context.
     * @param logPrefix       Logging prefix for debug messages.
     * @return                XML formatted context string ready for LLM consumption.
     */
    public String formatContext(List<SObject> records, String logPrefix) {
        try {
            if (records == null || records.isEmpty()) {
                return formatEmptyResult();
            }

            // Add XML declaration and root element with metadata attributes
            String xmlResult = '<?xml version="1.0" encoding="UTF-8"?>\n';
            xmlResult +=
                '<context_data format="' +
                FORMAT_STRATEGY +
                '" generatedAt="' +
                Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') +
                '" generator="' +
                GENERATOR_NAME +
                '" version="1.0">\n';

            // Add metadata section
            xmlResult += '  <metadata>\n';
            xmlResult += '    <description>Structured XML representation of Salesforce SObject data for LLM consumption</description>\n';
            xmlResult += '    <formatting_strategy>' + FORMAT_STRATEGY + '</formatting_strategy>\n';
            xmlResult += '  </metadata>\n';

            // Group records by type for organized formatting
            Map<String, List<SObject>> recordsByType = groupRecordsByType(records);
            List<String> allFormattedBlocks = new List<String>();

            for (String sObjTypeName : recordsByType.keySet()) {
                List<SObject> sObjectList = recordsByType.get(sObjTypeName);
                String formattedBlock = formatAsXml(sObjectList, logPrefix);

                if (String.isNotBlank(formattedBlock)) {
                    allFormattedBlocks.add(formattedBlock);
                }
            }

            xmlResult += String.join(allFormattedBlocks, '\n\n');
            xmlResult += '\n</context_data>';

            return xmlResult;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatContext: ' + e.getMessage());
            return formatErrorResult('Unexpected error: ' + e.getMessage(), logPrefix);
        }
    }

    /**
     * Formats SObjects into structured XML format with field metadata.
     * Creates hierarchical XML structure with object and field information.
     * Handles child relationships by including them as nested XML sections.
     *
     * @param sObjectList   List of records of the same SObjectType to format.
     * @param logPrefix     Logging prefix for debug messages.
     * @return              XML-formatted string with object and field data.
     */
    private String formatAsXml(List<SObject> sObjectList, String logPrefix) {
        try {
            if (sObjectList.isEmpty())
                return '';

            Schema.DescribeSObjectResult objectDescribe = sObjectList[0].getSObjectType().getDescribe();
            if (objectDescribe == null)
                return '';

            Set<String> allFieldNames = new Set<String>();
            for (SObject record : sObjectList) {
                allFieldNames.addAll(record.getPopulatedFieldsAsMap().keySet());
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

                    // Extract all accessible fields including relationship fields
                    Map<String, Object> allAccessibleFields = extractAllAccessibleFields(record, logPrefix);

                    for (String fieldLabel : allAccessibleFields.keySet()) {
                        Object value = allAccessibleFields.get(fieldLabel);
                        String displayValue = (value == null) ? '' : String.valueOf(value);

                        // Use the human-readable field label for XML output
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

            if (recordXmlBlocks.isEmpty())
                return '';

            String finalBlock = '<object_group label="' + objectDescribe.getLabelPlural().escapeHtml4() + '">\n';
            finalBlock += '  <object_info api_name="' + objectDescribe.getName() + '" label="' + objectDescribe.getLabel().escapeHtml4() + '" />\n';
            finalBlock += String.join(recordXmlBlocks, '\n');
            finalBlock += '\n</object_group>';

            return finalBlock;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Unexpected error in formatAsXml: ' + e.getMessage());
            return '<error message="' + e.getMessage().escapeHtml4() + '" />';
        }
    }

    /**
     * Formats child relationship records as nested XML within the parent record.
     *
     * @param relationshipName  The name of the child relationship field.
     * @param childRecords      List of child SObject records.
     * @param logPrefix         Logging prefix for debug messages.
     * @return                  XML-formatted string for the child relationship section.
     */
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

            String childObjectName = childDescribe.getName();
            String childObjectLabel = childDescribe.getLabel();

            return '    <child_relationship name="' +
                relationshipName.escapeHtml4() +
                '" object_type="' +
                childObjectName +
                '" object_label="' +
                childObjectLabel.escapeHtml4() +
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

    /**
     * Format empty result with metadata
     */
    private String formatEmptyResult() {
        String xmlResult = '<?xml version="1.0" encoding="UTF-8"?>\n';
        xmlResult +=
            '<context_data format="' +
            FORMAT_STRATEGY +
            '" generatedAt="' +
            Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') +
            '" generator="' +
            GENERATOR_NAME +
            '" version="1.0">\n';
        xmlResult += '  <metadata>\n';
        xmlResult += '    <description>Structured XML representation of Salesforce SObject data for LLM consumption</description>\n';
        xmlResult += '    <message>No records to format</message>\n';
        xmlResult += '  </metadata>\n';
        xmlResult += '</context_data>';
        return xmlResult;
    }

    /**
     * Format error result with structured error information
     */
    private String formatErrorResult(String errorMessage, String logPrefix) {
        String xmlResult = '<?xml version="1.0" encoding="UTF-8"?>\n';
        xmlResult +=
            '<context_data format="' +
            FORMAT_STRATEGY +
            '" generatedAt="' +
            Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') +
            '" generator="' +
            GENERATOR_NAME +
            '" version="1.0">\n';
        xmlResult += '  <metadata>\n';
        xmlResult += '    <description>Structured XML representation of Salesforce SObject data for LLM consumption</description>\n';
        xmlResult += '    <error message="' + errorMessage.escapeHtml4() + '" />\n';
        xmlResult += '  </metadata>\n';
        xmlResult += '</context_data>';
        return xmlResult;
    }
}
