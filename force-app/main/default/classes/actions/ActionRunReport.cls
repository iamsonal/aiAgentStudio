/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Standard Action: Runs a Salesforce Tabular or Summary report and returns an
 *              intelligent, token-efficient summary of the results.
 * @extends BaseAgentAction
 */
public class ActionRunReport extends BaseAgentAction {
    private static final String ARG_REPORT_NAME = 'reportDeveloperName';

    protected override String getLogPrefixName() {
        return 'ActionRunReport';
    }

    protected override void parseActionConfiguration(String actionConfigurationJson, String logPrefix) {
        super.parseActionConfiguration(actionConfigurationJson, logPrefix);
        if (this.parsedActionConfig != null && !this.parsedActionConfig.isEmpty()) {
        }
    }

    /**
     * @description Inner class to hold parsed and validated arguments from the LLM.
     */
    private class RunReportArgs extends BaseAgentAction.ParsedArguments {
        String reportDeveloperName;

        public RunReportArgs(String jsonArguments) {
            Map<String, Object> parsedArgs = (Map<String, Object>) JSON.deserializeUntyped(jsonArguments);
            this.reportDeveloperName = ParameterExtractionUtils.getRequiredString(parsedArgs, ARG_REPORT_NAME);
        }
    }

    protected override BaseAgentAction.ParsedArguments parseAndValidateArguments(String argumentsJson, String logPrefix) {
        try {
            return new RunReportArgs(argumentsJson);
        } catch (Exception e) {
            throw new ValidationException('Failed to parse arguments for RunReport: ' + e.getMessage(), null, e);
        }
    }

    protected override ActionResult performAction(BaseAgentAction.ParsedArguments validatedArgs, String logPrefix) {
        RunReportArgs args = (RunReportArgs) validatedArgs;

        Id reportId;
        try {
            List<Report> reports = [SELECT Id FROM Report WHERE DeveloperName = :args.reportDeveloperName WITH USER_MODE LIMIT 1];
            if (reports.isEmpty()) {
                throw new ValidationException(
                    'No report found with Developer Name "' + args.reportDeveloperName + '" or user lacks access.',
                    ARG_REPORT_NAME
                );
            }
            reportId = reports[0].Id;
        } catch (Exception e) {
            throw e;
        }

        Reports.ReportResults results = Reports.ReportManager.runReport(reportId, true);

        Map<String, Object> summaryPayload = ReportSummarizer.summarize(results);

        Boolean wasSuccess = (Boolean) summaryPayload.get('isSuccess');
        if (!wasSuccess) {
            return this.runtimeError((String) summaryPayload.get('message'), AIAgentConstants.ERR_CODE_INPUT_VALIDATION, null);
        }

        String successMsg = (String) summaryPayload.get('summary');
        String internalDetails = 'Successfully ran and summarized report: ' + results.getReportMetadata().getName();

        return this.success(summaryPayload, successMsg, internalDetails);
    }
}
