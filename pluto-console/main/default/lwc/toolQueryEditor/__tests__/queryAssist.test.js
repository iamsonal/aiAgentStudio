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

import { bindNameFor, rankSuggestions, readQueryContext, suggest } from '../queryAssist';

const FIELDS = {
    case: [
        { value: 'Id', label: 'Case ID', dataType: 'ID' },
        {
            value: 'Status',
            label: 'Status',
            dataType: 'PICKLIST',
            isPicklist: true,
            picklistValues: [
                { value: 'New', label: 'New' },
                { value: 'Closed', label: 'Closed' }
            ]
        },
        { value: 'AccountId', label: 'Account ID', dataType: 'REFERENCE', referenceTo: 'Account', relationshipName: 'Account' },
        { value: 'WhatId__c', label: 'Related', dataType: 'REFERENCE', referenceTo: 'Account' },
        { value: 'IsEscalated', label: 'Escalated', dataType: 'BOOLEAN' },
        { value: 'ClosedDate', label: 'Closed Date', dataType: 'DATETIME' }
    ],
    account: [
        { value: 'Name', label: 'Account Name', dataType: 'STRING' },
        { value: 'OwnerId', label: 'Owner ID', dataType: 'REFERENCE', referenceTo: 'User', relationshipName: 'Owner', pointsToUser: true }
    ],
    user: [{ value: 'Email', label: 'Email', dataType: 'EMAIL' }]
};
FIELDS.contact = [
    { value: 'LastName', label: 'Last Name', dataType: 'STRING' },
    { value: 'Email', label: 'Email', dataType: 'EMAIL' }
];
const CHILDREN = {
    account: [
        { value: 'Contacts', label: 'Contact' },
        { value: 'Cases', label: 'Case' }
    ],
    contact: [{ value: 'Cases', label: 'Case' }],
    case: []
};
const fieldsOf = (name) => FIELDS[String(name).toLowerCase()] || [];
const childrenOf = (name) => CHILDREN[String(name).toLowerCase()] || [];

function at(query) {
    const caret = query.indexOf('|');
    return suggest(readQueryContext(query.replace('|', ''), caret < 0 ? undefined : caret), fieldsOf, childrenOf);
}

function labels(result) {
    return result.items.map((item) => item.label);
}

describe('queryAssist', () => {
    it('starts with SELECT and offers the fields of the FROM object, even before FROM is typed', () => {
        expect(labels(at('SEL'))).toEqual(['SELECT']);
        expect(labels(at('SELECT Sta| FROM Case LIMIT 5'))).toEqual(['Status']);
        expect(labels(at('SELECT Id, | FROM Case'))).toContain('Account.');
        expect(labels(at('SELECT Id |FROM Case'))).toEqual(['FROM']);
    });

    it('asks to search for objects after FROM once two letters are typed', () => {
        expect(at('SELECT Id FROM C')).toEqual({ items: [] });
        expect(at('SELECT Id FROM Ca')).toEqual({ searchObjects: 'Ca', items: [] });
        expect(labels(at('SELECT Id FROM Case '))).toEqual(['WHERE', 'ORDER BY', 'LIMIT']);
    });

    it('follows parent paths only through one-object lookups, loading each object when first needed', () => {
        expect(labels(at('SELECT Account.Owner.E| FROM Case'))).toEqual(['Email']);
        expect(labels(at('SELECT WhatId__r.| FROM Case'))).toEqual([]);
        expect(suggest(readQueryContext('SELECT Account.N FROM Case', 16), (name) => (name === 'Case' ? FIELDS.case : undefined))).toEqual({
            needsObject: 'Account',
            items: []
        });
    });

    it('offers a parameter named after the field, :anchorId for lookups, and fixed values', () => {
        expect(labels(at('SELECT Id FROM Case WHERE AccountId = '))).toEqual([':anchorId', ':accountId', 'NULL']);
        expect(labels(at('SELECT Id FROM Account WHERE OwnerId = '))).toEqual([':anchorId', ':initiatingUserId', ':principalUserId', ':ownerId', 'NULL']);
        expect(labels(at('SELECT Id FROM Case WHERE Status IN '))).toEqual([':statuses']);
        expect(labels(at('SELECT Id FROM Case WHERE Status = '))).toEqual([':status', "'New'", "'Closed'", 'NULL']);
        expect(labels(at("SELECT Id FROM Case WHERE Status = 'Ne"))).toEqual(['New']);
        expect(labels(at("SELECT Id FROM Case WHERE Status IN ('New', "))).toEqual(["'New'", "'Closed'"]);
        expect(labels(at('SELECT Id FROM Case WHERE IsEscalated = '))).toEqual([':isEscalated', 'TRUE', 'FALSE', 'NULL']);
        expect(labels(at('SELECT Id FROM Case WHERE ClosedDate > LAST'))).toEqual(['LAST_N_DAYS:30', 'LAST_MONTH']);
        expect(labels(at('SELECT Id FROM Case WHERE Account.Name = :'))).toEqual([':accountName']);
    });

    it('reads a child subquery through its relationship: child relationships after FROM, then the child object fields', () => {
        expect(labels(at('SELECT Id, (SELECT Id FROM Con|) FROM Account WHERE AccountNumber = :accountNumber'))).toEqual(['Contacts']);
        expect(labels(at('SELECT Id, (SELECT Id FROM |) FROM Account'))).toEqual(['Cases', 'Contacts']);
        expect(labels(at('SELECT Id, (SELECT Id, Last| FROM Contacts) FROM Account WHERE AccountNumber = :accountNumber'))).toEqual(['LastName']);
        expect(labels(at('SELECT Id, (SELECT Id FROM Contacts WHERE LastName = |) FROM Account'))).toEqual([':lastName', 'NULL']);
        expect(labels(at('SELECT Id, (SELECT Id, (SELECT | FROM Cases) FROM Contacts) FROM Account'))).toContain('Status');
        expect(labels(at('SELECT Id, (SELECT Id FROM Contacts) FROM Account WHERE Na|'))).toEqual(['Name']);
        expect(at('SELECT Id, (SELECT | FROM Nope) FROM Account').message).toBe('Nope is not a child relationship Pluto can find, or you cannot read it.');
    });

    it('offers parameters inside a filter subquery, typed from its own object', () => {
        expect(labels(at('SELECT Id FROM Account WHERE Id IN (SELECT AccountId FROM Case WHERE Status = '))).toEqual([':status', "'New'", "'Closed'", 'NULL']);
        expect(labels(at('SELECT Id FROM Account WHERE Id IN (SELECT AccountId FROM Case) '))).toEqual(['AND', 'OR', 'ORDER BY', 'LIMIT']);
    });

    it('offers what comes next after a condition, in ORDER BY, and at LIMIT', () => {
        expect(labels(at('SELECT Id FROM Case WHERE Status = :status '))).toEqual(['AND', 'OR', 'ORDER BY', 'LIMIT']);
        expect(labels(at('SELECT Id FROM Case WHERE Status '))).toContain('NOT IN');
        expect(labels(at('SELECT Id FROM Case ORDER BY ClosedDate '))).toEqual(['ASC', 'DESC', 'NULLS FIRST', 'NULLS LAST', 'LIMIT']);
        expect(labels(at('SELECT Id FROM Case LIMIT '))).toEqual([':maxRecords']);
        expect(labels(at('SELECT Id FROM Case LIMIT :m'))).toEqual([':maxRecords']);
        expect(labels(at('SELECT Id FROM Case LIMIT 10 '))).toEqual(['OFFSET']);
        expect(labels(at('SELECT Id FROM Case LIMIT 10 OFFSET '))).toEqual([':skipRecords']);
    });

    it('names an object it cannot find or the user cannot read', () => {
        expect(at('SELECT | FROM Acount').message).toBe('Pluto cannot find the object Acount, or you cannot read it.');
        expect(at('SELECT | ').message).toBe('Write FROM and an object to see its fields.');
    });

    it('ignores quoted text that looks like a clause', () => {
        expect(labels(at("SELECT Id FROM Case WHERE Subject = 'FROM Account WHERE' "))).toEqual(['AND', 'OR', 'ORDER BY', 'LIMIT']);
    });

    it('names parameters in camel case and plural for lists', () => {
        expect(bindNameFor('Region__c', false)).toBe('region');
        expect(bindNameFor('Account.Billing_City__c', false)).toBe('accountBillingCity');
        expect(bindNameFor('Status', true)).toBe('statuses');
        expect(bindNameFor('Priority', true)).toBe('priorities');
        expect(bindNameFor('AccountId', true)).toBe('accountIds');
    });

    it('ranks exact, then prefix, then anywhere matches', () => {
        const items = ['MyStatus', 'Status__c', 'Status'].map((label) => ({ label, value: label }));
        expect(rankSuggestions(items, 'status').map((item) => item.label)).toEqual(['Status', 'Status__c', 'MyStatus']);
    });
});
