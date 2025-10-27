/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Abstract base class for all agent actions in the AI Agent Framework.
 *
 * Uses two-pass deserialization pattern: JSON.deserializeUntyped() followed by manual DTO population
 * with ActionConfigUtils for type safety and LLM output variability handling.
 *
 * Subclasses must implement executeAction() method and define ArgumentsDTO/ConfigDTO classes.
 * For SObject operations, use TypeCoercionService.coerceArgumentTypesForSObject() for field type coercion.
 *
 * Schema Contract: ArgumentsDTO fields must match ParametersTemplate__c properties exactly.
 *
 * @implements IAgentAction
 */
public abstract class BaseAgentAction implements IAgentAction {
    // --- Common State (Accessible by Subclasses) ---
    protected ActionContext actionContext { get; private set; }
    protected Map<String, Object> parsedActionConfig { get; private set; }

    /**
     * Exception for validation errors with optional field name.
     */
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

    /**
     * Exception for security/permission denials.
     */
    public virtual class ActionSecurityException extends AIAgentException {
    }

    /**
     * Exception for null ActionOutcome.
     */
    private class ActionHandlerNullException extends AIAgentException {
    }

    /**
     * Executes an agent action with parameter deserialization and outcome wrapping.
     *
     * @param actionConfigurationJson Action configuration JSON
     * @param argumentsJson           Action arguments JSON
     * @param context                 ActionContext for execution
     * @return                        ActionOutcome result
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

    /**
     * Abstract method for action implementation.
     * Subclasses deserialize params into DTOs, validate, and execute business logic.
     *
     * @param params Raw parameters from JSON
     * @return       ActionOutcome with result or error
     */
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
                } else {
                    throw new ValidationException('ActionConfiguration JSON must be a JSON Object (Map).');
                }
            } catch (Exception e) {
                throw new ValidationException('Invalid ActionConfiguration JSON: ' + e.getMessage(), e);
            }
        }
    }

    /**
     * Maps exceptions to ActionOutcome.
     *
     * @param ex       Exception to map
     * @param logPrefix Logging prefix
     * @return         ActionOutcome representing error
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

        if (ex instanceof TypeCoercionService.TypeCoercionException) {
            TypeCoercionService.TypeCoercionException tce = (TypeCoercionService.TypeCoercionException) ex;
            if (String.isNotBlank(tce.correctionGuidance)) {
                return ActionOutcome.failureWithGuidance(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, tce.getMessage(), tce.correctionGuidance);
            }
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, tce.getMessage());
        }

        if (ex instanceof QueryServiceException) {
            QueryServiceException qse = (QueryServiceException) ex;
            String guidance = extractGuidanceFromQueryException(qse);
            if (String.isNotBlank(guidance)) {
                return ActionOutcome.failureWithGuidance(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, qse.getMessage(), guidance);
            }
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, qse.getMessage());
        }

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
        if (ex.getTypeName().contains('LLMProviderException') || (ex instanceof AIAgentException && ex.getMessage().contains('LLM'))) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_LLM_CALL_FAILED, 'LLM Communication Failed: ' + ex.getMessage());
        }
        if (ex instanceof ActionRegistry.ActionRegistryException) {
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, 'Action Setup Failed: ' + ex.getMessage());
        }

        return ActionOutcome.failure(AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ex.getMessage());
    }

    /**
     * Extracts correction guidance from QueryServiceException.
     *
     * @param qse QueryServiceException
     * @return Correction guidance or null
     */
    private String extractGuidanceFromQueryException(QueryServiceException qse) {
        if (qse == null) {
            return null;
        }

        List<String> guidanceParts = new List<String>();

        if (String.isNotBlank(qse.suggestedFix)) {
            guidanceParts.add(qse.suggestedFix);
        }

        if (qse.alternativeSolutions != null && !qse.alternativeSolutions.isEmpty()) {
            for (String alternative : qse.alternativeSolutions) {
                if (String.isNotBlank(alternative)) {
                    guidanceParts.add(alternative);
                }
            }
        }

        return guidanceParts.isEmpty() ? null : String.join(guidanceParts, ' | ');
    }

    /**
     * Maps DML StatusCode to framework error codes.
     *
     * @param statusCodeStr Status code string
     * @param defaultCode   Default error code
     * @return              Mapped error code
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
     * Extracts object properties using JSON serialization.
     *
     * @param obj Object to extract properties from
     * @return    Map of properties or fallback
     */
    private Map<String, Object> extractObjectProperties(Object obj) {
        Map<String, Object> properties = new Map<String, Object>();

        try {
            String jsonStr = JSON.serialize(obj);
            Map<String, Object> deserialized = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
            properties.putAll(deserialized);
        } catch (Exception e) {
            properties.put('result', obj);
        }

        return properties;
    }
}
