/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * FieldDescriptor provides rich metadata about a single field in an action's configuration or parameters.
 * Used for dynamic form generation in the LWC configurator.
 */
public class FieldDescriptor {
    /**
     * Field name (property key in JSON)
     */
    @AuraEnabled
    public String name { get; set; }

    /**
     * Field type: string, number, integer, boolean, array, object, date, datetime
     */
    @AuraEnabled
    public String fieldType { get; set; }

    /**
     * Format for string types: date, date-time, salesforce-id, email, url, etc.
     */
    @AuraEnabled
    public String format { get; set; }

    /**
     * Human-readable label for the field
     */
    @AuraEnabled
    public String label { get; set; }

    /**
     * Description/help text for the field
     */
    @AuraEnabled
    public String helpText { get; set; }

    /**
     * Placeholder text for input fields
     */
    @AuraEnabled
    public String placeholder { get; set; }

    /**
     * Whether the field is required
     */
    @AuraEnabled
    public Boolean required { get; set; }

    /**
     * Default value (as string, will be parsed based on type)
     */
    @AuraEnabled
    public String defaultValue { get; set; }

    /**
     * For number/integer types: minimum value
     */
    @AuraEnabled
    public Decimal minValue { get; set; }

    /**
     * For number/integer types: maximum value
     */
    @AuraEnabled
    public Decimal maxValue { get; set; }

    /**
     * For string types: minimum length
     */
    @AuraEnabled
    public Integer minLength { get; set; }

    /**
     * For string types: maximum length
     */
    @AuraEnabled
    public Integer maxLength { get; set; }

    /**
     * For string types: regex pattern for validation
     */
    @AuraEnabled
    public String pattern { get; set; }

    /**
     * For picklist types: list of allowed values
     */
    @AuraEnabled
    public List<String> picklistValues { get; set; }

    /**
     * For reference fields: the SObject API name being referenced
     */
    @AuraEnabled
    public String sObjectType { get; set; }

    /**
     * Whether the field is sensitive (should be masked in UI)
     */
    @AuraEnabled
    public Boolean sensitive { get; set; }

    /**
     * For object/array types: nested field descriptors
     */
    @AuraEnabled
    public List<FieldDescriptor> nestedFields { get; set; }

    /**
     * Display order in the form (lower numbers first)
     */
    @AuraEnabled
    public Integer displayOrder { get; set; }

    /**
     * Default constructor
     */
    public FieldDescriptor() {
        this.name = '';
        this.fieldType = 'string';
        this.format = '';
        this.label = '';
        this.helpText = '';
        this.placeholder = '';
        this.required = false;
        this.defaultValue = null;
        this.sensitive = false;
        this.nestedFields = new List<FieldDescriptor>();
        this.picklistValues = new List<String>();
        this.displayOrder = 0;
    }

    /**
     * Constructor with name and type
     */
    public FieldDescriptor(String name, String fieldType) {
        this.name = name;
        this.fieldType = fieldType;
        this.format = '';
        this.label = name;
        this.helpText = '';
        this.placeholder = '';
        this.required = false;
        this.defaultValue = null;
        this.sensitive = false;
        this.nestedFields = new List<FieldDescriptor>();
        this.picklistValues = new List<String>();
        this.displayOrder = 0;
    }

    /**
     * Fluent API for setting label
     */
    public FieldDescriptor setLabel(String label) {
        this.label = label;
        return this;
    }

    /**
     * Fluent API for setting help text
     */
    public FieldDescriptor setHelpText(String helpText) {
        this.helpText = helpText;
        return this;
    }

    /**
     * Fluent API for setting placeholder
     */
    public FieldDescriptor setPlaceholder(String placeholder) {
        this.placeholder = placeholder;
        return this;
    }

    /**
     * Fluent API for marking as required
     */
    public FieldDescriptor setRequired(Boolean required) {
        this.required = required;
        return this;
    }

    /**
     * Fluent API for setting default value
     */
    public FieldDescriptor setDefaultValue(String defaultValue) {
        this.defaultValue = defaultValue;
        return this;
    }

    /**
     * Fluent API for setting format
     */
    public FieldDescriptor setFormat(String format) {
        this.format = format;
        return this;
    }

    /**
     * Fluent API for setting as sensitive
     */
    public FieldDescriptor setSensitive(Boolean sensitive) {
        this.sensitive = sensitive;
        return this;
    }

    /**
     * Fluent API for setting min value
     */
    public FieldDescriptor setMinValue(Decimal minValue) {
        this.minValue = minValue;
        return this;
    }

    /**
     * Fluent API for setting max value
     */
    public FieldDescriptor setMaxValue(Decimal maxValue) {
        this.maxValue = maxValue;
        return this;
    }

    /**
     * Fluent API for setting min length
     */
    public FieldDescriptor setMinLength(Integer minLength) {
        this.minLength = minLength;
        return this;
    }

    /**
     * Fluent API for setting max length
     */
    public FieldDescriptor setMaxLength(Integer maxLength) {
        this.maxLength = maxLength;
        return this;
    }

    /**
     * Fluent API for setting pattern
     */
    public FieldDescriptor setPattern(String pattern) {
        this.pattern = pattern;
        return this;
    }

    /**
     * Fluent API for setting picklist values
     */
    public FieldDescriptor setPicklistValues(List<String> values) {
        this.picklistValues = values;
        return this;
    }

    /**
     * Fluent API for setting sObject type
     */
    public FieldDescriptor setSObjectType(String sObjectType) {
        this.sObjectType = sObjectType;
        return this;
    }

    /**
     * Fluent API for setting nested fields
     */
    public FieldDescriptor setNestedFields(List<FieldDescriptor> nestedFields) {
        this.nestedFields = nestedFields;
        return this;
    }

    /**
     * Fluent API for setting display order
     */
    public FieldDescriptor setDisplayOrder(Integer order) {
        this.displayOrder = order;
        return this;
    }

    // ========== Static Factory Methods ==========

    /**
     * Creates a string field descriptor
     */
    public static FieldDescriptor string(String name) {
        FieldDescriptor fd = new FieldDescriptor();
        fd.name = name;
        fd.fieldType = 'string';
        fd.label = autoLabel(name);
        return fd;
    }

    /**
     * Creates an integer field descriptor
     */
    public static FieldDescriptor integer(String name) {
        FieldDescriptor fd = new FieldDescriptor();
        fd.name = name;
        fd.fieldType = 'integer';
        fd.label = autoLabel(name);
        return fd;
    }

    /**
     * Creates a number field descriptor
     */
    public static FieldDescriptor number(String name) {
        FieldDescriptor fd = new FieldDescriptor();
        fd.name = name;
        fd.fieldType = 'number';
        fd.label = autoLabel(name);
        return fd;
    }

    /**
     * Creates a boolean field descriptor
     */
    public static FieldDescriptor boolean(String name) {
        FieldDescriptor fd = new FieldDescriptor();
        fd.name = name;
        fd.fieldType = 'boolean';
        fd.label = autoLabel(name);
        return fd;
    }

    /**
     * Creates a Salesforce ID field descriptor
     */
    public static FieldDescriptor salesforceId(String name) {
        FieldDescriptor fd = new FieldDescriptor();
        fd.name = name;
        fd.fieldType = 'string';
        fd.format = 'salesforce-id';
        fd.label = autoLabel(name);
        return fd;
    }

    /**
     * Creates an object field descriptor
     */
    public static FieldDescriptor object(String name) {
        FieldDescriptor fd = new FieldDescriptor();
        fd.name = name;
        fd.fieldType = 'object';
        fd.label = autoLabel(name);
        return fd;
    }

    /**
     * Creates an array field descriptor
     */
    public static FieldDescriptor array(String name) {
        FieldDescriptor fd = new FieldDescriptor();
        fd.name = name;
        fd.fieldType = 'array';
        fd.label = autoLabel(name);
        return fd;
    }

    // ========== Convenience Methods for Fluent Chaining ==========

    /**
     * Marks field as required (convenience shorthand)
     */
    public FieldDescriptor required() {
        this.required = true;
        return this;
    }

    /**
     * Sets help text (convenience shorthand)
     */
    public FieldDescriptor help(String helpText) {
        this.helpText = helpText;
        return this;
    }

    /**
     * Sets default value (convenience shorthand)
     */
    public FieldDescriptor defaultTo(Object defaultValue) {
        this.defaultValue = String.valueOf(defaultValue);
        return this;
    }

    /**
     * Sets picklist options (convenience shorthand)
     */
    public FieldDescriptor options(List<String> values) {
        this.picklistValues = values;
        return this;
    }

    /**
     * Sets min/max range (convenience shorthand)
     */
    public FieldDescriptor range(Decimal min, Decimal max) {
        this.minValue = min;
        this.maxValue = max;
        return this;
    }

    /**
     * Sets min length (convenience shorthand)
     */
    public FieldDescriptor minLength(Integer minLength) {
        this.minLength = minLength;
        return this;
    }

    /**
     * Sets max length (convenience shorthand)
     */
    public FieldDescriptor maxLength(Integer maxLength) {
        this.maxLength = maxLength;
        return this;
    }

    /**
     * Sets pattern (convenience shorthand)
     */
    public FieldDescriptor pattern(String pattern) {
        this.pattern = pattern;
        return this;
    }

    /**
     * Sets SObject type (convenience shorthand)
     */
    public FieldDescriptor sObject(String sObjectType) {
        this.sObjectType = sObjectType;
        return this;
    }

    /**
     * Sets nested fields (convenience shorthand)
     */
    public FieldDescriptor nested(List<FieldDescriptor> nestedFields) {
        this.nestedFields = nestedFields;
        return this;
    }

    // ========== Helper Methods ==========

    /**
     * Auto-generates a label from a field name
     */
    private static String autoLabel(String name) {
        if (String.isBlank(name))
            return '';
        String label = name.replace('_', ' ').replace('Id', ' ID');
        return label.substring(0, 1).toUpperCase() + label.substring(1);
    }
}
