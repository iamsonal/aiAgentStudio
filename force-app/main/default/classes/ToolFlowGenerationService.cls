/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Unified service for the Tool Flow Graph Editor LWC.
 * Provides editor bootstrap data (graph JSON, capabilities, staleness flag) and
 * all graph-mutation actions (generate via LLM, save).
 *
 * The LLM produces an entry array (tools available at the start of execution)
 * and a flow array (typed transition rules). Gateway types:
 *   sequential — one tool leads directly to the next
 *   parallel   — a tool fans out to multiple tools that all run
 *   exclusive  — a tool leads to a choice where the LLM picks exactly one branch
 */
public inherited sharing class ToolFlowGenerationService {
    private static final String LOG_PREFIX = '[ToolFlowGenSvc] ';

    // ── Inner types ──────────────────────────────────────────────────────────

    /** Data returned to the LWC on initial wire load. */
    public class FlowGraphEditorData {
        @AuraEnabled
        public String graphJson { get; set; }
        @AuraEnabled
        public String capabilitiesHash { get; set; }
        @AuraEnabled
        public String graphWarning { get; set; }
        @AuraEnabled
        public Boolean enableToolFlowGraph { get; set; }
        @AuraEnabled
        public Boolean parallelCallingEnabled { get; set; }
        @AuraEnabled
        public Boolean isStale { get; set; }
        @AuraEnabled
        public List<CapabilityInfo> capabilities { get; set; }

        public FlowGraphEditorData() {
            this.capabilities = new List<CapabilityInfo>();
            this.capabilitiesHash = null;
            this.graphWarning = null;
            this.enableToolFlowGraph = false;
            this.parallelCallingEnabled = false;
            this.isStale = false;
        }
    }

    /** Lightweight capability descriptor for the palette sidebar. */
    public class CapabilityInfo {
        @AuraEnabled
        public Id id { get; set; }
        @AuraEnabled
        public String capabilityName { get; set; }
        @AuraEnabled
        public String description { get; set; }
        @AuraEnabled
        public Boolean runAsynchronously { get; set; }
        @AuraEnabled
        public String exposureLevel { get; set; }

        public CapabilityInfo(AgentCapability__c cap) {
            this.id = cap.Id;
            this.capabilityName = cap.CapabilityName__c;
            this.description = cap.Description__c;
            this.runAsynchronously = cap.RunAsynchronously__c;
            this.exposureLevel = cap.ExposureLevel__c;
        }
    }

    /** Result envelope returned by generateGraph. */
    public class GenerationResult {
        @AuraEnabled
        public Boolean success { get; set; }
        @AuraEnabled
        public String graphJson { get; set; }
        @AuraEnabled
        public String errorMessage { get; set; }
        @AuraEnabled
        public List<String> warnings { get; set; }

        public GenerationResult() {
            this.warnings = new List<String>();
        }
    }

    // ── AuraEnabled methods ──────────────────────────────────────────────────

    /**
     * @description Returns all data needed to bootstrap the flow graph editor:
     * current graph JSON, capability list, feature flags, and staleness state.
     * Cacheable so the LWC wire adapter can refresh on recordId change.
     *
     * @param agentDefId The ID of the AIAgentDefinition__c record.
     * @return FlowGraphEditorData
     */
    @AuraEnabled(cacheable=true)
    public static FlowGraphEditorData getFlowGraphEditorData(Id agentDefId) {
        FlowGraphEditorData data = new FlowGraphEditorData();
        if (agentDefId == null)
            return data;

        List<AIAgentDefinition__c> agentDefs = [
            SELECT Id, ToolFlowGraph__c, ToolFlowGraphWarning__c, EnableToolFlowGraph__c, EnableParallelToolCalling__c
            FROM AIAgentDefinition__c
            WHERE Id = :agentDefId
            LIMIT 1
        ];
        if (agentDefs.isEmpty())
            return data;

        AIAgentDefinition__c agentDef = agentDefs[0];
        data.graphJson = agentDef.ToolFlowGraph__c;
        data.graphWarning = agentDef.ToolFlowGraphWarning__c;
        data.enableToolFlowGraph = agentDef.EnableToolFlowGraph__c == true;
        data.parallelCallingEnabled = agentDef.EnableParallelToolCalling__c == true;

        List<AgentCapability__c> capabilities = AIAgentConfigService.getCapabilitiesByAgentId(agentDefId);
        List<AgentCapability__c> externalCapabilities = filterExternalCapabilities(capabilities);
        data.capabilitiesHash = ToolFlowGraphService.generateCapabilitiesHash(externalCapabilities);
        for (AgentCapability__c cap : capabilities) {
            data.capabilities.add(new CapabilityInfo(cap));
        }

        if (String.isNotBlank(agentDef.ToolFlowGraph__c)) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(agentDef.ToolFlowGraph__c);
                String storedHash = parsed.containsKey('capabilitiesHash') ? String.valueOf(parsed.get('capabilitiesHash')) : null;
                data.isStale = ToolFlowGraphService.isGraphStale(data.capabilitiesHash, storedHash);
            } catch (Exception e) {
                data.isStale = true;
                System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Error checking staleness: ' + e.getMessage());
            }
        }

        return data;
    }

    /**
     * @description Generates a Tool Flow Graph for an agent using LLM analysis.
     *
     * @param agentDefId The ID of the AIAgentDefinition__c record.
     * @return GenerationResult containing the graph JSON or error information.
     */
    @AuraEnabled
    public static GenerationResult generateGraph(Id agentDefId) {
        GenerationResult result = new GenerationResult();

        try {
            AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefId);
            List<AgentCapability__c> capabilities = AIAgentConfigService.getCapabilitiesByAgentId(agentDefId);
            List<AgentCapability__c> externalCaps = filterExternalCapabilities(capabilities);

            if (externalCaps.isEmpty()) {
                result.success = false;
                result.errorMessage = 'No capabilities configured for this agent. Add capabilities before generating a flow graph.';
                return result;
            }

            if (externalCaps.size() == 1) {
                result.success = true;
                result.graphJson = buildSingleToolGraph(externalCaps);
                result.warnings.add('Agent has only one capability. A single-node entry-only graph was generated.');
                return result;
            }

            LLMConfiguration__c llmConfig = AIAgentConfigService.getLLMConfiguration(agentDef.LLMConfiguration__c);
            String analysisPrompt = buildAnalysisPrompt(agentDef, externalCaps);
            String llmResponse = callLLMForAnalysis(llmConfig, analysisPrompt);

            result = parseLLMResponse(llmResponse, externalCaps, capabilities, agentDef.EnableParallelToolCalling__c == true);

            if (result.success && String.isNotBlank(result.graphJson)) {
                // Inject capabilities hash for staleness detection
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(result.graphJson);
                parsed.put('capabilitiesHash', ToolFlowGraphService.generateCapabilitiesHash(externalCaps));
                parsed.put('generatedAt', String.valueOf(Datetime.now()));
                result.graphJson = JSON.serialize(parsed);
            }

            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Graph generation failed: ' + e.getMessage() + '\n' + e.getStackTraceString());
            result.success = false;
            result.errorMessage = 'Failed to generate flow graph: ' + e.getMessage();
            return result;
        }
    }

    /**
     * @description Saves a generated or manually edited graph to the agent definition.
     *
     * @param agentDefId The ID of the AIAgentDefinition__c record.
     * @param graphJson  The graph JSON to save.
     * @return True if save was successful.
     */
    @AuraEnabled
    public static Boolean saveGraph(Id agentDefId, String graphJson) {
        try {
            List<String> warnings = new List<String>();

            if (String.isNotBlank(graphJson)) {
                AIAgentDefinition__c agentDef = AIAgentConfigService.getAgentDefinition(agentDefId);
                List<AgentCapability__c> capabilities = AIAgentConfigService.getCapabilitiesByAgentId(agentDefId);

                try {
                    ToolFlowGraphService.FlowGraph graph = ToolFlowGraphService.parseGraph(graphJson);
                    validateGraphStructure(graph, capabilities, agentDef.EnableParallelToolCalling__c == true);

                    // Check for staleness
                    Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(graphJson);
                    String storedHash = parsed.containsKey('capabilitiesHash') ? String.valueOf(parsed.get('capabilitiesHash')) : null;
                    String currentHash = ToolFlowGraphService.generateCapabilitiesHash(filterExternalCapabilities(capabilities));

                    if (String.isBlank(storedHash)) {
                        warnings.add('Flow graph is missing capabilitiesHash. Consider regenerating the graph.');
                    } else if (ToolFlowGraphService.isGraphStale(currentHash, storedHash)) {
                        warnings.add(
                            'Flow graph appears stale — capabilities have changed since the graph was generated. Regenerate to reflect current tools.'
                        );
                    }
                } catch (Exception parseEx) {
                    throw new AuraHandledException('Graph JSON could not be validated: ' + parseEx.getMessage());
                }
            }

            AIAgentDefinition__c agentDefToUpdate = new AIAgentDefinition__c(Id = agentDefId, ToolFlowGraph__c = graphJson, ToolFlowGraphWarning__c = null);
            update agentDefToUpdate;

            System.debug(LoggingLevel.INFO, LOG_PREFIX + 'Saved flow graph for agent: ' + agentDefId + ' with ' + warnings.size() + ' warning(s)');
            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, LOG_PREFIX + 'Failed to save graph: ' + e.getMessage());
            throw new AuraHandledException('Failed to save flow graph: ' + e.getMessage());
        }
    }

    // ── Private helpers ──────────────────────────────────────────────────────

    private static String buildAnalysisPrompt(AIAgentDefinition__c agentDef, List<AgentCapability__c> capabilities) {
        // Agent context — include name/purpose for domain awareness; omit instructions
        // by default, but include a bounded summary because some agents encode real
        // sequencing constraints there (for example, "once assigned, notify customer").
        String prompt = 'Agent: ' + agentDef.Name + '\n';
        if (String.isNotBlank(agentDef.Description__c)) {
            prompt += 'Purpose: ' + agentDef.Description__c + '\n';
        }
        prompt += 'Parallel Tool Calling Enabled: ' + (agentDef.EnableParallelToolCalling__c == true ? 'true' : 'false') + '\n';
        if (String.isNotBlank(agentDef.InstructionsPrompt__c)) {
            String instructionSummary = agentDef.InstructionsPrompt__c.trim();
            if (instructionSummary.length() > 700) {
                instructionSummary = instructionSummary.substring(0, 700) + '...';
            }
            prompt += 'Instructions Summary: ' + instructionSummary + '\n';
        }
        prompt += '\nTools:\n';
        for (AgentCapability__c cap : capabilities) {
            String exec = cap.RunAsynchronously__c == true ? ' [async]' : '';
            String toolDesc = String.isNotBlank(cap.Description__c) ? cap.Description__c : '';
            prompt += '- ' + cap.CapabilityName__c + exec + ': ' + toolDesc + '\n';
        }

        prompt += '\nOutput ONLY valid JSON matching this exact schema (no markdown, no explanation):\n';
        prompt += '{\n';
        prompt += '  "version": "3.0",\n';
        prompt += '  "entry": ["REAL_TOOL_NAME_FROM_LIST"],\n';
        prompt += '  "flow": [\n';
        prompt += '    {"fromTools":["REAL_TOOL_NAME_FROM_LIST"],"type":"sequential","toTools":["ANOTHER_REAL_TOOL_NAME_FROM_LIST"]},\n';
        prompt += '    {"fromTools":["REAL_TOOL_NAME_FROM_LIST"],"type":"parallel","toTools":["REAL_TOOL_NAME_FROM_LIST","REAL_TOOL_NAME_FROM_LIST"]},\n';
        prompt += '    {"fromTools":["REAL_TOOL_NAME_FROM_LIST","REAL_TOOL_NAME_FROM_LIST"],"type":"sequential","toTools":["REAL_TOOL_NAME_FROM_LIST"]},\n';
        prompt += '    {"fromTools":["REAL_TOOL_NAME_FROM_LIST"],"type":"exclusive","toTools":["REAL_TOOL_NAME_FROM_LIST","REAL_TOOL_NAME_FROM_LIST"],\n';
        prompt += '     "conditions":{"REAL_TOOL_NAME_FROM_LIST":"Positive outcome","REAL_TOOL_NAME_FROM_LIST":"Negative outcome"}}\n';
        prompt += '  ]\n';
        prompt += '}\n\n';

        prompt += 'Rules:\n';
        prompt += '  · "type" is required on every rule: sequential | parallel | exclusive\n';
        prompt += '  · Every tool name in entry/fromTools/toTools must EXACTLY match one of the tools listed above.\n';
        prompt += '  · Placeholder names like tool_a, tool_b, tool_c, REAL_TOOL_NAME_FROM_LIST, or ANOTHER_REAL_TOOL_NAME_FROM_LIST are ALWAYS invalid.\n';
        prompt += '  · NEVER create two separate sequential rules from the same source tool — consolidate into one parallel rule with all targets in toTools.\n';
        prompt += '  · Use parallel when multiple tools can run at the same time after a predecessor.\n';
        prompt += '  · If Parallel Tool Calling Enabled is false, DO NOT output any parallel rules.\n';
        prompt += '  · A join gate (multiple fromTools converging) must use type "sequential", not "parallel". "parallel" means fan-OUT only.\n';
        prompt += '  · Use exclusive ONLY when the agent must choose exactly one tool from the toTools list based on data.\n';
        prompt += '  · NEVER put the same downstream tool under both parallel and exclusive paths from the same source.\n';
        prompt += '  · "conditions" maps toTool names → short label (≤5 words, no "When"/"If")\n';
        prompt += '  · Model ONLY tool execution paths. Do not create branches for agent behaviours that involve no tool (e.g. stopping, replying, rejecting). Those are not flow graph nodes.\n';
        prompt += '  · Every tool must appear in entry or be reachable; no cycles\n';

        return prompt;
    }

    private static void validateGraphStructure(ToolFlowGraphService.FlowGraph graph, List<AgentCapability__c> capabilities, Boolean parallelCallingEnabled) {
        Set<String> validCapabilityNames = new Set<String>();
        for (AgentCapability__c capability : capabilities) {
            if (capability.ExposureLevel__c == 'External' && String.isNotBlank(capability.CapabilityName__c)) {
                validCapabilityNames.add(capability.CapabilityName__c);
            }
        }
        ToolFlowGraphService.validateGraphSemantics(graph, validCapabilityNames, parallelCallingEnabled);
    }

    private static String callLLMForAnalysis(LLMConfiguration__c llmConfig, String prompt) {
        ILLMProviderAdapter adapter = LLMInteractionService.getLLMProviderAdapter(llmConfig);

        List<Map<String, Object>> messages = new List<Map<String, Object>>();
        messages.add(
            new Map<String, Object>{
                'role' => 'system',
                'content' => 'You design Tool Flow Graphs — execution-order graphs for AI agent tools. ' +
                'Given an agent\'s purpose and tool list, produce a minimal, correct flow graph. ' +
                'Condition labels for exclusive branches must be ≤5 words, outcome-phrase style (no "When"/"If"). ' +
                'Respond with valid JSON only — no markdown, no commentary.'
            }
        );
        messages.add(new Map<String, Object>{ 'role' => 'user', 'content' => prompt });

        ProviderResult result = adapter.sendMessage(messages, null, llmConfig, null);

        if (result == null || String.isBlank(result.content)) {
            throw new AIAgentException('LLM returned empty response for flow graph generation.');
        }

        return result.content;
    }

    private static GenerationResult parseLLMResponse(
        String llmResponse,
        List<AgentCapability__c> externalCaps,
        List<AgentCapability__c> allCaps,
        Boolean parallelCallingEnabled
    ) {
        GenerationResult result = new GenerationResult();

        try {
            String jsonContent = extractJsonFromResponse(llmResponse);
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonContent);

            Set<String> validCapNames = new Set<String>();
            for (AgentCapability__c cap : externalCaps) {
                validCapNames.add(cap.CapabilityName__c);
            }
            Set<String> unknownToolNames = new Set<String>();

            // Validate and clean entry tools
            List<String> entry = new List<String>();
            if (parsed.containsKey('entry') && parsed.get('entry') instanceof List<Object>) {
                for (Object item : (List<Object>) parsed.get('entry')) {
                    String toolName = String.valueOf(item);
                    if (validCapNames.contains(toolName)) {
                        entry.add(toolName);
                    } else {
                        unknownToolNames.add(toolName);
                        result.warnings.add('LLM referenced unknown tool "' + toolName + '" in entry. Skipped.');
                    }
                }
            }

            // Validate and clean flow rules
            List<Map<String, Object>> flow = new List<Map<String, Object>>();
            if (parsed.containsKey('flow') && parsed.get('flow') instanceof List<Object>) {
                for (Object ruleObj : (List<Object>) parsed.get('flow')) {
                    if (!(ruleObj instanceof Map<String, Object>)) {
                        continue;
                    }
                    Map<String, Object> rule = (Map<String, Object>) ruleObj;

                    // Validate fromTools (string or array — LLM sometimes emits a bare string,
                    // or uses the old 'from'/'to' key names instead of 'fromTools'/'toTools')
                    Object fromRaw = rule.containsKey('fromTools') ? rule.get('fromTools') : rule.get('from');
                    List<String> fromList = new List<String>();
                    if (fromRaw instanceof String) {
                        if (validCapNames.contains((String) fromRaw)) {
                            fromList.add((String) fromRaw);
                        } else {
                            unknownToolNames.add(String.valueOf(fromRaw));
                            result.warnings.add('LLM referenced unknown tool "' + fromRaw + '" in fromTools. Rule skipped.');
                            continue;
                        }
                    } else if (fromRaw instanceof List<Object>) {
                        for (Object f : (List<Object>) fromRaw) {
                            String fname = String.valueOf(f);
                            if (validCapNames.contains(fname)) {
                                fromList.add(fname);
                            } else {
                                unknownToolNames.add(fname);
                                result.warnings.add('LLM referenced unknown tool "' + fname + '" in fromTools array. Skipped.');
                            }
                        }
                        if (fromList.isEmpty()) {
                            continue;
                        }
                    } else {
                        continue;
                    }

                    // Validate toTools (same fallback for 'to' key)
                    Object toRaw = rule.containsKey('toTools') ? rule.get('toTools') : rule.get('to');
                    List<String> toList = new List<String>();
                    if (toRaw instanceof List<Object>) {
                        for (Object t : (List<Object>) toRaw) {
                            String tname = String.valueOf(t);
                            if (validCapNames.contains(tname)) {
                                toList.add(tname);
                            } else {
                                unknownToolNames.add(tname);
                                result.warnings.add('LLM referenced unknown tool "' + tname + '" in toTools. Skipped.');
                            }
                        }
                    } else if (toRaw instanceof String) {
                        String tname = (String) toRaw;
                        if (validCapNames.contains(tname))
                            toList.add(tname);
                        else
                            unknownToolNames.add(tname);
                    }
                    if (toList.isEmpty()) {
                        continue;
                    }

                    // Only the three canonical types are valid; any LLM hallucination (e.g. "join") → sequential
                    String ruleType = rule.containsKey('type') ? String.valueOf(rule.get('type')).toLowerCase().trim() : 'sequential';
                    if (!new Set<String>{ 'sequential', 'parallel', 'exclusive' }.contains(ruleType)) {
                        result.warnings.add('Unknown rule type "' + ruleType + '" normalised to "sequential".');
                        ruleType = 'sequential';
                    }

                    // Always store with fromTools/toTools (canonical field names)
                    Map<String, Object> cleanedRule = new Map<String, Object>{ 'fromTools' => fromList, 'type' => ruleType, 'toTools' => toList };

                    // For exclusive rules, preserve the LLM-generated conditions map.
                    // Only keep entries whose keys are valid, known tool names so hallucinated
                    // tool names can never sneak through via the conditions object.
                    if (ruleType == 'exclusive' && rule.containsKey('conditions') && rule.get('conditions') instanceof Map<String, Object>) {
                        Map<String, Object> rawConditions = (Map<String, Object>) rule.get('conditions');
                        Map<String, Object> cleanedConditions = new Map<String, Object>();
                        for (String condKey : rawConditions.keySet()) {
                            if (validCapNames.contains(condKey) && rawConditions.get(condKey) instanceof String) {
                                String condText = ((String) rawConditions.get(condKey)).trim();
                                if (String.isNotBlank(condText)) {
                                    cleanedConditions.put(condKey, condText);
                                }
                            }
                        }
                        if (!cleanedConditions.isEmpty()) {
                            cleanedRule.put('conditions', cleanedConditions);
                        }
                    }

                    flow.add(cleanedRule);
                }
            }

            Map<String, Object> outputGraph = new Map<String, Object>{ 'version' => '3.0', 'entry' => entry, 'flow' => flow };

            ToolFlowGraphService.FlowGraph validatedGraph = ToolFlowGraphService.parseGraph(JSON.serialize(outputGraph));
            ToolFlowGraphService.validateGraphSemantics(validatedGraph, validCapNames, parallelCallingEnabled);

            result.success = true;
            result.graphJson = JSON.serialize(outputGraph);
            return result;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Failed to parse LLM response: ' + e.getMessage());
            result.success = false;
            result.errorMessage = buildGenerationErrorMessage(e.getMessage(), llmResponse, externalCaps);
            return result;
        }
    }

    private static String buildSingleToolGraph(List<AgentCapability__c> externalCaps) {
        Map<String, Object> graph = new Map<String, Object>{
            'version' => '3.0',
            'capabilitiesHash' => ToolFlowGraphService.generateCapabilitiesHash(externalCaps),
            'generatedAt' => String.valueOf(Datetime.now()),
            'entry' => new List<String>{ externalCaps[0].CapabilityName__c },
            'flow' => new List<Object>()
        };
        return JSON.serialize(graph);
    }

    private static List<AgentCapability__c> filterExternalCapabilities(List<AgentCapability__c> capabilities) {
        List<AgentCapability__c> externalCaps = new List<AgentCapability__c>();
        if (capabilities == null) {
            return externalCaps;
        }
        for (AgentCapability__c cap : capabilities) {
            if (cap.ExposureLevel__c == 'External') {
                externalCaps.add(cap);
            }
        }
        return externalCaps;
    }

    private static String extractJsonFromResponse(String response) {
        if (String.isBlank(response)) {
            throw new AIAgentException('Empty response from LLM.');
        }

        // Try to extract from markdown code block
        Integer codeStart = response.indexOf('```json');
        if (codeStart >= 0) {
            Integer contentStart = response.indexOf('\n', codeStart) + 1;
            Integer codeEnd = response.indexOf('```', codeStart + 7);
            if (contentStart > 0 && codeEnd > contentStart) {
                return response.substring(contentStart, codeEnd).trim();
            }
        }

        // Try raw code block
        Integer rawStart = response.indexOf('```');
        if (rawStart >= 0) {
            Integer contentStart = response.indexOf('\n', rawStart) + 1;
            Integer rawEnd = response.indexOf('```', rawStart + 3);
            if (contentStart > 0 && rawEnd > contentStart) {
                return response.substring(contentStart, rawEnd).trim();
            }
        }

        // Try to extract first { ... } object
        Integer objStart = response.indexOf('{');
        Integer objEnd = response.lastIndexOf('}');
        if (objStart >= 0 && objEnd > objStart) {
            return response.substring(objStart, objEnd + 1).trim();
        }

        return response.trim();
    }

    @TestVisible
    private static String buildGenerationErrorMessage(String baseMessage, String llmResponse, List<AgentCapability__c> externalCaps) {
        String message = 'Failed to parse LLM response as Tool Flow Graph: ' + baseMessage;
        if (looksLikeSchemaPlaceholderResponse(llmResponse)) {
            List<String> validNames = new List<String>();
            for (AgentCapability__c cap : externalCaps) {
                if (String.isNotBlank(cap.CapabilityName__c)) {
                    validNames.add(cap.CapabilityName__c);
                }
            }
            validNames.sort();
            if (validNames.size() > 6) {
                List<String> truncatedNames = new List<String>();
                for (Integer i = 0; i < 6; i++) {
                    truncatedNames.add(validNames[i]);
                }
                validNames = truncatedNames;
            }
            message +=
                ' The LLM appears to have echoed schema placeholder names like "tool_a" instead of using this agent\'s real capability names.' +
                (validNames.isEmpty() ? '' : ' Valid tools include: ' + String.join(validNames, ', ') + '.');
        }
        return message;
    }

    @TestVisible
    private static Boolean looksLikeSchemaPlaceholderResponse(String response) {
        if (String.isBlank(response)) {
            return false;
        }
        String normalized = response.toLowerCase();
        return normalized.contains('"tool_a"') ||
            normalized.contains('"tool_b"') ||
            normalized.contains('"tool_c"') ||
            normalized.contains('real_tool_name_from_list') ||
            normalized.contains('another_real_tool_name_from_list');
    }
}
