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
 * The admin's edits to the inputs a tool builds from its settings. They sit
 * in Implementation Configuration under inputOverrides, by input path:
 *
 *   "inputOverrides": {
 *     "recordData.Subject": { "description": "One line naming the product." },
 *     "recordData.Description": { "required": true },
 *     "recordData.Priority": { "allowedValues": ["Medium", "High"] },
 *     "decision": { "allowedValues": ["released", "hold"] },
 *     "reason": { "maxLength": 255 }
 *   }
 *
 * An edit can only narrow what the tool builds: replace a description, make
 * an optional input required, keep some of the values the input offers,
 * limit free text to a list of values, or lower its length limit. Save
 * refuses any other edit. On a run, a kept value the tool no longer offers
 * is dropped, and an input left with no values is left out.
 */
public inherited sharing class ToolInputOverrides {
    public static final String KEY = 'inputOverrides';
    private static final Set<String> EDIT_KEYS = new Set<String>{ 'description', 'required', 'allowedValues', 'maxLength' };
    private static final Integer MAX_DESCRIPTION_CHARACTERS = 2000;
    private static final Integer MAX_ALLOWED_VALUES = 100;

    /** A problem with one edit, on the input it names. */
    public class Problem {
        public String path;
        public String message;

        Problem(String path, String message) {
            this.path = path;
            this.message = message;
        }
    }

    public class Applied {
        public String schema;
        public String problem;
    }

    /** The edits by path. Empty when the configuration has none. Throws when inputOverrides is not an object of edits. */
    public static Map<String, Map<String, Object>> read(String configuration) {
        Map<String, Map<String, Object>> edits = new Map<String, Map<String, Object>>();
        Object raw = configurationValue(configuration);
        if (raw == null) {
            return edits;
        }
        if (!(raw instanceof Map<String, Object>)) {
            throw new AgentKernelException.ConfigurationException(
                KEY + ' must be an object whose keys are input paths, such as {"recordData.Priority": {"allowedValues": ["High"]}}.'
            );
        }
        Map<String, Object> byPath = (Map<String, Object>) raw;
        for (String path : byPath.keySet()) {
            if (!(byPath.get(path) instanceof Map<String, Object>)) {
                throw new AgentKernelException.ConfigurationException('The edit for ' + path + ' must be an object.');
            }
            edits.put(path, (Map<String, Object>) byPath.get(path));
        }
        return edits;
    }

    /** Each edit that names no built input, or that would widen it, as a message naming the path. */
    public static List<String> problems(String builtSchema, String configuration) {
        List<String> messages = new List<String>();
        for (Problem problem : problemsByInput(builtSchema, configuration)) {
            messages.add(problem.message);
        }
        return messages;
    }

    /** The same problems, each with the input path it belongs to; null path when the edits cannot be read at all. */
    public static List<Problem> problemsByInput(String builtSchema, String configuration) {
        List<Problem> problems = new List<Problem>();
        Map<String, Map<String, Object>> edits;
        try {
            edits = read(configuration);
        } catch (AgentKernelException.ConfigurationException invalid) {
            problems.add(new Problem(null, invalid.getMessage()));
            return problems;
        }
        if (edits.isEmpty()) {
            return problems;
        }
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(builtSchema);
        for (String path : edits.keySet()) {
            Map<String, Object> node = ToolSchemaRows.nodeAt(schema, path);
            if (node == null) {
                problems.add(
                    new Problem(path, 'The edit for ' + path + ' names an input this tool does not have. Remove the edit, or change the tool\'s settings.')
                );
                continue;
            }
            Map<String, Object> edit = edits.get(path);
            for (String key : edit.keySet()) {
                if (!EDIT_KEYS.contains(key)) {
                    problems.add(
                        new Problem(
                            path,
                            'The edit for ' + path + ' has an unknown setting, ' + key + '. Use description, required, allowedValues, or maxLength.'
                        )
                    );
                }
            }
            Object description = edit.get('description');
            if (
                edit.containsKey('description') &&
                (!(description instanceof String) ||
                String.isBlank((String) description) ||
                ((String) description).length() > MAX_DESCRIPTION_CHARACTERS)
            ) {
                problems.add(new Problem(path, 'The description for ' + path + ' must be text of 1 to ' + MAX_DESCRIPTION_CHARACTERS + ' characters.'));
            }
            Object required = edit.get('required');
            if (edit.containsKey('required') && !(required instanceof Boolean)) {
                problems.add(new Problem(path, 'required for ' + path + ' must be true or false.'));
            } else if (required == false && ToolSchemaRows.requiredNames(ToolSchemaRows.parentOf(schema, path)).contains(lastSegment(path))) {
                problems.add(new Problem(path, path + ' is required by the tool. An edit can make an input required, but not optional.'));
            }
            if (edit.containsKey('allowedValues')) {
                for (String message : allowedValueProblems(path, node, edit.get('allowedValues'))) {
                    problems.add(new Problem(path, message));
                }
            }
            if (edit.containsKey('maxLength')) {
                String message = maxLengthProblem(path, node, edit.get('maxLength'));
                if (message != null) {
                    problems.add(new Problem(path, message));
                }
            }
        }
        return problems;
    }

    /**
     * The built schema with the edits applied for a run. Edits for inputs
     * the tool no longer builds are skipped. A problem means the schema
     * cannot be used: a required input has none of its kept values left.
     */
    public static Applied apply(String builtSchema, String configuration) {
        Applied result = new Applied();
        Map<String, Map<String, Object>> edits = read(configuration);
        if (edits.isEmpty()) {
            result.schema = builtSchema;
            return result;
        }
        Map<String, Object> schema = (Map<String, Object>) JSON.deserializeUntyped(builtSchema);
        List<String> emptied = new List<String>();
        for (String path : edits.keySet()) {
            Map<String, Object> node = ToolSchemaRows.nodeAt(schema, path);
            if (node == null) {
                continue;
            }
            Map<String, Object> edit = edits.get(path);
            if (edit.get('description') instanceof String && !String.isBlank((String) edit.get('description'))) {
                node.put('description', edit.get('description'));
            }
            if (edit.get('required') == true) {
                markRequired(ToolSchemaRows.parentOf(schema, path), lastSegment(path));
            }
            if (edit.get('maxLength') instanceof Integer) {
                lowerMaxLength(node, (Integer) edit.get('maxLength'));
            }
            if (edit.get('allowedValues') instanceof List<Object> && !keepValues(node, (List<Object>) edit.get('allowedValues'))) {
                emptied.add(path);
            }
        }
        emptied.sort();
        for (String path : emptied) {
            Map<String, Object> parent = ToolSchemaRows.parentOf(schema, path);
            String name = lastSegment(path);
            if (ToolSchemaRows.requiredNames(parent).contains(name)) {
                result.problem = path + ' is required, but none of the values it is limited to are offered any more. Edit ' + path + '\'s values on the tool.';
                return result;
            }
            ((Map<String, Object>) parent.get('properties')).remove(name);
        }
        result.schema = CanonicalJson.serializeInOrder(schema, false);
        return result;
    }

    private static List<String> allowedValueProblems(String path, Map<String, Object> node, Object chosen) {
        List<String> problems = new List<String>();
        Map<String, Object> values = ToolSchemaRows.valuesOf(node);
        Object offered = values.get('enum');
        if (!(offered instanceof List<Object>) && values.get('type') != 'string') {
            problems.add(path + ' is not text, so its values cannot be limited.');
            return problems;
        }
        if (!(chosen instanceof List<Object>) || ((List<Object>) chosen).isEmpty()) {
            problems.add('allowedValues for ' + path + ' must list at least one value.');
            return problems;
        }
        if (offered instanceof List<Object>) {
            Set<String> offeredValues = serializedSet((List<Object>) offered);
            for (Object value : (List<Object>) chosen) {
                if (!offeredValues.contains(JSON.serialize(value))) {
                    problems.add(path + ' does not offer the value ' + String.valueOf(value) + '. Choose from the values it offers.');
                }
            }
            return problems;
        }
        // Free text: the admin lists the values the model may send.
        List<Object> listed = (List<Object>) chosen;
        if (listed.size() > MAX_ALLOWED_VALUES) {
            problems.add(path + ' can be limited to at most ' + MAX_ALLOWED_VALUES + ' values.');
        }
        Integer maxLength = values.get('maxLength') instanceof Integer ? (Integer) values.get('maxLength') : null;
        Set<String> seen = new Set<String>();
        for (Object value : listed) {
            if (!(value instanceof String) || String.isBlank((String) value)) {
                problems.add('Each value for ' + path + ' must be non-blank text.');
            } else if (!seen.add((String) value)) {
                problems.add(path + ' lists the value ' + value + ' more than once.');
            } else if (maxLength != null && ((String) value).length() > maxLength) {
                problems.add('The value ' + value + ' is longer than the ' + maxLength + ' characters ' + path + ' allows.');
            }
        }
        return problems;
    }

    private static String maxLengthProblem(String path, Map<String, Object> node, Object chosen) {
        Map<String, Object> values = ToolSchemaRows.valuesOf(node);
        if (values.get('type') != 'string') {
            return path + ' is not text, so it has no length limit.';
        }
        if (!(chosen instanceof Integer) || (Integer) chosen < 1) {
            return 'maxLength for ' + path + ' must be a whole number of at least 1.';
        }
        Integer built = values.get('maxLength') instanceof Integer ? (Integer) values.get('maxLength') : null;
        if (built != null && (Integer) chosen > built) {
            return path + ' allows at most ' + built + ' characters. An edit can lower the limit, but not raise it.';
        }
        Integer minLength = values.get('minLength') instanceof Integer ? (Integer) values.get('minLength') : null;
        if (minLength != null && (Integer) chosen < minLength) {
            return path + ' needs at least ' + minLength + ' characters, so its limit cannot be lower.';
        }
        return null;
    }

    private static void lowerMaxLength(Map<String, Object> node, Integer chosen) {
        Map<String, Object> values = ToolSchemaRows.valuesOf(node);
        if (values.get('type') != 'string') {
            return;
        }
        Integer built = values.get('maxLength') instanceof Integer ? (Integer) values.get('maxLength') : null;
        values.put('maxLength', built == null ? chosen : Math.min(built, chosen));
    }

    /**
     * Keeps the offered values the admin chose, in the tool's order, or
     * limits free text to the admin's list. False when none is left.
     */
    private static Boolean keepValues(Map<String, Object> node, List<Object> chosen) {
        Map<String, Object> values = ToolSchemaRows.valuesOf(node);
        if (!(values.get('enum') instanceof List<Object>)) {
            if (values.get('type') == 'string' && !chosen.isEmpty()) {
                values.put('enum', chosen);
            }
            return true;
        }
        Set<String> wanted = serializedSet(chosen);
        List<Object> kept = new List<Object>();
        for (Object value : (List<Object>) values.get('enum')) {
            if (wanted.contains(JSON.serialize(value))) {
                kept.add(value);
            }
        }
        if (kept.isEmpty()) {
            return false;
        }
        values.put('enum', kept);
        return true;
    }

    private static void markRequired(Map<String, Object> parent, String name) {
        List<Object> required = parent.get('required') instanceof List<Object> ? (List<Object>) parent.get('required') : new List<Object>();
        if (!ToolSchemaRows.requiredNames(parent).contains(name)) {
            required.add(name);
        }
        parent.put('required', required);
    }

    private static Set<String> serializedSet(List<Object> values) {
        Set<String> result = new Set<String>();
        for (Object value : values) {
            result.add(JSON.serialize(value));
        }
        return result;
    }

    private static String lastSegment(String path) {
        return path.contains('.') ? path.substringAfterLast('.') : path;
    }

    private static Object configurationValue(String configuration) {
        if (String.isBlank(configuration)) {
            return null;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(configuration);
        } catch (Exception unreadable) {
            return null;
        }
        return parsed instanceof Map<String, Object> ? ((Map<String, Object>) parsed).get(KEY) : null;
    }
}
