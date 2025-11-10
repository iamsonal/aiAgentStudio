/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionDescription is a DTO that provides comprehensive metadata about an agent action.
 * It contains JSON Schemas for configuration and parameters, as well as UI field descriptors
 * for dynamic form generation.
 *
 * This class enables self-describing actions where the action class itself is the single
 * source of truth for its configuration requirements.
 */
public class ActionDescription {
    /**
     * Human-readable label for the action
     */
    @AuraEnabled
    public String label { get; set; }

    /**
     * Detailed description of what the action does
     */
    @AuraEnabled
    public String description { get; set; }

    /**
     * JSON Schema (Draft 7) for backend configuration (BackendConfiguration__c field)
     * Used for Monaco editor IntelliSense and validation
     */
    @AuraEnabled
    public String configJsonSchema { get; set; }

    /**
     * Field descriptors for backend configuration - used for dynamic form UI generation
     */
    @AuraEnabled
    public List<FieldDescriptor> configFields { get; set; }

    /**
     * JSON Schema (Draft 7) for parameters (Parameters__c field)
     * Used for Monaco editor IntelliSense and validation
     */
    @AuraEnabled
    public String parametersJsonSchema { get; set; }

    /**
     * Field descriptors for parameters - used for dynamic form UI generation
     */
    @AuraEnabled
    public List<FieldDescriptor> parameterFields { get; set; }

    /**
     * Indicates whether this action requires SObject selection
     */
    @AuraEnabled
    public Boolean requiresSObject { get; set; }

    /**
     * Optional guidance HTML to display in the UI
     */
    @AuraEnabled
    public String guidanceHtml { get; set; }

    /**
     * Constructor with default values
     */
    public ActionDescription() {
        this.label = '';
        this.description = '';
        this.configJsonSchema = '{}';
        this.configFields = new List<FieldDescriptor>();
        this.parametersJsonSchema = '{}';
        this.parameterFields = new List<FieldDescriptor>();
        this.requiresSObject = false;
        this.guidanceHtml = '';
    }

    /**
     * Fluent API for setting label
     */
    public ActionDescription setLabel(String label) {
        this.label = label;
        return this;
    }

    /**
     * Fluent API for setting description
     */
    public ActionDescription setDescription(String description) {
        this.description = description;
        return this;
    }

    /**
     * Fluent API for setting config JSON schema
     */
    public ActionDescription setConfigJsonSchema(String schema) {
        this.configJsonSchema = schema;
        return this;
    }

    /**
     * Fluent API for setting config fields
     */
    public ActionDescription setConfigFields(List<FieldDescriptor> fields) {
        this.configFields = fields;
        return this;
    }

    /**
     * Fluent API for setting parameters JSON schema
     */
    public ActionDescription setParametersJsonSchema(String schema) {
        this.parametersJsonSchema = schema;
        return this;
    }

    /**
     * Fluent API for setting parameter fields
     */
    public ActionDescription setParameterFields(List<FieldDescriptor> fields) {
        this.parameterFields = fields;
        return this;
    }

    /**
     * Fluent API for setting requiresSObject flag
     */
    public ActionDescription setRequiresSObject(Boolean required) {
        this.requiresSObject = required;
        return this;
    }

    /**
     * Fluent API for setting guidance HTML
     */
    public ActionDescription setGuidanceHtml(String html) {
        this.guidanceHtml = html;
        return this;
    }
}
