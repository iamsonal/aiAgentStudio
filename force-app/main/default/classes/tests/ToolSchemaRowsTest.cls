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
private class ToolSchemaRowsTest {
    @IsTest
    static void readsNestedInputsAsRowsInOrder() {
        List<ToolSchemaRows.Row> rows = ToolSchemaRows.read(
            '{"type":"object","properties":{' +
                '"recordData":{"type":"object","description":"Field values.","properties":{' +
                '"Subject":{"type":"string","maxLength":255,"description":"Subject."},' +
                '"AccountId":{"type":"string","format":"salesforce-id","description":"Account."}' +
                '},"required":["Subject"],"additionalProperties":false},' +
                '"statuses":{"type":"array","items":{"type":"string","enum":["New","Closed"]},"description":"Statuses."},' +
                '"lines":{"type":"array","items":{"type":"object","properties":{"sku":{"type":"string","description":"SKU."}},"required":["sku"],"additionalProperties":false},"description":"Lines."},' +
                '"limit":{"type":"integer","minimum":1,"maximum":50,"description":"Most rows."}' +
                '},"required":["recordData"],"additionalProperties":false}'
        );
        Map<String, ToolSchemaRows.Row> byPath = new Map<String, ToolSchemaRows.Row>();
        for (ToolSchemaRows.Row row : rows) {
            byPath.put(row.path, row);
        }
        System.assertEquals(
            new Set<String>{ 'recordData', 'recordData.Subject', 'recordData.AccountId', 'statuses', 'lines', 'lines.sku', 'limit' },
            byPath.keySet()
        );
        System.assertEquals('Group', byPath.get('recordData').typeLabel);
        System.assert(byPath.get('recordData').hasChildren);
        System.assert(byPath.get('recordData').required);

        ToolSchemaRows.Row subject = byPath.get('recordData.Subject');
        System.assertEquals(1, subject.depth);
        System.assertEquals('Text (255)', subject.typeLabel);
        System.assertEquals(255, subject.maxLength);
        System.assert(subject.required);
        System.assert(!byPath.get('recordData.AccountId').required);
        System.assertEquals('Record Id', byPath.get('recordData.AccountId').typeLabel);

        System.assertEquals('List of Picklist', byPath.get('statuses').typeLabel);
        System.assertEquals(new List<String>{ 'New', 'Closed' }, byPath.get('statuses').allowedValues);
        System.assertEquals(1, byPath.get('lines.sku').depth, 'A list of objects adds no path segment.');
        System.assertEquals('Whole number', byPath.get('limit').typeLabel);
        System.assertEquals(50, byPath.get('limit').maximum);
    }

    @IsTest
    static void aBlankSchemaHasNoRows() {
        System.assertEquals(0, ToolSchemaRows.read(null).size());
    }
}
