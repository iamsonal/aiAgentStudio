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

    public static IAgentAction createActionHandler(Id actionDefinitionId) {
        if (actionDefinitionId == null)
            throw new ActionRegistryException('Action Definition ID cannot be null.');
        ensureCacheInitialized();

        List<ActionDefinition__c> definitions = [
            SELECT Id, Name, ImplementationType__c, ImplementationName__c, StandardActionType__c
            FROM ActionDefinition__c
            WHERE Id = :actionDefinitionId AND IsActive__c = TRUE
            LIMIT 1
        ];
        if (definitions.isEmpty())
            throw new ActionRegistryException('Active Action Definition not found for ID: ' + actionDefinitionId);

        ActionDefinition__c definition = definitions[0];
        String implType = definition.ImplementationType__c;
        String implName = definition.ImplementationName__c;
        String stdActionType = definition.StandardActionType__c;
        String logIdentifier = ('Standard'.equalsIgnoreCase(implType)) ? stdActionType : implName;

        if (String.isBlank(implType))
            throw new ActionRegistryException('Action Definition (' + actionDefinitionId + ') missing required Implementation Type.');
        if ('Standard'.equalsIgnoreCase(implType) && String.isBlank(stdActionType))
            throw new ActionRegistryException('Action Definition (' + actionDefinitionId + ' Type=Standard) missing required Standard Action Type.');
        if (('Apex'.equalsIgnoreCase(implType) || 'Flow'.equalsIgnoreCase(implType)) && String.isBlank(implName))
            throw new ActionRegistryException(
                'Action Definition (' + actionDefinitionId + ' Type=' + implType + ') missing required Implementation Name.'
            );

        IAgentAction actionInstance = null;
        try {
            switch on implType {
                when 'Standard' {
                    String cacheKey = stdActionType.toLowerCase();
                    StandardActionHandler__mdt handlerMdt = standardHandlerCache.get(cacheKey);
                    if (handlerMdt == null)
                        throw new ActionRegistryException('No active StandardActionHandler registered for key: "' + stdActionType + '".');
                    actionInstance = instantiateAndCheckInterface(Type.forName(handlerMdt.HandlerClassName__c), handlerMdt.HandlerClassName__c);
                }
                when 'Apex' {
                    actionInstance = instantiateAndCheckInterface(Type.forName(implName), implName);
                }
                when 'Flow' {
                    final String FLOW_HANDLER_KEY = 'RunFlow';
                    StandardActionHandler__mdt flowHandlerMdt = standardHandlerCache.get(FLOW_HANDLER_KEY.toLowerCase());
                    if (flowHandlerMdt == null)
                        throw new ActionRegistryException(
                            'Flow handler registration not found in StandardActionHandler__mdt for key: "' + FLOW_HANDLER_KEY + '".'
                        );
                    actionInstance = instantiateAndCheckInterface(
                        Type.forName(flowHandlerMdt.HandlerClassName__c),
                        flowHandlerMdt.HandlerClassName__c
                    );
                }
                when else {
                    throw new ActionRegistryException('Unsupported Implementation Type: "' + implType + '".');
                }
            }
            return actionInstance;
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
