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
 * Suggestions for the Query Records query box, read from the text before the
 * caret. Only what Core accepts is offered, so never totals or GROUP BY.
 */

import { runValueOptions } from 'c/toolRunValues';

export const ANCHOR_BIND = 'anchorId';
export const QUERY_TOOL_TYPE = 'QueryRecords';
export const MIN_OBJECT_TERM = 2;
const MAX_SUGGESTIONS = 50;

const CLAUSES = new Set(['SELECT', 'FROM', 'WHERE', 'ORDER', 'LIMIT', 'OFFSET']);
const CONDITION_STARTS = new Set(['WHERE', 'AND', 'OR', 'NOT']);
const WORD_COMPARISONS = new Set(['LIKE', 'IN', 'INCLUDES', 'EXCLUDES']);
const LIST_OPERATORS = new Set(['IN', 'NOT IN', 'INCLUDES', 'EXCLUDES']);
const RESERVED = new Set([...CLAUSES, ...CONDITION_STARTS, ...WORD_COMPARISONS, 'BY', 'ASC', 'DESC', 'NULLS', 'FIRST', 'LAST']);
const OPERATORS = ['=', '!=', 'IN', 'NOT IN', 'LIKE', '<', '<=', '>', '>='];
/** A parameter for the number in LIMIT or OFFSET, so the agent can choose how many records to read. */
const COUNT_BINDS = { LIMIT: ':maxRecords', OFFSET: ':skipRecords' };
const DATE_LITERALS = ['TODAY', 'YESTERDAY', 'LAST_N_DAYS:30', 'NEXT_N_DAYS:30', 'THIS_WEEK', 'THIS_MONTH', 'LAST_MONTH', 'THIS_QUARTER', 'THIS_YEAR'];
const TOKEN = /'[^']*'?|<=|>=|!=|<>|[=<>(),]|:[A-Za-z_][A-Za-z0-9_]*|[A-Za-z0-9_.][A-Za-z0-9_.:]*/g;

/** Replaces the inside of each quoted string with underscores, keeping positions, and finds the string holding the caret. */
function maskStrings(query, caret) {
    let masked = '';
    let quoteStart = null;
    let index = 0;
    while (index < query.length) {
        if (query[index] !== "'") {
            masked += query[index];
            index++;
            continue;
        }
        const start = index;
        masked += "'";
        index++;
        while (index < query.length && query[index] !== "'") {
            const escaped = query[index] === '\\' && index + 1 < query.length;
            masked += escaped ? '__' : '_';
            index += escaped ? 2 : 1;
        }
        const closed = index < query.length;
        if (closed) {
            masked += "'";
            index++;
        }
        if (start < caret && (!closed || caret < index)) {
            quoteStart = start;
        }
    }
    return { masked, quoteStart };
}

function tokenize(text) {
    return (text.match(TOKEN) || []).map((text) => {
        let kind = 'word';
        if (text.startsWith("'")) {
            kind = 'string';
        } else if (text.startsWith(':')) {
            kind = 'bind';
        } else if (text === '(' || text === ')' || text === ',') {
            kind = text;
        } else if (/^[=<>!]/.test(text)) {
            kind = 'op';
        }
        return { text, upper: text.toUpperCase(), kind };
    });
}

/** Folds each closed parenthesis group into one value token, so its words do not count as clauses of the outer query. */
function collapseGroups(tokens) {
    const flat = [];
    const opens = [];
    for (const token of tokens) {
        if (token.kind === '(') {
            opens.push(flat.length);
            flat.push(token);
        } else if (token.kind === ')') {
            if (opens.length) {
                flat.length = opens.pop();
            }
            flat.push({ text: ')', upper: ')', kind: 'group' });
        } else {
            flat.push(token);
        }
    }
    return flat;
}

function lastClause(tokens) {
    for (let index = tokens.length - 1; index >= 0; index--) {
        if (tokens[index].kind === 'word' && CLAUSES.has(tokens[index].upper)) {
            return tokens[index].upper;
        }
    }
    return null;
}

/** The end of the query that starts at start: its closing parenthesis, or the end of the text. */
function scopeClose(masked, start) {
    let depth = 0;
    for (let index = start; index < masked.length; index++) {
        if (masked[index] === '(') {
            depth++;
        } else if (masked[index] === ')') {
            if (depth === 0) {
                return index;
            }
            depth--;
        }
    }
    return masked.length;
}

/** The name after FROM in the query that starts at start, such as Account, or Contacts in a child subquery. */
function fromName(masked, start) {
    const tokens = collapseGroups(tokenize(masked.slice(start, scopeClose(masked, start))));
    for (let index = 0; index < tokens.length - 1; index++) {
        if (tokens[index].upper === 'FROM' && tokens[index + 1].kind === 'word') {
            return tokens[index + 1].text;
        }
    }
    return null;
}

/**
 * The queries that hold the caret, outermost first. A subquery opened in
 * SELECT is a child subquery, whose FROM names a child relationship of the
 * query around it; one opened in WHERE names an object of its own.
 */
function scopesAt(masked, end) {
    const opens = [];
    for (let index = 0; index < end; index++) {
        if (masked[index] === '(') {
            opens.push(index);
        } else if (masked[index] === ')') {
            opens.pop();
        }
    }
    const scopes = [{ start: 0, isChild: false }];
    for (const open of opens) {
        if (/^\s*SELECT\b/i.test(masked.slice(open + 1, end))) {
            const around = scopes[scopes.length - 1];
            const clause = lastClause(collapseGroups(tokenize(masked.slice(around.start, open))));
            scopes.push({ start: open + 1, isChild: clause === 'SELECT' });
        }
    }
    return scopes.map((scope) => ({ ...scope, from: fromName(masked, scope.start) }));
}

/** Reads what is being typed at the caret and where it sits in the query. */
export function readQueryContext(query, caret) {
    const text = query || '';
    const at = Math.max(0, Math.min(caret == null ? text.length : caret, text.length));
    const { masked, quoteStart } = maskStrings(text, at);
    let end;
    let term;
    let path = [];
    let bind = false;
    if (quoteStart != null) {
        end = quoteStart;
        term = text.slice(quoteStart + 1, at);
    } else {
        const word = /(?:[A-Za-z0-9_]+\.)*[A-Za-z0-9_]*$/.exec(masked.slice(0, at))[0];
        path = word.split('.');
        term = path.pop();
        end = at - word.length;
        if (masked[end - 1] === ':') {
            if (path.length) {
                return null;
            }
            bind = true;
            end--;
            term = ':' + term;
        }
    }
    const scopes = scopesAt(masked, end);
    const scope = scopes[scopes.length - 1];
    const tokens = collapseGroups(tokenize(masked.slice(scope.start, end)));
    let base = scopes.length - 1;
    while (base > 0 && scopes[base].isChild) {
        base--;
    }
    return {
        term,
        path,
        bind,
        inQuote: quoteStart != null,
        replaceFrom: at - term.length,
        replaceTo: at,
        tokens,
        clause: lastClause(tokens),
        objectName: scopes[base].from,
        childPath: scopes.slice(base + 1).map((child) => child.from),
        inChildQuery: scope.isChild
    };
}

/** The field and operator in front of the caret, as in Status = | or Status IN ('New', |. */
function comparisonAt(tokens) {
    let index = tokens.length - 1;
    let inList = false;
    if (index < 0) {
        return null;
    }
    if (tokens[index].kind === ',' || tokens[index].kind === '(') {
        while (index >= 0 && tokens[index].kind !== '(') {
            index--;
        }
        if (index < 1 || !LIST_OPERATORS.has(tokens[index - 1].upper)) {
            return null;
        }
        inList = true;
        index--;
    }
    const token = tokens[index];
    if (token.kind !== 'op' && !(token.kind === 'word' && WORD_COMPARISONS.has(token.upper))) {
        return null;
    }
    let operator = token.kind === 'op' ? token.text : token.upper;
    let fieldIndex = index - 1;
    if (operator === 'IN' && tokens[index - 1] && tokens[index - 1].upper === 'NOT') {
        operator = 'NOT IN';
        fieldIndex--;
    }
    const field = tokens[fieldIndex];
    if (!field || field.kind !== 'word' || RESERVED.has(field.upper)) {
        return null;
    }
    return { field: field.text, operator, inList };
}

/** What kind of text belongs at the caret. */
function placeOf(context) {
    const tokens = context.tokens;
    const previous = tokens[tokens.length - 1];
    const before = tokens[tokens.length - 2];
    const count = COUNT_BINDS[context.clause];
    if (count && previous.upper === context.clause && !context.inQuote) {
        return { kind: 'keyword', words: [count] };
    }
    if (context.inQuote || context.bind) {
        const comparison = context.clause === 'WHERE' ? comparisonAt(tokens) : null;
        return comparison ? { kind: 'value', ...comparison } : { kind: 'none' };
    }
    switch (context.clause) {
        case null:
            return tokens.length ? { kind: 'none' } : { kind: 'keyword', words: ['SELECT'] };
        case 'SELECT':
            if (previous.upper === 'SELECT' || previous.kind === ',') {
                return { kind: 'field' };
            }
            return previous.kind === 'word' ? { kind: 'keyword', words: ['FROM'] } : { kind: 'none' };
        case 'FROM':
            if (previous.upper === 'FROM') {
                return { kind: 'object' };
            }
            return previous.kind === 'word' && before && before.upper === 'FROM'
                ? { kind: 'keyword', words: ['WHERE', 'ORDER BY', 'LIMIT'] }
                : { kind: 'none' };
        case 'WHERE': {
            const comparison = comparisonAt(tokens);
            if (comparison) {
                return { kind: 'value', ...comparison };
            }
            if (CONDITION_STARTS.has(previous.upper) || previous.kind === '(') {
                return { kind: 'field' };
            }
            if (['string', 'bind', 'group'].includes(previous.kind) || comparisonAt(tokens.slice(0, -1))) {
                return { kind: 'keyword', words: ['AND', 'OR', 'ORDER BY', 'LIMIT'] };
            }
            return previous.kind === 'word' && !RESERVED.has(previous.upper) ? { kind: 'keyword', words: OPERATORS } : { kind: 'none' };
        }
        case 'ORDER':
            if (previous.upper === 'ORDER') {
                return { kind: 'keyword', words: ['BY'] };
            }
            if (previous.upper === 'BY' || previous.kind === ',') {
                return { kind: 'field' };
            }
            if (previous.upper === 'NULLS') {
                return { kind: 'keyword', words: ['FIRST', 'LAST'] };
            }
            if (previous.upper === 'FIRST' || previous.upper === 'LAST') {
                return { kind: 'keyword', words: ['LIMIT'] };
            }
            if (previous.upper === 'ASC' || previous.upper === 'DESC') {
                return { kind: 'keyword', words: ['NULLS FIRST', 'NULLS LAST', 'LIMIT'] };
            }
            return { kind: 'keyword', words: ['ASC', 'DESC', 'NULLS FIRST', 'NULLS LAST', 'LIMIT'] };
        case 'LIMIT':
            return { kind: 'keyword', words: ['OFFSET'] };
        default:
            return { kind: 'none' };
    }
}

/** The object a relationship path ends on, such as Account.Owner from Contact. */
function objectAlong(objectName, segments, fieldsOf) {
    let current = objectName;
    for (const segment of segments) {
        const fields = fieldsOf(current);
        if (fields === undefined) {
            return { needsObject: current };
        }
        const lookup = fields.find((field) => field.relationshipName && field.relationshipName.toLowerCase() === segment.toLowerCase());
        if (!lookup) {
            return { missing: true };
        }
        current = lookup.referenceTo;
    }
    return fieldsOf(current) === undefined ? { needsObject: current } : { objectName: current };
}

/** A parameter name for a field, such as status for Status, accountName for Account.Name, and statuses for Status IN. */
export function bindNameFor(fieldPath, isList) {
    const words = fieldPath
        .split('.')
        .map((segment) => segment.replace(/__(c|r)$/i, ''))
        .join('_')
        .split('_')
        .filter(Boolean);
    let name = words.map((word, index) => (index === 0 ? word.charAt(0).toLowerCase() + word.slice(1) : word.charAt(0).toUpperCase() + word.slice(1))).join('');
    if (!/^[A-Za-z]/.test(name)) {
        name = 'value' + name;
    }
    if (!isList) {
        return name;
    }
    if (/(s|x|ch|sh)$/i.test(name)) {
        return name + 'es';
    }
    return /[^aeiou]y$/i.test(name) ? name.slice(0, -1) + 'ies' : name + 's';
}

function fieldItems(fields) {
    const items = [];
    for (const field of [...fields].sort((left, right) => left.value.localeCompare(right.value))) {
        items.push({ value: field.value, label: field.value, detail: `${field.label} • ${field.dataType}` });
        if (field.relationshipName) {
            items.push({ value: field.relationshipName + '.', label: field.relationshipName + '.', detail: `${field.referenceTo} fields` });
        }
    }
    return items;
}

function valueItems(place, field, context) {
    const isList = LIST_OPERATORS.has(place.operator);
    const picklist = field && field.isPicklist ? field.picklistValues || [] : [];
    if (context.inQuote) {
        return picklist.map((choice) => ({ value: choice.value + "'", label: choice.value, detail: choice.label }));
    }
    if (place.inList) {
        return picklist.map((choice) => ({ value: quoted(choice.value), label: quoted(choice.value), detail: choice.label }));
    }
    const items = [];
    const type = field ? field.dataType : null;
    if (place.operator === '=' && (type === 'ID' || type === 'REFERENCE')) {
        items.push({ value: ':' + ANCHOR_BIND, label: ':' + ANCHOR_BIND, detail: "The run's record" });
    }
    if (!isList && type === 'REFERENCE') {
        runValueOptions(field)
            .filter((option) => option.value !== ':' + ANCHOR_BIND)
            .forEach((option) => items.push({ value: option.value, label: option.value, detail: option.subtitle }));
    }
    const name = bindNameFor(place.field, isList);
    items.push({ value: ':' + name, label: ':' + name, detail: isList ? 'New list parameter the agent fills in' : 'New parameter the agent fills in' });
    if (context.bind || isList || !field) {
        return items;
    }
    if (place.operator === '=' || place.operator === '!=') {
        picklist.forEach((choice) => items.push({ value: quoted(choice.value), label: quoted(choice.value), detail: choice.label }));
    }
    if (field.dataType === 'BOOLEAN') {
        items.push({ value: 'TRUE', label: 'TRUE', detail: '' }, { value: 'FALSE', label: 'FALSE', detail: '' });
    }
    if (field.dataType === 'DATE' || field.dataType === 'DATETIME') {
        DATE_LITERALS.forEach((literal) => items.push({ value: literal, label: literal, detail: 'Date literal' }));
    }
    if (place.operator === '=' || place.operator === '!=') {
        items.push({ value: 'NULL', label: 'NULL', detail: 'No value' });
    }
    return items;
}

function quoted(value) {
    return "'" + String(value).replace(/\\/g, '\\\\').replace(/'/g, "\\'") + "'";
}

/** Keeps items that match the typed text: exact first, then by prefix, then anywhere, each in their original order. */
export function rankSuggestions(items, term) {
    const needle = (term || '').toLowerCase();
    if (!needle) {
        return items.slice(0, MAX_SUGGESTIONS);
    }
    return items
        .map((item, index) => {
            const label = item.label.toLowerCase();
            const detail = (item.detail || '').toLowerCase();
            let rank = -1;
            if (label === needle) {
                rank = 0;
            } else if (label.startsWith(needle)) {
                rank = 1;
            } else if (detail.startsWith(needle)) {
                rank = 2;
            } else if (label.includes(needle) || detail.includes(needle)) {
                rank = 3;
            }
            return { item, index, rank };
        })
        .filter((entry) => entry.rank >= 0)
        .sort((left, right) => left.rank - right.rank || left.index - right.index)
        .map((entry) => entry.item)
        .slice(0, MAX_SUGGESTIONS);
}

/** The object a chain of child relationships ends on, such as Contact for Contacts from Account. */
function objectThroughChildren(objectName, relationships, childrenOf) {
    let current = objectName;
    for (const relationship of relationships) {
        const children = childrenOf(current);
        if (children === undefined) {
            return { needsChildren: current };
        }
        const child = relationship ? children.find((candidate) => candidate.value.toLowerCase() === relationship.toLowerCase()) : null;
        if (!child) {
            return { missing: relationship };
        }
        current = child.label;
    }
    return { objectName: current };
}

function childItems(children) {
    return [...children]
        .sort((left, right) => left.value.localeCompare(right.value))
        .map((child) => ({ value: child.value, label: child.value, detail: `${child.label} records` }));
}

/**
 * The suggestions for a context. fieldsOf(objectName) returns the fields of
 * an object, an empty list when the object is unknown, or undefined while it
 * is not loaded; childrenOf(objectName) does the same for its child
 * relationships, as { value: relationship, label: child object }. The result
 * names what to load or an object search to run when the suggestions need one.
 */
export function suggest(context, fieldsOf, childrenOf = () => []) {
    if (!context) {
        return { items: [] };
    }
    const place = placeOf(context);
    if (place.kind === 'keyword') {
        const items = place.words.map((word) => ({ value: word, label: word, detail: '' }));
        return { items: rankSuggestions(items, context.term) };
    }
    if (place.kind === 'object' && !context.inChildQuery) {
        return context.term.length >= MIN_OBJECT_TERM ? { searchObjects: context.term, items: [] } : { items: [] };
    }
    if (place.kind === 'none') {
        return { items: [], message: place.message };
    }
    if (!context.objectName) {
        return { items: [], message: 'Write FROM and an object to see its fields.' };
    }
    if (place.kind === 'object') {
        const parent = objectThroughChildren(context.objectName, context.childPath.slice(0, -1), childrenOf);
        if (parent.needsChildren || !parent.objectName) {
            return { needsChildren: parent.needsChildren, items: [] };
        }
        const children = childrenOf(parent.objectName);
        if (children === undefined) {
            return { needsChildren: parent.objectName, items: [] };
        }
        return { items: rankSuggestions(childItems(children), context.term) };
    }
    const scope = objectThroughChildren(context.objectName, context.childPath, childrenOf);
    if (scope.needsChildren) {
        return { needsChildren: scope.needsChildren, items: [] };
    }
    if (!scope.objectName) {
        return scope.missing
            ? { items: [], message: `${scope.missing} is not a child relationship Pluto can find, or you cannot read it.` }
            : { items: [], message: 'Write FROM and a child relationship, such as Contacts, to see its fields.' };
    }
    if (place.kind === 'field') {
        const found = objectAlong(scope.objectName, context.path, fieldsOf);
        if (found.needsObject) {
            return { needsObject: found.needsObject, items: [] };
        }
        if (found.missing) {
            return { items: [] };
        }
        const fields = fieldsOf(found.objectName);
        if (!fields.length) {
            return { items: [], message: `Pluto cannot find the object ${found.objectName}, or you cannot read it.` };
        }
        return { items: rankSuggestions(fieldItems(fields), context.term) };
    }
    const segments = place.field.split('.');
    const fieldName = segments.pop().toLowerCase();
    const found = objectAlong(scope.objectName, segments, fieldsOf);
    if (found.needsObject) {
        return { needsObject: found.needsObject, items: [] };
    }
    const field = found.objectName ? fieldsOf(found.objectName).find((candidate) => candidate.value.toLowerCase() === fieldName) : null;
    return { items: rankSuggestions(valueItems(place, field || null, context), context.term) };
}
