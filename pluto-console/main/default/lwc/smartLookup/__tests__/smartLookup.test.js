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
import SmartLookup from 'c/smartLookup';

if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = jest.fn();

async function flush() {
    await new Promise((r) => setTimeout(r, 0));
    await Promise.resolve();
}

async function tick(ms = 250) {
    await new Promise((r) => setTimeout(r, ms));
    await Promise.resolve();
}

function options() {
    return [
        { label: 'Acme Account', value: 'acc1', subtitle: 'Customer', icon: 'standard:account' },
        { label: 'Beta Account', value: 'acc2', subtitle: 'Partner' },
        { label: 'Gamma', value: 'g1' }
    ];
}

function createLookup(props = {}) {
    const element = createElement('c-smart-lookup', { is: SmartLookup });
    Object.assign(element, { label: 'Account', options: options(), ...props });
    document.body.appendChild(element);
    return element;
}

function inputOf(element) {
    return element.shadowRoot.querySelector('input');
}

function focusInput(element) {
    inputOf(element).dispatchEvent(new FocusEvent('focus'));
}

async function blurInput(element) {
    inputOf(element).dispatchEvent(new FocusEvent('blur'));
    await tick(200);
}

function typeInto(element, text) {
    const input = inputOf(element);
    input.value = text;
    input.dispatchEvent(new Event('input'));
}

function keyDown(element, key) {
    inputOf(element).dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }));
}

function optionValues(element) {
    return Array.from(element.shadowRoot.querySelectorAll('[role="option"]')).map((option) => option.dataset.value);
}

function clickOption(element, value) {
    const option = Array.from(element.shadowRoot.querySelectorAll('[role="option"]')).find((candidate) => candidate.dataset.value === value);
    expect(option).toBeTruthy();
    option.click();
}

function listbox(element) {
    return element.shadowRoot.querySelector('[role="listbox"]');
}

function help(element) {
    return element.shadowRoot.querySelector('.slds-form-element__help');
}

function recordChanges(element) {
    const changes = [];
    element.addEventListener('change', (event) => changes.push(event.detail));
    return changes;
}

afterEach(() => {
    while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
    jest.clearAllMocks();
});

describe('c-smart-lookup rendering', () => {
    it('renders the label, required marker and placeholder', async () => {
        const element = createLookup({ required: true, placeholder: 'Search accounts' });
        await flush();
        expect(element.shadowRoot.querySelector('label').textContent).toContain('Account');
        expect(element.shadowRoot.querySelector('abbr')).toBeTruthy();
        expect(inputOf(element).placeholder).toBe('Search accounts');
        expect(inputOf(element).getAttribute('role')).toBe('combobox');
    });

    it('hides the label for the label-hidden variant but keeps an accessible name', async () => {
        const element = createLookup({ variant: 'label-hidden' });
        await flush();
        expect(element.shadowRoot.querySelector('label')).toBeNull();
        expect(inputOf(element).getAttribute('aria-label')).toBe('Account');
    });

    it('shows a resolved selection as a read-only input with its icon and a clear button', async () => {
        const element = createLookup({ value: 'acc1' });
        await flush();
        expect(inputOf(element).value).toBe('Acme Account');
        expect(inputOf(element).readOnly).toBe(true);
        expect(element.shadowRoot.querySelector('.slds-combobox__input-entity-icon').iconName).toBe('standard:account');
        expect(element.shadowRoot.querySelector('button[title="Remove selected option"]')).toBeTruthy();
    });

    it('does not open the list when a selected lookup is focused', async () => {
        const element = createLookup({ value: 'acc1' });
        await flush();
        focusInput(element);
        await flush();
        expect(listbox(element)).toBeNull();
    });

    it('keeps an unknown stored value editable as text', async () => {
        const element = createLookup({ value: 'unknown' });
        await flush();
        expect(inputOf(element).value).toBe('unknown');
        expect(inputOf(element).readOnly).toBe(false);
    });

    it('disables the input and hides the clear button', async () => {
        const element = createLookup({ value: 'acc1', disabled: true });
        await flush();
        expect(inputOf(element).disabled).toBe(true);
        expect(element.shadowRoot.querySelector('button[title="Remove selected option"]')).toBeNull();
    });

    it('shows the label once options arrive after a value was set', async () => {
        const element = createLookup({ options: [], value: 'acc1' });
        await flush();
        expect(inputOf(element).value).toBe('acc1');
        element.setOptions(options());
        await flush();
        expect(inputOf(element).value).toBe('Acme Account');
    });

    it('tolerates non-array options and nullish values', async () => {
        const element = createLookup();
        await flush();
        element.options = 'not-an-array';
        element.value = null;
        await flush();
        expect(element.value).toBe('');
        expect(inputOf(element).value).toBe('');
    });
});

describe('c-smart-lookup search and selection', () => {
    it('opens on focus and filters by label, value and subtitle', async () => {
        const element = createLookup();
        await flush();
        focusInput(element);
        await flush();
        expect(optionValues(element)).toEqual(['acc1', 'acc2', 'g1']);
        expect(inputOf(element).getAttribute('aria-expanded')).toBe('true');
        typeInto(element, 'beta');
        await flush();
        expect(optionValues(element)).toEqual(['acc2']);
        typeInto(element, 'g1');
        await flush();
        expect(optionValues(element)).toEqual(['g1']);
        typeInto(element, 'partner');
        await flush();
        expect(optionValues(element)).toEqual(['acc2']);
    });

    it('stays closed on focus when there is nothing to show yet', async () => {
        const element = createLookup({ options: [] });
        await flush();
        focusInput(element);
        await flush();
        expect(listbox(element)).toBeNull();
    });

    it('debounces search events and fires only the latest term', async () => {
        const element = createLookup();
        const terms = [];
        element.addEventListener('search', (event) => terms.push(event.detail.searchTerm));
        await flush();
        focusInput(element);
        typeInto(element, 'a');
        await tick(100);
        typeInto(element, 'ac');
        await tick(300);
        expect(terms).toEqual(['ac']);
    });

    it('shows a no-results row that is not an option', async () => {
        const element = createLookup();
        await flush();
        focusInput(element);
        typeInto(element, 'zzz-no-match');
        await flush();
        expect(element.shadowRoot.querySelector('[data-id="no-results"]').textContent).toBe('No results found');
        expect(optionValues(element)).toEqual([]);
    });

    it('selects an option on click without firing change while typing', async () => {
        const element = createLookup();
        const changes = recordChanges(element);
        await flush();
        focusInput(element);
        typeInto(element, 'beta');
        await flush();
        expect(changes).toEqual([]);
        clickOption(element, 'acc2');
        await flush();
        expect(changes).toEqual([{ value: 'acc2', label: 'Beta Account' }]);
        expect(element.value).toBe('acc2');
        expect(inputOf(element).value).toBe('Beta Account');
        expect(listbox(element)).toBeNull();
    });

    it('keeps focus in the input when the list is pressed', async () => {
        const element = createLookup();
        await flush();
        focusInput(element);
        await flush();
        const mouseDown = new MouseEvent('mousedown', { bubbles: true, cancelable: true });
        listbox(element).dispatchEvent(mouseDown);
        expect(mouseDown.defaultPrevented).toBe(true);
    });

    it('clears the selection through the clear button and reopens the list', async () => {
        const element = createLookup({ value: 'acc1' });
        const changes = recordChanges(element);
        await flush();
        element.shadowRoot.querySelector('button[title="Remove selected option"]').click();
        await flush();
        expect(changes).toEqual([{ value: '', label: '' }]);
        expect(element.value).toBe('');
        expect(inputOf(element).readOnly).toBe(false);
        expect(optionValues(element)).toEqual(['acc1', 'acc2', 'g1']);
    });

    it('supports free-text entry with a change on every keystroke', async () => {
        const element = createLookup({ allowFreeText: true });
        const changes = recordChanges(element);
        await flush();
        focusInput(element);
        typeInto(element, 'Custom Name');
        await flush();
        expect(changes).toEqual([{ value: 'Custom Name', label: 'Custom Name' }]);
        expect(element.value).toBe('Custom Name');
        expect(element.shadowRoot.querySelector('[data-id="no-results"]').textContent).toContain('Type any value');
    });

    it('does not replace free text with a matching label when the host echoes the value', async () => {
        const element = createLookup({ allowFreeText: true });
        await flush();
        focusInput(element);
        typeInto(element, 'acc1');
        element.value = 'acc1';
        element.setOptions(options());
        await flush();
        expect(inputOf(element).value).toBe('acc1');
    });

    it('keeps typed strict text when options refresh mid-edit', async () => {
        const element = createLookup();
        await flush();
        focusInput(element);
        typeInto(element, 'beta');
        await flush();
        element.setOptions(options());
        await flush();
        expect(inputOf(element).value).toBe('beta');
        expect(optionValues(element)).toEqual(['acc2']);
    });

    it('lets a host revert a declined choice by setting the value back', async () => {
        const element = createLookup({ value: 'acc1' });
        await flush();
        element.shadowRoot.querySelector('button[title="Remove selected option"]').click();
        await flush();
        clickOption(element, 'acc2');
        await flush();
        element.value = 'acc1';
        await flush();
        expect(inputOf(element).value).toBe('Acme Account');
    });

    it('announces result counts to screen readers', async () => {
        const element = createLookup();
        await flush();
        focusInput(element);
        await flush();
        expect(element.shadowRoot.querySelector('[aria-live="polite"]').textContent).toBe('3 results available');
    });
});

describe('c-smart-lookup keyboard', () => {
    it('moves the active option with arrows, wraps, and selects with Enter', async () => {
        const element = createLookup();
        const changes = recordChanges(element);
        await flush();
        focusInput(element);
        await flush();
        keyDown(element, 'ArrowUp');
        await flush();
        expect(element.shadowRoot.querySelector('.slds-has-focus').dataset.value).toBe('g1');
        keyDown(element, 'ArrowDown');
        await flush();
        const active = element.shadowRoot.querySelector('.slds-has-focus');
        expect(active.dataset.value).toBe('acc1');
        expect(inputOf(element).getAttribute('aria-activedescendant')).toBe(active.getAttribute('id'));
        keyDown(element, 'Enter');
        await flush();
        expect(changes).toEqual([{ value: 'acc1', label: 'Acme Account' }]);
    });

    it('opens a closed list with ArrowDown', async () => {
        const element = createLookup();
        await flush();
        keyDown(element, 'ArrowDown');
        await flush();
        expect(listbox(element)).not.toBeNull();
    });

    it('ignores Enter when no option is active', async () => {
        const element = createLookup();
        const changes = recordChanges(element);
        await flush();
        focusInput(element);
        await flush();
        keyDown(element, 'Enter');
        await flush();
        expect(changes).toEqual([]);
    });

    it('closes on Escape and restores the current value', async () => {
        const element = createLookup({ value: 'unknown' });
        await flush();
        focusInput(element);
        typeInto(element, 'zzz');
        await flush();
        keyDown(element, 'Escape');
        await flush();
        expect(listbox(element)).toBeNull();
        expect(inputOf(element).value).toBe('unknown');
    });

    it('keeps free text on Escape and only closes the list', async () => {
        const element = createLookup({ allowFreeText: true });
        await flush();
        focusInput(element);
        typeInto(element, 'Custom Thing');
        await flush();
        keyDown(element, 'Escape');
        await flush();
        expect(listbox(element)).toBeNull();
        expect(element.value).toBe('Custom Thing');
    });

    it('clears a selection with Backspace', async () => {
        const element = createLookup({ value: 'acc1' });
        const changes = recordChanges(element);
        await flush();
        keyDown(element, 'Backspace');
        await flush();
        expect(changes).toEqual([{ value: '', label: '' }]);
    });
});

describe('c-smart-lookup blur', () => {
    it('clears the value when the admin empties the text and leaves', async () => {
        const element = createLookup({ value: 'unknown' });
        const changes = recordChanges(element);
        await flush();
        focusInput(element);
        typeInto(element, '');
        await blurInput(element);
        expect(changes).toEqual([{ value: '', label: '' }]);
        expect(element.value).toBe('');
    });

    it('reverts unmatched strict text without a change', async () => {
        const element = createLookup({ value: 'unknown' });
        const changes = recordChanges(element);
        await flush();
        focusInput(element);
        typeInto(element, 'zzz-no-match');
        await blurInput(element);
        expect(changes).toEqual([]);
        expect(inputOf(element).value).toBe('unknown');
    });

    it('closes the list and fires no change when nothing was edited', async () => {
        const element = createLookup({ value: 'unknown' });
        const changes = recordChanges(element);
        await flush();
        focusInput(element);
        await blurInput(element);
        expect(changes).toEqual([]);
        expect(listbox(element)).toBeNull();
    });
});

describe('c-smart-lookup validity', () => {
    it('reports a missing required value inline with the SLDS error style, not a browser bubble', async () => {
        const element = createLookup({ required: true });
        await flush();
        const nativeReport = jest.spyOn(inputOf(element), 'reportValidity');

        expect(element.checkValidity()).toBe(false);
        expect(help(element)).toBeNull();
        expect(element.reportValidity()).toBe(false);
        await flush();

        expect(nativeReport).not.toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('.slds-form-element').classList).toContain('slds-has-error');
        expect(help(element).textContent).toBe('Complete this field.');
        expect(inputOf(element).getAttribute('aria-invalid')).toBe('true');
        expect(inputOf(element).getAttribute('aria-describedby')).toBe(help(element).getAttribute('id'));

        focusInput(element);
        await flush();
        clickOption(element, 'acc1');
        await flush();
        expect(element.shadowRoot.querySelector('.slds-has-error')).toBeNull();
        expect(help(element)).toBeNull();
    });

    it('shows the required error after the admin leaves an empty required lookup', async () => {
        const element = createLookup({ required: true });
        await flush();
        focusInput(element);
        await blurInput(element);
        expect(help(element).textContent).toBe('Complete this field.');
    });

    it('asks for a listed value when strict text was typed but not chosen', async () => {
        const element = createLookup({ required: true });
        await flush();
        typeInto(element, 'zzz');
        expect(element.reportValidity()).toBe(false);
        await flush();
        expect(help(element).textContent).toBe('Select a value from the list.');
    });

    it('accepts a stored value before any search results load', async () => {
        const element = createLookup({ required: true, options: [], value: 'Account' });
        await flush();
        expect(element.reportValidity()).toBe(true);
    });

    it('requires free text until the admin types', async () => {
        const element = createLookup({ required: true, allowFreeText: true });
        await flush();
        expect(element.checkValidity()).toBe(false);
        typeInto(element, 'hello');
        await flush();
        expect(element.reportValidity()).toBe(true);
    });

    it('treats a disabled lookup as valid', async () => {
        const element = createLookup({ required: true, disabled: true });
        await flush();
        expect(element.reportValidity()).toBe(true);
    });

    it('shows a custom validity message, such as a server field error, and clears it', async () => {
        const element = createLookup({ value: 'acc1' });
        await flush();
        element.setCustomValidity('Object is not supported.');
        expect(element.reportValidity()).toBe(false);
        await flush();
        expect(help(element).textContent).toBe('Object is not supported.');

        element.setCustomValidity('');
        await flush();
        expect(help(element)).toBeNull();
        expect(element.checkValidity()).toBe(true);
    });

    it('coerces string booleans from attributes', async () => {
        const element = createLookup({ required: 'true', allowFreeText: 'true', disabled: 'false' });
        await flush();
        expect(inputOf(element).disabled).toBe(false);
        expect(element.checkValidity()).toBe(false);
        const bare = createLookup({ required: '' });
        await flush();
        expect(bare.required).toBe(true);
    });

    it('focuses its input', async () => {
        const element = createLookup();
        await flush();
        const focus = jest.spyOn(inputOf(element), 'focus');
        element.focus();
        expect(focus).toHaveBeenCalled();
    });
});
