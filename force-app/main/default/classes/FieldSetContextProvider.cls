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

/** Reads one explicitly selected Salesforce record through an administrator-selected Field Set. */
@SuppressWarnings('PMD.ApexSOQLInjection')
global inherited sharing class FieldSetContextProvider implements IContextProvider {
    global class RecordUnavailableException extends Exception {
    }

    global AgentKernelModels.ContextResponse provide(AgentKernelModels.ContextRequest request) {
        if (request == null || request.principal == null) {
            throw new AgentKernelException.ConfigurationException('Field Set context requires an execution principal.');
        }
        AgentContextConfigurationValidator.assertFieldSet(request.objectApiName, request.fieldSetName, request.contextSubject);
        Id recordId = request.contextSubject == 'Initiating User' ? request.principal.initiatingUserId : request.principal.anchorRecordId;
        if (recordId == null) {
            throw new RecordUnavailableException('The selected context record is unavailable.');
        }
        Schema.SObjectType objectType = Schema.getGlobalDescribe().get(request.objectApiName);
        if (recordId.getSObjectType() != objectType) {
            throw new AgentKernelException.ConfigurationException('The context record type does not match the configured object.');
        }
        Schema.FieldSet fieldSet = objectType.getDescribe().fieldSets.getMap().get(request.fieldSetName);
        Set<String> selectedFields = new Set<String>{ 'Id' };
        for (Schema.FieldSetMember member : fieldSet.getFields()) {
            selectedFields.add(member.getFieldPath());
        }
        List<String> orderedFields = new List<String>(selectedFields);
        orderedFields.sort();
        List<SObject> records = Database.query(
            'SELECT ' + String.join(orderedFields, ',') + ' FROM ' + objectType.getDescribe().getName() + ' WHERE Id = :recordId LIMIT 1',
            AccessLevel.USER_MODE
        );
        if (records.isEmpty()) {
            throw new RecordUnavailableException('The selected context record is unavailable.');
        }
        AgentKernelModels.ContextResponse response = new AgentKernelModels.ContextResponse();
        response.recordSets = new Map<String, List<SObject>>{ objectType.getDescribe().getName() => records };
        return response;
    }
}
