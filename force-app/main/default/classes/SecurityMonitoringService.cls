/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

 /**
 * @description
 * SecurityMonitoringService provides comprehensive monitoring and alerting capabilities
 * for AI Agent security events, particularly prompt injection attempts and other
 * security-related incidents within the framework.
 *
 * Key Features:
 * - Real-time security event logging and analysis
 * - Configurable alerting thresholds and notification channels
 * - Security metrics collection and reporting
 * - Integration with Salesforce's native monitoring capabilities
 * - Automated response capabilities for high-risk events
 *
 * Security Events Monitored:
 * - Prompt injection attempts (successful and blocked)
 * - Unusual content patterns in user-generated data
 * - Repeated security violations from specific users or sources
 * - Configuration changes to security policies
 * - Failed security validations and their patterns
 */
public inherited sharing class SecurityMonitoringService {
    // Event severity levels
    public enum EventSeverity {
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL
    }

    // Event types for categorization
    public enum EventType {
        PROMPT_INJECTION_ATTEMPT,
        CONTENT_SANITIZATION,
        POLICY_VIOLATION,
        CONFIGURATION_CHANGE,
        SECURITY_BYPASS_ATTEMPT,
        ANOMALOUS_PATTERN_DETECTED
    }

    /**
     * Security event data structure
     */
    public class SecurityEvent {
        public EventType eventType;
        public EventSeverity severity;
        public String description;
        public String userId;
        public String sessionId;
        public String sourceObject;
        public String sourceField;
        public String detectedPatterns;
        public String originalContent;
        public String sanitizedContent;
        public DateTime eventTimestamp;
        public Map<String, Object> metadata;

        public SecurityEvent() {
            this.eventTimestamp = System.now();
            this.metadata = new Map<String, Object>();
        }
    }

    /**
     * Security metrics for monitoring dashboard
     */
    public class SecurityMetrics {
        public Integer totalEvents;
        public Integer criticalEvents;
        public Integer highRiskEvents;
        public Integer blockedAttempts;
        public Integer sanitizedContent;
        public Map<String, Integer> eventsByType;
        public Map<String, Integer> eventsByUser;
        public Map<String, Integer> eventsByObject;
        public DateTime periodStart;
        public DateTime periodEnd;

        public SecurityMetrics() {
            this.eventsByType = new Map<String, Integer>();
            this.eventsByUser = new Map<String, Integer>();
            this.eventsByObject = new Map<String, Integer>();
        }
    }

    private static final Integer MAX_EVENTS_PER_TRANSACTION = 10;
    private static List<SecurityEvent> pendingEvents = new List<SecurityEvent>();

    /**
     * Records a security event for monitoring and analysis
     *
     * @param eventType The type of security event
     * @param severity The severity level of the event
     * @param description Human-readable description of the event
     * @param context Additional context information
     */
    public static void recordSecurityEvent(EventType eventType, EventSeverity severity, String description, Map<String, Object> context) {
        SecurityEvent event = new SecurityEvent();
        event.eventType = eventType;
        event.severity = severity;
        event.description = description;
        event.userId = UserInfo.getUserId();

        if (context != null) {
            event.sessionId = (String) context.get('sessionId');
            event.sourceObject = (String) context.get('sourceObject');
            event.sourceField = (String) context.get('sourceField');
            event.detectedPatterns = (String) context.get('detectedPatterns');
            event.originalContent = (String) context.get('originalContent');
            event.sanitizedContent = (String) context.get('sanitizedContent');
            event.metadata.putAll(context);
        }

        // Add to pending events for batch processing
        pendingEvents.add(event);

        // Log immediately for critical events
        if (severity == EventSeverity.CRITICAL) {
            logCriticalEvent(event);
        }

        // Process events if we've reached the batch limit
        if (pendingEvents.size() >= MAX_EVENTS_PER_TRANSACTION) {
            processPendingEvents();
        }
    }

    /**
     * Records a prompt injection attempt with detailed analysis
     *
     * @param analysisResult The security analysis result from PromptInjectionGuard
     * @param fieldName The field containing the suspicious content
     * @param objectType The SObject type containing the field
     * @param sessionId The current chat session ID (if applicable)
     */
    public static void recordPromptInjectionAttempt(
        PromptInjectionGuard.SecurityAnalysisResult analysisResult,
        String fieldName,
        String objectType,
        String sessionId
    ) {
        EventSeverity severity = mapRiskLevelToSeverity(analysisResult.riskLevel);

        Map<String, Object> context = new Map<String, Object>{
            'sessionId' => sessionId,
            'sourceObject' => objectType,
            'sourceField' => fieldName,
            'detectedPatterns' => String.join(analysisResult.detectedPatterns, '; '),
            'riskLevel' => analysisResult.riskLevel,
            'isSafe' => analysisResult.isSafe,
            'patternCount' => analysisResult.detectedPatterns.size()
        };

        String description =
            'Prompt injection attempt detected in ' +
            objectType +
            '.' +
            fieldName +
            ' (Risk: ' +
            analysisResult.riskLevel +
            ', Patterns: ' +
            analysisResult.detectedPatterns.size() +
            ')';

        recordSecurityEvent(EventType.PROMPT_INJECTION_ATTEMPT, severity, description, context);
    }

    /**
     * Records content sanitization events for monitoring
     *
     * @param originalContent The original content before sanitization
     * @param sanitizedContent The content after sanitization
     * @param fieldName The field that was sanitized
     * @param objectType The SObject type
     * @param sessionId The current session ID
     */
    public static void recordContentSanitization(
        String originalContent,
        String sanitizedContent,
        String fieldName,
        String objectType,
        String sessionId
    ) {
        Map<String, Object> context = new Map<String, Object>{
            'sessionId' => sessionId,
            'sourceObject' => objectType,
            'sourceField' => fieldName,
            'originalContent' => originalContent?.abbreviate(500),
            'sanitizedContent' => sanitizedContent?.abbreviate(500),
            'contentLengthBefore' => originalContent?.length() ?? 0,
            'contentLengthAfter' => sanitizedContent?.length() ?? 0
        };

        String description =
            'Content sanitized in ' +
            objectType +
            '.' +
            fieldName +
            ' (Length: ' +
            (originalContent?.length() ?? 0) +
            ' -> ' +
            (sanitizedContent?.length() ?? 0) +
            ')';

        recordSecurityEvent(EventType.CONTENT_SANITIZATION, EventSeverity.MEDIUM, description, context);
    }

    /**
     * Processes all pending security events in batch
     */
    public static void processPendingEvents() {
        if (pendingEvents.isEmpty()) {
            return;
        }

        try {
            // Log events to debug log
            for (SecurityEvent event : pendingEvents) {
                logSecurityEvent(event);
            }

            // TODO: Implement custom object persistence if needed
            // persistEventsToCustomObject(pendingEvents);

            // Check for alerting thresholds
            checkAlertingThresholds(pendingEvents);

            // Clear processed events
            pendingEvents.clear();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[SecurityMonitoringService] Failed to process security events: ' + e.getMessage());
        }
    }

    /**
     * Forces processing of any remaining pending events (call at end of transaction)
     */
    public static void flushPendingEvents() {
        if (!pendingEvents.isEmpty()) {
            processPendingEvents();
        }
    }

    /**
     * Retrieves security metrics for a given time period
     *
     * @param startTime The start of the reporting period
     * @param endTime The end of the reporting period
     * @return SecurityMetrics object with aggregated data
     */
    public static SecurityMetrics getSecurityMetrics(DateTime startTime, DateTime endTime) {
        SecurityMetrics metrics = new SecurityMetrics();
        metrics.periodStart = startTime;
        metrics.periodEnd = endTime;

        try {
            // TODO: Implement custom object queries for metrics
            // This would query SecurityEvent__c records if implemented

            // For now, return empty metrics
            metrics.totalEvents = 0;
            metrics.criticalEvents = 0;
            metrics.highRiskEvents = 0;
            metrics.blockedAttempts = 0;
            metrics.sanitizedContent = 0;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[SecurityMonitoringService] Failed to retrieve security metrics: ' + e.getMessage());
        }

        return metrics;
    }

    /**
     * Checks if current events trigger any alerting thresholds
     */
    private static void checkAlertingThresholds(List<SecurityEvent> events) {
        Integer criticalCount = 0;
        Integer highCount = 0;

        for (SecurityEvent event : events) {
            if (event.severity == EventSeverity.CRITICAL) {
                criticalCount++;
            } else if (event.severity == EventSeverity.HIGH) {
                highCount++;
            }
        }

        // Alert on multiple critical events in single transaction
        if (criticalCount >= 3) {
            sendSecurityAlert(
                'Multiple critical security events detected in single transaction',
                'Critical events: ' + criticalCount,
                EventSeverity.CRITICAL
            );
        }

        // Alert on high volume of security events
        if (events.size() >= 5) {
            sendSecurityAlert(
                'High volume of security events detected',
                'Total events: ' + events.size() + ', Critical: ' + criticalCount + ', High: ' + highCount,
                EventSeverity.HIGH
            );
        }
    }

    /**
     * Sends security alerts through configured channels
     */
    private static void sendSecurityAlert(String alertTitle, String alertMessage, EventSeverity severity) {
        try {
            // TODO: Implement alerting mechanism (email, Chatter, custom notifications)
            System.debug(LoggingLevel.ERROR, '[SECURITY_ALERT] ' + alertTitle + ': ' + alertMessage);

            // Example: Create a Chatter post for high-severity alerts
            // if (severity == EventSeverity.CRITICAL) {
            //     ConnectApi.FeedItemInput feedItemInput = new ConnectApi.FeedItemInput();
            //     ConnectApi.MessageBodyInput messageBodyInput = new ConnectApi.MessageBodyInput();
            //     messageBodyInput.messageSegments = new List<ConnectApi.MessageSegmentInput>();
            //
            //     ConnectApi.TextSegmentInput textSegment = new ConnectApi.TextSegmentInput();
            //     textSegment.text = '🚨 SECURITY ALERT: ' + alertTitle + '\n' + alertMessage;
            //     messageBodyInput.messageSegments.add(textSegment);
            //
            //     feedItemInput.body = messageBodyInput;
            //     feedItemInput.feedElementType = ConnectApi.FeedElementType.FeedItem;
            //     feedItemInput.subjectId = UserInfo.getUserId(); // Post to current user's feed
            //
            //     ConnectApi.ChatterFeeds.postFeedElement(Network.getNetworkId(), feedItemInput);
            // }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[SecurityMonitoringService] Failed to send security alert: ' + e.getMessage());
        }
    }

    /**
     * Logs critical events immediately for urgent response
     */
    private static void logCriticalEvent(SecurityEvent event) {
        System.debug(
            LoggingLevel.ERROR,
            '[CRITICAL_SECURITY_EVENT] ' +
                event.eventType +
                ': ' +
                event.description +
                ' | User: ' +
                event.userId +
                ' | Object: ' +
                event.sourceObject +
                ' | Field: ' +
                event.sourceField
        );
    }

    /**
     * Logs security events to debug log with structured format
     */
    private static void logSecurityEvent(SecurityEvent event) {
        String logLevel = (event.severity == EventSeverity.CRITICAL || event.severity == EventSeverity.HIGH) ? 'ERROR' : 'WARN';

        System.debug(
            LoggingLevel.valueOf(logLevel),
            '[SECURITY_EVENT] ' +
                event.eventType +
                ' | Severity: ' +
                event.severity +
                ' | Description: ' +
                event.description +
                ' | User: ' +
                event.userId +
                ' | Timestamp: ' +
                event.eventTimestamp.format()
        );
    }

    /**
     * Maps risk levels from PromptInjectionGuard to event severity
     */
    private static EventSeverity mapRiskLevelToSeverity(String riskLevel) {
        switch on riskLevel?.toUpperCase() {
            when 'CRITICAL' {
                return EventSeverity.CRITICAL;
            }
            when 'HIGH' {
                return EventSeverity.HIGH;
            }
            when 'MEDIUM' {
                return EventSeverity.MEDIUM;
            }
            when else {
                return EventSeverity.LOW;
            }
        }
    }

    /**
     * Clears pending events (for testing)
     */
    @TestVisible
    private static void clearPendingEvents() {
        pendingEvents.clear();
    }
}
