/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Abstract base class for Standard and Custom Agent Actions.
 *              Provides a standardized execution template, centralized error handling,
 *              and helper methods for creating consistent ActionResult objects.
 * @implements IAgentAction
 * @dependencies IAgentAction, ActionResult, ActionContext, AIAgentConstants, AIAgentException, LlmPayloadUtils, LLMProviderAdapter, ActionRegistry
 */
public abstract class BaseAgentAction implements IAgentAction {
    protected ActionContext actionContext { get; private set; }
    protected Map<String, Object> parsedActionConfig { get; private set; }

    /** @description Exception for errors during argument or configuration validation. */
    public virtual class ValidationException extends AIAgentException {
        public String fieldName;

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
        return 'ActionHandler:' + getLogPrefixName() + ' (Context: ' + (actionContext != null ? 'Set' : 'Not Set') + ')';
    }

    /** @description Exception specifically for security/permission denials. */
    public virtual class ActionSecurityException extends AIAgentException {
    }

    /** @description Exception for when performAction implementation returns null */
    private class ActionHandlerNullException extends AIAgentException {
    }

    /** @description Placeholder base for parsed args - Subclasses define their concrete type */
    public virtual class ParsedArguments {
    }

    /**
     * @description Standardized execution flow. Handles config/arg parsing, execution, exception mapping.
     */
    public virtual ActionResult execute(String actionConfigurationJson, String argumentsJson, ActionContext context) {
        if (context == null) {
            return new ActionResult('Internal error: Missing context.', 'ActionContext was null', AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR);
        }
        this.actionContext = context;
        final String logPrefix = '[' + getLogPrefixName() + ' Cap:' + context.agentCapabilityId + '] ';
        ActionResult finalResult = null;

        try {
            Map<String, Object> argsMap = String.isBlank(argumentsJson)
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);

            if (String.isNotBlank(context.preHookClassName)) {
                IPreActionHook preHook = (IPreActionHook) createHookInstance(context.preHookClassName, 'IPreActionHook');
                argsMap = preHook.preProcess(argsMap, context);
            }

            this.parseActionConfiguration(actionConfigurationJson, logPrefix);
            ParsedArguments validatedArgs = this.parseAndValidateArguments(JSON.serialize(argsMap), logPrefix);

            finalResult = this.performAction(validatedArgs, logPrefix);
            if (finalResult == null) {
                throw new ActionHandlerNullException('Handler (' + getLogPrefixName() + ') returned null ActionResult.');
            }
        } catch (Exception ex) {
            finalResult = mapExceptionToResult(ex, logPrefix);
        } finally {
            if (String.isNotBlank(context.postHookClassName) && finalResult != null) {
                try {
                    IPostActionHook postHook = (IPostActionHook) createHookInstance(context.postHookClassName, 'IPostActionHook');
                    postHook.postProcess(finalResult, context);
                } catch (Exception postHookEx) {
                }
            }
        }

        return finalResult;
    }

    private Object createHookInstance(String className, String interfaceName) {
        Type hookType = Type.forName(className);
        if (hookType == null) {
            throw new ValidationException('Hook class not found: "' + className + '". Check the class name and namespace.', null);
        }
        Object instance = hookType.newInstance();

        Type requiredInterface = Type.forName(interfaceName);
        if (!requiredInterface.isAssignableFrom(hookType)) {
            throw new ValidationException('Class ' + className + ' must implement the ' + interfaceName + ' interface.', null);
        }

        return instance;
    }

    protected virtual String getLogPrefixName() {
        return 'BaseAgentAction';
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

    protected abstract ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix);

    protected abstract ActionResult performAction(ParsedArguments validatedArgs, String logPrefix);

    protected ActionResult success(Object dataPayload, String messageForUser, String internalDetails) {
        Map<String, Object> standardOutput = new Map<String, Object>{
            'status' => 'SUCCESS',
            'messageForUser' => messageForUser,
            'data' => dataPayload
        };
        return new ActionResult(standardOutput, internalDetails);
    }

    protected ActionResult validationError(String details, String fieldName) {
        String toolName = this.getLogPrefixName();
        String llmErrorMessage =
            'Invalid input' +
            (String.isNotBlank(fieldName) ? ' for parameter "' + fieldName + '"' : '') +
            ' in the ' +
            toolName +
            ' action. Details: ' +
            details;

        Map<String, Object> errorPayload = new Map<String, Object>{
            'status' => 'ERROR',
            'error' => new Map<String, Object>{ 'code' => AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'message' => llmErrorMessage }
        };
        return new ActionResult(errorPayload, 'Validation Error: ' + details, AIAgentConstants.ERR_CODE_INPUT_VALIDATION);
    }

    protected ActionResult securityError(String details) {
        String toolName = this.getLogPrefixName();
        String llmErrorMessage = 'The ' + toolName + ' action was denied due to security restrictions. Details: ' + details;

        Map<String, Object> errorPayload = new Map<String, Object>{
            'status' => 'ERROR',
            'error' => new Map<String, Object>{ 'code' => AIAgentConstants.ERR_CODE_PERMISSION_DENIED, 'message' => llmErrorMessage }
        };
        return new ActionResult(errorPayload, details, AIAgentConstants.ERR_CODE_PERMISSION_DENIED);
    }

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

        Map<String, Object> errorPayload = new Map<String, Object>{
            'status' => 'ERROR',
            'error' => new Map<String, Object>{ 'code' => primaryErrorCode, 'message' => llmErrorMessage }
        };
        return new ActionResult(errorPayload, internalDetailsForLog, primaryErrorCode);
    }

    /** Maps DML StatusCode enum values to framework error codes */
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

    /** Creates generic RUNTIME FAILED ActionResult */
    protected ActionResult runtimeError(String internalMessage, String errorCode, Exception caughtException) {
        String toolName = this.getLogPrefixName();
        String finalErrorCode = String.isNotBlank(errorCode) ? errorCode : AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;
        String llmErrorMessage =
            'An unexpected internal error occurred while running the ' +
            toolName +
            ' action. The system reported: ' +
            internalMessage;

        Map<String, Object> errorPayload = new Map<String, Object>{
            'status' => 'ERROR',
            'error' => new Map<String, Object>{ 'code' => finalErrorCode, 'message' => llmErrorMessage }
        };

        String detailsForLogging = 'Runtime Error: ' + (internalMessage ?? 'No details available.');
        if (caughtException != null) {
            detailsForLogging += ' (Type: ' + caughtException.getTypeName() + ')';
        }

        return new ActionResult(errorPayload, detailsForLogging, finalErrorCode);
    }

    /** Maps caught exceptions to ActionResult */
    private ActionResult mapExceptionToResult(Exception ex, String logPrefix) {
        if (ex instanceof DmlException) {
            DmlException dmlEx = (DmlException) ex;
            String initialCode = dmlEx.getNumDml() > 0 ? dmlEx.getDmlStatusCode(0) : null;
            String firstDmlMsg = dmlEx.getNumDml() > 0 ? dmlEx.getDmlMessage(0) : ex.getMessage();
            return dmlError('DML failed: ' + firstDmlMsg, null, mapStatusCodeToErrorCode(initialCode, AIAgentConstants.ERR_CODE_DML_ERROR));
        }

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

        if (ex.getTypeName().contains('LLMProviderException') || (ex instanceof AIAgentException && ex.getMessage().contains('LLM'))) {
            return runtimeError('LLM Communication Failed: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, ex);
        }
        if (ex instanceof ActionRegistry.ActionRegistryException) {
            return runtimeError('Action Setup Failed: ' + ex.getMessage(), AIAgentConstants.ERR_CODE_CONFIG_ERROR, ex);
        }

        return this.runtimeError(ex.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ex);
    }

    /**
     * @description Creates a standardized, structured error payload map for the LLM.
     * @param toolName The name of the tool that failed.
     * @param errorCode A machine-readable framework error code.
     * @param errorMessage A detailed, LLM-readable description of what went wrong and potentially how to fix it.
     * @return A map ready to be serialized as JSON for the LLM.
     */
    private Map<String, Object> buildErrorPayload(String toolName, String errorCode, String errorMessage) {
        return new Map<String, Object>{
            'status' => 'error',
            'tool_name' => toolName,
            'error_type' => String.isNotBlank(errorCode) ? errorCode : AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
            'error_details' => errorMessage
        };
    }
}
