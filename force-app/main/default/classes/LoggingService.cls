/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Service class for centralized logging in Apex
 * @author Claude
 * @date 2025-04-19
 */
public without sharing class LoggingService {
    /**
     * Enum for log levels
     */
    public enum LogLevel {
        DEBUG,
        INFO,
        WARN,
        ERROR,
        FATAL
    }

    /**
     * @description Logs a debug message
     * @param context The context of the log
     * @param message The message to log
     */
    public static void logDebug(String context, String message) {
        log(LogLevel.DEBUG, context, message, null);
    }

    /**
     * @description Logs an info message
     * @param context The context of the log
     * @param message The message to log
     */
    public static void logInfo(String context, String message) {
        log(LogLevel.INFO, context, message, null);
    }

    /**
     * @description Logs a warning message
     * @param context The context of the log
     * @param message The message to log
     */
    public static void logWarning(String context, String message) {
        log(LogLevel.WARN, context, message, null);
    }

    /**
     * @description Logs an error message
     * @param context The context of the log
     * @param error The exception to log
     */
    public static void logError(String context, Exception error) {
        log(LogLevel.ERROR, context, error.getMessage(), error);
    }

    /**
     * @description Logs an error message with a custom message
     * @param context The context of the log
     * @param message The message to log
     * @param error The exception to log
     */
    public static void logError(String context, String message, Exception error) {
        log(LogLevel.ERROR, context, message, error);
    }

    /**
     * @description Logs a fatal error message
     * @param context The context of the log
     * @param error The exception to log
     */
    public static void logFatal(String context, Exception error) {
        log(LogLevel.FATAL, context, error.getMessage(), error);
    }

    /**
     * @description Central logging method
     * @param level The log level
     * @param context The context of the log
     * @param message The message to log
     * @param error The exception to log (optional)
     */
    private static void log(LogLevel level, String context, String message, Exception error) {
        String logMessage = formatLogMessage(level, context, message, error);

        if (shouldPersistLog(level)) {
            persistLog(level, context, message, error);
        }
    }

    /**
     * @description Format a log message
     * @param level The log level
     * @param context The context of the log
     * @param message The message to log
     * @param error The exception to log (optional)
     * @return String The formatted log message
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
     * @description Convert LogLevel to System.LoggingLevel
     * @param level Our LogLevel enum
     * @return System.LoggingLevel The corresponding System.LoggingLevel
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
                return System.LoggingLevel.ERROR;
            }
            when else {
                return System.LoggingLevel.DEBUG;
            }
        }
    }

    /**
     * @description Determine if a log should be persisted to a custom object
     * @param level The log level
     * @return Boolean Whether to persist the log
     */
    private static Boolean shouldPersistLog(LogLevel level) {
        return level == LogLevel.WARN || level == LogLevel.ERROR || level == LogLevel.FATAL;
    }

    /**
     * @description Persist a log to a custom object
     * @param level The log level
     * @param context The context of the log
     * @param message The message to log
     * @param error The exception to log (optional)
     */
    private static void persistLog(LogLevel level, String context, String message, Exception error) {
        /*
        Error_Log__c log = new Error_Log__c(
            Log_Level__c = level.name(),
            Context__c = context,
            Message__c = message,
            User__c = UserInfo.getUserId(),
            Timestamp__c = Datetime.now()
        );

        if (error != null) {
            log.Exception_Type__c = error.getTypeName();
            log.Line_Number__c = error.getLineNumber();
            log.Stack_Trace__c = error.getStackTraceString();
        }

        
        Database.insert(log, false);
        */

        if (level == LogLevel.ERROR || level == LogLevel.FATAL) {
        }
    }
}
