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
 * Single implementation of executable Agent Core configuration rules.
 *
 * Runtime validation throws the first finding through AgentConfigService,
 * while the public preflight facade maps every finding into a stable report.
 */
public inherited sharing class AgentConfigurationValidator {
    public class Finding {
        public String code;
        public String path;
        public String message;

        private Finding(String code, String path, String message) {
            this.code = code;
            this.path = path;
            this.message = message;
        }
    }

    public static List<Finding> collectErrors(AgentDefinition__c definition, List<AgentTool__c> tools, List<AgentContextProvider__c> contextProviders) {
        List<Finding> findings = new List<Finding>();
        validateDefinition(definition, findings);
        validateTools(tools == null ? new List<AgentTool__c>() : tools, findings);
        validateContextProviders(contextProviders == null ? new List<AgentContextProvider__c>() : contextProviders, findings);
        return findings;
    }

    private static void validateDefinition(AgentDefinition__c definition, List<Finding> findings) {
        if (definition == null) {
            add(findings, 'DEFINITION_REQUIRED', 'AgentDefinition', 'An agent definition is required.');
            return;
        }
        required(findings, definition.Id != null, 'DEFINITION_NOT_PERSISTED', 'AgentDefinition.Id', 'A persisted agent definition is required.');
        required(
            findings,
            definition.IsActive__c == true,
            'DEFINITION_INACTIVE',
            'AgentDefinition.IsActive',
            'The definition must be active before it can run.'
        );
        required(
            findings,
            !String.isBlank(definition.DeveloperName__c),
            'DEVELOPER_NAME_REQUIRED',
            'AgentDefinition.DeveloperName',
            'Agent developer name is required.'
        );
        required(findings, !String.isBlank(definition.Instructions__c), 'INSTRUCTIONS_REQUIRED', 'AgentDefinition.Instructions', 'Instructions are required.');
        AgentModel__mdt model = AgentModelService.activeModel(definition.Model__c);
        if (model == null) {
            add(findings, 'MODEL_NOT_APPROVED', 'AgentDefinition.Model', AgentModelService.unavailableMessage(definition.Model__c));
        }
        wholeRange(findings, definition.MaxModelCalls__c, 1, 9999, 'MAX_MODEL_CALLS_INVALID', 'AgentDefinition.MaxModelCalls');
        wholeRange(findings, definition.MaxToolCalls__c, 0, 9999, 'MAX_TOOL_CALLS_INVALID', 'AgentDefinition.MaxToolCalls');
        optionalRange(
            findings,
            definition.MaxTotalTokens__c,
            AgentConfigService.MIN_TOTAL_TOKENS,
            AgentConfigService.MAX_TOTAL_TOKENS,
            'MAX_TOTAL_TOKENS_INVALID',
            'AgentDefinition.MaxTotalTokens'
        );
        optionalRange(
            findings,
            definition.MaxModelRequestCharacters__c,
            AgentConfigService.MIN_MODEL_REQUEST_CHARACTERS,
            AgentConfigService.MAX_MODEL_REQUEST_CHARACTERS,
            'MAX_MODEL_REQUEST_CHARACTERS_INVALID',
            'AgentDefinition.MaxModelRequestCharacters'
        );
        optionalRange(
            findings,
            definition.ModelTimeoutSeconds__c,
            AgentConfigService.MIN_MODEL_TIMEOUT_SECONDS,
            AgentConfigService.DEFAULT_MODEL_TIMEOUT_SECONDS,
            'MODEL_TIMEOUT_SECONDS_INVALID',
            'AgentDefinition.ModelTimeoutSeconds'
        );
        optionalRange(
            findings,
            definition.TranscriptTurnLimit__c,
            0,
            AgentConfigService.MAX_TRANSCRIPT_TURN_LIMIT,
            'TRANSCRIPT_TURN_LIMIT_INVALID',
            'AgentDefinition.TranscriptTurnLimit'
        );
        optionalRange(
            findings,
            definition.ReplyWindowHours__c,
            1,
            AgentConfigService.MAX_REPLY_WINDOW_HOURS,
            'REPLY_WINDOW_HOURS_INVALID',
            'AgentDefinition.ReplyWindowHours'
        );

        String identityError = AgentDefinitionIdentityRules.error(definition);
        if (identityError != null) {
            add(findings, 'EXECUTION_IDENTITY_INVALID', 'AgentDefinition.ExecutionIdentity', identityError);
        }
        try {
            AgentExecutionPolicyService.validate(AgentExecutionPolicyService.resolve(definition));
        } catch (Exception error) {
            add(findings, 'EXECUTION_POLICY_INVALID', 'AgentDefinition.ExecutionPolicy', safe(error.getMessage()));
        }
        try {
            ToolJsonSchemaValidator.validateSchema(definition.OutputSchema__c, 'Agent output schema');
        } catch (Exception error) {
            add(findings, 'OUTPUT_SCHEMA_INVALID', 'AgentDefinition.OutputSchema', safe(error.getMessage()));
        }
        try {
            AsyncJobCostService.Estimate asyncEstimate = AsyncJobCostService.estimate(definition);
            if (asyncEstimate.exceedsMaximumJobsPerRun) {
                add(
                    findings,
                    'ASYNC_JOB_BUDGET_EXCEEDS_SUPPORTED_MAXIMUM',
                    'AgentDefinition.AsyncJobBudget',
                    'Retry-free Queueable cost of ' +
                        asyncEstimate.retryFreeJobsPerRun +
                        ' jobs exceeds the supported per-run maximum of ' +
                        AsyncJobCostService.MAXIMUM_JOBS_PER_RUN +
                        '.'
                );
            }
        } catch (Exception invalidBudget) {
            // Field-level findings already describe invalid budget inputs.
        }
        if (model != null) {
            try {
                AgentConfigService.newModelProvider(model);
            } catch (Exception error) {
                add(findings, 'MODEL_ADAPTER_INVALID', 'AgentModel.ModelAdapterClass', safe(error.getMessage()));
            }
        }
        if (!String.isBlank(definition.ToolAuthorizationPolicyClass__c)) {
            try {
                AgentConfigService.newToolAuthorizationPolicy(definition);
            } catch (Exception error) {
                add(findings, 'TOOL_AUTHORIZATION_POLICY_INVALID', 'AgentDefinition.ToolAuthorizationPolicyClass', safe(error.getMessage()));
            }
        }
    }

    private static void validateContextProviders(List<AgentContextProvider__c> providers, List<Finding> findings) {
        if (providers.size() > AgentConfigService.MAX_CONTEXT_PROVIDER_COUNT) {
            add(findings, 'CONTEXT_PROVIDER_COUNT_INVALID', 'AgentDefinition.ContextProviders', 'An agent can have at most 10 active context providers.');
        }
        Set<String> names = new Set<String>();
        for (AgentContextProvider__c provider : providers) {
            String path = 'AgentContextProvider[' + String.valueOf(provider.DeveloperName__c) + ']';
            String normalizedName = String.isBlank(provider.DeveloperName__c) ? '' : provider.DeveloperName__c.trim().toLowerCase();
            required(findings, normalizedName != '', 'CONTEXT_PROVIDER_NAME_REQUIRED', path + '.DeveloperName', 'A context provider name is required.');
            if (normalizedName != '' && names.contains(normalizedName)) {
                add(findings, 'DUPLICATE_CONTEXT_PROVIDER_NAME', path + '.DeveloperName', 'Active context provider names must be unique, ignoring case.');
            }
            names.add(normalizedName);
            String problem = AgentContextConfigurationValidator.error(provider);
            if (problem != null) {
                add(findings, 'CONTEXT_PROVIDER_INVALID', path, safe(problem));
            }
        }
    }

    private static void validateTools(List<AgentTool__c> tools, List<Finding> findings) {
        if (tools.size() > AgentConfigService.MAX_ACTIVE_TOOL_COUNT) {
            add(
                findings,
                'ACTIVE_TOOL_COUNT_INVALID',
                'AgentDefinition.Tools',
                'An agent can have at most ' + AgentConfigService.MAX_ACTIVE_TOOL_COUNT + ' active tools.'
            );
        }
        Integer aggregateCharacters = 0;
        for (AgentTool__c tool : tools) {
            aggregateCharacters += toolConfigurationCharacters(tool);
        }
        if (aggregateCharacters > AgentConfigService.MAX_AGGREGATE_TOOL_CONFIGURATION_CHARACTERS) {
            add(
                findings,
                'AGGREGATE_TOOL_CONFIGURATION_TOO_LARGE',
                'AgentDefinition.Tools',
                'Active tool configuration exceeds the ' + AgentConfigService.MAX_AGGREGATE_TOOL_CONFIGURATION_CHARACTERS + '-character aggregate limit.'
            );
        }
        Set<String> names = new Set<String>();
        for (AgentTool__c tool : tools) {
            String path = 'AgentTool[' + String.valueOf(tool.DeveloperName__c) + ']';
            String normalizedName = String.isBlank(tool.DeveloperName__c) ? '' : tool.DeveloperName__c.trim().toLowerCase();
            required(findings, normalizedName != '', 'TOOL_NAME_REQUIRED', path + '.DeveloperName', 'An active tool name is required.');
            if (normalizedName != '' && names.contains(normalizedName)) {
                add(findings, 'DUPLICATE_ACTIVE_TOOL_NAME', path + '.DeveloperName', 'Active tool names must be unique, ignoring case.');
            }
            if (normalizedName != '') {
                names.add(normalizedName);
            }

            required(
                findings,
                AgentToolTypeService.toolType(tool) != null,
                'TOOL_TYPE_INVALID',
                path + '.ToolType',
                AgentToolTypeService.unavailableMessage(tool.ToolType__c)
            );
            try {
                validateImplementationConfiguration(tool.ImplementationConfiguration__c, 'Tool');
            } catch (Exception error) {
                add(findings, 'TOOL_IMPLEMENTATION_CONFIGURATION_INVALID', path + '.ImplementationConfiguration', safe(error.getMessage()));
            }
            validateEffectiveSchema(tool, path, findings);
            if (!missingRequiredObject(tool, path, findings)) {
                validateImplementation(tool, path, findings);
            }
        }
    }

    /**
     * Rules checked when active tools are saved, on the schema each has now.
     * An inactive tool may save with a problem, so an admin can finish it
     * later; the tool page shows the problem. One outer boundary owns
     * the savepoint for the batch, so each tool's check only measures itself.
     */
    public static void validateToolsOnSave(List<AgentTool__c> tools) {
        List<AgentTool__c> active = new List<AgentTool__c>();
        for (AgentTool__c tool : tools) {
            if (tool.IsActive__c == true) {
                active.add(tool);
            }
        }
        if (active.isEmpty()) {
            return;
        }
        ExtensionExecutionGuard.Boundary batch = ExtensionExecutionGuard.open();
        try {
            for (AgentTool__c tool : active) {
                for (Finding finding : toolSaveErrors(tool)) {
                    tool.addError(finding.message);
                }
            }
        } finally {
            ExtensionExecutionGuard.close(batch);
        }
        assertExecutionUserAccess(active);
    }

    /** Fails the save of a standard record tool its agent's execution user could not use. */
    private static void assertExecutionUserAccess(List<AgentTool__c> tools) {
        Set<Id> definitionIds = new Set<Id>();
        for (AgentTool__c tool : tools) {
            if (tool.AgentDefinition__c != null && !tool.hasErrors()) {
                definitionIds.add(tool.AgentDefinition__c);
            }
        }
        Map<Id, User> executionUsers = ToolExecutionUserAccess.executionUsers(definitionIds);
        for (AgentTool__c tool : tools) {
            String problem = tool.hasErrors() ? null : ToolExecutionUserAccess.problem(tool, executionUsers.get(tool.AgentDefinition__c));
            if (problem != null) {
                tool.addError(problem);
            }
        }
    }

    /**
     * What saving this tool active would report, so an authoring screen can
     * show it before the admin saves. Reads and writes no record.
     */
    public static List<Finding> toolProblems(AgentTool__c tool) {
        ExtensionExecutionGuard.Boundary batch = ExtensionExecutionGuard.open();
        try {
            return toolSaveErrors(tool);
        } finally {
            ExtensionExecutionGuard.close(batch);
        }
    }

    private static List<Finding> toolSaveErrors(AgentTool__c tool) {
        List<Finding> findings = new List<Finding>();
        String path = 'AgentTool[' + String.valueOf(tool.DeveloperName__c) + ']';
        if (AgentToolTypeService.toolType(tool) == null) {
            add(findings, 'TOOL_TYPE_INVALID', path + '.ToolType', AgentToolTypeService.unavailableMessage(tool.ToolType__c));
            return findings;
        }
        try {
            validateImplementationConfiguration(tool.ImplementationConfiguration__c, 'Tool');
        } catch (Exception error) {
            add(findings, 'TOOL_IMPLEMENTATION_CONFIGURATION_INVALID', path + '.ImplementationConfiguration', safe(error.getMessage()));
            return findings;
        }
        validateEffectiveSchema(tool, path, findings);
        if (!missingRequiredObject(tool, path, findings)) {
            validateImplementation(tool, path, findings);
        }
        return findings;
    }

    private static Boolean missingRequiredObject(AgentTool__c tool, String path, List<Finding> findings) {
        if (!AgentToolTypeService.isMissingRequiredObject(tool)) {
            return false;
        }
        add(findings, 'TOOL_OBJECT_REQUIRED', path + '.ImplementationConfiguration', AgentToolTypeService.missingObjectMessage(tool.ToolType__c));
        return true;
    }

    /** The tool type's class must implement ITool, and the tool's own configuration check must pass without side effects. */
    private static void validateImplementation(AgentTool__c tool, String path, List<Finding> findings) {
        ITool implementation;
        try {
            implementation = AgentConfigService.newTool(tool);
        } catch (Exception error) {
            add(findings, 'TOOL_IMPLEMENTATION_INVALID', path + '.ToolType', safe(error.getMessage()));
            return;
        }
        AgentKernelModels.ToolConfiguration configuration = new AgentKernelModels.ToolConfiguration();
        configuration.toolName = tool.DeveloperName__c;
        configuration.implementationConfiguration = tool.ImplementationConfiguration__c;
        configuration.inputSchema = ToolSchemaService.effectiveSchema(tool).schema;
        List<String> problems;
        Exception checkFailure;
        ExtensionExecutionGuard.Boundary boundary = ExtensionExecutionGuard.open();
        try {
            problems = implementation.validateConfiguration(configuration);
        } catch (Exception caughtFailure) {
            checkFailure = caughtFailure;
        }
        ExtensionExecutionGuard.Result isolation = ExtensionExecutionGuard.close(boundary);
        if (isolation.performedDml || isolation.performedCallout || isolation.performedProhibitedAsync() || isolation.budgetExceeded) {
            add(findings, 'TOOL_CONFIGURATION_CHECK_INVALID', path + '.ToolType', 'The tool configuration check must remain query-only.');
            return;
        }
        if (checkFailure != null) {
            add(findings, 'TOOL_CONFIGURATION_INVALID', path + '.ImplementationConfiguration', safe(checkFailure.getMessage()));
            return;
        }
        for (String problem : problems == null ? new List<String>() : problems) {
            add(findings, 'TOOL_CONFIGURATION_INVALID', path + '.ImplementationConfiguration', problem);
        }
    }

    private static Integer toolConfigurationCharacters(AgentTool__c tool) {
        return characters(tool.DeveloperName__c) +
            characters(tool.Description__c) +
            characters(tool.ToolType__c) +
            characters(tool.ImplementationConfiguration__c) +
            characters(ToolSchemaService.effectiveSchema(tool).schema) +
            characters(tool.AllowedSensitiveDataCategories__c);
    }

    private static Integer characters(String value) {
        return value == null ? 0 : value.length();
    }

    private static void validateImplementationConfiguration(String value, String label) {
        if (String.isBlank(value)) {
            return;
        }
        if (value.length() > AgentConfigService.MAX_CONTEXT_CONFIGURATION_CHARACTERS && label == 'Context provider') {
            throw new AgentKernelException.ConfigurationException('Context provider implementation configuration exceeds 8000 characters.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(value);
        } catch (Exception invalidJson) {
            throw new AgentKernelException.ConfigurationException(label + ' implementation configuration must be valid JSON.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new AgentKernelException.ConfigurationException(label + ' implementation configuration must be a JSON object.');
        }
    }

    /**
     * The schema checks for an active tool, on the schema it has now:
     * hand-written, or built from its settings with the admin's edits. An
     * edit that would widen what the tool builds is refused here, by path.
     */
    private static void validateEffectiveSchema(AgentTool__c tool, String path, List<Finding> findings) {
        ToolSchemaService.Resolution schema = ToolSchemaService.effectiveSchema(tool);
        if (schema.problem != null) {
            Boolean missing = schema.built == false && String.isBlank(tool.InputSchema__c);
            add(findings, missing ? 'TOOL_INPUT_SCHEMA_REQUIRED' : 'TOOL_INPUT_SCHEMA_INVALID', path + '.InputSchema', safe(schema.problem));
            return;
        }
        if (schema.built) {
            for (String problem : ToolInputOverrides.problems(schema.authoring.inputSchema, tool.ImplementationConfiguration__c)) {
                add(findings, 'TOOL_INPUT_EDIT_INVALID', path + '.ImplementationConfiguration', safe(problem));
            }
        }
        try {
            ToolJsonSchemaValidator.validateSchema(schema.schema, 'Tool input schema');
            validateClosedInputSchema(schema.schema);
            validateTrustCategories(tool);
        } catch (Exception error) {
            add(findings, 'TOOL_INPUT_SCHEMA_INVALID', path + '.InputSchema', safe(error.getMessage()));
        }
        required(
            findings,
            !declaresStringFormat(schema.schema, 'email') || allowsCategory(tool, TrustService.CATEGORY_EMAIL),
            'TOOL_SENSITIVE_CATEGORY_REQUIRED',
            path + '.AllowedSensitiveDataCategories',
            'The input schema declares an email property, and the model sees email addresses only as trust tokens. Allow the Email category so Core restores the address for this tool.'
        );
    }

    private static void validateTrustCategories(AgentTool__c tool) {
        Set<String> allowed = new Set<String>{ 'Email', 'Phone', 'Payment Card', 'US SSN', 'IBAN', 'Salesforce Classified' };
        if (String.isBlank(tool.AllowedSensitiveDataCategories__c)) {
            return;
        }
        for (String category : tool.AllowedSensitiveDataCategories__c.split(';')) {
            if (!allowed.contains(category)) {
                throw new AgentKernelException.ConfigurationException('Allowed sensitive-data categories contain an unsupported value.');
            }
        }
    }

    private static Boolean allowsCategory(AgentTool__c tool, String category) {
        return !String.isBlank(tool.AllowedSensitiveDataCategories__c) && tool.AllowedSensitiveDataCategories__c.split(';').contains(category);
    }

    private static Boolean declaresStringFormat(String schemaJson, String format) {
        try {
            return declaresStringFormat(JSON.deserializeUntyped(schemaJson), format, 0);
        } catch (Exception invalidSchema) {
            return false;
        }
    }

    private static Boolean declaresStringFormat(Object value, String format, Integer depth) {
        if (depth > 20) {
            return false;
        }
        if (value instanceof List<Object>) {
            for (Object item : (List<Object>) value) {
                if (declaresStringFormat(item, format, depth + 1)) {
                    return true;
                }
            }
            return false;
        }
        if (!(value instanceof Map<String, Object>)) {
            return false;
        }
        Map<String, Object> schema = (Map<String, Object>) value;
        if (schema.get('format') == format) {
            return true;
        }
        for (String key : schema.keySet()) {
            if (declaresStringFormat(schema.get(key), format, depth + 1)) {
                return true;
            }
        }
        return false;
    }

    private static void validateClosedInputSchema(String schemaJson) {
        Object schema = JSON.deserializeUntyped(schemaJson);
        if (!(schema instanceof Map<String, Object>) || ((Map<String, Object>) schema).get('type') != 'object') {
            // Tool input is always one JSON object, and Core's rationale is added to object schemas.
            throw new AgentKernelException.ConfigurationException('A tool input schema must be a JSON object schema with "type": "object" at the top.');
        }
        requireClosedObjectSchemas(schema, '$');
        Object properties = schema instanceof Map<String, Object> ? ((Map<String, Object>) schema).get('properties') : null;
        if (properties instanceof Map<String, Object> && ((Map<String, Object>) properties).containsKey(AgentKernelModels.TOOL_RATIONALE_PROPERTY)) {
            throw new AgentKernelException.ConfigurationException(
                'Rename the ' + AgentKernelModels.TOOL_RATIONALE_PROPERTY + ' input. Agent Core adds it to every tool to ask the model why it made the call.'
            );
        }
    }

    private static void requireClosedObjectSchemas(Object value, String path) {
        if (!(value instanceof Map<String, Object>)) {
            return;
        }
        Map<String, Object> schema = (Map<String, Object>) value;
        if (schema.get('type') == 'object' && schema.get('additionalProperties') != false) {
            throw new AgentKernelException.ConfigurationException('Executable tool schemas require additionalProperties: false at ' + path + '.');
        }
        if (schema.get('properties') instanceof Map<String, Object>) {
            for (String propertyName : ((Map<String, Object>) schema.get('properties')).keySet()) {
                requireClosedObjectSchemas(((Map<String, Object>) schema.get('properties')).get(propertyName), path + '.properties.' + propertyName);
            }
        }
        if (schema.containsKey('items')) {
            requireClosedObjectSchemas(schema.get('items'), path + '.items');
        }
    }

    private static void wholeRange(List<Finding> findings, Decimal value, Integer minimum, Integer maximum, String code, String path) {
        required(
            findings,
            value != null && value == value.setScale(0) && value >= minimum && value <= maximum,
            code,
            path,
            'Value must be a whole number from ' + minimum + ' through ' + maximum + '.'
        );
    }

    private static void optionalRange(List<Finding> findings, Decimal value, Integer minimum, Integer maximum, String code, String path) {
        if (value != null) {
            wholeRange(findings, value, minimum, maximum, code, path);
        }
    }

    private static void required(List<Finding> findings, Boolean valid, String code, String path, String message) {
        if (!valid) {
            add(findings, code, path, message);
        }
    }

    private static void add(List<Finding> findings, String code, String path, String message) {
        findings.add(new Finding(code, path, safe(message)));
    }

    private static String safe(String message) {
        String result = String.isBlank(message) ? 'Configuration is invalid.' : message.replace('\r', ' ').replace('\n', ' ').trim();
        return result.length() > 255 ? result.substring(0, 255) : result;
    }
}
