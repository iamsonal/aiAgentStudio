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
 * Runs a tool class's IToolAuthoring description. A class that implements
 * it describes its settings, and builds the tool's inputs from them unless
 * the admin writes them. ToolSchemaService calls it on each run and applies
 * the admin's edits.
 *
 * Descriptions are extension code: each runs inside an execution boundary
 * and must stay query-only. Each tool type and configuration is described
 * at most once per transaction.
 */
public inherited sharing class ToolAuthoringService {
    private static Map<String, AgentKernelModels.ToolAuthoring> described = new Map<String, AgentKernelModels.ToolAuthoring>();

    /** True when the tool's class builds its inputs from its settings, so its Input Schema must be blank. */
    public static Boolean buildsInputs(AgentTool__c tool) {
        AgentKernelModels.ToolAuthoring authoring = describe(tool);
        return authoring != null && authoring.inputsWrittenByAdmin != true;
    }

    /**
     * The schema a draft tool would have now, with its edits applied, so an
     * authoring screen can show it before saving. Reads and writes no
     * record. Null when the tool type does not build its inputs. Throws the
     * problem when the settings cannot build a schema yet.
     */
    public static String previewSchema(String toolType, String implementationConfiguration) {
        AgentTool__c draft = new AgentTool__c(ToolType__c = toolType, ImplementationConfiguration__c = implementationConfiguration);
        if (!buildsInputs(draft)) {
            return null;
        }
        ToolSchemaService.Resolution resolution = ToolSchemaService.effectiveSchema(draft);
        if (resolution.problem != null) {
            throw new AgentKernelException.PermanentException(resolution.problem);
        }
        return resolution.schema;
    }

    /**
     * The tool's description, or null when its class does not implement
     * IToolAuthoring. A description that fails, or that writes, calls out, or
     * starts async work, comes back with a problem instead of a schema.
     */
    public static AgentKernelModels.ToolAuthoring describe(AgentTool__c tool) {
        String key = tool == null
            ? ''
            : String.valueOf(tool.ToolType__c) + '\n' + String.valueOf(tool.DeveloperName__c) + '\n' + String.valueOf(tool.ImplementationConfiguration__c);
        if (!described.containsKey(key)) {
            described.put(key, describeNow(tool));
        }
        return described.get(key);
    }

    /** Lets a test act as a later transaction. */
    public static void forgetDescribed() {
        described.clear();
    }

    private static AgentKernelModels.ToolAuthoring describeNow(AgentTool__c tool) {
        IToolAuthoring authoring = authoring(tool);
        if (authoring == null) {
            return null;
        }
        AgentKernelModels.ToolConfiguration configuration = new AgentKernelModels.ToolConfiguration();
        configuration.toolName = tool.DeveloperName__c;
        configuration.implementationConfiguration = tool.ImplementationConfiguration__c;
        AgentKernelModels.ToolAuthoring result;
        Exception failure;
        ExtensionExecutionGuard.Boundary boundary = ExtensionExecutionGuard.open();
        try {
            result = authoring.describe(configuration);
        } catch (Exception caughtFailure) {
            failure = caughtFailure;
        }
        ExtensionExecutionGuard.Result isolation = ExtensionExecutionGuard.close(boundary);
        if (isolation.performedDml || isolation.performedCallout || isolation.performedProhibitedAsync() || isolation.budgetExceeded) {
            return problem('Tool type ' + tool.ToolType__c + ' must describe its settings without changing records, calling out, or starting jobs.');
        }
        if (failure != null) {
            return problem(failure.getMessage());
        }
        if (result == null) {
            result = new AgentKernelModels.ToolAuthoring();
        }
        if (result.inputsWrittenByAdmin == true) {
            // The admin's Input Schema is the schema; a built one or a settings problem is not.
            result.inputSchema = null;
            result.problem = null;
        }
        return result;
    }

    private static IToolAuthoring authoring(AgentTool__c tool) {
        if (tool == null || AgentToolTypeService.toolType(tool) == null) {
            return null;
        }
        Object implementation;
        try {
            implementation = AgentConfigService.newTool(tool);
        } catch (Exception unavailable) {
            return null;
        }
        return implementation instanceof IToolAuthoring ? (IToolAuthoring) implementation : null;
    }

    private static AgentKernelModels.ToolAuthoring problem(String message) {
        AgentKernelModels.ToolAuthoring authoring = new AgentKernelModels.ToolAuthoring();
        authoring.problem = message;
        return authoring;
    }
}
