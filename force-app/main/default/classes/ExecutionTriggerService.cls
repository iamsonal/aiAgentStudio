/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ExecutionTriggerService manages ExecutionTrigger__c records for the unified agentic framework.
 * Handles trigger configuration, activation, and execution tracking for non-conversational agent invocations.
 *
 * Responsibilities:
 *   - Create and manage ExecutionTrigger__c configurations
 *   - Find active triggers based on type and conditions
 *   - Track trigger execution statistics and failures
 *   - Support different trigger types: Email, Schedule, DataChange, API, Manual, Batch
 *
 * This service enables the framework to support agent invocation beyond conversational patterns,
 * allowing agents to be triggered by emails, scheduled tasks, data changes, and external APIs.
 */
public inherited sharing class ExecutionTriggerService {
    // --- CONSTANTS ---
    private static final String LOG_PREFIX = '[ExecutionTriggerService] ';

    // --- EXCEPTIONS ---
    public class ExecutionTriggerException extends AIAgentException {
    }

    /**
     * Creates a new ExecutionTrigger__c record.
     *
     * @param triggerName The display name for the executionTrigger
     * @param developerName The unique developer name
     * @param agentDefinitionId The AI agent to execute when triggered
     * @param triggerType The type of executionTrigger (Email, Schedule, DataChange, etc.)
     * @param triggerConfiguration JSON configuration specific to the executionTrigger type
     * @param triggerConditions JSON conditions that must be met for executionTrigger to fire
     * @param isActive Whether the executionTrigger should be active immediately
     * @return Id of the created ExecutionTrigger__c record
     */
    public Id createTrigger(
        String triggerName,
        String developerName,
        Id agentDefinitionId,
        String triggerType,
        String triggerConfiguration,
        String triggerConditions,
        Boolean isActive
    ) {
        String logPrefix = LOG_PREFIX + '[createTrigger] ';

        try {
            ExecutionTrigger__c executionTrigger = new ExecutionTrigger__c(
                Name = triggerName,
                DeveloperName__c = developerName,
                AIAgentDefinition__c = agentDefinitionId,
                TriggerType__c = triggerType,
                TriggerConfiguration__c = triggerConfiguration,
                TriggerConditions__c = triggerConditions,
                IsActive__c = isActive != null ? isActive : true,
                ExecutionCount__c = 0,
                FailureCount__c = 0
            );

            insert executionTrigger;

            System.debug(
                LoggingLevel.INFO,
                logPrefix + 'Created ExecutionTrigger__c: ' + executionTrigger.Id + ' Name: ' + triggerName + ' Type: ' + triggerType
            );

            return executionTrigger.Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to create executionTrigger: ' + e.getMessage());
            throw new ExecutionTriggerException('Failed to create execution executionTrigger: ' + e.getMessage());
        }
    }

    /**
     * Finds active triggers by type.
     *
     * @param triggerType The type of triggers to find
     * @return List of active ExecutionTrigger__c records
     */
    public List<ExecutionTrigger__c> getActiveTriggersByType(String triggerType) {
        String logPrefix = LOG_PREFIX + '[getActiveTriggersByType] ';

        try {
            return [
                SELECT
                    Id,
                    Name,
                    DeveloperName__c,
                    AIAgentDefinition__c,
                    TriggerType__c,
                    TriggerConfiguration__c,
                    TriggerConditions__c,
                    LastExecutionTime__c,
                    NextExecutionTime__c,
                    ExecutionCount__c,
                    FailureCount__c,
                    NotificationSettings__c
                FROM ExecutionTrigger__c
                WHERE TriggerType__c = :triggerType AND IsActive__c = TRUE
                ORDER BY Name
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve triggers: ' + e.getMessage());
            throw new ExecutionTriggerException('Failed to retrieve execution triggers: ' + e.getMessage());
        }
    }

    /**
     * Finds triggers ready for scheduled execution.
     *
     * @return List of scheduled triggers that should execute now
     */
    public List<ExecutionTrigger__c> getScheduledTriggersReady() {
        String logPrefix = LOG_PREFIX + '[getScheduledTriggersReady] ';

        try {
            Datetime now = Datetime.now();

            return [
                SELECT
                    Id,
                    Name,
                    DeveloperName__c,
                    AIAgentDefinition__c,
                    TriggerConfiguration__c,
                    TriggerConditions__c,
                    NextExecutionTime__c,
                    ExecutionCount__c,
                    NotificationSettings__c
                FROM ExecutionTrigger__c
                WHERE TriggerType__c = 'Schedule' AND IsActive__c = TRUE AND NextExecutionTime__c <= :now
                ORDER BY NextExecutionTime__c
            ];
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to retrieve scheduled triggers: ' + e.getMessage());
            throw new ExecutionTriggerException('Failed to retrieve scheduled triggers: ' + e.getMessage());
        }
    }

    /**
     * Updates executionTrigger execution statistics after a executionTrigger fires.
     *
     * @param triggerId The executionTrigger that was executed
     * @param wasSuccessful Whether the execution was successful
     * @param nextExecutionTime Optional next execution time for scheduled triggers
     */
    public void updateTriggerStats(Id triggerId, Boolean wasSuccessful, Datetime nextExecutionTime) {
        String logPrefix = LOG_PREFIX + '[updateTriggerStats] ';

        try {
            ExecutionTrigger__c executionTrigger = new ExecutionTrigger__c(Id = triggerId, LastExecutionTime__c = Datetime.now());

            if (wasSuccessful) {
                // Increment execution count on success
                executionTrigger.ExecutionCount__c = getTriggerExecutionCount(triggerId) + 1;
            } else {
                // Increment failure count on failure
                executionTrigger.FailureCount__c = getTriggerFailureCount(triggerId) + 1;
            }

            if (nextExecutionTime != null) {
                executionTrigger.NextExecutionTime__c = nextExecutionTime;
            }

            update executionTrigger;

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Updated stats for executionTrigger: ' + triggerId + ' Success: ' + wasSuccessful);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update executionTrigger stats: ' + e.getMessage());
            throw new ExecutionTriggerException('Failed to update executionTrigger statistics: ' + e.getMessage());
        }
    }

    /**
     * Activates or deactivates a executionTrigger.
     *
     * @param triggerId The executionTrigger to update
     * @param isActive Whether the executionTrigger should be active
     */
    public void setTriggerActive(Id triggerId, Boolean isActive) {
        String logPrefix = LOG_PREFIX + '[setTriggerActive] ';

        try {
            ExecutionTrigger__c executionTrigger = new ExecutionTrigger__c(Id = triggerId, IsActive__c = isActive);

            update executionTrigger;

            System.debug(LoggingLevel.INFO, logPrefix + 'Set executionTrigger ' + triggerId + ' active status to: ' + isActive);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to update executionTrigger status: ' + e.getMessage());
            throw new ExecutionTriggerException('Failed to update executionTrigger status: ' + e.getMessage());
        }
    }

    /**
     * Finds triggers that match email criteria.
     *
     * @param fromAddress The sender email address
     * @param toAddress The recipient email address
     * @param subject The email subject
     * @return List of matching email triggers
     */
    public List<ExecutionTrigger__c> findEmailTriggers(String fromAddress, String toAddress, String subject) {
        String logPrefix = LOG_PREFIX + '[findEmailTriggers] ';

        try {
            List<ExecutionTrigger__c> emailTriggers = getActiveTriggersByType('Email');
            List<ExecutionTrigger__c> matchingTriggers = new List<ExecutionTrigger__c>();

            for (ExecutionTrigger__c emailTrigger : emailTriggers) {
                if (matchesEmailCriteria(emailTrigger, fromAddress, toAddress, subject)) {
                    matchingTriggers.add(emailTrigger);
                }
            }

            System.debug(LoggingLevel.DEBUG, logPrefix + 'Found ' + matchingTriggers.size() + ' matching email triggers for: ' + fromAddress);

            return matchingTriggers;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Failed to find email triggers: ' + e.getMessage());
            throw new ExecutionTriggerException('Failed to find email triggers: ' + e.getMessage());
        }
    }

    /**
     * Gets the current execution count for a executionTrigger.
     *
     * @param triggerId The executionTrigger ID
     * @return Current execution count
     */
    private Integer getTriggerExecutionCount(Id triggerId) {
        List<ExecutionTrigger__c> triggers = [
            SELECT ExecutionCount__c
            FROM ExecutionTrigger__c
            WHERE Id = :triggerId
            LIMIT 1
        ];

        return triggers.isEmpty() ? 0 : (Integer) triggers[0].ExecutionCount__c;
    }

    /**
     * Gets the current failure count for a executionTrigger.
     *
     * @param triggerId The executionTrigger ID
     * @return Current failure count
     */
    private Integer getTriggerFailureCount(Id triggerId) {
        List<ExecutionTrigger__c> triggers = [
            SELECT FailureCount__c
            FROM ExecutionTrigger__c
            WHERE Id = :triggerId
            LIMIT 1
        ];

        return triggers.isEmpty() ? 0 : (Integer) triggers[0].FailureCount__c;
    }

    /**
     * Checks if an email matches the criteria for a executionTrigger.
     *
     * @param executionTrigger The email executionTrigger configuration
     * @param fromAddress The sender email address
     * @param toAddress The recipient email address
     * @param subject The email subject
     * @return True if the email matches the executionTrigger criteria
     */
    private Boolean matchesEmailCriteria(ExecutionTrigger__c executionTrigger, String fromAddress, String toAddress, String subject) {
        try {
            if (String.isBlank(executionTrigger.TriggerConditions__c)) {
                return true; // No conditions means match all
            }

            Map<String, Object> conditions = (Map<String, Object>) JSON.deserializeUntyped(executionTrigger.TriggerConditions__c);

            // Check from domain restrictions
            List<Object> fromDomains = (List<Object>) conditions.get('fromDomains');
            if (fromDomains != null && !fromDomains.isEmpty()) {
                Boolean domainMatch = false;
                String fromDomain = fromAddress.substringAfter('@').toLowerCase();
                for (Object domain : fromDomains) {
                    if (fromDomain.equals(((String) domain).toLowerCase())) {
                        domainMatch = true;
                        break;
                    }
                }
                if (!domainMatch)
                    return false;
            }

            // Check to address restrictions
            List<Object> toAddresses = (List<Object>) conditions.get('toAddresses');
            if (toAddresses != null && !toAddresses.isEmpty()) {
                Boolean addressMatch = false;
                for (Object address : toAddresses) {
                    if (toAddress.equalsIgnoreCase((String) address)) {
                        addressMatch = true;
                        break;
                    }
                }
                if (!addressMatch)
                    return false;
            }

            // Check subject contains keywords
            List<Object> subjectContains = (List<Object>) conditions.get('subjectContains');
            if (subjectContains != null && !subjectContains.isEmpty()) {
                Boolean keywordMatch = false;
                String lowerSubject = subject.toLowerCase();
                for (Object keyword : subjectContains) {
                    if (lowerSubject.contains(((String) keyword).toLowerCase())) {
                        keywordMatch = true;
                        break;
                    }
                }
                if (!keywordMatch)
                    return false;
            }

            return true;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, LOG_PREFIX + 'Error parsing executionTrigger conditions: ' + e.getMessage());
            return false;
        }
    }
}
