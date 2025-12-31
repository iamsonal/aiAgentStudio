/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Central service for executing agent capabilities with integrated handler registry and routing.
 * Consolidated from ActionRegistry and CapabilityExecutionRouter to eliminate unnecessary separation
 * between "finding the code" and "running the code".
 *
 * Responsibilities:
 *   - Discovers and caches action handlers from StandardActionHandler__mdt
 *   - Instantiates appropriate IAgentAction implementations based on capability configuration
 *   - Routes execution to handlers for Standard, Apex, and Flow capability types
 *   - Manages error handling and outcome reporting
 */
public inherited sharing class CapabilityExecutionService {
    @TestVisible
    private static Map<String, StandardActionHandler__mdt> standardHandlerCache;
    @TestVisible
    private static Boolean isCacheInitialized = false;

    /**
     * Exception for action handler registration, instantiation, or execution errors.
     */
    public class CapabilityExecutionException extends AIAgentException {
    }

    // ===================================================================================
    // PUBLIC EXECUTION API
    // ===================================================================================

    /**
     * Executes a single agent capability by instantiating and routing to appropriate handler.
     *
     * @param capability         Agent capability record (required)
     * @param llmArgumentsJson   LLM arguments JSON
     * @param context            Action context (required)
     * @return                   Action outcome
     * @throws IllegalArgumentException if capability or context is null
     */
    public ActionOutcome executeSingleAction(AgentCapability__c capability, String llmArgumentsJson, ActionContext context) {
        String logPrefix =
            '[CapabilityExecutionService] [CapabilityId: ' +
            String.valueOf(capability?.Id) +
            ' | ExecutionId: ' +
            String.valueOf(context?.executionId) +
            '] ';

        // Validate required parameters
        if (capability == null || context == null) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Missing required input: capability or context is null.');
            throw new IllegalArgumentException('AgentCapability and ActionContext are required.');
        }

        try {
            // Route to the correct execution engine based on implementation type
            switch on capability.ImplementationType__c {
                when 'Standard', 'Apex', 'Flow' {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix + 'Executing ' + capability.ImplementationType__c + ' capability: ' + capability.CapabilityName__c
                    );

                    // Create handler (factory pattern integrated)
                    IAgentAction actionHandler = createActionHandler(capability);

                    // Execute the action handler and capture the outcome
                    ActionOutcome outcome = actionHandler.execute(capability.BackendConfiguration__c, llmArgumentsJson, context);

                    if (outcome == null) {
                        // Defensive: handler should never return null; treat as implementation bug
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
                }
                when else {
                    // Unsupported implementation type: log and return configuration error
                    String errorMsg =
                        'Unsupported ImplementationType__c: "' +
                        String.valueOf(capability.ImplementationType__c) +
                        '" for capability: ' +
                        capability.CapabilityName__c +
                        '. Valid types: Standard, Apex, Flow.';
                    System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
                    return ActionOutcome.failure(AIAgentConstants.ERR_CODE_CONFIG_ERROR, errorMsg);
                }
            }
        } catch (CapabilityExecutionException cee) {
            System.debug(LoggingLevel.ERROR, logPrefix + cee.getMessage());
            throw cee;
        } catch (Exception ex) {
            String errMsg = 'Unexpected error during action execution for capability: ' + capability.CapabilityName__c;
            System.debug(LoggingLevel.ERROR, logPrefix + errMsg + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString());
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, errMsg + ': ' + ex.getMessage());
        }
    }

    // ===================================================================================
    // HANDLER REGISTRY (Consolidated from ActionRegistry)
    // ===================================================================================

    /**
     * Creates and returns an IAgentAction handler for the given AgentCapability__c record.
     *
     * @param capability The AgentCapability__c record describing the action to instantiate (required)
     * @return An IAgentAction implementation matching the capability's configuration
     * @throws CapabilityExecutionException if configuration is invalid, handler cannot be found, or instantiation fails
     */
    private static IAgentAction createActionHandler(AgentCapability__c capability) {
        if (capability == null)
            throw new CapabilityExecutionException('AgentCapability cannot be null.');

        ensureCacheInitialized();

        String implType = capability.ImplementationType__c;
        String implDetail = capability.ImplementationDetail__c; // For Apex/Flow
        String stdActionType = capability.StandardActionType__c; // For Standard
        String logIdentifier = ('Standard'.equalsIgnoreCase(implType)) ? stdActionType : implDetail;

        // Validate configuration fields for the selected implementation type
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
            switch on implType {
                when 'Standard' {
                    StandardActionHandler__mdt handlerMdt = standardHandlerCache.get(stdActionType.toLowerCase());
                    if (handlerMdt == null) {
                        System.debug(LoggingLevel.ERROR, '[CapabilityExecutionService] No StandardActionHandler__mdt found for key: "' + stdActionType + '".');
                        throw new CapabilityExecutionException('No active StandardActionHandler registered for key: "' + stdActionType + '".');
                    }
                    return instantiateAndCheckInterface(Type.forName(handlerMdt.HandlerClassName__c), handlerMdt.HandlerClassName__c);
                }
                when 'Apex' {
                    return instantiateAndCheckInterface(Type.forName(implDetail), implDetail);
                }
                when 'Flow' {
                    final String FLOW_HANDLER_KEY = 'RunFlow';
                    StandardActionHandler__mdt flowHandlerMdt = standardHandlerCache.get(FLOW_HANDLER_KEY.toLowerCase());
                    if (flowHandlerMdt == null) {
                        System.debug(
                            LoggingLevel.ERROR,
                            '[CapabilityExecutionService] No Flow handler registration found for key: "' + FLOW_HANDLER_KEY + '".'
                        );
                        throw new CapabilityExecutionException('Flow handler registration not found for key: "' + FLOW_HANDLER_KEY + '".');
                    }
                    return instantiateAndCheckInterface(Type.forName(flowHandlerMdt.HandlerClassName__c), flowHandlerMdt.HandlerClassName__c);
                }
                when else {
                    System.debug(LoggingLevel.ERROR, '[CapabilityExecutionService] Unsupported Implementation Type: "' + implType + '".');
                    throw new CapabilityExecutionException('Unsupported Implementation Type: "' + implType + '".');
                }
            }
        } catch (CapabilityExecutionException cee) {
            throw cee; // Rethrow specific exceptions
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
     * Ensures handler cache is initialized from StandardActionHandler__mdt records.
     */
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

    /**
     * Instantiates the given handler class and validates it implements IAgentAction.
     *
     * @param handlerType The Type object for the handler class (must not be null)
     * @param className The class name (for error reporting)
     * @return An instance of IAgentAction implemented by the handler class
     * @throws CapabilityExecutionException if the class is not found or does not implement IAgentAction
     */
    private static IAgentAction instantiateAndCheckInterface(Type handlerType, String className) {
        if (handlerType == null)
            throw new CapabilityExecutionException('Handler class not found: "' + className + '". Verify the class exists and is accessible.');

        Object instanceObj = handlerType.newInstance(); // May throw TypeException or other instantiation errors

        if (!(instanceObj instanceof IAgentAction)) {
            System.debug(LoggingLevel.ERROR, '[CapabilityExecutionService] Handler class "' + className + '" does not implement IAgentAction.');
            throw new CapabilityExecutionException('Class "' + className + '" must implement the IAgentAction interface.');
        }

        return (IAgentAction) instanceObj;
    }

    /**
     * Clears the handler cache. Intended for use in test contexts only.
     */
    @TestVisible
    private static void clearCache_TestOnly() {
        standardHandlerCache = null;
        isCacheInitialized = false;
    }
}
