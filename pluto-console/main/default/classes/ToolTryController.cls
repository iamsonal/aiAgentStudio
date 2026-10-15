/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * Try tool: a dry run of one saved Agent Tool, for an admin checking its
 * inputs and settings. The tool runs once, and everything it did is undone:
 * its record changes are rolled back, and the request always ends in an error
 * that carries the result, so the platform also drops queued emails and jobs.
 *
 * A dry run is not an agent run. It checks the tool's setup, so it runs as
 * the admin trying it, even for an agent with an Agent Execution Identity.
 * It skips approvals and the authorization policy, and records nothing;
 * nothing it does is kept, so there is nothing to approve or recover. Only tools whose
 * type changes nothing outside Salesforce may be tried: a callout cannot be
 * undone, and the savepoint set before the call makes the platform refuse one.
 */
public with sharing class ToolTryController {
    /** Starts the error message that carries a dry run's result; anything else is a plain error. */
    public static final String RESULT_MARKER = 'PLUTO_DRY_RUN:';
    private static final Integer MAX_OUTPUT_CHARACTERS = 20000;

    public class TryState {
        @AuraEnabled
        public String toolName { get; set; }
        @AuraEnabled
        public Boolean canTry { get; set; }
        /** Why the tool cannot be tried, or null. */
        @AuraEnabled
        public String reason { get; set; }
        /** The editor builds its form from this. */
        @AuraEnabled
        public String inputSchema { get; set; }
        /** Calls of this tool can wait for approval in a real run. */
        @AuraEnabled
        public Boolean requiresApproval { get; set; }
        /** The tool acts on the record the agent starts from, so a dry run needs one. */
        @AuraEnabled
        public Boolean needsRecord { get; set; }
        /** Why the tool needs that record, in the admin's words; null when it does not. */
        @AuraEnabled
        public String recordHelp { get; set; }
    }

    public class TryResult {
        @AuraEnabled
        public Boolean success { get; set; }
        /** The input did not match the Input Schema, so the tool was not called. */
        @AuraEnabled
        public String inputProblem { get; set; }
        @AuraEnabled
        public String output { get; set; }
        @AuraEnabled
        public String errorCode { get; set; }
        @AuraEnabled
        public String errorMessage { get; set; }
        /** Retryable, Outcome Unknown, or Waiting, when the tool answered that way. */
        @AuraEnabled
        public String outcome { get; set; }
        @AuraEnabled
        public Long durationMs { get; set; }
        @AuraEnabled
        public Integer undoneRecordChanges { get; set; }
        /** Effects the dry run could not undo, for a tool type that wrongly claims none. */
        @AuraEnabled
        public List<String> notUndone { get; set; }
        /** Who the tool ran as. */
        @AuraEnabled
        public String ranAs { get; set; }
    }

    // Not cacheable: the tool may have just been saved.
    @AuraEnabled
    public static TryState getTryState(Id toolId) {
        assertMayTry();
        AgentTool__c tool = loadTool(toolId);
        TryState state = new TryState();
        state.toolName = tool.DeveloperName__c;
        state.requiresApproval = AgentApprovalService.mode(tool) != AgentKernelModels.APPROVAL_NOT_REQUIRED;
        state.reason = whyNot(tool);
        state.canTry = state.reason == null;
        // What the model would be sent now: built with the admin's edits, or hand-written.
        state.inputSchema = ToolSchemaService.effectiveSchema(tool).schema;
        state.recordHelp = recordHelp(tool);
        state.needsRecord = state.recordHelp != null;
        return state;
    }

    /**
     * Runs the tool once as you, and undoes everything.
     * Always throws: the message is RESULT_MARKER followed by the TryResult as
     * JSON, or a plain error when the tool cannot be tried.
     */
    @AuraEnabled
    public static void tryTool(Id toolId, String input, Id recordId) {
        assertMayTry();
        AgentTool__c tool = loadTool(toolId);
        String refusal = whyNot(tool);
        if (refusal != null) {
            throw handled(refusal);
        }
        TryResult result = new TryResult();
        result.notUndone = new List<String>();
        result.ranAs = UserInfo.getName();
        String toolInput = String.isBlank(input) ? '{}' : input;
        try {
            if (!(JSON.deserializeUntyped(toolInput) instanceof Map<String, Object>)) {
                throw new ToolJsonSchemaValidator.ValidationException('Tool input must be a JSON object.');
            }
            ToolSchemaService.Resolution schema = ToolSchemaService.effectiveSchema(tool);
            if (schema.problem != null) {
                throw new ToolJsonSchemaValidator.ValidationException(schema.problem);
            }
            ToolJsonSchemaValidator.validateInstance(toolInput, schema.schema, 'Tool input');
        } catch (Exception invalid) {
            result.success = false;
            result.inputProblem = invalid instanceof JSONException ? 'Tool input is not valid JSON.' : invalid.getMessage();
            throw carrying(result);
        }

        // A savepoint makes the platform refuse callouts, so the tool cannot reach outside Salesforce.
        Savepoint beforeTool = Database.setSavepoint();
        Integer rowsBefore = Limits.getDmlRows();
        Integer calloutsBefore = Limits.getCallouts();
        Integer immediateEventsBefore = Limits.getPublishImmediateDML();
        Long startedAt = System.currentTimeMillis();
        try {
            ITool implementation = AgentExtensionInvoker.newTool(tool);
            readResponse(AgentExtensionInvoker.executeTool(implementation, request(tool, toolInput, recordId)), result);
        } catch (CalloutException blocked) {
            result.success = false;
            result.errorCode = blocked.getTypeName();
            result.errorMessage =
                'The tool tried a callout, which a dry run blocks. If it calls outside systems, set its tool type\'s Effects to Reads Outside Systems or Changes Outside Systems. (' +
                blocked.getMessage() +
                ')';
        } catch (Exception failure) {
            result.success = false;
            result.errorCode = failure.getTypeName();
            result.errorMessage = failure.getMessage();
        }
        result.durationMs = System.currentTimeMillis() - startedAt;
        result.undoneRecordChanges = Limits.getDmlRows() - rowsBefore;
        if (Limits.getCallouts() > calloutsBefore) {
            result.notUndone.add('The tool made a callout. Set its tool type\'s Effects to Reads Outside Systems or Changes Outside Systems.');
        }
        if (Limits.getPublishImmediateDML() > immediateEventsBefore) {
            result.notUndone.add('The tool published an immediate platform event. Set its tool type\'s Effects to Changes Outside Systems.');
        }
        Database.rollback(beforeTool);
        throw carrying(result);
    }

    private static AgentKernelModels.ToolRequest request(AgentTool__c tool, String input, Id recordId) {
        AgentKernelModels.ToolRequest request = new AgentKernelModels.ToolRequest();
        request.toolName = tool.DeveloperName__c;
        request.input = input;
        request.implementationConfiguration = tool.ImplementationConfiguration__c;
        request.operationKey = 'pluto-dry-run:' + tool.Id + ':' + System.currentTimeMillis();
        request.principal = new AgentKernelModels.ExecutionPrincipal(UserInfo.getUserId(), null, UserInfo.getUserId(), recordId, null);
        return request;
    }

    private static void readResponse(AgentKernelModels.ToolResponse response, TryResult result) {
        if (response == null) {
            result.success = false;
            result.errorMessage = 'The tool returned no response.';
            return;
        }
        result.success = response.isSuccess == true && response.outcomeUnknown != true && response.awaitingExternalInput != true;
        result.errorCode = response.errorCode;
        result.errorMessage = response.errorMessage;
        if (response.outcomeUnknown == true) {
            result.outcome = 'Outcome Unknown';
        } else if (response.awaitingExternalInput == true) {
            result.outcome = 'Waiting';
        } else if (response.retryable == true) {
            result.outcome = 'Retryable';
        }
        String output = !String.isBlank(response.output) ? response.output : (response.recordSets == null ? null : JSON.serialize(response.recordSets));
        if (output != null && output.length() > MAX_OUTPUT_CHARACTERS) {
            output = output.substring(0, MAX_OUTPUT_CHARACTERS) + '… (cut short)';
        }
        result.output = output;
    }

    /**
     * A tool needs a record to try when it acts on the run's anchor record:
     * Post to Chatter with no Post To, Update Record's anchorRecordOnly, or the
     * :anchorId run value in a Fixed Field Value or a query. Other tools say
     * nothing about it.
     */
    private static String recordHelp(AgentTool__c tool) {
        String raw = String.isBlank(tool.ImplementationConfiguration__c) ? '{}' : tool.ImplementationConfiguration__c;
        Map<String, Object> config;
        try {
            config = StandardToolSupport.configuration(raw);
        } catch (Exception noSettings) {
            return null;
        }
        Boolean usesRecord =
            (tool.ToolType__c == 'PostChatter' && String.isBlank(String.valueOf(config.get('targetId') ?? ''))) ||
            config.get(StandardToolSupport.ANCHOR_RECORD_ONLY) == true ||
            raw.toLowerCase().contains(':' + ToolRunValues.ANCHOR_ID.toLowerCase());
        return usesRecord ? 'This tool reads or changes the record the agent is working on.' : null;
    }

    private static String whyNot(AgentTool__c tool) {
        if (AgentToolTypeService.toolType(tool) == null) {
            return AgentToolTypeService.unavailableMessage(tool.ToolType__c);
        }
        if (AgentToolTypeService.hasExternalEffects(tool)) {
            return 'This tool changes things outside Salesforce, so a dry run cannot undo it. Test it in a real agent run.';
        }
        return ToolSchemaService.effectiveSchema(tool).problem;
    }

    private static void assertMayTry() {
        if (!Schema.sObjectType.AgentTool__c.isUpdateable()) {
            throw handled('You need permission to edit Agent Tools to try one. Assign the Agent Tool Authoring permission set.');
        }
    }

    private static AgentTool__c loadTool(Id toolId) {
        if (toolId == null) {
            throw handled('Save the tool before trying it.');
        }
        try {
            return [
                SELECT Id, AgentDefinition__c, DeveloperName__c, ToolType__c, ImplementationConfiguration__c, InputSchema__c, ApprovalMode__c
                FROM AgentTool__c
                WHERE Id = :toolId
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (QueryException denied) {
            throw handled('You cannot read this tool.');
        }
    }

    private static AuraHandledException carrying(TryResult result) {
        return handled(RESULT_MARKER + JSON.serialize(result));
    }

    private static AuraHandledException handled(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }
}
