/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * EmailServiceConfiguration provides configuration and utility methods for email-triggered agent processing.
 * This class manages email routing rules, agent selection, and email service setup.
 *
 * Responsibilities:
 *   - Manages email routing configuration
 *   - Provides utilities for email address validation and parsing
 *   - Handles email service setup and configuration
 *   - Supports email filtering and routing rules
 */
public class EmailServiceConfiguration {
    /**
     * Exception thrown when email service configuration is invalid.
     */
    public class EmailConfigurationException extends Exception {
    }

    /**
     * Data structure for email routing rules.
     */
    public class EmailRoutingRule {
        public String ruleName;
        public String description;
        public Id agentDefinitionId;
        public String fromAddressPattern;
        public String toAddressPattern;
        public String subjectPattern;
        public String bodyPattern;
        public Integer priority;
        public Boolean isActive;
        public Map<String, String> additionalCriteria;
    }

    /**
     * Gets the default email routing configuration.
     * In a production system, this would query custom metadata or configuration objects.
     *
     * @return List<EmailRoutingRule> list of active routing rules
     */
    public static List<EmailRoutingRule> getEmailRoutingRules() {
        List<EmailRoutingRule> rules = new List<EmailRoutingRule>();

        try {
            // Query for active AI agents that support email processing
            List<AIAgentDefinition__c> emailAgents = [
                SELECT Id, DeveloperName__c, Name, Description__c, IsActive__c
                FROM AIAgentDefinition__c
                WHERE IsActive__c = TRUE AND AgentType__c = 'Email'
                ORDER BY Name
            ];

            // Create default routing rules for each email-enabled agent
            Integer priority = 1;
            for (AIAgentDefinition__c agent : emailAgents) {
                EmailRoutingRule rule = new EmailRoutingRule();
                rule.ruleName = 'Default_' + agent.DeveloperName__c;
                rule.description = 'Default routing rule for ' + agent.Name;
                rule.agentDefinitionId = agent.Id;
                rule.fromAddressPattern = '*'; // Match all senders
                rule.toAddressPattern = '*'; // Match all recipients
                rule.subjectPattern = '*'; // Match all subjects
                rule.bodyPattern = '*'; // Match all content
                rule.priority = priority++;
                rule.isActive = true;
                rule.additionalCriteria = new Map<String, String>();

                rules.add(rule);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[EmailServiceConfiguration] Error loading routing rules: ' + e.getMessage());
        }

        return rules;
    }

    /**
     * Finds the best matching routing rule for an email.
     *
     * @param fromAddress Sender's email address
     * @param toAddress Recipient's email address
     * @param subject Email subject
     * @param body Email body content
     * @return EmailRoutingRule matching rule or null if no match
     */
    public static EmailRoutingRule findMatchingRule(String fromAddress, String toAddress, String subject, String body) {
        List<EmailRoutingRule> rules = getEmailRoutingRules();

        // Sort by priority (lower number = higher priority)
        rules.sort(new EmailRoutingRuleComparator());

        for (EmailRoutingRule rule : rules) {
            if (!rule.isActive) {
                continue;
            }

            // Check if email matches this rule's criteria
            if (
                matchesPattern(fromAddress, rule.fromAddressPattern) &&
                matchesPattern(toAddress, rule.toAddressPattern) &&
                matchesPattern(subject, rule.subjectPattern) &&
                matchesPattern(body, rule.bodyPattern)
            ) {
                System.debug(LoggingLevel.INFO, '[EmailServiceConfiguration] Email matched rule: ' + rule.ruleName);
                return rule;
            }
        }

        System.debug(LoggingLevel.WARN, '[EmailServiceConfiguration] No matching rule found for email from: ' + fromAddress);
        return null;
    }

    /**
     * Checks if a text value matches a pattern.
     * Supports simple wildcard matching with '*' character.
     *
     * @param text The text to check
     * @param pattern The pattern to match against
     * @return Boolean true if text matches pattern
     */
    private static Boolean matchesPattern(String text, String pattern) {
        if (String.isBlank(pattern) || pattern == '*') {
            return true; // Wildcard matches everything
        }

        if (String.isBlank(text)) {
            return false;
        }

        // Convert to lowercase for case-insensitive matching
        String lowerText = text.toLowerCase();
        String lowerPattern = pattern.toLowerCase();

        // Simple wildcard matching
        if (lowerPattern.contains('*')) {
            // Simple wildcard implementation without regex
            if (lowerPattern == '*') {
                return true;
            } else if (lowerPattern.startsWith('*') && lowerPattern.endsWith('*')) {
                // Pattern like "*something*" - check if text contains the middle part
                String middle = lowerPattern.substring(1, lowerPattern.length() - 1);
                return lowerText.contains(middle);
            } else if (lowerPattern.startsWith('*')) {
                // Pattern like "*something" - check if text ends with the suffix
                String suffix = lowerPattern.substring(1);
                return lowerText.endsWith(suffix);
            } else if (lowerPattern.endsWith('*')) {
                // Pattern like "something*" - check if text starts with the prefix
                String prefix = lowerPattern.substring(0, lowerPattern.length() - 1);
                return lowerText.startsWith(prefix);
            } else {
                // Pattern has * in the middle - more complex matching
                return matchesComplexWildcard(lowerText, lowerPattern);
            }
        } else {
            // Exact match
            return lowerText.equals(lowerPattern);
        }
    }

    /**
     * Handles complex wildcard patterns with * in the middle.
     *
     * @param text The text to check
     * @param pattern The pattern with wildcards
     * @return Boolean true if text matches pattern
     */
    private static Boolean matchesComplexWildcard(String text, String pattern) {
        // Split pattern by * and check each part sequentially
        List<String> parts = pattern.split('\\*');
        Integer textIndex = 0;

        for (Integer i = 0; i < parts.size(); i++) {
            String part = parts[i];
            if (String.isBlank(part)) {
                continue; // Skip empty parts from consecutive *
            }

            Integer foundIndex = text.indexOf(part, textIndex);
            if (foundIndex == -1) {
                return false; // Part not found
            }

            // For the first part, it must start at the beginning (unless pattern starts with *)
            if (i == 0 && !pattern.startsWith('*') && foundIndex != 0) {
                return false;
            }

            textIndex = foundIndex + part.length();
        }

        // For the last part, check if pattern ends with * or if we've consumed all text
        return pattern.endsWith('*') || textIndex == text.length();
    }

    /**
     * Validates an email address format.
     *
     * @param emailAddress The email address to validate
     * @return Boolean true if email address is valid
     */
    public static Boolean isValidEmailAddress(String emailAddress) {
        if (String.isBlank(emailAddress)) {
            return false;
        }

        // Basic email validation without regex
        // Check for @ symbol and basic structure
        if (!emailAddress.contains('@')) {
            return false;
        }

        List<String> parts = emailAddress.split('@');
        if (parts.size() != 2) {
            return false; // Should have exactly one @ symbol
        }

        String localPart = parts[0];
        String domainPart = parts[1];

        // Basic validation rules
        if (String.isBlank(localPart) || String.isBlank(domainPart)) {
            return false;
        }

        // Domain must contain at least one dot
        if (!domainPart.contains('.')) {
            return false;
        }

        // Basic length checks
        if (localPart.length() > 64 || domainPart.length() > 255) {
            return false;
        }

        // Check for invalid characters (basic check)
        if (emailAddress.contains('..') || emailAddress.startsWith('.') || emailAddress.endsWith('.')) {
            return false;
        }

        return true;
    }

    /**
     * Extracts the domain from an email address.
     *
     * @param emailAddress The email address
     * @return String the domain part of the email address
     */
    public static String extractDomain(String emailAddress) {
        if (String.isBlank(emailAddress) || !emailAddress.contains('@')) {
            return null;
        }

        return emailAddress.substring(emailAddress.indexOf('@') + 1);
    }

    /**
     * Gets email service configuration settings.
     * In a production system, this would query custom settings or metadata.
     *
     * @return Map<String, Object> configuration settings
     */
    public static Map<String, Object> getEmailServiceSettings() {
        return new Map<String, Object>{
            'maxEmailSize' => 25 *
            1024 *
            1024, // 25MB max email size
            'maxAttachments' => 10, // Maximum number of attachments
            'maxAttachmentSize' => 5 *
            1024 *
            1024, // 5MB max attachment size
            'allowedAttachmentTypes' => new List<String>{ 'pdf', 'doc', 'docx', 'txt', 'csv', 'xlsx', 'jpg', 'png' },
            'enableAttachmentProcessing' => true,
            'enableHtmlProcessing' => true,
            'defaultTimeoutSeconds' => 300, // 5 minutes
            'enableEmailLogging' => true,
            'logLevel' => 'INFO'
        };
    }

    /**
     * Comparator class for sorting email routing rules by priority.
     */
    public class EmailRoutingRuleComparator implements Comparator<EmailRoutingRule> {
        public Integer compare(EmailRoutingRule rule1, EmailRoutingRule rule2) {
            if (rule1.priority == rule2.priority) {
                return 0;
            }
            return rule1.priority < rule2.priority ? -1 : 1;
        }
    }

    /**
     * Creates a sample email service configuration for testing.
     * This method can be used during development and testing.
     *
     * @return Map<String, Object> sample configuration
     */
    public static Map<String, Object> createSampleConfiguration() {
        return new Map<String, Object>{
            'emailServiceAddress' => 'aiagent@your-org.salesforce.com',
            'routingRules' => new List<Map<String, Object>>{
                new Map<String, Object>{ 'name' => 'Support Emails', 'pattern' => 'support@*', 'agentName' => 'SupportAgent', 'priority' => 1 },
                new Map<String, Object>{ 'name' => 'Sales Emails', 'pattern' => 'sales@*', 'agentName' => 'SalesAgent', 'priority' => 2 },
                new Map<String, Object>{ 'name' => 'General Emails', 'pattern' => '*', 'agentName' => 'GeneralAgent', 'priority' => 99 }
            }
        };
    }
}
