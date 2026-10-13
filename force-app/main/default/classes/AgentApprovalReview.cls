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
 * What an approver needs to decide one Agent Approval: the call's inputs,
 * the run's record, why, and by when. It knows no tool types: every call is
 * shown as its input values. Only someone who could decide a pending
 * approval sees it. Values stay as stored, so protected values appear as
 * placeholders; Review Input reveals them and records that it did. The
 * anchor is read as the approver, so a record they cannot open stays unnamed.
 */
public without sharing class AgentApprovalReview {
    private static final Integer MAX_VALUE_CHARACTERS = 1000;

    public class Request {
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String agentName;
        @AuraEnabled
        public RecordLink anchor;
        @AuraEnabled
        public List<InputValue> inputs = new List<InputValue>();
        @AuraEnabled
        public String reason;
        @AuraEnabled
        public String rationale;
        @AuraEnabled
        public Boolean hasProtectedValues = false;
        @AuraEnabled
        public Datetime expiresAt;
        @AuraEnabled
        public String expiryAction;
        @AuraEnabled
        public String decidedBy;
        @AuraEnabled
        public Datetime closedAt;
        @AuraEnabled
        public String decisionComment;
    }

    public class RecordLink {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String objectLabel;
        /** The record's name, or null when the approver cannot open it. */
        @AuraEnabled
        public String name;
    }

    public class InputValue {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;
    }

    public static Request load(Id approvalId) {
        List<AgentApproval__c> approvals = [
            SELECT
                Id,
                OwnerId,
                ApproverType__c,
                Status__c,
                AgentRun__c,
                AgentRun__r.AnchorRecordId__c,
                AgentRun__r.AgentDefinition__r.Name,
                AgentRun__r.AgentDefinition__r.DeveloperName__c,
                AgentCommand__c,
                AgentTool__c,
                ToolName__c,
                Reason__c,
                ExpiresAt__c,
                ExpiryAction__c
            FROM AgentApproval__c
            WHERE Id = :approvalId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (approvals.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent approval was not found.');
        }
        AgentApproval__c approval = approvals[0];
        if (approval.Status__c != AgentKernelModels.APPROVAL_STATUS_PENDING) {
            return decided(approvalId);
        }
        AgentApprovalService.assertReviewer(approval);

        Request result = new Request();
        result.status = approval.Status__c;
        result.agentName = displayName(approval.AgentRun__r.AgentDefinition__r.Name, approval.AgentRun__r.AgentDefinition__r.DeveloperName__c);
        result.reason = approval.Reason__c;
        result.expiresAt = approval.ExpiresAt__c;
        result.expiryAction = approval.ExpiryAction__c;
        result.anchor = link(approval.AgentRun__r.AnchorRecordId__c);

        List<AgentCommand__c> commands = [SELECT Input__c, Rationale__c FROM AgentCommand__c WHERE Id = :approval.AgentCommand__c WITH SYSTEM_MODE LIMIT 1];
        String input = commands.isEmpty() ? null : commands[0].Input__c;
        result.rationale = commands.isEmpty() ? null : commands[0].Rationale__c;
        result.hasProtectedValues = String.isNotBlank(input) && input.contains('{{');

        List<AgentTool__c> tools = [SELECT Name, DeveloperName__c FROM AgentTool__c WHERE Id = :approval.AgentTool__c WITH SYSTEM_MODE LIMIT 1];
        result.title = tools.isEmpty() ? displayName(null, approval.ToolName__c) : displayName(tools[0].Name, tools[0].DeveloperName__c);
        result.inputs = inputValues(input);
        return result;
    }

    /** Who decided and when, from the record as the viewer may read it. */
    private static Request decided(Id approvalId) {
        List<AgentApproval__c> visible = [
            SELECT Status__c, ToolName__c, Reason__c, DecidedBy__r.Name, ClosedAt__c, DecisionComment__c
            FROM AgentApproval__c
            WHERE Id = :approvalId
            WITH USER_MODE
            LIMIT 1
        ];
        if (visible.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent approval was not found.');
        }
        Request result = new Request();
        result.status = visible[0].Status__c;
        result.title = displayName(null, visible[0].ToolName__c);
        result.reason = visible[0].Reason__c;
        result.decidedBy = visible[0].DecidedBy__r?.Name;
        result.closedAt = visible[0].ClosedAt__c;
        result.decisionComment = visible[0].DecisionComment__c;
        return result;
    }

    /** A record the approver can open is named; any other keeps only its object. */
    private static RecordLink link(String recordIdText) {
        Id recordId;
        try {
            recordId = String.isBlank(recordIdText) ? null : (Id) recordIdText.trim();
        } catch (Exception invalidId) {
            return null;
        }
        if (recordId == null) {
            return null;
        }
        RecordLink result = new RecordLink();
        result.recordId = recordId;
        Schema.DescribeSObjectResult objectDescribe = recordId.getSObjectType().getDescribe();
        result.objectLabel = objectDescribe.getLabel();
        String nameField = nameField(objectDescribe);
        if (nameField == null || !objectDescribe.isAccessible()) {
            return result;
        }
        try {
            List<SObject> rows = Database.queryWithBinds(
                'SELECT ' + nameField + ' FROM ' + objectDescribe.getName() + ' WHERE Id = :recordId LIMIT 1',
                new Map<String, Object>{ 'recordId' => recordId },
                AccessLevel.USER_MODE
            );
            result.name = rows.isEmpty() ? null : text(rows[0].get(nameField));
        } catch (Exception hidden) {
            result.name = null;
        }
        return result;
    }

    private static String nameField(Schema.DescribeSObjectResult objectDescribe) {
        for (Schema.SObjectField field : objectDescribe.fields.getMap().values()) {
            Schema.DescribeFieldResult describe = field.getDescribe();
            if (describe.isNameField()) {
                return describe.isAccessible() ? describe.getName() : null;
            }
        }
        return null;
    }

    /**
     * Flattens the call's input into rows. A nested object's values are shown
     * under their own names, so {"recordData":{"Priority":"High"}} reads
     * Priority: High; lists and deeper values are shown as JSON.
     */
    private static List<InputValue> inputValues(String input) {
        List<InputValue> result = new List<InputValue>();
        Object parsed;
        try {
            parsed = String.isBlank(input) ? null : JSON.deserializeUntyped(input);
        } catch (Exception notJson) {
            parsed = null;
        }
        if (!(parsed instanceof Map<String, Object>)) {
            if (String.isNotBlank(input)) {
                result.add(inputValue('Input', input));
            }
            return result;
        }
        Map<String, Object> values = (Map<String, Object>) parsed;
        for (String name : values.keySet()) {
            Object value = values.get(name);
            if (value instanceof Map<String, Object>) {
                Map<String, Object> nested = (Map<String, Object>) value;
                for (String nestedName : nested.keySet()) {
                    result.add(inputValue(nestedName, nested.get(nestedName)));
                }
            } else {
                result.add(inputValue(name, value));
            }
        }
        return result;
    }

    private static InputValue inputValue(String label, Object value) {
        InputValue result = new InputValue();
        result.label = label;
        result.value = text(value);
        return result;
    }

    /** An admin's label as written; a record named only by its API name reads as words, so update_case_priority is Update case priority. */
    private static String displayName(String name, String apiName) {
        if (String.isNotBlank(name) && name != apiName) {
            return name;
        }
        String source = String.isNotBlank(apiName) ? apiName : name;
        return String.isBlank(source) ? null : source.replace('_', ' ').capitalize();
    }

    private static String text(Object value) {
        if (value == null) {
            return null;
        }
        String result = value instanceof String
            ? (String) value
            : value instanceof Map<String, Object> || value instanceof List<Object> ? JSON.serialize(value) : String.valueOf(value);
        return result.abbreviate(MAX_VALUE_CHARACTERS);
    }
}
