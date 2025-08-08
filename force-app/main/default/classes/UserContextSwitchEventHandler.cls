/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Handler for UserContextSwitchEvent__e platform events.
 *              Processes context switch events for audit logging and monitoring.
 */
public inherited sharing class UserContextSwitchEventHandler {
    /**
     * @description Processes UserContextSwitchEvent__e platform events
     * @param events List of UserContextSwitchEvent__e records
     */
    public static void handleContextSwitchEvents(List<UserContextSwitchEvent__e> events) {
        String logPrefix = '[UserContextSwitchEventHandler] ';

        if (events == null || events.isEmpty()) {
            return;
        }

        Id executionUserId = UserInfo.getUserId();

        for (UserContextSwitchEvent__e event : events) {
            try {
                processMessageInSwitchedContext(event);
            } catch (Exception e) {
                try {
                    TurnLifecycleService tls = new TurnLifecycleService();
                    tls.failTurn(
                        event.SessionId__c,
                        event.TurnIdentifier__c,
                        'Context switch processing failed: ' + e.getMessage(),
                        AIAgentConstants.ERR_CODE_UNEXPECTED_ERROR,
                        logPrefix
                    );
                } catch (Exception failEx) {
                }
            }
        }
    }

    /**
     * @description Processes the message in the switched user context by enqueuing a Queueable job
     * @param event The UserContextSwitchEvent__e containing message processing details
     */
    private static void processMessageInSwitchedContext(UserContextSwitchEvent__e event) {
        String logPrefix = '[UserContextSwitchEventHandler] ';

        try {
            AIAgentDefinition__c agentDefinition = AIAgentConfigService.getAgentDefinition(event.AgentDefinitionId__c);
            if (agentDefinition == null) {
                throw new UserContextException('Agent definition not found: ' + event.AgentDefinitionId__c);
            }

            UserContextMessageProcessor processor = new UserContextMessageProcessor(event);
            System.enqueueJob(processor);

            performAuditLogging(event, UserInfo.getUserId());
        } catch (Exception e) {
            throw e;
        }
    }

    /**
     * @description Performs additional audit logging for context switch events
     * @param event The UserContextSwitchEvent__e to audit
     * @param executionUserId The ID of the user the code is currently running as.
     */
    private static void performAuditLogging(UserContextSwitchEvent__e event, Id executionUserId) {
        String logPrefix = '[UserContextSwitchEventHandler] ';

        try {
            if (executionUserId != null) {
                List<User> executionUsers = [
                    SELECT Id, Profile.Name, UserRole.Name
                    FROM User
                    WHERE Id = :executionUserId
                    LIMIT 1
                ];

                if (!executionUsers.isEmpty()) {
                    User executionUser = executionUsers[0];
                    String profileName = executionUser.Profile?.Name;

                    if (profileName != null && (profileName.contains('System Administrator') || profileName.contains('Admin'))) {
                    }
                }
            }
        } catch (Exception e) {
        }
    }

    public class UserContextException extends AIAgentException {
    }
}
