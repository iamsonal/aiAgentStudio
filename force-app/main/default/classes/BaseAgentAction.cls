/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * BaseAgentAction is the abstract base class for all agent actions in the AI Agent Framework.
 * Responsibilities:
 *   - Provides a comprehensive framework for implementing agent actions with minimal boilerplate
 *   - Features high-performance, cached schema-driven parameter processing using AIAgentConfigService
 *   - Automatic type coercion based on JSON Schema from AgentCapability__c.Parameters__c (no more SOQL per execution)
 *   - Supports standard JSON Schema types (string, integer, number, boolean) and formats (date, date-time, email, url, salesforce-id)
 *   - Validates required parameters as defined in the JSON Schema "required" array to prevent NullPointerExceptions
 *   - Differentiates between configuration issues (graceful fallback) and system errors (halt execution)
 *   - Includes security validation and standardized error handling
 *   - Requires subclasses to implement only the executeAction() method; all validation, security, and outcome formatting are handled by the base class
 *   - Surfaces operational and validation issues clearly via ActionOutcome and logging for maintainability
 *
 * This class is not intended to be instantiated directly. All custom agent actions should extend this class.
 * @implements IAgentAction
 */
public abstract class BaseAgentAction implements IAgentAction {
    // --- Common State (Accessible by Subclasses) ---
    protected ActionContext actionContext { get; private set; }
    protected Map<String, Object> parsedActionConfig { get; private set; }

    /**
     * Exception for errors during argument or configuration validation.
     * Includes an optional field name for more precise error reporting.
     */
    public virtual class ValidationException extends AIAgentException {
        public String fieldName; // Optional

        // Only define this constructor because it has an extra param
        public ValidationException(String message, String field) {
            super(message);
            this.fieldName = field;
        }

        public ValidationException(String message, String field, Exception cause) {
            super(message);
            this.fieldName = field;
            this.initCause(cause);
        }
    }

    public virtual override String toString() {
        // Use a simple static string to avoid recursion with getLogPrefixName()
        return 'ActionHandler (Context: ' + (actionContext != null ? 'Set' : 'Not Set') + ')';
    }

    /**
     * Exception specifically for security/permission denials.
     */
    public virtual class ActionSecurityException extends AIAgentException {
    }

    /**
     * Exception for when performAction implementation returns null.
     */
    private class ActionHandlerNullException extends AIAgentException {
    }

    // ============================================================================
    // --- Template Method ---
    // ============================================================================

    /**
     * Template method for executing an agent action.
     * Handles intelligent parameter processing, security validation, and outcome wrapping.
     * Subclasses only need to implement executeAction() with pure business logic.
     *
     * @param actionConfigurationJson The action configuration as a JSON string.
     * @param argumentsJson           The action arguments as a JSON string.
     * @param context                 The ActionContext for this execution.
     * @return                        The ActionOutcome for the action.
     */
    public virtual ActionOutcome execute(String actionConfigurationJson, String argumentsJson, ActionContext context) {
        if (context == null) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Internal error: Missing context. ActionContext was null');
        }
        this.actionContext = context;
        final String logPrefix = '[' + getLogPrefixName() + ' Cap:' + context.agentCapabilityId + '] ';
        ActionOutcome finalOutcome = null;
        Long startTime = System.currentTimeMillis();

        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Starting action execution with intelligent parameter processing');

            Map<String, Object> argsMap = String.isBlank(argumentsJson)
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);

            // Parse configuration (still needed for some actions)
            this.parseActionConfiguration(actionConfigurationJson, logPrefix);

            // Intelligent parameter processing
            ActionOutcome paramOutcome = intelligentParameterProcessing(argsMap, logPrefix);
            if (!paramOutcome.isSuccess) {
                return paramOutcome;
            }
            Map<String, Object> processedParams = (Map<String, Object>) paramOutcome.data;

            // Intelligent security checks
            ActionOutcome securityOutcome = performIntelligentSecurityChecks(processedParams, logPrefix);
            if (!securityOutcome.isSuccess) {
                return securityOutcome;
            }

            // Call the simplified action method
            ActionOutcome actionOutcome = executeAction(processedParams);

            if (actionOutcome == null) {
                throw new ActionHandlerNullException('Handler (' + getLogPrefixName() + ') returned null ActionOutcome.');
            }

            finalOutcome = actionOutcome;
        } catch (Exception ex) {
            finalOutcome = mapExceptionToOutcome(ex, logPrefix);
        }

        // Log action outcome with performance metrics
        Long duration = System.currentTimeMillis() - startTime;

        System.debug(LoggingLevel.INFO, logPrefix + 'Execution Finished. Success: ' + finalOutcome.isSuccess);
        return finalOutcome;
    }

    // ============================================================================
    // --- SINGLE METHOD APPROACH - Actions implement this ONE method only ---
    // ============================================================================

    /**
     * The only method actions need to implement!
     * Framework automatically handles parameter extraction, validation, security, and result wrapping.
     * Uses the ActionOutcome pattern for consistent success/failure handling without throwing business logic exceptions.
     *
     * @param params Validated and typed parameters extracted from JSON arguments.
     * @return       ActionOutcome object containing either success data or structured error information.
     */
    public abstract ActionOutcome executeAction(Map<String, Object> params);

    /**
     * Schema-driven parameter processing using the JSON Schema from AgentCapability__c.Parameters__c.
     * Replaces brittle naming convention-based type coercion with explicit schema-driven type conversion.
     * Also validates required parameters to prevent NullPointerExceptions in executeAction implementations.
     *
     * @param rawArgs   The raw argument map from JSON.
     * @param logPrefix The logging prefix for debug output.
     * @return          ActionOutcome containing the processed and typed parameter map or error information.
     */
    private ActionOutcome intelligentParameterProcessing(Map<String, Object> rawArgs, String logPrefix) {
        Map<String, Object> processed = new Map<String, Object>();

        // Get the parameter schema for this capability
        try {
            Map<String, Object> parameterSchema = getParameterSchema(logPrefix);
            Map<String, Object> schemaProperties = getSchemaProperties(parameterSchema);
            List<String> requiredParameters = getRequiredParameters(parameterSchema);

            // First, validate that all required parameters are present
            ActionOutcome validationResult = validateRequiredParameters(rawArgs, requiredParameters, logPrefix);
            if (!validationResult.isSuccess) {
                return validationResult;
            }

            // Process and coerce all provided parameters
            for (String paramName : rawArgs.keySet()) {
                Object value = rawArgs.get(paramName);

                // Skip null values, but note that required validation already passed
                // so any nulls here are for optional parameters
                if (value == null) {
                    continue;
                }

                // Use schema-driven type coercion
                try {
                    Object coercedValue = coerceValueBySchema(value, paramName, schemaProperties, logPrefix);
                    processed.put(paramName, coercedValue);
                } catch (ValidationException ve) {
                    return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ve.getMessage());
                }
            }

            return ActionOutcome.success(processed);
        } catch (ValidationException ve) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ve.getMessage());
        } catch (Exception e) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Parameter processing failed: ' + e.getMessage());
        }
    }

    /**
     * Retrieves and parses the JSON Schema from AgentCapability__c.Parameters__c for the current capability.
     * Uses cached AIAgentConfigService for optimal performance and differentiates between 'not found' and 'system error'.
     *
     * @param logPrefix The logging prefix for debug output.
     * @return          The parsed parameter schema as a Map, or empty schema if not found/invalid.
     * @throws ValidationException for system errors that should halt execution.
     */
    private Map<String, Object> getParameterSchema(String logPrefix) {
        try {
            // Use cached service instead of direct SOQL
            AgentCapability__c capability = AIAgentConfigService.getCapabilityById(actionContext.agentCapabilityId);

            if (capability == null) {
                // CRITICAL: Missing AgentCapability is a definite system/config error that should halt execution
                // If we got this far, the capability should definitely exist - this indicates a serious system issue
                String errorMsg =
                    'Critical system error: AgentCapability not found for ID: ' +
                    actionContext.agentCapabilityId +
                    '. This indicates a serious configuration or data integrity issue.';
                System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
                throw new ValidationException(errorMsg, null);
            }

            String parametersJson = capability.Parameters__c;
            if (String.isBlank(parametersJson)) {
                // RECOVERABLE: Blank Parameters__c is a configuration issue but action can proceed with default schema
                System.debug(
                    LoggingLevel.WARN,
                    logPrefix + 'Parameters__c is blank for capability "' + capability.CapabilityName__c + '", using default schema'
                );
                return getDefaultSchema();
            }

            // Parse the JSON schema
            Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(parametersJson);
            System.debug(
                LoggingLevel.DEBUG,
                logPrefix +
                    'Loaded parameter schema for "' +
                    capability.CapabilityName__c +
                    '" with ' +
                    (schema.containsKey('properties') ? ((Map<String, Object>) schema.get('properties')).size() : 0) +
                    ' properties'
            );
            return schema;
        } catch (AIAgentConfigService.ConfigurationException configEx) {
            // CRITICAL: System error from the config service - this is serious and should halt execution
            // Database errors, permission issues, etc. indicate system problems that can't be worked around
            String errorMsg = 'Critical system error loading AgentCapability configuration: ' + configEx.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
            throw new ValidationException(errorMsg, null, configEx);
        } catch (JSONException jsonEx) {
            // RECOVERABLE: Invalid JSON in Parameters__c field - configuration issue but action can proceed
            // Admin can fix the JSON later, action can work with default schema for now
            System.debug(
                LoggingLevel.ERROR,
                logPrefix + 'Invalid JSON in Parameters__c field: ' + jsonEx.getMessage() + '. Using default schema to allow action to proceed.'
            );
            return getDefaultSchema();
        } catch (Exception e) {
            // CRITICAL: Unexpected system error - should halt execution
            // Unknown errors could indicate serious system issues that shouldn't be masked
            String errorMsg = 'Unexpected system error loading parameter schema: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
            throw new ValidationException(errorMsg, null, e);
        }
    }

    /**
     * Extracts the properties section from a JSON Schema.
     *
     * @param schema The parsed JSON Schema.
     * @return       The properties map, or empty map if not found.
     */
    private Map<String, Object> getSchemaProperties(Map<String, Object> schema) {
        if (schema.containsKey('properties') && schema.get('properties') instanceof Map<String, Object>) {
            return (Map<String, Object>) schema.get('properties');
        }
        return new Map<String, Object>();
    }

    /**
     * Extracts the required parameters array from a JSON Schema.
     *
     * @param schema The parsed JSON Schema.
     * @return       List of required parameter names, or empty list if not found.
     */
    private List<String> getRequiredParameters(Map<String, Object> schema) {
        if (schema.containsKey('required') && schema.get('required') instanceof List<Object>) {
            List<Object> requiredList = (List<Object>) schema.get('required');
            List<String> requiredParams = new List<String>();
            for (Object param : requiredList) {
                if (param instanceof String) {
                    requiredParams.add((String) param);
                }
            }
            return requiredParams;
        }
        return new List<String>();
    }

    /**
     * Validates that all required parameters are present in the provided arguments.
     * Treats empty strings as missing values since LLMs sometimes send empty strings instead of omitting parameters.
     *
     * @param rawArgs            The raw argument map from JSON.
     * @param requiredParameters List of required parameter names from schema.
     * @param logPrefix          The logging prefix for debug output.
     * @return                   ActionOutcome indicating success or failure with missing parameter details.
     */
    private ActionOutcome validateRequiredParameters(Map<String, Object> rawArgs, List<String> requiredParameters, String logPrefix) {
        List<String> missingParams = new List<String>();

        for (String requiredParam : requiredParameters) {
            Object value = rawArgs.get(requiredParam);

            // Consider parameter missing if:
            // 1. Not present in the map
            // 2. Value is null
            // 3. Value is an empty string (common LLM behavior)
            if (!rawArgs.containsKey(requiredParam) || value == null || (value instanceof String && String.isBlank((String) value))) {
                missingParams.add(requiredParam);
            }
        }

        if (!missingParams.isEmpty()) {
            String missingParamsList = String.join(missingParams, ', ');
            String errorMessage = 'Missing required parameter' + (missingParams.size() > 1 ? 's' : '') + ': ' + missingParamsList;
            System.debug(LoggingLevel.WARN, logPrefix + errorMessage);

            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, errorMessage);
        }

        System.debug(LoggingLevel.DEBUG, logPrefix + 'All ' + requiredParameters.size() + ' required parameters validated successfully');
        return ActionOutcome.success();
    }

    /**
     * Coerces a parameter value based on its JSON Schema type definition using the unified TypeCoercionService.
     * Supports standard JSON Schema types and formats including date/date-time, and now includes recursive
     * support for complex data structures (arrays and objects).
     *
     * @param value            The raw parameter value.
     * @param paramName        The parameter name.
     * @param schemaProperties The schema properties map.
     * @param logPrefix        The logging prefix for debug output.
     * @return                 The coerced value.
     */
    private Object coerceValueBySchema(Object value, String paramName, Map<String, Object> schemaProperties, String logPrefix) {
        // If no schema property defined for this parameter, return as-is
        if (!schemaProperties.containsKey(paramName)) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'No schema definition for parameter "' + paramName + '", keeping original type');
            return value;
        }

        Map<String, Object> propertySchema = (Map<String, Object>) schemaProperties.get(paramName);
        String schemaType = (String) propertySchema.get('type');

        if (String.isBlank(schemaType)) {
            System.debug(LoggingLevel.DEBUG, logPrefix + 'No type specified in schema for parameter "' + paramName + '", keeping original type');
            return value;
        }

        try {
            switch on schemaType.toLowerCase() {
                when 'string' {
                    // Check for format hints for special string types
                    String format = (String) propertySchema.get('format');
                    if (format == 'salesforce-id' || format == 'id') {
                        return TypeCoercionService.coerceToId(value, paramName);
                    } else if (format == 'date') {
                        return TypeCoercionService.coerceToDate(value, paramName);
                    } else if (format == 'date-time' || format == 'datetime') {
                        return TypeCoercionService.coerceToDateTime(value, paramName);
                    } else if (format == 'email') {
                        // Email format - validate using centralized TypeCoercionService
                        return TypeCoercionService.coerceToEmailString(value, paramName);
                    } else if (format == 'url' || format == 'uri') {
                        // URL format - validate using centralized TypeCoercionService
                        return TypeCoercionService.coerceToUrlString(value, paramName);
                    }
                    return TypeCoercionService.coerceToString(value, paramName, null);
                }
                when 'integer' {
                    return TypeCoercionService.coerceToInteger(value, paramName);
                }
                when 'number' {
                    return TypeCoercionService.coerceToDecimal(value, paramName);
                }
                when 'boolean' {
                    return TypeCoercionService.coerceToBoolean(value, paramName);
                }
                when 'array' {
                    // NEW: Handle array type recursively using enhanced TypeCoercionService
                    Map<String, Object> itemsSchema = (Map<String, Object>) propertySchema.get('items');
                    if (itemsSchema == null) {
                        System.debug(
                            LoggingLevel.DEBUG,
                            logPrefix + 'No items schema defined for array parameter "' + paramName + '", keeping original array'
                        );
                        return value;
                    }
                    System.debug(
                        LoggingLevel.DEBUG,
                        logPrefix + 'Recursively processing array parameter "' + paramName + '" with items schema type: ' + itemsSchema.get('type')
                    );
                    return TypeCoercionService.coerceArrayBySchema(value, paramName, itemsSchema);
                }
                when 'object' {
                    // NEW: Handle object type recursively using enhanced TypeCoercionService
                    Map<String, Object> propertiesSubSchema = (Map<String, Object>) propertySchema.get('properties');
                    if (propertiesSubSchema == null) {
                        System.debug(
                            LoggingLevel.DEBUG,
                            logPrefix + 'No properties schema defined for object parameter "' + paramName + '", keeping original object'
                        );
                        return value;
                    }
                    System.debug(
                        LoggingLevel.DEBUG,
                        logPrefix +
                            'Recursively processing object parameter "' +
                            paramName +
                            '" with ' +
                            propertiesSubSchema.size() +
                            ' property schemas'
                    );
                    return TypeCoercionService.coerceObjectBySchema(value, paramName, propertiesSubSchema);
                }
                when else {
                    System.debug(
                        LoggingLevel.DEBUG,
                        logPrefix + 'Unsupported schema type "' + schemaType + '" for parameter "' + paramName + '", keeping original type'
                    );
                    return value;
                }
            }
        } catch (TypeCoercionService.TypeCoercionException e) {
            // Convert TypeCoercionService exceptions to ValidationException for consistency
            throw new ValidationException('Type coercion failed for parameter "' + paramName + '": ' + e.getMessage(), paramName, e);
        } catch (ValidationException e) {
            // Re-throw validation exceptions
            throw e;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                logPrefix + 'Failed to coerce parameter "' + paramName + '" to type "' + schemaType + '": ' + e.getMessage()
            );
            return value;
        }
    }

    /**
     * Returns a default empty JSON Schema structure.
     *
     * @return The default schema map.
     */
    private Map<String, Object> getDefaultSchema() {
        return new Map<String, Object>{ 'type' => 'object', 'properties' => new Map<String, Object>() };
    }

    /**
     * Performs comprehensive security validation by analyzing parameter patterns and action context.
     * Automatically detects required permissions based on action type and validates object access.
     *
     * @param params   The processed parameter map.
     * @param logPrefix The logging prefix for debug output.
     * @return         ActionOutcome indicating success or failure with security violation details.
     */
    private ActionOutcome performIntelligentSecurityChecks(Map<String, Object> params, String logPrefix) {
        try {
            for (String paramName : params.keySet()) {
                Object value = params.get(paramName);

                // Check ID parameters for object access
                if (value instanceof Id && (paramName.toLowerCase().endsWith('id') || paramName.toLowerCase().contains('recordid'))) {
                    Id recordId = (Id) value;
                    SObjectType objType = recordId.getSObjectType();

                    // Intelligent access type detection based on action name
                    String actionName = String.valueOf(this).toLowerCase();
                    System.AccessType accessType = System.AccessType.READABLE; // Default

                    if (actionName.contains('create')) {
                        accessType = System.AccessType.CREATABLE;
                    } else if (actionName.contains('update') || actionName.contains('edit')) {
                        accessType = System.AccessType.UPDATABLE;
                    } else if (actionName.contains('delete')) {
                        accessType = System.AccessType.UPDATABLE; // Use UPDATABLE for delete operations
                    }

                    SecurityUtils.checkObjectPermission(objType, accessType);
                }
            }
            return ActionOutcome.success();
        } catch (SecurityUtils.ActionSecurityException ase) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ase.getMessage());
        } catch (Exception e) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Security validation failed: ' + e.getMessage());
        }
    }

    // ============================================================================
    // --- Helper Methods ---
    // ============================================================================

    protected virtual String getLogPrefixName() {
        String className = String.valueOf(this);
        // Extract class name from toString() output like "ActionCreateRecord:..."
        if (className.contains(':')) {
            className = className.substring(0, className.indexOf(':'));
        }
        return className.replace('Action', '');
    }

    protected virtual void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        this.parsedActionConfig = new Map<String, Object>();
        if (String.isNotBlank(actionConfigurationJson)) {
            try {
                Object parsed = JSON.deserializeUntyped(actionConfigurationJson);
                if (parsed instanceof Map<String, Object>) {
                    this.parsedActionConfig = (Map<String, Object>) parsed;
                } else {
                    throw new ValidationException('ActionConfiguration JSON must be a JSON Object (Map).');
                }
            } catch (Exception e) {
                throw new ValidationException('Invalid ActionConfiguration JSON: ' + e.getMessage(), e);
            }
        }
    }

    // ============================================================================
    // --- Private: Exception Mapping ---
    // ============================================================================

    /**
     * Maps caught exceptions to ActionOutcome.
     *
     * @param ex       The caught exception.
     * @param logPrefix The logging prefix for debug output.
     * @return         The ActionOutcome representing the error.
     */
    private ActionOutcome mapExceptionToOutcome(Exception ex, String logPrefix) {
        System.debug(
            LoggingLevel.ERROR,
            logPrefix + 'Exception during action execution - Type: ' + ex.getTypeName() + ', Message: ' + ex.getMessage()
        );
        if (ex instanceof DmlException) {
            DmlException dmlEx = (DmlException) ex;
            String initialCode = dmlEx.getNumDml() > 0 ? dmlEx.getDmlStatusCode(0) : null;
            String firstDmlMsg = dmlEx.getNumDml() > 0 ? dmlEx.getDmlMessage(0) : ex.getMessage();
            String errorCode = mapStatusCodeToErrorCode(initialCode, AIAgentConstants.ERR_CODE_DML_ERROR);
            return ActionOutcome.failure(errorCode, 'DML failed: ' + firstDmlMsg);
        }
        // (Keep QueryException, CalloutException, LimitException checks)
        if (ex instanceof System.QueryException) {
            String msgLower = ex.getMessage().toLowerCase();
            String errCode = (msgLower.contains('security enforced') || msgLower.contains('insufficient access'))
                ? AIAgentConstants.ERR_CODE_PERMISSION_DENIED
                : AIAgentConstants.ERR_CODE_SOQL_ERROR;
            return ActionOutcome.failure(errCode, 'Query failed: ' + ex.getMessage());
        }
        if (ex instanceof System.CalloutException) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, 'External callout failed: ' + ex.getMessage());
        }
        if (ex instanceof System.LimitException) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SYSTEM_LIMIT, 'System limit exceeded: ' + ex.getMessage());
        }

        // --- Handle framework specific exceptions (Use base AIAgentException or check type name if needed) ---
        if (ex instanceof ValidationException) {
            ValidationException ve = (ValidationException) ex;
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, ve.getMessage());
        }
        if (ex instanceof ActionSecurityException) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, ex.getMessage());
        }
        if (ex instanceof ActionHandlerNullException) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT, ex.getMessage());
        }
        if (ex instanceof LlmPayloadUtils.LlmPayloadException) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, 'LLM Data Error: ' + ex.getMessage());
        }
        // Handle LLM Provider Exceptions (adjust based on final class definition/inheritance)
        if (ex.getTypeName().contains('LLMProviderException') || (ex instanceof AIAgentException && ex.getMessage().contains('LLM'))) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, 'LLM Communication Failed: ' + ex.getMessage());
        }
        if (ex instanceof ActionRegistry.ActionRegistryException) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, 'Action Setup Failed: ' + ex.getMessage());
        }

        // --- Default Fallback ---
        return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ex.getMessage());
    }

    /**
     * Maps DML StatusCode enum values to framework error codes.
     *
     * @param statusCodeStr The status code as a string.
     * @param defaultCode   The default error code to use if no mapping is found.
     * @return              The mapped error code.
     */
    private String mapStatusCodeToErrorCode(String statusCodeStr, String defaultCode) {
        if (statusCodeStr == null)
            return defaultCode;

        if (statusCodeStr == 'UNABLE_TO_LOCK_ROW')
            return AIAgentConstants.ERR_CODE_RECORD_LOCKED;
        if (statusCodeStr == 'FIELD_CUSTOM_VALIDATION_EXCEPTION')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCodeStr == 'REQUIRED_FIELD_MISSING')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCodeStr == 'INSUFFICIENT_ACCESS_OR_READONLY' || statusCodeStr == 'CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY')
            return AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
        if (
            statusCodeStr == 'INVALID_CROSS_REFERENCE_KEY' ||
            statusCodeStr == 'INVALID_FIELD_FOR_INSERT_UPDATE' ||
            statusCodeStr == 'INVALID_ID_FIELD'
        )
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCodeStr == 'STRING_TOO_LONG')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCodeStr == 'DUPLICATE_VALUE')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCodeStr == 'FIELD_FILTER_VALIDATION_EXCEPTION')
            return AIAgentConstants.ERR_CODE_INPUT_VALIDATION;
        if (statusCodeStr == 'DELETE_FAILED')
            return AIAgentConstants.ERR_CODE_DML_ERROR;

        return defaultCode;
    }

    private String mapStatusCodeToErrorCode(System.StatusCode statusCode, String defaultCode) {
        return statusCode != null ? mapStatusCodeToErrorCode(statusCode.name(), defaultCode) : defaultCode;
    }

    /**
     * Extracts public properties from custom objects using JSON serialization for result formatting.
     * Provides fallback handling for objects that cannot be serialized.
     *
     * @param obj The custom object to extract properties from.
     * @return    A map of public properties, or a fallback map if serialization fails.
     */
    private Map<String, Object> extractObjectProperties(Object obj) {
        Map<String, Object> properties = new Map<String, Object>();

        try {
            String jsonStr = JSON.serialize(obj);
            Map<String, Object> deserialized = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
            properties.putAll(deserialized);
        } catch (Exception e) {
            // Fallback: just put the object itself
            properties.put('result', obj);
        }

        return properties;
    }
}
