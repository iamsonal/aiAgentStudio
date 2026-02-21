/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Provides unified context formatting for SObject data into formats optimized for LLM consumption. Supports JSON and Structured Text with token budget awareness.
 */
public inherited sharing class ContextFormattingService {
    private static final Integer DEFAULT_MAX_CHARS = 8000;
    private static final String PATH_SEPARATOR = '.';

    public ContextFormattingService() {
    }
    public class FormattingOptions {
        public Integer maxChars = DEFAULT_MAX_CHARS;
        public Boolean includeMetadata = true;
        public Boolean includeRecordUrls = false;
        public Boolean excludeIdFields = false; // When true, skips all Salesforce ID fields for token efficiency
        public Set<String> excludeFields = new Set<String>();

        // PII Masking support - caller supplies the PIIMaskingService; internal helpers are not exposed.
        public PIIMaskingService piiMaskingService = null;

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
        public FormattingOptions withExcludeIdFields(Boolean exclude) {
            this.excludeIdFields = exclude;
            return this;
        }
        public FormattingOptions withExcludeFields(Set<String> fields) {
            this.excludeFields = fields;
            return this;
        }

        /**
         * Enables PII masking for sensitive fields based on their Data Classification.
         * Fields marked as Confidential, Restricted, etc. will have their values replaced
         * with tokens before being sent to external LLMs. Pass the fully-configured
         * PIIMaskingService; the session and schema masker are accessed internally.
         *
         * @param maskingService The configured PIIMaskingService for this execution
         * @return This FormattingOptions instance for method chaining
         */
        public FormattingOptions withPIIMasking(PIIMaskingService maskingService) {
            this.piiMaskingService = maskingService;
            return this;
        }

        /**
         * Checks if PII masking is enabled for these options.
         * @return True if a PIIMaskingService has been configured
         */
        public Boolean isPIIMaskingEnabled() {
            return this.piiMaskingService != null;
        }

        // Cache of pre-calculated sensitive fields per SObject type
        // Optimization: Pre-calculate once per type instead of calling shouldMaskField for each field
        private transient Map<String, Set<String>> sensitiveFieldsCache = new Map<String, Set<String>>();

        /**
         * Gets the set of sensitive field names for an SObject type.
         * Pre-calculates and caches the result for performance optimization.
         * This avoids repeated shouldMaskField() calls inside record loops.
         *
         * @param sObjectType The SObject type to get sensitive fields for
         * @return Set of field API names (lowercased) that should be masked
         */
        public Set<String> getSensitiveFieldsForType(SObjectType sObjectType) {
            if (!isPIIMaskingEnabled() || sObjectType == null) {
                return new Set<String>();
            }

            String typeName = sObjectType.getDescribe().getName();

            // Check cache first
            if (sensitiveFieldsCache.containsKey(typeName)) {
                return sensitiveFieldsCache.get(typeName);
            }

            // Pre-calculate sensitive fields for this type
            Set<String> sensitiveFields = new Set<String>();
            for (String fieldName : piiMaskingService.getMaskedFields(sObjectType)) {
                sensitiveFields.add(fieldName.toLowerCase());
            }

            sensitiveFieldsCache.put(typeName, sensitiveFields);
            return sensitiveFields;
        }
    }

    /**
     * Main entry point for formatting SObject data based on the specified format strategy.
     * Defaults to JSON format if no strategy specified (most token-efficient).
     */
    public String formatContext(List<SObject> records, String logPrefix, String formatStrategy) {
        return formatContext(records, logPrefix, formatStrategy, new FormattingOptions());
    }

    /**
     * Format with custom options.
     * @param records List of SObject records to format (supports nested child relationships)
     * @param logPrefix Prefix for debug logs
     * @param formatStrategy 'JSON' or 'Structured Text' (defaults to JSON). 'YAML' is accepted as alias for backward compatibility.
     * @param options Formatting options for customization
     * @return Formatted string representation of the records
     */
    public String formatContext(List<SObject> records, String logPrefix, String formatStrategy, FormattingOptions options) {
        System.debug(logPrefix + 'ContextFormattingService.formatContext called with strategy: ' + formatStrategy);

        // Default to JSON - it's ~20% more token-efficient than text formats
        if (String.isBlank(formatStrategy)) {
            formatStrategy = 'JSON';
        }

        String result;
        switch on formatStrategy {
            when 'JSON' {
                result = formatAsJson(records, logPrefix, options);
            }
            when 'Structured Text', 'YAML' {
                // Structured Text now uses YAML format internally for better token efficiency
                // YAML is kept as alias for backward compatibility
                result = formatAsYaml(records, logPrefix, options);
            }
            when else {
                System.debug(LoggingLevel.WARN, logPrefix + 'Unknown format strategy: ' + formatStrategy + '. Defaulting to JSON.');
                result = formatAsJson(records, logPrefix, options);
            }
        }

        // Apply token budget truncation if needed
        if (result.length() > options.maxChars) {
            result = truncateWithContext(result, options.maxChars, formatStrategy);
        }

        return result;
    }

    // JSON FORMATTING

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
        Map<String, SObjectField> fieldMap = Utils.getObjectFields(objDescribe.getSObjectType());

        // Pre-calculate sensitive fields once per SObject type (optimization)
        Set<String> sensitiveFields = options.getSensitiveFieldsForType(objDescribe.getSObjectType());

        for (String fieldName : populatedFields.keySet()) {
            if (options.excludeFields.contains(fieldName.toLowerCase()))
                continue;

            // Skip ID fields if option is enabled
            if (options.excludeIdFields && isIdField(fieldName))
                continue;

            Object fieldValue = populatedFields.get(fieldName);
            String fieldLabel = getFieldLabel(fieldName, fieldMap);

            if (fieldValue instanceof List<SObject>) {
                // Child relationship (e.g., CaseHistories, CaseComments)
                List<SObject> children = (List<SObject>) fieldValue;
                if (!children.isEmpty()) {
                    childRels.put(fieldLabel, formatChildrenAsJson(children, logPrefix, options));
                }
            } else if (fieldValue instanceof SObject) {
                // Parent lookup (e.g., Account, Contact)
                SObject relatedRecord = (SObject) fieldValue;
                Map<String, Object> relatedFields = extractRelatedFieldValues(relatedRecord, fieldLabel, logPrefix, options);
                for (String relLabel : relatedFields.keySet()) {
                    recordData.put(relLabel, relatedFields.get(relLabel));
                }
            } else {
                // Check if PII masking should be applied (using pre-calculated set)
                Object outputValue = fieldValue;
                if (options.isPIIMaskingEnabled() && fieldValue != null && sensitiveFields.contains(fieldName.toLowerCase())) {
                    // Mask the field value
                    outputValue = options.piiMaskingService.maskFieldValue(fieldValue, fieldName);
                    System.debug(LoggingLevel.DEBUG, logPrefix + 'PII masked field: ' + fieldName);
                }
                recordData.put(fieldLabel, outputValue);
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

    // YAML FORMATTING

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
        Map<String, SObjectField> fieldMap = Utils.getObjectFields(objDescribe.getSObjectType());

        // Pre-calculate sensitive fields once per SObject type (optimization)
        Set<String> sensitiveFields = options.getSensitiveFieldsForType(objDescribe.getSObjectType());

        Boolean isFirst = true;
        for (String fieldName : populatedFields.keySet()) {
            if (options.excludeFields.contains(fieldName.toLowerCase()))
                continue;

            // Skip ID fields if option is enabled
            if (options.excludeIdFields && isIdField(fieldName))
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
                Map<String, Object> relatedFields = extractRelatedFieldValues(relatedRecord, fieldLabel, logPrefix, options);
                for (String relLabel : relatedFields.keySet()) {
                    String valueStr = formatYamlValue(relatedFields.get(relLabel));
                    lines.add(indent + prefix + relLabel + ': ' + valueStr);
                    prefix = '  ';
                }
            } else {
                // Check if PII masking should be applied (using pre-calculated set)
                Object outputValue = fieldValue;
                if (options.isPIIMaskingEnabled() && fieldValue != null && sensitiveFields.contains(fieldName.toLowerCase())) {
                    outputValue = options.piiMaskingService.maskFieldValue(fieldValue, fieldName);
                }
                String valueStr = formatYamlValue(outputValue);
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

    // UTILITY METHODS

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

    /**
     * Determines if a field is an ID field that should be excluded for token efficiency.
     * Matches: 'Id', fields ending in 'Id' (e.g., AccountId, OwnerId), and relationship IDs.
     * @param fieldName The API name of the field
     * @return true if the field is an ID field
     */
    private Boolean isIdField(String fieldName) {
        if (fieldName == null)
            return false;
        // Match 'Id' exactly or fields ending in 'Id' (case-insensitive)
        return fieldName.equalsIgnoreCase('Id') || fieldName.endsWithIgnoreCase('Id');
    }

    /**
     * Extracts field values from a related (lookup) record.
     * Uses dot notation for path (e.g., "Account.Name") for better LLM tokenization.
     * Skips ID fields from related records to avoid duplication (parent already has the lookup ID).
     *
     * @param relatedRecord The related SObject (e.g., Account from Case.Account)
     * @param pathPrefix The parent field label (e.g., "Account")
     * @param logPrefix Debug log prefix
     * @param options Formatting options
     * @return Map of flattened field paths to values
     */
    private Map<String, Object> extractRelatedFieldValues(SObject relatedRecord, String pathPrefix, String logPrefix, FormattingOptions options) {
        Map<String, Object> result = new Map<String, Object>();

        if (relatedRecord == null)
            return result;

        try {
            Map<String, Object> relatedPopulated = relatedRecord.getPopulatedFieldsAsMap();
            Schema.DescribeSObjectResult relatedDescribe = relatedRecord.getSObjectType().getDescribe();
            Map<String, SObjectField> relatedFieldMap = Utils.getObjectFields(relatedDescribe.getSObjectType());

            // Pre-calculate sensitive fields for the related record's type (optimization)
            Set<String> sensitiveFields = options.getSensitiveFieldsForType(relatedDescribe.getSObjectType());

            for (String fieldName : relatedPopulated.keySet()) {
                Object fieldValue = relatedPopulated.get(fieldName);

                // Skip nested relationships
                if (fieldValue instanceof List<SObject> || fieldValue instanceof SObject)
                    continue;

                // Always skip ID fields from related records - they're redundant
                // (the parent record already has the lookup ID field like AccountId)
                if (isIdField(fieldName))
                    continue;

                String fieldLabel = getFieldLabel(fieldName, relatedFieldMap);
                // Use dot notation for better tokenization: "Account.Name" instead of "Account → Name"
                String fullPath = pathPrefix + PATH_SEPARATOR + fieldLabel;

                // Check if PII masking should be applied (using pre-calculated set)
                Object outputValue = fieldValue;
                if (options.isPIIMaskingEnabled() && fieldValue != null && sensitiveFields.contains(fieldName.toLowerCase())) {
                    outputValue = options.piiMaskingService.maskFieldValue(fieldValue, fieldName);
                    System.debug(LoggingLevel.DEBUG, logPrefix + 'PII masked related field: ' + fullPath);
                }

                result.put(fullPath, outputValue);
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
        if (String.isBlank(content) || maxChars == null || maxChars <= 0) {
            return '';
        }
        if (content.length() <= maxChars)
            return content;

        if (maxChars <= 50) {
            String shortTruncate = content.substring(0, Math.min(content.length(), maxChars));
            if (format == 'JSON') {
                return shortTruncate + '\n... [truncated]"}';
            }
            return shortTruncate + '\n# ... [truncated due to size limit]';
        }

        Integer cutPoint = Math.max(0, maxChars - 50);
        String truncated = content.substring(0, cutPoint);

        Integer lastNewline = truncated.lastIndexOf('\n');
        if (lastNewline > 0 && lastNewline > cutPoint - 200) {
            truncated = truncated.substring(0, lastNewline);
        }

        if (format == 'JSON') {
            return truncated + '\n... [truncated]"}';
        } else {
            // Both 'Structured Text' and 'YAML' use YAML format with YAML comment syntax
            return truncated + '\n# ... [truncated due to size limit]';
        }
    }
}
