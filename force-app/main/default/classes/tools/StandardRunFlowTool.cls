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
 * Standard tool: run an active autolaunched flow and return its outputs.
 *
 * Standard tool types RunFlow and RunFlowWithExternalEffects. Operator
 * configuration must specify flowApiName and set allowSystemContext to true:
 * an autolaunched flow started from Apex runs with system access to objects
 * and fields, even in Default Mode (confirmed in an org, 2026-10-02).
 *
 * Tool input (model-visible, built on each run from the active version's
 * input variables): a flat object of flow input variables, for example
 *   {"recordId": "001...", "reason": "VIP escalation"}
 *
 * Behavior: the flow must exist with an active version and must be
 * autolaunched; screen flows are rejected before launch. The interview runs
 * as the execution principal, but the Flow's run context can elevate access.
 * Operators must audit sharing, CRUD, and FLS in the configured Flow. On an
 * attended run, the person the run works for must be able to edit every record
 * whose Id is a flow input, because Core cannot tell what the flow changes.
 * Scalar output variables are collected into a JSON object; a flow with no
 * outputs returns {"flowCompleted": true}. Record output variables are
 * returned as structured record sets, so Core applies field-level access and
 * Salesforce field classification before the model or evidence sees them. A
 * flow may not mix record and scalar outputs; that configuration is rejected
 * before launch. A fault after interview start is Unknown.
 * Only autolaunched flows are
 * supported: record-triggered and scheduled flows cannot be launched this
 * way and fail closed at configuration time.
 *
 * Recovery contract: under RunFlow the Flow only changes this org's records
 * and runs in a savepoint, so a fault is rolled back and returned to the
 * model. Under RunFlowWithExternalEffects a fault after the interview starts
 * is Unknown and needs reconciliation, never a blind retry.
 */
public inherited sharing class StandardRunFlowTool implements ITool, IToolAuthoring {
    private static final String FAULT_MESSAGE_VARIABLE = 'faultMessage';

    public AgentKernelModels.ToolResponse execute(AgentKernelModels.ToolRequest request) {
        Map<String, Object> config = StandardToolSupport.configuration(request == null ? null : request.implementationConfiguration);
        FlowDefinitionView definition = checkedDefinition(config);
        String flowApiName = definition.ApiName;
        Map<String, Object> input = StandardToolSupport.objectInput(request == null ? null : request.input, 'Tool input');
        Map<String, Object> flowParams = serializableParams(input, flowApiName);
        assertRequesterCanEditInputs(request.principal, flowParams);
        FlowOutputs outputs = outputVariables(definition);
        Flow.Interview interview;
        try {
            interview = Flow.Interview.createInterview(flowApiName, flowParams);
        } catch (Exception launchFailure) {
            throw StandardToolSupport.permanent(
                'Flow "' + flowApiName + '" could not be started: ' + StandardToolSupport.bound(launchFailure.getMessage(), 500)
            );
        }
        if (interview == null) {
            throw StandardToolSupport.permanent('Flow "' + flowApiName + '" could not be started. Verify the flow API name and active version.');
        }
        try {
            interview.start();
        } catch (Exception interviewFault) {
            // Without external effects Core rolls the flow back and returns this to the model; with them it is Unknown for an operator.
            throw new AgentKernelException.OutcomeUnknownException(
                'Flow "' + flowApiName + '" failed after it started: ' + StandardToolSupport.bound(interviewFault.getMessage(), 500)
            );
        }
        Object faultMessage = variableValue(interview, FAULT_MESSAGE_VARIABLE);
        if (faultMessage instanceof String && !String.isBlank((String) faultMessage)) {
            throw new AgentKernelException.OutcomeUnknownException(
                'Flow "' + flowApiName + '" reported a fault: ' + StandardToolSupport.bound((String) faultMessage, 500)
            );
        }
        if (outputs.returnsRecords) {
            return recordResponse(interview, outputs.names);
        }
        Map<String, Object> values = new Map<String, Object>();
        for (String name : outputs.names) {
            Object value = requiredVariableValue(interview, name);
            if (value instanceof SObject || value instanceof List<SObject>) {
                throw new AgentKernelException.OutcomeUnknownException('A flow output returned records that its metadata did not declare.');
            }
            if (value != null) {
                values.put(name, value);
            }
        }
        Object payload = values.isEmpty() ? (Object) new Map<String, Object>{ 'flowCompleted' => true } : (Object) values;
        String outputJson;
        try {
            outputJson = JSON.serialize(payload);
        } catch (Exception unserializable) {
            throw new AgentKernelException.OutcomeUnknownException('The flow output could not be serialized after execution.');
        }
        return StandardToolSupport.success(outputJson);
    }

    public List<String> validateConfiguration(AgentKernelModels.ToolConfiguration configuration) {
        try {
            outputVariables(checkedDefinition(StandardToolSupport.configuration(configuration == null ? null : configuration.implementationConfiguration)));
            return new List<String>();
        } catch (Exception invalid) {
            return StandardToolSupport.problems(invalid);
        }
    }

    /** The inputs are the active version's input variables, read on each run, so a Flow change reaches the model without a save. */
    public AgentKernelModels.ToolAuthoring describe(AgentKernelModels.ToolConfiguration configuration) {
        AgentKernelModels.ToolAuthoring authoring = new AgentKernelModels.ToolAuthoring();
        authoring.settings.add(
            new AgentKernelModels.ToolSetting(
                'flowApiName',
                'Flow',
                'flow',
                true,
                'The active autolaunched Flow the agent runs. Its input variables are the agent\'s inputs.'
            )
        );
        authoring.settings.add(
            new AgentKernelModels.ToolSetting(
                'allowSystemContext',
                'Allow System Context',
                'boolean',
                true,
                'Started by an agent, the Flow runs with system access to objects and fields. Check this after you audit what it can read and change.'
            )
        );
        try {
            Map<String, Object> config = StandardToolSupport.configuration(configuration == null ? null : configuration.implementationConfiguration);
            String flowApiName = StandardToolSupport.requiredConfig(config, 'flowApiName', 'flowApiName');
            if (!Pattern.matches('^[A-Za-z][A-Za-z0-9_]*$', flowApiName)) {
                throw StandardToolSupport.permanent('flowApiName must be a valid autolaunched flow API name.');
            }
            authoring.inputSchema = StandardToolSchemas.flowInputs(activeDefinition(flowApiName));
        } catch (Exception notYetBuildable) {
            authoring.problem = notYetBuildable.getMessage();
        }
        return authoring;
    }

    /**
     * An active autolaunched flow. Started from Apex, every autolaunched flow
     * runs with system access to objects and fields, Default Mode included,
     * so it can reach data the agent's user cannot. It runs only after the
     * operator audits it and sets allowSystemContext to true.
     */
    private static FlowDefinitionView checkedDefinition(Map<String, Object> config) {
        String flowApiName = StandardToolSupport.requiredConfig(config, 'flowApiName', 'flowApiName');
        if (!Pattern.matches('^[A-Za-z][A-Za-z0-9_]*$', flowApiName)) {
            throw StandardToolSupport.permanent('flowApiName must be a valid autolaunched flow API name.');
        }
        FlowDefinitionView definition = activeDefinition(flowApiName);
        if (config.get('allowSystemContext') != true) {
            throw StandardToolSupport.permanent(
                'Flow "' +
                    flowApiName +
                    '" runs with system access to objects and fields when an agent starts it. ' +
                    'Audit what it can read and change, then set allowSystemContext to true.'
            );
        }
        return definition;
    }

    private static FlowDefinitionView activeDefinition(String flowApiName) {
        List<FlowDefinitionView> definitions;
        try {
            // Flow metadata visibility can require elevation; business data
            // still runs as the execution principal inside the interview.
            definitions = [
                SELECT ApiName, ActiveVersionId, ProcessType
                FROM FlowDefinitionView
                WHERE ApiName = :flowApiName AND NamespacePrefix = NULL
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        } catch (Exception metadataUnavailable) {
            throw StandardToolSupport.permanent('Flow metadata is unavailable; execution was blocked.');
        }
        if (definitions.isEmpty()) {
            throw StandardToolSupport.permanent('Flow "' + flowApiName + '" was not found. Verify the flow API name.');
        }
        FlowDefinitionView definition = definitions[0];
        if (definition.ActiveVersionId == null) {
            throw StandardToolSupport.permanent('Flow "' + flowApiName + '" has no active version. Activate the flow in Flow Builder.');
        }
        if (definition.ProcessType != 'AutoLaunchedFlow') {
            throw StandardToolSupport.permanent('Flow "' + flowApiName + '" is not autolaunched. Only autolaunched flows can run as tools.');
        }
        return definition;
    }

    private class FlowOutputs {
        List<String> names = new List<String>();
        Boolean returnsRecords = false;
    }

    private static FlowOutputs outputVariables(FlowDefinitionView definition) {
        Map<String, Boolean> recordByName = new Map<String, Boolean>();
        try {
            for (FlowVariableView variable : [
                SELECT ApiName, DataType
                FROM FlowVariableView
                WHERE FlowVersionViewId = :definition.ActiveVersionId AND IsOutput = TRUE
                WITH SYSTEM_MODE
            ]) {
                recordByName.put(variable.ApiName, variable.DataType == 'SObject');
            }
        } catch (Exception metadataUnavailable) {
            throw StandardToolSupport.permanent('Flow output metadata is unavailable; execution was blocked.');
        }
        FlowOutputs outputs = new FlowOutputs();
        outputs.names.addAll(recordByName.keySet());
        outputs.returnsRecords = returnsRecords(definition.ApiName, recordByName);
        return outputs;
    }

    /** Record outputs take Core's structured protection path, which cannot also carry scalar outputs. */
    @TestVisible
    private static Boolean returnsRecords(String flowApiName, Map<String, Boolean> recordByName) {
        Set<Boolean> kinds = new Set<Boolean>(recordByName.values());
        if (kinds.size() > 1) {
            throw StandardToolSupport.permanent(
                'Flow "' + flowApiName + '" returns both record and non-record output variables. Return only records or only non-record values.'
            );
        }
        return kinds.contains(true);
    }

    private static AgentKernelModels.ToolResponse recordResponse(Flow.Interview interview, List<String> names) {
        Map<String, List<SObject>> recordSets = new Map<String, List<SObject>>();
        for (String name : names) {
            Object value = requiredVariableValue(interview, name);
            List<SObject> records = new List<SObject>();
            if (value instanceof List<SObject>) {
                records.addAll((List<SObject>) value);
            } else if (value instanceof SObject) {
                records.add((SObject) value);
            } else if (value != null) {
                throw new AgentKernelException.OutcomeUnknownException('A record flow output returned a non-record value.');
            }
            recordSets.put(name, records);
        }
        AgentKernelModels.ToolResponse response = new AgentKernelModels.ToolResponse();
        response.isSuccess = true;
        response.outcomeUnknown = false;
        response.recordSets = recordSets;
        return response;
    }

    /**
     * The flow runs as the execution user and may change any record it is
     * given, so an attended run checks the person's edit access on each record
     * Id among the inputs. A no-op on unattended runs.
     */
    @TestVisible
    private static void assertRequesterCanEditInputs(AgentKernelModels.ExecutionPrincipal principal, Map<String, Object> flowParams) {
        if (principal == null || principal.attendedByUserId == null) {
            return;
        }
        for (Object value : flowParams.values()) {
            List<Object> candidates = value instanceof List<Object> ? (List<Object>) value : new List<Object>{ value };
            for (Object candidate : candidates) {
                Id recordId = recordIdOf(candidate);
                if (recordId != null) {
                    ToolSecurity.assertRequesterCanEdit(principal, recordId, new Set<String>());
                }
            }
        }
    }

    private static Id recordIdOf(Object value) {
        if (!(value instanceof String)) {
            return null;
        }
        String text = ((String) value).trim();
        if ((text.length() != 15 && text.length() != 18) || !text.isAlphanumeric()) {
            return null;
        }
        try {
            Id recordId = Id.valueOf(text);
            return recordId.getSObjectType() == null ? null : recordId;
        } catch (Exception notAnId) {
            return null;
        }
    }

    private static Map<String, Object> serializableParams(Map<String, Object> input, String flowApiName) {
        Map<String, Object> params = new Map<String, Object>();
        for (String name : input.keySet()) {
            Object value = input.get(name);
            if (value == null) {
                params.put(name, null);
                continue;
            }
            try {
                JSON.serialize(value);
                params.put(name, value);
            } catch (Exception unserializable) {
                System.debug(
                    LoggingLevel.WARN,
                    '[StandardRunFlowTool] Flow "' + flowApiName + '" parameter "' + name + '" is not serializable; passing its string form.'
                );
                params.put(name, String.valueOf(value));
            }
        }
        return params;
    }

    private static Object variableValue(Flow.Interview interview, String name) {
        try {
            return interview.getVariableValue(name);
        } catch (Exception unreadable) {
            return null;
        }
    }

    private static Object requiredVariableValue(Flow.Interview interview, String name) {
        try {
            return interview.getVariableValue(name);
        } catch (Exception unreadable) {
            throw new AgentKernelException.OutcomeUnknownException('A declared flow output could not be read after execution.');
        }
    }
}
