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

        try {
            switch on capability.ImplementationType__c {
                when 'Standard', 'Apex', 'Flow' {
                    System.debug(
                        LoggingLevel.INFO,
                        logPrefix + 'Executing ' + capability.ImplementationType__c + ' capability: ' + capability.CapabilityName__c
                    );

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
                }
                when else {
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
