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
private class ToolInputOverridesTest {
    private static final String BUILT =
        '{"type":"object","properties":{' +
        '"recordData":{"type":"object","properties":{' +
        '"Subject":{"type":"string","maxLength":255,"description":"Subject of the Case."},' +
        '"Amount":{"type":"number"},' +
        '"Priority":{"type":"string","enum":["Low","Medium","High"]},' +
        '"Status":{"type":"string","enum":["New","Working"]}' +
        '},"required":["Status"],"additionalProperties":false},' +
        '"tags":{"type":"array","items":{"type":"string","enum":["a","b"]}}' +
        '},"required":["recordData"],"additionalProperties":false}';

    @IsTest
    static void editsThatNarrowAreAccepted() {
        System.assertEquals(
            new List<String>(),
            ToolInputOverrides.problems(
                BUILT,
                edits(
                    '"recordData.Subject":{"description":"One line naming the product."},' +
                        '"recordData.Priority":{"required":true,"allowedValues":["High","Medium"]},' +
                        '"recordData.Status":{"required":true},' +
                        '"tags":{"allowedValues":["a"]}'
                )
            )
        );
    }

    @IsTest
    static void editsThatWidenAreRefusedByPath() {
        assertProblem('"recordData.Origin":{"description":"x"}', 'The edit for recordData.Origin names an input this tool does not have');
        assertProblem('"recordData.Status":{"required":false}', 'recordData.Status is required by the tool');
        assertProblem('"recordData.Priority":{"allowedValues":["High","Urgent"]}', 'recordData.Priority does not offer the value Urgent');
        assertProblem('"recordData.Amount":{"allowedValues":["x"]}', 'recordData.Amount is not text, so its values cannot be limited');
        assertProblem('"recordData.Subject":{"allowedValues":["a","a"]}', 'recordData.Subject lists the value a more than once');
        assertProblem('"recordData.Subject":{"maxLength":300}', 'recordData.Subject allows at most 255 characters');
        assertProblem('"recordData.Subject":{"maxLength":0}', 'maxLength for recordData.Subject must be a whole number of at least 1');
        assertProblem('"recordData.Amount":{"maxLength":10}', 'recordData.Amount is not text, so it has no length limit');
        assertProblem('"recordData.Priority":{"allowedValues":[]}', 'allowedValues for recordData.Priority must list at least one value');
        assertProblem('"recordData.Subject":{"label":"x"}', 'has an unknown setting, label');
        assertProblem('"recordData.Subject":{"description":" "}', 'The description for recordData.Subject must be text');
        System.assert(ToolInputOverrides.problems(BUILT, '{"inputOverrides":["x"]}')[0].contains('must be an object whose keys are input paths'));
    }

    @IsTest
    static void editsApplyOnTopOfTheBuiltSchema() {
        ToolInputOverrides.Applied applied = ToolInputOverrides.apply(
            BUILT,
            edits(
                '"recordData.Subject":{"description":"One line naming the product."},' +
                    '"recordData.Priority":{"required":true,"allowedValues":["High","Medium"]},' +
                    '"tags":{"allowedValues":["b"]}'
            )
        );
        System.assertEquals(null, applied.problem);
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(applied.schema);
        System.assertEquals('One line naming the product.', ToolSchemaRows.nodeAt(schema, 'recordData.Subject').get('description'));
        System.assertEquals(
            JSON.serialize(new List<String>{ 'Medium', 'High' }),
            JSON.serialize(ToolSchemaRows.nodeAt(schema, 'recordData.Priority').get('enum')),
            'Kept values follow the tool\'s order.'
        );
        System.assert(ToolSchemaRows.requiredNames(ToolSchemaRows.parentOf(schema, 'recordData.Priority')).contains('Priority'));
        System.assertEquals(
            JSON.serialize(new List<String>{ 'b' }),
            JSON.serialize(ToolSchemaRows.valuesOf(ToolSchemaRows.nodeAt(schema, 'tags')).get('enum'))
        );
    }

    @IsTest
    static void freeTextCanBeLimitedToValuesAndAShorterLength() {
        String body = '"recordData.Subject":{"allowedValues":["released","hold"],"maxLength":40}';
        System.assertEquals(new List<String>(), ToolInputOverrides.problems(BUILT, edits(body)));

        Map<String, Object> subject = (Map<String, Object>) ToolSchemaRows.nodeAt(
            (Map<String, Object>) JSON.deserializeUntyped(ToolInputOverrides.apply(BUILT, edits(body)).schema),
            'recordData.Subject'
        );
        System.assertEquals(new List<Object>{ 'released', 'hold' }, subject.get('enum'));
        System.assertEquals(40, subject.get('maxLength'));
    }

    @IsTest
    static void valuesNoLongerOfferedAreDroppedOnARun() {
        ToolInputOverrides.Applied applied = ToolInputOverrides.apply(BUILT, edits('"recordData.Priority":{"allowedValues":["High","Urgent"]}'));
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(applied.schema);
        System.assertEquals(JSON.serialize(new List<String>{ 'High' }), JSON.serialize(ToolSchemaRows.nodeAt(schema, 'recordData.Priority').get('enum')));
    }

    @IsTest
    static void anOptionalInputWithNoValuesLeftIsLeftOut() {
        ToolInputOverrides.Applied applied = ToolInputOverrides.apply(BUILT, edits('"recordData.Priority":{"allowedValues":["Urgent"]}'));
        System.assertEquals(null, applied.problem);
        System.assertEquals(null, ToolSchemaRows.nodeAt((Map<String, Object>) JSON.deserializeUntyped(applied.schema), 'recordData.Priority'));
    }

    @IsTest
    static void aRequiredInputWithNoValuesLeftMakesTheSchemaUnavailable() {
        ToolInputOverrides.Applied applied = ToolInputOverrides.apply(BUILT, edits('"recordData.Status":{"allowedValues":["Closed"]}'));
        System.assertEquals(null, applied.schema);
        System.assert(applied.problem.startsWith('recordData.Status is required, but none of the values'), applied.problem);
    }

    @IsTest
    static void anEditForAnInputNoLongerBuiltIsSkippedOnARun() {
        ToolInputOverrides.Applied applied = ToolInputOverrides.apply(BUILT, edits('"recordData.Origin":{"description":"Gone."}'));
        System.assertEquals(null, applied.problem);
        System.assertEquals(null, ToolSchemaRows.nodeAt((Map<String, Object>) JSON.deserializeUntyped(applied.schema), 'recordData.Origin'));
    }

    private static String edits(String body) {
        return '{"objectApiName":"Case","inputOverrides":{' + body + '}}';
    }

    private static void assertProblem(String body, String expected) {
        List<String> problems = ToolInputOverrides.problems(BUILT, edits(body));
        System.assertEquals(1, problems.size(), String.valueOf(problems));
        System.assert(problems[0].contains(expected), problems[0]);
    }
}
