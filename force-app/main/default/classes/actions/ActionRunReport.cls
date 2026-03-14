/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ActionRunReport executes Salesforce reports and returns their results in a structured format.
 * Provides a secure and governed way for AI agents to access complex data using existing reports
 * without writing dynamic SOQL.
 *
 * Responsibilities:
 *   - Execute Salesforce reports with security enforcement
 *   - Support both tabular and summary reports
 *   - Return structured results with summary data
 *   - Validate report access and permissions
 *   - Handle report parameters/filters
 *
 * @ActionLabel Run Report
 * @ActionDescription Executes Salesforce reports and returns structured results
 *
 * @extends BaseAgentAction
 */
public with sharing class ActionRunReport extends BaseAgentAction {
    private static final Integer DEFAULT_MAX_ROWS = 200;
    private static final Integer ABSOLUTE_MAX_ROWS = 2000;

    // Supported report formats for this action
    private static final Set<String> SUPPORTED_REPORT_FORMATS = new Set<String>{ 'TABULAR', 'SUMMARY' };

    private ConfigDTO config;

    // Dependency injection for testability
    @TestVisible
    private IReportExecutor reportExecutor;

    /**
     * Interface for report execution - allows mocking in tests
     */
    @TestVisible
    private interface IReportExecutor {
        Reports.ReportResults runReport(Id reportId, Boolean includeDetails);
        Reports.ReportResults runReportWithFilters(Id reportId, List<ReportFilterDTO> filters, ActionRunReport action);
    }

    /**
     * Default implementation that calls the actual Reports API
     */
    @TestVisible
    private class DefaultReportExecutor implements IReportExecutor {
        public Reports.ReportResults runReport(Id reportId, Boolean includeDetails) {
            return Reports.ReportManager.runReport(reportId, includeDetails);
        }

        public Reports.ReportResults runReportWithFilters(Id reportId, List<ReportFilterDTO> filters, ActionRunReport action) {
            Reports.ReportMetadata reportMetadata = Reports.ReportManager.describeReport(reportId).getReportMetadata();
            List<Reports.ReportFilter> existingFilters = reportMetadata.getReportFilters();

            for (ReportFilterDTO filterDto : filters) {
                Reports.ReportFilter newFilter = new Reports.ReportFilter();
                newFilter.setColumn(filterDto.column);
                newFilter.setOperator(action.normalizeFilterOperator(filterDto.operator));
                newFilter.setValue(filterDto.value);
                existingFilters.add(newFilter);
            }

            reportMetadata.setReportFilters(existingFilters);
            return Reports.ReportManager.runReport(reportId, reportMetadata, true);
        }
    }

    public ActionRunReport() {
        this.reportExecutor = new DefaultReportExecutor();
    }

    /**
     * DTO for strongly-typed backend configuration.
     * Allows admins to pre-configure filters that are always applied to the report.
     */
    public class ConfigDTO {
        /**
         * @FieldLabel Default Filters
         * @FieldType array
         * @FieldHelp Pre-configured filters that are always applied to the report.
         * These are merged with any runtime filters provided by the LLM.
         * Useful for restricting data scope (e.g., business unit, region, record type).
         */
        public List<ReportFilterDTO> defaultFilters;
    }

    /**
     * DTO for report filter parameters
     */
    public class ReportFilterDTO {
        /**
         * @FieldLabel Column API Name
         * @FieldType string
         * @FieldHelp The API name of the column to filter (e.g., 'ACCOUNT_NAME', 'CREATED_DATE')
         */
        public String column;

        /**
         * @FieldLabel Filter Operator
         * @FieldType picklist
         * @FieldPicklistValues equals,notEqual,lessThan,greaterThan,lessOrEqual,greaterOrEqual,contains,notContain,startsWith
         * @FieldHelp The comparison operator for the filter
         */
        public String operator;

        /**
         * @FieldLabel Filter Value
         * @FieldType string
         * @FieldHelp The value to filter by. For dates use YYYY-MM-DD format.
         */
        public String value;
    }

    /**
     * DTO for strongly-typed arguments
     */
    public class ArgumentsDTO {
        /**
         * @FieldLabel Report ID
         * @FieldType salesforce-id
         * @FieldPlaceholder 00O000000000000AAA
         * @FieldHelp The 18-character Salesforce ID of the report to run
         */
        public String reportId;

        /**
         * @FieldLabel Report Developer Name
         * @FieldType string
         * @FieldHelp The API/Developer Name of the report (alternative to reportId)
         */
        public String reportDeveloperName;

        /**
         * @FieldLabel Max Rows
         * @FieldType integer
         * @FieldMinValue 1
         * @FieldMaxValue 2000
         * @FieldHelp Maximum number of rows to return (default: 200)
         */
        public Integer maxRows;

        /**
         * @FieldLabel Include Details
         * @FieldType boolean
         * @FieldHelp Include detailed row data in response
         */
        public Boolean includeDetails;

        /**
         * @FieldLabel Report Filters
         * @FieldType array
         * @FieldHelp Runtime filters to apply to the report. Each filter specifies column, operator, and value.
         */
        public List<ReportFilterDTO> filters;
    }

    /**
     * @description
     * Main entry point for report execution using Two-Pass Hybrid Deserialization.
     *
     * @param params Map<String, Object> - Raw parameters (deserialized into ArgumentsDTO for type safety)
     * @return ActionOutcome<ReportResult> - Contains report results with summary data
     */
    public override ActionOutcome executeAction(Map<String, Object> params) {
        Long startTime = System.currentTimeMillis();

        try {
            // Parse backend configuration for default filters
            config = parseConfig();

            // Two-Pass Hybrid Deserialization: Manually populate DTO from untyped map
            ArgumentsDTO args = new ArgumentsDTO();
            args.reportId = ActionConfigUtils.getOptionalString(params, 'reportId');
            args.reportDeveloperName = ActionConfigUtils.getOptionalString(params, 'reportDeveloperName');
            args.maxRows = ActionConfigUtils.getOptionalInteger(params, 'maxRows', DEFAULT_MAX_ROWS);
            args.includeDetails = ActionConfigUtils.getOptionalBoolean(params, 'includeDetails', true);
            args.filters = parseFilters(params.get('filters'));

            // Validate required DTO parameters
            if (String.isBlank(args.reportId) && String.isBlank(args.reportDeveloperName)) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Either reportId or reportDeveloperName is required');
            }

            // Limit max rows
            Integer finalMaxRows = Math.min(args.maxRows, ABSOLUTE_MAX_ROWS);

            // Resolve report ID if developer name provided using DTO parameters
            Id resolvedReportId;
            if (String.isNotBlank(args.reportId)) {
                try {
                    resolvedReportId = Id.valueOf(args.reportId);
                } catch (Exception e) {
                    return ActionOutcome.failure(AIAgentConstants.ERR_CODE_INPUT_VALIDATION, 'Invalid report ID format: ' + args.reportId);
                }
            } else {
                resolvedReportId = resolveReportByDeveloperName(args.reportDeveloperName);
                if (resolvedReportId == null) {
                    return ActionOutcome.failure(
                        AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND,
                        'Report not found with DeveloperName: ' + args.reportDeveloperName
                    );
                }
            }

            // Validate report exists, user has access, and format is supported
            ReportValidationResult validationResult = validateReportAccess(resolvedReportId);
            if (!validationResult.isValid) {
                return validationResult.outcome;
            }

            System.debug(LoggingLevel.INFO, '[ActionRunReport] Executing report: ' + resolvedReportId + ' (Format: ' + validationResult.reportFormat + ')');

            // Merge filters: backend config defaults + runtime filters from LLM
            List<ReportFilterDTO> allFilters = mergeFilters(config.defaultFilters, args.filters);

            // Execute report using injected executor (allows mocking in tests)
            Reports.ReportResults results;
            if (allFilters != null && !allFilters.isEmpty()) {
                results = reportExecutor.runReportWithFilters(resolvedReportId, allFilters, this);
            } else {
                results = reportExecutor.runReport(resolvedReportId, true);
            }

            Long executionTime = System.currentTimeMillis() - startTime;
            System.debug(LoggingLevel.INFO, '[ActionRunReport] Report execution completed in ' + executionTime + ' ms');

            // Parse and format results using DTO parameters
            ReportResult reportResult = parseReportResults(results, finalMaxRows, args.includeDetails);

            return ActionOutcome.success(reportResult);
        } catch (Reports.ReportRunException rre) {
            String message = rre.getMessage();
            if (message.containsIgnoreCase('filter')) {
                return ActionOutcome.failure(
                    AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                    'Invalid report filter: ' + message,
                    'Verify the filter column name exists in the report and the operator/value are valid for the column type.'
                );
            }
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_ACTION_EXECUTION, 'Report execution failed: ' + message);
        } catch (System.QueryException qe) {
            String message = qe.getMessage().toLowerCase();
            if (message.contains('insufficient access') || message.contains('security')) {
                return ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, 'Insufficient permissions to access this report');
            }
            return ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to access report: ' + qe.getMessage());
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionRunReport] Unexpected error: ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, '[ActionRunReport] Stack trace: ' + e.getStackTraceString());
            return ActionOutcome.fromException(e);
        }
    }

    /**
     * @description
     * Parses the filters parameter from the raw input into a list of ReportFilterDTO objects.
     *
     * @param filtersParam The raw filters parameter (could be List<Object> or null)
     * @return List<ReportFilterDTO> parsed filters, or null if no filters provided
     */
    @TestVisible
    private List<ReportFilterDTO> parseFilters(Object filtersParam) {
        if (filtersParam == null) {
            return null;
        }

        List<ReportFilterDTO> parsedFilters = new List<ReportFilterDTO>();

        if (filtersParam instanceof List<Object>) {
            List<Object> filtersList = (List<Object>) filtersParam;
            for (Object filterObj : filtersList) {
                if (filterObj instanceof Map<String, Object>) {
                    Map<String, Object> filterMap = (Map<String, Object>) filterObj;
                    ReportFilterDTO dto = new ReportFilterDTO();
                    dto.column = ActionConfigUtils.getOptionalString(filterMap, 'column');
                    dto.operator = ActionConfigUtils.getOptionalString(filterMap, 'operator');
                    dto.value = ActionConfigUtils.getOptionalString(filterMap, 'value');

                    // Only add if we have the required fields
                    if (String.isNotBlank(dto.column) && String.isNotBlank(dto.operator) && dto.value != null) {
                        parsedFilters.add(dto);
                    }
                }
            }
        }

        return parsedFilters.isEmpty() ? null : parsedFilters;
    }

    /**
     * @description
     * Parses the backend configuration JSON into a ConfigDTO object.
     *
     * @return ConfigDTO with default filters, or empty ConfigDTO if no config
     */
    private ConfigDTO parseConfig() {
        ConfigDTO cfg = new ConfigDTO();

        if (this.parsedActionConfig == null || this.parsedActionConfig.isEmpty()) {
            return cfg;
        }

        try {
            cfg.defaultFilters = parseFilters(this.parsedActionConfig.get('defaultFilters'));
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[ActionRunReport] Failed to parse backend config: ' + e.getMessage());
        }

        return cfg;
    }

    /**
     * @description
     * Merges backend config filters with runtime filters.
     * Backend config filters are applied first, then runtime filters are appended.
     *
     * @param configFilters Filters from backend configuration (admin-defined)
     * @param runtimeFilters Filters from LLM arguments (dynamic)
     * @return Combined list of filters, or null if both are empty
     */
    @TestVisible
    private List<ReportFilterDTO> mergeFilters(List<ReportFilterDTO> configFilters, List<ReportFilterDTO> runtimeFilters) {
        List<ReportFilterDTO> merged = new List<ReportFilterDTO>();

        if (configFilters != null && !configFilters.isEmpty()) {
            merged.addAll(configFilters);
        }

        if (runtimeFilters != null && !runtimeFilters.isEmpty()) {
            merged.addAll(runtimeFilters);
        }

        return merged.isEmpty() ? null : merged;
    }

    /**
     * @description
     * Normalizes operator string to the format expected by Reports.ReportFilter.setOperator().
     * The API expects specific string values like 'equals', 'notEqual', 'lessThan', etc.
     *
     * @param operatorStr The string representation of the operator from user input
     * @return Normalized operator string for the Reports API
     */
    @TestVisible
    private String normalizeFilterOperator(String operatorStr) {
        if (String.isBlank(operatorStr)) {
            return 'equals';
        }

        String op = operatorStr.toLowerCase().trim();

        if (op == 'equals' || op == 'eq' || op == '=') {
            return 'equals';
        } else if (op == 'notequal' || op == 'ne' || op == '!=' || op == '<>') {
            return 'notEqual';
        } else if (op == 'lessthan' || op == 'lt' || op == '<') {
            return 'lessThan';
        } else if (op == 'greaterthan' || op == 'gt' || op == '>') {
            return 'greaterThan';
        } else if (op == 'lessorequal' || op == 'lte' || op == '<=') {
            return 'lessOrEqual';
        } else if (op == 'greaterorequal' || op == 'gte' || op == '>=') {
            return 'greaterOrEqual';
        } else if (op == 'contains' || op == 'like') {
            return 'contains';
        } else if (op == 'notcontain' || op == 'notcontains') {
            return 'notContain';
        } else if (op == 'startswith') {
            return 'startsWith';
        } else {
            // Return as-is if already in correct format, or default to equals
            return operatorStr;
        }
    }

    /**
     * @description
     * Resolves a report ID from its DeveloperName.
     *
     * @param developerName The report's DeveloperName
     * @return The report's Id, or null if not found
     */
    private Id resolveReportByDeveloperName(String developerName) {
        try {
            List<Report> reports = [
                SELECT Id, DeveloperName, Name
                FROM Report
                WHERE DeveloperName = :developerName
                WITH USER_MODE
                LIMIT 1
            ];

            if (reports.isEmpty()) {
                return null;
            }

            return reports[0].Id;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[ActionRunReport] Error resolving report by DeveloperName: ' + e.getMessage());
            return null;
        }
    }

    /**
     * @description
     * Wrapper class for report validation results.
     */
    private class ReportValidationResult {
        public Boolean isValid;
        public ActionOutcome outcome;
        public String reportFormat;

        public ReportValidationResult(Boolean isValid, ActionOutcome outcome, String reportFormat) {
            this.isValid = isValid;
            this.outcome = outcome;
            this.reportFormat = reportFormat;
        }
    }

    /**
     * @description
     * Validates that the report exists, the user has access to it, and the format is supported.
     *
     * @param reportId The report Id to validate
     * @return ReportValidationResult indicating success/failure and report format
     */
    private ReportValidationResult validateReportAccess(Id reportId) {
        try {
            // Query the report to validate access
            List<Report> reports = [
                SELECT Id, Name, DeveloperName, Format
                FROM Report
                WHERE Id = :reportId
                WITH USER_MODE
                LIMIT 1
            ];

            if (reports.isEmpty()) {
                return new ReportValidationResult(
                    false,
                    ActionOutcome.failure(AIAgentConstants.ERR_CODE_RECORD_NOT_FOUND, 'Report not found: ' + reportId),
                    null
                );
            }

            Report report = reports[0];
            String reportFormat = report.Format;

            // Validate report format is supported
            if (!SUPPORTED_REPORT_FORMATS.contains(reportFormat.toUpperCase())) {
                String supportedFormatsStr = String.join(new List<String>(SUPPORTED_REPORT_FORMATS), ', ');
                return new ReportValidationResult(
                    false,
                    ActionOutcome.failure(
                        AIAgentConstants.ERR_CODE_INPUT_VALIDATION,
                        'Unsupported report format: ' + reportFormat + '. This action supports: ' + supportedFormatsStr,
                        'Matrix reports are not currently supported. Please use a Tabular or Summary report instead, or create a new report with a supported format.'
                    ),
                    reportFormat
                );
            }

            System.debug(
                LoggingLevel.DEBUG,
                '[ActionRunReport] Validated report access: ' + report.Name + ' (' + report.DeveloperName + '), Format: ' + reportFormat
            );

            return new ReportValidationResult(true, null, reportFormat);
        } catch (System.QueryException qe) {
            String message = qe.getMessage().toLowerCase();
            if (message.contains('insufficient access') || message.contains('security')) {
                return new ReportValidationResult(
                    false,
                    ActionOutcome.failure(AIAgentConstants.ERR_CODE_PERMISSION_DENIED, 'You do not have permission to access this report'),
                    null
                );
            }
            return new ReportValidationResult(
                false,
                ActionOutcome.failure(AIAgentConstants.ERR_CODE_SOQL_ERROR, 'Failed to validate report access: ' + qe.getMessage()),
                null
            );
        }
    }

    /**
     * @description
     * Parses report results into a structured format for LLM consumption.
     *
     * @param results The raw report results from ReportManager
     * @param maxRows Maximum number of detail rows to include
     * @param includeDetails Whether to include detail rows
     * @return Structured ReportResult object
     */
    private ReportResult parseReportResults(Reports.ReportResults results, Integer maxRows, Boolean includeDetails) {
        ReportResult result = new ReportResult();

        // Extract report metadata
        Reports.ReportMetadata metadata = results.getReportMetadata();
        result.reportName = metadata.getName();
        result.reportFormat = String.valueOf(metadata.getReportFormat());

        // Get aggregates/summary data
        Reports.ReportFactWithDetails factWithDetails = (Reports.ReportFactWithDetails) results.getFactMap().get('T!T');
        if (factWithDetails != null) {
            result.totalRows = factWithDetails.getRows().size();

            // Extract aggregate values
            List<Reports.SummaryValue> aggregates = factWithDetails.getAggregates();
            if (aggregates != null && !aggregates.isEmpty()) {
                result.aggregates = new List<Map<String, Object>>();
                for (Reports.SummaryValue summaryValue : aggregates) {
                    Map<String, Object> aggData = new Map<String, Object>();
                    aggData.put('label', summaryValue.getLabel());
                    aggData.put('value', summaryValue.getValue());
                    result.aggregates.add(aggData);
                }
            }
        } else {
            result.totalRows = 0;
        }

        // Extract detail rows if requested
        if (includeDetails && factWithDetails != null) {
            result.detailRows = new List<Map<String, Object>>();
            List<Reports.ReportDetailRow> detailRows = factWithDetails.getRows();

            Integer rowsToProcess = Math.min(detailRows.size(), maxRows);
            for (Integer i = 0; i < rowsToProcess; i++) {
                Reports.ReportDetailRow detailRow = detailRows[i];
                Map<String, Object> rowData = new Map<String, Object>();

                List<Reports.ReportDataCell> dataCells = detailRow.getDataCells();
                List<String> columnNames = metadata.getDetailColumns();

                for (Integer j = 0; j < dataCells.size() && j < columnNames.size(); j++) {
                    Reports.ReportDataCell cell = dataCells[j];
                    String columnName = columnNames[j];
                    rowData.put(columnName, cell.getLabel());
                }

                result.detailRows.add(rowData);
            }

            if (detailRows.size() > maxRows) {
                result.truncated = true;
                result.message = 'Report returned ' + detailRows.size() + ' rows, showing first ' + maxRows;
            }
        }

        if (result.message == null) {
            result.message = 'Report executed successfully. Returned ' + result.totalRows + ' row(s).';
        }

        return result;
    }

    /**
     * @description
     * Result wrapper for report execution results.
     */
    public class ReportResult {
        @AuraEnabled
        public String reportName;
        @AuraEnabled
        public String reportFormat;
        @AuraEnabled
        public Integer totalRows;
        @AuraEnabled
        public List<Map<String, Object>> aggregates;
        @AuraEnabled
        public List<Map<String, Object>> detailRows;
        @AuraEnabled
        public Boolean truncated = false;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Map<String, Object> metadata;

        public ReportResult() {
            this.metadata = new Map<String, Object>{ 'executionTime' => System.now(), 'success' => true };
        }
    }
}
