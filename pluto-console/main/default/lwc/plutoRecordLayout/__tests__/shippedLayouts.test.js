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

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '../../../../../..');

// The fields each Pluto record page shows come from these shipped layouts.
const LAYOUTS = [
    {
        file: 'force-app/main/default/layouts/AgentDefinition__c-Agent Definition Layout.layout-meta.xml',
        fields: [
            'Name',
            'DeveloperName__c',
            'Instructions__c',
            'Model__c',
            'ExecutionIdentity__c',
            'ReplyWindowHours__c',
            'OutputSchema__c',
            'AllowMultipleToolCalls__c',
            'MaxModelCalls__c',
            'MaxToolCalls__c',
            'MaxTotalTokens__c',
            'ModelTimeoutSeconds__c',
            'MaxRetries__c',
            'MaxModelRequestCharacters__c',
            'TranscriptTurnLimit__c',
            'ToolAuthorizationPolicyClass__c',
            'IsActive__c'
        ],
        oneColumn: ['Instructions__c', 'OutputSchema__c']
    },
    {
        file: 'force-app/main/default/layouts/AgentTool__c-Agent Tool Layout.layout-meta.xml',
        fields: [
            'AgentDefinition__c',
            'Name',
            'DeveloperName__c',
            'Description__c',
            'AllowedSensitiveDataCategories__c',
            'ApprovalMode__c',
            'ApproverType__c',
            'ApproverUser__c',
            'ApproverQueue__c',
            'ApprovalTimeoutMinutes__c',
            'ApprovalExpiryAction__c',
            'ImplementationType__c',
            'ToolType__c',
            'SortOrder__c',
            'IsActive__c'
        ],
        oneColumn: ['Description__c']
    },
    {
        file: 'force-app/main/default/layouts/AgentContextProvider__c-Agent Context Provider Layout.layout-meta.xml',
        fields: [
            'AgentDefinition__c',
            'Name',
            'DeveloperName__c',
            'ImplementationType__c',
            'ContextSubject__c',
            'ObjectApiName__c',
            'FieldSetName__c',
            'ImplementationReference__c',
            'ImplementationConfiguration__c',
            'Description__c',
            'SortOrder__c',
            'IsActive__c'
        ],
        oneColumn: ['Description__c', 'ImplementationConfiguration__c']
    },
    {
        file: 'force-app/main/default/layouts/AgentExecutionIdentity__c-Agent Execution Identity Layout.layout-meta.xml',
        fields: ['Name', 'PrincipalUser__c', 'LoopbackNamedCredential__c', 'IsActive__c', 'VerifiedAt__c', 'VerificationResult__c']
    }
];

function sections(xml) {
    return [...xml.matchAll(/<layoutSections>([\s\S]*?)<\/layoutSections>/g)].map(([, body]) => ({
        style: body.match(/<style>([^<]+)<\/style>/)?.[1],
        fields: [...body.matchAll(/<field>([^<]+)<\/field>/g)].map(([, name]) => name)
    }));
}

describe('shipped page layouts', () => {
    it.each(LAYOUTS)('$file carries every field its Pluto record page shows', ({ file, fields, oneColumn = [] }) => {
        const layout = sections(fs.readFileSync(path.join(ROOT, file), 'utf8'));
        const placed = layout.flatMap((section) => section.fields);
        expect(fields.filter((name) => !placed.includes(name))).toEqual([]);
        expect(placed.length).toBe(new Set(placed).size);
        // Markdown and JSON editors need the full page width.
        oneColumn.forEach((name) => {
            expect(layout.find((section) => section.fields.includes(name)).style).toBe('OneColumn');
        });
    });
});

describe('Pluto installation on Core alone', () => {
    const metadata = path.join(ROOT, 'pluto-console/main/default');
    const coreObjects = new Set(fs.readdirSync(path.join(ROOT, 'force-app/main/default/objects')));
    const tabs = new Set([
        ...fs.readdirSync(path.join(ROOT, 'force-app/main/default/tabs')).map((file) => file.replace('.tab-meta.xml', '')),
        ...fs.readdirSync(path.join(metadata, 'tabs')).map((file) => file.replace('.tab-meta.xml', ''))
    ]);

    it('ships only Core object overrides and record pages', () => {
        expect(fs.readdirSync(path.join(metadata, 'objects')).filter((object) => !coreObjects.has(object))).toEqual([]);
        for (const file of fs.readdirSync(path.join(metadata, 'flexipages'))) {
            const xml = fs.readFileSync(path.join(metadata, 'flexipages', file), 'utf8');
            for (const [, object] of xml.matchAll(/<sobjectType>([^<]+)<\/sobjectType>/g)) {
                expect(coreObjects.has(object)).toBe(true);
            }
        }
    });

    it('assigns only available record pages and tabs in the app and permission set', () => {
        const app = fs.readFileSync(path.join(metadata, 'applications/Pluto.app-meta.xml'), 'utf8');
        const permissions = fs.readFileSync(path.join(metadata, 'permissionsets/PlutoAdmin.permissionset-meta.xml'), 'utf8');
        for (const [, object] of app.matchAll(/<pageOrSobjectType>([^<]+)<\/pageOrSobjectType>/g)) {
            expect(coreObjects.has(object)).toBe(true);
        }
        for (const [, page] of app.matchAll(/<content>([^<]+)<\/content>/g)) {
            expect(fs.existsSync(path.join(metadata, 'flexipages', `${page}.flexipage-meta.xml`))).toBe(true);
        }
        for (const [, tab] of (app + permissions).matchAll(/<tabs?>([^<]+)<\/tabs?>/g)) {
            expect(tabs.has(tab)).toBe(true);
        }
    });
});
