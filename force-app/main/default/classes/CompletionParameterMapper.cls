/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * CompletionParameterMapper provides declarative, template-based parameter mapping
 * for completion capabilities. This class enables deterministic transformation of
 * completion context (summary, trigger metadata) into capability parameters without
 * requiring LLM calls.
 *
 * Responsibilities:
 *   - Parse JSON mapping templates with variable interpolation syntax
 *   - Extract values from completion context using dot notation paths
 *   - Substitute template variables with actual values
 *   - Provide fast, deterministic, cost-free parameter transformation
 *
 * Template Syntax:
 *   - Variables: {{variableName}} or {{path.to.nested.value}}
 *   - Available context: summary, executionId, agentDefinitionId, executionType, triggerSource, triggerMetadata.*
 *   - Example: {"toAddresses": ["{{triggerMetadata.fromAddress}}"], "body": "{{summary}}"}
 *
 * This is the architecturally correct approach for completion parameter mapping,
 * using LLM only as a fallback for truly complex cases.
 */
public class CompletionParameterMapper {
    private static final String LOG_PREFIX = '[CompletionParameterMapper] ';

    /**
     * Default mapping templates by agent type.
     * These are used when CompletionParameterMapping__c is not configured.
     */
    private static final Map<String, String> DEFAULT_MAPPINGS_BY_TYPE = new Map<String, String>{
        'Email' => '{"toAddresses": ["{{triggerMetadata.fromAddress}}"], "subject": "Re: {{triggerMetadata.emailSubject}}", "plainTextBody": "{{summary}}"}'
        // Future agent types can be added here:
        // 'SMS' => '{"phoneNumber": "{{triggerMetadata.fromNumber}}", "messageBody": "{{summary}}"}',
        // 'Slack' => '{"channelId": "{{triggerMetadata.channelId}}", "message": "{{summary}}"}',
        // etc.
    };

    /**
     * Exception thrown when parameter mapping fails.
     */
    public class MappingException extends Exception {
    }

    /**
     * Gets the default mapping template for a given agent type.
     * Returns null if no default exists for that type.
     *
     * @param agentType The agent type (e.g., 'Email', 'SMS', 'Slack')
     * @return The default JSON mapping template, or null if none exists
     */
    public static String getDefaultMapping(String agentType) {
        if (String.isBlank(agentType)) {
            return null;
        }
        return DEFAULT_MAPPINGS_BY_TYPE.get(agentType);
    }

    /**
     * Applies a declarative mapping template to completion context.
     *
     * @param mappingTemplate JSON template with {{variable}} placeholders
     * @param completionContext Map containing available variables (summary, triggerMetadata, etc.)
     * @return JSON string with variables replaced by actual values
     * @throws MappingException if template parsing or interpolation fails
     */
    public static String applyMapping(String mappingTemplate, Map<String, Object> completionContext) {
        String logPrefix = LOG_PREFIX + '[applyMapping] ';

        if (String.isBlank(mappingTemplate)) {
            throw new MappingException('Mapping template cannot be blank');
        }

        if (completionContext == null || completionContext.isEmpty()) {
            throw new MappingException('Completion context cannot be null or empty');
        }

        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Applying declarative mapping template');
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Template: ' + mappingTemplate.abbreviate(200));

            // Parse template as JSON to validate structure
            Object templateObj = JSON.deserializeUntyped(mappingTemplate);

            // Perform recursive variable substitution
            Object result = substituteVariables(templateObj, completionContext, logPrefix);

            // Serialize back to JSON
            String mappedJson = JSON.serialize(result);

            System.debug(LoggingLevel.INFO, logPrefix + 'Mapping completed successfully');
            System.debug(LoggingLevel.DEBUG, logPrefix + 'Result: ' + mappedJson.abbreviate(200));

            return mappedJson;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Mapping failed: ' + e.getMessage());
            throw new MappingException('Failed to apply mapping template: ' + e.getMessage());
        }
    }

    /**
     * Recursively substitutes template variables in the object tree.
     *
     * @param obj The object to process (can be String, Map, List, or primitive)
     * @param context The completion context containing variable values
     * @param logPrefix Logging prefix
     * @return Object with variables replaced
     */
    @SuppressWarnings('PMD.CyclomaticComplexity')
    private static Object substituteVariables(Object obj, Map<String, Object> context, String logPrefix) {
        if (obj == null) {
            return null;
        }

        // Handle strings - perform variable substitution
        if (obj instanceof String) {
            return interpolateString((String) obj, context, logPrefix);
        }

        // Handle maps - recurse into values
        // Note: After JSON deserialization, maps are Map<String, Object>
        try {
            Map<String, Object> testMap = (Map<String, Object>) obj;
            Map<String, Object> result = new Map<String, Object>();

            for (String key : testMap.keySet()) {
                result.put(key, substituteVariables(testMap.get(key), context, logPrefix));
            }

            return result;
        } catch (TypeException e) {
            // Not a map, continue to next type check
        }

        // Handle lists - recurse into elements
        // Note: After JSON deserialization, lists are List<Object>
        try {
            List<Object> testList = (List<Object>) obj;
            List<Object> result = new List<Object>();

            for (Object item : testList) {
                result.add(substituteVariables(item, context, logPrefix));
            }

            return result;
        } catch (TypeException e) {
            // Not a list, must be a primitive
        }

        // Return primitives as-is (numbers, booleans, etc.)
        return obj;
    }

    /**
     * Interpolates variables in a string template.
     * Supports syntax: {{variableName}} or {{path.to.nested.value}}
     *
     * @param template The string template with {{variable}} placeholders
     * @param context The completion context
     * @param logPrefix Logging prefix
     * @return String with variables replaced
     */
    private static String interpolateString(String template, Map<String, Object> context, String logPrefix) {
        if (String.isBlank(template)) {
            return template;
        }

        // Match pattern: {{variableName}} or {{path.to.value}}
        Pattern variablePattern = Pattern.compile('\\{\\{([^}]+)\\}\\}');
        Matcher matcher = variablePattern.matcher(template);

        String result = template;

        while (matcher.find()) {
            String fullMatch = matcher.group(0); // e.g., "{{triggerMetadata.fromAddress}}"
            String variablePath = matcher.group(1).trim(); // e.g., "triggerMetadata.fromAddress"

            // Extract value from context using path
            Object value = extractValueFromPath(variablePath, context, logPrefix);

            // Convert value to string
            String valueStr = value != null ? String.valueOf(value) : '';

            // Replace placeholder with actual value
            result = result.replace(fullMatch, valueStr);

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Replaced ' + fullMatch + ' with: ' + valueStr);
        }

        return result;
    }

    /**
     * Extracts a value from the context using dot notation path.
     * Example: "triggerMetadata.fromAddress" extracts context.get('triggerMetadata').get('fromAddress')
     *
     * @param path Dot-separated path (e.g., "triggerMetadata.fromAddress")
     * @param context The completion context
     * @param logPrefix Logging prefix
     * @return The extracted value, or null if not found
     */
    private static Object extractValueFromPath(String path, Map<String, Object> context, String logPrefix) {
        if (String.isBlank(path)) {
            return null;
        }

        List<String> parts = path.split('\\.');
        Object current = context;

        for (String part : parts) {
            if (current == null) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Path traversal stopped at null: ' + path);
                return null;
            }

            if (current instanceof Map<String, Object>) {
                Map<String, Object> currentMap = (Map<String, Object>) current;
                current = currentMap.get(part);
            } else {
                System.debug(LoggingLevel.WARN, logPrefix + 'Cannot traverse non-map object at path: ' + path);
                return null;
            }
        }

        return current;
    }

    /**
     * Builds the standard completion context map from execution data.
     *
     * @param summary The LLM-generated summary
     * @param execution The AgentExecution__c record with metadata
     * @return Map containing all available context variables
     */
    public static Map<String, Object> buildCompletionContext(String summary, AgentExecution__c execution) {
        String logPrefix = LOG_PREFIX + '[buildContext] ';

        // Parse trigger payload (contains email metadata, etc.)
        // Note: TriggerPayload__c is where EmailOrchestrator stores the email metadata
        Map<String, Object> triggerMetadata = new Map<String, Object>();
        if (String.isNotBlank(execution.TriggerPayload__c)) {
            try {
                triggerMetadata = (Map<String, Object>) JSON.deserializeUntyped(execution.TriggerPayload__c);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Failed to parse trigger payload: ' + e.getMessage());
            }
        }

        // Build standard context
        Map<String, Object> context = new Map<String, Object>{
            'summary' => summary,
            'executionId' => String.valueOf(execution.Id),
            'executionType' => execution.ExecutionType__c,
            'triggerSource' => execution.TriggerSource__c,
            'triggerMetadata' => triggerMetadata
        };

        System.debug(LoggingLevel.DEBUG, logPrefix + 'Built completion context with ' + context.keySet().size() + ' root keys');
        return context;
    }
}

