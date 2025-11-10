/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * AutoDescriptor simplifies ActionDescription creation by auto-generating JSON Schemas
 * from FieldDescriptor lists and loading guidance from StandardActionHandler__mdt.
 *
 * This eliminates the need for manual SchemaBuilder usage and keeps guidance configurable
 * in metadata instead of hardcoded in classes.
 *
 * All action labels, descriptions, and guidance MUST be defined in StandardActionHandler__mdt
 * custom metadata records. Hardcoding these values is no longer supported.
 *
 * Usage Pattern:
 * 1. Create a StandardActionHandler__mdt record for your action class
 * 2. DTOs define static describe() methods that return List<FieldDescriptor>
 * 3. Actions call new AutoDescriptor().loadFromMetadata() to load from metadata
 * 4. Field descriptors and JSON Schemas are set via method chaining
 *
 * Example:
 *
 * public override ActionDescription describe() {
 *     return new AutoDescriptor()
 *         .loadFromMetadata('ActionCreateRecord') // Required - loads from StandardActionHandler__mdt
 *         .setConfigFields(ConfigDTO.describe())
 *         .setParameterFields(ArgumentsDTO.describe())
 *         .toActionDescription();
 * }
 */
public class AutoDescriptor {
    private String label;
    private String description;
    private Boolean requiresSObject = false;
    private String guidanceHtml;
    private List<FieldDescriptor> configFields;
    private List<FieldDescriptor> parameterFields;

    /**
     * Constructor - creates a new AutoDescriptor builder
     */
    public AutoDescriptor() {
        // Default constructor
    }

    /**
     * Loads guidance metadata from StandardActionHandler__mdt based on handler class name
     * @param handlerClassName The fully qualified class name (e.g., 'ActionCreateRecord')
     * @return AutoDescriptor instance with metadata loaded
     * @throws IllegalArgumentException if metadata record is not found or inactive
     */
    public AutoDescriptor loadFromMetadata(String handlerClassName) {
        if (String.isBlank(handlerClassName)) {
            throw new IllegalArgumentException(
                '[AutoDescriptor] Handler class name cannot be blank. All actions must have a StandardActionHandler__mdt record.'
            );
        }

        try {
            // Query StandardActionHandler__mdt by HandlerClassName__c
            List<StandardActionHandler__mdt> handlers = [
                SELECT MasterLabel, Description__c, GuidanceText__c, RequiresSObject__c
                FROM StandardActionHandler__mdt
                WHERE HandlerClassName__c = :handlerClassName AND IsActive__c = TRUE
                LIMIT 1
            ];

            if (handlers.isEmpty()) {
                throw new IllegalArgumentException(
                    '[AutoDescriptor] No active StandardActionHandler__mdt record found for: ' +
                        handlerClassName +
                        '. Please create a metadata record with HandlerClassName__c = \'' +
                        handlerClassName +
                        '\' and IsActive__c = true.'
                );
            }

            StandardActionHandler__mdt handler = handlers[0];

            // Load metadata values
            this.label = handler.MasterLabel;
            this.description = handler.Description__c;
            this.guidanceHtml = handler.GuidanceText__c;
            if (handler.RequiresSObject__c != null) {
                this.requiresSObject = handler.RequiresSObject__c;
            }

            System.debug(LoggingLevel.FINE, '[AutoDescriptor] Successfully loaded metadata for ' + handlerClassName);
        } catch (QueryException e) {
            throw new IllegalArgumentException(
                '[AutoDescriptor] Error querying StandardActionHandler__mdt for ' + handlerClassName + ': ' + e.getMessage()
            );
        }

        return this;
    }

    /**
     * Sets whether the action requires an SObject
     * This can override the value from metadata if needed
     */
    public AutoDescriptor setRequiresSObject(Boolean requiresSObject) {
        this.requiresSObject = requiresSObject;
        return this;
    }

    /**
     * Sets configuration field descriptors
     */
    public AutoDescriptor setConfigFields(List<FieldDescriptor> fields) {
        this.configFields = fields;
        return this;
    }

    /**
     * Sets parameter field descriptors
     */
    public AutoDescriptor setParameterFields(List<FieldDescriptor> fields) {
        this.parameterFields = fields;
        return this;
    }

    /**
     * Builds the final ActionDescription with auto-generated JSON Schemas
     */
    public ActionDescription toActionDescription() {
        // Auto-generate JSON Schemas from FieldDescriptors
        String configSchema = '{"type": "object", "properties": {}}';
        String paramsSchema = '{"type": "object", "properties": {}}';

        if (this.configFields != null && !this.configFields.isEmpty()) {
            SchemaBuilder configBuilder = SchemaBuilder.fromDescriptors(this.configFields);
            configSchema = configBuilder.buildJsonSchema();
        }

        if (this.parameterFields != null && !this.parameterFields.isEmpty()) {
            SchemaBuilder paramsBuilder = SchemaBuilder.fromDescriptors(this.parameterFields);
            paramsSchema = paramsBuilder.buildJsonSchema();
        }

        return new ActionDescription()
            .setLabel(this.label)
            .setDescription(this.description)
            .setRequiresSObject(this.requiresSObject)
            .setGuidanceHtml(this.guidanceHtml)
            .setConfigFields(this.configFields != null ? this.configFields : new List<FieldDescriptor>())
            .setConfigJsonSchema(configSchema)
            .setParameterFields(this.parameterFields != null ? this.parameterFields : new List<FieldDescriptor>())
            .setParametersJsonSchema(paramsSchema);
    }
}
