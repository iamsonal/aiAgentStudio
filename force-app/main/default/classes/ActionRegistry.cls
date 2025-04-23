/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Factory/Registry for finding and instantiating IAgentAction implementations
 *              based on ActionDefinition__c configuration. Handles Standard, Apex, and Flow types.
 *              Standard action handlers are defined via StandardActionHandler__mdt custom metadata.
 */
public class ActionRegistry {
    @TestVisible
    private static Map<String, StandardActionHandler__mdt> standardHandlerCache;
    @TestVisible
    private static Boolean isCacheInitialized = false;

    /**
     * @description Ensures the cache for Standard Action Handler CMDT records is initialized once per transaction.
     */
    private static void ensureCacheInitialized() {
        if (isCacheInitialized) {
            return;
        }
        standardHandlerCache = new Map<String, StandardActionHandler__mdt>();
        try {
            List<StandardActionHandler__mdt> activeHandlers = [
                SELECT DeveloperName, MasterLabel, HandlerClassName__c, IsActive__c
                FROM StandardActionHandler__mdt
                WHERE IsActive__c = TRUE
            ];
            for (StandardActionHandler__mdt handler : activeHandlers) {
                if (String.isNotBlank(handler.DeveloperName) && String.isNotBlank(handler.HandlerClassName__c)) {
                    standardHandlerCache.put(handler.DeveloperName.toLowerCase(), handler);
                } else {
                }
            }
        } catch (Exception e) {
        }
        isCacheInitialized = true;
    }

    /**
     * @description Creates an IAgentAction instance for a given ActionDefinition__c ID.
     * @param actionDefinitionId The ID of the ActionDefinition__c record.
     * @return An instance of the IAgentAction implementation.
     * @throws ActionRegistry.ActionRegistryException If lookup fails, class not found, type mismatch, or instantiation fails.
     */
    public static IAgentAction createActionHandler(Id actionDefinitionId) {
        if (actionDefinitionId == null) {
            throw new ActionRegistryException('Action Definition ID cannot be null.');
        }

        ensureCacheInitialized();

        List<ActionDefinition__c> definitions = [
            SELECT Id, Name, ImplementationType__c, ImplementationName__c, StandardActionType__c
            FROM ActionDefinition__c
            WHERE Id = :actionDefinitionId AND IsActive__c = TRUE
            LIMIT 1
        ];

        if (definitions.isEmpty()) {
            throw new ActionRegistryException('Active Action Definition not found for ID: ' + actionDefinitionId);
        }
        ActionDefinition__c definition = definitions[0];
        String implType = definition.ImplementationType__c;

        String standardActionType = definition.StandardActionType__c;
        String implName = definition.ImplementationName__c;

        if (String.isBlank(implType)) {
            throw new ActionRegistryException(
                'Action Definition ' + actionDefinitionId + ' missing required Implementation Type.'
            );
        }
        if ('Standard'.equalsIgnoreCase(implType) && String.isBlank(standardActionType)) {
            throw new ActionRegistryException(
                'Action Definition ' +
                    actionDefinitionId +
                    ' (Type: Standard) missing required Standard Action Type selection.'
            );
        }
        if (('Apex'.equalsIgnoreCase(implType) || 'Flow'.equalsIgnoreCase(implType)) && String.isBlank(implName)) {
            throw new ActionRegistryException(
                'Action Definition ' +
                    actionDefinitionId +
                    ' (Type: ' +
                    implType +
                    ') missing required Implementation Name.'
            );
        }

        IAgentAction actionInstance = null;
        String logIdentifier = ('Standard'.equalsIgnoreCase(implType)) ? standardActionType : implName;

        try {
            switch on implType {
                when 'Standard' {
                    String cacheKey = standardActionType.toLowerCase();
                    if (!standardHandlerCache.containsKey(cacheKey)) {
                        throw new ActionRegistryException(
                            'No active standard handler registered in StandardActionHandler__mdt for key: "' +
                                standardActionType +
                                '" (ActionDefinition ID: ' +
                                definition.Id +
                                ')'
                        );
                    }
                    StandardActionHandler__mdt handlerMdt = standardHandlerCache.get(cacheKey);
                    String handlerClassName = handlerMdt.HandlerClassName__c;

                    Type standardType = Type.forName(handlerClassName);
                    if (standardType == null) {
                        throw new ActionRegistryException(
                            'Handler class not found: "' +
                                handlerClassName +
                                '" defined in StandardActionHandler__mdt for key: "' +
                                standardActionType +
                                '".'
                        );
                    }
                    actionInstance = instantiateAndCheckInterface(standardType);
                }
                when 'Apex' {
                    Type apexType = Type.forName(implName);
                    if (apexType == null) {
                        throw new ActionRegistryException(
                            'Apex class not found: "' + implName + '" for Action Definition ID: ' + definition.Id
                        );
                    }
                    actionInstance = instantiateAndCheckInterface(apexType);
                }
                when 'Flow' {
                    final String FLOW_HANDLER_KEY = 'RunFlow';
                    String flowCacheKey = FLOW_HANDLER_KEY.toLowerCase();

                    if (!standardHandlerCache.containsKey(flowCacheKey)) {
                        throw new ActionRegistryException(
                            'Standard Flow handler metadata not found. Ensure a StandardActionHandler__mdt record exists with DeveloperName = "' +
                                FLOW_HANDLER_KEY +
                                '".'
                        );
                    }
                    StandardActionHandler__mdt flowHandlerMdt = standardHandlerCache.get(flowCacheKey);
                    String flowWrapperClassName = flowHandlerMdt.HandlerClassName__c;

                    Type flowWrapperType = Type.forName(flowWrapperClassName);
                    if (flowWrapperType == null) {
                        throw new ActionRegistryException(
                            'Flow handler class not found: "' +
                                flowWrapperClassName +
                                '" defined in StandardActionHandler__mdt for key: "' +
                                FLOW_HANDLER_KEY +
                                '".'
                        );
                    }

                    actionInstance = instantiateAndCheckInterface(flowWrapperType);
                }
                when else {
                    throw new ActionRegistryException(
                        'Unsupported Implementation Type: "' + implType + '" for Action Definition ID: ' + definition.Id
                    );
                }
            }
            return actionInstance;
        } catch (Exception e) {
            if (!(e instanceof ActionRegistryException)) {
                throw new ActionRegistryException(
                    'Failed to instantiate action handler for definition "' + definition.Name + '": ' + e.getMessage(),
                    e
                );
            } else {
                throw e;
            }
        }
    }

    /**
     * Helper to instantiate a class and verify it implements IAgentAction.
     */
    private static IAgentAction instantiateAndCheckInterface(Type handlerType) {
        Object instanceObj = handlerType.newInstance();
        if (!(instanceObj instanceof IAgentAction)) {
            throw new ActionRegistryException('Class ' + handlerType.getName() + ' must implement IAgentAction.');
        }
        return (IAgentAction) instanceObj;
    }

    @TestVisible
    private static void clearCache_TestOnly() {
        standardHandlerCache = null;
        isCacheInitialized = false;
    }

    /** Custom Exception for registry/instantiation errors */
    public class ActionRegistryException extends AIAgentException {
    }
}
