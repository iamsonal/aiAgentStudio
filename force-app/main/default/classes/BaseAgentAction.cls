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
 *   - Features intelligent parameter processing, automatic type coercion, security validation, and standardized error handling
 *   - Requires subclasses to implement only the executeAction() method; all validation, security, and result formatting are handled by the base class
 *   - Surfaces operational and validation issues clearly via ActionResult and logging for maintainability
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
     * Handles intelligent parameter processing, security validation, and result wrapping.
     * Subclasses only need to implement executeAction() with pure business logic.
     *
     * @param actionConfigurationJson The action configuration as a JSON string.
     * @param argumentsJson           The action arguments as a JSON string.
     * @param context                 The ActionContext for this execution.
     * @return                        The standardized ActionResult for the action.
     */
    public virtual ActionResult execute(String actionConfigurationJson, String argumentsJson, ActionContext context) {
        if (context == null) {
            return new ActionResult('Internal error: Missing context.', 'ActionContext was null', AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR);
        }
        this.actionContext = context;
        final String logPrefix = '[' + getLogPrefixName() + ' Cap:' + context.agentCapabilityId + '] ';
        ActionResult finalResult = null;
        Long startTime = System.currentTimeMillis();

        // Log action start
        OrchestrationLogger.logActionStart(context, getLogPrefixName(), argumentsJson);

        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Starting action execution with intelligent parameter processing');

            Map<String, Object> argsMap = String.isBlank(argumentsJson)
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);

            // Parse configuration (still needed for some actions)
            this.parseActionConfiguration(actionConfigurationJson, logPrefix);

            // Intelligent parameter processing
            Map<String, Object> processedParams = intelligentParameterProcessing(argsMap, logPrefix);

            // Intelligent security checks
            performIntelligentSecurityChecks(processedParams, logPrefix);

            // Call the simplified action method
            Object result = executeAction(processedParams);

            // Intelligent result wrapping
            finalResult = intelligentResultWrapping(result, logPrefix);

            if (finalResult == null) {
                throw new ActionHandlerNullException('Handler (' + getLogPrefixName() + ') returned null ActionResult.');
            }
        } catch (Exception ex) {
            finalResult = mapExceptionToResult(ex, logPrefix);
        }

        // Log action result with performance metrics
        Long duration = System.currentTimeMillis() - startTime;
        OrchestrationLogger.logActionResult(context, getLogPrefixName(), finalResult, duration);

        System.debug(LoggingLevel.INFO, logPrefix + 'Execution Finished. Success: ' + finalResult.isSuccess);
        return finalResult;
    }

    // ============================================================================
    // --- SINGLE METHOD APPROACH - Actions implement this ONE method only ---
    // ============================================================================

    /**
     * The only method actions need to implement!
     * Framework automatically handles parameter extraction, validation, security, and result wrapping.
     *
     * @param params Validated and typed parameters extracted from JSON arguments.
     * @return       Simple result object (String, custom object, or ActionResult).
     */
    public abstract Object executeAction(Map<String, Object> params);

    /**
     * Intelligently processes and validates parameters using naming conventions and automatic type coercion.
     * Converts string parameters to appropriate types (ID, DateTime, Integer, Boolean) based on parameter names.
     *
     * @param rawArgs   The raw argument map from JSON.
     * @param logPrefix The logging prefix for debug output.
     * @return          The processed and typed parameter map.
     */
    private Map<String, Object> intelligentParameterProcessing(Map<String, Object> rawArgs, String logPrefix) {
        Map<String, Object> processed = new Map<String, Object>();

        for (String paramName : rawArgs.keySet()) {
            Object value = rawArgs.get(paramName);

            // Skip null values
            if (value == null) {
                continue;
            }

            // Intelligent type coercion based on parameter name patterns
            if (paramName.toLowerCase().endsWith('id') || paramName.toLowerCase().contains('recordid')) {
                // ID parameters
                processed.put(paramName, coerceToId(value, paramName));
            } else if (paramName.toLowerCase().contains('date') || paramName.toLowerCase().contains('time')) {
                // Date/DateTime parameters
                processed.put(paramName, coerceToDateTime(value, paramName));
            } else if (
                paramName.toLowerCase().contains('limit') ||
                paramName.toLowerCase().contains('count') ||
                paramName.toLowerCase().contains('max')
            ) {
                // Integer parameters
                processed.put(paramName, coerceToInteger(value, paramName));
            } else if (
                paramName.toLowerCase().contains('enable') ||
                paramName.toLowerCase().contains('is') ||
                paramName.toLowerCase().contains('has')
            ) {
                // Boolean parameters
                processed.put(paramName, coerceToBoolean(value, paramName));
            } else {
                // Keep as-is for other types
                processed.put(paramName, value);
            }
        }

        return processed;
    }

    /**
     * Performs comprehensive security validation by analyzing parameter patterns and action context.
     * Automatically detects required permissions based on action type and validates object access.
     *
     * @param params   The processed parameter map.
     * @param logPrefix The logging prefix for debug output.
     * @throws ActionSecurityException if object access is denied.
     */
    private void performIntelligentSecurityChecks(Map<String, Object> params, String logPrefix) {
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
    }

    /**
     * Automatically wraps action results in standardized ActionResult format.
     * Handles various return types including strings, custom objects, and existing ActionResults.
     *
     * @param result   The raw result from executeAction().
     * @param logPrefix The logging prefix for debug output.
     * @return         The standardized ActionResult.
     */
    private ActionResult intelligentResultWrapping(Object result, String logPrefix) {
        if (result == null) {
            return successWithData(new Map<String, Object>(), 'Action completed successfully', 'No data returned');
        }

        if (result instanceof ActionResult) {
            return (ActionResult) result;
        }

        if (result instanceof String) {
            return successWithData(new Map<String, Object>(), (String) result, 'String result returned');
        }

        // For custom result objects, extract public properties intelligently
        Map<String, Object> dataMap = extractObjectProperties(result);

        // Try to find a user message in the result object
        String userMessage = 'Action completed successfully';
        if (dataMap.containsKey('message')) {
            userMessage = String.valueOf(dataMap.get('message'));
        } else if (dataMap.containsKey('userMessage')) {
            userMessage = String.valueOf(dataMap.get('userMessage'));
        }

        return successWithData(dataMap, userMessage, 'Object result returned');
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
    // --- ActionResult Helper Methods ---
    // ============================================================================

    /**
     * Creates a successful ActionResult with clean, standardized structure.
     *
     * @param businessData   Pure business data without any framework fields.
     * @param messageForUser Human-readable success message.
     * @param internalDetails Internal logging details.
     * @param metadata       Optional metadata for complex scenarios.
     * @return               The standardized ActionResult.
     */
    protected ActionResult successWithData(Object businessData, String messageForUser, String internalDetails, Map<String, Object> metadata) {
        Map<String, Object> cleanOutput = new Map<String, Object>{
            'success' => true,
            'messageForUser' => messageForUser,
            'data' => businessData ?? new Map<String, Object>()
        };

        if (metadata != null && !metadata.isEmpty()) {
            cleanOutput.put('metadata', metadata);
        }

        return new ActionResult(cleanOutput, internalDetails);
    }

    /**
     * Creates a successful ActionResult with clean structure (no metadata).
     *
     * @param businessData   Pure business data without any framework fields.
     * @param messageForUser Human-readable success message.
     * @param internalDetails Internal logging details.
     * @return               The standardized ActionResult.
     */
    protected ActionResult successWithData(Object businessData, String messageForUser, String internalDetails) {
        return successWithData(businessData, messageForUser, internalDetails, null);
    }

    /**
     * Creates a validation error ActionResult with clean structure.
     *
     * @param details   The validation error details.
     * @param fieldName The name of the field that failed validation, if any.
     * @return          The standardized ActionResult.
     */
    protected ActionResult validationError(String details, String fieldName) {
        String toolName = this.getLogPrefixName();
        String llmErrorMessage =
            'Invalid input' +
            (String.isNotBlank(fieldName) ? ' for parameter "' + fieldName + '"' : '') +
            ' in the ' +
            toolName +
            ' action. Details: ' +
            details;

        Map<String, Object> cleanOutput = new Map<String, Object>{
            'success' => false,
            'errorCode' => AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
            'messageForUser' => llmErrorMessage,
            'data' => new Map<String, Object>()
        };

        return new ActionResult(cleanOutput, 'Validation Error: ' + details, AIAgentConstants.ERR_CODE_INPUT_VALIDATION);
    }

    /**
     * Creates a security error ActionResult with clean structure.
     *
     * @param details The security error details.
     * @return        The standardized ActionResult.
     */
    protected ActionResult securityError(String details) {
        String toolName = this.getLogPrefixName();
        String llmErrorMessage = 'The ' + toolName + ' action was denied due to security restrictions. Details: ' + details;

        Map<String, Object> cleanOutput = new Map<String, Object>{
            'success' => false,
            'errorCode' => AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
            'messageForUser' => llmErrorMessage,
            'data' => new Map<String, Object>()
        };

        return new ActionResult(cleanOutput, details, AIAgentConstants.ERR_CODE_PERMISSION_DENIED);
    }

    /**
     * Creates a DML error ActionResult with clean structure.
     *
     * @param genericMessage    The generic error message.
     * @param dmlErrors         The list of DML errors.
     * @param suggestedErrorCode The suggested error code, if any.
     * @return                  The standardized ActionResult.
     */
    protected ActionResult dmlError(String genericMessage, List<Database.Error> dmlErrors, String suggestedErrorCode) {
        String toolName = this.getLogPrefixName();
        String primaryErrorCode = suggestedErrorCode ?? AIAgentConstants.ERR_CODE_DML_ERROR;
        String firstDmlMessage = 'A database error occurred.';

        List<String> errorDetailsList = new List<String>();
        if (dmlErrors != null && !dmlErrors.isEmpty()) {
            StatusCode firstStatusCode = dmlErrors[0].getStatusCode();
            primaryErrorCode = mapStatusCodeToErrorCode(firstStatusCode, primaryErrorCode);
            firstDmlMessage = dmlErrors[0].getMessage();

            for (Database.Error err : dmlErrors) {
                String fieldStr = String.join(err.getFields() ?? new List<String>(), ',');
                errorDetailsList.add('[Fields:(' + fieldStr + '), Status:' + err.getStatusCode() + ', Msg:' + err.getMessage() + ']');
            }
        }
        String internalDetailsForLog = (genericMessage ?? '') + ' Details: ' + String.join(errorDetailsList, '; ');

        String llmErrorMessage = 'A database error occurred while executing the ' + toolName + ' action: ' + firstDmlMessage;

        Map<String, Object> cleanOutput = new Map<String, Object>{
            'success' => false,
            'errorCode' => primaryErrorCode,
            'messageForUser' => llmErrorMessage,
            'data' => new Map<String, Object>()
        };

        return new ActionResult(cleanOutput, internalDetailsForLog, primaryErrorCode);
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
     * Creates a runtime error ActionResult with clean structure.
     *
     * @param internalMessage The internal error message.
     * @param errorCode       The error code to use.
     * @param caughtException The caught exception, if any.
     * @return                The standardized ActionResult.
     */
    protected ActionResult runtimeError(String internalMessage, String errorCode, Exception caughtException) {
        String toolName = this.getLogPrefixName();
        String finalErrorCode = String.isNotBlank(errorCode) ? errorCode : AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;
        String llmErrorMessage =
            'An unexpected internal error occurred while running the ' +
            toolName +
            ' action. The system reported: ' +
            internalMessage;

        Map<String, Object> cleanOutput = new Map<String, Object>{
            'success' => false,
            'errorCode' => finalErrorCode,
            'messageForUser' => llmErrorMessage,
            'data' => new Map<String, Object>()
        };

        String detailsForLogging = 'Runtime Error: ' + (internalMessage ?? 'No details available.');
        if (caughtException != null) {
            detailsForLogging += ' (Type: ' + caughtException.getTypeName() + ')';
        }

        return new ActionResult(cleanOutput, detailsForLogging, finalErrorCode);
    }

    // ============================================================================
    // --- Private: Exception Mapping ---
    // ============================================================================

    /**
     * Maps caught exceptions to ActionResult.
     *
     * @param ex       The caught exception.
     * @param logPrefix The logging prefix for debug output.
     * @return         The standardized ActionResult.
     */
    private ActionResult mapExceptionToResult(Exception ex, String logPrefix) {
        System.debug(
            LoggingLevel.ERROR,
            logPrefix + 'Exception during action execution - Type: ' + ex.getTypeName() + ', Message: ' + ex.getMessage()
        );
        if (ex instanceof DmlException) {
            DmlException dmlEx = (DmlException) ex;
            String initialCode = dmlEx.getNumDml() > 0 ? dmlEx.getDmlStatusCode(0) : null;
            String firstDmlMsg = dmlEx.getNumDml() > 0 ? dmlEx.getDmlMessage(0) : ex.getMessage();
            return dmlError('DML failed: ' + firstDmlMsg, null, mapStatusCodeToErrorCode(initialCode, AIAgentConstants.ERR_CODE_DML_ERROR));
        }
        // (Keep QueryException, CalloutException, LimitException checks)
        if (ex instanceof System.QueryException) {
            String msgLower = ex.getMessage().toLowerCase();
            String errCode = (msgLower.contains('security enforced') || msgLower.contains('insufficient access'))
                ? AIAgentConstants.ERR_CODE_PERMISSION_DENIED
                : AIAgentConstants.ERR_CODE_SOQL_ERROR;
            return this.runtimeError('Query failed: ' + ex.getMessage(), errCode, ex);
        }
        if (ex instanceof System.CalloutException) {
            return this.runtimeError('External callout failed: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_CONNECT_API_ERROR, ex);
        }
        if (ex instanceof System.LimitException) {
            return this.runtimeError('System limit exceeded: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_SYSTEM_LIMIT, ex);
        }

        // --- Handle framework specific exceptions (Use base AIAgentException or check type name if needed) ---
        if (ex instanceof ValidationException) {
            ValidationException ve = (ValidationException) ex;
            return this.validationError(ve.getMessage(), ve.fieldName);
        }
        if (ex instanceof ActionSecurityException) {
            return this.securityError(ex.getMessage());
        }
        if (ex instanceof ActionHandlerNullException) {
            return this.runtimeError(ex.getMessage(), AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT, ex);
        }
        if (ex instanceof LlmPayloadUtils.LlmPayloadException) {
            return runtimeError('LLM Data Error: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_CONFIG_ERROR, ex);
        }
        // Handle LLM Provider Exceptions (adjust based on final class definition/inheritance)
        if (ex.getTypeName().contains('LLMProviderException') || (ex instanceof AIAgentException && ex.getMessage().contains('LLM'))) {
            return runtimeError('LLM Communication Failed: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, ex);
        }
        if (ex instanceof ActionRegistry.ActionRegistryException) {
            return runtimeError('Action Setup Failed: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_CONFIG_ERROR, ex);
        }

        // --- Default Fallback ---
        return this.runtimeError(ex.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ex);
    }

    // ============================================================================
    // --- Type Coercion Helpers for Simplified Actions ---
    // ============================================================================

    private Id coerceToId(Object value, String paramName) {
        if (value instanceof Id) {
            return (Id) value;
        }
        if (value instanceof String && String.isNotBlank((String) value)) {
            try {
                return Id.valueOf((String) value);
            } catch (Exception e) {
                throw new ValidationException('Invalid ID format for parameter "' + paramName + '": ' + value, paramName);
            }
        }
        throw new ValidationException('Parameter "' + paramName + '" must be a valid Salesforce ID', paramName);
    }

    private DateTime coerceToDateTime(Object value, String paramName) {
        if (value instanceof DateTime) {
            return (DateTime) value;
        }
        if (value instanceof String && String.isNotBlank((String) value)) {
            try {
                return DateTime.valueOf((String) value);
            } catch (Exception e) {
                throw new ValidationException('Invalid DateTime format for parameter "' + paramName + '": ' + value, paramName);
            }
        }
        return null; // Allow null for optional date parameters
    }

    private Integer coerceToInteger(Object value, String paramName) {
        if (value instanceof Integer) {
            return (Integer) value;
        }
        if (value instanceof Decimal) {
            return ((Decimal) value).intValue();
        }
        if (value instanceof String && String.isNotBlank((String) value)) {
            try {
                return Integer.valueOf((String) value);
            } catch (Exception e) {
                throw new ValidationException('Invalid Integer format for parameter "' + paramName + '": ' + value, paramName);
            }
        }
        return null;
    }

    private Boolean coerceToBoolean(Object value, String paramName) {
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        if (value instanceof String) {
            String strValue = ((String) value).toLowerCase();
            if (strValue == 'true' || strValue == '1' || strValue == 'yes') {
                return true;
            }
            if (strValue == 'false' || strValue == '0' || strValue == 'no') {
                return false;
            }
        }
        return null;
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
