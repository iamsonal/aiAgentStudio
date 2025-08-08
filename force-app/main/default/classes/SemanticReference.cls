/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Parses and resolves explicit, scoped semantic data references for graph nodes.
 *              This version enforces a strict syntax to eliminate ambiguity.
 * @syntax
 *  - {!input.parameter_name}
 *  - {!node.node_name.output.field_path}
 *  - {!context.variable_name}
 *  - {!result.property_name} (For Conditional Edges only)
 */
public class SemanticReference {
    public enum Scope {
        INPUT,
        NODE,
        CONTEXT,
        RESULT
    }

    public Scope scope { get; private set; }
    public String source { get; private set; }
    public String fieldPath { get; private set; }

    private SemanticReference(Scope scope, String source, String fieldPath) {
        this.scope = scope;
        this.source = source;
        this.fieldPath = fieldPath;
    }

    /**
     * @description Parses a reference string into a structured SemanticReference object.
     * @param reference The string to parse, e.g., '{!node.find_account.output.Id}'.
     * @return A SemanticReference instance.
     * @throws GraphExecutionService.GraphConfigurationException if the syntax is invalid.
     */
    public static SemanticReference parse(String reference) {
        if (String.isBlank(reference) || !reference.startsWith('{!') || !reference.endsWith('}')) {
            throw new GraphExecutionService.GraphConfigurationException(
                'Invalid reference format. Must start with "{!" and end with "}". Reference: ' + reference
            );
        }

        String content = reference.substring(2, reference.length() - 1);
        List<String> parts = content.split('\\.');
        if (parts.isEmpty() || String.isBlank(parts[0])) {
            throw new GraphExecutionService.GraphConfigurationException('Invalid reference format. Reference cannot be empty.');
        }

        Scope parsedScope = parseScope(parts[0]);
        String source = null;
        String fieldPath = null;

        switch on parsedScope {
            when NODE {
                if (parts.size() < 3 || parts[2] != 'output') {
                    throw new GraphExecutionService.GraphConfigurationException(
                        'Invalid "node" reference format. Must be "{!node.node_name.output...}". Reference: ' + reference
                    );
                }
                source = parts[1];
                if (parts.size() > 3) {
                    List<String> fieldPathParts = new List<String>();
                    for (Integer i = 3; i < parts.size(); i++) {
                        fieldPathParts.add(parts[i]);
                    }
                    fieldPath = String.join(fieldPathParts, '.');
                }
            }
            when INPUT, CONTEXT, RESULT {
                if (parts.size() < 2) {
                    throw new GraphExecutionService.GraphConfigurationException(
                        'Invalid "' + parts[0] + '" reference format. Must have at least a source. Reference: ' + reference
                    );
                }
                source = parts[1];
                if (parts.size() > 2) {
                    List<String> fieldPathParts = new List<String>();
                    for (Integer i = 2; i < parts.size(); i++) {
                        fieldPathParts.add(parts[i]);
                    }
                    fieldPath = String.join(fieldPathParts, '.');
                }
            }
        }

        return new SemanticReference(parsedScope, source, fieldPath);
    }

    /**
     * @description Resolves the value of this reference from the graph's state map.
     * @param stateMap The untyped map representation of the current GraphRunState.
     * @return The resolved value, which can be any Object type or null.
     */
    public Object resolveValue(Map<String, Object> stateMap) {
        Object baseObject = null;
        switch on this.scope {
            when INPUT {
                Map<String, Object> inputs = (Map<String, Object>) stateMap.get('inputs');
                baseObject = inputs?.get(this.source);
            }
            when NODE {
                Map<String, Object> nodes = (Map<String, Object>) stateMap.get('nodes');
                Map<String, Object> nodeState = (Map<String, Object>) nodes?.get(this.source);
                baseObject = nodeState?.get('output');
            }
            when CONTEXT {
                baseObject = resolveContextValue(this.source, stateMap);
            }
            when RESULT {
                Map<String, Object> currentResult = (Map<String, Object>) stateMap.get('currentNodeResult');
                baseObject = currentResult?.get(this.source);
            }
        }

        if (String.isNotBlank(this.fieldPath)) {
            return getNestedValue(baseObject, this.fieldPath);
        }

        return baseObject;
    }

    private static Scope parseScope(String scopeStr) {
        try {
            return Scope.valueOf(scopeStr.toUpperCase());
        } catch (Exception e) {
            throw new GraphExecutionService.GraphConfigurationException(
                'Invalid scope "' + scopeStr + '". Must be one of: input, node, context, result.'
            );
        }
    }

    private Object resolveContextValue(String variableName, Map<String, Object> stateMap) {
        switch on variableName {
            when 'userId' {
                return stateMap.get('originalUserId');
            }
            when 'originalUserId' {
                return stateMap.get('originalUserId');
            }
            when 'executionUserId' {
                return stateMap.get('executionUserId');
            }
            when 'chatSessionId' {
                return stateMap.get('chatSessionId');
            }
            when 'turnIdentifier' {
                return stateMap.get('turnIdentifier');
            }
            when 'currentTurnCount' {
                return stateMap.get('currentTurnCount');
            }
            when 'agentDefinitionId' {
                return stateMap.get('agentDefinitionId');
            }
            when else {
                return null;
            }
        }
    }

    private Object getNestedValue(Object data, String path) {
        if (data == null || String.isBlank(path))
            return data;

        List<String> keys = path.split('\\.');
        Object currentValue = data;

        for (String key : keys) {
            if (currentValue instanceof Map<String, Object>) {
                currentValue = ((Map<String, Object>) currentValue).get(key);
                if (currentValue == null)
                    return null;
            } else {
                return null;
            }
        }
        return currentValue;
    }
}
