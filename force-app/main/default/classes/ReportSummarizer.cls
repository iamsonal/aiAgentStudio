/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

public class ReportSummarizer {
    private static final Integer MAX_GROUPINGS_TO_RETURN = 15;

    /**
     * @description Main entry point. Analyzes the report format and delegates to the appropriate summarizer.
     * @param results The Reports.ReportResults object from a synchronous report run.
     * @return Map<String, Object> A structured map containing the report summary.
     */
    public static Map<String, Object> summarize(Reports.ReportResults results) {
        Reports.ReportMetadata metadata = results.getReportMetadata();
        Reports.ReportFormat reportFormat = metadata.getReportFormat();
        String reportFormatName = reportFormat.name();

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
                return new Map<String, Object>{
                    'isSuccess' => false,
                    'status' => 'UNKNOWN_FORMAT',
                    'message' => 'Could not process unknown report format: ' + reportFormatName
                };
            }
        }
    }

    /**
     * @description Summarizes a Tabular report. Focuses on record count.
     */
    private static Map<String, Object> summarizeTabular(Reports.ReportResults results, Reports.ReportMetadata metadata) {
        Integer recordCount = getRecordCount(results);
        String summaryMessage = 'The report "' + metadata.getName() + '" returned ' + recordCount + ' records.';

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
     * @description Summarizes a Summary report. Includes top-level groupings and aggregates.
     */
    private static Map<String, Object> summarizeSummary(Reports.ReportResults results, Reports.ReportMetadata metadata) {
        Integer recordCount = getRecordCount(results);
        List<String> aggregateLabels = metadata.getAggregates();

        List<String> groupingLabels = new List<String>();
        List<Reports.GroupingInfo> groupingsDownInfo = metadata.getGroupingsDown();
        List<Reports.GroupingInfo> groupingsAcrossInfo = metadata.getGroupingsAcross();

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

        Map<String, Reports.ReportFact> factMap = results.getFactMap();

        Reports.ReportFact grandTotalFact = factMap.get('T!T');
        if (grandTotalFact != null) {
            summaryMap.put('grandTotal', extractAggregates(grandTotalFact, aggregateLabels));
        }

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

        return summaryMap;
    }

    /**
     * @description Summarizes a Matrix report. Includes row and column groupings.
     */
    private static Map<String, Object> summarizeMatrix(Reports.ReportResults results, Reports.ReportMetadata metadata) {
        Integer recordCount = getRecordCount(results);
        List<String> aggregateLabels = metadata.getAggregates();

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

        Map<String, Reports.ReportFact> factMap = results.getFactMap();

        Reports.ReportFact grandTotalFact = factMap.get('T!T');
        if (grandTotalFact != null) {
            summaryMap.put('grandTotal', extractAggregates(grandTotalFact, aggregateLabels));
        }

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

        return summaryMap;
    }

    /**
     * @description Helper to extract aggregate values from a ReportFact.
     * @param fact The ReportFact for a specific grouping (or grand total).
     * @param aggregateLabels The ordered list of aggregate API names from metadata.
     * @return Map<String, Object> A map of aggregate name to its value.
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
     * @description Helper to get record count from report results
     * @param results The report results
     * @return Integer The total record count
     */
    private static Integer getRecordCount(Reports.ReportResults results) {
        Map<String, Reports.ReportFact> factMap = results.getFactMap();
        Reports.ReportFact grandTotalFact = factMap.get('T!T');

        if (grandTotalFact != null) {
            List<Reports.SummaryValue> aggregates = grandTotalFact.getAggregates();

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

                Object firstValue = aggregates[0].getValue();
                if (firstValue instanceof Integer) {
                    return (Integer) firstValue;
                } else if (firstValue instanceof Decimal) {
                    return ((Decimal) firstValue).intValue();
                }
            }
        }

        Integer count = 0;
        for (String key : factMap.keySet()) {
            if (!key.contains('!')) {
                count++;
            }
        }
        return count;
    }
}
