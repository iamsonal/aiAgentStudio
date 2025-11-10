/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SchemaBuilder provides a fluent API for building JSON Schemas (Draft 7) and field descriptors
 * for agent action configuration. It generates both the schema for Monaco editor validation
 * and field descriptors for dynamic form UI generation.
 *
 * Usage:
 * SchemaBuilder builder = SchemaBuilder.create()
 *     .addStringField('apiKey')
 *         .label('API Key')
 *         .required()
 *         .sensitive()
 *         .helpText('Your API key for authentication')
 *     .addStringField('endpoint')
 *         .label('API Endpoint')
 *         .placeholder('https://api.example.com')
 *     .addNumberField('retryAttempts')
 *         .label('Retry Attempts')
 *         .min(1).max(5)
 *         .defaultValue('3');
 *
 * String jsonSchema = builder.buildJsonSchema();
 * List<FieldDescriptor> fields = builder.buildFieldDescriptors();
 */
public class SchemaBuilder {
    private List<FieldBuilder> fields;
    private String schemaTitle;
    private String schemaDescription;

    /**
     * Private constructor - use create() instead
     */
    private SchemaBuilder() {
        this.fields = new List<FieldBuilder>();
        this.schemaTitle = '';
        this.schemaDescription = '';
    }

    /**
     * Creates a new SchemaBuilder instance
     */
    public static SchemaBuilder create() {
        return new SchemaBuilder();
    }

    /**
     * Sets the schema title
     */
    public SchemaBuilder title(String title) {
        this.schemaTitle = title;
        return this;
    }

    /**
     * Sets the schema description
     */
    public SchemaBuilder description(String description) {
        this.schemaDescription = description;
        return this;
    }

    /**
     * Adds a string field to the schema
     */
    public FieldBuilder addStringField(String name) {
        FieldBuilder fb = new FieldBuilder(this, name, 'string', '');
        this.fields.add(fb);
        return fb;
    }

    /**
     * Adds a number field to the schema
     */
    public FieldBuilder addNumberField(String name) {
        FieldBuilder fb = new FieldBuilder(this, name, 'number', '');
        this.fields.add(fb);
        return fb;
    }

    /**
     * Adds an integer field to the schema
     */
    public FieldBuilder addIntegerField(String name) {
        FieldBuilder fb = new FieldBuilder(this, name, 'integer', '');
        this.fields.add(fb);
        return fb;
    }

    /**
     * Adds a boolean field to the schema
     */
    public FieldBuilder addBooleanField(String name) {
        FieldBuilder fb = new FieldBuilder(this, name, 'boolean', '');
        this.fields.add(fb);
        return fb;
    }

    /**
     * Adds an array field to the schema
     */
    public FieldBuilder addArrayField(String name) {
        FieldBuilder fb = new FieldBuilder(this, name, 'array', '');
        this.fields.add(fb);
        return fb;
    }

    /**
     * Adds an object field to the schema
     */
    public FieldBuilder addObjectField(String name) {
        FieldBuilder fb = new FieldBuilder(this, name, 'object', '');
        this.fields.add(fb);
        return fb;
    }

    /**
     * Adds a date field to the schema
     */
    public FieldBuilder addDateField(String name) {
        FieldBuilder fb = new FieldBuilder(this, name, 'string', 'date');
        this.fields.add(fb);
        return fb;
    }

    /**
     * Adds a datetime field to the schema
     */
    public FieldBuilder addDateTimeField(String name) {
        FieldBuilder fb = new FieldBuilder(this, name, 'string', 'date-time');
        this.fields.add(fb);
        return fb;
    }

    /**
     * Adds a Salesforce ID field to the schema
     */
    public FieldBuilder addSalesforceIdField(String name) {
        FieldBuilder fb = new FieldBuilder(this, name, 'string', 'salesforce-id');
        this.fields.add(fb);
        return fb;
    }

    /**
     * Builds the JSON Schema string
     */
    public String buildJsonSchema() {
        Map<String, Object> schema = new Map<String, Object>{
            '$schema' => 'http://json-schema.org/draft-07/schema#',
            'type' => 'object',
            'properties' => new Map<String, Object>(),
            'required' => new List<String>()
        };

        if (String.isNotBlank(this.schemaTitle)) {
            schema.put('title', this.schemaTitle);
        }

        if (String.isNotBlank(this.schemaDescription)) {
            schema.put('description', this.schemaDescription);
        }

        Map<String, Object> properties = (Map<String, Object>) schema.get('properties');
        List<String> required = (List<String>) schema.get('required');

        for (FieldBuilder fb : this.fields) {
            properties.put(fb.name, fb.buildSchemaProperty());
            if (fb.isRequired) {
                required.add(fb.name);
            }
        }

        if (required.isEmpty()) {
            schema.remove('required');
        }

        return JSON.serialize(schema);
    }

    /**
     * Builds the list of FieldDescriptor objects
     */
    public List<FieldDescriptor> buildFieldDescriptors() {
        List<FieldDescriptor> descriptors = new List<FieldDescriptor>();
        Integer displayOrder = 0;

        for (FieldBuilder fb : this.fields) {
            descriptors.add(fb.buildFieldDescriptor(displayOrder++));
        }

        return descriptors;
    }

    /**
     * Inner class for building individual fields
     */
    public class FieldBuilder {
        private SchemaBuilder parent;
        private String name;
        private String fieldType;
        private String format;
        private String labelText;
        private String helpTextValue;
        private String placeholderText;
        private Boolean isRequired;
        private String defaultVal;
        private Decimal minVal;
        private Decimal maxVal;
        private Integer minLen;
        private Integer maxLen;
        private String patternValue;
        private List<String> enumValues;
        private String sObjectTypeValue;
        private Boolean isSensitive;
        private List<FieldDescriptor> nested;

        private FieldBuilder(SchemaBuilder parent, String name, String fieldType, String format) {
            this.parent = parent;
            this.name = name;
            this.fieldType = fieldType;
            this.format = format;
            this.labelText = name;
            this.helpTextValue = '';
            this.placeholderText = '';
            this.isRequired = false;
            this.isSensitive = false;
            this.enumValues = new List<String>();
            this.nested = new List<FieldDescriptor>();
        }

        /**
         * Constructor for creating FieldBuilder without parent (used by fromDescriptors)
         */
        private FieldBuilder(String name, String fieldType) {
            this.parent = null;
            this.name = name;
            this.fieldType = fieldType;
            this.format = '';
            this.labelText = name;
            this.helpTextValue = '';
            this.placeholderText = '';
            this.isRequired = false;
            this.isSensitive = false;
            this.enumValues = new List<String>();
            this.nested = new List<FieldDescriptor>();
        }

        /**
         * Sets the field label
         */
        public FieldBuilder label(String label) {
            this.labelText = label;
            return this;
        }

        /**
         * Sets the help text
         */
        public FieldBuilder helpText(String helpText) {
            this.helpTextValue = helpText;
            return this;
        }

        /**
         * Sets the placeholder
         */
        public FieldBuilder placeholder(String placeholder) {
            this.placeholderText = placeholder;
            return this;
        }

        /**
         * Marks the field as required
         */
        public FieldBuilder required() {
            this.isRequired = true;
            return this;
        }

        /**
         * Sets the default value
         */
        public FieldBuilder defaultValue(String defaultValue) {
            this.defaultVal = defaultValue;
            return this;
        }

        /**
         * Sets minimum value (for numbers)
         */
        public FieldBuilder min(Decimal minValue) {
            this.minVal = minValue;
            return this;
        }

        /**
         * Sets maximum value (for numbers)
         */
        public FieldBuilder max(Decimal maxValue) {
            this.maxVal = maxValue;
            return this;
        }

        /**
         * Sets minimum length (for strings)
         */
        public FieldBuilder minLength(Integer minLength) {
            this.minLen = minLength;
            return this;
        }

        /**
         * Sets maximum length (for strings)
         */
        public FieldBuilder maxLength(Integer maxLength) {
            this.maxLen = maxLength;
            return this;
        }

        /**
         * Sets regex pattern (for strings)
         */
        public FieldBuilder pattern(String pattern) {
            this.patternValue = pattern;
            return this;
        }

        /**
         * Sets allowed values (for picklists/enums)
         */
        public FieldBuilder enumValues(List<String> values) {
            this.enumValues = values;
            return this;
        }

        /**
         * Sets SObject type (for reference fields)
         */
        public FieldBuilder sObjectType(String sObjectType) {
            this.sObjectTypeValue = sObjectType;
            return this;
        }

        /**
         * Marks field as sensitive
         */
        public FieldBuilder sensitive() {
            this.isSensitive = true;
            return this;
        }

        /**
         * Sets nested fields (for objects/arrays)
         */
        public FieldBuilder nestedFields(List<FieldDescriptor> nestedFields) {
            this.nested = nestedFields;
            return this;
        }

        /**
         * Returns to the parent SchemaBuilder to add more fields
         */
        public SchemaBuilder done() {
            return this.parent;
        }

        /**
         * Adds another string field
         */
        public FieldBuilder addStringField(String name) {
            return this.parent.addStringField(name);
        }

        /**
         * Adds another number field
         */
        public FieldBuilder addNumberField(String name) {
            return this.parent.addNumberField(name);
        }

        /**
         * Adds another integer field
         */
        public FieldBuilder addIntegerField(String name) {
            return this.parent.addIntegerField(name);
        }

        /**
         * Adds another boolean field
         */
        public FieldBuilder addBooleanField(String name) {
            return this.parent.addBooleanField(name);
        }

        /**
         * Adds another date field
         */
        public FieldBuilder addDateField(String name) {
            return this.parent.addDateField(name);
        }

        /**
         * Adds another datetime field
         */
        public FieldBuilder addDateTimeField(String name) {
            return this.parent.addDateTimeField(name);
        }

        /**
         * Adds another Salesforce ID field
         */
        public FieldBuilder addSalesforceIdField(String name) {
            return this.parent.addSalesforceIdField(name);
        }

        /**
         * Builds the JSON Schema property
         */
        private Map<String, Object> buildSchemaProperty() {
            Map<String, Object> prop = new Map<String, Object>{ 'type' => this.fieldType };

            if (String.isNotBlank(this.helpTextValue)) {
                prop.put('description', this.helpTextValue);
            }

            if (String.isNotBlank(this.format)) {
                prop.put('format', this.format);
            }

            if (String.isNotBlank(this.defaultVal)) {
                // Parse default value to correct type for JSON Schema
                prop.put('default', parseDefaultValue(this.defaultVal, this.fieldType));
            }

            if (this.minVal != null) {
                prop.put('minimum', this.minVal);
            }

            if (this.maxVal != null) {
                prop.put('maximum', this.maxVal);
            }

            if (this.minLen != null) {
                prop.put('minLength', this.minLen);
            }

            if (this.maxLen != null) {
                prop.put('maxLength', this.maxLen);
            }

            if (String.isNotBlank(this.patternValue)) {
                prop.put('pattern', this.patternValue);
            }

            if (!this.enumValues.isEmpty()) {
                prop.put('enum', this.enumValues);
            }

            if (String.isNotBlank(this.sObjectTypeValue)) {
                prop.put('sObjectType', this.sObjectTypeValue);
            }

            return prop;
        }

        /**
         * Builds the FieldDescriptor
         */
        private FieldDescriptor buildFieldDescriptor(Integer displayOrder) {
            FieldDescriptor fd = new FieldDescriptor();
            fd.name = this.name;
            fd.fieldType = this.fieldType;
            fd.label = this.labelText;
            fd.helpText = this.helpTextValue;
            fd.placeholder = this.placeholderText;
            fd.required = this.isRequired;
            fd.defaultValue = this.defaultVal;
            fd.format = this.format;
            fd.minValue = this.minVal;
            fd.maxValue = this.maxVal;
            fd.minLength = this.minLen;
            fd.maxLength = this.maxLen;
            fd.pattern = this.patternValue;
            fd.picklistValues = this.enumValues;
            fd.sObjectType = this.sObjectTypeValue;
            fd.sensitive = this.isSensitive;
            fd.nestedFields = this.nested;
            fd.displayOrder = displayOrder;

            return fd;
        }

        /**
         * Parses default value to the correct type for JSON Schema
         */
        private Object parseDefaultValue(String value, String fieldType) {
            if (String.isBlank(value)) {
                return null;
            }

            try {
                if (fieldType == 'integer') {
                    return Integer.valueOf(value);
                } else if (fieldType == 'number') {
                    return Decimal.valueOf(value);
                } else if (fieldType == 'boolean') {
                    return Boolean.valueOf(value);
                } else {
                    return value; // string, array, object - keep as string
                }
            } catch (Exception e) {
                // If parsing fails, return as string
                System.debug(LoggingLevel.WARN, 'Could not parse default value "' + value + '" as ' + fieldType + ': ' + e.getMessage());
                return value;
            }
        }
    }

    /**
     * Creates a SchemaBuilder from existing FieldDescriptors.
     * This enables DTOs to define their schema once and reuse it.
     *
     * @param descriptors List of FieldDescriptor objects
     * @return SchemaBuilder populated with the descriptors
     */
    public static SchemaBuilder fromDescriptors(List<FieldDescriptor> descriptors) {
        SchemaBuilder builder = new SchemaBuilder();

        if (descriptors == null || descriptors.isEmpty()) {
            return builder;
        }

        for (FieldDescriptor fd : descriptors) {
            FieldBuilder fb = new FieldBuilder(fd.name, fd.fieldType);
            fb.labelText = fd.label;
            fb.helpTextValue = fd.helpText;
            fb.placeholderText = fd.placeholder;
            fb.isRequired = fd.required;
            fb.defaultVal = fd.defaultValue;
            fb.format = fd.format;
            fb.minVal = fd.minValue;
            fb.maxVal = fd.maxValue;
            fb.minLen = fd.minLength;
            fb.maxLen = fd.maxLength;
            fb.patternValue = fd.pattern;
            fb.enumValues = fd.picklistValues;
            fb.sObjectTypeValue = fd.sObjectType;
            fb.isSensitive = fd.sensitive;
            fb.nested = fd.nestedFields;

            builder.fields.add(fb);
        }

        return builder;
    }
}
