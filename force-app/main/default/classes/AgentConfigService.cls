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
 * Transaction-scoped repository and validator for agent configuration.
 */
public inherited sharing class AgentConfigService {
    public static final Integer MAX_ACTIVE_TOOL_COUNT = 25;
    public static final Integer MAX_AGGREGATE_TOOL_CONFIGURATION_CHARACTERS = 262144;
    public static final Integer MAX_CONTEXT_PROVIDER_COUNT = 10;
    public static final Integer MAX_CONTEXT_CHARACTERS = 50000;
    public static final Integer MAX_CONTEXT_CONFIGURATION_CHARACTERS = 8000;
    public static final Integer DEFAULT_MODEL_REQUEST_CHARACTERS = 50000;
    public static final Integer MIN_MODEL_REQUEST_CHARACTERS = 5000;
    public static final Integer MAX_MODEL_REQUEST_CHARACTERS = 400000;
    public static final Integer DEFAULT_MODEL_TIMEOUT_SECONDS = 120;
    public static final Integer MIN_MODEL_TIMEOUT_SECONDS = 10;
    public static final Integer DEFAULT_TRANSCRIPT_TURN_LIMIT = 10;
    public static final Integer MAX_TRANSCRIPT_TURN_LIMIT = 50;
    public static final Integer MAX_REPLY_WINDOW_HOURS = 168;
    public static final Integer DEFAULT_TOTAL_TOKENS = 250000;
    public static final Integer MIN_TOTAL_TOKENS = 1000;
    public static final Integer MAX_TOTAL_TOKENS = 100000000;
    private static Map<Id, AgentDefinition__c> definitionsById = new Map<Id, AgentDefinition__c>();
    private static Map<String, AgentDefinition__c> definitionsByName = new Map<String, AgentDefinition__c>();
    private static Map<Id, List<AgentTool__c>> toolsByAgentId = new Map<Id, List<AgentTool__c>>();
    private static Map<Id, List<AgentContextProvider__c>> contextProvidersByAgentId = new Map<Id, List<AgentContextProvider__c>>();
    /** Definitions that passed validation in this transaction; configuration is cached above, so the result cannot change. */
    private static Map<Id, List<AgentTool__c>> validatedToolsByAgentId = new Map<Id, List<AgentTool__c>>();

    public static Integer modelRequestCharacters(AgentDefinition__c definition) {
        return bounded(definition?.MaxModelRequestCharacters__c, DEFAULT_MODEL_REQUEST_CHARACTERS, MIN_MODEL_REQUEST_CHARACTERS, MAX_MODEL_REQUEST_CHARACTERS);
    }

    public static Integer modelTimeoutSeconds(AgentDefinition__c definition) {
        return bounded(definition?.ModelTimeoutSeconds__c, DEFAULT_MODEL_TIMEOUT_SECONDS, MIN_MODEL_TIMEOUT_SECONDS, DEFAULT_MODEL_TIMEOUT_SECONDS);
    }

    public static Integer transcriptTurnLimit(AgentDefinition__c definition) {
        return bounded(definition?.TranscriptTurnLimit__c, DEFAULT_TRANSCRIPT_TURN_LIMIT, 0, MAX_TRANSCRIPT_TURN_LIMIT);
    }

    /** Model tokens one run, or one reply of a conversational run, may use before it pauses. */
    public static Integer maxTotalTokens(AgentDefinition__c definition) {
        Decimal value = definition == null ? null : (Decimal) definition.getPopulatedFieldsAsMap().get('MaxTotalTokens__c');
        return bounded(value, DEFAULT_TOTAL_TOKENS, MIN_TOTAL_TOKENS, MAX_TOTAL_TOKENS);
    }

    /** Hours a conversational run waits for the person's next message, or null when the run ends with its answer. */
    public static Integer replyWindowHours(AgentDefinition__c definition) {
        Decimal value = definition == null ? null : (Decimal) definition.getPopulatedFieldsAsMap().get('ReplyWindowHours__c');
        return value == null ? null : bounded(value, null, 1, MAX_REPLY_WINDOW_HOURS);
    }

    private static Integer bounded(Decimal value, Integer defaultValue, Integer minimum, Integer maximum) {
        return value == null ? defaultValue : Math.max(minimum, Math.min(maximum, value.intValue()));
    }

    @TestVisible
    private static void clearCacheForTest() {
        definitionsById.clear();
        definitionsByName.clear();
        toolsByAgentId.clear();
        contextProvidersByAgentId.clear();
        validatedToolsByAgentId.clear();
    }

    public static AgentDefinition__c getActiveDefinition(Id definitionId) {
        if (definitionId == null) {
            throw new AgentKernelException.ConfigurationException('Agent definition ID is required.');
        }
        if (!definitionsById.containsKey(definitionId)) {
            cache(loadActiveDefinition(definitionId, null));
        }
        return definitionsById.get(definitionId);
    }

    public static AgentDefinition__c getActiveDefinition(String developerName) {
        if (String.isBlank(developerName)) {
            throw new AgentKernelException.ConfigurationException('Agent developer name is required.');
        }
        String key = developerName.trim().toLowerCase();
        if (!definitionsByName.containsKey(key)) {
            cache(loadActiveDefinition(null, developerName.trim()));
        }
        return definitionsByName.get(key);
    }

    private static AgentDefinition__c loadActiveDefinition(Id definitionId, String developerName) {
        List<AgentDefinition__c> records = [
            SELECT
                Id,
                LastModifiedDate,
                DeveloperName__c,
                IsActive__c,
                ExecutionIdentity__c,
                Instructions__c,
                Model__c,
                MaxModelCalls__c,
                MaxToolCalls__c,
                MaxTotalTokens__c,
                AllowMultipleToolCalls__c,
                MaxRetries__c,
                MaxModelRequestCharacters__c,
                ModelTimeoutSeconds__c,
                TranscriptTurnLimit__c,
                ReplyWindowHours__c,
                OutputSchema__c,
                ToolAuthorizationPolicyClass__c,
                (
                    SELECT
                        Id,
                        LastModifiedDate,
                        AgentDefinition__c,
                        DeveloperName__c,
                        Description__c,
                        ImplementationType__c,
                        ImplementationReference__c,
                        ImplementationConfiguration__c,
                        ContextSubject__c,
                        ObjectApiName__c,
                        FieldSetName__c,
                        SortOrder__c,
                        IsActive__c
                    FROM ContextProviders__r
                    WHERE IsActive__c = TRUE
                    ORDER BY SortOrder__c ASC NULLS LAST, DeveloperName__c ASC
                )
            FROM AgentDefinition__c
            WHERE IsActive__c = TRUE AND (Id = :definitionId OR DeveloperName__c = :developerName)
            WITH USER_MODE
            LIMIT 1
        ];
        if (records.isEmpty()) {
            throw new AgentKernelException.NotFoundException(notFoundMessage(definitionId, developerName));
        }
        return records[0];
    }

    /**
     * Sharing on the Agent Definition decides who may run it. A miss is read
     * again in system mode only to tell a user who was not shared the agent
     * apart from a name that matches no active agent; a normal start pays nothing.
     */
    private static String notFoundMessage(Id definitionId, String developerName) {
        List<AgentDefinition__c> hidden = [
            SELECT DeveloperName__c
            FROM AgentDefinition__c
            WHERE IsActive__c = TRUE AND (Id = :definitionId OR DeveloperName__c = :developerName)
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!hidden.isEmpty()) {
            return 'You can\'t run agent ' + hidden[0].DeveloperName__c + '. Ask your admin to share it with you.';
        }
        return 'No active agent has the Id or API name ' + (definitionId != null ? String.valueOf(definitionId) : developerName) + '.';
    }

    public static List<AgentTool__c> getActiveTools(Id definitionId) {
        if (definitionId == null) {
            throw new AgentKernelException.ConfigurationException('Agent definition ID is required.');
        }
        return getActiveToolsByDefinitionIds(new Set<Id>{ definitionId }).get(definitionId);
    }

    public static Map<Id, List<AgentTool__c>> getActiveToolsByDefinitionIds(Set<Id> definitionIds) {
        Map<Id, List<AgentTool__c>> result = new Map<Id, List<AgentTool__c>>();
        if (definitionIds == null || definitionIds.isEmpty()) {
            return result;
        }
        Set<Id> missingDefinitionIds = new Set<Id>();
        for (Id definitionId : definitionIds) {
            if (definitionId != null && !toolsByAgentId.containsKey(definitionId)) {
                toolsByAgentId.put(definitionId, new List<AgentTool__c>());
                missingDefinitionIds.add(definitionId);
            }
        }
        if (!missingDefinitionIds.isEmpty()) {
            for (AgentTool__c tool : [
                SELECT
                    Id,
                    LastModifiedDate,
                    AgentDefinition__c,
                    DeveloperName__c,
                    Description__c,
                    ToolType__c,
                    ImplementationConfiguration__c,
                    InputSchema__c,
                    RequiresApproval__c,
                    ApproverType__c,
                    ApproverUser__c,
                    ApproverQueue__c,
                    ApprovalTimeoutHours__c,
                    ApprovalExpiryAction__c,
                    AllowedSensitiveDataCategories__c,
                    IsActive__c,
                    SortOrder__c
                FROM AgentTool__c
                WHERE AgentDefinition__c IN :missingDefinitionIds AND IsActive__c = TRUE
                WITH USER_MODE
                ORDER BY AgentDefinition__c ASC, SortOrder__c ASC NULLS LAST, DeveloperName__c ASC
            ]) {
                List<AgentTool__c> configuredTools = toolsByAgentId.get(tool.AgentDefinition__c);
                configuredTools.add(tool);
                if (configuredTools.size() > MAX_ACTIVE_TOOL_COUNT) {
                    throw new AgentKernelException.ConfigurationException('An agent can have at most ' + MAX_ACTIVE_TOOL_COUNT + ' active tools.');
                }
            }
        }
        for (Id definitionId : definitionIds) {
            List<AgentTool__c> configuredTools = definitionId != null && toolsByAgentId.containsKey(definitionId)
                ? toolsByAgentId.get(definitionId).clone()
                : new List<AgentTool__c>();
            result.put(definitionId, configuredTools);
        }
        return result;
    }

    public static List<AgentContextProvider__c> getActiveContextProviders(Id definitionId) {
        if (definitionId == null) {
            throw new AgentKernelException.ConfigurationException('Agent definition ID is required.');
        }
        if (!contextProvidersByAgentId.containsKey(definitionId)) {
            contextProvidersByAgentId.put(
                definitionId,
                [
                    SELECT
                        Id,
                        LastModifiedDate,
                        AgentDefinition__c,
                        DeveloperName__c,
                        Description__c,
                        ImplementationType__c,
                        ImplementationReference__c,
                        ImplementationConfiguration__c,
                        ContextSubject__c,
                        ObjectApiName__c,
                        FieldSetName__c,
                        SortOrder__c,
                        IsActive__c
                    FROM AgentContextProvider__c
                    WHERE AgentDefinition__c = :definitionId AND IsActive__c = TRUE
                    WITH USER_MODE
                    ORDER BY SortOrder__c ASC NULLS LAST, DeveloperName__c ASC
                ]
            );
        }
        return contextProvidersByAgentId.get(definitionId).clone();
    }

    public static IModelProvider newModelProvider(AgentModel__mdt model) {
        return (IModelProvider) newImplementation(model == null ? null : model.ModelAdapterClass__c, true, 'model adapter');
    }

    /** Resolves an ITool adapter through the tool's Agent Tool Type record. */
    public static ITool newTool(AgentTool__c tool) {
        if (tool == null) {
            throw new AgentKernelException.ConfigurationException('Tool configuration is required.');
        }
        AgentToolType__mdt toolType = AgentToolTypeService.toolType(tool);
        if (toolType == null) {
            throw new AgentKernelException.ConfigurationException(AgentToolTypeService.unavailableMessage(tool.ToolType__c));
        }
        return (ITool) newImplementation(toolType.ToolClass__c, false, 'tool');
    }

    /** Returns the operator-controlled configuration supplied to an adapter. */
    public static String toolConfiguration(AgentTool__c tool) {
        return tool == null ? null : tool.ImplementationConfiguration__c;
    }

    public static IContextProvider newContextProvider(AgentContextProvider__c configuration) {
        if (configuration != null && configuration.ImplementationType__c == 'Field Set') {
            return new FieldSetContextProvider();
        }
        String className = configuration == null ? null : configuration.ImplementationReference__c;
        Type implementationType = resolveImplementationType(className);
        if (implementationType == null) {
            throw new AgentKernelException.ConfigurationException('Configured context provider class was not found.');
        }
        Object implementation;
        try {
            implementation = implementationType.newInstance();
        } catch (Exception initializationFailure) {
            throw new AgentKernelException.ConfigurationException('Configured context provider class could not be initialized.');
        }
        if (!(implementation instanceof IContextProvider)) {
            throw new AgentKernelException.ConfigurationException('Configured context provider does not implement the required IContextProvider interface.');
        }
        return (IContextProvider) implementation;
    }

    public static IToolAuthorizationPolicy newToolAuthorizationPolicy(AgentDefinition__c definition) {
        if (definition == null || String.isBlank(definition.ToolAuthorizationPolicyClass__c)) {
            return null;
        }
        Type implementationType = resolveImplementationType(definition.ToolAuthorizationPolicyClass__c);
        if (implementationType == null) {
            throw new AgentKernelException.ConfigurationException('Configured tool authorization policy class was not found.');
        }
        try {
            Object implementation = implementationType.newInstance();
            if (!(implementation instanceof IToolAuthorizationPolicy)) {
                throw new AgentKernelException.ConfigurationException('Configured tool authorization policy does not implement IToolAuthorizationPolicy.');
            }
            return (IToolAuthorizationPolicy) implementation;
        } catch (AgentKernelException.ConfigurationException error) {
            throw error;
        } catch (Exception initializationFailure) {
            throw new AgentKernelException.ConfigurationException('Configured tool authorization policy could not be initialized.');
        }
    }

    public static List<AgentTool__c> validate(AgentDefinition__c definition) {
        if (definition != null && definition.Id != null && validatedToolsByAgentId.containsKey(definition.Id)) {
            return validatedToolsByAgentId.get(definition.Id).clone();
        }
        List<AgentTool__c> tools = definition == null || definition.Id == null ? new List<AgentTool__c>() : getActiveTools(definition.Id);
        List<AgentContextProvider__c> contexts = definition == null ||
            definition.Id == null
            ? new List<AgentContextProvider__c>()
            : getActiveContextProviders(definition.Id);
        List<AgentConfigurationValidator.Finding> findings = AgentConfigurationValidator.collectErrors(definition, tools, contexts);
        if (!findings.isEmpty()) {
            throw new AgentKernelException.ConfigurationException(findings[0].message);
        }
        if (definition.Id != null) {
            validatedToolsByAgentId.put(definition.Id, tools.clone());
        }
        return tools;
    }

    /** Definition fields that change how a run behaves, kept as a short hash because their text may be long or private. */
    private static final List<SObjectField> HASHED_SETTINGS = new List<SObjectField>{
        AgentDefinition__c.Instructions__c,
        AgentDefinition__c.Model__c,
        AgentDefinition__c.OutputSchema__c,
        AgentDefinition__c.ToolAuthorizationPolicyClass__c,
        AgentDefinition__c.ExecutionIdentity__c
    };

    /** Limits and switches, kept as values so a change can say what they became. */
    private static final List<SObjectField> VALUE_SETTINGS = new List<SObjectField>{
        AgentDefinition__c.MaxModelCalls__c,
        AgentDefinition__c.MaxToolCalls__c,
        AgentDefinition__c.MaxTotalTokens__c,
        AgentDefinition__c.AllowMultipleToolCalls__c,
        AgentDefinition__c.MaxRetries__c,
        AgentDefinition__c.MaxModelRequestCharacters__c,
        AgentDefinition__c.ModelTimeoutSeconds__c,
        AgentDefinition__c.TranscriptTurnLimit__c,
        AgentDefinition__c.ReplyWindowHours__c
    };

    /**
     * Fingerprint of everything that changes how a run behaves: the
     * definition's executable fields, active tools, and active context
     * providers. Recorded on each invocation so a mid-run change is visible.
     */
    public static String configurationHash(AgentDefinition__c definition, List<AgentTool__c> tools, List<AgentContextProvider__c> contexts) {
        return fingerprintHash(configurationFingerprint(definition, tools, contexts));
    }

    public static String fingerprintHash(Map<String, Object> fingerprint) {
        return CanonicalJson.sha256(CanonicalJson.serialize(fingerprint));
    }

    /**
     * The configuration by part: limits and switches as values, everything
     * else as a short hash. It holds no instructions, schemas, or record data,
     * only tool and context developer names, so events may store it.
     */
    public static Map<String, Object> configurationFingerprint(
        AgentDefinition__c definition,
        List<AgentTool__c> tools,
        List<AgentContextProvider__c> contexts
    ) {
        Map<String, Object> settings = new Map<String, Object>();
        for (SObjectField field : HASHED_SETTINGS) {
            Object value = definition.get(field);
            if (field == AgentDefinition__c.Model__c) {
                // The model record, not only its name, decides which provider model runs.
                AgentModel__mdt model = AgentModelService.activeModel(definition.Model__c);
                value = new List<Object>{
                    value,
                    model == null ? null : new List<Object>{ model.ModelAdapterClass__c, model.ModelIdentifier__c, model.NamedCredential__c }
                };
            }
            settings.put(String.valueOf(field), shortHash(value));
        }
        for (SObjectField field : VALUE_SETTINGS) {
            settings.put(String.valueOf(field), definition.get(field));
        }
        Map<String, String> toolParts = new Map<String, String>();
        for (AgentTool__c tool : tools == null ? new List<AgentTool__c>() : tools) {
            toolParts.put(
                tool.DeveloperName__c,
                shortHash(
                    new List<Object>{
                        tool.Description__c,
                        AgentToolTypeService.bindingHash(tool),
                        tool.InputSchema__c,
                        tool.RequiresApproval__c,
                        tool.ApproverType__c,
                        tool.ApproverUser__c,
                        tool.ApproverQueue__c,
                        tool.ApprovalTimeoutHours__c,
                        tool.ApprovalExpiryAction__c,
                        tool.AllowedSensitiveDataCategories__c
                    }
                )
            );
        }
        Map<String, String> contextParts = new Map<String, String>();
        for (AgentContextProvider__c context : contexts == null ? new List<AgentContextProvider__c>() : contexts) {
            contextParts.put(
                context.DeveloperName__c,
                shortHash(
                    new List<Object>{
                        context.ImplementationType__c,
                        context.ImplementationReference__c,
                        context.ImplementationConfiguration__c,
                        context.ContextSubject__c,
                        context.ObjectApiName__c,
                        context.FieldSetName__c,
                        context.SortOrder__c
                    }
                )
            );
        }
        // Names sit in pairs, not as keys, so an admin's sensitive JSON keys can never redact them.
        return new Map<String, Object>{ 'settings' => settings, 'tools' => namedParts(toolParts), 'contexts' => namedParts(contextParts) };
    }

    /**
     * What differs between two fingerprints, for an admin: a limit says what it
     * was and became; a hashed setting, tool, or context only that it changed.
     */
    public static List<Object> configurationChanges(Map<String, Object> previous, Map<String, Object> current) {
        List<Object> changes = new List<Object>();
        Map<String, Object> before = asMap(previous.get('settings'));
        Map<String, Object> after = asMap(current.get('settings'));
        for (SObjectField field : HASHED_SETTINGS) {
            String key = String.valueOf(field);
            if (!sameValue(before.get(key), after.get(key))) {
                changes.add(new Map<String, Object>{ 'setting' => field.getDescribe().getLabel() });
            }
        }
        for (SObjectField field : VALUE_SETTINGS) {
            String key = String.valueOf(field);
            if (!sameValue(before.get(key), after.get(key))) {
                changes.add(new Map<String, Object>{ 'setting' => field.getDescribe().getLabel(), 'before' => before.get(key), 'after' => after.get(key) });
            }
        }
        addPartChanges(changes, 'tool', previous.get('tools'), current.get('tools'));
        addPartChanges(changes, 'context', previous.get('contexts'), current.get('contexts'));
        return changes;
    }

    /** One line for the event's summary: "Changed Max Tool Calls (3 to 4), tool lookup_order." */
    public static String describeChanges(List<Object> changes) {
        List<String> parts = new List<String>();
        for (Object entry : changes) {
            Map<String, Object> change = asMap(entry);
            if (change.containsKey('setting')) {
                parts.add(
                    change.containsKey('after')
                        ? change.get('setting') + ' (' + String.valueOf(change.get('before')) + ' to ' + String.valueOf(change.get('after')) + ')'
                        : String.valueOf(change.get('setting'))
                );
            } else {
                String kind = change.containsKey('tool') ? 'tool' : 'context';
                parts.add(change.get('change') + ' ' + kind + ' ' + change.get(kind));
            }
        }
        return parts.isEmpty() ? null : 'Changed ' + String.join(parts, ', ') + '.';
    }

    private static void addPartChanges(List<Object> changes, String kind, Object previous, Object current) {
        Map<String, Object> before = partsByName(previous);
        Map<String, Object> after = partsByName(current);
        Set<String> names = new Set<String>(before.keySet());
        names.addAll(after.keySet());
        List<String> ordered = new List<String>(names);
        ordered.sort();
        for (String partName : ordered) {
            String change = !before.containsKey(partName)
                ? 'added'
                : !after.containsKey(partName) ? 'removed' : before.get(partName) != after.get(partName) ? 'changed' : null;
            if (change != null) {
                changes.add(new Map<String, Object>{ kind => partName, 'change' => change });
            }
        }
    }

    private static List<Object> namedParts(Map<String, String> parts) {
        List<String> names = new List<String>(parts.keySet());
        names.sort();
        List<Object> result = new List<Object>();
        for (String partName : names) {
            result.add(new List<Object>{ partName, parts.get(partName) });
        }
        return result;
    }

    private static Map<String, Object> partsByName(Object parts) {
        Map<String, Object> result = new Map<String, Object>();
        if (parts instanceof List<Object>) {
            for (Object entry : (List<Object>) parts) {
                if (entry instanceof List<Object> && ((List<Object>) entry).size() == 2) {
                    List<Object> pair = (List<Object>) entry;
                    result.put(String.valueOf(pair[0]), pair[1]);
                }
            }
        }
        return result;
    }

    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : new Map<String, Object>();
    }

    /** A stored fingerprint comes back from JSON as Integer where the record held Decimal, so numbers compare by value. */
    private static Boolean sameValue(Object left, Object right) {
        if (left == null || right == null) {
            return left == right;
        }
        Boolean numeric =
            (left instanceof Decimal || left instanceof Integer || left instanceof Long || left instanceof Double) &&
            (right instanceof Decimal ||
            right instanceof Integer ||
            right instanceof Long ||
            right instanceof Double);
        return numeric ? Decimal.valueOf(String.valueOf(left)) == Decimal.valueOf(String.valueOf(right)) : String.valueOf(left) == String.valueOf(right);
    }

    private static String shortHash(Object value) {
        return CanonicalJson.sha256(JSON.serialize(value)).substring(0, 16);
    }

    /** Instantiates the configured class once and checks it implements the expected interface. */
    private static Object newImplementation(String className, Boolean modelProvider, String label) {
        try {
            Type implementationType = resolveImplementationType(className);
            if (implementationType == null) {
                throw new AgentKernelException.ConfigurationException('Configured ' + label + ' class was not found.');
            }
            Object implementation = implementationType.newInstance();
            Boolean valid = modelProvider ? implementation instanceof IModelProvider : implementation instanceof ITool;
            if (!valid) {
                throw new AgentKernelException.ConfigurationException('Configured ' + label + ' class does not implement the required interface.');
            }
            return implementation;
        } catch (AgentKernelException.ConfigurationException e) {
            throw e;
        } catch (Exception e) {
            throw new AgentKernelException.ConfigurationException('Configured ' + label + ' class could not be initialized.');
        }
    }

    @TestVisible
    private static Type resolveImplementationType(String configuredName) {
        String className = String.isBlank(configuredName) ? null : configuredName.trim();
        if (className == null || !Pattern.matches('^(?:[A-Za-z][A-Za-z0-9_]*\\.)?[A-Za-z][A-Za-z0-9_]*$', className)) {
            throw new AgentKernelException.ConfigurationException('Configured implementation class name is invalid.');
        }

        Integer separator = className.indexOf('.');
        if (separator > 0) {
            return Type.forName(className.substring(0, separator), className.substring(separator + 1));
        }

        // Core is deployed in the empty namespace, so a bare name resolves there.
        Type implementationType = Type.forName(className);
        return implementationType == null ? Type.forName('', className) : implementationType;
    }

    private static void cache(AgentDefinition__c definition) {
        definitionsById.put(definition.Id, definition);
        definitionsByName.put(definition.DeveloperName__c.toLowerCase(), definition);
        if (definition.ContextProviders__r != null) {
            contextProvidersByAgentId.put(definition.Id, definition.ContextProviders__r);
        }
    }
}
