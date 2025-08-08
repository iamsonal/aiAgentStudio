/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description ENHANCED Standard Action: Runs Salesforce reports and returns intelligent,
 *              token-efficient summaries with comprehensive format support.
 *              Framework automatically handles parameter extraction, validation, and result wrapping.
 *              ActionConfiguration: No specific configuration required.
 *
 *              MAINTAINS: Explicit security checks, comprehensive error handling, and intelligent summarization.
 *              ENHANCED: Simplified interface while preserving all robustness and performance features.
 * @extends BaseAgentAction
 */
public class ActionRunReport extends BaseAgentAction {
    private static final String PARAM_REPORT_NAME = 'reportDeveloperName';

    /**
     * @description THE ONLY METHOD we need to implement!
     *              Framework automatically handles parameter extraction, validation, and security.
     *              ENHANCED: Maintains comprehensive validation and performance while leveraging framework simplicity.
     */
    public override Object executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        String reportDeveloperName = getRequiredStringParam(params, PARAM_REPORT_NAME);

        if (String.isBlank(reportDeveloperName)) {
            throw new ValidationException('Report developer name cannot be blank', PARAM_REPORT_NAME);
        }

        Id reportId = findReportWithSecurity(reportDeveloperName);

        Reports.ReportResults results = executeReportSafely(reportId, reportDeveloperName);

        Map<String, Object> summaryPayload = ReportSummarizer.summarize(results);

        validateSummarizationResult(summaryPayload);

        return createReportResult(summaryPayload, startTime, reportDeveloperName);
    }

    /**
     * @description Creates structured ReportResult with performance metrics and LLM-friendly metadata
     */
    private ReportResult createReportResult(Map<String, Object> summaryPayload, Long startTime, String reportDeveloperName) {
        Long executionTime = System.currentTimeMillis() - startTime;
        String successMessage = (String) summaryPayload.get('summary');

        return new ReportResult(summaryPayload, executionTime, reportDeveloperName, successMessage);
    }

    /**
     * @description Securely finds report by developer name with explicit user-mode security
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

            return reports[0].Id;
        } catch (QueryException qe) {
            throw new ValidationException('Error accessing report: ' + qe.getMessage(), PARAM_REPORT_NAME);
        }
    }

    /**
     * @description Executes report with comprehensive error handling and logging
     */
    private Reports.ReportResults executeReportSafely(Id reportId, String reportDeveloperName) {
        try {
            Reports.ReportResults results = Reports.ReportManager.runReport(reportId, true);

            if (results == null) {
                throw new ValidationException('Report execution returned null results', PARAM_REPORT_NAME);
            }

            return results;
        } catch (Exception e) {
            throw new ValidationException('Failed to execute report "' + reportDeveloperName + '": ' + e.getMessage(), PARAM_REPORT_NAME);
        }
    }

    /**
     * @description Validates summarization result and handles unsupported formats
     */
    private void validateSummarizationResult(Map<String, Object> summaryPayload) {
        Boolean wasSuccess = (Boolean) summaryPayload.get('isSuccess');
        if (!wasSuccess) {
            String errorMessage = (String) summaryPayload.get('message');

            throw new ValidationException(errorMessage, PARAM_REPORT_NAME);
        }
    }

    /**
     * @description Helper method to extract required string parameters with validation
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
