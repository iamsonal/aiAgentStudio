/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * ReportSummarizer: Enterprise report analysis and summarization service for AI-driven insights.
 *
 * This class processes Salesforce report results across all formats (Tabular, Summary, Matrix) to generate
 * structured summaries with key metrics, grouping analysis, and aggregate data extraction. It is optimized for
 * AI agent consumption, with configurable output limits, intelligent data prioritization, and clear, actionable summaries.
 *
 * Key Responsibilities:
 *   - Analyzes report format and routes to the appropriate summarization strategy.
 *   - Extracts and structures key metrics, groupings, and aggregate data for all report types.
 *   - Provides concise, LLM-friendly summaries and diagnostics for downstream automation.
 *   - Limits output size to prevent excessive payloads and ensures performance.
 */
public class ReportSummarizer {
    private static final Integer MAX_GROUPINGS_TO_RETURN = 15; // Prevent huge payloads

    /**
     * @description
     * Analyzes report format and routes to the appropriate summarization strategy.
     * Provides a unified interface for all Salesforce report types with structured output.
     *
     * @param results Report execution results from Reports API
     * @return Map containing structured summary with format-specific analysis and metrics
     */
    public static Map<String, Object> summarize(Reports.ReportResults results) {
        Reports.ReportMetadata metadata = results.getReportMetadata();
        Reports.ReportFormat reportFormat = metadata.getReportFormat();
        String reportFormatName = reportFormat.name();

        System.debug(LoggingLevel.INFO, '[ReportSummarizer] Processing ' + reportFormatName + ' report: ' + metadata.getName());

        switch on reportFormatName {
            when 'TABULAR' {
                return summarizeTabular(results, metadata);
            }
            when 'SUMMARY' {
                return summarizeSummary(results, metadata);
            }
            when 'MATRIX' {
                return summarizeMatrix(results, metadata);
            }
            when else {
                System.debug(LoggingLevel.ERROR, '[ReportSummarizer] Unknown report format: ' + reportFormatName);
                return new Map<String, Object>{
                    'isSuccess' => false,
                    'status' => 'UNKNOWN_FORMAT',
                    'message' => 'Could not process unknown report format: ' + reportFormatName
                };
            }
        }
    }

    /**
     * @description
     * Processes tabular reports, focusing on record count and basic metrics.
     * Tabular reports contain raw data without groupings or aggregations.
     *
     * @param results Report execution results
     * @param metadata Report metadata
     * @return Map with summary and metrics for tabular report
     */
    private static Map<String, Object> summarizeTabular(Reports.ReportResults results, Reports.ReportMetadata metadata) {
        Integer recordCount = getRecordCount(results);
        String summaryMessage = 'The report "' + metadata.getName() + '" returned ' + recordCount + ' records.';

        System.debug(LoggingLevel.DEBUG, '[ReportSummarizer] Tabular report processed: ' + recordCount + ' records');

        return new Map<String, Object>{
            'isSuccess' => true,
            'status' => 'SUCCESS',
            'reportName' => metadata.getName(),
            'reportFormat' => 'Tabular',
            'recordCount' => recordCount,
            'summary' => summaryMessage
        };
    }

    /**
     * @description
     * Processes summary reports with groupings and aggregate analysis.
     * Extracts grouping hierarchies, aggregate values, and provides top-level insights.
     *
     * @param results Report execution results
     * @param metadata Report metadata
     * @return Map with summary, groupings, and aggregate metrics for summary report
     */
    private static Map<String, Object> summarizeSummary(Reports.ReportResults results, Reports.ReportMetadata metadata) {
        Integer recordCount = getRecordCount(results);
        List<String> aggregateLabels = metadata.getAggregates();

        // Get grouping field names
        List<String> groupingLabels = new List<String>();
        List<Reports.GroupingInfo> groupingsDownInfo = metadata.getGroupingsDown();
        List<Reports.GroupingInfo> groupingsAcrossInfo = metadata.getGroupingsAcross();

        // Extract field names from GroupingInfo
        if (groupingsDownInfo != null) {
            for (Reports.GroupingInfo gi : groupingsDownInfo) {
                groupingLabels.add(gi.getName());
            }
        }
        if (groupingsAcrossInfo != null) {
            for (Reports.GroupingInfo gi : groupingsAcrossInfo) {
                groupingLabels.add(gi.getName());
            }
        }

        Map<String, Object> summaryMap = new Map<String, Object>{
            'isSuccess' => true,
            'status' => 'SUCCESS',
            'reportName' => metadata.getName(),
            'reportFormat' => 'Summary',
            'recordCount' => recordCount,
            'groupingFields' => groupingLabels,
            'groupings' => new List<Map<String, Object>>(),
            'grandTotal' => new Map<String, Object>()
        };

        // The fact map is the source of all summary data
        Map<String, Reports.ReportFact> factMap = results.getFactMap();

        // Extract grand total aggregates for overall metrics
        Reports.ReportFact grandTotalFact = factMap.get('T!T');
        if (grandTotalFact != null) {
            summaryMap.put('grandTotal', extractAggregates(grandTotalFact, aggregateLabels));
        }

        // Process grouping data with configurable limits
        Reports.Dimension groupingInfo = results.getGroupingsDown();
        Integer groupingCount = 0;

        if (groupingInfo != null && groupingInfo.getGroupings() != null) {
            for (Reports.GroupingValue groupingValue : groupingInfo.getGroupings()) {
                if (groupingCount >= MAX_GROUPINGS_TO_RETURN)
                    break;

                String groupKey = groupingValue.getKey();
                Reports.ReportFact groupFact = factMap.get(groupKey + '!T');

                if (groupFact != null) {
                    Map<String, Object> groupDetail = new Map<String, Object>{
                        'groupingValue' => groupingValue.getLabel(),
                        'key' => groupingValue.getKey(),
                        'aggregates' => extractAggregates(groupFact, aggregateLabels)
                    };
                    ((List<Map<String, Object>>) summaryMap.get('groupings')).add(groupDetail);
                    groupingCount++;
                }
            }
        }

        String summaryMessage = 'The report "' + metadata.getName() + '" returned ' + recordCount + ' records';
        if (!groupingLabels.isEmpty()) {
            summaryMessage += ', grouped by ' + String.join(groupingLabels, ', ');
        }
        summaryMessage += '.';

        if (groupingCount >= MAX_GROUPINGS_TO_RETURN) {
            summaryMessage += ' The summary includes the top ' + MAX_GROUPINGS_TO_RETURN + ' groups.';
        }

        summaryMap.put('summary', summaryMessage);

        System.debug(LoggingLevel.DEBUG, '[ReportSummarizer] Summary report processed: ' + recordCount + ' records, ' + groupingCount + ' groupings');

        return summaryMap;
    }

    /**
     * @description
     * Processes matrix reports with two-dimensional grouping analysis.
     * Handles row and column groupings with cross-tabulated aggregate data.
     *
     * @param results Report execution results
     * @param metadata Report metadata
     * @return Map with summary, row/column groupings, and aggregate metrics for matrix report
     */
    private static Map<String, Object> summarizeMatrix(Reports.ReportResults results, Reports.ReportMetadata metadata) {
        Integer recordCount = getRecordCount(results);
        List<String> aggregateLabels = metadata.getAggregates();

        // Get grouping field names
        List<String> rowGroupings = new List<String>();
        List<String> columnGroupings = new List<String>();

        List<Reports.GroupingInfo> rowGroupingsInfo = metadata.getGroupingsDown();
        List<Reports.GroupingInfo> columnGroupingsInfo = metadata.getGroupingsAcross();

        if (rowGroupingsInfo != null) {
            for (Reports.GroupingInfo gi : rowGroupingsInfo) {
                rowGroupings.add(gi.getName());
            }
        }
        if (columnGroupingsInfo != null) {
            for (Reports.GroupingInfo gi : columnGroupingsInfo) {
                columnGroupings.add(gi.getName());
            }
        }

        Map<String, Object> summaryMap = new Map<String, Object>{
            'isSuccess' => true,
            'status' => 'SUCCESS',
            'reportName' => metadata.getName(),
            'reportFormat' => 'Matrix',
            'recordCount' => recordCount,
            'rowGroupingFields' => rowGroupings,
            'columnGroupingFields' => columnGroupings,
            'matrixData' => new List<Map<String, Object>>(),
            'grandTotal' => new Map<String, Object>()
        };

        // The fact map is the source of all summary data
        Map<String, Reports.ReportFact> factMap = results.getFactMap();

        // Process Grand Total
        Reports.ReportFact grandTotalFact = factMap.get('T!T');
        if (grandTotalFact != null) {
            summaryMap.put('grandTotal', extractAggregates(grandTotalFact, aggregateLabels));
        }

        // Process row groupings
        Reports.Dimension rowDimension = results.getGroupingsDown();
        Integer processedCount = 0;

        if (rowDimension != null && rowDimension.getGroupings() != null) {
            for (Reports.GroupingValue rowGrouping : rowDimension.getGroupings()) {
                if (processedCount >= MAX_GROUPINGS_TO_RETURN)
                    break;

                Map<String, Object> rowData = new Map<String, Object>{
                    'rowLabel' => rowGrouping.getLabel(),
                    'rowKey' => rowGrouping.getKey(),
                    'rowTotal' => new Map<String, Object>(),
                    'cells' => new List<Map<String, Object>>()
                };

                // Get row total
                String rowTotalKey = rowGrouping.getKey() + '!T';
                Reports.ReportFact rowTotalFact = factMap.get(rowTotalKey);
                if (rowTotalFact != null) {
                    rowData.put('rowTotal', extractAggregates(rowTotalFact, aggregateLabels));
                }

                ((List<Map<String, Object>>) summaryMap.get('matrixData')).add(rowData);
                processedCount++;
            }
        }

        String summaryMessage = 'The matrix report "' + metadata.getName() + '" returned ' + recordCount + ' records';
        if (!rowGroupings.isEmpty() || !columnGroupings.isEmpty()) {
            List<String> groupingDescriptions = new List<String>();
            if (!rowGroupings.isEmpty()) {
                groupingDescriptions.add('rows: ' + String.join(rowGroupings, ', '));
            }
            if (!columnGroupings.isEmpty()) {
                groupingDescriptions.add('columns: ' + String.join(columnGroupings, ', '));
            }
            summaryMessage += ', grouped by ' + String.join(groupingDescriptions, ' and ');
        }
        summaryMessage += '.';

        summaryMap.put('summary', summaryMessage);

        System.debug(
            LoggingLevel.DEBUG,
            '[ReportSummarizer] Matrix report processed: ' + recordCount + ' records, ' + processedCount + ' row groupings'
        );

        return summaryMap;
    }

    /**
     * @description
     * Extracts and structures aggregate values from report facts with proper labeling.
     *
     * @param fact ReportFact containing aggregate data for a specific grouping or grand total
     * @param aggregateLabels Ordered list of aggregate field API names from report metadata
     * @return Map of aggregate names to structured value/label pairs
     */
    private static Map<String, Object> extractAggregates(Reports.ReportFact fact, List<String> aggregateLabels) {
        Map<String, Object> aggregateMap = new Map<String, Object>();
        List<Reports.SummaryValue> summaryValues = fact.getAggregates();

        for (Integer i = 0; i < summaryValues.size(); i++) {
            if (i < aggregateLabels.size()) {
                String aggLabel = aggregateLabels[i];
                Reports.SummaryValue summaryValue = summaryValues[i];
                Object aggValue = summaryValue.getValue();
                String aggLabel_formatted = summaryValue.getLabel();

                aggregateMap.put(aggLabel, new Map<String, Object>{ 'value' => aggValue, 'label' => aggLabel_formatted });
            }
        }
        return aggregateMap;
    }

    /**
     * @description
     * Intelligently extracts record count from report results using multiple fallback strategies.
     * Attempts to find explicit record count aggregate, then falls back to detail row counting.
     *
     * @param results Report execution results
     * @return Integer Total record count from the report
     */
    private static Integer getRecordCount(Reports.ReportResults results) {
        Map<String, Reports.ReportFact> factMap = results.getFactMap();
        Reports.ReportFact grandTotalFact = factMap.get('T!T');

        if (grandTotalFact != null) {
            List<Reports.SummaryValue> aggregates = grandTotalFact.getAggregates();

            // Primary strategy: look for explicit record count aggregate
            if (!aggregates.isEmpty()) {
                for (Reports.SummaryValue sv : aggregates) {
                    if (sv.getLabel() != null && sv.getLabel().toLowerCase().contains('record count')) {
                        Object value = sv.getValue();
                        if (value instanceof Integer) {
                            return (Integer) value;
                        } else if (value instanceof Decimal) {
                            return ((Decimal) value).intValue();
                        }
                    }
                }

                // Secondary strategy: use first numeric aggregate as proxy
                Object firstValue = aggregates[0].getValue();
                if (firstValue instanceof Integer) {
                    return (Integer) firstValue;
                } else if (firstValue instanceof Decimal) {
                    return ((Decimal) firstValue).intValue();
                }
            }
        }

        // Fallback strategy: count detail-level fact entries
        Integer count = 0;
        for (String key : factMap.keySet()) {
            if (!key.contains('!')) {
                count++;
            }
        }

        System.debug(LoggingLevel.DEBUG, '[ReportSummarizer] Record count determined using fallback method: ' + count);
        return count;
    }
}
