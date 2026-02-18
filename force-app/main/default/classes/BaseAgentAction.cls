/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Abstract base class for all agent actions. Subclasses must implement executeAction() and define ArgumentsDTO/ConfigDTO classes.
 */
public abstract with sharing class BaseAgentAction implements IAgentAction {
    protected ActionContext actionContext { get; private set; }
    protected Map<String, Object> parsedActionConfig { get; private set; }
    public virtual class ValidationException extends AIAgentException {
        public String fieldName; // Optional

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
        return 'ActionHandler (Context: ' + (actionContext != null ? 'Set' : 'Not Set') + ')';
    }

    public virtual class ActionSecurityException extends AIAgentException {
    }

    private class ActionHandlerNullException extends AIAgentException {
    }

    public virtual ActionOutcome execute(String actionConfigurationJson, String argumentsJson, ActionContext context) {
        if (context == null) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, 'Internal error: Missing context. ActionContext was null');
        }
        this.actionContext = context;
        final String logPrefix = '[' + getLogPrefixName() + ' Cap:' + context.agentCapabilityId + '] ';
        ActionOutcome finalOutcome = null;
        Long startTime = System.currentTimeMillis();

        try {
            System.debug(LoggingLevel.INFO, logPrefix + 'Starting action execution');

            Map<String, Object> argsMap = String.isBlank(argumentsJson)
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);

            this.parseActionConfiguration(actionConfigurationJson, logPrefix);

            ActionOutcome actionOutcome = executeAction(argsMap);

            if (actionOutcome == null) {
                throw new ActionHandlerNullException('Handler (' + getLogPrefixName() + ') returned null ActionOutcome.');
            }

            finalOutcome = actionOutcome;
        } catch (Exception ex) {
            finalOutcome = mapExceptionToOutcome(ex, logPrefix);
        }

        Long duration = System.currentTimeMillis() - startTime;
        System.debug(LoggingLevel.INFO, logPrefix + 'Execution Finished. Success: ' + finalOutcome.isSuccess);
        return finalOutcome;
    }

    public abstract ActionOutcome executeAction(Map<String, Object> params);

    protected virtual String getLogPrefixName() {
        String className = String.valueOf(this);
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
                    this.parsedActionConfig = resolveContextTokens(this.parsedActionConfig);
                } else {
                    throw new ValidationException('ActionConfiguration JSON must be a JSON Object (Map).');
                }
            } catch (Exception e) {
                throw new ValidationException('Invalid ActionConfiguration JSON: ' + e.getMessage(), e);
            }
        }
    }

    private Map<String, Object> resolveContextTokens(Map<String, Object> configMap) {
        Map<String, Object> resolved = new Map<String, Object>();

        for (String key : configMap.keySet()) {
            Object value = configMap.get(key);
            resolved.put(key, resolveTokenValue(value));
        }

        return resolved;
    }

    private Object resolveTokenValue(Object value) {
        if (value == null) {
            return null;
        }

        if (value instanceof String) {
            return replaceTokensInString((String) value);
        }

        if (value instanceof Map<String, Object>) {
            Map<String, Object> mapValue = (Map<String, Object>) value;
            Map<String, Object> resolvedMap = new Map<String, Object>();
            for (String key : mapValue.keySet()) {
                resolvedMap.put(key, resolveTokenValue(mapValue.get(key)));
            }
            return resolvedMap;
        }

        if (value instanceof List<Object>) {
            List<Object> listValue = (List<Object>) value;
            List<Object> resolvedList = new List<Object>();
            for (Object item : listValue) {
                resolvedList.add(resolveTokenValue(item));
            }
            return resolvedList;
        }

        return value;
    }

    private String replaceTokensInString(String input) {
        if (String.isBlank(input) || !input.contains('$')) {
            return input;
        }

        String result = input;

        if (this.actionContext != null) {
            result = result.replace('$Context.UserId', String.valueOf(this.actionContext.originalUserId));
        }

        result = result.replace('$User.Id', UserInfo.getUserId());
        result = result.replace('$System.Today', String.valueOf(System.today()));
        result = result.replace('$System.Now', String.valueOf(System.now()));

        return result;
    }

    private ActionOutcome mapExceptionToOutcome(Exception ex, String logPrefix) {
        System.debug(LoggingLevel.ERROR, logPrefix + 'Exception during action execution - Type: ' + ex.getTypeName() + ', Message: ' + ex.getMessage());
        if (ex instanceof DmlException) {
            DmlException dmlEx = (DmlException) ex;
            String initialCode = dmlEx.getNumDml() > 0 ? dmlEx.getDmlStatusCode(0) : null;
            String firstDmlMsg = dmlEx.getNumDml() > 0 ? dmlEx.getDmlMessage(0) : ex.getMessage();
            String errorCode = mapStatusCodeToErrorCode(initialCode, AIAgentConstants.ERR_CODE_DML_ERROR);
            String errorMessage = 'DML failed: ' + firstDmlMsg;
            return ActionOutcome.failureWithMeta(
                errorCode,
                errorMessage,
                ActionOutcome.deriveErrorCategory(errorCode),
                isRetryableException(ex, errorCode, errorMessage),
                null
            );
        }
        if (ex instanceof System.QueryException) {
            String msgLower = ex.getMessage().toLowerCase();
            String errCode = (msgLower.contains('security enforced') || msgLower.contains('insufficient access'))
                ? AIAgentConstants.ERR_CODE_PERMISSION_DENIED
                : AIAgentConstants.ERR_CODE_SOQL_ERROR;
            String errorMessage = 'Query failed: ' + ex.getMessage();
            return ActionOutcome.failureWithMeta(
                errCode,
                errorMessage,
                ActionOutcome.deriveErrorCategory(errCode),
                isRetryableException(ex, errCode, errorMessage),
                null
            );
        }
        if (ex instanceof System.CalloutException) {
            String errorCode = AIAgentConstants.ERR_CODE_CONNECT_API_ERROR;
            String errorMessage = 'External callout failed: ' + ex.getMessage();
            return ActionOutcome.failureWithMeta(
                errorCode,
                errorMessage,
                ActionOutcome.deriveErrorCategory(errorCode),
                isRetryableException(ex, errorCode, errorMessage),
                null
            );
        }
        if (ex instanceof System.LimitException) {
            String errorCode = AIAgentConstants.ERR_CODE_SYSTEM_LIMIT;
            String errorMessage = 'System limit exceeded: ' + ex.getMessage();
            return ActionOutcome.failureWithMeta(
                errorCode,
                errorMessage,
                ActionOutcome.deriveErrorCategory(errorCode),
                isRetryableException(ex, errorCode, errorMessage),
                null
            );
        }

        if (ex instanceof TypeCoercionService.TypeCoercionException) {
            TypeCoercionService.TypeCoercionException tce = (TypeCoercionService.TypeCoercionException) ex;
            if (String.isNotBlank(tce.correctionGuidance)) {
                return ActionOutcome.failureWithMeta(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    tce.getMessage(),
                    AIAgentConstants.ERR_CATEGORY_VALIDATION,
                    false,
                    tce.correctionGuidance
                );
            }
            return ActionOutcome.failureWithMeta(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                tce.getMessage(),
                AIAgentConstants.ERR_CATEGORY_VALIDATION,
                false,
                null
            );
        }

        if (ex instanceof ValidationException) {
            ValidationException ve = (ValidationException) ex;
            return ActionOutcome.failureWithMeta(
                AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                ve.getMessage(),
                AIAgentConstants.ERR_CATEGORY_VALIDATION,
                false,
                null
            );
        }
        if (ex instanceof ActionSecurityException) {
            return ActionOutcome.failureWithMeta(
                AIAgentConstants.ERR_CODE_PERMISSION_DENIED,
                ex.getMessage(),
                AIAgentConstants.ERR_CATEGORY_PERMISSION,
                false,
                null
            );
        }
        if (ex instanceof ActionHandlerNullException) {
            String errorCode = AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT;
            return ActionOutcome.failureWithMeta(
                errorCode,
                ex.getMessage(),
                ActionOutcome.deriveErrorCategory(errorCode),
                isRetryableException(ex, errorCode, ex.getMessage()),
                null
            );
        }
        if (ex instanceof LLMFormattingService.LlmPayloadException) {
            String errorCode = AIAgentConstants.ERR_CODE_CONFIG_ERROR;
            String errorMessage = 'LLM Data Error: ' + ex.getMessage();
            return ActionOutcome.failureWithMeta(errorCode, errorMessage, ActionOutcome.deriveErrorCategory(errorCode), false, null);
        }
        if (ex.getTypeName().contains('ProviderException') || (ex instanceof AIAgentException && ex.getMessage().contains('LLM'))) {
            String errorCode = AIAgentConstants.ERR_CODE_LLM_CALL_FAILED;
            String errorMessage = 'LLM Communication Failed: ' + ex.getMessage();
            return ActionOutcome.failureWithMeta(
                errorCode,
                errorMessage,
                ActionOutcome.deriveErrorCategory(errorCode),
                isRetryableException(ex, errorCode, errorMessage),
                null
            );
        }
        if (ex instanceof CapabilityExecutionService.CapabilityExecutionException) {
            String errorCode = AIAgentConstants.ERR_CODE_CONFIG_ERROR;
            String errorMessage = 'Action Setup Failed: ' + ex.getMessage();
            return ActionOutcome.failureWithMeta(errorCode, errorMessage, ActionOutcome.deriveErrorCategory(errorCode), false, null);
        }

        String errorCode = AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR;
        String errorMessage = ex.getMessage();
        return ActionOutcome.failureWithMeta(
            errorCode,
            errorMessage,
            ActionOutcome.deriveErrorCategory(errorCode),
            isRetryableException(ex, errorCode, errorMessage),
            null
        );
    }

    private Boolean isRetryableException(Exception ex, String errorCode, String errorMessage) {
        if (errorCode == AIAgentConstants.ERR_CODE_RECORD_LOCKED) {
            return true;
        }
        if (errorCode == AIAgentConstants.ERR_CODE_LLM_CALL_FAILED || errorCode == AIAgentConstants.ERR_CODE_CONNECT_API_ERROR) {
            return !isNonRetryableMessage(errorMessage);
        }
        if (ex instanceof System.CalloutException) {
            return !isNonRetryableMessage(errorMessage);
        }
        return ActionOutcome.deriveRetryable(errorCode);
    }

    private Boolean isTransientMessage(String errorMessage) {
        if (String.isBlank(errorMessage)) {
            return false;
        }
        String msg = errorMessage.toLowerCase();

        if (isNonRetryableMessage(errorMessage)) {
            return false;
        }

        return msg.contains('timeout') ||
            msg.contains('timed out') ||
            msg.contains('temporarily unavailable') ||
            msg.contains('rate limit') ||
            msg.contains('too many requests') ||
            msg.contains('connection') ||
            msg.contains('network') ||
            msg.contains('unavailable') ||
            msg.contains('service') ||
            msg.contains('502') ||
            msg.contains('503') ||
            msg.contains('504');
    }

    private Boolean isNonRetryableMessage(String errorMessage) {
        if (String.isBlank(errorMessage)) {
            return false;
        }
        String msg = errorMessage.toLowerCase();
        return msg.contains('unauthorized') ||
            msg.contains('forbidden') ||
            msg.contains('authentication') ||
            msg.contains('invalid') ||
            msg.contains('bad request') ||
            msg.contains('validation');
    }

    @TestVisible
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
        if (statusCodeStr == 'INVALID_CROSS_REFERENCE_KEY' || statusCodeStr == 'INVALID_FIELD_FOR_INSERT_UPDATE' || statusCodeStr == 'INVALID_ID_FIELD')
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
}
