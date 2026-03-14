/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * Before-save trigger handler for AIAgentDefinition__c. Enforces agent-type
 * configuration invariants and manages the persistent ToolFlowGraphWarning__c field:
 * clears it when the graph is saved/regenerated or the feature is disabled, and
 * sets it when graph-relevant configuration changes.
 */
public with sharing class AIAgentDefinitionTriggerHandler {
    /**
     * Evaluates each updated record to determine whether the Tool Flow Graph
     * warning should be set or cleared. Operates directly on Trigger.new
     * (before-update context) so no extra DML is needed.
     *
     * @param newRecords Trigger.new
     * @param oldMap     Trigger.oldMap (null for before insert)
     */
    public static void handleBeforeSave(List<AIAgentDefinition__c> newRecords, Map<Id, AIAgentDefinition__c> oldMap) {
        if (newRecords == null) {
            return;
        }

        for (AIAgentDefinition__c rec : newRecords) {
            enforceErrorRecoveryMode(rec);

            if (oldMap == null) {
                continue;
            }

            AIAgentDefinition__c old = oldMap.get(rec.Id);
            if (old == null) {
                continue;
            }

            if (String.isBlank(rec.ToolFlowGraph__c)) {
                continue;
            }

            if (rec.ToolFlowGraph__c != old.ToolFlowGraph__c) {
                rec.ToolFlowGraphWarning__c = null;
                continue;
            }

            if (old.EnableToolFlowGraph__c == true && rec.EnableToolFlowGraph__c != true) {
                rec.ToolFlowGraphWarning__c = null;
                continue;
            }

            if (rec.EnableToolFlowGraph__c != true) {
                continue;
            }

            List<String> warnings = new List<String>();

            if (rec.EnableParallelToolCalling__c != old.EnableParallelToolCalling__c) {
                warnings.add('Parallel tool calling setting was changed. ' + 'Review the flow graph for parallel step compatibility.');
            }

            if (rec.AgentType__c != old.AgentType__c) {
                warnings.add('Agent type was changed. ' + 'The flow graph may need restructuring.');
            }

            if (rec.InstructionsPrompt__c != old.InstructionsPrompt__c) {
                warnings.add('Agent instructions were updated. ' + 'Review the flow graph to ensure tool sequencing still matches the updated instructions.');
            }

            if (!warnings.isEmpty()) {
                rec.ToolFlowGraphWarning__c = String.join(warnings, '\n');
            }
        }
    }

    private static void enforceErrorRecoveryMode(AIAgentDefinition__c rec) {
        if (rec == null || !AgentExecutionService.requiresAutonomousRecovery(rec.AgentType__c)) {
            return;
        }

        if (String.isBlank(rec.ErrorRecoveryMode__c)) {
            rec.ErrorRecoveryMode__c = 'Autonomous';
            return;
        }

        if (rec.ErrorRecoveryMode__c != 'Autonomous') {
            rec.ErrorRecoveryMode__c.addError('This agent type must use Error Recovery Mode = Autonomous.');
        }
    }
}
