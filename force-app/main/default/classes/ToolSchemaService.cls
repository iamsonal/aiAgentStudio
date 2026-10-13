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
 * The input schema a tool has right now: the one the model is sent, and the
 * one every call is checked against. Every reader asks here, so within a
 * transaction the request and the checks use the same schema.
 *
 * A tool whose class implements IToolAuthoring builds its schema from its
 * settings and the org's current metadata, then the admin's edits
 * (inputOverrides) narrow it. Its Input Schema must be blank: a stored one
 * may hold narrowed values, so it is refused instead of ignored. Any other
 * tool, and one whose class says the admin writes its inputs, uses its
 * hand-written Input Schema.
 *
 * Each tool is resolved at most once per transaction. A later transaction
 * builds again, so picklist, field, and Flow changes reach the next run.
 */
public inherited sharing class ToolSchemaService {
    public class Resolution {
        /** The schema to send and check against. Null when there is a problem. */
        public String schema;
        /** What the admin must fix before the tool can be used. */
        public String problem;
        /** True when the schema is built from the settings, false when it is hand-written. */
        public Boolean built;
        /** The tool's description of its settings, when its class describes them. */
        public AgentKernelModels.ToolAuthoring authoring;
    }

    private static Map<String, Resolution> resolved = new Map<String, Resolution>();

    public static Resolution effectiveSchema(AgentTool__c tool) {
        String key = cacheKey(tool);
        if (!resolved.containsKey(key)) {
            resolved.put(key, resolve(tool));
        }
        return resolved.get(key);
    }

    /** Lets a test act as a later transaction. */
    @TestVisible
    private static void forgetResolved() {
        resolved.clear();
        ToolAuthoringService.forgetDescribed();
    }

    private static Resolution resolve(AgentTool__c tool) {
        Resolution result = new Resolution();
        result.authoring = ToolAuthoringService.describe(tool);
        result.built = result.authoring != null && result.authoring.inputsWrittenByAdmin != true;
        String toolName = String.isBlank(tool.DeveloperName__c) ? 'This tool' : 'Tool ' + tool.DeveloperName__c;
        if (!result.built) {
            if (String.isBlank(tool.InputSchema__c)) {
                result.problem = toolName + ' needs an Input Schema, because its tool type does not build its inputs.';
            } else {
                result.schema = tool.InputSchema__c;
            }
            return result;
        }
        if (!String.isBlank(tool.InputSchema__c)) {
            result.problem = toolName + ' builds its inputs from its settings, so its Input Schema must be blank. Clear the Input Schema.';
            return result;
        }
        if (result.authoring.problem != null) {
            result.problem = result.authoring.problem;
            return result;
        }
        if (String.isBlank(result.authoring.inputSchema)) {
            result.problem = 'Tool type ' + tool.ToolType__c + ' built no input schema.';
            return result;
        }
        try {
            ToolInputOverrides.Applied applied = ToolInputOverrides.apply(result.authoring.inputSchema, tool.ImplementationConfiguration__c);
            if (applied.problem != null) {
                result.problem = applied.problem;
                return result;
            }
            ToolJsonSchemaValidator.validateSchema(applied.schema, 'Tool input schema');
            result.schema = applied.schema;
        } catch (Exception invalid) {
            result.problem = invalid.getMessage();
        }
        return result;
    }

    private static String cacheKey(AgentTool__c tool) {
        return String.valueOf(tool.Id) +
            '|' +
            CanonicalJson.sha256(
                String.join(
                    new List<String>{
                        String.valueOf(tool.DeveloperName__c),
                        String.valueOf(tool.ToolType__c),
                        String.valueOf(tool.ImplementationConfiguration__c),
                        String.valueOf(tool.InputSchema__c)
                    },
                    '\n'
                )
            );
    }
}
