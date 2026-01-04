/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Processes LLM responses that contain only textual content (no tool calls).
 * Orchestrates message persistence, context ledger updates, memory management,
 * and completion capability execution with declarative parameter mapping.
 *
 * Includes integrated parameter mapping capabilities for deterministic,
 * template-based transformation of completion context into capability parameters.
 */
public class ContentResponseHandler implements ILLMResponseHandler {
    /**
     * Exception thrown when completion capability invocation fails.
     */
    public class CompletionCapabilityException extends Exception {
    }

    /**
     * Exception thrown when parameter mapping fails.
     */
    public class MappingException extends Exception {
    }

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
     * Handles an LLM response containing only textual content (no tool calls).
     * Orchestrates message persistence, context ledger update, memory management, and error handling.
     *
     * @param context The orchestration context for the current LLM turn.
     * @return        OUTCOME_COMPLETED if successful, OUTCOME_FAILED if validation or persistence fails.
     */
    public String handle(OrchestrationContext context) {
        String logPrefix = context.logPrefix + '[ContentHandler] ';
        System.debug(
            LoggingLevel.INFO,
            logPrefix + 'Handling text-only LLM response for session: ' + context.executionId + ', turn: ' + context.turnIdentifier
        );

        // Use the shared decision step logger from the context
        AgentDecisionStepLogger decisionLogger = context.decisionLogger;

        LLMInteractionService.MessageData assistantData = context.llmResult.assistantMessageData;

        // Validate LLM response content before proceeding
        if (String.isBlank(assistantData?.content)) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Validation failed: LLM response content is empty.');

            // Log the error step
            decisionLogger.logError(
                'Empty LLM Response',
                'LLM returned empty successful response',
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                'LLM returned empty successful response',
                null,
                null
            );

            context.agentStateSvc.failTurn(
                context.executionId,
                context.turnIdentifier,
                'LLM returned empty successful response.',
                AIAgentConstants.ERR_CODE_LLM_CALL_FAILED,
                logPrefix
            );
            return OrchestrationService.OUTCOME_FAILED;
        }

        ActionOutcome completionOutcome = null;
        if (shouldInvokeCompletionCapability(context)) {
            completionOutcome = invokeCompletionCapability(context, assistantData.content, logPrefix);
        }

        // Persist the user message as the parent of the assistant's reply using ExecutionStep__c
        Id savedUserMessageId = null;
        if (context.userMessageData != null && String.isNotBlank(context.userMessageData.content)) {
            ExecutionStepService executionStepService = new ExecutionStepService();
            savedUserMessageId = executionStepService.createUserInputStep(
                context.executionId,
                context.userMessageData.content,
                context.turnIdentifier,
                context.currentTurnCount
            );
        }

        // Save assistant message with token usage data using ExecutionStep__c
        Id savedAssistantMessageId = null;
        if (String.isNotBlank(assistantData.content)) {
            ExecutionStepService executionStepService = new ExecutionStepService();
            savedAssistantMessageId = executionStepService.createAgentResponseStepWithTokens(
                context.executionId,
                assistantData.content,
                context.turnIdentifier,
                context.currentTurnCount,
                context.llmResult.providerResult.promptTokens,
                context.llmResult.providerResult.completionTokens,
                context.llmResult.providerResult.totalTokens,
                context.llmResult.providerResult.modelIdentifier,
                context.llmResult.providerResult.llmCalloutDurationMs
            );
        }

        // Log completion capability result if it was invoked
        if (completionOutcome != null) {
            logCompletionCapabilityResult(context, completionOutcome, completionOutcome.data, logPrefix);
        }

        // Commit the turn context to the ledger for traceability
        try {
            context.contextManagerSvc.commitExecutionTurnContext(context.executionId, context.currentTurnCount, context.currentPageRecordId, null);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Context ledger update failed: ' + e.getMessage());
        }

        // Invoke memory management completion hook if configured
        try {
            AIAgentDefinition__c agentConfig = AIAgentConfigService.getAgentDefinition(context.agentDefinitionId);
            if (String.isNotBlank(agentConfig.MemoryStrategy__c)) {
                LLMConfiguration__c llmConfig = AIAgentConfigService.getLLMConfiguration(agentConfig.LLMConfiguration__c);
                IMemoryManager memoryManager = ContextManagerService.getMemoryManager(agentConfig.MemoryStrategy__c);
                // Note: Memory manager will need to be updated to handle both execution models
                memoryManager.onTurnCompletion(context.executionId, agentConfig, llmConfig, logPrefix);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Memory management completion hook failed: ' + e.getMessage());
        }

        // Complete the turn successfully
        context.agentStateSvc.completeTurnSuccessfully(context.executionId, context.turnIdentifier, savedAssistantMessageId, logPrefix);
        return OrchestrationService.OUTCOME_COMPLETED;
    }

    /**
     * Determines if a completion capability should be invoked for this execution.
     * Checks if the agent definition has a completion capability configured and
     * ensures it's not a conversational agent (which displays responses in UI).
     *
     * @param context The orchestration context for the current turn.
     * @return        True if completion capability should be invoked, false otherwise.
     */
    private Boolean shouldInvokeCompletionCapability(OrchestrationContext context) {
        try {
            // Query agent definition to check for completion capability
            AIAgentDefinition__c agentDef = [
                SELECT CompletionCapability__c, AgentType__c
                FROM AIAgentDefinition__c
                WHERE Id = :context.agentDefinitionId
                LIMIT 1
            ];

            // Don't invoke for conversational agents (they show response in UI)
            if (agentDef.AgentType__c == 'Conversational') {
                System.debug(LoggingLevel.INFO, context.logPrefix + '[CompletionCheck] Skipping completion capability for conversational agent');
                return false;
            }

            // Check if completion capability is configured
            return String.isNotBlank(agentDef.CompletionCapability__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, context.logPrefix + '[CompletionCheck] Error checking completion capability: ' + e.getMessage());
            return false;
        }
    }

    /**
     * Invokes the configured completion capability using declarative mapping.
     *
     * Strategy:
     * 1. Check if CompletionParameterMapping__c is configured (custom admin mapping)
     * 2. If not, check for hardcoded default mapping by AgentType__c
     * 3. If neither exists, throw an error (no LLM fallback)
     *
     * This approach provides:
     * - Performance: Declarative mapping is instant (no API calls)
     * - Cost: Declarative mapping is free
     * - Reliability: 100% deterministic, no hallucination risk
     * - Maintainability: Clear, testable transformation logic
     *
     * @param context      The orchestration context for the current turn.
     * @param summary      The final LLM-generated summary to pass to the completion capability.
     * @param logPrefix    Logging prefix for debug output.
     * @return             ActionOutcome representing the result of the completion capability execution.
     */
    private ActionOutcome invokeCompletionCapability(OrchestrationContext context, String summary, String logPrefix) {
        String completionLogPrefix = logPrefix + '[CompletionCapability] ';

        try {
            // 1. Query agent definition with completion configuration
            AIAgentDefinition__c agentDef = [
                SELECT CompletionCapability__c, CompletionParameterMapping__c, AgentType__c
                FROM AIAgentDefinition__c
                WHERE Id = :context.agentDefinitionId
                LIMIT 1
            ];

            // 2. Query the completion capability record
            AgentCapability__c capability = [
                SELECT
                    Id,
                    CapabilityName__c,
                    Description__c,
                    Parameters__c,
                    ImplementationType__c,
                    ImplementationDetail__c,
                    StandardActionType__c,
                    BackendConfiguration__c,
                    FailFastOnError__c,
                    RunAsynchronously__c,
                    HITLMode__c,
                    ExposureLevel__c
                FROM AgentCapability__c
                WHERE Id = :agentDef.CompletionCapability__c
                LIMIT 1
            ];

            System.debug(LoggingLevel.INFO, completionLogPrefix + 'Invoking completion capability: ' + capability.CapabilityName__c);

            // 3. Determine execution strategy: Custom Mapping → Default Mapping → Error
            String toolArgs;
            String mappingTemplate = null;

            // Check for custom admin-provided mapping
            if (String.isNotBlank(agentDef.CompletionParameterMapping__c)) {
                mappingTemplate = agentDef.CompletionParameterMapping__c;
                System.debug(LoggingLevel.INFO, completionLogPrefix + 'Using custom declarative mapping');
            } else {
                // Check for hardcoded default mapping by agent type
                mappingTemplate = getDefaultMapping(agentDef.AgentType__c);
                if (String.isNotBlank(mappingTemplate)) {
                    System.debug(LoggingLevel.INFO, completionLogPrefix + 'Using default declarative mapping for agent type: ' + agentDef.AgentType__c);
                } else {
                    // No mapping available - this is a configuration error
                    String errorMsg =
                        'No completion parameter mapping found. ' +
                        'Either configure CompletionParameterMapping__c or add a default mapping for agent type: ' +
                        agentDef.AgentType__c;
                    System.debug(LoggingLevel.ERROR, completionLogPrefix + errorMsg);
                    throw new CompletionCapabilityException(errorMsg);
                }
            }

            // Execute declarative mapping
            System.debug(LoggingLevel.INFO, completionLogPrefix + 'Executing declarative parameter mapping');
            toolArgs = executeDeclarativeMapping(context, summary, mappingTemplate, completionLogPrefix);

            // 4. Build ActionContext for capability execution
            ActionContext actionContext = new ActionContext(
                context.executionId,
                context.originalUserId,
                context.executionUserId,
                context.currentPageRecordId, // relatedRecordId
                context.agentDefinitionId,
                capability.Id, // capabilityId
                null, // implementationDetail
                context.turnIdentifier,
                context.currentTurnCount,
                'Completion' // executionType
            );

            // 5. Execute capability using CapabilityExecutionService
            ActionOutcome outcome = context.actionExecSvc.executeSingleAction(capability, toolArgs, actionContext);

            System.debug(LoggingLevel.INFO, completionLogPrefix + 'Completion capability executed. Success: ' + outcome.isSuccess);
            return outcome;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, completionLogPrefix + 'Completion capability failed: ' + e.getMessage() + '\n' + e.getStackTraceString());

            // Don't let completion failure crash the main flow
            ActionOutcome errorOutcome = ActionOutcome.failure(
                AIAgentConstants.ERR_CODE_COMPLETION_CAPABILITY_FAILED,
                'Completion capability execution failed: ' + e.getMessage()
            );
            return errorOutcome;
        }
    }

    /**
     * Executes declarative parameter mapping using CompletionParameterMapper.
     * Fast, deterministic, and cost-free.
     *
     * @param context         The orchestration context
     * @param summary         The LLM summary
     * @param mappingTemplate The JSON template with {{variable}} placeholders
     * @param logPrefix       Logging prefix
     * @return                JSON string with mapped parameters
     */
    private String executeDeclarativeMapping(OrchestrationContext context, String summary, String mappingTemplate, String logPrefix) {
        String mapLogPrefix = logPrefix + '[DeclarativeMapping] ';

        try {
            // Query execution for trigger payload (contains email metadata, etc.)
            AgentExecution__c execution = [
                SELECT TriggerPayload__c, ExecutionType__c, TriggerSource__c
                FROM AgentExecution__c
                WHERE Id = :context.executionId
                LIMIT 1
            ];

            // Build completion context
            Map<String, Object> completionContext = buildCompletionContext(summary, execution);

            // Apply mapping template
            String mappedJson = applyMapping(mappingTemplate, completionContext);

            System.debug(LoggingLevel.INFO, mapLogPrefix + 'Declarative mapping completed successfully');
            return mappedJson;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, mapLogPrefix + 'Declarative mapping failed: ' + e.getMessage());
            throw new CompletionCapabilityException('Declarative mapping failed: ' + e.getMessage());
        }
    }

    /**
     * Logs the result of the completion capability execution as an ExecutionStep__c record.
     *
     * @param context        The orchestration context for the current turn.
     * @param outcome        The ActionOutcome from the completion capability execution.
     * @param outcomeData    The outcome data that may contain capability details.
     * @param logPrefix      Logging prefix for debug output.
     */
    private void logCompletionCapabilityResult(OrchestrationContext context, ActionOutcome outcome, Object outcomeData, String logPrefix) {
        String resultLogPrefix = logPrefix + '[LogCompletion] ';

        try {
            ExecutionStepService executionStepService = new ExecutionStepService();

            String resultContent = outcome.isSuccess ? 'Completion capability executed successfully' : 'Completion capability failed: ' + outcome.errorMessage;

            // Build metadata for the completion step
            Map<String, Object> stepMetadata = new Map<String, Object>{ 'success' => outcome.isSuccess, 'errorCode' => outcome.errorCode };

            executionStepService.createStep(
                context.executionId,
                'ToolResult',
                'Tool',
                resultContent,
                'Text',
                context.turnIdentifier,
                context.currentTurnCount,
                null, // toolCallId
                null, // toolName
                null, // toolArguments
                outcome.data != null ? JSON.serialize(outcome.data) : null,
                JSON.serialize(stepMetadata),
                null, // promptTokens
                null, // completionTokens
                null, // totalTokens
                null, // modelIdentifier
                null, // llmCalloutDurationMs
                false, // isInternal
                null, // isAsyncToolExecution
                null // capabilityId
            );

            System.debug(LoggingLevel.INFO, resultLogPrefix + 'Logged completion capability result');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, resultLogPrefix + 'Failed to log completion result: ' + e.getMessage());
        }
    }

    // ===================================================================================
    // PARAMETER MAPPING - Merged from CompletionParameterMapper
    // ===================================================================================

    /**
     * Gets the default mapping template for a given agent type.
     * Returns null if no default exists for that type.
     *
     * @param agentType The agent type (e.g., 'Email', 'SMS', 'Slack')
     * @return The default JSON mapping template, or null if none exists
     */
    @TestVisible
    private static String getDefaultMapping(String agentType) {
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
    @TestVisible
    private static String applyMapping(String mappingTemplate, Map<String, Object> completionContext) {
        String logPrefix = '[applyMapping] ';

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
    @TestVisible
    private static Map<String, Object> buildCompletionContext(String summary, AgentExecution__c execution) {
        String logPrefix = '[buildContext] ';

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
