/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * SemanticReference parses and resolves scoped semantic data references for graph execution nodes.
 * It enforces strict, unambiguous syntax for referencing input parameters, node outputs, context variables,
 * and result properties within a graph execution state. This class provides robust parsing, validation,
 * and value resolution for references such as:
 *   - {!input.parameter_name} (input parameters)
 *   - {!node.node_name.output.field_path} (node output data)
 *   - {!context.variable_name} (context variables)
 *   - {!result.property_name} (result properties, conditional edges only)
 *
 * Responsibilities:
 *   - Parse and validate semantic reference strings
 *   - Extract scope, source, and field path components
 *   - Resolve referenced values from a graph execution state map
 *   - Enforce strict syntax to prevent ambiguity in data resolution
 */
public class SemanticReference {
    public enum Scope {
        INPUT,
        NODE,
        CONTEXT,
        RESULT
    }

    // Reference components
    public Scope scope { get; private set; }
    public String source { get; private set; } // e.g., parameter_name, node_name, variable_name
    public String fieldPath { get; private set; }

    private SemanticReference(Scope scope, String source, String fieldPath) {
        this.scope = scope;
        this.source = source;
        this.fieldPath = fieldPath;
    }

    /**
     * Parses a semantic reference string into a structured SemanticReference object.
     * Validates syntax and extracts scope, source, and field path components.
     *
     * @param reference   The reference string to parse (e.g., '{!node.find_account.output.Id}').
     * @return            Parsed SemanticReference instance ready for value resolution.
     * @throws            GraphExecutionService.GraphConfigurationException if reference syntax is invalid.
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
                source = parts[1]; // The node_name
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
     * Resolves the actual value of this semantic reference from the graph execution state.
     * Navigates through the state map based on scope and field path to extract data.
     *
     * @param stateMap   The graph execution state containing all available data.
     * @return           The resolved value (any Object type) or null if not found.
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
                // Result scope contains current node execution results
                Map<String, Object> currentResult = (Map<String, Object>) stateMap.get('currentNodeResult');
                baseObject = currentResult?.get(this.source);
            }
        }

        // Navigate nested field path if specified
        if (String.isNotBlank(this.fieldPath)) {
            return getNestedValue(baseObject, this.fieldPath);
        }

        return baseObject;
    }

    /**
     * Parses the scope string into a Scope enum value.
     *
     * @param scopeStr   The scope string (e.g., 'input', 'node', etc.).
     * @return           The corresponding Scope enum value.
     * @throws           GraphExecutionService.GraphConfigurationException if invalid.
     */
    private static Scope parseScope(String scopeStr) {
        try {
            return Scope.valueOf(scopeStr.toUpperCase());
        } catch (Exception e) {
            throw new GraphExecutionService.GraphConfigurationException(
                'Invalid scope "' + scopeStr + '". Must be one of: input, node, context, result.'
            );
        }
    }

    /**
     * Resolves a context variable from the state map.
     *
     * @param variableName   The context variable name.
     * @param stateMap       The graph execution state map.
     * @return               The resolved value or null if not found.
     */
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

    /**
     * Navigates a nested field path within a data object (Map<String, Object>), returning the value at the path.
     * Supports both dot notation and array indexing (e.g., 'records[0].AccountId').
     *
     * @param data   The base object (may be a Map<String, Object> or null).
     * @param path   The dot-separated field path with optional array indexing (e.g., 'records[0].AccountId').
     * @return       The value at the nested path, or null if not found.
     */
    private Object getNestedValue(Object data, String path) {
        if (data == null || String.isBlank(path))
            return data;

        List<String> keys = path.split('\\.');
        Object currentValue = data;

        for (String key : keys) {
            // Check if this key contains array indexing syntax like 'records[0]'
            if (key.contains('[') && key.contains(']')) {
                String fieldName = key.substring(0, key.indexOf('['));
                String indexStr = key.substring(key.indexOf('[') + 1, key.indexOf(']'));

                try {
                    Integer arrayIndex = Integer.valueOf(indexStr);

                    // First navigate to the field
                    if (currentValue instanceof Map<String, Object>) {
                        currentValue = ((Map<String, Object>) currentValue).get(fieldName);
                        if (currentValue == null)
                            return null;
                    } else {
                        return null;
                    }

                    // Then handle array indexing
                    if (currentValue instanceof List<Object>) {
                        List<Object> listValue = (List<Object>) currentValue;
                        if (arrayIndex >= 0 && arrayIndex < listValue.size()) {
                            currentValue = listValue.get(arrayIndex);
                        } else {
                            return null; // Index out of bounds
                        }
                    } else {
                        return null; // Not a list, can't index
                    }
                } catch (Exception e) {
                    // Invalid array index format
                    return null;
                }
            } else {
                // Standard field navigation
                if (currentValue instanceof Map<String, Object>) {
                    currentValue = ((Map<String, Object>) currentValue).get(key);
                    if (currentValue == null)
                        return null;
                } else {
                    return null;
                }
            }
        }
        return currentValue;
    }
}
