/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionRunReport is a robust Apex action for securely running Salesforce reports and returning intelligent, token-efficient summaries with comprehensive format support.
 *
 * Responsibilities:
 *   - Validates and extracts the report developer name from input parameters.
 *   - Performs explicit security checks to ensure the user can access the report.
 *   - Executes the report with comprehensive error handling and logging.
 *   - Summarizes report results using the ReportSummarizer for LLM-friendly output.
 *   - Returns structured result data with performance metrics and metadata.
 *
 * Scope:
 *   - Strictly focused on secure, flexible report execution and summarization.
 *   - Designed for maintainability, extensibility, and clarity, with detailed debug output and robust error handling.
 *
 * No specific ActionConfiguration required.
 *
 * @extends BaseAgentAction
 */
public class ActionRunReport extends BaseAgentAction {
    private static final String PARAM_REPORT_NAME = 'reportDeveloperName';

    /**
     * @description
     * Main entry point for report execution. Validates parameters, enforces security, executes the report, summarizes results, and returns structured output.
     *
     * @param params Map<String, Object> - Must include 'reportDeveloperName' (String).
     * @return ReportResult - Contains summary, performance metrics, and metadata.
     * @throws ValidationException for parameter, security, or execution errors.
     *
     * Side effects: Logs key steps, errors, and performance metrics for troubleshooting and monitoring.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        // Extract and validate required parameter
        String reportDeveloperName = getRequiredStringParam(params, PARAM_REPORT_NAME);
        if (String.isBlank(reportDeveloperName)) {
            throw new ValidationException('Report developer name cannot be blank', PARAM_REPORT_NAME);
        }

        // Security: Find report with user-mode security
        Id reportId = findReportWithSecurity(reportDeveloperName);

        // Execute report and handle errors
        Reports.ReportResults results = executeReportSafely(reportId, reportDeveloperName);

        // Summarize results for LLM-friendly output
        Map<String, Object> summaryPayload = ReportSummarizer.summarize(results);

        // Validate summarization
        validateSummarizationResult(summaryPayload);

        // Return result with performance metrics and metadata
        return createReportResult(summaryPayload, startTime, reportDeveloperName);
    }

    /**
     * @description
     * Creates a structured ReportResult with performance metrics and LLM-friendly metadata.
     *
     * @param summaryPayload Map<String, Object> - The summarized report data.
     * @param startTime Long - The start time of execution for performance metrics.
     * @param reportDeveloperName String - The requested report developer name.
     * @return ReportResult - Structured result for downstream use.
     */
    private ReportResult createReportResult(Map<String, Object> summaryPayload, Long startTime, String reportDeveloperName) {
        Long executionTime = System.currentTimeMillis() - startTime;
        String successMessage = (String) summaryPayload.get('summary');

        System.debug(LoggingLevel.INFO, '[ActionRunReport] Report execution succeeded in ' + executionTime + ' ms. Summary: ' + successMessage);

        return new ReportResult(summaryPayload, executionTime, reportDeveloperName, successMessage);
    }

    /**
     * @description
     * Securely finds a report by developer name with explicit user-mode security.
     *
     * @param reportDeveloperName String - The developer name of the report.
     * @return Id - The Id of the found report.
     * @throws ValidationException if the report is not found or user lacks access.
     */
    private Id findReportWithSecurity(String reportDeveloperName) {
        try {
            List<Report> reports = [
                SELECT Id, Name
                FROM Report
                WHERE DeveloperName = :reportDeveloperName
                WITH USER_MODE
                LIMIT 1
            ];

            if (reports.isEmpty()) {
                throw new ValidationException(
                    'No report found with Developer Name "' + reportDeveloperName + '" or user lacks access.',
                    PARAM_REPORT_NAME
                );
            }

            System.debug(LoggingLevel.INFO, '[ActionRunReport] Found report: ' + reports[0].Name + ' (ID: ' + reports[0].Id + ')');
            return reports[0].Id;
        } catch (QueryException qe) {
            System.debug(LoggingLevel.ERROR, '[ActionRunReport] Query error while finding report: ' + qe.getMessage());
            throw new ValidationException('Error accessing report: ' + qe.getMessage(), PARAM_REPORT_NAME);
        }
    }

    /**
     * @description
     * Executes the report with comprehensive error handling and logging.
     *
     * @param reportId Id - The Id of the report to execute.
     * @param reportDeveloperName String - The developer name of the report (for error context).
     * @return Reports.ReportResults - The results of the report execution.
     * @throws ValidationException if execution fails or returns null.
     */
    private Reports.ReportResults executeReportSafely(Id reportId, String reportDeveloperName) {
        try {
            System.debug(LoggingLevel.INFO, '[ActionRunReport] Executing report with ID: ' + reportId);
            Reports.ReportResults results = Reports.ReportManager.runReport(reportId, true);

            if (results == null) {
                throw new ValidationException('Report execution returned null results', PARAM_REPORT_NAME);
            }

            return results;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionRunReport] Report execution error: ' + e.getMessage());
            throw new ValidationException('Failed to execute report "' + reportDeveloperName + '": ' + e.getMessage(), PARAM_REPORT_NAME);
        }
    }

    /**
     * @description
     * Validates the summarization result and handles unsupported formats.
     *
     * @param summaryPayload Map<String, Object> - The summarized report data.
     * @throws ValidationException if summarization failed or format is unsupported.
     */
    private void validateSummarizationResult(Map<String, Object> summaryPayload) {
        Boolean wasSuccess = (Boolean) summaryPayload.get('isSuccess');
        if (!wasSuccess) {
            String errorMessage = (String) summaryPayload.get('message');
            System.debug(LoggingLevel.WARN, '[ActionRunReport] Report summarization failed: ' + errorMessage);
            throw new ValidationException(errorMessage, PARAM_REPORT_NAME);
        }
    }

    /**
     * @description
     * Helper method to extract required string parameters with validation.
     *
     * @param params Map<String, Object> - The input parameters.
     * @param paramName String - The name of the required parameter.
     * @return String - The extracted string value.
     * @throws ValidationException if the parameter is missing or not a string.
     */
    private String getRequiredStringParam(Map<String, Object> params, String paramName) {
        Object value = params.get(paramName);
        if (value == null) {
            throw new ValidationException('Required parameter "' + paramName + '" is missing', paramName);
        }
        if (!(value instanceof String)) {
            throw new ValidationException('Parameter "' + paramName + '" must be a string', paramName);
        }
        return (String) value;
    }

    /**
     * @description
     * Result wrapper for successful report execution operations. Provides structured data for both user display and LLM processing.
     *
     * Fields:
     *   - message: String - User-facing message summarizing the result.
     *   - reportName: String - The name of the report executed.
     *   - reportFormat: String - The format of the report.
     *   - recordCount: Integer - The number of records in the report.
     *   - executionTimeMs: Long - The execution time in milliseconds.
     *   - reportData: Map<String, Object> - The full report summary data.
     *   - metadata: Map<String, Object> - Additional context for downstream consumers.
     */
    public class ReportResult {
        public String message;
        public String reportName;
        public String reportFormat;
        public Integer recordCount;
        public Long executionTimeMs;
        public Map<String, Object> reportData;
        public Map<String, Object> metadata;

        public ReportResult(Map<String, Object> summaryPayload, Long executionTime, String requestedReportName, String message) {
            this.message = message;
            this.reportName = (String) summaryPayload.get('reportName');
            this.reportFormat = (String) summaryPayload.get('reportFormat');
            this.recordCount = (Integer) summaryPayload.get('recordCount');
            this.executionTimeMs = executionTime;
            this.reportData = summaryPayload;
            this.metadata = new Map<String, Object>{
                'actionType' => 'REPORT_EXECUTION',
                'dataQuality' => 'HIGH',
                'requestedReportName' => requestedReportName,
                'timestamp' => System.now().format('yyyy-MM-dd HH:mm:ss'),
                'executionTimeMs' => executionTime,
                'reportFormat' => this.reportFormat,
                'recordCount' => this.recordCount,
                'executionSuccessful' => true
            };
        }
    }
}
