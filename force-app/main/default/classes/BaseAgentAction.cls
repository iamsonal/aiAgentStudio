/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Abstract base class for Standard and Custom Agent Actions.
 *              Provides a standardized execution template, centralized error handling,
 *              and helper methods for creating consistent ActionResult objects.
 *              Subclasses must implement parsing/validation of arguments and core action logic.
 * @implements IAgentAction
 */
public abstract class BaseAgentAction implements IAgentAction {
    /** @description Action context providing Session, User, Record IDs etc. */
    protected ActionContext actionContext { get; private set; }
    /** @description Parsed ActionConfiguration JSON from AgentCapabilityBinding. */
    protected Map<String, Object> parsedActionConfig { get; private set; }

    /**
     * @description Standardized execution flow for all actions extending this base class.
     *              Handles parsing, validation calls, execution calls, and exception handling.
     *              Subclasses should NOT override this method.
     * @param actionConfigurationJson JSON String from AgentCapabilityBinding__c.ActionConfiguration__c.
     * @param argumentsJson Raw JSON string of arguments provided by the LLM.
     * @param context Shared ActionContext.
     * @return ActionResult Standardized result object.
     */
    public ActionResult execute(String actionConfigurationJson, String argumentsJson, ActionContext context) {
        this.actionContext = context;
        final String logPrefix =
            '[' +
            getLogPrefixName() +
            ' ActionDefId:' +
            context?.actionDefinitionId +
            ' BindingId:' +
            context?.agentCapabilityId +
            '] ';
        ActionResult finalResult = null;
        ParsedArguments validatedArgs = null;

        try {
            this.parseActionConfiguration(actionConfigurationJson, logPrefix);

            validatedArgs = this.parseAndValidateArguments(argumentsJson, logPrefix);

            finalResult = this.performAction(validatedArgs, logPrefix);
        } catch (ValidationException ve) {
            finalResult = this.validationError(ve.getMessage(), ve.fieldName);
        } catch (ActionSecurityException se) {
            finalResult = this.securityError(se.getMessage());
        } catch (Exception ex) {
            String exceptionType = ex.getTypeName();
            String errorMessage = ex.getMessage();
            String stackTrace = ex.getStackTraceString();

            finalResult = mapExceptionToResult(ex, logPrefix);
        } finally {
            if (finalResult == null) {
                finalResult = this.runtimeError(
                    'Action implementation failed to return a result.',
                    AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT,
                    null
                );
            }
        }

        return finalResult;
    }

    protected virtual String getLogPrefixName() {
        return 'BaseAgentAction';
    }

    /**
     * Parses the actionConfigurationJson from the AgentCapabilityBinding.
     * Subclasses can override this to parse specific configuration keys relevant to them.
     * The base implementation parses the JSON into the `parsedActionConfig` map.
     * @param actionConfigurationJson The raw JSON string.
     * @param logPrefix Logging prefix.
     * @throws ValidationException if JSON is invalid or required config is missing.
     */
    protected virtual void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        if (String.isNotBlank(actionConfigurationJson)) {
            try {
                Object parsed = JSON.deserializeUntyped(actionConfigurationJson);
                if (parsed instanceof Map<String, Object>) {
                    this.parsedActionConfig = (Map<String, Object>) parsed;
                } else {
                    throw new ValidationException('ActionConfiguration JSON must be a valid JSON Object (Map).');
                }
            } catch (Exception e) {
                throw new ValidationException('Invalid ActionConfiguration JSON: ' + e.getMessage());
            }
        } else {
            this.parsedActionConfig = new Map<String, Object>();
        }
    }

    /**
     * Subclasses MUST implement this method to parse the `argumentsJson` string from the LLM
     * into a specific `ParsedArguments` subclass instance, validate the contents, and perform
     * necessary type coercion using `ActionParamUtils` or similar utilities.
     * @param argumentsJson Raw JSON string of arguments from the LLM.
     * @param logPrefix Logging prefix.
     * @return An instance of a subclass of `ParsedArguments` containing validated and typed data.
     * @throws ValidationException if arguments are invalid or missing.
     */
    protected abstract ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix);

    /**
     * Subclasses MUST implement this method to perform the core logic of the action
     * using the validated arguments. This method should contain the business logic,
     * DML operations, callouts, etc. It must explicitly call security check methods
     * from `SecurityUtils` before performing sensitive operations.
     * @param validatedArgs The validated and typed arguments returned by `parseAndValidateArguments`.
     * @param logPrefix Logging prefix.
     * @return ActionResult Indicating the success or failure of the action's core logic.
     * @throws Any Exception (will be caught by the base execute method). Specific exceptions
     *         like DML exceptions can be caught here for more tailored error reporting via helpers.
     */
    protected abstract ActionResult performAction(ParsedArguments validatedArgs, String logPrefix);

    /**
     * Creates a SUCCESS ActionResult.
     * @param outputForLlm The data payload (must be serializable) to return to the LLM.
     * @param internalDetails Debugging/logging information about the success.
     * @return A successful ActionResult instance.
     */
    protected ActionResult success(Object outputForLlm, String internalDetails) {
        return new ActionResult(outputForLlm, internalDetails);
    }

    /**
     * Creates a FAILED ActionResult due to input validation issues.
     * @param details Specific details about the validation failure.
     * @param fieldName Optional - the name of the field that failed validation.
     * @return A failed ActionResult instance with INPUT_VALIDATION code.
     */
    protected ActionResult validationError(String details, String fieldName) {
        String summaryForLlm =
            'Invalid input provided' +
            (String.isNotBlank(fieldName) ? ' for "' + fieldName + '"' : '') +
            '.';
        return new ActionResult(summaryForLlm, details, AIAgentConstants.ERR_CODE_INPUT_VALIDATION);
    }

    /**
     * Creates a FAILED ActionResult due to security/permission issues.
     * @param details Specific details about the permission denial (FLS, CRUD, Record Access).
     * @return A failed ActionResult instance with PERMISSION_DENIED code.
     */
    protected ActionResult securityError(String details) {
        String summaryForLlm = 'Action cannot be performed due to permission restrictions.';

        return new ActionResult(summaryForLlm, details, AIAgentConstants.ERR_CODE_PERMISSION_DENIED);
    }

    /**
     * Creates a FAILED ActionResult specifically for DML failures (Insert/Update/Delete).
     * Extracts information from SaveResult/DeleteResult errors.
     * @param genericMessage A high-level message like "Failed to create/update/delete record."
     * @param dmlErrors List of Database.Error objects from the DML result.
     * @param errorCode Specific DML-related error code (e.g., DML_ERROR, RECORD_LOCKED), defaults if null.
     * @return A failed ActionResult instance.
     */
    protected ActionResult dmlError(String genericMessage, List<Database.Error> dmlErrors, String errorCode) {
        String details = genericMessage;
        String primaryErrorCode = String.isNotBlank(errorCode) ? errorCode : AIAgentConstants.ERR_CODE_DML_ERROR;

        if (dmlErrors != null && !dmlErrors.isEmpty()) {
            List<String> errorDetailsList = new List<String>();
            for (Database.Error err : dmlErrors) {
                String fieldStr = (err.getFields() == null || err.getFields().isEmpty())
                    ? 'N/A'
                    : String.join(err.getFields(), ',');
                errorDetailsList.add(
                    'Fields: [' + fieldStr + '], Status: ' + err.getStatusCode() + ', Message: ' + err.getMessage()
                );

                if (err.getStatusCode() == StatusCode.UNABLE_TO_LOCK_ROW) {
                    primaryErrorCode = AIAgentConstants.ERR_CODE_RECORD_LOCKED;
                }
            }
            details += ' Details: ' + String.join(errorDetailsList, '; ');
        }

        return new ActionResult(genericMessage, details, primaryErrorCode);
    }

    /**
     * Creates a FAILED ActionResult for unexpected runtime errors.
     * @param details High-level description or Exception message.
     * @param errorCode Specific code if known, otherwise defaults to UNEXPECTED_ERROR.
     * @param ex Optional - The caught exception (used for logging stack trace).
     * @return A failed ActionResult instance.
     */
    protected ActionResult runtimeError(String message, String errorCode, Exception ex) {
        String summaryForLlm = 'An unexpected error occurred while processing the action.';
        String details = message;

        if (ex != null) {
            details += ' (Type: ' + ex.getTypeName() + ')';
        }
        return new ActionResult(summaryForLlm, details, errorCode);
    }

    /**
     * Helper to map various caught exceptions to standardized ActionResult objects.
     * Called when an exception is caught directly by the base execute method's catch block.
     * @param ex The caught exception.
     * @param logPrefix Logging prefix.
     * @return A failed ActionResult instance.
     */
    private ActionResult mapExceptionToResult(Exception ex, String logPrefix) {
        if (ex instanceof DmlException) {
            DmlException dmlEx = (DmlException) ex;
            String firstErrorMessage = dmlEx.getNumDml() > 0 ? dmlEx.getDmlMessage(0) : ex.getMessage();
            String internalDetails = 'DML Exception: ' + firstErrorMessage;

            String primaryErrorCode = AIAgentConstants.ERR_CODE_DML_ERROR;
            String lowerMsg = firstErrorMessage.toLowerCase();
            if (lowerMsg.contains('unable to lock row')) {
                primaryErrorCode = AIAgentConstants.ERR_CODE_RECORD_LOCKED;
            } else if (lowerMsg.contains('insufficient access') || lowerMsg.contains('access denied')) {
                primaryErrorCode = AIAgentConstants.ERR_CODE_PERMISSION_DENIED;
            } else if (lowerMsg.contains('required field missing')) {
                primaryErrorCode = AIAgentConstants.ERR_CODE_DML_ERROR;
            } else if (lowerMsg.contains('not found')) {
                primaryErrorCode = AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND;
            }

            return this.runtimeError(internalDetails, primaryErrorCode, ex);
        } else if (ex instanceof System.QueryException) {
            String errorCode = ex.getMessage().toLowerCase().contains('security enforced') ||
                ex.getMessage().toLowerCase().contains('insufficient access')
                ? AIAgentConstants.ERR_CODE_PERMISSION_DENIED
                : AIAgentConstants.ERR_CODE_SOQL_ERROR;
            return this.runtimeError('Data query failed: ' + ex.getMessage(), errorCode, ex);
        } else if (ex instanceof System.CalloutException) {
            return this.runtimeError(
                'Failed calling external service: ' + ex.getMessage(),
                AIAgentConstants.ERR_CODE_CONNECT_API_ERROR,
                ex
            );
        } else if (ex instanceof System.LimitException) {
            return this.runtimeError(
                'Operation exceeded Salesforce limits: ' + ex.getMessage(),
                AIAgentConstants.ERR_CODE_SYSTEM_LIMIT /* Need to add this */,
                ex
            );
        } else if (ex instanceof ValidationException) {
            ValidationException ve = (ValidationException) ex;
            return this.validationError(ve.getMessage(), ve.fieldName);
        } else if (ex instanceof ActionSecurityException) {
            ActionSecurityException se = (ActionSecurityException) ex;
            return this.securityError(se.getMessage());
        }

        return this.runtimeError(ex.getMessage(), AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR, ex);
    }

    /**
     * @description Helper to consistently create a FAILED ActionResult.
     * @param internalDetails Developer/debug information about the failure.
     * @param errorCode Optional machine-readable error code.
     * @return ActionResult instance indicating failure.
     */
    public static ActionResult createErrorResult(String internalDetails, String errorCode) {
        String summaryForLlm = 'Action failed: ' + internalDetails?.abbreviate(200);
        return new ActionResult(summaryForLlm, internalDetails, errorCode);
    }

    /**
     * @description Helper to consistently create a SUCCESSFUL ActionResult.
     * @param outputForLlm Object (serializable) payload to return to the LLM.
     * @param internalDetails Developer/debug information about the successful execution.
     * @return ActionResult instance indicating success.
     */
    public static ActionResult createSuccessResult(Object outputForLlm, String internalDetails) {
        return new ActionResult(outputForLlm, internalDetails);
    }

    public virtual class ParsedArguments {
    }

    public class ValidationException extends AIAgentException {
        public String fieldName;
        public String message;

        public ValidationException(String message, String fieldName) {
            this.message = message;
            this.fieldName = fieldName;
        }
    }

    public class ActionSecurityException extends AIAgentException {
    }
}
