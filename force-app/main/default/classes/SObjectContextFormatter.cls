/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Formats SObject lists into various structured text formats for LLM context.
 *              This class acts as a central formatting engine, routing to different strategies
 *              (e.g., XML, Structured Text) based on agent configuration. It is optimized to
 *              perform a single, cached schema describe call per SObject type per transaction.
 */
public inherited sharing class SObjectContextFormatter {
    @TestVisible
    private class ObjectSchemaInfo {
        public DescribeSObjectResult objectDescribe { get; private set; }
        public Map<String, DescribeFieldResult> fieldDescribeMap { get; private set; }
        private Map<String, Schema.SObjectField> fieldTokenMap { get; set; }

        public ObjectSchemaInfo(DescribeSObjectResult objDescribe) {
            this.objectDescribe = objDescribe;
            this.fieldDescribeMap = new Map<String, DescribeFieldResult>();
            this.fieldTokenMap = objDescribe.fields.getMap();
        }

        public DescribeFieldResult getFieldDescribe(String fieldName) {
            String fieldNameLower = fieldName.toLowerCase();

            if (fieldDescribeMap.containsKey(fieldNameLower)) {
                return fieldDescribeMap.get(fieldNameLower);
            }

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

        public void describeFields(Set<String> fieldNames) {
            for (String fieldName : fieldNames) {
                getFieldDescribe(fieldName);
            }
        }
    }

    @TestVisible
    private static Map<SObjectType, ObjectSchemaInfo> schemaInfoCache = new Map<SObjectType, ObjectSchemaInfo>();

    /**
     * @description Main entry point for formatting context. Groups records by type and delegates to the appropriate strategy.
     * @param records The list of all SObjects to be included in the context.
     * @param formatStrategy The chosen format (e.g., 'Xml', 'StructuredText').
     * @param logPrefix A logging prefix.
     * @return A single string containing all formatted context blocks.
     */
    public static String formatContext(List<SObject> records, String formatStrategy, String logPrefix) {
        if (records == null || records.isEmpty()) {
            return '';
        }

        Map<String, List<SObject>> recordsByType = groupRecordsByType(records);
        List<String> allFormattedBlocks = new List<String>();

        for (String sObjTypeName : recordsByType.keySet()) {
            List<SObject> sObjectList = recordsByType.get(sObjTypeName);
            String formattedBlock = '';

            if ('XML'.equalsIgnoreCase(formatStrategy)) {
                formattedBlock = formatAsXml(sObjectList, logPrefix);
            } else {
                formattedBlock = formatAsStructuredText(sObjectList, logPrefix);
            }

            if (String.isNotBlank(formattedBlock)) {
                allFormattedBlocks.add(formattedBlock);
            }
        }
        return String.join(allFormattedBlocks, '\n\n');
    }

    /**
     * @description Formats a list of SObjects of the SAME TYPE into a structured XML block.
     * @param sObjectList A list of records, all of the same SObjectType.
     * @param logPrefix A logging prefix.
     * @return An XML-formatted string.
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
     * @description Formats a list of SObjects of the SAME TYPE into Markdown-grouped key-value text.
     * @param sObjectList A list of records, all of the same SObjectType.
     * @param logPrefix A logging prefix.
     * @return A Markdown-formatted string.
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

        String groupHeader = '## ' + schemaInfo.objectDescribe.getLabelPlural() + ' (' + sObjectList.size() + ' Records)';
        List<String> recordBlocks = new List<String>();

        for (SObject record : sObjectList) {
            List<String> fieldEntries = new List<String>();
            Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

            String primaryDisplayFieldApiName = findPrimaryDisplayField(populatedFields.keySet(), schemaInfo);

            if (String.isNotBlank(primaryDisplayFieldApiName) && populatedFields.get(primaryDisplayFieldApiName) != null) {
                String primaryValue = String.valueOf(populatedFields.get(primaryDisplayFieldApiName));
                fieldEntries.add('**' + primaryValue + '**');
            }

            List<String> sortedFieldNames = new List<String>(populatedFields.keySet());
            sortedFieldNames.sort();

            for (String fieldName : sortedFieldNames) {
                if (fieldName.equalsIgnoreCase(primaryDisplayFieldApiName))
                    continue;

                DescribeFieldResult dfr = schemaInfo.getFieldDescribe(fieldName);
                if (dfr != null && dfr.isAccessible()) {
                    Object value = populatedFields.get(fieldName);

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

        return groupHeader + '\n\n' + String.join(recordBlocks, '\n\n---\n\n');
    }

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

    private static ObjectSchemaInfo getSchemaInfo(SObjectType sObjType, String logPrefix) {
        if (sObjType == null)
            return null;
        if (!schemaInfoCache.containsKey(sObjType)) {
            ObjectSchemaInfo newSchemaInfo = null;
            try {
                newSchemaInfo = new ObjectSchemaInfo(sObjType.getDescribe());
            } catch (Exception e) {
            }
            schemaInfoCache.put(sObjType, newSchemaInfo);
        }
        return schemaInfoCache.get(sObjType);
    }

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

    @TestVisible
    private static void clearCache() {
        schemaInfoCache.clear();
    }
}
