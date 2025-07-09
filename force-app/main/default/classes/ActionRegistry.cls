/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Factory/Registry for finding and instantiating IAgentAction implementations.
 *              Handles Standard, Apex, and Flow types via StandardActionHandler__mdt metadata.
 */
public class ActionRegistry {
    @TestVisible
    private static Map<String, StandardActionHandler__mdt> standardHandlerCache;
    @TestVisible
    private static Boolean isCacheInitialized = false;

    /** @description Custom exception for registry errors */
    public class ActionRegistryException extends AIAgentException {
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
                }
            }
        } catch (Exception e) {
            throw new ActionRegistryException('Failed to load Standard Action Handlers from Custom Metadata.', e);
        }
        isCacheInitialized = true;
    }

    public static IAgentAction createActionHandler(AgentCapability__c capability) {
        if (capability == null)
            throw new ActionRegistryException('AgentCapability cannot be null.');
        ensureCacheInitialized();

        String implType = capability.ImplementationType__c;
        String implDetail = capability.ImplementationDetail__c;
        String stdActionType = capability.StandardActionType__c;
        String logIdentifier = ('Standard'.equalsIgnoreCase(implType)) ? stdActionType : implDetail;

        if (String.isBlank(implType))
            throw new ActionRegistryException('Capability (' + capability.Id + ') missing required Implementation Type.');
        if ('Standard'.equalsIgnoreCase(implType) && String.isBlank(stdActionType))
            throw new ActionRegistryException('Capability (' + capability.Id + ' Type=Standard) missing required Standard Action Type.');
        if (('Apex'.equalsIgnoreCase(implType) || 'Flow'.equalsIgnoreCase(implType)) && String.isBlank(implDetail))
            throw new ActionRegistryException('Capability (' + capability.Id + ' Type=' + implType + ') missing required Implementation Detail.');

        try {
            switch on implType {
                when 'Standard' {
                    StandardActionHandler__mdt handlerMdt = standardHandlerCache.get(stdActionType.toLowerCase());
                    if (handlerMdt == null)
                        throw new ActionRegistryException('No active StandardActionHandler registered for key: "' + stdActionType + '".');
                    return instantiateAndCheckInterface(Type.forName(handlerMdt.HandlerClassName__c), handlerMdt.HandlerClassName__c);
                }
                when 'Apex' {
                    return instantiateAndCheckInterface(Type.forName(implDetail), implDetail);
                }
                when 'Flow' {
                    final String FLOW_HANDLER_KEY = 'RunFlow';
                    StandardActionHandler__mdt flowHandlerMdt = standardHandlerCache.get(FLOW_HANDLER_KEY.toLowerCase());
                    if (flowHandlerMdt == null)
                        throw new ActionRegistryException('Flow handler registration not found for key: "' + FLOW_HANDLER_KEY + '".');
                    return instantiateAndCheckInterface(Type.forName(flowHandlerMdt.HandlerClassName__c), flowHandlerMdt.HandlerClassName__c);
                }
                when else {
                    throw new ActionRegistryException('Unsupported Implementation Type: "' + implType + '".');
                }
            }
        } catch (ActionRegistryException are) {
            throw are;
        } catch (Exception e) {
            throw new ActionRegistryException('Failed to instantiate handler (' + logIdentifier + '): ' + e.getMessage(), e);
        }
    }

    private static IAgentAction instantiateAndCheckInterface(Type handlerType, String className) {
        if (handlerType == null)
            throw new ActionRegistryException('Handler class not found: "' + className + '".');
        Object instanceObj = handlerType.newInstance();
        if (!(instanceObj instanceof IAgentAction)) {
            throw new ActionRegistryException('Class ' + className + ' must implement IAgentAction.');
        }
        return (IAgentAction) instanceObj;
    }

    @TestVisible
    private static void clearCache_TestOnly() {
        standardHandlerCache = null;
        isCacheInitialized = false;
    }
}
