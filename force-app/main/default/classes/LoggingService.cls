/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * LoggingService is a centralized, structured logging utility for the agent framework.
 *
 * Responsibilities:
 *   - Provides consistent logging at multiple severity levels (DEBUG, INFO, WARN, ERROR, FATAL)
 *   - Supports both System.debug output and optional persistence to custom objects for critical errors
 *   - Automatically enriches logs with user information, timestamps, and context
 *   - Formats log messages for clarity and auditability
 *
 * This service is intended to be used throughout the framework for all logging needs, ensuring
 * that logs are actionable, traceable, and easy to analyze in both development and production.
 */
public without sharing class LoggingService {
    /**
     * Enumeration of available logging levels in order of severity.
     */
    public enum LogLevel {
        DEBUG,
        INFO,
        WARN,
        ERROR,
        FATAL
    }

    /**
     * Logs a debug message.
     *
     * @param context  The context or source of the log message.
     * @param message  The message to log.
     */
    public static void logDebug(String context, String message) {
        log(LogLevel.DEBUG, context, message, null);
    }

    /**
     * Logs an info message.
     *
     * @param context  The context or source of the log message.
     * @param message  The message to log.
     */
    public static void logInfo(String context, String message) {
        log(LogLevel.INFO, context, message, null);
    }

    /**
     * Logs a warning message.
     *
     * @param context  The context or source of the log message.
     * @param message  The message to log.
     */
    public static void logWarning(String context, String message) {
        log(LogLevel.WARN, context, message, null);
    }

    /**
     * Logs an error message with exception details.
     *
     * @param context  The context or source of the log message.
     * @param error    The exception to log.
     */
    public static void logError(String context, Exception error) {
        log(LogLevel.ERROR, context, error.getMessage(), error);
    }

    /**
     * Logs an error message with a custom message and exception details.
     *
     * @param context  The context or source of the log message.
     * @param message  The message to log.
     * @param error    The exception to log.
     */
    public static void logError(String context, String message, Exception error) {
        log(LogLevel.ERROR, context, message, error);
    }

    /**
     * Logs a fatal error message with exception details.
     *
     * @param context  The context or source of the log message.
     * @param error    The exception to log.
     */
    public static void logFatal(String context, Exception error) {
        log(LogLevel.FATAL, context, error.getMessage(), error);
    }

    /**
     * Central logging method for all log levels.
     *
     * @param level    The log level.
     * @param context  The context or source of the log message.
     * @param message  The message to log.
     * @param error    The exception to log (optional).
     */
    private static void log(LogLevel level, String context, String message, Exception error) {
        // Build and output the log message
        String logMessage = formatLogMessage(level, context, message, error);
        System.debug(getSystemDebugLevel(level), logMessage);
        // Persist log if severity warrants audit trail
        if (shouldPersistLog(level)) {
            persistLog(level, context, message, error);
        }
    }

    /**
     * Formats a log message with timestamp, user info, context, and error details.
     *
     * @param level    The log level.
     * @param context  The context or source of the log message.
     * @param message  The message to log.
     * @param error    The exception to log (optional).
     * @return String  The formatted log message.
     */
    private static String formatLogMessage(LogLevel level, String context, String message, Exception error) {
        String timestamp = Datetime.now().format('yyyy-MM-dd HH:mm:ss.SSS');
        String userId = UserInfo.getUserId();
        String username = UserInfo.getUsername();
        String formattedMessage = '[' + level + '] ' + timestamp + ' ' + username + ' (' + userId + ') ' + context + ': ' + message;

        if (error != null) {
            formattedMessage +=
                '\nException Type: ' +
                error.getTypeName() +
                '\nLine Number: ' +
                error.getLineNumber() +
                '\nStack Trace: ' +
                error.getStackTraceString();
        }

        return formattedMessage;
    }

    /**
     * Converts LogLevel to System.LoggingLevel for System.debug output.
     *
     * @param level  Our LogLevel enum.
     * @return System.LoggingLevel  The corresponding System.LoggingLevel.
     */
    private static System.LoggingLevel getSystemDebugLevel(LogLevel level) {
        switch on level {
            when DEBUG {
                return System.LoggingLevel.DEBUG;
            }
            when INFO {
                return System.LoggingLevel.INFO;
            }
            when WARN {
                return System.LoggingLevel.WARN;
            }
            when ERROR {
                return System.LoggingLevel.ERROR;
            }
            when FATAL {
                return System.LoggingLevel.ERROR; // System.LoggingLevel doesn't have FATAL
            }
            when else {
                return System.LoggingLevel.DEBUG;
            }
        }
    }

    /**
     * Determines if a log entry should be persisted based on severity level.
     *
     * Currently persists warnings, errors, and fatal errors only.
     *
     * @param level  The log level to evaluate.
     * @return Boolean  True if the log should be persisted to custom objects.
     */
    private static Boolean shouldPersistLog(LogLevel level) {
        return level == LogLevel.WARN || level == LogLevel.ERROR || level == LogLevel.FATAL;
    }

    /**
     * Persists log entries to custom objects for critical issues requiring audit trails.
     *
     * Currently outputs to debug logs as a placeholder for custom object implementation.
     *
     * @param level    The log level.
     * @param context  The logging context.
     * @param message  The log message.
     * @param error    Optional exception details.
     */
    private static void persistLog(LogLevel level, String context, String message, Exception error) {
        if (level == LogLevel.ERROR || level == LogLevel.FATAL) {
            System.debug(System.LoggingLevel.ERROR, 'PERSISTENT LOG: ' + formatLogMessage(level, context, message, error));
        }
    }
}
