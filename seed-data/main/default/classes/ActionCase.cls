/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionCase is an object-centric action class containing Case-related query operations.
 * Follows the object-centric pattern to consolidate related queries in a single class.
 *
 * Supported Operations:
 *   - GET_BY_ID: Get a specific case by Salesforce ID
 *
 * @extends BaseAgentAction
 */
public class ActionCase extends BaseAgentAction {
    private static final Integer DEFAULT_MAX_RESULTS = 25;
    private static final Integer ABSOLUTE_MAX_RESULTS = 100;

    // Operation constants - SINGLE SOURCE OF TRUTH
    private static final String OP_GET_BY_ID = 'GET_BY_ID';

    private ConfigDTO config;

    /**
     * DTO for backend configuration
     */
    public class ConfigDTO {
        public String operation;
        public List<String> defaultFields;
        public Integer maxResults;
    }

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        public String caseId;
    }

    /**
     * Returns field descriptors for ConfigDTO
     */
    private static List<FieldDescriptor> describeConfig() {
        return new List<FieldDescriptor>{
            FieldDescriptor.string('operation')
                .required()
                .help('The query operation to perform')
                .options(getAllOperations()),
            FieldDescriptor.integer('maxResults')
                .help('Maximum number of records to return (default: 25, max: 100)')
                .defaultTo(25)
                .range(1, 100)
        };
    }

    /**
     * Returns field descriptors for ArgumentsDTO
     */
    private static List<FieldDescriptor> describeArguments() {
        return new List<FieldDescriptor>{
            FieldDescriptor.salesforceId('caseId')
                .required()
                .help('The Salesforce ID of the case to retrieve')
                .setPlaceholder('500000000000000AAA')
        };
    }

    @TestVisible
    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        if (String.isBlank(actionConfigurationJson)) {
            throw new ValidationException('Backend configuration is required for ActionCase', null);
        }

        try {
            Map<String, Object> configMap = (Map<String, Object>) JSON.deserializeUntyped(actionConfigurationJson);

            this.config = new ConfigDTO();
            this.config.operation = (String) configMap.get('operation');
            this.config.defaultFields = ActionConfigUtils.getOptionalStringList(configMap, 'defaultFields');
            this.config.maxResults = configMap.get('maxResults') != null ? Integer.valueOf(configMap.get('maxResults')) : DEFAULT_MAX_RESULTS;

            this.config.maxResults = Math.min(this.config.maxResults, ABSOLUTE_MAX_RESULTS);
        } catch (Exception e) {
            throw new ValidationException('Invalid backend configuration JSON: ' + e.getMessage(), e);
        }

        if (String.isBlank(this.config.operation)) {
            throw new ValidationException('operation is required in backend configuration. Example: {"operation": "GET_BY_ID"}', 'operation');
        }

        System.debug(LoggingLevel.INFO, logPrefix + 'Configured ActionCase with operation: ' + this.config.operation);
    }

    public override ActionOutcome executeAction(Map<String, Object> params) {
        // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
        ArgumentsDTO args = new ArgumentsDTO();
        args.caseId = (String) params.get('caseId');

        if (this.config.operation == OP_GET_BY_ID) {
            return getById(args);
        } else {
            return ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_CONFIG_ERROR,
                'Unknown operation: ' + this.config.operation + '. Valid operations: ' + String.join(getAllOperations(), ', ')
            );
        }
    }

    /**
     * @description
     * Returns all supported operations for this action.
     * Single source of truth for operation names.
     */
    private static List<String> getAllOperations() {
        return new List<String>{
            OP_GET_BY_ID
        };
    }

    private ActionOutcome getById(ArgumentsDTO args) {
        if (String.isBlank(args.caseId)) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'caseId is required for GET_BY_ID operation');
        }

        try {
            List<Case> results = [
                SELECT Id, CaseNumber, Subject, Description, Status, Priority, CreatedDate, AccountId, ContactId, Origin, Type
                FROM Case
                WHERE Id = :args.caseId
                WITH USER_MODE
                LIMIT 1
            ];

            if (results.isEmpty()) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, 'Case not found with ID: ' + args.caseId);
            }

            return ActionOutcome.success(new Map<String, Object>{ 'record' => results[0], 'message' => 'Found case: ' + results[0].CaseNumber });
        } catch (System.QueryException qEx) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to query case: ' + qEx.getMessage());
        }
    }

    /**
     * @description
     * Provides self-description with JSON schemas and field descriptors for dynamic UI generation.
     * Uses AutoDescriptor for simplified schema generation from DTO metadata.
     *
     * @return ActionDescription with complete configuration and parameter schemas
     */
    public override ActionDescription describe() {
        return new AutoDescriptor()
            .loadFromMetadata('ActionCase')  // Loads label, description, guidance from metadata
            .setConfigFields(describeConfig())
            .setParameterFields(describeArguments())
            .toActionDescription();
    }
}
