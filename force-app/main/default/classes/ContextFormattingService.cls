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
 * optimized for LLM (Large Language Model) consumption. Supports JSON, YAML, and Structured Text formats
 * with token budget awareness.
 *
 * Key Features:
 * - Token budget awareness with intelligent truncation
 * - Salesforce-specific enrichment (record URLs)
 * - Compact output formats optimized for token efficiency
 */
public inherited sharing class ContextFormattingService {
    private static final Integer DEFAULT_MAX_CHARS = 8000;

    public ContextFormattingService() {
    }

    /**
     * Formatting options for customizing output
     */
    public class FormattingOptions {
        public Integer maxChars = DEFAULT_MAX_CHARS;
        public Boolean includeMetadata = true;
        public Boolean includeRecordUrls = false;
        public Set<String> excludeFields = new Set<String>();

        public FormattingOptions() {
        }

        public FormattingOptions withMaxChars(Integer chars) {
            this.maxChars = chars;
            return this;
        }
        public FormattingOptions withMetadata(Boolean include) {
            this.includeMetadata = include;
            return this;
        }
        public FormattingOptions withRecordUrls(Boolean include) {
            this.includeRecordUrls = include;
            return this;
        }
        public FormattingOptions withExcludeFields(Set<String> fields) {
            this.excludeFields = fields;
            return this;
        }
    }

    /**
     * Main entry point for formatting SObject data based on the specified format strategy.
     */
    public String formatContext(List<SObject> records, String logPrefix, String formatStrategy) {
        return formatContext(records, logPrefix, formatStrategy, new FormattingOptions());
    }

    /**
     * Format with custom options
     */
    public String formatContext(List<SObject> records, String logPrefix, String formatStrategy, FormattingOptions options) {
        System.debug(logPrefix + 'ContextFormattingService.formatContext called with strategy: ' + formatStrategy);

        if (String.isBlank(formatStrategy)) {
            formatStrategy = 'Structured Text';
        }

        String result;
        switch on formatStrategy {
            when 'JSON' {
                result = formatAsJson(records, logPrefix, options);
            }
            when 'YAML' {
                result = formatAsYaml(records, logPrefix, options);
            }
            when 'Structured Text' {
                result = formatAsStructuredText(records, logPrefix, options);
            }
            when else {
                System.debug(LoggingLevel.WARN, logPrefix + 'Unknown format strategy: ' + formatStrategy + '. Defaulting to Structured Text.');
                result = formatAsStructuredText(records, logPrefix, options);
            }
        }

        // Apply token budget truncation if needed
        if (result.length() > options.maxChars) {
            result = truncateWithContext(result, options.maxChars, formatStrategy);
        }

        return result;
    }

    // ===================================================================================
    // JSON FORMATTING
    // ===================================================================================

    private String formatAsJson(List<SObject> records, String logPrefix, FormattingOptions options) {
        try {
            if (records == null || records.isEmpty()) {
                return options.includeMetadata ? '{"_meta":{"format":"JSON","records":0},"data":[]}' : '[]';
            }

            Map<String, List<SObject>> recordsByType = groupRecordsByType(records);
            List<Object> allData = new List<Object>();

            for (String sObjTypeName : recordsByType.keySet()) {
                List<SObject> sObjectList = recordsByType.get(sObjTypeName);
                Object formattedGroup = formatSObjectGroupAsJson(sObjectList, logPrefix, options);
                if (formattedGroup != null) {
                    allData.add(formattedGroup);
                }
            }

            if (allData.size() == 1) {
                return JSON.serialize(allData[0]);
            }

            Map<String, Object> result = new Map<String, Object>();
            if (options.includeMetadata) {
                result.put('_meta', createCompactMetadata('JSON', records.size()));
            }
            result.put('data', allData);
            return JSON.serialize(result);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in formatAsJson: ' + e.getMessage());
            return '{"error":"' + e.getMessage().escapeEcmaScript() + '"}';
        }
    }

    private Object formatSObjectGroupAsJson(List<SObject> sObjectList, String logPrefix, FormattingOptions options) {
        if (sObjectList.isEmpty())
            return null;

        Schema.DescribeSObjectResult objDescribe = sObjectList[0].getSObjectType().getDescribe();
        Map<String, Object> groupData = new Map<String, Object>();

        Map<String, Object> meta = new Map<String, Object>();
        meta.put('type', objDescribe.getName());
        meta.put('label', objDescribe.getLabel());
        meta.put('count', sObjectList.size());
        groupData.put('_meta', meta);

        List<Object> recordsList = new List<Object>();
        for (SObject record : sObjectList) {
            Map<String, Object> recordData = formatSingleRecordAsJson(record, objDescribe, logPrefix, options);
            if (!recordData.isEmpty()) {
                recordsList.add(recordData);
            }
        }
        groupData.put('records', recordsList);
        return groupData;
    }

    private Map<String, Object> formatSingleRecordAsJson(
        SObject record,
        Schema.DescribeSObjectResult objDescribe,
        String logPrefix,
        FormattingOptions options
    ) {
        Map<String, Object> recordData = new Map<String, Object>();
        Map<String, Object> childRels = new Map<String, Object>();

        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
        Map<String, SObjectField> fieldMap = SchemaUtils.getObjectFields(objDescribe.getSObjectType());

        for (String fieldName : populatedFields.keySet()) {
            if (options.excludeFields.contains(fieldName.toLowerCase()))
                continue;

            Object fieldValue = populatedFields.get(fieldName);
            String fieldLabel = getFieldLabel(fieldName, fieldMap);

            if (fieldValue instanceof List<SObject>) {
                List<SObject> children = (List<SObject>) fieldValue;
                if (!children.isEmpty()) {
                    childRels.put(fieldLabel, formatChildrenAsJson(children, logPrefix, options));
                }
            } else if (fieldValue instanceof SObject) {
                SObject relatedRecord = (SObject) fieldValue;
                Map<String, Object> relatedFields = extractRelatedFieldValues(relatedRecord, fieldLabel, logPrefix);
                for (String relLabel : relatedFields.keySet()) {
                    recordData.put(relLabel, relatedFields.get(relLabel));
                }
            } else {
                recordData.put(fieldLabel, fieldValue);
            }
        }

        if (options.includeRecordUrls) {
            recordData.put('_url', getRecordUrl(record.Id));
        }

        if (!childRels.isEmpty()) {
            recordData.put('_children', childRels);
        }

        return recordData;
    }

    private List<Object> formatChildrenAsJson(List<SObject> children, String logPrefix, FormattingOptions options) {
        List<Object> result = new List<Object>();
        if (children == null || children.isEmpty())
            return result;

        Schema.DescribeSObjectResult childDescribe = children[0].getSObjectType().getDescribe();

        for (SObject child : children) {
            Map<String, Object> childData = formatSingleRecordAsJson(child, childDescribe, logPrefix, options);
            if (!childData.isEmpty()) {
                result.add(childData);
            }
        }
        return result;
    }

    // ===================================================================================
    // YAML FORMATTING
    // ===================================================================================

    private String formatAsYaml(List<SObject> records, String logPrefix, FormattingOptions options) {
        try {
            if (records == null || records.isEmpty()) {
                return options.includeMetadata ? '_meta:\n  format: YAML\n  records: 0\ndata: []' : '[]';
            }

            List<String> yamlParts = new List<String>();

            if (options.includeMetadata) {
                yamlParts.add('_meta:');
                yamlParts.add('  format: YAML');
                yamlParts.add('  generated: ' + Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
                yamlParts.add('  records: ' + records.size());
            }

            Map<String, List<SObject>> recordsByType = groupRecordsByType(records);

            for (String sObjTypeName : recordsByType.keySet()) {
                List<SObject> sObjectList = recordsByType.get(sObjTypeName);
                String formattedGroup = formatSObjectGroupAsYaml(sObjectList, logPrefix, options);
                if (String.isNotBlank(formattedGroup)) {
                    yamlParts.add(formattedGroup);
                }
            }

            return String.join(yamlParts, '\n');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in formatAsYaml: ' + e.getMessage());
            return 'error: ' + escapeYamlString(e.getMessage());
        }
    }

    private String formatSObjectGroupAsYaml(List<SObject> sObjectList, String logPrefix, FormattingOptions options) {
        if (sObjectList.isEmpty())
            return '';

        Schema.DescribeSObjectResult objDescribe = sObjectList[0].getSObjectType().getDescribe();
        List<String> lines = new List<String>();

        lines.add(objDescribe.getLabelPlural() + ':');

        for (SObject record : sObjectList) {
            String recordYaml = formatSingleRecordAsYaml(record, objDescribe, logPrefix, options, 1);
            if (String.isNotBlank(recordYaml)) {
                lines.add(recordYaml);
            }
        }

        return String.join(lines, '\n');
    }

    private String formatSingleRecordAsYaml(
        SObject record,
        Schema.DescribeSObjectResult objDescribe,
        String logPrefix,
        FormattingOptions options,
        Integer indentLevel
    ) {
        String indent = '  '.repeat(indentLevel);
        List<String> lines = new List<String>();

        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
        Map<String, SObjectField> fieldMap = SchemaUtils.getObjectFields(objDescribe.getSObjectType());

        Boolean isFirst = true;
        for (String fieldName : populatedFields.keySet()) {
            if (options.excludeFields.contains(fieldName.toLowerCase()))
                continue;

            Object fieldValue = populatedFields.get(fieldName);
            String fieldLabel = getFieldLabel(fieldName, fieldMap);
            String prefix = isFirst ? '- ' : '  ';
            isFirst = false;

            if (fieldValue instanceof List<SObject>) {
                List<SObject> children = (List<SObject>) fieldValue;
                if (!children.isEmpty()) {
                    lines.add(indent + prefix + fieldLabel + ':');
                    lines.add(formatChildrenAsYaml(children, logPrefix, options, indentLevel + 2));
                }
            } else if (fieldValue instanceof SObject) {
                SObject relatedRecord = (SObject) fieldValue;
                Map<String, Object> relatedFields = extractRelatedFieldValues(relatedRecord, fieldLabel, logPrefix);
                for (String relLabel : relatedFields.keySet()) {
                    String valueStr = formatYamlValue(relatedFields.get(relLabel));
                    lines.add(indent + prefix + relLabel + ': ' + valueStr);
                    prefix = '  ';
                }
            } else {
                String valueStr = formatYamlValue(fieldValue);
                lines.add(indent + prefix + fieldLabel + ': ' + valueStr);
            }
        }

        if (options.includeRecordUrls && record.Id != null) {
            lines.add(indent + '  _url: ' + getRecordUrl(record.Id));
        }

        return String.join(lines, '\n');
    }

    private String formatChildrenAsYaml(List<SObject> children, String logPrefix, FormattingOptions options, Integer indentLevel) {
        List<String> lines = new List<String>();
        if (children == null || children.isEmpty())
            return '';

        Schema.DescribeSObjectResult childDescribe = children[0].getSObjectType().getDescribe();

        for (SObject child : children) {
            String childYaml = formatSingleRecordAsYaml(child, childDescribe, logPrefix, options, indentLevel);
            if (String.isNotBlank(childYaml)) {
                lines.add(childYaml);
            }
        }
        return String.join(lines, '\n');
    }

    private String formatYamlValue(Object value) {
        if (value == null)
            return 'null';
        if (value instanceof Boolean)
            return String.valueOf(value);
        if (value instanceof Integer || value instanceof Long || value instanceof Decimal || value instanceof Double) {
            return String.valueOf(value);
        }
        if (value instanceof Date)
            return ((Date) value).format();
        if (value instanceof Datetime)
            return ((Datetime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        String strVal = String.valueOf(value);
        if (strVal.contains(':') || strVal.contains('#') || strVal.contains('\n') || strVal.startsWith('-') || strVal.startsWith('[')) {
            return '"' + escapeYamlString(strVal) + '"';
        }
        return strVal;
    }

    private String escapeYamlString(String input) {
        if (input == null)
            return '';
        return input.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r');
    }

    // ===================================================================================
    // STRUCTURED TEXT FORMATTING
    // ===================================================================================

    private String formatAsStructuredText(List<SObject> records, String logPrefix, FormattingOptions options) {
        try {
            if (records == null || records.isEmpty()) {
                return options.includeMetadata ? '--- No records ---' : '';
            }

            List<String> parts = new List<String>();

            if (options.includeMetadata) {
                parts.add('=== Context Data ===');
                parts.add('Generated: ' + Datetime.now().formatGmt('yyyy-MM-dd HH:mm:ss') + ' UTC');
                parts.add('Records: ' + records.size());
                parts.add('');
            }

            Map<String, List<SObject>> recordsByType = groupRecordsByType(records);

            for (String sObjTypeName : recordsByType.keySet()) {
                List<SObject> sObjectList = recordsByType.get(sObjTypeName);
                String formattedGroup = formatSObjectGroupAsText(sObjectList, logPrefix, options);
                if (String.isNotBlank(formattedGroup)) {
                    parts.add(formattedGroup);
                }
            }

            parts.add('=== End Context ===');
            return String.join(parts, '\n');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in formatAsStructuredText: ' + e.getMessage());
            return 'Error: ' + e.getMessage();
        }
    }

    private String formatSObjectGroupAsText(List<SObject> sObjectList, String logPrefix, FormattingOptions options) {
        if (sObjectList.isEmpty())
            return '';

        Schema.DescribeSObjectResult objDescribe = sObjectList[0].getSObjectType().getDescribe();
        List<String> lines = new List<String>();

        lines.add('--- ' + objDescribe.getLabelPlural() + ' (' + sObjectList.size() + ') ---');

        for (Integer i = 0; i < sObjectList.size(); i++) {
            SObject record = sObjectList[i];
            String recordText = formatSingleRecordAsText(record, objDescribe, logPrefix, options);
            if (String.isNotBlank(recordText)) {
                if (i > 0)
                    lines.add('');
                lines.add(recordText);
            }
        }

        return String.join(lines, '\n');
    }

    private String formatSingleRecordAsText(SObject record, Schema.DescribeSObjectResult objDescribe, String logPrefix, FormattingOptions options) {
        List<String> lines = new List<String>();

        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();
        Map<String, SObjectField> fieldMap = SchemaUtils.getObjectFields(objDescribe.getSObjectType());

        // Find primary display value for header
        String primaryValue = findPrimaryDisplayValue(record, populatedFields);
        if (String.isNotBlank(primaryValue)) {
            lines.add('[' + primaryValue + ']');
        }

        for (String fieldName : populatedFields.keySet()) {
            if (options.excludeFields.contains(fieldName.toLowerCase()))
                continue;

            Object fieldValue = populatedFields.get(fieldName);
            String fieldLabel = getFieldLabel(fieldName, fieldMap);

            if (fieldValue instanceof List<SObject>) {
                List<SObject> children = (List<SObject>) fieldValue;
                if (!children.isEmpty()) {
                    lines.add('  ' + fieldLabel + ':');
                    lines.add(formatChildrenAsText(children, logPrefix, options));
                }
            } else if (fieldValue instanceof SObject) {
                SObject relatedRecord = (SObject) fieldValue;
                Map<String, Object> relatedFields = extractRelatedFieldValues(relatedRecord, fieldLabel, logPrefix);
                for (String relLabel : relatedFields.keySet()) {
                    String valueStr = relatedFields.get(relLabel) == null ? '[not set]' : String.valueOf(relatedFields.get(relLabel));
                    valueStr = valueStr.replace('\n', ' ').replace('\r', '');
                    lines.add('  ' + relLabel + ': ' + valueStr);
                }
            } else {
                String valueStr = fieldValue == null ? '[not set]' : String.valueOf(fieldValue);
                valueStr = valueStr.replace('\n', ' ').replace('\r', '');
                lines.add('  ' + fieldLabel + ': ' + valueStr);
            }
        }

        if (options.includeRecordUrls && record.Id != null) {
            lines.add('  URL: ' + getRecordUrl(record.Id));
        }

        return String.join(lines, '\n');
    }

    private String formatChildrenAsText(List<SObject> children, String logPrefix, FormattingOptions options) {
        List<String> lines = new List<String>();
        if (children == null || children.isEmpty())
            return '';

        Schema.DescribeSObjectResult childDescribe = children[0].getSObjectType().getDescribe();
        Map<String, SObjectField> childFieldMap = SchemaUtils.getObjectFields(childDescribe.getSObjectType());

        for (SObject child : children) {
            Map<String, Object> childFields = child.getPopulatedFieldsAsMap();
            List<String> fieldStrs = new List<String>();

            for (String fieldName : childFields.keySet()) {
                Object fieldValue = childFields.get(fieldName);
                if (!(fieldValue instanceof List<SObject>) && !(fieldValue instanceof SObject) && fieldValue != null) {
                    String fieldLabel = getFieldLabel(fieldName, childFieldMap);
                    fieldStrs.add(fieldLabel + ': ' + String.valueOf(fieldValue));
                }
            }

            if (!fieldStrs.isEmpty()) {
                lines.add('    - ' + String.join(fieldStrs, ', '));
            }
        }
        return String.join(lines, '\n');
    }

    // ===================================================================================
    // UTILITY METHODS
    // ===================================================================================

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

    private String getFieldLabel(String fieldName, Map<String, SObjectField> fieldMap) {
        if (fieldMap == null || String.isBlank(fieldName))
            return fieldName;

        SObjectField fieldToken = fieldMap.get(fieldName.toLowerCase());
        if (fieldToken != null && fieldToken.getDescribe().isAccessible()) {
            return fieldToken.getDescribe().getLabel();
        }
        return fieldName;
    }

    private String findPrimaryDisplayValue(SObject record, Map<String, Object> populatedFields) {
        for (String fieldName : new List<String>{ 'Name', 'Subject', 'Title', 'CaseNumber' }) {
            if (populatedFields.containsKey(fieldName)) {
                Object value = populatedFields.get(fieldName);
                if (value != null) {
                    return String.valueOf(value);
                }
            }
        }
        return null;
    }

    private Map<String, Object> extractRelatedFieldValues(SObject relatedRecord, String pathPrefix, String logPrefix) {
        Map<String, Object> result = new Map<String, Object>();

        if (relatedRecord == null)
            return result;

        try {
            Map<String, Object> relatedPopulated = relatedRecord.getPopulatedFieldsAsMap();
            Schema.DescribeSObjectResult relatedDescribe = relatedRecord.getSObjectType().getDescribe();
            Map<String, SObjectField> relatedFieldMap = SchemaUtils.getObjectFields(relatedDescribe.getSObjectType());

            for (String fieldName : relatedPopulated.keySet()) {
                Object fieldValue = relatedPopulated.get(fieldName);

                if (fieldValue instanceof List<SObject> || fieldValue instanceof SObject)
                    continue;

                String fieldLabel = getFieldLabel(fieldName, relatedFieldMap);
                String fullPath = pathPrefix + ' → ' + fieldLabel;
                result.put(fullPath, fieldValue);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Error extracting related fields: ' + e.getMessage());
        }

        return result;
    }

    private Map<String, Object> createCompactMetadata(String format, Integer recordCount) {
        Map<String, Object> meta = new Map<String, Object>();
        meta.put('format', format);
        meta.put('generated', Datetime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
        meta.put('records', recordCount);
        return meta;
    }

    private String getRecordUrl(Id recordId) {
        if (recordId == null)
            return null;
        return URL.getOrgDomainUrl().toExternalForm() + '/' + recordId;
    }

    private String truncateWithContext(String content, Integer maxChars, String format) {
        if (content.length() <= maxChars)
            return content;

        Integer cutPoint = maxChars - 50;
        String truncated = content.substring(0, cutPoint);

        Integer lastNewline = truncated.lastIndexOf('\n');
        if (lastNewline > cutPoint - 200) {
            truncated = truncated.substring(0, lastNewline);
        }

        if (format == 'JSON') {
            return truncated + '\n... [truncated]"}';
        } else if (format == 'YAML') {
            return truncated + '\n# ... [truncated due to size limit]';
        } else {
            return truncated + '\n... [truncated due to size limit]';
        }
    }
}
