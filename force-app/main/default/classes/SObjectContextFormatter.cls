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
     * Handles child relationships by pre-caching schema information for all object types.
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

        // Pre-cache schema information for all object types including child relationships
        preloadSchemaForRecordsAndChildren(records, logPrefix);

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
     * Handles child relationships by including them as nested XML sections.
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
     * Handles child relationships by formatting them as nested sections.
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
            List<String> childRelationshipBlocks = new List<String>();
            Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

            // Identify primary display field for record title
            String primaryDisplayFieldApiName = findPrimaryDisplayField(populatedFields.keySet(), schemaInfo);

            if (String.isNotBlank(primaryDisplayFieldApiName) && populatedFields.get(primaryDisplayFieldApiName) != null) {
                String primaryValue = String.valueOf(populatedFields.get(primaryDisplayFieldApiName));
                fieldEntries.add('**' + primaryValue + '**');
            }

            // Extract all accessible fields including relationship fields
            Map<String, Object> allAccessibleFields = extractAllAccessibleFields(record, logPrefix);

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
                    primaryFieldLabel = getFieldLabel(primaryDisplayFieldApiName, schemaInfo);
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
                recordBlocks.add(String.join(recordParts, '\n\n'));
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
     * Pre-loads schema information for all SObject types found in the records,
     * including child relationship objects, to prevent null pointer exceptions.
     *
     * @param records    List of SObjects to analyze for schema preloading.
     * @param logPrefix  Logging prefix for debug messages.
     */
    private static void preloadSchemaForRecordsAndChildren(List<SObject> records, String logPrefix) {
        Set<SObjectType> allObjectTypes = new Set<SObjectType>();

        for (SObject record : records) {
            // Add the main record's object type
            allObjectTypes.add(record.getSObjectType());

            // Check for child relationships by examining populated fields
            Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
            for (String fieldName : populatedFields.keySet()) {
                Object fieldValue = populatedFields.get(fieldName);

                // Check if this field contains child relationship data
                if (fieldValue instanceof List<SObject>) {
                    List<SObject> childRecords = (List<SObject>) fieldValue;
                    for (SObject childRecord : childRecords) {
                        allObjectTypes.add(childRecord.getSObjectType());
                    }
                }
            }
        }

        // Pre-cache schema information for all discovered object types
        for (SObjectType objType : allObjectTypes) {
            getSchemaInfo(objType, logPrefix);
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
    private static String formatChildRelationship(String relationshipName, List<SObject> childRecords, String logPrefix) {
        if (childRecords == null || childRecords.isEmpty()) {
            return '';
        }

        // Create header for child relationship section
        String childHeader = '### ' + relationshipName + ' (' + childRecords.size() + ' items)';
        List<String> childRecordBlocks = new List<String>();

        for (SObject childRecord : childRecords) {
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
        }

        if (childRecordBlocks.isEmpty()) {
            return '';
        }

        return childHeader + '\n' + String.join(childRecordBlocks, '\n\n');
    }

    /**
     * Formats child relationship records as nested XML within the parent record.
     *
     * @param relationshipName  The name of the child relationship field.
     * @param childRecords      List of child SObject records.
     * @param logPrefix         Logging prefix for debug messages.
     * @return                  XML-formatted string for the child relationship section.
     */
    private static String formatChildRelationshipAsXml(String relationshipName, List<SObject> childRecords, String logPrefix) {
        if (childRecords == null || childRecords.isEmpty()) {
            return '';
        }

        SObject firstChild = childRecords[0];
        ObjectSchemaInfo childSchemaInfo = getSchemaInfo(firstChild.getSObjectType(), logPrefix);
        if (childSchemaInfo == null) {
            return '';
        }

        List<String> childRecordXml = new List<String>();
        for (SObject childRecord : childRecords) {
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
        }

        if (childRecordXml.isEmpty()) {
            return '';
        }

        String childObjectName = childSchemaInfo.objectDescribe.getName();
        String childObjectLabel = childSchemaInfo.objectDescribe.getLabel();

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
    }

    /**
     * Extracts all accessible field values from an SObject, including relationship fields.
     * This method handles both direct fields and relationship traversal (e.g., PricebookEntry.Product2.Name).
     *
     * @param record     The SObject record to extract fields from.
     * @param logPrefix  Logging prefix for debug messages.
     * @return           Map of field labels to their values.
     */
    private static Map<String, Object> extractAllAccessibleFields(SObject record, String logPrefix) {
        Map<String, Object> allFields = new Map<String, Object>();

        if (record == null) {
            return allFields;
        }

        // Start with direct populated fields
        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
        ObjectSchemaInfo recordSchemaInfo = getSchemaInfo(record.getSObjectType(), logPrefix);

        // Process each populated field
        for (String fieldName : populatedFields.keySet()) {
            Object fieldValue = populatedFields.get(fieldName);

            // Skip child relationship lists (they're handled separately)
            if (fieldValue instanceof List<SObject>) {
                continue;
            }

            // For direct fields, add them with proper labels
            if (!(fieldValue instanceof SObject)) {
                String fieldLabel = getFieldLabel(fieldName, recordSchemaInfo);
                allFields.put(fieldLabel, fieldValue);
            } else {
                // For relationship fields, we need to traverse and extract accessible fields
                SObject relatedRecord = (SObject) fieldValue;
                String relationshipLabel = getFieldLabel(fieldName, recordSchemaInfo);
                Map<String, Object> relatedFields = extractRelatedFields(relatedRecord, relationshipLabel, logPrefix);
                allFields.putAll(relatedFields);
            }
        }

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
    private static Map<String, Object> extractRelatedFields(SObject relatedRecord, String pathPrefix, String logPrefix) {
        Map<String, Object> relatedFields = new Map<String, Object>();

        if (relatedRecord == null) {
            return relatedFields;
        }

        try {
            Map<String, Object> relatedPopulatedFields = relatedRecord.getPopulatedFieldsAsMap();
            ObjectSchemaInfo relatedSchemaInfo = getSchemaInfo(relatedRecord.getSObjectType(), logPrefix);

            for (String fieldName : relatedPopulatedFields.keySet()) {
                Object fieldValue = relatedPopulatedFields.get(fieldName);

                // Skip child relationship lists
                if (fieldValue instanceof List<SObject>) {
                    continue;
                }

                String fieldLabel = getFieldLabel(fieldName, relatedSchemaInfo);
                String fullLabelPath = pathPrefix + ' → ' + fieldLabel;

                if (!(fieldValue instanceof SObject)) {
                    // Direct field value
                    relatedFields.put(fullLabelPath, fieldValue);
                } else {
                    // Nested relationship - recurse (but limit depth to prevent infinite loops)
                    if (pathPrefix.split('→').size() < 3) {
                        // Limit to 3 levels deep
                        SObject nestedRecord = (SObject) fieldValue;
                        Map<String, Object> nestedFields = extractRelatedFields(nestedRecord, fullLabelPath, logPrefix);
                        relatedFields.putAll(nestedFields);
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Failed to extract fields from related record at path ' + pathPrefix + ': ' + e.getMessage());
        }

        return relatedFields;
    }

    /**
     * Gets the field label for a given field name using schema information.
     *
     * @param fieldName    The API name of the field.
     * @param schemaInfo   The ObjectSchemaInfo for the object containing the field.
     * @return             The field label, or the field name if label cannot be determined.
     */
    private static String getFieldLabel(String fieldName, ObjectSchemaInfo schemaInfo) {
        if (schemaInfo == null || String.isBlank(fieldName)) {
            return fieldName;
        }

        DescribeFieldResult dfr = schemaInfo.getFieldDescribe(fieldName);
        if (dfr != null && dfr.isAccessible()) {
            return dfr.getLabel();
        }

        return fieldName; // Fallback to API name if label cannot be determined
    }

    /**
     * Clears the schema info cache (for testing or transaction resets).
     */
    @TestVisible
    private static void clearCache() {
        schemaInfoCache.clear();
    }
}
