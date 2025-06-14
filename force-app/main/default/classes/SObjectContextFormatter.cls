/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Formats SObject lists into structured text or Maps for LLM context.
 *              This class is optimized to perform a single, cached schema describe call per
 *              SObject type per transaction, ensuring high performance and eliminating
 *              redundant processing and log spam.
 */
public inherited sharing class SObjectContextFormatter {
    @TestVisible
    private class ObjectSchemaInfo {
        public DescribeSObjectResult objectDescribe { get; private set; }
        public Map<String, DescribeFieldResult> fieldDescribeMap { get; private set; }

        public ObjectSchemaInfo(DescribeSObjectResult objDescribe) {
            this.objectDescribe = objDescribe;
            this.fieldDescribeMap = new Map<String, DescribeFieldResult>();
            if (objDescribe != null && objDescribe.fields != null && objDescribe.fields.getMap() != null) {
                for (SObjectField fieldToken : objDescribe.fields.getMap().values()) {
                    DescribeFieldResult dfr = fieldToken.getDescribe();

                    this.fieldDescribeMap.put(dfr.getName().toLowerCase(), dfr);
                }
            }
        }
    }

    @TestVisible
    private static Map<SObjectType, ObjectSchemaInfo> schemaInfoCache = new Map<SObjectType, ObjectSchemaInfo>();

    private static final Map<String, Set<String>> PICKLIST_EXCLUSION_MAP = new Map<String, Set<String>>{
        'User' => new Set<String>{ 'TimeZoneSidKey', 'LocaleSidKey', 'LanguageLocaleKey' }
    };

    /**
     * @description Gets all necessary schema information for an SObject, using a
     *              transaction-scoped cache to ensure describe calls happen only once.
     * @param sObjType The SObject type to describe.
     * @param logPrefix Logging prefix.
     * @return An ObjectSchemaInfo DTO containing the describe results, or null on error.
     */
    private static ObjectSchemaInfo getSchemaInfo(SObjectType sObjType, String logPrefix) {
        if (sObjType == null)
            return null;

        if (!schemaInfoCache.containsKey(sObjType)) {
            ObjectSchemaInfo newSchemaInfo = null;
            try {
                DescribeSObjectResult objDescribe = sObjType.getDescribe(SObjectDescribeOptions.DEFERRED);
                newSchemaInfo = new ObjectSchemaInfo(objDescribe);
            } catch (Exception e) {
            }
            schemaInfoCache.put(sObjType, newSchemaInfo);
        }
        return schemaInfoCache.get(sObjType);
    }

    public static String formatSObjectListAsHumanReadable(String mainLabel, String subLabel, List<SObject> records, String logPrefix) {
        if (records == null || records.isEmpty())
            return '';

        SObjectType objType = records[0].getSObjectType();
        ObjectSchemaInfo schemaInfo = getSchemaInfo(objType, logPrefix);
        if (schemaInfo == null)
            return '';

        String blockLabel = String.isNotBlank(subLabel) ? subLabel : mainLabel;
        List<String> formattedRecords = new List<String>();

        for (SObject record : records) {
            Map<String, Object> fields = record.getPopulatedFieldsAsMap();
            List<String> fieldEntries = new List<String>();

            for (String fieldName : fields.keySet()) {
                DescribeFieldResult dfr = schemaInfo.fieldDescribeMap.get(fieldName.toLowerCase());
                if (dfr != null && dfr.isAccessible()) {
                    Object value = fields.get(fieldName);
                    String displayValue = (value == null || (value instanceof String && String.isBlank((String) value)))
                        ? '[Not Set]'
                        : String.valueOf(value);
                    fieldEntries.add(dfr.getLabel() + ': ' + displayValue);
                }
            }
            if (!fieldEntries.isEmpty()) {
                formattedRecords.add(formatSingleRecordAsText(record, fieldEntries));
            }
        }

        if (formattedRecords.isEmpty())
            return '';
        return '** ' + blockLabel + ' (' + formattedRecords.size() + ' Records) **\n' + String.join(formattedRecords, '\n');
    }

    public static List<Map<String, Object>> formatSObjectListAsMaps(List<SObject> records, String logPrefix) {
        if (records == null || records.isEmpty())
            return new List<Map<String, Object>>();

        SObjectType objType = records[0].getSObjectType();
        ObjectSchemaInfo schemaInfo = getSchemaInfo(objType, logPrefix);
        if (schemaInfo == null)
            return new List<Map<String, Object>>();

        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (SObject record : records) {
            Map<String, Object> fieldDataMap = new Map<String, Object>();
            Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

            for (String fieldApiName : populatedFields.keySet()) {
                DescribeFieldResult dfr = schemaInfo.fieldDescribeMap.get(fieldApiName.toLowerCase());
                if (dfr != null && dfr.isAccessible()) {
                    fieldDataMap.put(dfr.getName(), populatedFields.get(fieldApiName));
                }
            }
            if (!fieldDataMap.isEmpty()) {
                results.add(fieldDataMap);
            }
        }
        return results;
    }

    public static Map<String, Object> formatSObjectSchema(List<SObject> records, String logPrefix) {
        if (records == null || records.isEmpty())
            return new Map<String, Object>();

        SObjectType sObjType = records[0].getSObjectType();
        ObjectSchemaInfo schemaInfo = getSchemaInfo(sObjType, logPrefix);
        if (schemaInfo == null)
            return new Map<String, Object>();

        DescribeSObjectResult sObjDescribe = schemaInfo.objectDescribe;
        String sObjectApiName = sObjDescribe.getName();
        Set<String> exclusionsForThisObject = PICKLIST_EXCLUSION_MAP.get(sObjectApiName) ?? new Set<String>();
        Map<String, Object> schemaResult = new Map<String, Object>();

        try {
            Set<String> populatedFieldApiNames = new Set<String>();
            for (SObject record : records) {
                populatedFieldApiNames.addAll(record.getPopulatedFieldsAsMap().keySet());
            }
            if (populatedFieldApiNames.isEmpty())
                return schemaResult;

            schemaResult.put('label', sObjDescribe.getLabel());
            schemaResult.put('apiName', sObjectApiName);
            schemaResult.put('labelPlural', sObjDescribe.getLabelPlural());

            if (schemaInfo.fieldDescribeMap.containsKey('recordtypeid') && populatedFieldApiNames.contains('RecordTypeId')) {
                try {
                    Id recordTypeId = (Id) records[0].get('RecordTypeId');
                    if (recordTypeId != null) {
                        RecordTypeInfo rti = sObjDescribe.getRecordTypeInfosById().get(recordTypeId);
                        if (rti != null && !rti.isMaster()) {
                            schemaResult.put(
                                'recordTypeInfo',
                                new Map<String, Object>{ 'name' => rti.getName(), 'developerName' => rti.getDeveloperName() }
                            );
                        }
                    }
                } catch (Exception e) {
                }
            }

            Map<String, Object> fieldSchemas = new Map<String, Object>();
            for (String fieldApiName : populatedFieldApiNames) {
                DescribeFieldResult dfr = schemaInfo.fieldDescribeMap.get(fieldApiName.toLowerCase());
                if (dfr == null || !dfr.isAccessible())
                    continue;

                Map<String, Object> fieldDetails = new Map<String, Object>();
                fieldDetails.put('label', dfr.getLabel());
                fieldDetails.put('type', String.valueOf(dfr.getType()).toLowerCase());
                fieldDetails.put('updateable', dfr.isUpdateable());
                fieldDetails.put('requiredOnCreate', !dfr.isNillable() && dfr.isCreateable());

                if (dfr.getType() == DisplayType.PICKLIST) {
                    if (exclusionsForThisObject.contains(dfr.getName())) {
                        fieldDetails.put('picklistValues', '[Omitted for brevity]');
                    } else {
                        Map<String, String> picklistValueMap = new Map<String, String>();
                        for (PicklistEntry entry : dfr.getPicklistValues()) {
                            if (entry.isActive()) {
                                picklistValueMap.put(entry.getValue(), entry.getLabel());
                            }
                        }
                        if (!picklistValueMap.isEmpty()) {
                            fieldDetails.put('picklistValues', picklistValueMap);
                        }
                    }
                }
                fieldSchemas.put(dfr.getName(), fieldDetails);
            }

            if (!fieldSchemas.isEmpty()) {
                schemaResult.put('fields', fieldSchemas);
            }
        } catch (Exception e) {
            return new Map<String, Object>();
        }
        return schemaResult;
    }

    private static String formatSingleRecordAsText(SObject record, List<String> fieldEntries) {
        String nameValue = findAccessibleFieldValue(fieldEntries, 'Name: ');
        String subjectValue = findAccessibleFieldValue(fieldEntries, 'Subject: ');
        String caseNumValue = findAccessibleFieldValue(fieldEntries, 'Case Number: ');

        String displayPrefix = nameValue ?? subjectValue ?? caseNumValue ?? 'Record ' + record.Id;

        List<String> otherFields = new List<String>();
        for (String entry : fieldEntries) {
            if (!entry.startsWith('Name: ') && !entry.startsWith('Subject: ') && !entry.startsWith('Case Number: ')) {
                otherFields.add(entry);
            }
        }

        String recordString = displayPrefix;
        if (!otherFields.isEmpty()) {
            recordString += ' (' + String.join(otherFields, ' | ') + ')';
        }
        return '- ' + recordString;
    }

    private static String findAccessibleFieldValue(List<String> fieldEntries, String prefix) {
        for (String entry : fieldEntries) {
            if (entry.startsWithIgnoreCase(prefix)) {
                return entry.substring(prefix.length()).trim();
            }
        }
        return null;
    }

    @TestVisible
    private static void clearCache() {
        schemaInfoCache.clear();
    }
}
