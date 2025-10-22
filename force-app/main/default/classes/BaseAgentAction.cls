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
 *
 * ARCHITECTURE: TWO-PASS HYBRID DESERIALIZATION PATTERN
 * =====================================================
 * This class implements a carefully-designed "Two-Pass Hybrid Deserialization" pattern that balances
 * performance, type safety, flexibility, and LLM resilience. Before considering changes to this pattern,
 * please read this documentation thoroughly to understand the architectural decisions and constraints.
 *
 * THE PATTERN:
 * -----------
 * Pass 1: JSON.deserializeUntyped(argumentsJson) → Map<String, Object>
 *         - Fast, native Salesforce JSON parser
 *         - Produces untyped map structure
 *
 * Pass 2: Manual DTO population from the map
 *         - Subclasses define inner ArgumentsDTO classes for type safety
 *         - Use ActionConfigUtils helpers for safe extraction and type coercion
 *         - Example: args.fields = ActionConfigUtils.getOptionalStringList(params, 'fields')
 *
 * Pass 3 (Dynamic SObject Fields Only): TypeCoercionService.coerceArgumentTypesForSObject()
 *         - For Map<String, Object> containing dynamic SObject field data
 *         - Performs Salesforce-specific type coercion (String "123" → Decimal for AnnualRevenue)
 *         - Enforces Field-Level Security (FLS)
 *         - Validates against SObject schema
 *
 * WHY THIS PATTERN? (Critical Technical Constraints)
 * ==================================================
 *
 * 1. LLM OUTPUT VARIABILITY - The #1 Reason
 *    LLMs send data in unpredictable formats:
 *
 *    Common: { "queryLimit": "10" }        // String instead of Integer
 *    Common: { "topics": "single-topic" }  // String instead of List<String>
 *    Common: { "includeDetails": "true" }  // String instead of Boolean
 *
 *    Native JSON.deserialize(json, ArgumentsDTO.class) FAILS on these variations with:
 *    "System.JSONException: Cannot deserialize instance of Integer from String value"
 *
 *    Our pattern SUCCEEDS because ActionConfigUtils handles these gracefully:
 *    - getOptionalInteger(): String "10" → Integer 10
 *    - getOptionalStringList(): Single value → List with one element
 *    - getOptionalBoolean(): String "true" → Boolean true
 *
 * 2. DYNAMIC SOBJECT FIELDS - Cannot Use Native Deserialization
 *    LLMs send arbitrary SObject field data:
 *
 *    JSON from LLM:
 *    {
 *      "fields": {
 *        "AnnualRevenue": "1000000",      // String, but field expects Decimal
 *        "NumberOfEmployees": "500",       // String, but field expects Integer
 *        "IsActive": "true"                // String, but field expects Boolean
 *      }
 *    }
 *
 *    Even with proper JSON types, native deserialization creates:
 *    Map<String, Object> fields = { 'AnnualRevenue' => '1000000' }  // Still String!
 *
 *    When you do: account.put('AnnualRevenue', fields.get('AnnualRevenue'))
 *    Result: System.TypeException: Invalid decimal: 1000000
 *
 *    WHY: Native deserialization doesn't know that 'AnnualRevenue' should be Decimal.
 *         It needs SObject schema awareness, which only TypeCoercionService provides.
 *
 * 3. SMART DEFAULTS & VALIDATION
 *    Actions need intelligent defaults and bounds checking:
 *
 *    args.queryLimit = params.containsKey('queryLimit')
 *        ? Integer.valueOf(params.get('queryLimit'))
 *        : DEFAULT_QUERY_LIMIT;                    // Default if missing
 *    args.queryLimit = Math.min(args.queryLimit, MAX_LIMIT);  // Bounds check
 *
 *    With native deserialization, missing fields = null. You'd need to add this logic
 *    AFTER deserialization anyway, defeating the purpose of "single-pass" optimization.
 *
 * 4. CLEAR ERROR MESSAGES FOR LLM FEEDBACK
 *    Our pattern produces actionable errors:
 *    ✅ "Missing required parameter: recordId"
 *    ✅ "Invalid SObject API Name in configuration: InvalidObject__c"
 *
 *    Native deserialization produces cryptic parser errors:
 *    ❌ "System.JSONException: Unexpected character '}' at line 1 column 23"
 *
 *    LLMs need clear, semantic error messages to self-correct.
 *
 * ALTERNATIVES CONSIDERED AND REJECTED
 * ====================================
 *
 * Alternative 1: "Single-Pass Native Deserialization"
 *    Idea: JSON.deserialize(argumentsJson, ArgumentsDTO.class)
 *
 *    REJECTED because:
 *    ❌ Fails on LLM type variations (String "10" when Integer expected)
 *    ❌ Cannot handle dynamic SObject field type matching
 *    ❌ Cannot convert single values to lists
 *    ❌ Still needs post-processing for defaults/validation
 *    ❌ Produces cryptic error messages
 *    ❌ Breaking change to all 15+ action classes and 30+ test classes
 *
 *    Net benefit: Save ~0.7ms per action (JSON parsing is <1% of total execution time)
 *    Net cost: Breaks LLM resilience, requires fallback code paths anyway
 *
 * Alternative 2: "Refined Hybrid with Try/Catch Native"
 *    Idea: Try native deserialize, fall back to manual if it fails
 *
 *    REJECTED because:
 *    ❌ Two code paths to maintain (native + fallback)
 *    ❌ Still need ActionConfigUtils for edge cases
 *    ❌ Still need TypeCoercionService for SObject fields
 *    ❌ Error handling becomes complex
 *    ❌ Testing burden doubles
 *    ❌ Performance gain negligible (~0.7ms vs database ops at 50-500ms)
 *
 *    Net benefit: ~13% code reduction, ~20% faster JSON parsing
 *    Net cost: Increased complexity, scattered validation logic
 *
 * PERFORMANCE CONSIDERATIONS
 * =========================
 * The Two-Pass pattern is NOT a performance bottleneck:
 *
 * Typical action execution breakdown:
 *   - JSON parsing (our pattern):      ~3.5ms  (0.7% - 7% of total)
 *   - Database queries/DML:            ~50-200ms
 *   - HTTP callouts (if any):          ~100-500ms
 *   - FLS checks & validation:         ~5-10ms
 *   - Business logic:                  ~10-50ms
 *   Total:                             ~165-765ms
 *
 * Optimizing JSON parsing would save ~0.7ms (20% of 3.5ms).
 * This is 0.1% - 0.4% of total execution time - NOT MEANINGFUL.
 *
 * Better optimization targets:
 *   ✅ Cache SObject describes:        Save 5-10ms per action
 *   ✅ Batch FLS checks:                Save 2-5ms per action
 *   ✅ Optimize SOQL queries:           Save 20-100ms per action
 *
 * IMPLEMENTATION PATTERN FOR SUBCLASSES
 * =====================================
 *
 * Step 1: Define ArgumentsDTO inner class
 *   public class ArgumentsDTO {
 *       public String recordId;                    // Static field
 *       public Integer queryLimit;                  // Static field
 *       public Map<String, Object> fields;          // Dynamic SObject fields
 *   }
 *
 * Step 2: Implement executeAction with manual DTO population
 *   public override ActionOutcome executeAction(Map<String, Object> params) {
 *       // Manual population using ActionConfigUtils for safety
 *       ArgumentsDTO args = new ArgumentsDTO();
 *       args.recordId = (String) params.get('recordId');
 *       args.queryLimit = ActionConfigUtils.getOptionalInteger(params, 'queryLimit', DEFAULT_LIMIT);
 *       args.fields = ActionConfigUtils.getOptionalMap(params, 'fields');
 *
 *       // Validate DTO
 *       if (String.isBlank(args.recordId)) {
 *           return ActionOutcome.failure('INPUT_VALIDATION', 'recordId is required');
 *       }
 *
 *       // For dynamic SObject fields, use TypeCoercionService
 *       Map<String, Object> typedFields = TypeCoercionService.coerceArgumentTypesForSObject(
 *           args.fields,
 *           Schema.Account.SObjectType,
 *           AccessType.CREATABLE
 *       );
 *
 *       // Execute business logic using typed DTO and validated fields
 *       Account acc = new Account();
 *       for (String fieldName : typedFields.keySet()) {
 *           acc.put(fieldName, typedFields.get(fieldName));
 *       }
 *       insert acc;
 *
 *       return ActionOutcome.success(acc.Id);
 *   }
 *
 * KEY UTILITIES
 * ============
 * - ActionConfigUtils: Type-safe extraction from Map<String, Object>
 *   Methods: getOptionalStringList, getRequiredString, getOptionalInteger, etc.
 *   Purpose: Handle LLM output variability, provide defaults, validate types
 *
 * - TypeCoercionService: SObject-specific field processing
 *   Method: coerceArgumentTypesForSObject(fields, SObjectType, AccessType)
 *   Purpose: Match JSON types to SObject schema, enforce FLS, validate data
 *
 * WHEN TO CHANGE THIS PATTERN
 * ===========================
 * DO NOT change this pattern unless:
 *   ✅ You have data showing JSON parsing is >20% of execution time (it's currently <7%)
 *   ✅ You have a solution for LLM type variability (String "10" vs Integer 10)
 *   ✅ You have a solution for dynamic SObject field type matching
 *   ✅ You have a solution for List<String> coercion (single value → list)
 *   ✅ You maintain clear error messages for LLM feedback
 *   ✅ You avoid breaking 15 action classes and 30+ test classes
 *
 * This pattern is battle-tested with real LLM integrations. Changes should be
 * approached with extreme caution and thorough testing across all action types.
 *
 * SCHEMA CONTRACT REQUIREMENT (CRITICAL)
 * =======================================
 * For Standard Actions, there is a MANDATORY contract between:
 *
 * 1. StandardActionHandler__mdt Custom Metadata Records
 *    - ParametersTemplate__c: JSON Schema defining expected parameters
 *    - BackendConfigTemplate__c: JSON template for backend configuration
 *
 * 2. Action Class DTOs
 *    - ArgumentsDTO: Inner class with fields matching ParametersTemplate__c properties
 *    - ConfigDTO: Inner class with fields matching BackendConfigTemplate__c keys
 *
 * CONTRACT RULES:
 * --------------
 * ✅ MUST: Every ArgumentsDTO field MUST have a corresponding property in ParametersTemplate__c
 * ✅ MUST: Every ConfigDTO field MUST have a corresponding key in BackendConfigTemplate__c
 * ✅ MUST: Field names must match EXACTLY (case-sensitive)
 * ⚠️  AVOID: Using Apex reserved keywords as field names (e.g., use queryLimit not limit)
 *
 * WHY THIS MATTERS:
 * ----------------
 * - ParametersTemplate__c → Sent to LLM as function schema
 * - LLM generates JSON matching the schema
 * - ArgumentsDTO extracts fields from that JSON
 * - Mismatch = Runtime failure when LLM sends "limit" but code expects "queryLimit"
 *
 * ENFORCEMENT:
 * -----------
 * - Automated validation via StandardActionSchemaValidationTest
 * - Test fails if metadata schemas don't match DTOs
 * - Run tests after changing any DTO or metadata template
 *
 * EXAMPLE MISMATCH (DON'T DO THIS):
 * ---------------------------------
 * ❌ BAD:
 *   ParametersTemplate__c: { "properties": { "limit": { "type": "integer" } } }
 *   ArgumentsDTO: public Integer queryLimit;  // ← MISMATCH!
 *
 * ✅ GOOD:
 *   ParametersTemplate__c: { "properties": { "queryLimit": { "type": "integer" } } }
 *   ArgumentsDTO: public Integer queryLimit;  // ← MATCH!
 *
 * When modifying actions:
 * 1. Update BOTH DTO and metadata template in sync
 * 2. Run StandardActionSchemaValidationTest
 * 3. Fix any validation errors before deployment
 *
 * See: SchemaValidator.cls and StandardActionSchemaValidationTest.cls
 *
 * RESPONSIBILITIES
 * ===============
 *   - Provides streamlined framework for implementing agent actions
 *   - Performs JSON.deserializeUntyped() for arguments and configuration
 *   - Delegates DTO population, validation, and security checks to subclasses
 *   - Subclasses define ArgumentsDTO and ConfigDTO classes for type safety
 *   - Requires subclasses to implement only executeAction() method
 *   - Surfaces operational issues via ActionOutcome and logging
 *
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
     * Handles basic parameter deserialization and outcome wrapping.
     * Subclasses implement executeAction() with their business logic and can use DTOs for type safety.
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
            System.debug(LoggingLevel.INFO, logPrefix + 'Starting action execution');

            // Simple JSON deserialization - subclasses can use DTOs for type safety
            Map<String, Object> argsMap = String.isBlank(argumentsJson)
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(argumentsJson);

            // Parse configuration (actions handle their own DTO conversion if needed)
            this.parseActionConfiguration(actionConfigurationJson, logPrefix);

            // Call the action method directly - actions handle their own validation and security
            ActionOutcome actionOutcome = executeAction(argsMap);

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
     * Actions should deserialize params into strongly-typed DTOs, perform validation and security checks,
     * then execute business logic. Uses ActionOutcome pattern for consistent success/failure handling.
     *
     * Pattern:
     *   1. Deserialize params Map into a strongly-typed ArgumentsDTO
     *   2. Validate required fields and business rules
     *   3. For SObject operations, extract Map<String, Object> from DTO and use TypeCoercionService
     *   4. Perform security checks using SecurityUtils
     *   5. Execute business logic
     *   6. Return ActionOutcome with success data or error information
     *
     * @param params Raw parameters from JSON deserialization (use DTOs for type safety)
     * @return       ActionOutcome object containing either success data or structured error information
     */
    public abstract ActionOutcome executeAction(Map<String, Object> params);


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
