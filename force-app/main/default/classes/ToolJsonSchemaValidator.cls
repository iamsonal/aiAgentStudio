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
 * Bounded validator for the intentionally small JSON Schema subset supported
 * by tool contracts. Blank optional schemas impose no instance constraints.
 */
public inherited sharing class ToolJsonSchemaValidator {
    /** Every tool result is a JSON object; Core checks no other shape. */
    public static final String TOOL_RESULT_SCHEMA = '{"type":"object"}';
    private static final Integer MAX_SCHEMA_LENGTH = 32768;
    private static final Integer MAX_INSTANCE_LENGTH = 131072;
    private static final Integer MAX_SCHEMA_DEPTH = 10;
    private static final Integer MAX_INSTANCE_DEPTH = 20;
    private static final Integer MAX_PROPERTIES = 50;
    private static final Integer MAX_ARRAY_ITEMS = 1000;
    private static final Integer MAX_ENUM_VALUES = 100;
    private static final Integer MAX_DESCRIPTION_CHARACTERS = 2000;
    private static final Integer MAX_NODE_WORK = 5000;
    /** Longer allowed-value lists are not repeated in an error; the model already has them in the schema. */
    private static final Integer MAX_NAMED_ENUM_VALUES = 10;
    private static Integer remainingNodeWork;
    private static final Set<String> SUPPORTED_TYPES = new Set<String>{ 'object', 'array', 'string', 'number', 'integer', 'boolean', 'null' };
    private static final Set<String> SUPPORTED_KEYWORDS = new Set<String>{
        'type',
        'properties',
        'required',
        'additionalProperties',
        'items',
        'enum',
        'minLength',
        'maxLength',
        'minimum',
        'maximum',
        'format',
        'description',
        'title'
    };
    private static final Set<String> SUPPORTED_STRING_FORMATS = new Set<String>{ 'date', 'date-time', 'email', 'uri', 'salesforce-id' };
    private static final Pattern DATE_FORMAT = Pattern.compile('[0-9]{4}-[0-9]{2}-[0-9]{2}');
    private static final Pattern DATE_TIME_FORMAT = Pattern.compile(
        '([0-9]{4}-[0-9]{2}-[0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\\.[0-9]{1,9})?(?:[Zz]|[+-]([0-9]{2}):([0-9]{2}))'
    );
    private static final Pattern EMAIL_FORMAT = Pattern.compile('[^\\s@]+@[^\\s@]+\\.[^\\s@]+');
    private static final Pattern URI_FORMAT = Pattern.compile('[A-Za-z][A-Za-z0-9+.-]*:[^\\s]+');
    private static final Pattern SALESFORCE_ID_FORMAT = Pattern.compile('[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?');

    public class ValidationException extends Exception {
    }

    public static void validateSchema(String schemaJson, String label) {
        if (String.isBlank(schemaJson)) {
            return;
        }
        String safeLabel = String.isBlank(label) ? 'Tool schema' : label;
        if (schemaJson.length() > MAX_SCHEMA_LENGTH) {
            throw configuration(safeLabel + ' exceeds the supported size limit.');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(schemaJson);
        } catch (Exception invalidJson) {
            throw configuration(safeLabel + ' is not valid JSON.');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw configuration(safeLabel + ' must be a JSON object.');
        }
        remainingNodeWork = MAX_NODE_WORK;
        validateSchemaNode((Map<String, Object>) parsed, safeLabel, 0);
    }

    public static Boolean requiresBooleanProperty(String schemaJson, String propertyName) {
        if (String.isBlank(schemaJson) || String.isBlank(propertyName)) {
            return false;
        }
        try {
            Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(schemaJson);
            List<Object> required = (List<Object>) schema.get('required');
            Map<String, Object> properties = (Map<String, Object>) schema.get('properties');
            Map<String, Object> property = properties == null ? null : (Map<String, Object>) properties.get(propertyName);
            return required != null && required.contains(propertyName) && property != null && property.get('type') == 'boolean';
        } catch (Exception invalidSchema) {
            return false;
        }
    }

    public static void validateInstance(String valueJson, String schemaJson, String label) {
        if (String.isBlank(schemaJson)) {
            return;
        }
        String safeLabel = String.isBlank(label) ? 'Tool value' : label;
        if (valueJson == null || valueJson.length() > MAX_INSTANCE_LENGTH) {
            throw new ValidationException(safeLabel + ' exceeds the supported size limit.');
        }
        Object schemaValue;
        Object instanceValue;
        try {
            schemaValue = JSON.deserializeUntyped(schemaJson);
            instanceValue = JSON.deserializeUntyped(valueJson);
        } catch (Exception invalidJson) {
            throw new ValidationException(safeLabel + ' is not valid JSON.');
        }
        try {
            remainingNodeWork = MAX_NODE_WORK;
            validateValue(instanceValue, (Map<String, Object>) schemaValue, safeLabel, 0);
        } catch (ValidationException validationFailure) {
            throw validationFailure;
        } catch (Exception invalidShape) {
            throw new ValidationException(safeLabel + ' does not match its configured schema.');
        }
    }

    private static void validateSchemaNode(Map<String, Object> schema, String path, Integer depth) {
        consumeNodeWork(path, true);
        if (depth > MAX_SCHEMA_DEPTH) {
            throw configuration(path + ' exceeds the supported schema depth.');
        }
        for (String keyword : schema.keySet()) {
            if (!SUPPORTED_KEYWORDS.contains(keyword)) {
                throw configuration(path + ' uses unsupported keyword ' + keyword + '.');
            }
        }
        if (!(schema.get('type') instanceof String)) {
            throw configuration(path + ' requires one supported string type.');
        }
        String typeName = (String) schema.get('type');
        if (!SUPPORTED_TYPES.contains(typeName)) {
            throw configuration(path + ' has an unsupported type.');
        }
        validateAnnotations(schema, path);
        validateEnum(schema, path);

        if (typeName == 'object') {
            validateObjectSchema(schema, path, depth);
        } else if (typeName == 'array') {
            requireOnly(schema, new Set<String>{ 'type', 'items', 'enum', 'description', 'title' }, path);
            if (!(schema.get('items') instanceof Map<String, Object>)) {
                throw configuration(path + '.items must be one schema object.');
            }
            validateSchemaNode((Map<String, Object>) schema.get('items'), path + '.items', depth + 1);
        } else if (typeName == 'string') {
            requireOnly(schema, new Set<String>{ 'type', 'enum', 'minLength', 'maxLength', 'format', 'description', 'title' }, path);
            Integer minimum = optionalNonNegativeInteger(schema.get('minLength'), path + '.minLength');
            Integer maximum = optionalNonNegativeInteger(schema.get('maxLength'), path + '.maxLength');
            if (minimum != null && maximum != null && minimum > maximum) {
                throw configuration(path + ' has minLength greater than maxLength.');
            }
            if (
                schema.containsKey('format') && (!(schema.get('format') instanceof String) || !SUPPORTED_STRING_FORMATS.contains((String) schema.get('format')))
            ) {
                throw configuration(path + '.format is unsupported.');
            }
        } else if (typeName == 'number' || typeName == 'integer') {
            requireOnly(schema, new Set<String>{ 'type', 'enum', 'minimum', 'maximum', 'description', 'title' }, path);
            Decimal minimum = optionalDecimal(schema.get('minimum'), path + '.minimum');
            Decimal maximum = optionalDecimal(schema.get('maximum'), path + '.maximum');
            if (minimum != null && maximum != null && minimum > maximum) {
                throw configuration(path + ' has minimum greater than maximum.');
            }
        } else {
            requireOnly(schema, new Set<String>{ 'type', 'enum', 'description', 'title' }, path);
        }
    }

    private static void validateAnnotations(Map<String, Object> schema, String path) {
        for (String annotation : new List<String>{ 'description', 'title' }) {
            if (!schema.containsKey(annotation)) {
                continue;
            }
            Object value = schema.get(annotation);
            if (!(value instanceof String) || String.isBlank((String) value) || ((String) value).length() > MAX_DESCRIPTION_CHARACTERS) {
                throw configuration(path + '.' + annotation + ' must be nonblank text within ' + MAX_DESCRIPTION_CHARACTERS + ' characters.');
            }
        }
    }

    private static void validateObjectSchema(Map<String, Object> schema, String path, Integer depth) {
        requireOnly(schema, new Set<String>{ 'type', 'properties', 'required', 'additionalProperties', 'enum', 'description', 'title' }, path);
        Map<String, Object> properties = new Map<String, Object>();
        if (schema.containsKey('properties')) {
            if (!(schema.get('properties') instanceof Map<String, Object>)) {
                throw configuration(path + '.properties must be an object.');
            }
            properties = (Map<String, Object>) schema.get('properties');
        }
        if (properties.size() > MAX_PROPERTIES) {
            throw configuration(path + ' exceeds the supported property count.');
        }
        for (String propertyName : properties.keySet()) {
            if (!(properties.get(propertyName) instanceof Map<String, Object>)) {
                throw configuration(path + '.properties contains a non-schema value.');
            }
            validateSchemaNode((Map<String, Object>) properties.get(propertyName), path + '.' + propertyName, depth + 1);
        }
        if (schema.containsKey('required')) {
            if (!(schema.get('required') instanceof List<Object>)) {
                throw configuration(path + '.required must be an array.');
            }
            List<Object> requiredNames = (List<Object>) schema.get('required');
            if (requiredNames.size() > MAX_PROPERTIES) {
                throw configuration(path + '.required exceeds the supported count.');
            }
            Set<String> seen = new Set<String>();
            for (Object requiredName : requiredNames) {
                if (!(requiredName instanceof String) || !properties.containsKey((String) requiredName) || seen.contains((String) requiredName)) {
                    throw configuration(path + '.required contains an invalid property name.');
                }
                seen.add((String) requiredName);
            }
        }
        if (schema.containsKey('additionalProperties') && schema.get('additionalProperties') != false) {
            throw configuration(path + '.additionalProperties only supports false.');
        }
    }

    private static void validateEnum(Map<String, Object> schema, String path) {
        if (!schema.containsKey('enum')) {
            return;
        }
        if (!(schema.get('enum') instanceof List<Object>)) {
            throw configuration(path + '.enum must be an array.');
        }
        List<Object> values = (List<Object>) schema.get('enum');
        if (values.isEmpty() || values.size() > MAX_ENUM_VALUES) {
            throw configuration(path + '.enum has an unsupported value count.');
        }
        Set<String> serializedValues = new Set<String>();
        for (Object value : values) {
            if (value instanceof Map<String, Object> || value instanceof List<Object>) {
                throw configuration(path + '.enum only supports scalar or null values.');
            }
            String serialized = JSON.serialize(value);
            if (serialized.length() > 4096 || serializedValues.contains(serialized)) {
                throw configuration(path + '.enum contains an invalid or duplicate value.');
            }
            serializedValues.add(serialized);
        }
    }

    private static void validateValue(Object value, Map<String, Object> schema, String path, Integer depth) {
        consumeNodeWork(path, false);
        if (depth > MAX_INSTANCE_DEPTH) {
            throw new ValidationException(path + ' exceeds the supported value depth.');
        }
        if (schema.containsKey('enum')) {
            validateEnumValue(value, (List<Object>) schema.get('enum'), path);
        }

        String typeName = (String) schema.get('type');
        if (String.isBlank(typeName)) {
            throw new ValidationException(path + ' has no schema type.');
        }
        if (typeName == 'null') {
            require(value == null, path, 'must be null');
        } else if (typeName == 'boolean') {
            require(value instanceof Boolean, path, 'must be true or false');
        } else if (typeName == 'string') {
            require(value instanceof String, path, 'must be text');
            Integer length = ((String) value).length();
            Integer minimum = optionalNonNegativeInteger(schema.get('minLength'), path);
            Integer maximum = optionalNonNegativeInteger(schema.get('maxLength'), path);
            require(minimum == null || length >= minimum, path, 'must be at least ' + minimum + ' characters');
            require(maximum == null || length <= maximum, path, 'must be at most ' + maximum + ' characters');
            validateFormat((String) value, (String) schema.get('format'), path);
        } else if (typeName == 'number' || typeName == 'integer') {
            require(isNumber(value), path, 'must be a number');
            Decimal numericValue = Decimal.valueOf(String.valueOf(value));
            require(typeName != 'integer' || numericValue == numericValue.setScale(0), path, 'must be a whole number');
            Decimal minimum = optionalDecimal(schema.get('minimum'), path);
            Decimal maximum = optionalDecimal(schema.get('maximum'), path);
            require(minimum == null || numericValue >= minimum, path, rangeRule(minimum, maximum));
            require(maximum == null || numericValue <= maximum, path, rangeRule(minimum, maximum));
        } else if (typeName == 'array') {
            require(value instanceof List<Object>, path, 'must be a list');
            List<Object> values = (List<Object>) value;
            if (values.size() > MAX_ARRAY_ITEMS) {
                throw new ValidationException(path + ' exceeds the supported array size.');
            }
            for (Integer index = 0; index < values.size(); index++) {
                validateValue(values[index], (Map<String, Object>) schema.get('items'), path + '[' + index + ']', depth + 1);
            }
        } else if (typeName == 'object') {
            require(value instanceof Map<String, Object>, path, 'must be an object');
            validateObjectValue((Map<String, Object>) value, schema, path, depth);
        } else {
            throw new ValidationException(path + ' has an unsupported schema type.');
        }
    }

    /** Names the allowed values, which come from the schema, never the value sent: it may be sensitive. */
    private static void validateEnumValue(Object value, List<Object> allowed, String path) {
        String serialized = JSON.serialize(value);
        for (Object enumValue : allowed) {
            if (JSON.serialize(enumValue) == serialized) {
                return;
            }
        }
        if (allowed.size() > MAX_NAMED_ENUM_VALUES) {
            throw new ValidationException(path + ' must be one of the allowed values.');
        }
        List<String> names = new List<String>();
        for (Object enumValue : allowed) {
            names.add(enumValue instanceof String ? (String) enumValue : JSON.serialize(enumValue));
        }
        String last = names.remove(names.size() - 1);
        String listed = names.isEmpty() ? last : String.join(names, ', ') + (names.size() == 1 ? ' or ' : ', or ') + last;
        throw new ValidationException(path + ' must be ' + (names.isEmpty() ? '' : 'one of ') + listed + '.');
    }

    private static String rangeRule(Decimal minimum, Decimal maximum) {
        if (minimum != null && maximum != null) {
            return 'must be from ' + minimum + ' to ' + maximum;
        }
        return minimum != null ? 'must be at least ' + minimum : 'must be at most ' + maximum;
    }

    /** Property names in errors are bounded: an unexpected one is the caller's own text. */
    private static String boundedName(String name) {
        return name == null ? 'null' : name.abbreviate(80);
    }

    private static void validateObjectValue(Map<String, Object> value, Map<String, Object> schema, String path, Integer depth) {
        if (value.size() > MAX_PROPERTIES) {
            throw new ValidationException(path + ' exceeds the supported property count.');
        }
        Map<String, Object> properties = schema.containsKey('properties') ? (Map<String, Object>) schema.get('properties') : new Map<String, Object>();
        if (schema.containsKey('required')) {
            for (Object requiredName : (List<Object>) schema.get('required')) {
                if (!value.containsKey((String) requiredName)) {
                    throw new ValidationException(path + ' is missing the required property ' + boundedName((String) requiredName) + '.');
                }
            }
        }
        for (String propertyName : value.keySet()) {
            if (!properties.containsKey(propertyName)) {
                if (schema.get('additionalProperties') == false) {
                    throw new ValidationException(path + ' contains ' + boundedName(propertyName) + ', which the schema does not allow.');
                }
                validateUnconstrainedValue(value.get(propertyName), path + '.' + propertyName, depth + 1);
                continue;
            }
            validateValue(value.get(propertyName), (Map<String, Object>) properties.get(propertyName), path + '.' + propertyName, depth + 1);
        }
    }

    private static void validateUnconstrainedValue(Object value, String path, Integer depth) {
        consumeNodeWork(path, false);
        if (depth > MAX_INSTANCE_DEPTH) {
            throw new ValidationException(path + ' exceeds the supported value depth.');
        }
        if (value instanceof Map<String, Object>) {
            Map<String, Object> objectValue = (Map<String, Object>) value;
            if (objectValue.size() > MAX_PROPERTIES) {
                throw new ValidationException(path + ' exceeds the supported property count.');
            }
            for (String key : objectValue.keySet()) {
                validateUnconstrainedValue(objectValue.get(key), path + '.' + key, depth + 1);
            }
        } else if (value instanceof List<Object>) {
            List<Object> arrayValue = (List<Object>) value;
            if (arrayValue.size() > MAX_ARRAY_ITEMS) {
                throw new ValidationException(path + ' exceeds the supported array size.');
            }
            for (Integer index = 0; index < arrayValue.size(); index++) {
                validateUnconstrainedValue(arrayValue[index], path + '[' + index + ']', depth + 1);
            }
        }
    }

    private static void requireOnly(Map<String, Object> schema, Set<String> allowed, String path) {
        for (String keyword : schema.keySet()) {
            if (!allowed.contains(keyword)) {
                throw configuration(path + ' does not support keyword ' + keyword + ' for its type.');
            }
        }
    }

    private static Integer optionalNonNegativeInteger(Object value, String path) {
        if (value == null) {
            return null;
        }
        if (!isNumber(value)) {
            throw configuration(path + ' must be a non-negative integer.');
        }
        Decimal decimalValue = Decimal.valueOf(String.valueOf(value));
        if (decimalValue < 0 || decimalValue != decimalValue.setScale(0) || decimalValue > 131072) {
            throw configuration(path + ' must be a bounded non-negative integer.');
        }
        return decimalValue.intValue();
    }

    private static Decimal optionalDecimal(Object value, String path) {
        if (value == null) {
            return null;
        }
        if (!isNumber(value)) {
            throw configuration(path + ' must be numeric.');
        }
        return Decimal.valueOf(String.valueOf(value));
    }

    /**
     * Formats are assertions. A value that is one protected-value token, such
     * as {{EMAIL_3_9f2c61ab}}, passes: it is checked again once resolved.
     */
    private static void validateFormat(String value, String format, String path) {
        if (format == null || TrustService.isToken(value)) {
            return;
        }
        Boolean valid;
        String expected;
        if (format == 'date') {
            valid = isDate(value);
            expected = 'a date such as 2026-10-01';
        } else if (format == 'date-time') {
            valid = isDateTime(value);
            expected = 'a date and time with a time zone, such as 2026-10-01T15:30:00Z';
        } else if (format == 'email') {
            valid = value.length() <= 254 && EMAIL_FORMAT.matcher(value).matches();
            expected = 'an email address';
        } else if (format == 'uri') {
            valid = value.length() <= 2048 && URI_FORMAT.matcher(value).matches();
            expected = 'an absolute URI such as https://example.com/path';
        } else {
            valid = isSalesforceId(value);
            expected = 'a 15- or 18-character Salesforce record ID';
        }
        if (!valid) {
            throw new ValidationException(path + ' must be ' + expected + '.');
        }
    }

    private static Boolean isDate(String value) {
        if (!DATE_FORMAT.matcher(value).matches()) {
            return false;
        }
        Integer year = Integer.valueOf(value.substring(0, 4));
        Integer month = Integer.valueOf(value.substring(5, 7));
        Integer day = Integer.valueOf(value.substring(8, 10));
        if (month < 1 || month > 12 || day < 1) {
            return false;
        }
        return day <= Date.daysInMonth(year, month);
    }

    private static Boolean isDateTime(String value) {
        Matcher parts = DATE_TIME_FORMAT.matcher(value);
        if (!parts.matches() || !isDate(parts.group(1))) {
            return false;
        }
        Integer offsetHours = parts.group(5) == null ? 0 : Integer.valueOf(parts.group(5));
        Integer offsetMinutes = parts.group(6) == null ? 0 : Integer.valueOf(parts.group(6));
        return Integer.valueOf(parts.group(2)) < 24 &&
            Integer.valueOf(parts.group(3)) < 60 &&
            Integer.valueOf(parts.group(4)) <= 60 &&
            offsetHours < 24 &&
            offsetMinutes < 60;
    }

    private static Boolean isSalesforceId(String value) {
        if (!SALESFORCE_ID_FORMAT.matcher(value).matches()) {
            return false;
        }
        try {
            Id.valueOf(value);
            return true;
        } catch (Exception invalid) {
            return false;
        }
    }

    private static Boolean isNumber(Object value) {
        return value instanceof Decimal || value instanceof Integer || value instanceof Long || value instanceof Double;
    }

    /** The rule is the schema's, so the message is safe to show the model; the value sent is never included. */
    private static void require(Boolean condition, String path, String rule) {
        if (!condition) {
            throw new ValidationException(path + ' ' + rule + '.');
        }
    }

    private static void consumeNodeWork(String path, Boolean schemaValidation) {
        remainingNodeWork = remainingNodeWork == null ? MAX_NODE_WORK - 1 : remainingNodeWork - 1;
        if (remainingNodeWork < 0) {
            if (schemaValidation) {
                throw configuration(path + ' exceeds the aggregate schema work limit.');
            }
            throw new ValidationException(path + ' exceeds the aggregate value work limit.');
        }
    }

    private static AgentKernelException.ConfigurationException configuration(String message) {
        return new AgentKernelException.ConfigurationException(message);
    }
}
