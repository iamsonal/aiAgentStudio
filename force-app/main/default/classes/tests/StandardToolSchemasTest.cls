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

@IsTest
private class StandardToolSchemasTest {
    @IsTest
    static void recordFieldsCarryWhatSalesforceSaysAboutTheirValues() {
        Map<String, Object> fields = recordData('{"objectApiName":"Case","fields":["Subject","SuppliedEmail","AccountId"]}');

        Map<String, Object> subject = (Map<String, Object>) fields.get('Subject');
        System.assertEquals(255, subject.get('maxLength'), 'A text field carries its length.');

        Map<String, Object> email = (Map<String, Object>) fields.get('SuppliedEmail');
        System.assertEquals('email', email.get('format'), 'An email field carries the email format.');
        System.assertEquals(Case.SuppliedEmail.getDescribe().getLength(), email.get('maxLength'));

        Map<String, Object> account = (Map<String, Object>) fields.get('AccountId');
        System.assertEquals('salesforce-id', account.get('format'));
        System.assert(((String) account.get('description')).endsWith('The Id of an Account record.'), (String) account.get('description'));
        System.assert(!account.containsKey('maxLength'), 'An Id has no length to state.');
    }

    @IsTest
    static void picklistsListTheirActiveValues() {
        Map<String, Object> priority = (Map<String, Object>) recordData('{"objectApiName":"Case","fields":["Priority"]}').get('Priority');
        List<String> active = new List<String>();
        for (Schema.PicklistEntry entry : Case.Priority.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                active.add(entry.getValue());
            }
        }
        System.assertEquals(JSON.serialize(active), JSON.serialize(priority.get('enum')));
    }

    @IsTest
    static void aFixedValueIsNeverAnInput() {
        Map<String, Object> fields = recordData('{"objectApiName":"Case","fields":["Subject","Origin"],"defaultFieldValues":{"Origin":"Web"}}');
        System.assertEquals(new Set<String>{ 'Subject' }, fields.keySet());
    }

    private static Map<String, Object> recordData(String configuration) {
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(StandardToolSchemas.recordInputs(configuration, true));
        Map<String, Object> recordData = (Map<String, Object>) ((Map<String, Object>) schema.get('properties')).get('recordData');
        return (Map<String, Object>) recordData.get('properties');
    }

    @IsTest
    static void createRecordAsksForTheRecordTypeRightAfterTheObject() {
        List<String> names = new List<String>();
        for (AgentKernelModels.ToolSetting setting : StandardToolSchemas.recordSettings(true)) {
            names.add(setting.name);
        }
        System.assertEquals(new List<String>{ 'objectApiName', StandardToolSupport.RECORD_TYPE_KEY, 'fields', 'defaultFieldValues' }, names);
    }
}
