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
 * Settings and Input Schemas of the standard tool types. The model-facing
 * schema of a standard tool is fully determined by what the admin chose (the
 * query's binds, the writable fields), so an admin never writes JSON Schema
 * for one. Each standard tool's IToolAuthoring description builds it here,
 * and ToolSchemaService builds it again on each run.
 *
 * Run Flow tools build their inputs from the Flow's input variables.
 */
public inherited sharing class StandardToolSchemas {
    /** Core's own limit on allowed values. */
    private static final Integer MAX_ENUM_VALUES = 100;
    /** A lookup that can point to more objects than this is described as any record Id. */
    private static final Integer MAX_NAMED_TARGETS = 3;
    /** Field types whose length is a character limit. */
    private static final Set<Schema.DisplayType> TEXT_TYPES = new Set<Schema.DisplayType>{
        Schema.DisplayType.STRING,
        Schema.DisplayType.TEXTAREA,
        Schema.DisplayType.EMAIL,
        Schema.DisplayType.PHONE,
        Schema.DisplayType.URL,
        Schema.DisplayType.ENCRYPTEDSTRING,
        Schema.DisplayType.COMBOBOX
    };
    private static final Integer MAX_WRITABLE_FIELDS = 30;
    /**
     * Each record type's picklist values by lowercase field name, read once
     * per transaction. Apex describe cannot scope picklists to a record type,
     * so this uses the UI API read, which counts toward the org's API request
     * limit; it runs only when a tool is saved or previewed.
     */
    @TestVisible
    private static Map<String, Map<String, List<String>>> recordTypeValues = new Map<String, Map<String, List<String>>>();

    /** The settings of Create Record (creating) or Update Record. */
    public static List<AgentKernelModels.ToolSetting> recordSettings(Boolean creating) {
        String verb = creating ? 'set' : 'change';
        List<AgentKernelModels.ToolSetting> settings = new List<AgentKernelModels.ToolSetting>{
            new AgentKernelModels.ToolSetting(
                'objectApiName',
                'Object',
                'object',
                true,
                'The object whose records the agent ' + (creating ? 'creates' : 'updates') + ', such as Case.'
            ),
            objectSetting(
                new AgentKernelModels.ToolSetting(
                    'fields',
                    'Fields the Agent May ' + (creating ? 'Set' : 'Change'),
                    'fields',
                    true,
                    '1 to ' + MAX_WRITABLE_FIELDS + ' fields. The agent can ' + verb + ' only these fields.'
                )
            ),
            objectSetting(
                new AgentKernelModels.ToolSetting(
                    'defaultFieldValues',
                    'Fixed Field Values',
                    'fieldValues',
                    false,
                    'Field values every ' +
                        (creating ? 'new record gets' : 'update sets') +
                        '. The agent cannot change them, and they cannot also be fields the agent may set. A value can be one Pluto fills in ' +
                        'on each call: the run\'s record, its users, today or a date relative to it, or now.'
                )
            )
        };
        if (creating) {
            // Record Type comes right after Object: it decides which picklist values the fields offer.
            settings.add(
                1,
                objectSetting(
                    new AgentKernelModels.ToolSetting(
                        StandardToolSupport.RECORD_TYPE_KEY,
                        'Record Type',
                        'recordType',
                        false,
                        'The record type new records get. It decides which picklist values the agent may choose.'
                    )
                )
            );
            settings[1].blankMeaning = 'The default record type';
            return settings;
        }
        settings.add(
            new AgentKernelModels.ToolSetting(
                StandardToolSupport.ANCHOR_RECORD_ONLY,
                'Anchor Record Only',
                'boolean',
                false,
                'Check to update only the run\'s record (its Anchor Record ID). The agent does not choose the record, so text it reads cannot point it at another record. ' +
                'Leave unchecked to let the agent choose any record the run user can edit.'
            )
        );
        return settings;
    }

    private static AgentKernelModels.ToolSetting objectSetting(AgentKernelModels.ToolSetting setting) {
        setting.objectSetting = 'objectApiName';
        return setting;
    }

    /**
     * The Input Schema of Create Record (creating) or Update Record: a
     * recordData object of the listed fields, plus recordId when the agent
     * chooses the record. Throws the message the tool's save would report.
     */
    public static String recordInputs(String implementationConfiguration, Boolean creating) {
        Map<String, Object> config = StandardToolSupport.configuration(implementationConfiguration);
        Schema.SObjectType objectType = StandardToolSupport.resolveObject(StandardToolSupport.requiredConfig(config, 'objectApiName', 'objectApiName'));
        String objectLabel = objectType.getDescribe().getLabel();
        List<Schema.DescribeFieldResult> writable = writableFields(config, objectType, creating);
        Schema.RecordTypeInfo recordType = creating ? StandardToolSupport.chosenRecordType(objectType, config) : null;
        Set<String> defaulted = new Set<String>();
        for (String name : StandardToolSupport.defaultFieldValues(config).keySet()) {
            defaulted.add(name == null ? '' : name.trim().toLowerCase());
        }
        Map<String, Object> values = new Map<String, Object>();
        List<String> requiredValues = new List<String>();
        for (Schema.DescribeFieldResult field : writable) {
            // A fixed value is the tool's, never the model's, so it is not an input.
            if (defaulted.contains(field.getName().toLowerCase())) {
                continue;
            }
            values.put(field.getName(), fieldProperty(field, field.getLabel() + ' of the ' + objectLabel + '.', objectType, recordType));
            if (creating && mustBeSentOnCreate(field, defaulted)) {
                requiredValues.add(field.getName());
            }
        }
        Map<String, Object> recordData = objectProperty(values, requiredValues);
        recordData.put('description', creating ? 'Field values for the new ' + objectLabel + '.' : 'Field values to change on the ' + objectLabel + '.');
        Map<String, Object> properties = new Map<String, Object>{ 'recordData' => recordData };
        List<String> required = new List<String>{ 'recordData' };
        if (!creating && !StandardToolSupport.anchorRecordOnly(config)) {
            properties.put(
                'recordId',
                new Map<String, Object>{ 'type' => 'string', 'format' => 'salesforce-id', 'description' => 'The Id of the ' + objectLabel + ' to update.' }
            );
            required.add('recordId');
        }
        return closed(properties, required);
    }

    /** One required input per bind, typed from the field it is compared to; a run value, such as :anchorId, is never an input. */
    public static String queryInputs(StandardQueryRecordsTool.Query query) {
        Map<String, Object> properties = new Map<String, Object>();
        List<String> required = new List<String>();
        for (StandardQueryRecordsTool.Bind bind : query.binds) {
            if (bind.isRunValue()) {
                continue;
            }
            if (bind.isCount()) {
                properties.put(
                    bind.name,
                    new Map<String, Object>{
                        'type' => 'integer',
                        'minimum' => bind.operator == 'LIMIT' ? 1 : 0,
                        'description' => bind.operator == 'LIMIT' ? 'Most records to return.' : 'Records to skip before the first one returned.'
                    }
                );
                required.add(bind.name);
                continue;
            }
            String description = bindDescription(bind);
            Map<String, Object> property = fieldProperty(bind.field.field, description, bind.field.ownerType, null);
            if (bind.isList) {
                property.remove('description');
                property = new Map<String, Object>{ 'type' => 'array', 'items' => property, 'description' => description };
            }
            properties.put(bind.name, property);
            required.add(bind.name);
        }
        return closed(properties, required);
    }

    private static final Map<String, String> COMPARISONS = new Map<String, String>{
        '!=' => 'is not',
        '<>' => 'is not',
        '<' => 'is less than',
        '>' => 'is greater than',
        '<=' => 'is at most',
        '>=' => 'is at least',
        'LIKE' => 'is like',
        'NOT IN' => 'is none of',
        'INCLUDES' => 'includes one of',
        'EXCLUDES' => 'excludes all of'
    };

    /** What a bind does, in words, such as "The Account ID to match." */
    private static String bindDescription(StandardQueryRecordsTool.Bind bind) {
        String label = bind.field.field.getLabel() + (bind.field.path.contains('.') ? ' (' + bind.field.path + ')' : '');
        String description;
        if (bind.operator == '=') {
            description = 'The ' + label + ' to match.';
        } else if (bind.operator == 'IN') {
            description = 'The ' + label + ' values to match, 1 to 50 of them.';
        } else {
            String comparison = COMPARISONS.containsKey(bind.operator) ? COMPARISONS.get(bind.operator) : bind.operator;
            description = 'Finds records whose ' + label + ' ' + comparison + (bind.isList ? ' these values, 1 to 50 of them.' : ' this value.');
        }
        return description + (bind.operator == 'LIKE' ? ' Use % as a wildcard, such as %refund%.' : '');
    }

    /**
     * Run Flow's inputs: one optional input per input variable of the Flow's
     * active version. Record, Apex-defined, and collection variables are left
     * out, because a model sends plain JSON values. The admin makes inputs
     * required with edits, because a Flow does not mark them.
     */
    public static String flowInputs(FlowDefinitionView definition) {
        Map<String, Object> properties = new Map<String, Object>();
        List<FlowVariableView> variables;
        try {
            // Flow metadata visibility can require elevation; it holds no business data.
            variables = [
                SELECT ApiName, DataType, Description, IsCollection
                FROM FlowVariableView
                WHERE FlowVersionViewId = :definition.ActiveVersionId AND IsInput = TRUE
                WITH SYSTEM_MODE
                ORDER BY ApiName
            ];
        } catch (Exception metadataUnavailable) {
            throw StandardToolSupport.permanent('The input variables of Flow "' + definition.ApiName + '" could not be read.');
        }
        for (FlowVariableView variable : variables) {
            Map<String, Object> property = variable.IsCollection == true ? null : flowProperty(variable.DataType);
            if (property == null) {
                continue;
            }
            property.put(
                'description',
                String.isBlank(variable.Description) ? 'Input variable ' + variable.ApiName + ' of the Flow.' : variable.Description.abbreviate(2000)
            );
            properties.put(variable.ApiName, property);
        }
        return closed(properties, new List<String>());
    }

    private static Map<String, Object> flowProperty(String dataType) {
        String normalized = String.isBlank(dataType) ? '' : dataType.trim().toLowerCase();
        if (normalized == 'string' || normalized == 'picklist' || normalized == 'multipicklist' || normalized == 'text') {
            return new Map<String, Object>{ 'type' => 'string' };
        }
        if (normalized == 'integer') {
            return new Map<String, Object>{ 'type' => 'integer' };
        }
        if (normalized == 'number' || normalized == 'double' || normalized == 'decimal' || normalized == 'currency' || normalized == 'percent') {
            return new Map<String, Object>{ 'type' => 'number' };
        }
        if (normalized == 'boolean') {
            return new Map<String, Object>{ 'type' => 'boolean' };
        }
        if (normalized == 'date') {
            return new Map<String, Object>{ 'type' => 'string', 'format' => 'date' };
        }
        if (normalized == 'datetime') {
            return new Map<String, Object>{ 'type' => 'string', 'format' => 'date-time' };
        }
        return null;
    }

    /** Post Chatter's one input: the text to post. */
    public static String chatterInputs(Integer maxCharacters) {
        return closed(
            new Map<String, Object>{
                'messageText' => new Map<String, Object>{
                    'type' => 'string',
                    'minLength' => 1,
                    'maxLength' => maxCharacters,
                    'description' => 'The text to post.'
                }
            },
            new List<String>{ 'messageText' }
        );
    }

    /** The writable fields an admin chose for Create or Update Record. The list is required: it is the tool's only field grant. */
    public static List<Schema.DescribeFieldResult> writableFields(Map<String, Object> config, Schema.SObjectType objectType, Boolean creating) {
        Object configured = config == null ? null : config.get('fields');
        if (configured == null) {
            throw StandardToolSupport.permanent(
                'List the fields the agent may ' + (creating ? 'set' : 'update') + ' in fields, for example "fields":["Subject","Priority"].'
            );
        }
        if (!(configured instanceof List<Object>) || ((List<Object>) configured).isEmpty() || ((List<Object>) configured).size() > MAX_WRITABLE_FIELDS) {
            throw StandardToolSupport.permanent('fields must list 1 through ' + MAX_WRITABLE_FIELDS + ' field API names the agent may write.');
        }
        Map<String, Schema.SObjectField> fieldMap = StandardToolSupport.fieldMap(objectType);
        List<Schema.DescribeFieldResult> result = new List<Schema.DescribeFieldResult>();
        for (Object value : (List<Object>) configured) {
            String name = value instanceof String ? ((String) value).trim().toLowerCase() : '';
            Schema.DescribeFieldResult field = fieldMap.containsKey(name) ? fieldMap.get(name).getDescribe() : null;
            if (field == null || !(creating ? field.isCreateable() : field.isUpdateable())) {
                throw StandardToolSupport.permanent(
                    'Field ' +
                        String.valueOf(value) +
                        ' does not exist on ' +
                        objectType.getDescribe().getName() +
                        ' or cannot be ' +
                        (creating ? 'set on create.' : 'updated.')
                );
            }
            result.add(field);
        }
        return result;
    }

    /**
     * A listed field the model must send to create a record: the record
     * cannot be saved without it, the platform does not fill it, it is not a
     * checkbox (always set), and the tool does not supply it as a default.
     * Updates change only what they send, so they require no field.
     */
    private static Boolean mustBeSentOnCreate(Schema.DescribeFieldResult field, Set<String> defaulted) {
        return !field.isNillable() &&
            !field.isDefaultedOnCreate() &&
            field.getType() != Schema.DisplayType.BOOLEAN &&
            !defaulted.contains(field.getName().toLowerCase());
    }

    private static String closed(Map<String, Object> properties, List<String> required) {
        return CanonicalJson.serializeInOrder(objectProperty(properties, required), false);
    }

    private static Map<String, Object> objectProperty(Map<String, Object> properties, List<String> required) {
        Map<String, Object> schema = new Map<String, Object>{ 'type' => 'object', 'properties' => properties, 'additionalProperties' => false };
        if (!required.isEmpty()) {
            schema.put('required', required);
        }
        return schema;
    }

    /**
     * The values the agent may set on a picklist field: the values of the
     * chosen record type when there is one, else every active value. If the
     * record type's values cannot be read, every active value is used.
     */
    public static List<String> picklistValues(Schema.SObjectType objectType, Schema.RecordTypeInfo recordType, Schema.DescribeFieldResult field) {
        if (recordType != null) {
            List<String> scoped = valuesForRecordType(objectType, recordType.getRecordTypeId()).get(field.getName().toLowerCase());
            if (scoped != null) {
                return scoped;
            }
        }
        List<String> values = new List<String>();
        for (Schema.PicklistEntry entry : field.getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    private static Map<String, List<String>> valuesForRecordType(Schema.SObjectType objectType, Id recordTypeId) {
        String objectApiName = objectType.getDescribe().getName();
        String key = objectApiName.toLowerCase() + '|' + String.valueOf(recordTypeId);
        if (!recordTypeValues.containsKey(key)) {
            Map<String, List<String>> byField = new Map<String, List<String>>();
            try {
                ConnectApi.PicklistValuesCollection collection = ConnectApi.RecordUi.getPicklistValuesByRecordType(objectApiName, String.valueOf(recordTypeId));
                for (String fieldName : collection.picklistFieldValues.keySet()) {
                    List<String> values = new List<String>();
                    for (ConnectApi.PicklistValue entry : collection.picklistFieldValues.get(fieldName).values) {
                        values.add(entry.value);
                    }
                    byField.put(fieldName.toLowerCase(), values);
                }
            } catch (Exception unavailable) {
                // Every active value is offered instead, as for a tool without a record type.
                byField.clear();
            }
            recordTypeValues.put(key, byField);
        }
        return recordTypeValues.get(key);
    }

    /**
     * A field's JSON type with what Salesforce says about its values: its
     * length, its format, the picklist values the agent may set, and for a
     * lookup the object it points to, so the model sends a value the save
     * accepts.
     */
    private static Map<String, Object> fieldProperty(
        Schema.DescribeFieldResult field,
        String description,
        Schema.SObjectType objectType,
        Schema.RecordTypeInfo recordType
    ) {
        Map<String, Object> property = new Map<String, Object>();
        Schema.DisplayType fieldType = field.getType();
        if (fieldType == Schema.DisplayType.BOOLEAN) {
            property.put('type', 'boolean');
        } else if (fieldType == Schema.DisplayType.INTEGER) {
            property.put('type', 'integer');
        } else if (
            fieldType == Schema.DisplayType.DOUBLE ||
            fieldType == Schema.DisplayType.CURRENCY ||
            fieldType == Schema.DisplayType.PERCENT ||
            fieldType == Schema.DisplayType.LONG
        ) {
            property.put('type', 'number');
        } else {
            property.put('type', 'string');
            if (fieldType == Schema.DisplayType.REFERENCE || fieldType == Schema.DisplayType.ID) {
                property.put('format', 'salesforce-id');
                description += referenceHint(field, objectType);
            } else if (fieldType == Schema.DisplayType.DATE) {
                property.put('format', 'date');
            } else if (fieldType == Schema.DisplayType.DATETIME) {
                property.put('format', 'date-time');
            } else if (fieldType == Schema.DisplayType.PICKLIST) {
                List<String> values = picklistValues(objectType, recordType, field);
                // A partial list would forbid valid values, so a long list is left to the platform's picklist check.
                if (!values.isEmpty() && values.size() <= MAX_ENUM_VALUES) {
                    property.put('enum', values);
                }
            } else if (fieldType == Schema.DisplayType.MULTIPICKLIST) {
                description += ' Separate several values with a semicolon, such as A;B.';
            } else if (fieldType == Schema.DisplayType.EMAIL) {
                property.put('format', 'email');
            } else if (fieldType == Schema.DisplayType.URL) {
                property.put('format', 'uri');
            }
            if (TEXT_TYPES.contains(fieldType) && field.getLength() > 0) {
                property.put('maxLength', field.getLength());
            }
        }
        property.put('description', description);
        return property;
    }

    /** Names the object a lookup points to, so the model fetches the right kind of record's Id. */
    private static String referenceHint(Schema.DescribeFieldResult field, Schema.SObjectType objectType) {
        List<String> labels = new List<String>();
        List<Schema.SObjectType> targets = field.getType() == Schema.DisplayType.ID ? new List<Schema.SObjectType>{ objectType } : field.getReferenceTo();
        for (Schema.SObjectType target : targets == null ? new List<Schema.SObjectType>() : targets) {
            if (target != null) {
                labels.add(target.getDescribe().getLabel());
            }
        }
        if (labels.isEmpty() || labels.size() > MAX_NAMED_TARGETS) {
            return ' A Salesforce record Id.';
        }
        String last = labels.remove(labels.size() - 1);
        String listed = labels.isEmpty() ? last : String.join(labels, ', ') + (labels.size() == 1 ? ' or ' : ', or ') + last;
        return ' The Id of ' + (startsWithVowel(listed) ? 'an ' : 'a ') + listed + ' record.';
    }

    private static Boolean startsWithVowel(String value) {
        return 'aeiou'.contains(value.left(1).toLowerCase());
    }
}
