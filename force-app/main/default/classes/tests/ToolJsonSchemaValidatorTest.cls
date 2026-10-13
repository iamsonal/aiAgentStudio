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

@IsTest(SeeAllData=false)
private class ToolJsonSchemaValidatorTest {
    private static final String SUPPORTED_SCHEMA =
        '{"type":"object","properties":{' +
        '"name":{"type":"string","minLength":2,"maxLength":20},' +
        '"count":{"type":"integer","minimum":1,"maximum":10},' +
        '"active":{"type":"boolean"},' +
        '"tags":{"type":"array","items":{"type":"string","enum":["a","b"]}}' +
        '},"required":["name","count"],"additionalProperties":false}';

    @IsTest
    static void supportedSchemaAcceptsMatchingValue() {
        ToolJsonSchemaValidator.validateSchema(SUPPORTED_SCHEMA, 'Test schema');
        ToolJsonSchemaValidator.validateInstance('{"name":"valid","count":2,"active":true,"tags":["a","b"]}', SUPPORTED_SCHEMA, 'Test value');
    }

    @IsTest
    static void valueValidationRejectsMissingAndAdditionalProperties() {
        assertInvalid('{"name":"valid"}');
        assertInvalid('{"name":"valid","count":2,"extra":true}');
        assertInvalid('{"name":"valid","count":2.5}');
        assertInvalid('{"name":"x","count":2}');
    }

    @IsTest
    static void configurationRejectsUnsupportedKeywords() {
        Boolean rejected = false;
        try {
            ToolJsonSchemaValidator.validateSchema('{"type":"string","pattern":"[a-z]+"}', 'Unsupported schema');
        } catch (AgentKernelException.ConfigurationException expected) {
            rejected = true;
        }
        System.assert(rejected, 'Unsupported JSON Schema keywords must be rejected.');
    }

    @IsTest
    static void acceptsOnlySupportedStringFormats() {
        ToolJsonSchemaValidator.validateSchema('{"type":"string","format":"date-time"}', 'Formatted schema');
        Boolean rejected = false;
        try {
            ToolJsonSchemaValidator.validateSchema('{"type":"string","format":"hostname"}', 'Unsupported format');
        } catch (AgentKernelException.ConfigurationException expected) {
            rejected = true;
        }
        System.assert(rejected, 'Unsupported string formats must be rejected.');
    }

    @IsTest
    static void formatsAreCheckedOnValues() {
        Map<String, List<String>> valid = new Map<String, List<String>>{
            'date' => new List<String>{ '2028-02-29', '2026-10-01' },
            'date-time' => new List<String>{ '2026-10-01T15:30:00Z', '2026-10-01T15:30:00.123+05:30', '2026-10-01t15:30:00-08:00' },
            'email' => new List<String>{ 'jane@example.com', '{{EMAIL_3_9f2c61ab}}' },
            'uri' => new List<String>{ 'https://example.com/path?q=1', 'mailto:jane@example.com' },
            'salesforce-id' => new List<String>{ '001000000000000', '001000000000000AAA' }
        };
        Map<String, List<String>> invalid = new Map<String, List<String>>{
            'date' => new List<String>{ '2026-02-29', '2026-13-01', 'tomorrow-ish', '2026-10-01T00:00:00Z' },
            'date-time' => new List<String>{ '2026-10-01T15:30:00', '2026-10-01 15:30:00Z', '2026-10-01T24:00:00Z', '2026-02-30T10:00:00Z' },
            'email' => new List<String>{ 'jane', 'jane@example', 'jane doe@example.com', 'Reach {{EMAIL_3_9f2c61ab}} today' },
            'uri' => new List<String>{ 'example.com/path', 'https://exa mple.com' },
            'salesforce-id' => new List<String>{ 'not-an-id', '001000000000000ZZZ', '0010000000000' }
        };
        for (String format : valid.keySet()) {
            String schema = '{"type":"string","format":"' + format + '"}';
            for (String value : valid.get(format)) {
                ToolJsonSchemaValidator.validateInstance(JSON.serialize(value), schema, 'Value');
            }
            for (String value : invalid.get(format)) {
                Boolean rejected = false;
                try {
                    ToolJsonSchemaValidator.validateInstance(JSON.serialize(value), schema, 'Value');
                } catch (ToolJsonSchemaValidator.ValidationException expected) {
                    rejected = expected.getMessage().startsWith('Value must be ');
                }
                System.assert(rejected, format + ' must reject ' + value);
            }
        }
    }

    @IsTest
    static void blankSchemasRemainCompatible() {
        ToolJsonSchemaValidator.validateSchema(null, 'Blank schema');
        ToolJsonSchemaValidator.validateInstance('not-json', '', 'Blank value');
    }

    @IsTest
    static void descriptionAndTitleAnnotationsAreAcceptedButBounded() {
        ToolJsonSchemaValidator.validateSchema(
            '{"type":"object","description":"Tool input.","title":"Input","properties":{"name":{"type":"string","description":"A name.","title":"Name"}},"required":["name"],"additionalProperties":false}',
            'Annotated schema'
        );
        Boolean rejected = false;
        try {
            ToolJsonSchemaValidator.validateSchema('{"type":"string","description":42}', 'Non-string description');
        } catch (AgentKernelException.ConfigurationException expected) {
            rejected = true;
        }
        System.assert(rejected, 'Non-string descriptions must be rejected.');
        String oversized = '{"type":"string","description":"';
        for (Integer index = 0; index < 2001; index++) {
            oversized += 'x';
        }
        oversized += '"}';
        rejected = false;
        try {
            ToolJsonSchemaValidator.validateSchema(oversized, 'Oversized description');
        } catch (AgentKernelException.ConfigurationException expected) {
            rejected = true;
        }
        System.assert(rejected, 'Oversized descriptions must be rejected.');
    }

    @IsTest
    static void errorsNameTheBrokenRuleWithoutTheValue() {
        System.assertEquals('Tool input.name must be at most 20 characters.', invalidMessage('{"name":"secret-value-that-is-too-long","count":2}'));
        System.assertEquals('Tool input.name must be at least 2 characters.', invalidMessage('{"name":"x","count":2}'));
        System.assertEquals('Tool input.count must be from 1 to 10.', invalidMessage('{"name":"valid","count":11}'));
        System.assertEquals('Tool input.count must be a whole number.', invalidMessage('{"name":"valid","count":2.5}'));
        System.assertEquals('Tool input.count must be a number.', invalidMessage('{"name":"valid","count":"two"}'));
        System.assertEquals('Tool input.name must be text.', invalidMessage('{"name":5,"count":2}'));
        System.assertEquals('Tool input.active must be true or false.', invalidMessage('{"name":"valid","count":2,"active":"yes"}'));
        System.assertEquals('Tool input.tags must be a list.', invalidMessage('{"name":"valid","count":2,"tags":"a"}'));
        System.assertEquals('Tool input.tags[0] must be one of a or b.', invalidMessage('{"name":"valid","count":2,"tags":["secret"]}'));
        System.assert(!invalidMessage('{"name":"secret-value-that-is-too-long","count":2}').contains('secret'), 'The value sent is never repeated.');
    }

    @IsTest
    static void longAllowedValueListsAreNotRepeated() {
        List<String> values = new List<String>();
        for (Integer index = 0; index < 11; index++) {
            values.add('"v' + index + '"');
        }
        String schema = '{"type":"string","enum":[' + String.join(values, ',') + ']}';
        Boolean rejected = false;
        try {
            ToolJsonSchemaValidator.validateInstance('"other"', schema, 'Tool input');
        } catch (ToolJsonSchemaValidator.ValidationException expected) {
            rejected = true;
            System.assertEquals('Tool input must be one of the allowed values.', expected.getMessage());
        }
        System.assert(rejected, 'A value outside the list is refused.');
    }

    private static String invalidMessage(String valueJson) {
        try {
            ToolJsonSchemaValidator.validateInstance(valueJson, SUPPORTED_SCHEMA, 'Tool input');
        } catch (ToolJsonSchemaValidator.ValidationException expected) {
            return expected.getMessage();
        }
        System.assert(false, 'Expected schema validation to reject ' + valueJson);
        return null;
    }

    private static void assertInvalid(String valueJson) {
        Boolean rejected = false;
        try {
            ToolJsonSchemaValidator.validateInstance(valueJson, SUPPORTED_SCHEMA, 'Test value');
        } catch (ToolJsonSchemaValidator.ValidationException expected) {
            rejected = true;
        }
        System.assert(rejected, 'Expected schema validation to reject ' + valueJson);
    }
}
