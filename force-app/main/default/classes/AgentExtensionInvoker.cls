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
 * Establishes record sharing before extension constructors and methods run.
 * The worker retains system-mode ownership of lifecycle persistence.
 */
public with sharing class AgentExtensionInvoker {
    public static IModelProvider newModelProvider(AgentModel__mdt model) {
        return AgentConfigService.newModelProvider(model);
    }

    public static AgentKernelModels.ModelResponse invokeModel(IModelProvider provider, AgentKernelModels.ModelRequest request) {
        return provider.invoke(request);
    }

    public static ITool newTool(AgentTool__c tool) {
        return AgentConfigService.newTool(tool);
    }

    public static AgentKernelModels.ToolResponse executeTool(ITool tool, AgentKernelModels.ToolRequest request) {
        return tool.execute(request);
    }

    public static AgentKernelModels.ContextResponse provideContext(AgentContextProvider__c provider, AgentKernelModels.ContextRequest request) {
        return AgentConfigService.newContextProvider(provider).provide(request);
    }

    public static AgentKernelModels.ToolAuthorizationResponse evaluatePolicy(
        AgentDefinition__c definition,
        AgentKernelModels.ToolAuthorizationRequest request
    ) {
        return AgentConfigService.newToolAuthorizationPolicy(definition).evaluate(request);
    }
}
