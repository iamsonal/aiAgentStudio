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
 * Standard tool: read records with one SOQL query the admin wrote. Each
 * :name bind is a value the model supplies, in WHERE (subqueries included),
 * LIMIT, or OFFSET. A run value, such as :anchorId (the run's record) or
 * :initiatingUserId, is filled in by Core and is never a model input (see
 * ToolRunValues). The model never sees or changes the query text. Runs in user mode
 * and returns recordSets, so Core strips unreadable fields, filters records
 * for the person on attended runs, and tokenizes sensitive values, including
 * in parent and child records.
 *
 * Configuration: {"query":"SELECT Subject, Account.Name FROM Case WHERE ContactId = :contactId AND Status IN :statuses ORDER BY CreatedDate DESC LIMIT 10"}
 * Model input: {"contactId":"003...","statuses":["New","Working"]}
 *
 * Core reads only what it needs from the query (each object, the fields it
 * selects, each bind and what it is compared to) and refuses only what it
 * cannot protect: totals, Agent Core objects, system mode, FOR clauses, and
 * aliases, whose values Core would drop. The platform compiles the rest at
 * save. LIMIT is optional; Core's 200-record output limit still applies.
 *
 * Standard tool type QueryRecords. It only reads, so Core may repeat a failed
 * or lost call.
 */
public inherited sharing class StandardQueryRecordsTool implements ITool, IRequesterFilteredTool, IToolAuthoring {
    public static final String ANCHOR_BIND = 'anchorId';
    private static final Integer MAX_LIST_VALUES = 50;
    private static final Integer MAX_QUERY_CHARACTERS = 4000;
    private static final Set<String> AGGREGATES = new Set<String>{ 'COUNT', 'COUNT_DISTINCT', 'SUM', 'AVG', 'MIN', 'MAX' };
    /** Functions that return a field's value under the field's own name, so Core's protection still applies. */
    private static final Set<String> SELECT_FUNCTIONS = new Set<String>{ 'TOLABEL', 'FORMAT', 'CONVERTCURRENCY' };
    private static final Set<String> REFUSED_CLAUSES = new Set<String>{ 'GROUP', 'HAVING', 'FOR', 'USING', 'UPDATE' };
    private static final Set<String> CLAUSES = new Set<String>{ 'SELECT', 'FROM', 'WHERE', 'WITH', 'ORDER', 'LIMIT', 'OFFSET' };
    private static final String OUTER_QUERY = 'outer';
    private static final String CHILD_QUERY = 'child';
    private static final String FILTER_QUERY = 'filter';
    private static final Set<String> COMPARISONS = new Set<String>{ '=', '!=', '<>', '<', '<=', '>', '>=' };
    private static final Set<String> WORD_COMPARISONS = new Set<String>{ 'LIKE', 'IN', 'INCLUDES', 'EXCLUDES' };
    private static final Set<String> LIST_OPERATORS = new Set<String>{ 'IN', 'NOT IN', 'INCLUDES', 'EXCLUDES' };
    private static final Set<String> KEYWORDS = new Set<String>{
        'AND',
        'OR',
        'NOT',
        'IN',
        'LIKE',
        'INCLUDES',
        'EXCLUDES',
        'NULL',
        'TRUE',
        'FALSE',
        'SELECT',
        'FROM',
        'WHERE'
    };

    public AgentKernelModels.ToolResponse execute(AgentKernelModels.ToolRequest request) {
        Query query = read(request == null ? null : request.implementationConfiguration);
        Map<String, Object> input = StandardToolSupport.objectInput(request == null || String.isBlank(request.input) ? '{}' : request.input, 'Tool input');
        Map<String, Bind> modelBinds = new Map<String, Bind>();
        for (Bind bind : query.binds) {
            if (!bind.isRunValue()) {
                modelBinds.put(bind.name.toLowerCase(), bind);
            }
        }
        for (String key : input.keySet()) {
            if (key == null || !modelBinds.containsKey(key.toLowerCase())) {
                throw StandardToolSupport.permanent(
                    'Tool input contains an unsupported property: ' +
                        key +
                        '. This tool accepts: ' +
                        (modelBinds.isEmpty() ? 'no inputs' : String.join(query.modelInputNames(), ', ')) +
                        '.'
                );
            }
        }
        Map<String, Object> supplied = new Map<String, Object>();
        for (String key : input.keySet()) {
            supplied.put(key.toLowerCase(), input.get(key));
        }
        Map<String, Object> binds = new Map<String, Object>();
        for (Bind bind : query.binds) {
            if (binds.containsKey(bind.name)) {
                continue;
            }
            binds.put(
                bind.name,
                bind.isAnchor()
                    ? anchorValue(request, bind)
                    : bind.isRunValue() ? ToolRunValues.resolve(ToolRunValues.canonical(bind.name), request) : bind.value(supplied.get(bind.name.toLowerCase()))
            );
        }
        List<SObject> records;
        try {
            records = Database.queryWithBinds(query.soql, binds, AccessLevel.USER_MODE);
        } catch (QueryException denied) {
            throw StandardToolSupport.permanent('The query could not run as the run user: ' + StandardToolSupport.bound(denied.getMessage(), 500));
        }
        AgentKernelModels.ToolResponse response = new AgentKernelModels.ToolResponse();
        response.isSuccess = true;
        response.recordSets = new Map<String, List<SObject>>{ query.objectName => records };
        return response;
    }

    public List<String> validateConfiguration(AgentKernelModels.ToolConfiguration configuration) {
        try {
            compile(read(configuration == null ? null : configuration.implementationConfiguration));
            return new List<String>();
        } catch (Exception invalid) {
            return StandardToolSupport.problems(invalid);
        }
    }

    public AgentKernelModels.ToolAuthoring describe(AgentKernelModels.ToolConfiguration configuration) {
        AgentKernelModels.ToolAuthoring authoring = new AgentKernelModels.ToolAuthoring();
        authoring.settings.add(
            new AgentKernelModels.ToolSetting(
                'query',
                'Query',
                'query',
                true,
                'One SOQL query. Each :name in WHERE is a value the agent fills in, and :' + ANCHOR_BIND + ' is the run\'s record.'
            )
        );
        try {
            authoring.inputSchema = StandardToolSchemas.queryInputs(read(configuration == null ? null : configuration.implementationConfiguration));
        } catch (Exception notYetBuildable) {
            authoring.problem = notYetBuildable.getMessage();
        }
        return authoring;
    }

    /**
     * True when the query's WHERE compares a field to :anchorId with = and
     * has no OR or NOT, so every record it returns relates to the run's
     * record. False for a query that cannot be read.
     */
    public static Boolean scopedToAnchor(String implementationConfiguration) {
        try {
            return read(implementationConfiguration).scopedToAnchor;
        } catch (Exception unreadable) {
            return false;
        }
    }

    /** The query in a tool's configuration, read and checked; throws a message naming the fix. */
    public static Query read(String implementationConfiguration) {
        Map<String, Object> config = StandardToolSupport.configuration(implementationConfiguration);
        for (String key : config.keySet()) {
            if (key != 'query') {
                throw StandardToolSupport.permanent('Unsupported setting ' + key + '. Query Records takes only "query".');
            }
        }
        String soql = StandardToolSupport.requiredConfig(config, 'query', 'query');
        if (soql.length() > MAX_QUERY_CHARACTERS) {
            throw StandardToolSupport.permanent('The query must be at most ' + MAX_QUERY_CHARACTERS + ' characters.');
        }
        return new Reader(soql).read();
    }

    /** Runs the query once in system mode with empty values, so the platform reports unknown fields and syntax; rows are discarded. */
    private static void compile(Query query) {
        Map<String, Object> placeholders = new Map<String, Object>();
        for (Bind bind : query.binds) {
            placeholders.put(bind.name, bind.isList ? bind.emptyList() : bind.placeholder());
        }
        try {
            Database.queryWithBinds(query.soql, placeholders, AccessLevel.SYSTEM_MODE);
        } catch (QueryException invalid) {
            throw StandardToolSupport.permanent('The query does not run: ' + StandardToolSupport.bound(invalid.getMessage(), 500));
        }
    }

    private static Id anchorValue(AgentKernelModels.ToolRequest request, Bind bind) {
        Id anchorId = request == null || request.principal == null ? null : request.principal.anchorRecordId;
        if (anchorId == null) {
            throw StandardToolSupport.permanent('This tool reads records of the run\'s record, but the run was not started on a record.');
        }
        Schema.SObjectType anchorType = anchorId.getSObjectType();
        Boolean fits = bind.field.field.getType() == Schema.DisplayType.ID
            ? bind.field.ownerType == anchorType
            : bind.field.field.getReferenceTo().contains(anchorType);
        if (!fits) {
            throw StandardToolSupport.permanent(
                bind.field.path + ' cannot hold the run\'s record, which is a ' + anchorType.getDescribe().getName() + '. Run this tool on a matching record.'
            );
        }
        return anchorId;
    }

    /** What Core read from a query. */
    public class Query {
        public String soql;
        public Schema.SObjectType objectType;
        public String objectName;
        public List<FieldRef> selected = new List<FieldRef>();
        public List<FieldRef> ordered = new List<FieldRef>();
        /** Each bind once, in the order it first appears. */
        public List<Bind> binds = new List<Bind>();
        public Boolean scopedToAnchor = false;

        public List<String> modelInputNames() {
            List<String> names = new List<String>();
            for (Bind bind : binds) {
                if (!bind.isRunValue()) {
                    names.add(bind.name);
                }
            }
            return names;
        }

        /**
         * Every field the query names through a selection, a bind, or ORDER
         * BY, on one known object. Fields behind a lookup to many objects are
         * left out: Core checks those records when the query returns them.
         */
        public List<FieldRef> fieldsRead() {
            List<FieldRef> all = new List<FieldRef>();
            List<FieldRef> named = new List<FieldRef>(selected);
            named.addAll(ordered);
            for (Bind bind : binds) {
                named.add(bind.field);
            }
            for (FieldRef ref : named) {
                if (ref != null && ref.field != null && !ref.polymorphic) {
                    all.add(ref);
                }
            }
            return all;
        }
    }

    /** A field path from the FROM object, such as Account.Owner.Email, resolved to the object that owns its last field. */
    public class FieldRef {
        public String path;
        public Schema.SObjectType ownerType;
        public Schema.DescribeFieldResult field;
        /** True behind a lookup to many objects, such as What.Name; ownerType is then the first of them that has the field. */
        public Boolean polymorphic = false;
    }

    public class Bind {
        public String name;
        /** The comparison, such as = or NOT IN, or LIMIT or OFFSET for a record count. */
        public String operator;
        /** The field the value is compared to; null for LIMIT and OFFSET. */
        public FieldRef field;
        public Boolean isList;

        public Boolean isAnchor() {
            return name.equalsIgnoreCase(ANCHOR_BIND);
        }

        /** True for a value Core fills in on each call, such as :anchorId; the model never supplies it. */
        public Boolean isRunValue() {
            return ToolRunValues.isRunValue(name);
        }

        public Boolean isCount() {
            return operator == 'LIMIT' || operator == 'OFFSET';
        }

        /** A value that compiles at save: an empty value for a comparison, the smallest count for LIMIT or OFFSET. */
        Object placeholder() {
            if (!isCount()) {
                return null;
            }
            return operator == 'LIMIT' ? 1 : 0;
        }

        Object value(Object raw) {
            if (raw == null) {
                throw StandardToolSupport.permanent('Tool input must include ' + name + '.');
            }
            if (isCount()) {
                Integer count = (Integer) StandardToolSupport.coerceValue(Schema.DisplayType.INTEGER, raw, name);
                Integer least = operator == 'LIMIT' ? 1 : 0;
                if (count < least) {
                    throw StandardToolSupport.permanent(name + ' must be a whole number of at least ' + least + '.');
                }
                return count;
            }
            if (!isList) {
                return coerce(raw);
            }
            if (!(raw instanceof List<Object>) || ((List<Object>) raw).isEmpty() || ((List<Object>) raw).size() > MAX_LIST_VALUES) {
                throw StandardToolSupport.permanent(name + ' must be a list of 1 through ' + MAX_LIST_VALUES + ' values.');
            }
            List<Object> values = emptyList();
            for (Object item : (List<Object>) raw) {
                if (item == null) {
                    throw StandardToolSupport.permanent(name + ' must not contain empty values.');
                }
                values.add(coerce(item));
            }
            return values;
        }

        private Object coerce(Object raw) {
            Schema.DisplayType type = field.field.getType();
            return StandardToolSupport.coerceValue(type == Schema.DisplayType.ID ? Schema.DisplayType.REFERENCE : type, raw, name);
        }

        /** A list typed for the field: the platform refuses an untyped list as an IN bind. */
        List<Object> emptyList() {
            Schema.DisplayType type = field.field.getType();
            if (type == Schema.DisplayType.ID || type == Schema.DisplayType.REFERENCE) {
                return new List<Id>();
            }
            if (type == Schema.DisplayType.INTEGER) {
                return new List<Integer>();
            }
            if (type == Schema.DisplayType.DOUBLE || type == Schema.DisplayType.CURRENCY || type == Schema.DisplayType.PERCENT) {
                return new List<Decimal>();
            }
            if (type == Schema.DisplayType.DATE) {
                return new List<Date>();
            }
            if (type == Schema.DisplayType.DATETIME) {
                return new List<Datetime>();
            }
            if (type == Schema.DisplayType.BOOLEAN) {
                return new List<Boolean>();
            }
            if (type == Schema.DisplayType.TIME) {
                return new List<Time>();
            }
            return new List<String>();
        }
    }

    private class Token {
        String kind;
        String text;
        String upper;

        Token(String kind, String text) {
            this.kind = kind;
            this.text = text;
            this.upper = text.toUpperCase();
        }

        Boolean isWord(String value) {
            return kind == 'word' && upper == value;
        }
    }

    private class Reader {
        private final String soql;
        private List<Token> tokens = new List<Token>();
        private Query query = new Query();
        private Map<Schema.SObjectType, Map<String, Schema.SObjectField>> fieldsByType = new Map<Schema.SObjectType, Map<String, Schema.SObjectField>>();
        private Map<Schema.SObjectType, Map<String, Schema.DescribeFieldResult>> relationshipsByType = new Map<Schema.SObjectType, Map<String, Schema.DescribeFieldResult>>();
        private Map<String, Bind> bindsByName = new Map<String, Bind>();

        Reader(String soql) {
            this.soql = soql;
            query.soql = soql;
        }

        Query read() {
            tokenize();
            readQuery(tokens, OUTER_QUERY, null);
            query.binds = orderedBinds();
            return query;
        }

        /**
         * Reads one query: the outer query, a child subquery in SELECT whose
         * FROM names a child relationship of parentType, or a filter subquery
         * in WHERE whose FROM names an object. Returns its object.
         */
        private Schema.SObjectType readQuery(List<Token> queryTokens, String kind, Schema.SObjectType parentType) {
            Map<String, List<Token>> clauses = clauses(queryTokens);
            if (!clauses.containsKey('FROM')) {
                throw refuse(
                    kind == OUTER_QUERY
                        ? 'The query needs FROM and one object, such as SELECT Subject FROM Case WHERE CaseNumber = :caseNumber.'
                        : 'Each subquery needs FROM, such as (SELECT LastName FROM Contacts).'
                );
            }
            Schema.SObjectType objectType = kind == CHILD_QUERY ? readChildFrom(clauses.get('FROM'), parentType) : readFrom(clauses.get('FROM'));
            if (kind == OUTER_QUERY) {
                query.objectType = objectType;
                query.objectName = objectType.getDescribe().getName();
            }
            readSelect(clauses.get('SELECT'), objectType, kind);
            if (clauses.containsKey('WHERE')) {
                readWhere(clauses.get('WHERE'), objectType, kind == OUTER_QUERY);
            }
            if (clauses.containsKey('WITH')) {
                readWith(clauses.get('WITH'));
            }
            if (clauses.containsKey('ORDER')) {
                readOrder(clauses.get('ORDER'), objectType);
            }
            for (String countClause : new List<String>{ 'LIMIT', 'OFFSET' }) {
                if (clauses.containsKey(countClause)) {
                    readCount(countClause, clauses.get(countClause));
                }
            }
            return objectType;
        }

        private List<Bind> orderedBinds() {
            List<Bind> result = new List<Bind>();
            Set<String> seen = new Set<String>();
            for (Token token : tokens) {
                if (token.kind == 'bind' && seen.add(token.text.toLowerCase())) {
                    result.add(bindsByName.get(token.text.toLowerCase()));
                }
            }
            return result;
        }

        private void tokenize() {
            Integer index = 0;
            Integer length = soql.length();
            while (index < length) {
                String c = soql.substring(index, index + 1);
                if (c.isWhitespace()) {
                    index++;
                } else if (c == '\'') {
                    Integer close = index + 1;
                    while (close < length && soql.substring(close, close + 1) != '\'') {
                        close += soql.substring(close, close + 1) == '\\' ? 2 : 1;
                    }
                    if (close >= length) {
                        throw refuse('The query has a quote that is never closed.');
                    }
                    tokens.add(new Token('string', soql.substring(index, close + 1)));
                    index = close + 1;
                } else if (c == ':' && index + 1 < length && soql.substring(index + 1, index + 2).isAlpha()) {
                    Integer finish = scan(index + 1, false);
                    tokens.add(new Token('bind', soql.substring(index + 1, finish)));
                    index = finish;
                } else if (c.isAlpha() || c == '_') {
                    Integer finish = scan(index, true);
                    tokens.add(new Token('word', soql.substring(index, finish)));
                    index = finish;
                } else if (c.isNumeric() || (c == '-' && index + 1 < length && soql.substring(index + 1, index + 2).isNumeric())) {
                    Integer finish = index + 1;
                    while (finish < length && (soql.substring(finish, finish + 1).isAlphanumeric() || ':.-+'.contains(soql.substring(finish, finish + 1)))) {
                        finish++;
                    }
                    tokens.add(new Token('number', soql.substring(index, finish)));
                    index = finish;
                } else if ('(),:'.contains(c)) {
                    tokens.add(new Token(c, c));
                    index++;
                } else if ('=<>!'.contains(c)) {
                    String two = index + 2 <= length ? soql.substring(index, index + 2) : c;
                    String op = COMPARISONS.contains(two) ? two : c;
                    if (!COMPARISONS.contains(op)) {
                        throw refuse('The query has an operator Core does not read: ' + op + '.');
                    }
                    tokens.add(new Token('op', op));
                    index += op.length();
                } else {
                    throw refuse('The query has a character Core does not read: ' + c + '.');
                }
            }
        }

        private Integer scan(Integer start, Boolean allowDots) {
            Integer finish = start;
            while (finish < soql.length()) {
                String c = soql.substring(finish, finish + 1);
                if (!(c.isAlphanumeric() || c == '_' || (allowDots && c == '.'))) {
                    break;
                }
                finish++;
            }
            return finish;
        }

        /** One query's clauses; tokens inside parentheses stay with the clause they are in. */
        private Map<String, List<Token>> clauses(List<Token> queryTokens) {
            if (queryTokens.isEmpty() || !queryTokens[0].isWord('SELECT')) {
                throw refuse('The query must start with SELECT.');
            }
            Map<String, List<Token>> result = new Map<String, List<Token>>();
            String current;
            Integer depth = 0;
            for (Token token : queryTokens) {
                if (token.kind == '(') {
                    depth++;
                } else if (token.kind == ')') {
                    depth--;
                    if (depth < 0) {
                        throw refuse('The query has a closing parenthesis without an opening one.');
                    }
                }
                if (depth == 0 && token.kind == 'word' && REFUSED_CLAUSES.contains(token.upper)) {
                    throw refuse(refusedClause(token.upper));
                }
                if (depth == 0 && token.kind == 'word' && CLAUSES.contains(token.upper)) {
                    if (result.containsKey(token.upper)) {
                        throw refuse('The query has more than one ' + token.upper + '.');
                    }
                    current = token.upper;
                    result.put(current, new List<Token>());
                    continue;
                }
                result.get(current).add(token);
            }
            if (depth != 0) {
                throw refuse('The query has an opening parenthesis that is never closed.');
            }
            return result;
        }

        private String refusedClause(String keyword) {
            if (keyword == 'GROUP' || keyword == 'HAVING') {
                return 'Query Records returns records, not totals, so GROUP BY and HAVING are not supported. Use a Run Report tool for totals.';
            }
            if (keyword == 'FOR' || keyword == 'UPDATE') {
                return 'Remove the FOR clause. Query Records only reads.';
            }
            return 'Remove USING SCOPE. Filter in WHERE instead.';
        }

        private Schema.SObjectType readFrom(List<Token> objectTokens) {
            if (objectTokens.size() != 1 || objectTokens[0].kind != 'word' || objectTokens[0].text.contains('.')) {
                throw refuse('FROM must name one object with no alias, such as FROM Case.');
            }
            return StandardToolSupport.resolveObject(objectTokens[0].text);
        }

        /** The object behind a child relationship, such as Contact for Contacts on Account. */
        private Schema.SObjectType readChildFrom(List<Token> relationshipTokens, Schema.SObjectType parentType) {
            String parentName = parentType.getDescribe().getName();
            if (relationshipTokens.size() != 1 || relationshipTokens[0].kind != 'word' || relationshipTokens[0].text.contains('.')) {
                throw refuse('A child subquery reads FROM one child relationship of ' + parentName + ', such as (SELECT LastName FROM Contacts).');
            }
            String relationshipName = relationshipTokens[0].text;
            for (Schema.ChildRelationship child : parentType.getDescribe().getChildRelationships()) {
                if (child.getRelationshipName() != null && child.getRelationshipName().equalsIgnoreCase(relationshipName)) {
                    Schema.SObjectType childType = child.getChildSObject();
                    if (StandardToolSupport.isCoreObject(childType.getDescribe().getName())) {
                        throw refuse('Agent Core records cannot be read through ' + relationshipName + '.');
                    }
                    return childType;
                }
            }
            throw refuse(relationshipName + ' is not a child relationship of ' + parentName + '.');
        }

        private void readSelect(List<Token> selectList, Schema.SObjectType objectType, String kind) {
            Boolean expectField = true;
            Integer index = 0;
            while (index < selectList.size()) {
                Token token = selectList[index];
                Token next = index + 1 < selectList.size() ? selectList[index + 1] : null;
                if (!expectField) {
                    if (token.kind != ',') {
                        throw refuse(
                            'SELECT lists fields separated by commas, without aliases, because Core returns values only under field names. Check near ' +
                                token.text +
                                '.'
                        );
                    }
                    expectField = true;
                    index++;
                    continue;
                }
                if (token.kind == '(' && next != null && next.isWord('SELECT') && kind != FILTER_QUERY) {
                    Integer close = closing(selectList, index);
                    readQuery(slice(selectList, index + 1, close), CHILD_QUERY, objectType);
                    index = close + 1;
                } else if (token.isWord('TYPEOF')) {
                    index = readTypeof(selectList, index, objectType);
                } else if (token.kind == 'word' && next != null && next.kind == '(') {
                    index = readFunction(selectList, index, objectType, kind);
                } else if (token.kind == 'bind') {
                    throw refuse('Use :' + token.text + ' only in WHERE, compared to a field, or as the number in LIMIT or OFFSET.');
                } else if (token.kind == 'word') {
                    FieldRef ref = resolve(token.text, objectType);
                    if (kind != FILTER_QUERY) {
                        query.selected.add(ref);
                    }
                    index++;
                } else {
                    throw refuse('SELECT lists fields separated by commas. Check near ' + token.text + '.');
                }
                expectField = false;
            }
            if (expectField) {
                throw refuse('SELECT must list at least one field, with no trailing comma.');
            }
        }

        /** toLabel(), FORMAT(), or convertCurrency() around one field or another of these, such as FORMAT(convertCurrency(Amount)). Returns the index after it. */
        private Integer readFunction(List<Token> selectList, Integer index, Schema.SObjectType objectType, String kind) {
            Token function = selectList[index];
            if (AGGREGATES.contains(function.upper)) {
                throw refuse('Query Records returns records, not totals, so ' + function.upper + '() is not supported. Use a Run Report tool for totals.');
            }
            if (!SELECT_FUNCTIONS.contains(function.upper)) {
                throw refuse('SELECT can use toLabel(), FORMAT(), and convertCurrency(), not ' + function.text + '().');
            }
            Integer close = closing(selectList, index + 1);
            List<Token> argument = slice(selectList, index + 2, close);
            if (argument.size() == 1 && argument[0].kind == 'word') {
                FieldRef ref = resolve(argument[0].text, objectType);
                if (kind != FILTER_QUERY) {
                    query.selected.add(ref);
                }
            } else if (argument.size() > 1 && argument[0].kind == 'word' && argument[1].kind == '(' && closing(argument, 1) == argument.size() - 1) {
                readFunction(argument, 0, objectType, kind);
            } else {
                throw refuse(function.text + '() takes one field, such as ' + function.text + '(Amount).');
            }
            return close + 1;
        }

        /**
         * TYPEOF What WHEN Account THEN Name, Phone ELSE Name END. Each WHEN
         * object's fields are read like any other; the ELSE fields belong to
         * whichever object the record is. Returns the index after END.
         */
        private Integer readTypeof(List<Token> selectList, Integer index, Schema.SObjectType objectType) {
            Token relationship = index + 1 < selectList.size() ? selectList[index + 1] : null;
            Schema.DescribeFieldResult lookup = relationship == null ? null : relationships(objectType).get(relationship.upper.toLowerCase());
            if (lookup == null) {
                throw refuse('TYPEOF names a lookup of ' + objectType.getDescribe().getName() + ', such as TYPEOF What.');
            }
            refuseCoreTargets(lookup, relationship.text);
            Schema.SObjectType whenType;
            Boolean inElse = false;
            index += 2;
            while (index < selectList.size() && !selectList[index].isWord('END')) {
                Token token = selectList[index];
                if (token.isWord('WHEN') && index + 2 < selectList.size() && selectList[index + 2].isWord('THEN')) {
                    whenType = target(lookup, selectList[index + 1].text);
                    if (whenType == null) {
                        throw refuse(selectList[index + 1].text + ' is not an object ' + relationship.text + ' can point to.');
                    }
                    inElse = false;
                    index += 3;
                } else if (token.isWord('ELSE')) {
                    whenType = null;
                    inElse = true;
                    index++;
                } else if (token.kind == ',' && (whenType != null || inElse)) {
                    index++;
                } else if (token.kind == 'word' && (whenType != null || inElse)) {
                    if (whenType != null) {
                        query.selected.add(resolve(token.text, whenType));
                    }
                    index++;
                } else {
                    throw refuse('TYPEOF lists fields after WHEN Object THEN and after ELSE. Check near ' + token.text + '.');
                }
            }
            if (index >= selectList.size()) {
                throw refuse('TYPEOF must end with END.');
            }
            return index + 1;
        }

        private Schema.SObjectType target(Schema.DescribeFieldResult lookup, String objectName) {
            for (Schema.SObjectType candidate : lookup.getReferenceTo()) {
                if (candidate.getDescribe().getName().equalsIgnoreCase(objectName)) {
                    return candidate;
                }
            }
            return null;
        }

        private void refuseCoreTargets(Schema.DescribeFieldResult lookup, String path) {
            for (Schema.SObjectType candidate : lookup.getReferenceTo()) {
                if (StandardToolSupport.isCoreObject(candidate.getDescribe().getName())) {
                    throw refuse('Agent Core records cannot be read through ' + path + '.');
                }
            }
        }

        /** Binds anywhere in WHERE, including in filter subqueries, each typed from a field of the query it is in. */
        private void readWhere(List<Token> condition, Schema.SObjectType objectType, Boolean isOuter) {
            Boolean hasOrNot = false;
            Boolean comparesAnchor = false;
            Integer index = 0;
            while (index < condition.size()) {
                Token token = condition[index];
                if (token.kind == '(' && index + 1 < condition.size() && condition[index + 1].isWord('SELECT')) {
                    Integer close = closing(condition, index);
                    readQuery(slice(condition, index + 1, close), FILTER_QUERY, null);
                    index = close + 1;
                    continue;
                }
                if (token.isWord('OR') || token.isWord('NOT')) {
                    hasOrNot = true;
                }
                if (token.kind == 'bind') {
                    Bind bind = comparison(condition, index, objectType);
                    if (bind.isAnchor() && bind.operator == '=') {
                        comparesAnchor = true;
                    }
                    remember(bind);
                }
                index++;
            }
            if (isOuter) {
                query.scopedToAnchor = comparesAnchor && !hasOrNot;
            }
        }

        /**
         * Only WITH DATA CATEGORY. Core runs every query in user mode, and the
         * platform refuses an access level in WITH on top of that.
         */
        private void readWith(List<Token> withTokens) {
            String first = withTokens.isEmpty() ? '' : withTokens[0].upper;
            if (first == 'DATA' && withTokens.size() > 1 && withTokens[1].isWord('CATEGORY')) {
                return;
            }
            if (first == 'SYSTEM_MODE' || first == 'USER_MODE' || first == 'SECURITY_ENFORCED') {
                throw refuse('Remove WITH ' + first + '. Core always runs the query with the run user\'s access.');
            }
            throw refuse('WITH takes only DATA CATEGORY. Core always runs the query with the run user\'s access.');
        }

        /** The index of the parenthesis that closes the one at open. */
        private Integer closing(List<Token> items, Integer openIndex) {
            Integer depth = 0;
            for (Integer index = openIndex; index < items.size(); index++) {
                if (items[index].kind == '(') {
                    depth++;
                } else if (items[index].kind == ')') {
                    depth--;
                    if (depth == 0) {
                        return index;
                    }
                }
            }
            throw refuse('The query has an opening parenthesis that is never closed.');
        }

        private List<Token> slice(List<Token> items, Integer first, Integer stop) {
            List<Token> result = new List<Token>();
            for (Integer index = first; index < stop; index++) {
                result.add(items[index]);
            }
            return result;
        }

        /** The bind at index with the field and operator in front of it, as in Status = :status or Status NOT IN :statuses. */
        private Bind comparison(List<Token> condition, Integer index, Schema.SObjectType objectType) {
            String name = condition[index].text;
            Token previous = index > 0 ? condition[index - 1] : null;
            Integer fieldIndex = index - 2;
            String operator;
            if (previous != null && previous.kind == 'op') {
                operator = previous.text;
            } else if (previous != null && previous.kind == 'word' && WORD_COMPARISONS.contains(previous.upper)) {
                operator = previous.upper;
                if (previous.upper == 'IN' && index > 1 && condition[index - 2].isWord('NOT')) {
                    operator = 'NOT IN';
                    fieldIndex = index - 3;
                }
            }
            Token fieldToken = fieldIndex >= 0 ? condition[fieldIndex] : null;
            if (operator == null || fieldToken == null || fieldToken.kind != 'word' || KEYWORDS.contains(fieldToken.upper)) {
                throw refuse('Compare :' + name + ' to a field, as in Status = :' + name + ' or Status IN :' + name + '.');
            }
            Bind bind = new Bind();
            bind.name = name;
            bind.operator = operator;
            bind.isList = LIST_OPERATORS.contains(operator);
            bind.field = resolve(fieldToken.text, objectType);
            if (bind.field.field == null) {
                throw refuse('Core cannot tell the type of ' + fieldToken.text + ', so compare :' + name + ' to a field of one object instead.');
            }
            if (bind.isAnchor()) {
                Schema.DisplayType type = bind.field.field.getType();
                if (bind.isList || (type != Schema.DisplayType.ID && type != Schema.DisplayType.REFERENCE)) {
                    throw refuse(
                        ':' + ANCHOR_BIND + ' is the run\'s record. Compare it with = to Id or a lookup field, such as AccountId = :' + ANCHOR_BIND + '.'
                    );
                }
            } else if (bind.isRunValue()) {
                String problem = bind.isList
                    ? ':' + name + ' is one value, so it cannot follow ' + operator + '.'
                    : ToolRunValues.fitProblem(ToolRunValues.canonical(name), bind.field.field, bind.field.ownerType);
                if (problem != null) {
                    throw refuse(problem);
                }
            }
            return bind;
        }

        private void remember(Bind bind) {
            String key = bind.name.toLowerCase();
            Bind existing = bindsByName.get(key);
            if (existing == null) {
                bindsByName.put(key, bind);
                return;
            }
            if (existing.isCount() || bind.isCount()) {
                if (existing.isCount() != bind.isCount()) {
                    throw refuse(':' + bind.name + ' is used both as a field value and as a LIMIT or OFFSET. Use a separate bind for each.');
                }
                return;
            }
            if (existing.isList != bind.isList || existing.field.field.getType() != bind.field.field.getType()) {
                throw refuse(':' + bind.name + ' is compared to fields of different types. Use a separate bind for each.');
            }
        }

        private void readOrder(List<Token> orderTokens, Schema.SObjectType objectType) {
            if (orderTokens.isEmpty() || !orderTokens[0].isWord('BY')) {
                throw refuse('Write ORDER BY followed by field names.');
            }
            Boolean expectField = true;
            for (Integer index = 1; index < orderTokens.size(); index++) {
                Token token = orderTokens[index];
                if (expectField && token.kind == 'word') {
                    query.ordered.add(resolve(token.text, objectType));
                    expectField = false;
                } else if (!expectField && token.kind == 'word' && new Set<String>{ 'ASC', 'DESC', 'NULLS', 'FIRST', 'LAST' }.contains(token.upper)) {
                    continue;
                } else if (!expectField && token.kind == ',') {
                    expectField = true;
                } else if (token.kind == 'bind') {
                    throw refuse('Use :' + token.text + ' only in WHERE, compared to a field.');
                } else {
                    throw refuse('ORDER BY lists field names, each with optional ASC, DESC, and NULLS FIRST or LAST. Check near ' + token.text + '.');
                }
            }
            if (expectField) {
                throw refuse('ORDER BY must list at least one field, with no trailing comma.');
            }
        }

        /** LIMIT or OFFSET: a whole number, or one :name the agent fills in. */
        private void readCount(String clause, List<Token> countTokens) {
            if (countTokens.size() == 1 && countTokens[0].kind == 'number' && countTokens[0].text.isNumeric()) {
                return;
            }
            if (countTokens.size() == 1 && countTokens[0].kind == 'bind') {
                Bind bind = new Bind();
                bind.name = countTokens[0].text;
                bind.operator = clause;
                bind.isList = false;
                if (bind.isRunValue()) {
                    throw refuse(':' + bind.name + ' is filled in by Core, not a number. Use another name in ' + clause + '.');
                }
                remember(bind);
                return;
            }
            throw refuse(clause + ' takes a whole number or one :name, such as ' + clause + ' 10.');
        }

        /**
         * Resolves a field path through parent relationships. A lookup to many
         * objects, such as What, may only be the last step; Core then checks
         * the records the query returns instead of the field.
         */
        private FieldRef resolve(String path, Schema.SObjectType objectType) {
            List<String> segments = path.split('\\.');
            String fieldName = segments[segments.size() - 1].toLowerCase();
            Schema.SObjectType current = objectType;
            for (Integer index = 0; index < segments.size() - 1; index++) {
                Schema.DescribeFieldResult lookup = relationships(current).get(segments[index].toLowerCase());
                String objectName = current.getDescribe().getName();
                if (lookup == null) {
                    throw refuse(segments[index] + ' in ' + path + ' is not a parent relationship of ' + objectName + '.');
                }
                refuseCoreTargets(lookup, path);
                if (lookup.getReferenceTo().size() != 1) {
                    if (index != segments.size() - 2) {
                        throw refuse(
                            segments[index] +
                                ' in ' +
                                path +
                                ' can point to more than one object, so Core cannot follow it further. Use TYPEOF ' +
                                segments[index] +
                                ' instead.'
                        );
                    }
                    return polymorphicField(path, lookup, fieldName);
                }
                current = lookup.getReferenceTo()[0];
            }
            Schema.SObjectField field = fields(current).get(fieldName);
            if (field == null) {
                throw refuse('Field ' + path + ' does not exist on ' + current.getDescribe().getName() + '.');
            }
            FieldRef ref = new FieldRef();
            ref.path = path;
            ref.ownerType = current;
            ref.field = field.getDescribe();
            return ref;
        }

        /** A field such as What.Name, typed from the first object the lookup can point to that has it; the platform checks the rest at save. */
        private FieldRef polymorphicField(String path, Schema.DescribeFieldResult lookup, String fieldName) {
            FieldRef ref = new FieldRef();
            ref.path = path;
            ref.polymorphic = true;
            for (Schema.SObjectType candidate : lookup.getReferenceTo()) {
                Schema.SObjectField field = fields(candidate).get(fieldName);
                if (field != null) {
                    ref.ownerType = candidate;
                    ref.field = field.getDescribe();
                    break;
                }
            }
            return ref;
        }

        private Map<String, Schema.SObjectField> fields(Schema.SObjectType objectType) {
            if (!fieldsByType.containsKey(objectType)) {
                fieldsByType.put(objectType, StandardToolSupport.fieldMap(objectType));
            }
            return fieldsByType.get(objectType);
        }

        private Map<String, Schema.DescribeFieldResult> relationships(Schema.SObjectType objectType) {
            if (!relationshipsByType.containsKey(objectType)) {
                Map<String, Schema.DescribeFieldResult> byName = new Map<String, Schema.DescribeFieldResult>();
                for (Schema.SObjectField field : fields(objectType).values()) {
                    Schema.DescribeFieldResult describe = field.getDescribe();
                    if (describe.getType() == Schema.DisplayType.REFERENCE && !String.isBlank(describe.getRelationshipName())) {
                        byName.put(describe.getRelationshipName().toLowerCase(), describe);
                    }
                }
                relationshipsByType.put(objectType, byName);
            }
            return relationshipsByType.get(objectType);
        }

        private AgentKernelException.PermanentException refuse(String message) {
            return StandardToolSupport.permanent(message);
        }
    }
}
