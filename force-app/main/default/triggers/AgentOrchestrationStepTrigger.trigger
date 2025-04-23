/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


trigger AgentOrchestrationStepTrigger on AgentOrchestrationStep__e (after insert) {

    List<Queueable> jobsToEnqueue = new List<Queueable>();

    for (AgentOrchestrationStep__e event : Trigger.new) {
        System.debug(LoggingLevel.INFO, '[AgentOrchestrationStepTrigger] Processing Event for Session: ' + event.ChatSessionId__c + ', Turn: ' + event.TurnIdentifier__c + ', NextStep: ' + event.NextStepType__c);

        try {
            // --- Determine which Queueable to enqueue based on the event type ---
            switch on event.NextStepType__c {
                when 'PrepareLLMCallWithResults' {
                    // --- Ensure required fields are present ---
                    // (Add more robust validation if needed based on your constructor requirements)
                    if (String.isBlank(event.ChatSessionId__c) || String.isBlank(event.UserId__c) || String.isBlank(event.AgentDefinitionId__c) ||
                            String.isBlank(event.TurnIdentifier__c) || event.CurrentTurnCount__c == null)
                    {
                        System.debug(LoggingLevel.ERROR, '[AgentOrchestrationStepTrigger] Skipping event due to missing required fields for PrepareLLMCallWithResults: ' + JSON.serialize(event));
                        continue; // Skip this event
                    }

                    // Instantiate the PrepareLLMCallQueueable using data from the event
                    PrepareLLMCallQueueable nextPrepJob = new PrepareLLMCallQueueable(
                            (Id)event.ChatSessionId__c,
                            (Id)event.UserId__c,
                            (Id)event.AgentDefinitionId__c,
                            event.TurnIdentifier__c,
                            Integer.valueOf(event.CurrentTurnCount__c) // <<< Pass Turn Count
                            // Ensure constructor matches! Pass LLMConfigId if PrepareLLMCall needs it here? No, it gets it from AgentDef.
                    );
                    jobsToEnqueue.add(nextPrepJob);
                    System.debug(LoggingLevel.INFO, '[AgentOrchestrationStepTrigger] Prepared PrepareLLMCallQueueable job.');

                }
                // case 'AnotherStepType': // Example if decoupling more transitions later
                //     // Instantiate a different Queueable
                //     break;
                when else {
                    System.debug(LoggingLevel.WARN, '[AgentOrchestrationStepTrigger] Unknown NextStepType__c: ' + event.NextStepType__c + '. Skipping event.');
                }
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '[AgentOrchestrationStepTrigger] Error processing event: ' + e.getMessage() + '\nStackTrace: ' + e.getStackTraceString() + '\nEvent Data: ' + JSON.serialize(event));
            // Consider adding more robust error handling here (e.g., custom object log, Platform Status Alert)
        }
    }

    // Enqueue all prepared jobs outside the loop
    if (!jobsToEnqueue.isEmpty()) {
        List<Id> jobIds = new List<Id>();
        System.debug(LoggingLevel.INFO, '[AgentOrchestrationStepTrigger] Enqueueing ' + jobsToEnqueue.size() + ' jobs.');
        for (Queueable job : jobsToEnqueue) {
            try {
                Id jobId = System.enqueueJob(job);
                jobIds.add(jobId);
            } catch (Exception enqueueEx) {
                System.debug(LoggingLevel.ERROR, '[AgentOrchestrationStepTrigger] Failed to enqueue job of type ' + String.valueOf(job) + '. Error: ' + enqueueEx.getMessage());
                // Log or handle failure
            }
        }
        System.debug(LoggingLevel.INFO, '[AgentOrchestrationStepTrigger] Enqueued Job IDs: ' + String.join(jobIds, ', '));
    }
}