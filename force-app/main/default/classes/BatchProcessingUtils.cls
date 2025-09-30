/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * BatchProcessingUtils provides utility methods for batch processing operations in the AI Agent framework.
 * This class contains helper methods for batch job management, monitoring, and configuration.
 *
 * Responsibilities:
 *   - Batch job configuration and validation
 *   - Batch processing monitoring and reporting
 *   - Utility methods for batch data handling
 *   - Batch job scheduling and management
 *   - Performance optimization utilities
 */
public class BatchProcessingUtils {

    /**
     * Exception thrown when batch processing utilities encounter errors.
     */
    public class BatchUtilsException extends Exception {}

    /**
     * Batch job status information.
     */
    public class BatchJobStatus {
        public Id batchJobId;
        public Id parentExecutionId;
        public String jobName;
        public String status;
        public Integer totalBatches;
        public Integer processedBatches;
        public Integer totalRecords;
        public Integer processedRecords;
        public Integer failedRecords;
        public Datetime startTime;
        public Datetime endTime;
        public List<String> errors;
        public Map<String, Object> statistics;
    }

    /**
     * Batch processing statistics.
     */
    public class BatchStatistics {
        public Integer totalJobs;
        public Integer activeJobs;
        public Integer completedJobs;
        public Integer failedJobs;
        public Integer totalRecordsProcessed;
        public Decimal averageProcessingTime;
        public Map<String, Integer> jobsByAgent;
        public Map<String, Integer> jobsByStatus;
    }

    /**
     * Gets the status of a batch job by its Salesforce batch job ID.
     *
     * @param batchJobId The Salesforce batch job ID
     * @return BatchJobStatus current status information
     */
    public static BatchJobStatus getBatchJobStatus(Id batchJobId) {
        String logPrefix = '[BatchProcessingUtils.getBatchJobStatus] ';

        try {
            // Query AsyncApexJob for batch job information
            AsyncApexJob batchJob = [
                SELECT Id, Status, JobType, MethodName, TotalJobItems, JobItemsProcessed,
                       NumberOfErrors, CreatedDate, CompletedDate, ExtendedStatus
                FROM AsyncApexJob
                WHERE Id = :batchJobId
                LIMIT 1
            ];

            // Find the corresponding parent execution
            // Note: Using ExecutionMetadata__c instead of TriggerPayload__c for filtering as it's more reliable
            String batchJobIdString = String.valueOf(batchJobId);
            List<AgentExecution__c> parentExecutions = [
                SELECT Id, Name, ExecutionStatus__c, ProcessingStatus__c, StartTime__c,
                       EndTime__c, TriggerPayload__c, ExecutionMetadata__c
                FROM AgentExecution__c
                WHERE ExecutionType__c = 'Batch'
                AND ParentExecution__c = null
                AND CreatedDate = TODAY
                ORDER BY CreatedDate DESC
                LIMIT 10
            ];

            // Filter in memory for batch job ID since LIKE on long text fields can be unreliable
            List<AgentExecution__c> matchingExecutions = new List<AgentExecution__c>();
            for (AgentExecution__c exec : parentExecutions) {
                if (exec.TriggerPayload__c != null && exec.TriggerPayload__c.contains(batchJobIdString)) {
                    matchingExecutions.add(exec);
                }
            }
            parentExecutions = matchingExecutions;

            BatchJobStatus status = new BatchJobStatus();
            status.batchJobId = batchJobId;
            status.status = batchJob.Status;
            status.totalBatches = batchJob.TotalJobItems;
            status.processedBatches = batchJob.JobItemsProcessed;
            status.startTime = batchJob.CreatedDate;
            status.endTime = batchJob.CompletedDate;
            status.errors = new List<String>();

            if (!parentExecutions.isEmpty()) {
                AgentExecution__c parentExecution = parentExecutions[0];
                status.parentExecutionId = parentExecution.Id;
                status.jobName = extractJobNameFromPayload(parentExecution.TriggerPayload__c);

                // Get child execution statistics
                List<AggregateResult> childStats = [
                    SELECT COUNT(Id) totalRecords,
                           COUNT_DISTINCT(SourceRecordId__c) uniqueRecords,
                           ExecutionStatus__c status
                    FROM AgentExecution__c
                    WHERE ParentExecution__c = :parentExecution.Id
                    GROUP BY ExecutionStatus__c
                ];

                Integer totalRecords = 0;
                Integer processedRecords = 0;
                Integer failedRecords = 0;

                for (AggregateResult stat : childStats) {
                    Integer count = (Integer) stat.get('totalRecords');
                    String execStatus = (String) stat.get('status');

                    totalRecords += count;
                    if ('Completed'.equals(execStatus)) {
                        processedRecords += count;
                    } else if ('Failed'.equals(execStatus)) {
                        failedRecords += count;
                    }
                }

                status.totalRecords = totalRecords;
                status.processedRecords = processedRecords;
                status.failedRecords = failedRecords;
            }

            // Add error information if available
            if (batchJob.NumberOfErrors > 0) {
                status.errors.add('Batch job has ' + batchJob.NumberOfErrors + ' errors');
                if (String.isNotBlank(batchJob.ExtendedStatus)) {
                    status.errors.add('Extended Status: ' + batchJob.ExtendedStatus);
                }
            }

            return status;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error getting batch job status: ' + e.getMessage());
            throw new BatchUtilsException('Failed to get batch job status: ' + e.getMessage());
        }
    }

    /**
     * Gets batch processing statistics for a time period.
     *
     * @param days Number of days to look back
     * @return BatchStatistics processing statistics
     */
    public static BatchStatistics getBatchStatistics(Integer days) {
        String logPrefix = '[BatchProcessingUtils.getBatchStatistics] ';
        Datetime startDate = Datetime.now().addDays(-days);

        try {
            BatchStatistics stats = new BatchStatistics();
            stats.jobsByAgent = new Map<String, Integer>();
            stats.jobsByStatus = new Map<String, Integer>();

            // Query parent batch executions
            List<AggregateResult> parentStats = [
                SELECT COUNT(Id) totalJobs,
                       ExecutionStatus__c status,
                       AIAgentDefinition__r.DeveloperName__c agentName
                FROM AgentExecution__c
                WHERE ExecutionType__c = 'Batch'
                AND ParentExecution__c = null
                AND StartTime__c >= :startDate
                GROUP BY ExecutionStatus__c, AIAgentDefinition__r.DeveloperName__c
            ];

            Integer totalJobs = 0;
            Integer activeJobs = 0;
            Integer completedJobs = 0;
            Integer failedJobs = 0;

            for (AggregateResult stat : parentStats) {
                Integer jobCount = (Integer) stat.get('totalJobs');
                String status = (String) stat.get('status');
                String agentName = (String) stat.get('agentName');

                totalJobs += jobCount;

                // Count by status
                if ('Processing'.equals(status)) {
                    activeJobs += jobCount;
                } else if ('Completed'.equals(status)) {
                    completedJobs += jobCount;
                } else if ('Failed'.equals(status)) {
                    failedJobs += jobCount;
                }

                // Count by agent
                if (stats.jobsByAgent.containsKey(agentName)) {
                    stats.jobsByAgent.put(agentName, stats.jobsByAgent.get(agentName) + jobCount);
                } else {
                    stats.jobsByAgent.put(agentName, jobCount);
                }

                // Count by status
                if (stats.jobsByStatus.containsKey(status)) {
                    stats.jobsByStatus.put(status, stats.jobsByStatus.get(status) + jobCount);
                } else {
                    stats.jobsByStatus.put(status, jobCount);
                }
            }

            stats.totalJobs = totalJobs;
            stats.activeJobs = activeJobs;
            stats.completedJobs = completedJobs;
            stats.failedJobs = failedJobs;

            // Get total records processed
            List<AggregateResult> recordStats = [
                SELECT COUNT(Id) totalRecords
                FROM AgentExecution__c
                WHERE ExecutionType__c = 'Batch'
                AND ParentExecution__c != null
                AND StartTime__c >= :startDate
            ];

            if (!recordStats.isEmpty()) {
                stats.totalRecordsProcessed = (Integer) recordStats[0].get('totalRecords');
            }

            // Calculate average processing time
            // Note: SOQL doesn't support arithmetic in SELECT, so we'll calculate in memory
            List<AgentExecution__c> completedExecutions = [
                SELECT StartTime__c, EndTime__c
                FROM AgentExecution__c
                WHERE ExecutionType__c = 'Batch'
                AND ParentExecution__c = null
                AND ExecutionStatus__c = 'Completed'
                AND StartTime__c >= :startDate
                AND EndTime__c != null
                AND StartTime__c != null
                LIMIT 100
            ];

            if (!completedExecutions.isEmpty()) {
                Long totalDuration = 0;
                Integer validExecutions = 0;

                for (AgentExecution__c exec : completedExecutions) {
                    if (exec.StartTime__c != null && exec.EndTime__c != null) {
                        Long duration = exec.EndTime__c.getTime() - exec.StartTime__c.getTime();
                        totalDuration += duration;
                        validExecutions++;
                    }
                }

                if (validExecutions > 0) {
                    stats.averageProcessingTime = Decimal.valueOf(totalDuration) / validExecutions / 1000; // Convert to seconds
                }
            }

            return stats;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error getting batch statistics: ' + e.getMessage());
            throw new BatchUtilsException('Failed to get batch statistics: ' + e.getMessage());
        }
    }

    /**
     * Monitors active batch jobs and returns their current status.
     *
     * @return List<BatchJobStatus> list of active batch job statuses
     */
    public static List<BatchJobStatus> getActiveBatchJobs() {
        String logPrefix = '[BatchProcessingUtils.getActiveBatchJobs] ';

        try {
            List<BatchJobStatus> activeJobs = new List<BatchJobStatus>();

            // Query active AsyncApexJobs for BatchAgentProcessor
            List<AsyncApexJob> batchJobs = [
                SELECT Id, Status, JobType, MethodName, TotalJobItems, JobItemsProcessed,
                       NumberOfErrors, CreatedDate, CompletedDate, ExtendedStatus
                FROM AsyncApexJob
                WHERE JobType = 'BatchApex'
                AND MethodName LIKE '%BatchAgentProcessor%'
                AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
                ORDER BY CreatedDate DESC
                LIMIT 50
            ];

            for (AsyncApexJob job : batchJobs) {
                try {
                    BatchJobStatus status = getBatchJobStatus(job.Id);
                    activeJobs.add(status);
                } catch (Exception e) {
                    System.debug(LoggingLevel.WARN, logPrefix + 'Could not get status for job ' + job.Id + ': ' + e.getMessage());
                }
            }

            return activeJobs;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error getting active batch jobs: ' + e.getMessage());
            throw new BatchUtilsException('Failed to get active batch jobs: ' + e.getMessage());
        }
    }

    /**
     * Validates a SOQL query for batch processing.
     *
     * @param soqlQuery The SOQL query to validate
     * @return Boolean true if query is valid for batch processing
     */
    public static Boolean validateBatchQuery(String soqlQuery) {
        if (String.isBlank(soqlQuery)) {
            return false;
        }

        try {
            // Basic validation - query should start with SELECT
            if (!soqlQuery.trim().toLowerCase().startsWith('select')) {
                return false;
            }

            // Query should contain FROM clause
            if (!soqlQuery.toLowerCase().contains(' from ')) {
                return false;
            }

            // Try to execute a count query to validate syntax
            String countQuery = 'SELECT COUNT() FROM (' + soqlQuery + ')';
            Database.countQuery(countQuery);

            return true;

        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[BatchProcessingUtils] Query validation failed: ' + e.getMessage());
            return false;
        }
    }

    /**
     * Estimates the number of records that will be processed by a batch job.
     *
     * @param soqlQuery The SOQL query for the batch job
     * @return Integer estimated record count
     */
    public static Integer estimateBatchRecordCount(String soqlQuery) {
        try {
            String countQuery = 'SELECT COUNT() FROM (' + soqlQuery + ')';
            return Database.countQuery(countQuery);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[BatchProcessingUtils] Could not estimate record count: ' + e.getMessage());
            return 0;
        }
    }

    /**
     * Calculates optimal batch size based on record count and processing complexity.
     *
     * @param recordCount Total number of records to process
     * @param processingMode Processing mode (Individual, Grouped, Summary)
     * @return Integer recommended batch size
     */
    public static Integer calculateOptimalBatchSize(Integer recordCount, String processingMode) {
        Integer optimalSize = 200; // Default

        if (recordCount == null || recordCount <= 0) {
            return optimalSize;
        }

        // Adjust based on processing mode
        if ('Individual'.equals(processingMode)) {
            // Individual processing can handle more records per batch
            if (recordCount < 1000) {
                optimalSize = 200;
            } else if (recordCount < 10000) {
                optimalSize = 100;
            } else {
                optimalSize = 50;
            }
        } else if ('Grouped'.equals(processingMode)) {
            // Grouped processing handles fewer records but more complex operations
            if (recordCount < 1000) {
                optimalSize = 100;
            } else if (recordCount < 10000) {
                optimalSize = 50;
            } else {
                optimalSize = 25;
            }
        } else if ('Summary'.equals(processingMode)) {
            // Summary processing can handle larger batches
            optimalSize = 500;
        }

        // Ensure batch size is within Salesforce limits
        return Math.min(optimalSize, 2000);
    }

    /**
     * Aborts a running batch job.
     *
     * @param batchJobId The batch job ID to abort
     * @return Boolean true if successfully aborted
     */
    public static Boolean abortBatchJob(Id batchJobId) {
        String logPrefix = '[BatchProcessingUtils.abortBatchJob] ';

        try {
            System.abortJob(batchJobId);

            // Update parent execution status
            String batchJobIdString = String.valueOf(batchJobId);
            List<AgentExecution__c> allParentExecutions = [
                SELECT Id, TriggerPayload__c FROM AgentExecution__c
                WHERE ExecutionType__c = 'Batch'
                AND ParentExecution__c = NULL
                AND CreatedDate = TODAY
                LIMIT 10
            ];

            // Filter in memory for batch job ID
            List<AgentExecution__c> parentExecutions = new List<AgentExecution__c>();
            for (AgentExecution__c exec : allParentExecutions) {
                if (exec.TriggerPayload__c != null && exec.TriggerPayload__c.contains(batchJobIdString)) {
                    parentExecutions.add(exec);
                    break; // Only need the first match
                }
            }

            if (!parentExecutions.isEmpty()) {
                ExecutionContextService executionContextService = new ExecutionContextService();
                executionContextService.updateStatus(
                    parentExecutions[0].Id,
                    'Aborted',
                    AIAgentConstants.STATUS_FAILED,
                    null,
                    'Batch job was manually aborted'
                );
            }

            System.debug(LoggingLevel.INFO, logPrefix + 'Successfully aborted batch job: ' + batchJobId);
            return true;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error aborting batch job: ' + e.getMessage());
            return false;
        }
    }

    /**
     * Creates a batch job configuration for common scenarios.
     *
     * @param scenario The batch scenario (DataMigration, BulkUpdate, Analytics, etc.)
     * @param agentDeveloperName The agent to use for processing
     * @param objectType The SObject type to process
     * @param whereClause Optional WHERE clause for filtering
     * @return BatchAgentProcessor.BatchJobConfig configured for the scenario
     */
    public static BatchAgentProcessor.BatchJobConfig createScenarioConfig(
        String scenario,
        String agentDeveloperName,
        String objectType,
        String whereClause
    ) {
        // Build SOQL query
        String soqlQuery = 'SELECT Id, Name FROM ' + objectType;
        if (String.isNotBlank(whereClause)) {
            soqlQuery += ' WHERE ' + whereClause;
        }

        // Configure based on scenario
        String processingMode = 'Individual';
        Integer batchSize = 200;
        String jobName = scenario + ' - ' + objectType;

        switch on scenario.toLowerCase() {
            when 'datamigration' {
                processingMode = 'Individual';
                batchSize = 100;
                jobName = 'Data Migration: ' + objectType;
            }
            when 'bulkupdate' {
                processingMode = 'Grouped';
                batchSize = 200;
                jobName = 'Bulk Update: ' + objectType;
            }
            when 'analytics' {
                processingMode = 'Summary';
                batchSize = 500;
                jobName = 'Analytics Processing: ' + objectType;
            }
            when 'cleanup' {
                processingMode = 'Individual';
                batchSize = 50;
                jobName = 'Data Cleanup: ' + objectType;
            }
        }

        return BatchAgentProcessor.createSimpleBatchConfig(jobName, agentDeveloperName, soqlQuery, processingMode);
    }

    /**
     * Utility method to extract job name from trigger payload.
     */
    private static String extractJobNameFromPayload(String triggerPayload) {
        try {
            if (String.isNotBlank(triggerPayload)) {
                Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(triggerPayload);
                return (String) payload.get('batchJobName');
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[BatchProcessingUtils] Could not extract job name from payload: ' + e.getMessage());
        }
        return 'Unknown Batch Job';
    }

    /**
     * Schedules a batch job to run at a specific time.
     *
     * @param config Batch job configuration
     * @param scheduledTime When to run the batch job
     * @return String scheduled job ID
     */
    public static String scheduleBatchJob(BatchAgentProcessor.BatchJobConfig config, Datetime scheduledTime) {
        String cronExpression = getCronExpression(scheduledTime);
        String jobName = 'Scheduled Batch: ' + config.jobName;

        ScheduledBatchProcessor scheduler = new ScheduledBatchProcessor(config);
        return System.schedule(jobName, cronExpression, scheduler);
    }

    /**
     * Converts a Datetime to a cron expression.
     */
    private static String getCronExpression(Datetime scheduledTime) {
        return scheduledTime.second() + ' ' +
               scheduledTime.minute() + ' ' +
               scheduledTime.hour() + ' ' +
               scheduledTime.day() + ' ' +
               scheduledTime.month() + ' ' +
               '? ' +
               scheduledTime.year();
    }

    /**
     * Inner class for scheduled batch processing.
     */
    public class ScheduledBatchProcessor implements Schedulable {
        private BatchAgentProcessor.BatchJobConfig config;

        public ScheduledBatchProcessor(BatchAgentProcessor.BatchJobConfig config) {
            this.config = config;
        }

        public void execute(SchedulableContext sc) {
            BatchAgentProcessor.startBatchJob(config);
        }
    }
}
