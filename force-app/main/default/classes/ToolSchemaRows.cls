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
 * Reads a tool's input schema as rows an admin can review: one row per
 * input, children after their parent. Works on any schema Core accepts,
 * built or hand-written, so an authoring screen needs no schema code of
 * its own. Paths join property names with "."; the items of a list of
 * objects add no segment, so a list "lines" of objects with "sku" gives
 * the path lines.sku.
 */
public inherited sharing class ToolSchemaRows {
    public class Row {
        @AuraEnabled
        public String path;
        @AuraEnabled
        public String name;
        /** 0 for a top-level input. */
        @AuraEnabled
        public Integer depth;
        /** The JSON type: string, integer, number, boolean, array, or object. */
        @AuraEnabled
        public String type;
        /** What an admin reads, such as Text (255), Record Id, or List of Text. */
        @AuraEnabled
        public String typeLabel;
        /** The type of the input's values: its own type, or its items' type for a list. */
        @AuraEnabled
        public String valueType;
        @AuraEnabled
        public String format;
        @AuraEnabled
        public Boolean required;
        @AuraEnabled
        public String description;
        /** The values the model may send; for a list, the values of each item. Null when any value of the type is allowed. */
        @AuraEnabled
        public List<String> allowedValues;
        @AuraEnabled
        public Integer minLength;
        @AuraEnabled
        public Integer maxLength;
        @AuraEnabled
        public Decimal minimum;
        @AuraEnabled
        public Decimal maximum;
        @AuraEnabled
        public Boolean hasChildren;
    }

    /** The rows of a schema, or an empty list for a blank one. The schema must already be valid. */
    public static List<Row> read(String schemaJson) {
        List<Row> rows = new List<Row>();
        if (String.isBlank(schemaJson)) {
            return rows;
        }
        Object root = JSON.deserializeUntyped(schemaJson);
        if (root instanceof Map<String, Object>) {
            addProperties((Map<String, Object>) root, '', 0, rows);
        }
        return rows;
    }

    /** The object schema whose properties hold the input at path, or null. Lists of objects are passed through. */
    public static Map<String, Object> parentOf(Map<String, Object> schema, String path) {
        Map<String, Object> current = schema;
        List<String> segments = path.split('\\.');
        for (Integer index = 0; index < segments.size() - 1; index++) {
            Map<String, Object> child = propertyOf(current, segments[index]);
            current = child == null ? null : objectOf(child);
            if (current == null) {
                return null;
            }
        }
        return propertyOf(current, segments[segments.size() - 1]) == null ? null : current;
    }

    /** The schema of the input at path, or null. */
    public static Map<String, Object> nodeAt(Map<String, Object> schema, String path) {
        Map<String, Object> parent = parentOf(schema, path);
        return parent == null ? null : propertyOf(parent, path.contains('.') ? path.substringAfterLast('.') : path);
    }

    /** The object whose properties a node's children are: the node itself, or the items of a list of objects. */
    public static Map<String, Object> objectOf(Map<String, Object> node) {
        if (node.get('type') == 'object') {
            return node;
        }
        if (node.get('type') == 'array' && node.get('items') instanceof Map<String, Object>) {
            Map<String, Object> items = (Map<String, Object>) node.get('items');
            return items.get('type') == 'object' ? items : null;
        }
        return null;
    }

    /** The node that holds a value list: the node, or the items of a list of plain values. */
    public static Map<String, Object> valuesOf(Map<String, Object> node) {
        if (node.get('type') == 'array' && node.get('items') instanceof Map<String, Object>) {
            return (Map<String, Object>) node.get('items');
        }
        return node;
    }

    public static Set<String> requiredNames(Map<String, Object> objectSchema) {
        Set<String> names = new Set<String>();
        Object required = objectSchema.get('required');
        for (Object name : required instanceof List<Object> ? (List<Object>) required : new List<Object>()) {
            names.add(String.valueOf(name));
        }
        return names;
    }

    private static Map<String, Object> propertyOf(Map<String, Object> objectSchema, String name) {
        Object properties = objectSchema == null ? null : objectSchema.get('properties');
        if (!(properties instanceof Map<String, Object>)) {
            return null;
        }
        Object node = ((Map<String, Object>) properties).get(name);
        return node instanceof Map<String, Object> ? (Map<String, Object>) node : null;
    }

    private static void addProperties(Map<String, Object> objectSchema, String prefix, Integer depth, List<Row> rows) {
        Object properties = objectSchema.get('properties');
        if (!(properties instanceof Map<String, Object>)) {
            return;
        }
        Set<String> required = requiredNames(objectSchema);
        Map<String, Object> byName = (Map<String, Object>) properties;
        for (String name : byName.keySet()) {
            if (!(byName.get(name) instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> node = (Map<String, Object>) byName.get(name);
            Row row = new Row();
            row.name = name;
            row.path = prefix + name;
            row.depth = depth;
            row.type = (String) node.get('type');
            row.typeLabel = typeLabel(node);
            row.required = required.contains(name);
            row.description = (String) node.get('description');
            Map<String, Object> values = valuesOf(node);
            row.valueType = values.get('type') instanceof String ? (String) values.get('type') : null;
            row.format = (String) values.get('format');
            row.allowedValues = allowedValues(values.get('enum'));
            row.minLength = integerOf(values.get('minLength'));
            row.maxLength = integerOf(values.get('maxLength'));
            row.minimum = decimalOf(values.get('minimum'));
            row.maximum = decimalOf(values.get('maximum'));
            Map<String, Object> children = objectOf(node);
            row.hasChildren = children != null && children.get('properties') instanceof Map<String, Object>;
            rows.add(row);
            if (row.hasChildren) {
                addProperties(children, row.path + '.', depth + 1, rows);
            }
        }
    }

    private static String typeLabel(Map<String, Object> node) {
        String type = (String) node.get('type');
        if (type == 'array') {
            Object items = node.get('items');
            return 'List of ' + (items instanceof Map<String, Object> ? typeLabel((Map<String, Object>) items) : 'values');
        }
        if (type == 'object') {
            return 'Group';
        }
        if (type == 'integer') {
            return 'Whole number';
        }
        if (type == 'number') {
            return 'Number';
        }
        if (type == 'boolean') {
            return 'Checkbox';
        }
        if (type != 'string') {
            return type;
        }
        if (node.containsKey('enum')) {
            return 'Picklist';
        }
        String format = (String) node.get('format');
        if (format == 'salesforce-id') {
            return 'Record Id';
        }
        if (format == 'date') {
            return 'Date';
        }
        if (format == 'date-time') {
            return 'Date and time';
        }
        if (format == 'email') {
            return 'Email';
        }
        if (format == 'uri') {
            return 'URL';
        }
        Integer maxLength = integerOf(node.get('maxLength'));
        return maxLength == null ? 'Text' : 'Text (' + maxLength + ')';
    }

    private static List<String> allowedValues(Object values) {
        if (!(values instanceof List<Object>)) {
            return null;
        }
        List<String> result = new List<String>();
        for (Object value : (List<Object>) values) {
            result.add(value instanceof String ? (String) value : JSON.serialize(value));
        }
        return result;
    }

    private static Integer integerOf(Object value) {
        return value == null ? null : Integer.valueOf(String.valueOf(value));
    }

    private static Decimal decimalOf(Object value) {
        return value == null ? null : Decimal.valueOf(String.valueOf(value));
    }
}
