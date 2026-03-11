/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Central service for executing agent capabilities. Discovers handlers, instantiates actions, and routes execution.
 */
public inherited sharing class CapabilityExecutionService {
    @TestVisible
    private static Map<String, StandardActionHandler__mdt> standardHandlerCache;
    @TestVisible
    private static Boolean isCacheInitialized = false;

    public class CapabilityExecutionException extends AIAgentException {
    }

    private class SchemaValidationFailure {
        public String errorCode;
        public String message;
        public String correctionGuidance;

        public SchemaValidationFailure(String errorCode, String message, String correctionGuidance) {
            this.errorCode = errorCode;
            this.message = message;
            this.correctionGuidance = correctionGuidance;
        }
    }

    public ActionOutcome executeSingleAction(AgentCapability__c capability, String llmArgumentsJson, ActionContext context) {
        String logPrefix =
            '[CapabilityExecutionService] [CapabilityId: ' +
            String.valueOf(capability?.Id) +
            ' | ExecutionId: ' +
            String.valueOf(context?.executionId) +
            '] ';

        if (capability == null || context == null) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Missing required input: capability or context is null.');
            throw new IllegalArgumentException('AgentCapability and ActionContext are required.');
        }

        ActionOutcome validationFailure = validateParametersAgainstSchema(capability, llmArgumentsJson, logPrefix);
        if (validationFailure != null) {
            return validationFailure;
        }

        try {
            // ImplementationType__c is a restricted picklist with only: Standard, Apex, Flow
            System.debug(LoggingLevel.INFO, logPrefix + 'Executing ' + capability.ImplementationType__c + ' capability: ' + capability.CapabilityName__c);

            IAgentAction actionHandler = createActionHandler(capability);
            ActionOutcome outcome = actionHandler.execute(capability.BackendConfiguration__c, llmArgumentsJson, context);

            if (outcome == null) {
                System.debug(LoggingLevel.ERROR, logPrefix + 'Action handler returned null outcome. This indicates a handler implementation bug.');
                outcome = ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_ACTION_HANDLER_NULL_RESULT,
                    'Action handler failed to return an outcome. Handler returned null. Check handler implementation for capability: ' +
                    capability.CapabilityName__c
                );
            } else {
                System.debug(LoggingLevel.DEBUG, logPrefix + 'Action handler returned outcome: ' + String.valueOf(outcome));
            }
            return outcome;
        } catch (CapabilityExecutionException cee) {
            System.debug(LoggingLevel.ERROR, logPrefix + cee.getMessage());
            throw cee;
        } catch (Exception ex) {
            String errMsg = 'Unexpected error during action execution for capability: ' + capability.CapabilityName__c;
            System.debug(LoggingLevel.ERROR, logPrefix + errMsg + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, errMsg + ': ' + ex.getMessage());
        }
    }

    private static IAgentAction createActionHandler(AgentCapability__c capability) {
        if (capability == null)
            throw new CapabilityExecutionException('AgentCapability cannot be null.');

        ensureCacheInitialized();

        String implType = capability.ImplementationType__c;
        String implDetail = null;
        String stdActionType = null;
        if ('Standard'.equalsIgnoreCase(implType)) {
            stdActionType = capability.StandardActionType__c;
        } else if ('Apex'.equalsIgnoreCase(implType) || 'Flow'.equalsIgnoreCase(implType)) {
            implDetail = capability.ImplementationDetail__c;
        }
        String logIdentifier = ('Standard'.equalsIgnoreCase(implType)) ? stdActionType : implDetail;

        if (String.isBlank(implType))
            throw new CapabilityExecutionException('Capability (' + capability.Id + ') missing required Implementation Type.');
        if ('Standard'.equalsIgnoreCase(implType) && String.isBlank(stdActionType))
            throw new CapabilityExecutionException('Capability (' + capability.Id + ' Type=Standard) missing required Standard Action Type.');
        if (('Apex'.equalsIgnoreCase(implType) || 'Flow'.equalsIgnoreCase(implType)) && String.isBlank(implDetail))
            throw new CapabilityExecutionException('Capability (' + capability.Id + ' Type=' + implType + ') missing required Implementation Detail.');

        System.debug(
            LoggingLevel.INFO,
            '[CapabilityExecutionService] Instantiating handler for capability: Name="' +
                capability.CapabilityName__c +
                '", Type="' +
                implType +
                '", Implementation="' +
                logIdentifier +
                '"'
        );

        try {
            // ImplementationType__c is a restricted picklist with only: Standard, Apex, Flow
            if ('Standard'.equalsIgnoreCase(implType)) {
                StandardActionHandler__mdt handlerMdt = standardHandlerCache.get(stdActionType.toLowerCase());
                if (handlerMdt == null) {
                    System.debug(LoggingLevel.ERROR, '[CapabilityExecutionService] No StandardActionHandler__mdt found for key: "' + stdActionType + '".');
                    throw new CapabilityExecutionException('No active StandardActionHandler registered for key: "' + stdActionType + '".');
                }
                return instantiateAndCheckInterface(Type.forName(handlerMdt.HandlerClassName__c), handlerMdt.HandlerClassName__c);
            } else if ('Apex'.equalsIgnoreCase(implType)) {
                return instantiateAndCheckInterface(Type.forName(implDetail), implDetail);
            } else if ('Flow'.equalsIgnoreCase(implType)) {
                return instantiateAndCheckInterface(Type.forName('ActionFlowHandler'), 'ActionFlowHandler');
            }
            // Note: No else needed - picklist only allows Standard, Apex, Flow
            return null; // Unreachable, but required for compiler
        } catch (CapabilityExecutionException cee) {
            throw cee;
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[CapabilityExecutionService] Handler instantiation failed for capability: Name="' +
                    capability.CapabilityName__c +
                    '", Implementation="' +
                    logIdentifier +
                    '". Exception: ' +
                    e.getMessage()
            );
            throw new CapabilityExecutionException('Failed to instantiate handler "' + logIdentifier + '": ' + e.getMessage(), e);
        }
    }

    @TestVisible
    private static ActionOutcome validateParametersAgainstSchema(AgentCapability__c capability, String llmArgumentsJson, String logPrefix) {
        if (String.isBlank(capability.Parameters__c)) {
            return null;
        }

        Map<String, Object> schema;
        try {
            schema = (Map<String, Object>) JSON.deserializeUntyped(capability.Parameters__c);
        } catch (Exception e) {
            String msg = 'Capability "' + capability.CapabilityName__c + '" has invalid Parameters__c JSON Schema: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, logPrefix + msg);
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, msg);
        }

        if (!looksLikeJsonSchema(schema)) {
            return null;
        }

        Object args = new Map<String, Object>();
        if (String.isNotBlank(llmArgumentsJson)) {
            try {
                args = JSON.deserializeUntyped(llmArgumentsJson);
            } catch (Exception e) {
                String msg = 'Invalid JSON arguments for capability "' + capability.CapabilityName__c + '": ' + e.getMessage();
                System.debug(LoggingLevel.WARN, logPrefix + msg);
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    msg,
                    'Provide valid JSON arguments that match the Parameters__c schema.'
                );
            }
        }

        SchemaValidationFailure failure = validateSchemaNode(schema, args, 'parameters', capability.CapabilityName__c);
        if (failure == null) {
            return null;
        }

        System.debug(LoggingLevel.WARN, logPrefix + failure.message);
        return ActionOutcome.failure(failure.errorCode, failure.message, failure.correctionGuidance);
    }

    @TestVisible
    private static Boolean looksLikeJsonSchema(Map<String, Object> schema) {
        if (schema == null || schema.isEmpty()) {
            return false;
        }

        for (
            String key : new List<String>{
                'type',
                'properties',
                'required',
                'additionalProperties',
                'enum',
                'pattern',
                'minimum',
                'maximum',
                'items',
                'minItems',
                'maxItems',
                'minLength',
                'maxLength'
            }
        ) {
            if (schema.containsKey(key)) {
                return true;
            }
        }

        return false;
    }

    private static SchemaValidationFailure validateSchemaNode(Map<String, Object> schema, Object value, String path, String capabilityName) {
        if (schema == null) {
            return null;
        }

        SchemaValidationFailure typeFailure = validateType(schema.get('type'), value, path);
        if (typeFailure != null) {
            return typeFailure;
        }

        SchemaValidationFailure enumFailure = validateEnumConstraint(schema.get('enum'), value, path);
        if (enumFailure != null) {
            return enumFailure;
        }

        Object declaredType = schema.get('type');
        if (declaredType instanceof String) {
            String typeName = (String) declaredType;
            if ('object'.equals(typeName)) {
                return validateObjectNode(schema, value, path, capabilityName);
            }
            if ('array'.equals(typeName)) {
                return validateArrayNode(schema, value, path, capabilityName);
            }
            if ('string'.equals(typeName)) {
                return validateStringNode(schema, value, path);
            }
            if ('integer'.equals(typeName) || 'number'.equals(typeName)) {
                return validateNumericNode(schema, value, path, 'integer'.equals(typeName));
            }
        } else if (schema.containsKey('properties') && value instanceof Map<String, Object>) {
            return validateObjectNode(schema, value, path, capabilityName);
        }

        return null;
    }

    private static SchemaValidationFailure validateObjectNode(Map<String, Object> schema, Object value, String path, String capabilityName) {
        if (!(value instanceof Map<String, Object>)) {
            return buildInputFailure(path, 'must be a JSON object', null);
        }

        Map<String, Object> valueMap = (Map<String, Object>) value;
        Map<String, Object> properties = schema.get('properties') instanceof Map<String, Object>
            ? (Map<String, Object>) schema.get('properties')
            : new Map<String, Object>();
        Set<String> allowedProperties = new Set<String>();
        for (String key : properties.keySet()) {
            allowedProperties.add(key);
        }

        List<Object> required = schema.get('required') instanceof List<Object> ? (List<Object>) schema.get('required') : new List<Object>();
        for (Object requiredFieldObj : required) {
            String requiredField = String.valueOf(requiredFieldObj);
            if (!valueMap.containsKey(requiredField) || valueMap.get(requiredField) == null) {
                return buildInputFailure(appendPath(path, requiredField), 'is required', 'Provide a value for "' + requiredField + '".');
            }
        }

        Object additionalPropertiesSetting = schema.get('additionalProperties');
        // Framework contract: once an object schema declares explicit properties, it is closed by default
        // unless the capability author explicitly opts into extra keys via additionalProperties=true/object schema.
        Boolean allowAdditionalProperties = properties.isEmpty();
        if (additionalPropertiesSetting != null) {
            allowAdditionalProperties = Boolean.valueOf(String.valueOf(additionalPropertiesSetting)) == true;
        }
        if (!allowAdditionalProperties || additionalPropertiesSetting instanceof Map<String, Object>) {
            for (String providedKey : valueMap.keySet()) {
                if (allowedProperties.contains(providedKey)) {
                    continue;
                }

                if (additionalPropertiesSetting instanceof Map<String, Object>) {
                    SchemaValidationFailure additionalPropertyFailure = validateSchemaNode(
                        (Map<String, Object>) additionalPropertiesSetting,
                        valueMap.get(providedKey),
                        appendPath(path, providedKey),
                        capabilityName
                    );
                    if (additionalPropertyFailure != null) {
                        return additionalPropertyFailure;
                    }
                    continue;
                }

                return buildInputFailure(
                    appendPath(path, providedKey),
                    'is not declared in the capability schema',
                    allowedProperties.isEmpty()
                        ? 'Remove the undeclared property.'
                        : 'Allowed properties at ' + path + ': ' + String.join(new List<String>(allowedProperties), ', ')
                );
            }
        }

        for (String propertyName : properties.keySet()) {
            if (!valueMap.containsKey(propertyName)) {
                continue;
            }

            Object propertySchemaObj = properties.get(propertyName);
            if (!(propertySchemaObj instanceof Map<String, Object>)) {
                return buildConfigFailure(
                    'Capability "' + capabilityName + '" has invalid schema for property "' + appendPath(path, propertyName) + '".',
                    null
                );
            }

            SchemaValidationFailure nestedFailure = validateSchemaNode(
                (Map<String, Object>) propertySchemaObj,
                valueMap.get(propertyName),
                appendPath(path, propertyName),
                capabilityName
            );
            if (nestedFailure != null) {
                return nestedFailure;
            }
        }

        return null;
    }

    private static SchemaValidationFailure validateArrayNode(Map<String, Object> schema, Object value, String path, String capabilityName) {
        if (!(value instanceof List<Object>)) {
            return buildInputFailure(path, 'must be an array', null);
        }

        List<Object> values = (List<Object>) value;
        if (schema.containsKey('minItems') && values.size() < Integer.valueOf(String.valueOf(schema.get('minItems')))) {
            return buildInputFailure(path, 'must contain at least ' + String.valueOf(schema.get('minItems')) + ' item(s)', null);
        }
        if (schema.containsKey('maxItems') && values.size() > Integer.valueOf(String.valueOf(schema.get('maxItems')))) {
            return buildInputFailure(path, 'must contain no more than ' + String.valueOf(schema.get('maxItems')) + ' item(s)', null);
        }

        if (schema.get('items') instanceof Map<String, Object>) {
            Map<String, Object> itemSchema = (Map<String, Object>) schema.get('items');
            for (Integer i = 0; i < values.size(); i++) {
                SchemaValidationFailure itemFailure = validateSchemaNode(itemSchema, values[i], path + '[' + i + ']', capabilityName);
                if (itemFailure != null) {
                    return itemFailure;
                }
            }
        }

        return null;
    }

    private static SchemaValidationFailure validateStringNode(Map<String, Object> schema, Object value, String path) {
        if (!(value instanceof String)) {
            return buildInputFailure(path, 'must be a string', null);
        }

        String stringValue = (String) value;
        if (schema.containsKey('minLength') && stringValue.length() < Integer.valueOf(String.valueOf(schema.get('minLength')))) {
            return buildInputFailure(path, 'must be at least ' + String.valueOf(schema.get('minLength')) + ' character(s)', null);
        }
        if (schema.containsKey('maxLength') && stringValue.length() > Integer.valueOf(String.valueOf(schema.get('maxLength')))) {
            return buildInputFailure(path, 'must be no more than ' + String.valueOf(schema.get('maxLength')) + ' character(s)', null);
        }
        if (schema.containsKey('pattern')) {
            String regexPattern = String.valueOf(schema.get('pattern'));
            try {
                if (!Pattern.compile(regexPattern).matcher(stringValue).matches()) {
                    return buildInputFailure(path, 'does not match the required pattern', 'Provide a value that matches pattern "' + regexPattern + '".');
                }
            } catch (Exception e) {
                return buildConfigFailure('Capability schema contains an invalid regex pattern for "' + path + '": ' + regexPattern, null);
            }
        }

        return null;
    }

    private static SchemaValidationFailure validateNumericNode(Map<String, Object> schema, Object value, String path, Boolean requireInteger) {
        if (!isNumericValue(value)) {
            return buildInputFailure(path, requireInteger ? 'must be an integer' : 'must be a number', null);
        }

        Decimal numericValue = Decimal.valueOf(String.valueOf(value));
        if (requireInteger && numericValue.scale() > 0) {
            return buildInputFailure(path, 'must be an integer', null);
        }
        if (schema.containsKey('minimum') && numericValue < Decimal.valueOf(String.valueOf(schema.get('minimum')))) {
            return buildInputFailure(path, 'must be greater than or equal to ' + String.valueOf(schema.get('minimum')), null);
        }
        if (schema.containsKey('maximum') && numericValue > Decimal.valueOf(String.valueOf(schema.get('maximum')))) {
            return buildInputFailure(path, 'must be less than or equal to ' + String.valueOf(schema.get('maximum')), null);
        }

        return null;
    }

    private static SchemaValidationFailure validateType(Object typeDefinition, Object value, String path) {
        if (typeDefinition == null) {
            return null;
        }

        List<String> allowedTypes = new List<String>();
        if (typeDefinition instanceof String) {
            allowedTypes.add((String) typeDefinition);
        } else if (typeDefinition instanceof List<Object>) {
            for (Object typeName : (List<Object>) typeDefinition) {
                allowedTypes.add(String.valueOf(typeName));
            }
        }

        if (allowedTypes.isEmpty()) {
            return null;
        }

        for (String allowedType : allowedTypes) {
            if (matchesType(allowedType, value)) {
                return null;
            }
        }

        return buildInputFailure(path, 'must be of type ' + String.join(allowedTypes, ' or '), null);
    }

    private static Boolean matchesType(String typeName, Object value) {
        if ('null'.equals(typeName)) {
            return value == null;
        }
        if (value == null) {
            return false;
        }
        if ('object'.equals(typeName)) {
            return value instanceof Map<String, Object>;
        }
        if ('array'.equals(typeName)) {
            return value instanceof List<Object>;
        }
        if ('string'.equals(typeName)) {
            return value instanceof String;
        }
        if ('boolean'.equals(typeName)) {
            return value instanceof Boolean;
        }
        if ('integer'.equals(typeName)) {
            return isNumericValue(value) && Decimal.valueOf(String.valueOf(value)).scale() == 0;
        }
        if ('number'.equals(typeName)) {
            return isNumericValue(value);
        }
        return true;
    }

    private static Boolean isNumericValue(Object value) {
        return value instanceof Integer || value instanceof Long || value instanceof Double || value instanceof Decimal;
    }

    private static SchemaValidationFailure validateEnumConstraint(Object enumDefinition, Object value, String path) {
        if (!(enumDefinition instanceof List<Object>) || value == null) {
            return null;
        }

        List<String> allowedValues = new List<String>();
        for (Object allowedValue : (List<Object>) enumDefinition) {
            allowedValues.add(String.valueOf(allowedValue));
            if (valuesEqual(allowedValue, value)) {
                return null;
            }
        }

        return buildInputFailure(path, 'must be one of: ' + String.join(allowedValues, ', '), null);
    }

    private static Boolean valuesEqual(Object left, Object right) {
        if (left == null || right == null) {
            return left == right;
        }
        if (isNumericValue(left) && isNumericValue(right)) {
            return Decimal.valueOf(String.valueOf(left)) == Decimal.valueOf(String.valueOf(right));
        }
        return String.valueOf(left) == String.valueOf(right);
    }

    private static SchemaValidationFailure buildInputFailure(String path, String requirement, String guidance) {
        return new SchemaValidationFailure(
            AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
            'Invalid capability arguments: "' + path + '" ' + requirement + '.',
            guidance
        );
    }

    private static SchemaValidationFailure buildConfigFailure(String message, String guidance) {
        return new SchemaValidationFailure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, message, guidance);
    }

    private static String appendPath(String basePath, String childPath) {
        return String.isBlank(basePath) ? childPath : basePath + '.' + childPath;
    }

    private static void ensureCacheInitialized() {
        if (isCacheInitialized)
            return;

        standardHandlerCache = new Map<String, StandardActionHandler__mdt>();

        try {
            List<StandardActionHandler__mdt> handlers = [
                SELECT DeveloperName, MasterLabel, HandlerClassName__c, IsActive__c
                FROM StandardActionHandler__mdt
                WHERE IsActive__c = TRUE
            ];

            for (StandardActionHandler__mdt h : handlers) {
                if (String.isNotBlank(h.DeveloperName) && String.isNotBlank(h.HandlerClassName__c)) {
                    standardHandlerCache.put(h.DeveloperName.toLowerCase(), h);
                } else {
                    System.debug(
                        LoggingLevel.ERROR,
                        '[CapabilityExecutionService] Skipped StandardActionHandler__mdt record (Id=' + h.Id + '): missing DeveloperName or HandlerClassName.'
                    );
                }
            }

            System.debug(
                LoggingLevel.INFO,
                '[CapabilityExecutionService] Handler cache initialized: ' + standardHandlerCache.size() + ' active handlers loaded.'
            );
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[CapabilityExecutionService] CRITICAL: Unable to load Standard Action Handlers from Custom Metadata. Exception: ' + e.getMessage()
            );
            throw new CapabilityExecutionException('Failed to load Standard Action Handlers from Custom Metadata. Check CMDT configuration.', e);
        }

        isCacheInitialized = true;
    }

    private static IAgentAction instantiateAndCheckInterface(Type handlerType, String className) {
        if (handlerType == null)
            throw new CapabilityExecutionException('Handler class not found: "' + className + '". Verify the class exists and is accessible.');

        Object instanceObj = handlerType.newInstance();

        if (!(instanceObj instanceof IAgentAction)) {
            System.debug(LoggingLevel.ERROR, '[CapabilityExecutionService] Handler class "' + className + '" does not implement IAgentAction.');
            throw new CapabilityExecutionException('Class "' + className + '" must implement the IAgentAction interface.');
        }

        return (IAgentAction) instanceObj;
    }

    @TestVisible
    private static void clearCache_TestOnly() {
        standardHandlerCache = null;
        isCacheInitialized = false;
    }
}
