/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SObjectContextFormatter is a central formatting engine for converting SObject data into structured text formats
 * optimized for LLM (Large Language Model) consumption. It supports multiple formatting strategies (XML, Structured Text),
 * implements efficient schema caching to minimize describe calls per transaction, and ensures consistent, readable data
 * presentation for AI context injection and prompt engineering.
 *
 * Responsibilities:
 *   - Format SObject records into XML or Markdown-style structured text for LLMs
 *   - Group and organize records by type for clarity
 *   - Efficiently cache schema metadata to reduce describe call overhead
 *   - Provide extensible, maintainable formatting logic for AI context use cases
 */
public inherited sharing class SObjectContextFormatter {
    // Schema information cache container
    @TestVisible
    private class ObjectSchemaInfo {
        public DescribeSObjectResult objectDescribe { get; private set; }
        public Map<String, DescribeFieldResult> fieldDescribeMap { get; private set; } // Lowercase key
        private Map<String, Schema.SObjectField> fieldTokenMap { get; set; }

        public ObjectSchemaInfo(DescribeSObjectResult objDescribe) {
            this.objectDescribe = objDescribe;
            this.fieldDescribeMap = new Map<String, DescribeFieldResult>();
            this.fieldTokenMap = objDescribe.fields.getMap();
        }

        /**
         * Retrieves the DescribeFieldResult for a field, with lazy loading and caching.
         *
         * @param fieldName   The API name of the field to describe.
         * @return            DescribeFieldResult for the field, or null if not found.
         */
        public DescribeFieldResult getFieldDescribe(String fieldName) {
            String fieldNameLower = fieldName.toLowerCase();

            // Return cached result if available
            if (fieldDescribeMap.containsKey(fieldNameLower)) {
                return fieldDescribeMap.get(fieldNameLower);
            }

            // Locate and describe the field, then cache result
            for (String key : fieldTokenMap.keySet()) {
                if (key.equalsIgnoreCase(fieldName)) {
                    Schema.SObjectField fieldToken = fieldTokenMap.get(key);
                    DescribeFieldResult dfr = fieldToken.getDescribe();
                    fieldDescribeMap.put(dfr.getName().toLowerCase(), dfr);
                    return dfr;
                }
            }
            return null;
        }

        /**
         * Batch describes multiple fields to optimize performance and cache usage.
         *
         * @param fieldNames   Set of field names to describe.
         */
        public void describeFields(Set<String> fieldNames) {
            for (String fieldName : fieldNames) {
                getFieldDescribe(fieldName);
            }
        }
    }

    // Transaction-scoped schema information cache
    @TestVisible
    private static Map<SObjectType, ObjectSchemaInfo> schemaInfoCache = new Map<SObjectType, ObjectSchemaInfo>();

    /**
     * Main entry point for formatting SObject data into structured context for LLMs.
     * Groups records by type and applies the specified formatting strategy.
     *
     * @param records         List of SObjects to format for LLM context.
     * @param formatStrategy  The formatting approach ('XML' or 'StructuredText').
     * @param logPrefix       Logging prefix for debug messages.
     * @return                Formatted context string ready for LLM consumption.
     */
    public static String formatContext(List<SObject> records, String formatStrategy, String logPrefix) {
        if (records == null || records.isEmpty()) {
            return '';
        }

        // Group records by type for organized formatting
        Map<String, List<SObject>> recordsByType = groupRecordsByType(records);
        List<String> allFormattedBlocks = new List<String>();

        for (String sObjTypeName : recordsByType.keySet()) {
            List<SObject> sObjectList = recordsByType.get(sObjTypeName);
            String formattedBlock = '';

            // Apply appropriate formatting strategy
            if ('XML'.equalsIgnoreCase(formatStrategy)) {
                formattedBlock = formatAsXml(sObjectList, logPrefix);
            } else {
                // Default to StructuredText formatting
                formattedBlock = formatAsStructuredText(sObjectList, logPrefix);
            }

            if (String.isNotBlank(formattedBlock)) {
                allFormattedBlocks.add(formattedBlock);
            }
        }
        return String.join(allFormattedBlocks, '\n\n');
    }

    /**
     * Formats SObjects into structured XML format with field metadata.
     * Creates hierarchical XML structure with object and field information.
     *
     * @param sObjectList   List of records of the same SObjectType to format.
     * @param logPrefix     Logging prefix for debug messages.
     * @return              XML-formatted string with object and field data.
     */
    private static String formatAsXml(List<SObject> sObjectList, String logPrefix) {
        if (sObjectList.isEmpty())
            return '';

        ObjectSchemaInfo schemaInfo = getSchemaInfo(sObjectList[0].getSObjectType(), logPrefix);
        if (schemaInfo == null)
            return '';

        Set<String> allFieldNames = new Set<String>();
        for (SObject record : sObjectList) {
            allFieldNames.addAll(record.getPopulatedFieldsAsMap().keySet());
        }

        schemaInfo.describeFields(allFieldNames);

        List<String> recordXmlBlocks = new List<String>();
        for (SObject record : sObjectList) {
            List<String> fieldXmlTags = new List<String>();
            Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

            for (String fieldName : populatedFields.keySet()) {
                DescribeFieldResult dfr = schemaInfo.getFieldDescribe(fieldName);
                if (dfr != null && dfr.isAccessible()) {
                    Object value = populatedFields.get(fieldName);
                    String displayValue = (value == null) ? '' : String.valueOf(value);
                    // Escape HTML characters for safe XML output
                    fieldXmlTags.add(
                        '    <field api_name="' +
                            dfr.getName() +
                            '" label="' +
                            dfr.getLabel().escapeHtml4() +
                            '">' +
                            displayValue.escapeHtml4() +
                            '</field>'
                    );
                }
            }
            if (!fieldXmlTags.isEmpty()) {
                recordXmlBlocks.add('  <record>\n' + String.join(fieldXmlTags, '\n') + '\n  </record>');
            }
        }

        if (recordXmlBlocks.isEmpty())
            return '';

        String finalBlock = '<object_group label="' + schemaInfo.objectDescribe.getLabelPlural().escapeHtml4() + '">\n';
        finalBlock +=
            '  <object_info api_name="' +
            schemaInfo.objectDescribe.getName() +
            '" label="' +
            schemaInfo.objectDescribe.getLabel().escapeHtml4() +
            '" />\n';
        finalBlock += String.join(recordXmlBlocks, '\n');
        finalBlock += '\n</object_group>';

        return finalBlock;
    }

    /**
     * Formats SObjects into readable Markdown-style structured text.
     * Creates grouped sections with clear record separation and field labels.
     *
     * @param sObjectList   List of records of the same SObjectType to format.
     * @param logPrefix     Logging prefix for debug messages.
     * @return              Markdown-formatted string with organized record data.
     */
    private static String formatAsStructuredText(List<SObject> sObjectList, String logPrefix) {
        if (sObjectList.isEmpty())
            return '';

        ObjectSchemaInfo schemaInfo = getSchemaInfo(sObjectList[0].getSObjectType(), logPrefix);
        if (schemaInfo == null)
            return '';

        Set<String> allFieldNames = new Set<String>();
        for (SObject record : sObjectList) {
            allFieldNames.addAll(record.getPopulatedFieldsAsMap().keySet());
        }

        schemaInfo.describeFields(allFieldNames);

        // Create section header with object information
        String groupHeader = '## ' + schemaInfo.objectDescribe.getLabelPlural() + ' (' + sObjectList.size() + ' Records)';
        List<String> recordBlocks = new List<String>();

        for (SObject record : sObjectList) {
            List<String> fieldEntries = new List<String>();
            Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

            // Identify primary display field for record title
            String primaryDisplayFieldApiName = findPrimaryDisplayField(populatedFields.keySet(), schemaInfo);

            if (String.isNotBlank(primaryDisplayFieldApiName) && populatedFields.get(primaryDisplayFieldApiName) != null) {
                String primaryValue = String.valueOf(populatedFields.get(primaryDisplayFieldApiName));
                fieldEntries.add('**' + primaryValue + '**');
            }

            // Sort field names for consistent output
            List<String> sortedFieldNames = new List<String>(populatedFields.keySet());
            sortedFieldNames.sort();

            for (String fieldName : sortedFieldNames) {
                // Skip primary field already used as title
                if (fieldName.equalsIgnoreCase(primaryDisplayFieldApiName))
                    continue;

                DescribeFieldResult dfr = schemaInfo.getFieldDescribe(fieldName);
                if (dfr != null && dfr.isAccessible()) {
                    Object value = populatedFields.get(fieldName);
                    // Sanitize value for clean text output
                    String displayValue = (value == null) ? '[Not Set]' : String.valueOf(value).replace('\n', ' ').replace('\r', '');
                    fieldEntries.add(dfr.getLabel() + ': ' + displayValue);
                }
            }
            if (!fieldEntries.isEmpty()) {
                recordBlocks.add(String.join(fieldEntries, '\n'));
            }
        }

        if (recordBlocks.isEmpty())
            return '';

        // Combine record blocks with clear separators
        return groupHeader + '\n\n' + String.join(recordBlocks, '\n\n---\n\n');
    }

    // Utility methods for formatting support

    /**
     * Groups a list of SObjects by their SObjectType name.
     *
     * @param records   List of SObjects to group.
     * @return          Map from SObjectType name to list of SObjects.
     */
    private static Map<String, List<SObject>> groupRecordsByType(List<SObject> records) {
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
     * Retrieves and caches ObjectSchemaInfo for a given SObjectType.
     * Logs cache misses and describe failures for troubleshooting.
     *
     * @param sObjType   The SObjectType to describe.
     * @param logPrefix  Logging prefix for debug messages.
     * @return           ObjectSchemaInfo for the SObjectType, or null if describe fails.
     */
    private static ObjectSchemaInfo getSchemaInfo(SObjectType sObjType, String logPrefix) {
        if (sObjType == null)
            return null;
        if (!schemaInfoCache.containsKey(sObjType)) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Schema cache MISS for ' + sObjType + '. Describing object.');
            ObjectSchemaInfo newSchemaInfo = null;
            try {
                newSchemaInfo = new ObjectSchemaInfo(sObjType.getDescribe());
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to describe SObject ' + sObjType + ': ' + e.getMessage());
            }
            schemaInfoCache.put(sObjType, newSchemaInfo);
        }
        return schemaInfoCache.get(sObjType);
    }

    /**
     * Finds the primary display field for a record, prioritizing common display fields.
     *
     * @param populatedFields   Set of populated field API names.
     * @param schemaInfo        ObjectSchemaInfo for the SObjectType.
     * @return                  The API name of the primary display field, or 'Id' if none found.
     */
    private static String findPrimaryDisplayField(Set<String> populatedFields, ObjectSchemaInfo schemaInfo) {
        List<String> preferredFields = new List<String>{ 'Name', 'Subject', 'CaseNumber', 'Title' };
        Set<String> populatedFieldsLower = new Set<String>();
        for (String f : populatedFields) {
            populatedFieldsLower.add(f.toLowerCase());
        }

        for (String preferred : preferredFields) {
            if (populatedFieldsLower.contains(preferred.toLowerCase())) {
                DescribeFieldResult dfr = schemaInfo.getFieldDescribe(preferred);
                if (dfr != null && dfr.isAccessible()) {
                    return dfr.getName();
                }
            }
        }
        return 'Id';
    }

    /**
     * Clears the schema info cache (for testing or transaction resets).
     */
    @TestVisible
    private static void clearCache() {
        schemaInfoCache.clear();
    }
}
