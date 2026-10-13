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

import { createElement } from 'lwc';
import ToolQueryEditor from 'c/toolQueryEditor';
import getFieldOptions from '@salesforce/apex/ToolAuthoringController.getFieldOptions';
import searchStandardTargetSObjects from '@salesforce/apex/ToolAuthoringController.searchStandardTargetSObjects';
import getChildRelationshipOptions from '@salesforce/apex/ToolAuthoringController.getChildRelationshipOptions';

jest.mock('@salesforce/apex/ToolAuthoringController.getFieldOptions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.searchStandardTargetSObjects', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ToolAuthoringController.getChildRelationshipOptions', () => ({ default: jest.fn() }), { virtual: true });

const CASE_FIELDS = [
    { value: 'AccountId', label: 'Account ID', dataType: 'REFERENCE', referenceTo: 'Account', relationshipName: 'Account' },
    { value: 'Status', label: 'Status', dataType: 'PICKLIST', isPicklist: true, picklistValues: [{ value: 'New', label: 'New' }] }
];

async function type(element, text) {
    const textarea = element.shadowRoot.querySelector('textarea');
    textarea.value = text;
    textarea.setSelectionRange(text.length, text.length);
    textarea.dispatchEvent(new CustomEvent('input'));
    await flush();
    return textarea;
}

function shownSuggestions(element) {
    return [...element.shadowRoot.querySelectorAll('[role="option"] .query-option-value')].map((node) => node.textContent);
}

async function flush() {
    await new Promise((resolve) => setTimeout(resolve, 0));
    await Promise.resolve();
}

function createEditor() {
    return createElement('c-tool-query-editor', { is: ToolQueryEditor });
}

describe('c-tool-query-editor', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('shows the query the page gives it', async () => {
        const element = createEditor();
        element.value = 'SELECT Name FROM Account WHERE Type = :type LIMIT 5';
        document.body.appendChild(element);
        await flush();

        expect(element.shadowRoot.querySelector('textarea').value).toBe('SELECT Name FROM Account WHERE Type = :type LIMIT 5');
    });

    it('tells the page the query on each edit, so the inputs follow it', async () => {
        const element = createEditor();
        const changed = jest.fn();
        element.addEventListener('querychange', changed);
        document.body.appendChild(element);
        await flush();
        expect(changed).not.toHaveBeenCalled();

        const textarea = element.shadowRoot.querySelector('textarea');
        textarea.value = 'SELECT Subject FROM Case WHERE Status IN :statuses LIMIT 10';
        textarea.dispatchEvent(new CustomEvent('input'));

        expect(changed).toHaveBeenCalledTimes(1);
        expect(changed.mock.calls[0][0].detail.value).toBe('SELECT Subject FROM Case WHERE Status IN :statuses LIMIT 10');
    });

    describe('suggestions', () => {
        beforeEach(() => {
            getFieldOptions.mockImplementation(({ objectApiName }) => Promise.resolve(objectApiName === 'Case' ? CASE_FIELDS : []));
        });

        it('offers fields of the FROM object, loads them once, and Tab inserts the highlighted one', async () => {
            const element = createEditor();
            const changed = jest.fn();
            element.addEventListener('querychange', changed);
            document.body.appendChild(element);
            await flush();

            const textarea = await type(element, 'SELECT Id FROM Case WHERE Acc');
            expect(shownSuggestions(element)).toEqual(['AccountId', 'Account.']);
            expect(textarea.getAttribute('aria-activedescendant')).toBeTruthy();

            textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', cancelable: true }));
            await flush();
            expect(textarea.value).toBe('SELECT Id FROM Case WHERE AccountId ');
            expect(element.value.trim()).toBe('SELECT Id FROM Case WHERE AccountId');
            expect(changed).toHaveBeenCalledTimes(2);

            await type(element, 'SELECT Id FROM Case WHERE AccountId = ');
            expect(shownSuggestions(element)).toEqual([':anchorId', ':accountId', 'NULL']);
            expect(getFieldOptions).toHaveBeenCalledTimes(1);
        });

        it('opens the list under the word being typed, not under the query box', async () => {
            const offsetTop = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetTop');
            const offsetLeft = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetLeft');
            Object.defineProperty(HTMLSpanElement.prototype, 'offsetTop', { configurable: true, get: () => 60 });
            Object.defineProperty(HTMLSpanElement.prototype, 'offsetLeft', { configurable: true, get: () => 900 });
            try {
                const element = createEditor();
                document.body.appendChild(element);
                await flush();
                const textarea = element.shadowRoot.querySelector('textarea');
                textarea.style.lineHeight = '20px';
                textarea.style.borderWidth = '0px';
                Object.defineProperty(textarea, 'offsetHeight', { configurable: true, value: 200 });
                Object.defineProperty(textarea, 'offsetWidth', { configurable: true, value: 800 });
                await type(element, 'SELECT Id FROM Case WHERE Acc');

                const style = element.shadowRoot.querySelector('[role="listbox"]').getAttribute('style');
                expect(style).toContain('top: 80px');
                expect(style).toContain('left: 416px');
            } finally {
                delete HTMLSpanElement.prototype.offsetTop;
                delete HTMLSpanElement.prototype.offsetLeft;
                Object.defineProperty(HTMLElement.prototype, 'offsetTop', offsetTop);
                Object.defineProperty(HTMLElement.prototype, 'offsetLeft', offsetLeft);
            }
        });

        it('inserts the highlighted suggestion on Enter, leaves Shift+Enter for new lines, and Esc closes the list', async () => {
            const element = createEditor();
            document.body.appendChild(element);
            await flush();
            let textarea = await type(element, 'SELECT Id FROM Case WHERE Status = ');

            const shiftEnter = new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true, cancelable: true });
            textarea.dispatchEvent(shiftEnter);
            expect(shiftEnter.defaultPrevented).toBe(false);

            textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', cancelable: true }));
            await flush();
            expect(textarea.value).toBe('SELECT Id FROM Case WHERE Status = :status ');

            textarea = await type(element, 'SELECT Id FROM Case WHERE Status = ');
            textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', cancelable: true }));
            await flush();
            textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', cancelable: true }));
            await flush();
            expect(textarea.value).toBe("SELECT Id FROM Case WHERE Status = 'New' ");

            textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', cancelable: true }));
            await flush();
            expect(element.shadowRoot.querySelector('[role="listbox"]')).toBeNull();
        });

        it('searches objects after FROM once the admin pauses, asking only for Query Records objects', async () => {
            jest.useFakeTimers();
            try {
                searchStandardTargetSObjects.mockResolvedValue([{ value: 'Case', label: 'Case • Case' }]);
                const element = createEditor();
                document.body.appendChild(element);
                for (let tick = 0; tick < 5; tick++) {
                    await Promise.resolve();
                }
                const textarea = element.shadowRoot.querySelector('textarea');
                textarea.value = 'SELECT Id FROM Ca';
                textarea.dispatchEvent(new CustomEvent('input'));
                textarea.value = 'SELECT Id FROM Cas';
                textarea.dispatchEvent(new CustomEvent('input'));
                await Promise.resolve();
                jest.advanceTimersByTime(250);
                for (let tick = 0; tick < 5; tick++) {
                    await Promise.resolve();
                }

                expect(searchStandardTargetSObjects).toHaveBeenCalledTimes(1);
                expect(searchStandardTargetSObjects).toHaveBeenCalledWith({ term: 'Cas', operation: 'QueryRecords' });
                expect(shownSuggestions(element)).toEqual(['Case']);
            } finally {
                jest.useRealTimers();
            }
        });

        it('tells the admin when an object is unknown or they cannot read it, instead of listing its fields', async () => {
            const element = createEditor();
            document.body.appendChild(element);
            await flush();
            await type(element, 'SELECT Id, Na FROM Secret__c');

            expect(shownSuggestions(element)).toEqual([]);
            const textarea = element.shadowRoot.querySelector('textarea');
            textarea.setSelectionRange(13, 13);
            textarea.dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(element.shadowRoot.querySelector('.query-suggestion-message').textContent).toBe(
                'Pluto cannot find the object Secret__c, or you cannot read it.'
            );
        });

        it('suggests child relationships and the child object fields inside a child subquery', async () => {
            getChildRelationshipOptions.mockResolvedValue([{ value: 'Cases', label: 'Case' }]);
            getFieldOptions.mockImplementation(({ objectApiName }) => Promise.resolve(objectApiName === 'Case' ? CASE_FIELDS : []));
            const element = createEditor();
            document.body.appendChild(element);
            await flush();

            const textarea = await type(element, 'SELECT Id, (SELECT Id FROM Ca) FROM Account');
            textarea.setSelectionRange(29, 29);
            textarea.dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(shownSuggestions(element)).toEqual(['Cases']);
            expect(getChildRelationshipOptions).toHaveBeenCalledWith({ objectApiName: 'Account' });

            textarea.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', cancelable: true }));
            await flush();
            expect(textarea.value).toBe('SELECT Id, (SELECT Id FROM Cases) FROM Account');

            textarea.setSelectionRange(19, 19);
            textarea.dispatchEvent(new CustomEvent('click'));
            await flush();
            expect(shownSuggestions(element)).toEqual(expect.arrayContaining(['AccountId', 'Status']));
        });

        it('shows no suggestions while the editor is read-only', async () => {
            const element = createEditor();
            element.disabled = true;
            document.body.appendChild(element);
            await flush();
            await type(element, 'SELECT Id FROM Case WHERE ');

            expect(element.shadowRoot.querySelector('[role="listbox"]')).toBeNull();
            expect(getFieldOptions).not.toHaveBeenCalled();
        });
    });
});
