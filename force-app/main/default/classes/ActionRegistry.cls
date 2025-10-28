/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Central factory and registry for all IAgentAction implementations.
 * Discovers, registers, and instantiates action handlers based on AgentCapability__c configuration.
 */
public class ActionRegistry {
    @TestVisible
    private static Map<String, StandardActionHandler__mdt> standardHandlerCache;
    @TestVisible
    private static Boolean isCacheInitialized = false;

    /**
     * Exception for action handler registration or instantiation errors.
     */
    public class ActionRegistryException extends AIAgentException {
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
                        '[ActionRegistry] Skipped StandardActionHandler__mdt record (Id=' + h.Id + '): missing DeveloperName or HandlerClassName.'
                    );
                }
            }
            System.debug(
                LoggingLevel.INFO,
                '[ActionRegistry] Handler cache initialized: ' + standardHandlerCache.size() + ' active handlers loaded.'
            );
        } catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ActionRegistry] CRITICAL: Unable to load Standard Action Handlers from Custom Metadata. Exception: ' + e.getMessage()
            );
            throw new ActionRegistryException('Failed to load Standard Action Handlers from Custom Metadata. Check CMDT configuration.', e);
        }
        isCacheInitialized = true;
    }

    /**
     * Creates and returns an IAgentAction handler for the given AgentCapability__c record.
     *
     * @param capability The AgentCapability__c record describing the action to instantiate. Must not be null.
     * @return An IAgentAction implementation matching the capability's configuration.
     * @throws ActionRegistryException if configuration is invalid, handler cannot be found, or instantiation fails.
     *
     * Side effects: Logs detailed debug output for diagnostics and error tracing.
     */
    public static IAgentAction createActionHandler(AgentCapability__c capability) {
        if (capability == null)
            throw new ActionRegistryException('AgentCapability cannot be null.');
        ensureCacheInitialized();

        String implType = capability.ImplementationType__c;
        String implDetail = capability.ImplementationDetail__c; // For Apex/Flow
        String stdActionType = capability.StandardActionType__c; // For Standard
        String logIdentifier = ('Standard'.equalsIgnoreCase(implType)) ? stdActionType : implDetail;

        // Validate configuration fields for the selected implementation type
        if (String.isBlank(implType))
            throw new ActionRegistryException('Capability (' + capability.Id + ') missing required Implementation Type.');
        if ('Standard'.equalsIgnoreCase(implType) && String.isBlank(stdActionType))
            throw new ActionRegistryException('Capability (' + capability.Id + ' Type=Standard) missing required Standard Action Type.');
        if (('Apex'.equalsIgnoreCase(implType) || 'Flow'.equalsIgnoreCase(implType)) && String.isBlank(implDetail))
            throw new ActionRegistryException('Capability (' + capability.Id + ' Type=' + implType + ') missing required Implementation Detail.');

        System.debug(
            LoggingLevel.INFO,
            '[ActionRegistry] Instantiating handler for capability: Name="' +
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
                        System.debug(LoggingLevel.ERROR, '[ActionRegistry] No StandardActionHandler__mdt found for key: "' + stdActionType + '".');
                        throw new ActionRegistryException('No active StandardActionHandler registered for key: "' + stdActionType + '".');
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
                        System.debug(LoggingLevel.ERROR, '[ActionRegistry] No Flow handler registration found for key: "' + FLOW_HANDLER_KEY + '".');
                        throw new ActionRegistryException('Flow handler registration not found for key: "' + FLOW_HANDLER_KEY + '".');
                    }
                    return instantiateAndCheckInterface(Type.forName(flowHandlerMdt.HandlerClassName__c), flowHandlerMdt.HandlerClassName__c);
                }
                when else {
                    System.debug(LoggingLevel.ERROR, '[ActionRegistry] Unsupported Implementation Type: "' + implType + '".');
                    throw new ActionRegistryException('Unsupported Implementation Type: "' + implType + '".');
                }
            }
        } catch (ActionRegistryException are) {
            throw are;
        } // Rethrow specific exceptions
        catch (Exception e) {
            System.debug(
                LoggingLevel.ERROR,
                '[ActionRegistry] Handler instantiation failed for capability: Name="' +
                    capability.CapabilityName__c +
                    '", Implementation="' +
                    logIdentifier +
                    '". Exception: ' +
                    e.getMessage()
            );
            throw new ActionRegistryException('Failed to instantiate handler "' + logIdentifier + '": ' + e.getMessage(), e);
        }
    }

    /**
     * Instantiates the given handler class and validates it implements IAgentAction.
     *
     * @param handlerType The Type object for the handler class (must not be null)
     * @param className The class name (for error reporting)
     * @return An instance of IAgentAction implemented by the handler class
     * @throws ActionRegistryException if the class is not found or does not implement IAgentAction
     */
    private static IAgentAction instantiateAndCheckInterface(Type handlerType, String className) {
        if (handlerType == null)
            throw new ActionRegistryException('Handler class not found: "' + className + '". Verify the class exists and is accessible.');

        Object instanceObj = handlerType.newInstance(); // May throw TypeException or other instantiation errors

        if (!(instanceObj instanceof IAgentAction)) {
            System.debug(LoggingLevel.ERROR, '[ActionRegistry] Handler class "' + className + '" does not implement IAgentAction.');
            throw new ActionRegistryException('Class "' + className + '" must implement the IAgentAction interface.');
        }
        return (IAgentAction) instanceObj;
    }

    /**
     * Clears the handler cache. Intended for use in test contexts only.
     * Side effects: Resets standardHandlerCache and isCacheInitialized.
     */
    @TestVisible
    private static void clearCache_TestOnly() {
        standardHandlerCache = null;
        isCacheInitialized = false;
    }
}
