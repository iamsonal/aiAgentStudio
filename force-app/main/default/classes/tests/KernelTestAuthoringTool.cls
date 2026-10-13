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
 * KernelTestTool whose Input Schema follows from its settings: one string
 * input per name in "inputs". "misbehave" makes describe write a record or
 * throw, so tests can check Core's boundary.
 */
@IsTest
public with sharing class KernelTestAuthoringTool implements ITool, IToolAuthoring {
    private final KernelTestTool delegate = new KernelTestTool();
    /** How many times any instance described its settings, so tests can see the per-transaction cache. */
    public static Integer describeCount = 0;
    /** When set, describe reports this problem, as when a field the tool lists was deleted after the tool was saved. */
    public static String problemOnNextRun;
    /** When set, every input offers only these values, as a picklist does. */
    public static List<String> offeredValues;
    /** When true, the tool describes only its settings and the admin writes its inputs, as Call API does. */
    public static Boolean inputsWrittenByAdmin = false;

    public List<String> validateConfiguration(AgentKernelModels.ToolConfiguration configuration) {
        return delegate.validateConfiguration(configuration);
    }

    public AgentKernelModels.ToolResponse execute(AgentKernelModels.ToolRequest request) {
        return delegate.execute(request);
    }

    public AgentKernelModels.ToolAuthoring describe(AgentKernelModels.ToolConfiguration configuration) {
        describeCount++;
        Map<String, Object> config = String.isBlank(configuration.implementationConfiguration)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(configuration.implementationConfiguration);
        if (config.get('misbehave') == 'write') {
            insert new Account(Name = 'Written while describing');
        }
        if (config.get('misbehave') == 'throw') {
            throw new IllegalArgumentException('Name at least one input.');
        }
        AgentKernelModels.ToolAuthoring authoring = new AgentKernelModels.ToolAuthoring();
        authoring.inputsWrittenByAdmin = inputsWrittenByAdmin;
        if (problemOnNextRun != null) {
            authoring.problem = problemOnNextRun;
            return authoring;
        }
        authoring.settings.add(new AgentKernelModels.ToolSetting('inputs', 'Inputs', 'json', true, 'The inputs the agent fills in, as a JSON list of names.'));
        if (!(config.get('inputs') instanceof List<Object>)) {
            authoring.problem = 'List the inputs in inputs.';
            return authoring;
        }
        Map<String, Object> properties = new Map<String, Object>();
        for (Object name : (List<Object>) config.get('inputs')) {
            Map<String, Object> property = new Map<String, Object>{ 'type' => 'string' };
            if (offeredValues != null) {
                property.put('enum', offeredValues);
            }
            properties.put(String.valueOf(name), property);
        }
        authoring.inputSchema = JSON.serialize(new Map<String, Object>{ 'type' => 'object', 'properties' => properties, 'additionalProperties' => false });
        return authoring;
    }
}
