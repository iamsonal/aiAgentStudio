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

        ActionOutcome validationFailure = validateRequiredParameters(capability, llmArgumentsJson, logPrefix);
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
        String implDetail = capability.ImplementationDetail__c;
        String stdActionType = capability.StandardActionType__c;
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

    /**
     * @description Validates that all fields listed in the capability's JSON Schema "required" array are
     * present and non-null in the LLM-supplied arguments. Returns a structured failure outcome if any
     * required field is missing so the LLM receives an actionable INPUT_VALIDATION error rather than
     * a NullPointerException from deep inside the action handler.
     *
     * @return null if validation passes, or an ActionOutcome.failure if required fields are absent.
     */
    @TestVisible
    private static ActionOutcome validateRequiredParameters(AgentCapability__c capability, String llmArgumentsJson, String logPrefix) {
        if (String.isBlank(capability.Parameters__c)) {
            return null;
        }

        Map<String, Object> schema;
        try {
            schema = (Map<String, Object>) JSON.deserializeUntyped(capability.Parameters__c);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, logPrefix + 'Could not parse Parameters__c as JSON schema, skipping required-field validation: ' + e.getMessage());
            return null;
        }

        List<Object> required = (List<Object>) schema.get('required');
        if (required == null || required.isEmpty()) {
            return null;
        }

        Map<String, Object> args = new Map<String, Object>();
        if (String.isNotBlank(llmArgumentsJson)) {
            try {
                args = (Map<String, Object>) JSON.deserializeUntyped(llmArgumentsJson);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, logPrefix + 'Could not parse llmArgumentsJson, skipping required-field validation: ' + e.getMessage());
                return null;
            }
        }

        List<String> missing = new List<String>();
        for (Object req : required) {
            String fieldName = (String) req;
            if (!args.containsKey(fieldName) || args.get(fieldName) == null) {
                missing.add(fieldName);
            }
        }

        if (missing.isEmpty()) {
            return null;
        }

        String msg =
            'Missing required parameter(s) for capability "' +
            capability.CapabilityName__c +
            '": ' +
            String.join(missing, ', ') +
            '. Please provide all required fields and retry.';
        System.debug(LoggingLevel.WARN, logPrefix + msg);
        return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, msg);
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
