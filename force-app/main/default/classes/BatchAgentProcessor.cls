/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * BatchAgentProcessor handles batch processing of records through AI agents using the unified execution framework.
 * This class implements the DML phase of the batch processing pattern, creating AgentExecution__c records
 * and publishing platform events for async processing.
 *
 * Responsibilities:
 *   - Processes collections of records in batches
 *   - Creates parent and child execution records for batch hierarchy
 *   - Manages batch size limits and chunking
 *   - Publishes platform events for async LLM processing
 *   - Handles batch job monitoring and status tracking
 *   - Supports different batch processing strategies
 */
public class BatchAgentProcessor implements Database.Batchable<SObject>, Database.Stateful {

    /**
     * Exception thrown when batch processing configuration is invalid.
     */
    public class BatchProcessingException extends Exception {}

    /**
     * Configuration for batch processing jobs.
     */
    public class BatchJobConfig {
        public String jobName;
        public String description;
        public Id agentDefinitionId;
        public String soqlQuery;
        public Integer batchSize;
        public String processingMode; // 'Individual', 'Grouped', 'Summary'
        public Map<String, Object> processingParameters;
        public Boolean createChildExecutions;
        public String triggerSource;
        public Id parentExecutionId;
    }

    /**
     * Batch processing context and state.
     */
    public class BatchContext {
        public BatchJobConfig config;
        public Id parentExecutionId;
        public Integer totalBatches;
        public Integer processedBatches;
        public Integer totalRecords;
        public Integer processedRecords;
        public List<String> errors;
        public Datetime startTime;
    }

    // Stateful properties to maintain context across batch executions
    private BatchContext batchContext;
    private static final Integer DEFAULT_BATCH_SIZE = 200;
    private static final Integer MAX_BATCH_SIZE = 2000;

    /**
     * Constructor for batch processing with configuration.
     *
     * @param config Batch job configuration
     */
    public BatchAgentProcessor(BatchJobConfig config) {
        this.batchContext = new BatchContext();
        this.batchContext.config = config;
        this.batchContext.errors = new List<String>();
        this.batchContext.startTime = Datetime.now();
        this.batchContext.processedBatches = 0;
        this.batchContext.processedRecords = 0;

        // Validate configuration
        validateBatchConfig(config);
    }

    /**
     * Database.Batchable start method - defines the query for batch processing.
     *
     * @param bc Database.BatchableContext
     * @return Database.QueryLocator for the records to process
     */
    public Database.QueryLocator start(Database.BatchableContext bc) {
        String logPrefix = '[BatchAgentProcessor.start] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Starting batch job: ' + batchContext.config.jobName);

        try {
            // Create parent execution record for the entire batch job
            batchContext.parentExecutionId = createParentExecution(bc.getJobId());

            // Return query locator for the records to process
            return Database.getQueryLocator(batchContext.config.soqlQuery);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in batch start: ' + e.getMessage());
            throw new BatchProcessingException('Failed to start batch job: ' + e.getMessage());
        }
    }

    /**
     * Database.Batchable execute method - processes each batch of records.
     *
     * @param bc Database.BatchableContext
     * @param scope List of SObjects to process in this batch
     */
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        String logPrefix = '[BatchAgentProcessor.execute] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Processing batch with ' + scope.size() + ' records');

        try {
            batchContext.processedBatches++;
            batchContext.processedRecords += scope.size();

            // Process records based on processing mode
            switch on batchContext.config.processingMode {
                when 'Individual' {
                    processIndividualRecords(scope);
                }
                when 'Grouped' {
                    processGroupedRecords(scope);
                }
                when 'Summary' {
                    processSummaryBatch(scope);
                }
                when else {
                    processIndividualRecords(scope); // Default to individual processing
                }
            }

            // Update parent execution progress
            updateParentExecutionProgress();

            System.debug(LoggingLevel.INFO, logPrefix + 'Completed batch ' + batchContext.processedBatches +
                        '. Total records processed: ' + batchContext.processedRecords);

        } catch (Exception e) {
            String errorMsg = 'Batch execution error: ' + e.getMessage();
            batchContext.errors.add(errorMsg);
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg + '\nStack Trace: ' + e.getStackTraceString());

            // Continue processing other batches even if one fails
        }
    }

    /**
     * Database.Batchable finish method - completes the batch job.
     *
     * @param bc Database.BatchableContext
     */
    public void finish(Database.BatchableContext bc) {
        String logPrefix = '[BatchAgentProcessor.finish] ';
        System.debug(LoggingLevel.INFO, logPrefix + 'Finishing batch job: ' + batchContext.config.jobName);

        try {
            // Update parent execution with final status
            finalizeParentExecution(bc);

            // Send completion notification if configured
            sendBatchCompletionNotification();

            System.debug(LoggingLevel.INFO, logPrefix + 'Batch job completed successfully. ' +
                        'Processed ' + batchContext.processedRecords + ' records in ' +
                        batchContext.processedBatches + ' batches');

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, logPrefix + 'Error in batch finish: ' + e.getMessage());
        }
    }

    /**
     * Processes records individually - creates separate execution for each record.
     *
     * @param records List of records to process
     */
    private void processIndividualRecords(List<SObject> records) {
        String logPrefix = '[BatchAgentProcessor.processIndividualRecords] ';

        List<AgentExecution__c> executions = new List<AgentExecution__c>();
        List<ExecutionStep__c> steps = new List<ExecutionStep__c>();
        List<AsyncFrameworkRequest__e> events = new List<AsyncFrameworkRequest__e>();

        for (SObject record : records) {
            try {
                // Create individual execution record
                String turnIdentifier = generateTurnIdentifier();

                AgentExecution__c execution = new AgentExecution__c(
                    ExecutionType__c = 'Batch',
                    AIAgentDefinition__c = batchContext.config.agentDefinitionId,
                    TriggerSource__c = batchContext.config.triggerSource ?? 'BatchJob',
                    ExecutionStatus__c = 'Processing',
                    ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
                    StartTime__c = Datetime.now(),
                    LastActivityTime__c = Datetime.now(),
                    CurrentTurnIdentifier__c = turnIdentifier,
                    User__c = UserInfo.getUserId(),
                    SourceRecordId__c = record.Id,
                    ParentExecution__c = batchContext.parentExecutionId,
                    TriggerPayload__c = JSON.serialize(new Map<String, Object>{
                        'batchJobName' => batchContext.config.jobName,
                        'processingMode' => 'Individual',
                        'recordId' => record.Id,
                        'recordType' => String.valueOf(record.getSObjectType())
                    }),
                    ExecutionMetadata__c = JSON.serialize(new Map<String, Object>{
                        'batchContext' => true,
                        'parentExecutionId' => batchContext.parentExecutionId,
                        'processingMode' => 'Individual'
                    })
                );
                executions.add(execution);

            } catch (Exception e) {
                String errorMsg = 'Error creating execution for record ' + record.Id + ': ' + e.getMessage();
                batchContext.errors.add(errorMsg);
                System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
            }
        }

        // Insert executions
        if (!executions.isEmpty()) {
            insert executions;

            // Create execution steps and platform events
            for (Integer i = 0; i < executions.size() && i < records.size(); i++) {
                AgentExecution__c execution = executions[i];
                SObject record = records[i];

                // Create execution step
                ExecutionStep__c step = new ExecutionStep__c(
                    AgentExecution__c = execution.Id,
                    StepType__c = 'BatchItem',
                    StepRole__c = 'System',
                    Content__c = 'Processing record: ' + record.Id + ' (' + record.getSObjectType() + ')',
                    ContentType__c = 'BatchItem',
                    Timestamp__c = Datetime.now(),
                    TurnIdentifier__c = execution.CurrentTurnIdentifier__c,
                    TurnCount__c = 1,
                    StepMetadata__c = JSON.serialize(new Map<String, Object>{
                        'recordId' => record.Id,
                        'recordType' => String.valueOf(record.getSObjectType()),
                        'batchProcessing' => true
                    })
                );
                steps.add(step);

                // Create platform event for async processing
                Map<String, Object> eventPayload = new Map<String, Object>{
                    'executionId' => execution.Id,
                    'triggerSource' => 'BatchJob',
                    'batchJobName' => batchContext.config.jobName,
                    'processingMode' => 'Individual',
                    'recordId' => record.Id,
                    'recordType' => String.valueOf(record.getSObjectType()),
                    'recordData' => getRecordData(record),
                    'parentExecutionId' => batchContext.parentExecutionId
                };

                AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
                    SessionId__c = execution.Id,
                    TurnIdentifier__c = execution.CurrentTurnIdentifier__c,
                    JobType__c = 'InitiateExecution',
                    Payload__c = JSON.serialize(eventPayload)
                );
                events.add(event);
            }

            // Insert steps and publish events
            if (!steps.isEmpty()) {
                insert steps;
            }

            if (!events.isEmpty()) {
                List<Database.SaveResult> eventResults = EventBus.publish(events);
                for (Database.SaveResult result : eventResults) {
                    if (!result.isSuccess()) {
                        String errorMsg = 'Failed to publish batch event: ' + result.getErrors()[0].getMessage();
                        batchContext.errors.add(errorMsg);
                        System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
                    }
                }
            }
        }
    }

    /**
     * Processes records as a group - creates single execution for the entire batch.
     *
     * @param records List of records to process as a group
     */
    private void processGroupedRecords(List<SObject> records) {
        String logPrefix = '[BatchAgentProcessor.processGroupedRecords] ';

        try {
            // Create single execution for the entire group
            String turnIdentifier = generateTurnIdentifier();

            AgentExecution__c execution = new AgentExecution__c(
                ExecutionType__c = 'Batch',
                AIAgentDefinition__c = batchContext.config.agentDefinitionId,
                TriggerSource__c = batchContext.config.triggerSource ?? 'BatchJob',
                ExecutionStatus__c = 'Processing',
                ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                CurrentTurnIdentifier__c = turnIdentifier,
                User__c = UserInfo.getUserId(),
                ParentExecution__c = batchContext.parentExecutionId,
                TriggerPayload__c = JSON.serialize(new Map<String, Object>{
                    'batchJobName' => batchContext.config.jobName,
                    'processingMode' => 'Grouped',
                    'recordCount' => records.size(),
                    'recordIds' => getRecordIds(records)
                }),
                ExecutionMetadata__c = JSON.serialize(new Map<String, Object>{
                    'batchContext' => true,
                    'parentExecutionId' => batchContext.parentExecutionId,
                    'processingMode' => 'Grouped',
                    'recordCount' => records.size()
                })
            );

            insert execution;

            // Create execution step for the group
            ExecutionStep__c step = new ExecutionStep__c(
                AgentExecution__c = execution.Id,
                StepType__c = 'BatchItem',
                StepRole__c = 'System',
                Content__c = 'Processing batch group with ' + records.size() + ' records',
                ContentType__c = 'BatchGroup',
                Timestamp__c = Datetime.now(),
                TurnIdentifier__c = execution.CurrentTurnIdentifier__c,
                TurnCount__c = 1,
                StepMetadata__c = JSON.serialize(new Map<String, Object>{
                    'recordCount' => records.size(),
                    'recordIds' => getRecordIds(records),
                    'batchProcessing' => true
                })
            );

            insert step;

            // Create platform event for async processing
            Map<String, Object> eventPayload = new Map<String, Object>{
                'executionId' => execution.Id,
                'triggerSource' => 'BatchJob',
                'batchJobName' => batchContext.config.jobName,
                'processingMode' => 'Grouped',
                'recordCount' => records.size(),
                'recordIds' => getRecordIds(records),
                'recordsData' => getRecordsData(records),
                'parentExecutionId' => batchContext.parentExecutionId
            };

            AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
                SessionId__c = execution.Id,
                TurnIdentifier__c = execution.CurrentTurnIdentifier__c,
                JobType__c = 'InitiateExecution',
                Payload__c = JSON.serialize(eventPayload)
            );

            Database.SaveResult eventResult = EventBus.publish(event);
            if (!eventResult.isSuccess()) {
                throw new BatchProcessingException('Failed to publish grouped batch event: ' + eventResult.getErrors()[0].getMessage());
            }

        } catch (Exception e) {
            String errorMsg = 'Error processing grouped records: ' + e.getMessage();
            batchContext.errors.add(errorMsg);
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
        }
    }

    /**
     * Processes records as a summary - creates execution with summary information.
     *
     * @param records List of records to summarize
     */
    private void processSummaryBatch(List<SObject> records) {
        String logPrefix = '[BatchAgentProcessor.processSummaryBatch] ';

        try {
            // Create summary execution
            String turnIdentifier = generateTurnIdentifier();

            // Generate summary information
            Map<String, Object> summaryData = generateBatchSummary(records);

            AgentExecution__c execution = new AgentExecution__c(
                ExecutionType__c = 'Batch',
                AIAgentDefinition__c = batchContext.config.agentDefinitionId,
                TriggerSource__c = batchContext.config.triggerSource ?? 'BatchJob',
                ExecutionStatus__c = 'Processing',
                ProcessingStatus__c = AIAgentConstants.STATUS_PROCESSING,
                StartTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now(),
                CurrentTurnIdentifier__c = turnIdentifier,
                User__c = UserInfo.getUserId(),
                ParentExecution__c = batchContext.parentExecutionId,
                TriggerPayload__c = JSON.serialize(new Map<String, Object>{
                    'batchJobName' => batchContext.config.jobName,
                    'processingMode' => 'Summary',
                    'summaryData' => summaryData
                }),
                ExecutionMetadata__c = JSON.serialize(new Map<String, Object>{
                    'batchContext' => true,
                    'parentExecutionId' => batchContext.parentExecutionId,
                    'processingMode' => 'Summary',
                    'summaryGenerated' => true
                })
            );

            insert execution;

            // Create platform event for summary processing
            Map<String, Object> eventPayload = new Map<String, Object>{
                'executionId' => execution.Id,
                'triggerSource' => 'BatchJob',
                'batchJobName' => batchContext.config.jobName,
                'processingMode' => 'Summary',
                'summaryData' => summaryData,
                'parentExecutionId' => batchContext.parentExecutionId
            };

            AsyncFrameworkRequest__e event = new AsyncFrameworkRequest__e(
                SessionId__c = execution.Id,
                TurnIdentifier__c = execution.CurrentTurnIdentifier__c,
                JobType__c = 'InitiateExecution',
                Payload__c = JSON.serialize(eventPayload)
            );

            Database.SaveResult eventResult = EventBus.publish(event);
            if (!eventResult.isSuccess()) {
                throw new BatchProcessingException('Failed to publish summary batch event: ' + eventResult.getErrors()[0].getMessage());
            }

        } catch (Exception e) {
            String errorMsg = 'Error processing summary batch: ' + e.getMessage();
            batchContext.errors.add(errorMsg);
            System.debug(LoggingLevel.ERROR, logPrefix + errorMsg);
        }
    }

    /**
     * Creates the parent execution record for the entire batch job.
     *
     * @param batchJobId The Salesforce batch job ID
     * @return Id of the created parent execution
     */
    private Id createParentExecution(Id batchJobId) {
        ExecutionContextService executionContextService = new ExecutionContextService();

        Map<String, Object> batchMetadata = new Map<String, Object>{
            'batchJobName' => batchContext.config.jobName,
            'batchJobId' => batchJobId,
            'batchSize' => batchContext.config.batchSize,
            'processingMode' => batchContext.config.processingMode,
            'startTime' => batchContext.startTime,
            'isParentExecution' => true
        };

        Id parentExecutionId = executionContextService.createExecution(
            'Batch', // ExecutionType__c
            batchContext.config.agentDefinitionId, // AIAgentDefinition__c
            batchContext.config.triggerSource ?? 'BatchJob', // TriggerSource__c
            JSON.serialize(batchMetadata), // TriggerPayload__c
            null, // SourceRecordId__c
            UserInfo.getUserId(), // User__c
            null // ServiceUser__c
        );

        return parentExecutionId;
    }

    /**
     * Updates the parent execution with current progress.
     */
    private void updateParentExecutionProgress() {
        try {
            ExecutionContextService executionContextService = new ExecutionContextService();

            String statusMessage = 'Processed ' + batchContext.processedRecords + ' records in ' +
                                 batchContext.processedBatches + ' batches';

            executionContextService.updateStatus(
                batchContext.parentExecutionId,
                'Processing',
                AIAgentConstants.STATUS_PROCESSING,
                null,
                statusMessage
            );

        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[BatchAgentProcessor] Failed to update parent execution progress: ' + e.getMessage());
        }
    }

    /**
     * Finalizes the parent execution when batch job completes.
     *
     * @param bc Database.BatchableContext
     */
    private void finalizeParentExecution(Database.BatchableContext bc) {
        try {
            ExecutionContextService executionContextService = new ExecutionContextService();

            String finalStatus = batchContext.errors.isEmpty() ? 'Completed' : 'Failed';
            String statusCode = batchContext.errors.isEmpty() ? AIAgentConstants.STATUS_IDLE : AIAgentConstants.STATUS_FAILED;

            String finalMessage = 'Batch job completed. Processed ' + batchContext.processedRecords +
                                ' records in ' + batchContext.processedBatches + ' batches';

            if (!batchContext.errors.isEmpty()) {
                finalMessage += '. Errors: ' + batchContext.errors.size();
            }

            executionContextService.updateStatus(
                batchContext.parentExecutionId,
                finalStatus,
                statusCode,
                null,
                finalMessage
            );

            // Update end time
            AgentExecution__c parentExecution = new AgentExecution__c(
                Id = batchContext.parentExecutionId,
                EndTime__c = Datetime.now(),
                LastActivityTime__c = Datetime.now()
            );
            update parentExecution;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[BatchAgentProcessor] Failed to finalize parent execution: ' + e.getMessage());
        }
    }

    /**
     * Sends batch completion notification if configured.
     */
    private void sendBatchCompletionNotification() {
        // Implementation would depend on notification requirements
        // Could send email, create tasks, post to Chatter, etc.
        System.debug(LoggingLevel.INFO, '[BatchAgentProcessor] Batch job ' + batchContext.config.jobName + ' completed');
    }

    /**
     * Validates batch configuration before processing.
     *
     * @param config Batch job configuration to validate
     */
    private void validateBatchConfig(BatchJobConfig config) {
        if (config == null) {
            throw new BatchProcessingException('Batch configuration is required');
        }

        if (String.isBlank(config.jobName)) {
            throw new BatchProcessingException('Batch job name is required');
        }

        if (config.agentDefinitionId == null) {
            throw new BatchProcessingException('Agent definition ID is required');
        }

        if (String.isBlank(config.soqlQuery)) {
            throw new BatchProcessingException('SOQL query is required');
        }

        if (config.batchSize == null || config.batchSize <= 0) {
            config.batchSize = DEFAULT_BATCH_SIZE;
        } else if (config.batchSize > MAX_BATCH_SIZE) {
            config.batchSize = MAX_BATCH_SIZE;
        }

        if (String.isBlank(config.processingMode)) {
            config.processingMode = 'Individual';
        }
    }

    /**
     * Utility methods for data extraction and processing.
     */

    private Map<String, Object> getRecordData(SObject record) {
        Map<String, Object> recordData = new Map<String, Object>();
        Map<String, Object> populatedFields = record.getPopulatedFieldsAsMap();

        for (String fieldName : populatedFields.keySet()) {
            recordData.put(fieldName, populatedFields.get(fieldName));
        }

        return recordData;
    }

    private List<Id> getRecordIds(List<SObject> records) {
        List<Id> recordIds = new List<Id>();
        for (SObject record : records) {
            recordIds.add(record.Id);
        }
        return recordIds;
    }

    private List<Map<String, Object>> getRecordsData(List<SObject> records) {
        List<Map<String, Object>> recordsData = new List<Map<String, Object>>();
        for (SObject record : records) {
            recordsData.add(getRecordData(record));
        }
        return recordsData;
    }

    private Map<String, Object> generateBatchSummary(List<SObject> records) {
        Map<String, Object> summary = new Map<String, Object>();
        summary.put('recordCount', records.size());
        summary.put('recordType', records.isEmpty() ? 'Unknown' : String.valueOf(records[0].getSObjectType()));
        summary.put('batchNumber', batchContext.processedBatches);
        summary.put('processingTime', Datetime.now());

        // Add more summary logic based on record type and business requirements

        return summary;
    }

    private String generateTurnIdentifier() {
        return 'batch_turn_' + Datetime.now().getTime() + '_' + Math.round(Math.random() * 1000);
    }

    /**
     * Static utility methods for starting batch jobs.
     */

    /**
     * Starts a batch job with the specified configuration.
     *
     * @param config Batch job configuration
     * @return Id of the started batch job
     */
    public static Id startBatchJob(BatchJobConfig config) {
        BatchAgentProcessor processor = new BatchAgentProcessor(config);
        return Database.executeBatch(processor, config.batchSize);
    }

    /**
     * Creates a simple batch job configuration for common use cases.
     *
     * @param jobName Name of the batch job
     * @param agentDeveloperName Developer name of the agent to use
     * @param soqlQuery SOQL query to select records
     * @param processingMode Processing mode (Individual, Grouped, Summary)
     * @return BatchJobConfig configured batch job
     */
    public static BatchJobConfig createSimpleBatchConfig(String jobName, String agentDeveloperName, String soqlQuery, String processingMode) {
        // Look up agent definition
        AIAgentDefinition__c agent = [
            SELECT Id FROM AIAgentDefinition__c
            WHERE DeveloperName__c = :agentDeveloperName
            AND IsActive__c = true
            LIMIT 1
        ];

        BatchJobConfig config = new BatchJobConfig();
        config.jobName = jobName;
        config.agentDefinitionId = agent.Id;
        config.soqlQuery = soqlQuery;
        config.processingMode = processingMode;
        config.batchSize = DEFAULT_BATCH_SIZE;
        config.triggerSource = 'BatchJob';
        config.createChildExecutions = true;

        return config;
    }
}
