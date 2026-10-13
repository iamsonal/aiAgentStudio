/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * Shared parsing, field coercion, and response helpers for the standard
 * tools Core ships (record, Flow, and Chatter tools).
 *
 * Package-internal: keeps the tools small and their error semantics
 * identical. Validation failures before any side effect throw
 * PermanentException with instructive messages so the model can correct
 * and retry. Anything thrown after a write may have committed and must
 * surface as OutcomeUnknown instead.
 */
public inherited sharing class StandardToolSupport {
    private static final Integer MAX_MESSAGE_CHARACTERS = 2000;

    public static Map<String, Object> objectInput(String input, String label) {
        if (String.isBlank(input)) {
            throw permanent(label + ' must be a JSON object.');
        }
        try {
            Object parsed = JSON.deserializeUntyped(input);
            if (parsed instanceof Map<String, Object>) {
                return (Map<String, Object>) parsed;
            }
        } catch (Exception ignored) {
        }
        throw permanent(label + ' must be a JSON object.');
    }

    public static Map<String, Object> requiredObjectProperty(Map<String, Object> input, String key, String label) {
        Object value = input == null ? null : input.get(key);
        if (value instanceof Map<String, Object>) {
            return (Map<String, Object>) value;
        }
        throw permanent(label + ' must include an object property named ' + key + '.');
    }

    public static void assertOnlyInputKeys(Map<String, Object> input, Set<String> allowedKeys) {
        for (String key : input == null ? new Set<String>() : input.keySet()) {
            if (key == null || !allowedKeys.contains(key.toLowerCase())) {
                throw permanent('Tool input contains an unsupported property: ' + key + '.');
            }
        }
    }

    public static Map<String, Object> configuration(String raw) {
        return objectInput(raw, 'Tool implementation configuration');
    }

    public static String requiredConfig(Map<String, Object> config, String key, String label) {
        String value = config == null ? null : stringOf(config.get(key));
        if (String.isBlank(value)) {
            throw permanent(label + ' is required in the tool implementation configuration.');
        }
        return value.trim();
    }

    public static Map<String, Object> defaultFieldValues(Map<String, Object> config) {
        Object value = config == null ? null : config.get('defaultFieldValues');
        if (value == null) {
            return new Map<String, Object>();
        }
        if (value instanceof Map<String, Object>) {
            return (Map<String, Object>) value;
        }
        throw permanent('defaultFieldValues must be an object in the tool implementation configuration.');
    }

    /**
     * Checked at save, so a bad Fixed Field Value never reaches a run. Each
     * one names a field the tool can write and the agent does not also set,
     * and holds a value the field accepts: a run value that fits it, or a
     * plain value of the field's type. A picklist value must be active.
     */
    public static void assertFixedFieldValues(Schema.SObjectType objectType, Map<String, Object> config, Boolean creating) {
        Map<String, Object> defaults = defaultFieldValues(config);
        Map<String, Schema.SObjectField> fields = fieldMap(objectType);
        String objectName = objectType.getDescribe().getName();
        Set<String> agentFields = new Set<String>();
        Object configured = config == null ? null : config.get('fields');
        if (configured instanceof List<Object>) {
            for (Object value : (List<Object>) configured) {
                agentFields.add(value instanceof String ? ((String) value).trim().toLowerCase() : '');
            }
        }
        for (String name : defaults.keySet()) {
            String key = name == null ? '' : name.trim().toLowerCase();
            if (!fields.containsKey(key)) {
                throw permanent('Fixed Field Values names a field that does not exist on ' + objectName + ': ' + name + '.');
            }
            Schema.DescribeFieldResult field = fields.get(key).getDescribe();
            if (!(creating ? field.isCreateable() : field.isUpdateable())) {
                throw permanent(
                    'Fixed Field Values cannot set ' +
                        field.getName() +
                        ', because ' +
                        objectName +
                        ' does not let a ' +
                        (creating ? 'new record' : 'record update') +
                        ' set it.'
                );
            }
            if (agentFields.contains(key)) {
                throw permanent(field.getName() + ' is both a Fixed Field Value and a field the agent may set. Remove it from one of them.');
            }
            Object raw = defaults.get(name);
            ToolRunValues.Expression runValue = ToolRunValues.namedBy(raw);
            if (runValue != null) {
                String problem = runValue.fitProblem(field);
                if (problem != null) {
                    throw permanent(problem);
                }
                continue;
            }
            try {
                coerceValue(field.getType(), raw, field.getName());
            } catch (AgentKernelException.PermanentException wrongType) {
                throw permanent('Fixed Field Values: ' + wrongType.getMessage());
            }
            if (raw instanceof String && isRestrictedPicklist(field) && !activePicklistValues(field).contains((String) raw)) {
                throw permanent('Fixed Field Values: ' + (String) raw + ' is not an active value of ' + field.getName() + '.');
            }
        }
    }

    private static Boolean isRestrictedPicklist(Schema.DescribeFieldResult field) {
        return field.getType() == Schema.DisplayType.PICKLIST && field.isRestrictedPicklist();
    }

    private static Set<String> activePicklistValues(Schema.DescribeFieldResult field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : field.getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    /**
     * The Fixed Field Values for this call, with each run value, such as
     * :initiatingUserId or :endOfMonth, replaced by its value. Only the
     * admin's settings are read this way; a :name the model sends stays
     * plain text.
     */
    public static Map<String, Object> fixedFieldValues(Map<String, Object> config, Schema.SObjectType objectType, AgentKernelModels.ToolRequest request) {
        Map<String, Object> defaults = defaultFieldValues(config);
        Map<String, Schema.SObjectField> fields = fieldMap(objectType);
        Map<String, Object> resolved = new Map<String, Object>();
        for (String name : defaults.keySet()) {
            Object raw = defaults.get(name);
            ToolRunValues.Expression runValue = ToolRunValues.namedBy(raw);
            Schema.SObjectField field = name == null ? null : fields.get(name.trim().toLowerCase());
            if (runValue == null || field == null) {
                resolved.put(name, raw);
                continue;
            }
            Schema.DescribeFieldResult describe = field.getDescribe();
            String problem = runValue.fitProblem(describe);
            if (problem != null) {
                throw permanent(problem);
            }
            resolved.put(name, runValue.resolveFor(request, describe));
        }
        return resolved;
    }

    public static Map<String, Object> mergeDefaultFieldValues(Map<String, Object> defaults, Map<String, Object> modelValues) {
        Map<String, Object> merged = new Map<String, Object>();
        Set<String> configuredNames = new Set<String>();
        for (String name : defaults == null ? new Set<String>() : defaults.keySet()) {
            String normalized = name == null ? '' : name.trim().toLowerCase();
            if (String.isBlank(normalized)) {
                throw permanent('defaultFieldValues contains a blank field name.');
            }
            if (configuredNames.contains(normalized)) {
                throw permanent('defaultFieldValues contains duplicate field names: ' + name + '.');
            }
            configuredNames.add(normalized);
            merged.put(name.trim(), defaults.get(name));
        }
        for (String name : modelValues == null ? new Set<String>() : modelValues.keySet()) {
            String normalized = name == null ? '' : name.trim().toLowerCase();
            if (configuredNames.contains(normalized)) {
                throw permanent('Tool input must not set the operator-managed default field: ' + name + '.');
            }
            merged.put(name, modelValues.get(name));
        }
        return merged;
    }

    public static String stringOf(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof String) {
            return ((String) value).trim();
        }
        return String.valueOf(value);
    }

    /**
     * Agent Core's own records are never tool targets: an agent must not read
     * or change runs, approvals, trust data, its own configuration, or the
     * events that report on them. The optional packages' records are listed
     * too, so a standard tool can never reach a channel ledger or a route.
     */
    private static final Set<String> CORE_OBJECTS = new Set<String>{
        'agentrun__c',
        'agentcommand__c',
        'agentevent__c',
        'agentinvocation__c',
        'agenttrusttoken__c',
        'agenttrustkey__c',
        'agentapproval__c',
        'agentdefinition__c',
        'agenttool__c',
        'agentcontextprovider__c',
        'agentexecutionidentity__c',
        'agentlifecycleevent__e',
        'agentoperationalsignal__e',
        'agentapprovalroute__c',
        'agentchannelconversation__c',
        'agentchannelmessage__c',
        'agentchannelroute__c',
        'agentchannelsignal__e'
    };
    /** Platform objects that expose a custom object's sharing, history, feed, or changes. */
    private static final List<String> COMPANION_SUFFIXES = new List<String>{ '__share', '__history', '__feed', '__changeevent' };

    public static Schema.SObjectType resolveObject(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            throw permanent('An object type is required.');
        }
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(objectApiName.trim());
        if (objectType == null) {
            throw permanent('Unknown object: ' + objectApiName.trim() + '.');
        }
        if (isCoreObject(objectType.getDescribe().getName())) {
            throw permanent('Agent Core records cannot be used as a tool target.');
        }
        return objectType;
    }

    /** True for Agent Core's own objects, which are never tool targets. */
    public static Boolean isCoreObject(String objectApiName) {
        if (String.isBlank(objectApiName)) {
            return false;
        }
        String name = objectApiName.trim().toLowerCase();
        for (String suffix : COMPANION_SUFFIXES) {
            if (name.endsWith(suffix)) {
                name = name.removeEnd(suffix) + '__c';
                break;
            }
        }
        return CORE_OBJECTS.contains(name);
    }

    public static Map<String, Schema.SObjectField> fieldMap(Schema.SObjectType objectType) {
        Map<String, Schema.SObjectField> fields = objectType.getDescribe().fields.getMap();
        Map<String, Schema.SObjectField> byName = new Map<String, Schema.SObjectField>();
        for (String apiName : fields.keySet()) {
            byName.put(apiName.toLowerCase(), fields.get(apiName));
        }
        return byName;
    }

    /** Converts a configuration failure into the message list ITool.validateConfiguration returns. */
    public static List<String> problems(Exception failure) {
        return new List<String>{ failure == null ? 'The tool configuration is invalid.' : failure.getMessage() };
    }

    public static final String ANCHOR_RECORD_ONLY = 'anchorRecordOnly';

    /**
     * True when Update Record may change only the run's anchor record, so the
     * model never chooses which record. Refuses the replaced "target" and
     * "relatedThrough" settings instead of ignoring them, because ignoring
     * them would let a tool that was limited to one record change any record.
     */
    public static Boolean anchorRecordOnly(Map<String, Object> config) {
        if (config != null && (config.containsKey('target') || config.containsKey('relatedThrough'))) {
            throw permanent('"target" and "relatedThrough" are replaced by "anchorRecordOnly". Set "anchorRecordOnly": true to update only the run\'s record.');
        }
        Object value = config == null ? null : config.get(ANCHOR_RECORD_ONLY);
        if (value == null) {
            return false;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        throw permanent('anchorRecordOnly must be true or false.');
    }

    public static Id anchorRecordId(AgentKernelModels.ToolRequest request, Schema.SObjectType objectType) {
        Id anchorId = request == null || request.principal == null ? null : request.principal.anchorRecordId;
        if (anchorId == null) {
            throw permanent('This tool acts on the run\'s anchor record, but the run has none.');
        }
        if (objectType != null && anchorId.getSObjectType() != objectType) {
            throw permanent('The run\'s anchor record is not a ' + objectType.getDescribe().getName() + '.');
        }
        return anchorId;
    }

    /**
     * Coerces a JSON-deserialized value to the shape SObject.put expects for
     * the field type. Nested maps and lists are rejected: these tools bind
     * flat scalar parameters only.
     */
    public static Object coerceValue(Schema.DisplayType fieldType, Object raw, String fieldLabel) {
        if (raw == null) {
            return null;
        }
        if (raw instanceof Map<String, Object> || raw instanceof List<Object>) {
            throw permanent('Field ' + fieldLabel + ' does not accept a structured value.');
        }
        if (fieldType == Schema.DisplayType.BOOLEAN) {
            if (raw instanceof Boolean) {
                return raw;
            }
            throw permanent('Field ' + fieldLabel + ' requires true or false.');
        }
        if (fieldType == Schema.DisplayType.INTEGER) {
            if (raw instanceof Integer) {
                return raw;
            }
            if (raw instanceof Decimal && ((Decimal) raw).scale() == 0) {
                return Integer.valueOf(((Decimal) raw).intValue());
            }
            throw permanent('Field ' + fieldLabel + ' requires a whole number.');
        }
        if (fieldType == Schema.DisplayType.DOUBLE || fieldType == Schema.DisplayType.CURRENCY || fieldType == Schema.DisplayType.PERCENT) {
            if (raw instanceof Decimal || raw instanceof Integer || raw instanceof Double || raw instanceof Long) {
                return Decimal.valueOf(String.valueOf(raw));
            }
            throw permanent('Field ' + fieldLabel + ' requires a number.');
        }
        if (fieldType == Schema.DisplayType.DATE) {
            // A Date or Datetime object comes only from a run value; model input is JSON text.
            if (raw instanceof Date) {
                return raw;
            }
            if (raw instanceof String) {
                try {
                    return Date.valueOf(((String) raw).trim());
                } catch (Exception ignored) {
                }
            }
            throw permanent('Field ' + fieldLabel + ' requires an ISO-8601 date (yyyy-MM-dd).');
        }
        if (fieldType == Schema.DisplayType.DATETIME) {
            if (raw instanceof Datetime) {
                return raw;
            }
            // ISO-8601 keeps the time zone the model wrote; Datetime.valueOf would read it in the service user's zone.
            if (raw instanceof String) {
                Datetime parsed = parseIsoDatetime(((String) raw).trim());
                if (parsed != null) {
                    return parsed;
                }
            }
            throw permanent('Field ' + fieldLabel + ' requires an ISO-8601 datetime with a time zone, such as 2026-10-01T15:30:00Z.');
        }
        if (fieldType == Schema.DisplayType.TIME) {
            if (raw instanceof String) {
                try {
                    return parseTime(((String) raw).trim());
                } catch (Exception ignored) {
                }
            }
            throw permanent('Field ' + fieldLabel + ' requires a time in Salesforce format (HH:mm:ss.SSS).');
        }
        if (fieldType == Schema.DisplayType.REFERENCE) {
            if (raw instanceof String || raw instanceof Id) {
                try {
                    return Id.valueOf(String.valueOf(raw).trim());
                } catch (Exception ignored) {
                }
            }
            throw permanent('Field ' + fieldLabel + ' requires a valid Salesforce record ID.');
        }
        if (raw instanceof String) {
            return raw;
        }
        return String.valueOf(raw);
    }

    private static final Pattern ISO_DATETIME = Pattern.compile(
        '^(\\d{4})-(\\d{2})-(\\d{2})[T ](\\d{2}):(\\d{2})(?::(\\d{2})(?:\\.\\d{1,9})?)?(Z|[+-]\\d{2}:?\\d{2})$'
    );

    /** An ISO-8601 datetime with its time zone (Z or an offset), as an instant; null when it is not one. */
    @TestVisible
    private static Datetime parseIsoDatetime(String value) {
        Matcher match = ISO_DATETIME.matcher(value == null ? '' : value);
        if (!match.matches()) {
            return null;
        }
        Integer year = Integer.valueOf(match.group(1));
        Integer month = Integer.valueOf(match.group(2));
        Integer day = Integer.valueOf(match.group(3));
        Integer hour = Integer.valueOf(match.group(4));
        Integer minute = Integer.valueOf(match.group(5));
        Integer second = match.group(6) == null ? 0 : Integer.valueOf(match.group(6));
        if (month < 1 || month > 12 || day < 1 || day > Date.daysInMonth(year, month) || hour > 23 || minute > 59 || second > 59) {
            return null;
        }
        Datetime instant = Datetime.newInstanceGmt(year, month, day, hour, minute, second);
        String zone = match.group(7);
        if (zone != 'Z') {
            String digits = zone.substring(1).remove(':');
            Integer offsetMinutes = Integer.valueOf(digits.left(2)) * 60 + Integer.valueOf(digits.right(2));
            // Local time minus its offset is UTC.
            instant = instant.addMinutes(zone.startsWith('+') ? -offsetMinutes : offsetMinutes);
        }
        return instant;
    }

    private static Time parseTime(String value) {
        Matcher match = Pattern.compile('^(\\d{2}):(\\d{2}):(\\d{2})(?:\\.(\\d{1,3}))?$').matcher(value);
        if (!match.matches()) {
            throw new IllegalArgumentException('Invalid time format.');
        }
        Integer hour = Integer.valueOf(match.group(1));
        Integer minute = Integer.valueOf(match.group(2));
        Integer second = Integer.valueOf(match.group(3));
        Integer millisecond = 0;
        if (match.group(4) != null) {
            String fraction = match.group(4);
            millisecond = Integer.valueOf((fraction + '000').substring(0, 3));
        }
        return Time.newInstance(hour, minute, second, millisecond);
    }

    /** Configuration key: the developer name of the record type Create Record gives new records. Blank uses the default. */
    public static final String RECORD_TYPE_KEY = 'recordTypeDeveloperName';

    /**
     * The record type the admin chose for new records, or null when none is
     * set. The developer name is the same in every org, unlike the Id. The
     * record type has one owner: a tool that also sets RecordTypeId in
     * defaultFieldValues or lets the agent set it is refused.
     */
    public static Schema.RecordTypeInfo chosenRecordType(Schema.SObjectType objectType, Map<String, Object> config) {
        String name = config == null ? null : stringOf(config.get(RECORD_TYPE_KEY));
        if (String.isBlank(name)) {
            return null;
        }
        for (String field : defaultFieldValues(config).keySet()) {
            if (field != null && field.trim().equalsIgnoreCase('RecordTypeId')) {
                throw permanent('Set the record type in ' + RECORD_TYPE_KEY + ' or in defaultFieldValues.RecordTypeId, not both.');
            }
        }
        Object listed = config.get('fields');
        for (Object field : listed instanceof List<Object> ? (List<Object>) listed : new List<Object>()) {
            if (field instanceof String && ((String) field).trim().equalsIgnoreCase('RecordTypeId')) {
                throw permanent('The agent cannot choose RecordTypeId while ' + RECORD_TYPE_KEY + ' sets it. Remove RecordTypeId from fields.');
            }
        }
        String objectApiName = objectType.getDescribe().getName();
        for (Schema.RecordTypeInfo info : objectType.getDescribe().getRecordTypeInfos()) {
            if (!info.isMaster() && info.isActive() && info.getDeveloperName().equalsIgnoreCase(name)) {
                return info;
            }
        }
        throw permanent(
            RECORD_TYPE_KEY +
                ' ' +
                name +
                ' is not an active record type of ' +
                objectApiName +
                '. Choose an active record type, or leave it blank to use the default.'
        );
    }

    public static void assertActiveRecordType(Schema.SObjectType objectType, Object value, String fieldLabel) {
        if (value == null) {
            return;
        }
        Id recordTypeId;
        try {
            recordTypeId = (Id) value;
        } catch (Exception invalid) {
            throw permanent('Field ' + fieldLabel + ' requires a valid Salesforce record type ID.');
        }
        if (recordTypeId.getSObjectType().getDescribe().getName() != 'RecordType') {
            throw permanent('Field ' + fieldLabel + ' requires a record type ID.');
        }
        String objectApiName = objectType.getDescribe().getName();
        List<RecordType> recordTypes = [
            SELECT Id
            FROM RecordType
            WHERE Id = :recordTypeId AND SObjectType = :objectApiName AND IsActive = TRUE
            WITH USER_MODE
            LIMIT 1
        ];
        if (recordTypes.isEmpty()) {
            throw permanent('Record type is inactive, not valid for ' + objectApiName + ', or not visible to the execution principal.');
        }
    }

    /**
     * A record locked by another transaction is transient, and these tools run
     * in a savepoint, so repeating the call is safe. Every other DML rejection
     * goes back to the model to correct.
     */
    public static AgentKernelException dmlFailure(String objectApiName, String operation, DmlException failure) {
        String status = failure.getDmlStatusCode(0);
        if (status == 'UNABLE_TO_LOCK_ROW') {
            return new AgentKernelException.RetryableException('The ' + objectApiName + ' record is locked by another update; retrying.');
        }
        String guidance;
        if (status == 'REQUIRED_FIELD_MISSING') {
            guidance = ' Supply all required fields.';
        } else if (status == 'FIELD_CUSTOM_VALIDATION_EXCEPTION') {
            guidance = ' Correct the value rejected by the validation rule.';
        } else if (status == 'DUPLICATE_VALUE') {
            guidance = ' Use a value that does not conflict with an existing record.';
        } else if (status == 'STRING_TOO_LONG') {
            guidance = ' Shorten the supplied text value.';
        } else {
            guidance = '';
        }
        return permanent('The ' + objectApiName + ' record could not be ' + operation + ': ' + bound(failure.getDmlMessage(0), 500) + guidance);
    }

    public static AgentKernelModels.ToolResponse success(String output) {
        AgentKernelModels.ToolResponse response = new AgentKernelModels.ToolResponse();
        response.isSuccess = true;
        response.outcomeUnknown = false;
        response.output = output;
        return response;
    }

    public static String bound(String value, Integer maxCharacters) {
        if (value == null) {
            return '';
        }
        Integer ceiling = maxCharacters == null ? MAX_MESSAGE_CHARACTERS : maxCharacters;
        return value.length() > ceiling ? value.substring(0, ceiling) : value;
    }

    public static AgentKernelException.PermanentException permanent(String message) {
        return new AgentKernelException.PermanentException(bound(message, MAX_MESSAGE_CHARACTERS));
    }
}
