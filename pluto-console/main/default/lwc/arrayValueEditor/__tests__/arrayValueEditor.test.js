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
import ArrayValueEditor from 'c/arrayValueEditor';

async function flush() {
    await new Promise((r) => setTimeout(r, 0));
    await Promise.resolve();
}

function makeElement(props = {}) {
    const el = createElement('c-array-value-editor', { is: ArrayValueEditor });
    Object.assign(el, { label: 'Array Values', helpText: 'Define values.', itemType: 'string', value: '[]' }, props);
    return el;
}

function listen(el) {
    const seen = [];
    el.addEventListener('arraychange', (e) => seen.push(e));
    return seen;
}

function buttons(el) {
    return Array.from(el.shadowRoot.querySelectorAll('lightning-button'));
}

function buttonIcons(el) {
    return Array.from(el.shadowRoot.querySelectorAll('lightning-button-icon'));
}

function findButton(el, label) {
    return buttons(el).find((b) => b.label === label);
}

describe('c-array-value-editor', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders label, help text and empty state without clear button', async () => {
        const el = makeElement();
        document.body.appendChild(el);
        await flush();
        const text = el.shadowRoot.textContent;
        expect(text).toContain('Array Values');
        expect(el.shadowRoot.querySelector('lightning-helptext').content).toBe('Define values.');
        expect(text).toContain('No items yet');
        expect(el.shadowRoot.querySelectorAll('li.slds-item')).toHaveLength(0);
        expect(findButton(el, 'Add Item')).toBeDefined();
        expect(findButton(el, 'Clear All')).toBeUndefined();
    });

    it('adds a string item defaulting to empty string', async () => {
        const el = makeElement({ value: '[]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        findButton(el, 'Add Item').click();
        expect(seen).toHaveLength(1);
        expect(seen[0].detail).toEqual({ value: '[""]' });
    });

    it('adds typed defaults for number, boolean and object', async () => {
        for (const [itemType, expected] of [
            ['number', '[0]'],
            ['integer', '[0]'],
            ['boolean', '[false]'],
            ['object', '[{}]'],
            ['date', '[""]']
        ]) {
            const el = makeElement({ itemType, value: '[]' });
            const seen = listen(el);
            document.body.appendChild(el);
            await flush();
            findButton(el, 'Add Item').click();
            expect(seen[0].detail).toEqual({ value: expected });
            document.body.removeChild(el);
        }
    });

    it('renders string rows and edits them through lightning-input', async () => {
        const el = makeElement({ value: '["a","b"]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const rows = el.shadowRoot.querySelectorAll('li.slds-item');
        expect(rows).toHaveLength(2);
        expect(rows[0].querySelector('.slds-badge').textContent).toBe('1');
        expect(findButton(el, 'Clear All')).toBeDefined();
        const first = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.dataset.index === '0');
        expect(first.value).toBe('a');
        first.value = 'z';
        first.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '["z","b"]' });
    });

    it('edits string rows through smart-lookup when field options exist', async () => {
        const fields = [{ label: 'Name', value: 'Name' }];
        const el = makeElement({ value: '["a"]', availableFields: fields });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const lookup = el.shadowRoot.querySelector('c-smart-lookup');
        expect(lookup).not.toBeNull();
        expect(lookup.value).toBe('a');
        lookup.dispatchEvent(new CustomEvent('change', { detail: { value: 'Name', label: 'Name' } }));
        expect(seen[0].detail).toEqual({ value: '["Name"]' });
    });

    it('restricts string items to allowed values when provided', async () => {
        const el = makeElement({ value: '["Tech"]', availableFields: [{ label: 'Name', value: 'Name' }], allowedValues: ['Tech', 'Finance'] });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const selector = el.shadowRoot.querySelector('lightning-combobox');
        expect(selector.options).toEqual([
            { label: 'Tech', value: 'Tech' },
            { label: 'Finance', value: 'Finance' }
        ]);
        expect(el.shadowRoot.querySelector('c-smart-lookup')).toBeNull();
        selector.dispatchEvent(new CustomEvent('change', { detail: { value: 'Finance' } }));
        expect(seen[0].detail).toEqual({ value: '["Finance"]' });
    });

    it('removes an item by index', async () => {
        const el = makeElement({ value: '["a","b"]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        buttonIcons(el)
            .find((b) => b.alternativeText === 'Remove item' && b.dataset.index === '0')
            .click();
        expect(seen[0].detail).toEqual({ value: '["b"]' });
    });

    it('keeps values correct across remove then add with parent feedback', async () => {
        const el = makeElement({ value: '["a","b"]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        buttonIcons(el)
            .find((b) => b.alternativeText === 'Remove item' && b.dataset.index === '0')
            .click();
        expect(seen[0].detail).toEqual({ value: '["b"]' });
        el.value = '["b"]';
        await flush();
        findButton(el, 'Add Item').click();
        expect(seen[1].detail).toEqual({ value: '["b",""]' });
        el.value = '["b",""]';
        await flush();
        const rendered = Array.from(el.shadowRoot.querySelectorAll('li.slds-item'));
        expect(rendered).toHaveLength(2);
    });

    it('edits number rows and coerces invalid input to null', async () => {
        const el = makeElement({ itemType: 'number', value: '[1]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const num = el.shadowRoot.querySelector('lightning-input');
        expect(num.type).toBe('number');
        num.value = '5';
        num.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '[5]' });
        num.value = 'abc';
        num.dispatchEvent(new CustomEvent('change'));
        expect(seen[1].detail).toEqual({ value: '[null]' });
    });

    it('treats integer item type as number type', async () => {
        const el = makeElement({ itemType: 'integer', value: '[2]' });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('lightning-input').type).toBe('number');
        expect(el.shadowRoot.querySelector('c-smart-lookup')).toBeNull();
    });

    it('toggles boolean rows', async () => {
        const el = makeElement({ itemType: 'boolean', value: '[false]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const toggle = el.shadowRoot.querySelector('lightning-input');
        expect(toggle.type).toBe('toggle');
        expect(toggle.checked).toBe(false);
        toggle.checked = true;
        toggle.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '[true]' });
    });

    it('clears all items', async () => {
        const el = makeElement({ value: '["a"]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        findButton(el, 'Clear All').click();
        expect(seen[0].detail).toEqual({ value: '[]' });
    });

    it('returns empty items for blank, invalid and non-array values', async () => {
        for (const value of ['', '[]', 'not json', '"str"', '123', '{"a":1}']) {
            const el = makeElement({ value });
            document.body.appendChild(el);
            await flush();
            expect(el.shadowRoot.querySelectorAll('li.slds-item')).toHaveLength(0);
            expect(el.shadowRoot.textContent).toContain('No items yet');
            document.body.removeChild(el);
        }
    });

    it('parses boolean strings in boolean rows', async () => {
        const el = makeElement({ itemType: 'boolean', value: '["true",false]' });
        document.body.appendChild(el);
        await flush();
        const toggles = Array.from(el.shadowRoot.querySelectorAll('lightning-input'));
        expect(toggles).toHaveLength(2);
        expect(toggles[0].checked).toBe(true);
        expect(toggles[1].checked).toBe(false);
    });

    it('shows json preview when enabled and falls back on invalid json', async () => {
        const el = makeElement({ value: '["a"]', showJsonPreview: true });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('code').textContent).toContain('"a"');
        expect(el.shadowRoot.textContent).toContain('JSON Preview');
        document.body.removeChild(el);

        const bad = makeElement({ value: 'oops', showJsonPreview: true });
        document.body.appendChild(bad);
        await flush();
        expect(bad.shadowRoot.querySelector('code').textContent).toBe('oops');
    });

    it('exposes property value type options on pair type selectors', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"a":"1"}]' });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('lightning-combobox').options).toEqual([
            { label: 'String', value: 'string' },
            { label: 'Number', value: 'number' },
            { label: 'Boolean', value: 'boolean' }
        ]);
    });

    it('renders object key-value pairs and edits keys', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"city":"Paris"}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const keyInput = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.placeholder === 'Key');
        expect(keyInput.value).toBe('city');
        const valInput = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.placeholder === 'Value');
        expect(valInput.value).toBe('Paris');
        keyInput.value = 'town';
        keyInput.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '[{"town":"Paris"}]' });
    });

    it('infers pair value types for booleans and numbers', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"a":true,"b":3,"c":"x"}]' });
        document.body.appendChild(el);
        await flush();
        const typeCombos = Array.from(el.shadowRoot.querySelectorAll('lightning-combobox'));
        expect(typeCombos.map((c) => c.value)).toEqual(['boolean', 'number', 'string']);
        expect(Array.from(el.shadowRoot.querySelectorAll('lightning-input')).some((i) => i.type === 'toggle')).toBe(true);
    });

    it('edits object pair values and boolean pair toggles', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"city":"Paris","open":true}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const valInput = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find(
            (i) => i.placeholder === 'Value' && i.dataset.pairId.endsWith('-0')
        );
        valInput.value = 'Lyon';
        valInput.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '[{"city":"Lyon","open":true}]' });
        const boolToggle = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.type === 'toggle');
        boolToggle.checked = false;
        boolToggle.dispatchEvent(new CustomEvent('change'));
        expect(seen[1].detail).toEqual({ value: '[{"city":"Paris","open":false}]' });
    });

    it('converts pair value when pair type changes', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"n":"x"}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const typeCombo = el.shadowRoot.querySelector('lightning-combobox');
        expect(typeCombo.value).toBe('string');
        typeCombo.dispatchEvent(new CustomEvent('change', { detail: { value: 'number' } }));
        expect(seen[0].detail).toEqual({ value: '[{"n":0}]' });
    });

    it('converts pair value to boolean when pair type changes to boolean', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"f":"true"}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        el.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'boolean' } }));
        expect(seen[0].detail).toEqual({ value: '[{"f":true}]' });
    });

    it('adds and removes key-value pairs', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"a":"1"}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        findButton(el, 'Add Property').click();
        expect(seen[0].detail).toEqual({ value: '[{"a":"1"}]' });
        el.value = '[{"a":"1","b":"2"}]';
        await flush();
        const removers = buttonIcons(el).filter((b) => b.alternativeText === 'Remove');
        expect(removers).toHaveLength(2);
        removers[1].click();
        expect(seen[1].detail).toEqual({ value: '[{"a":"1"}]' });
    });

    it('flags empty keys as required', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"":"x"}]' });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.textContent).toContain('Key is required.');
    });

    it('flags duplicate trimmed keys', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"a":"1"," a ":"2"}]' });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.textContent.match(/Duplicate key\./g)).toHaveLength(2);
    });

    it('skips empty and duplicate keys when building json', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"":"x"}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        findButton(el, 'Add Property').click();
        expect(seen[0].detail).toEqual({ value: '[{}]' });
    });

    it('initializes new object rows with one empty pair', async () => {
        const el = makeElement({ itemType: 'object', value: '[]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        findButton(el, 'Add Item').click();
        expect(seen[0].detail).toEqual({ value: '[{}]' });
    });

    it('disables add, remove and clear controls when disabled', async () => {
        const el = makeElement({ value: '["a"]', disabled: true });
        document.body.appendChild(el);
        await flush();
        expect(findButton(el, 'Add Item').disabled).toBe(true);
        expect(findButton(el, 'Clear All').disabled).toBe(true);
        expect(buttonIcons(el).find((b) => b.alternativeText === 'Remove item').disabled).toBe(true);
        expect(el.shadowRoot.querySelector('lightning-input').disabled).toBe(true);
    });

    it('clears the object when its last pair is removed', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"a":"1"}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        buttonIcons(el)
            .find((b) => b.alternativeText === 'Remove')
            .click();
        expect(seen[0].detail).toEqual({ value: '[{}]' });
    });

    it('tolerates non-string values without throwing', async () => {
        const num = makeElement({ value: 5 });
        document.body.appendChild(num);
        await flush();
        expect(num.shadowRoot.querySelectorAll('li.slds-item')).toHaveLength(0);
        document.body.removeChild(num);

        const arr = makeElement({ value: ['a'] });
        document.body.appendChild(arr);
        await flush();
        expect(arr.shadowRoot.querySelectorAll('li.slds-item')).toHaveLength(1);
    });

    it('treats whitespace, null and undefined values as empty', async () => {
        for (const value of ['   ', null, undefined, 0]) {
            const el = makeElement({ value });
            document.body.appendChild(el);
            await flush();
            expect(el.shadowRoot.querySelectorAll('li.slds-item')).toHaveLength(0);
            expect(el.shadowRoot.textContent).toContain('No items yet');
            document.body.removeChild(el);
        }
    });

    it('renders primitive object elements with empty pairs that build to empty objects', async () => {
        const el = makeElement({ itemType: 'object', value: '["a"]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelectorAll('li.slds-item')).toHaveLength(1);
        expect(Array.from(el.shadowRoot.querySelectorAll('lightning-input')).filter((i) => i.placeholder === 'Key')).toHaveLength(0);
        expect(findButton(el, 'Add Property')).toBeDefined();
        findButton(el, 'Add Property').click();
        expect(seen[0].detail).toEqual({ value: '[{}]' });
        document.body.removeChild(el);

        const nul = makeElement({ itemType: 'object', value: '[null]' });
        document.body.appendChild(nul);
        await flush();
        expect(nul.shadowRoot.querySelectorAll('li.slds-item')).toHaveLength(1);
        expect(findButton(nul, 'Add Property')).toBeDefined();
    });

    it('removes the middle item and keeps the rest', async () => {
        const el = makeElement({ value: '["a","b","c"]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        expect(Array.from(el.shadowRoot.querySelectorAll('.slds-badge')).map((b) => b.textContent)).toEqual(['1', '2', '3']);
        buttonIcons(el)
            .find((b) => b.alternativeText === 'Remove item' && b.dataset.index === '1')
            .click();
        expect(seen[0].detail).toEqual({ value: '["a","c"]' });
    });

    it('coerces blank number input to null', async () => {
        const el = makeElement({ itemType: 'number', value: '[""]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const num = el.shadowRoot.querySelector('lightning-input');
        expect(num.value).toBe('');
        num.value = '';
        num.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '[null]' });
    });

    it('renders plain input when field options are undefined', async () => {
        const el = makeElement({ value: '["a"]', availableFields: undefined });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('c-smart-lookup')).toBeNull();
        expect(el.shadowRoot.querySelector('lightning-input').value).toBe('a');
    });

    it('hides helptext when help text is blank', async () => {
        const el = makeElement({ helpText: '' });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('lightning-helptext')).toBeNull();
    });

    it('pretty prints the json preview with indentation', async () => {
        const el = makeElement({ value: '["a"]', showJsonPreview: true });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('code').textContent).toContain('\n');
        document.body.removeChild(el);

        const nul = makeElement({ value: null, showJsonPreview: true });
        document.body.appendChild(nul);
        await flush();
        expect(nul.shadowRoot.querySelector('code').textContent).toBe('[]');
    });

    it('dispatches arraychange as a bubbling composed event', async () => {
        const el = makeElement({ itemType: 'boolean', value: '[false]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const toggle = el.shadowRoot.querySelector('lightning-input');
        toggle.checked = true;
        toggle.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].bubbles).toBe(true);
        expect(seen[0].composed).toBe(true);
    });

    it('renders number pair inputs and converts pairs across every type', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"n":3}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        expect(Array.from(el.shadowRoot.querySelectorAll('lightning-input')).some((i) => i.type === 'number')).toBe(true);
        el.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'string' } }));
        expect(seen[0].detail).toEqual({ value: '[{"n":"3"}]' });
        document.body.removeChild(el);

        const bool = makeElement({ itemType: 'object', value: '[{"f":true}]' });
        const seenBool = listen(bool);
        document.body.appendChild(bool);
        await flush();
        expect(bool.shadowRoot.querySelector('lightning-input[type="toggle"]') || bool.shadowRoot.querySelectorAll('lightning-input')[1]).toBeDefined();
        bool.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'number' } }));
        expect(seenBool[0].detail).toEqual({ value: '[{"f":0}]' });
        document.body.removeChild(bool);

        const toString = makeElement({ itemType: 'object', value: '[{"f":true}]' });
        const seenString = listen(toString);
        document.body.appendChild(toString);
        await flush();
        toString.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'string' } }));
        expect(seenString[0].detail).toEqual({ value: '[{"f":"true"}]' });
    });

    it('edits number pair values preserving numeric output', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"n":3}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const valInput = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.placeholder === 'Value');
        valInput.value = '4';
        valInput.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '[{"n":4}]' });
    });

    it('toggles object boolean pairs from false to true', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"open":false}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const toggle = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.type === 'toggle');
        expect(toggle.checked).toBe(false);
        toggle.checked = true;
        toggle.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '[{"open":true}]' });
    });

    it('validates edited keys and skips empty or duplicate keys in output', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"a":"1","b":"2"}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('.slds-has-error')).toBeNull();
        const keyInputs = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).filter((i) => i.placeholder === 'Key');
        keyInputs[1].value = 'a';
        keyInputs[1].dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '[{"a":"1"}]' });
        document.body.removeChild(el);

        const empty = makeElement({ itemType: 'object', value: '[{"a":"1"}]' });
        const seenEmpty = listen(empty);
        document.body.appendChild(empty);
        await flush();
        const keyInput = Array.from(empty.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.placeholder === 'Key');
        keyInput.value = '';
        keyInput.dispatchEvent(new CustomEvent('change'));
        expect(seenEmpty[0].detail).toEqual({ value: '[{}]' });
    });

    it('maps placeholder keys to empty strings for editing', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"__placeholder_0":"x"}]' });
        document.body.appendChild(el);
        await flush();
        const keyInput = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.placeholder === 'Key');
        expect(keyInput.value).toBe('');
        expect(el.shadowRoot.textContent).toContain('Key is required.');
    });

    it('disables pair controls when disabled', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"a":"1"}]', disabled: true });
        document.body.appendChild(el);
        await flush();
        expect(Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.placeholder === 'Key').disabled).toBe(true);
        expect(el.shadowRoot.querySelector('lightning-combobox').disabled).toBe(true);
        expect(buttonIcons(el).find((b) => b.alternativeText === 'Remove').disabled).toBe(true);
        expect(findButton(el, 'Add Property').disabled).toBe(true);
    });

    it('offers no reorder controls — order is insertion order only', async () => {
        const el = makeElement({ value: '["a","b"]' });
        document.body.appendChild(el);
        await flush();
        const labels = buttons(el).map((b) => b.label);
        expect(labels).not.toContain('Move Up');
        expect(labels).not.toContain('Move Down');
        expect(buttonIcons(el).some((b) => b.alternativeText === 'Move up')).toBe(false);
        expect(buttonIcons(el).some((b) => b.alternativeText === 'Move down')).toBe(false);
    });

    it('adds a default item even when the current value is invalid json', async () => {
        const el = makeElement({ value: 'not json' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        findButton(el, 'Add Item').click();
        expect(seen[0].detail).toEqual({ value: '[""]' });
    });

    it('renders boolean true values as checked toggles', async () => {
        const el = makeElement({ itemType: 'boolean', value: '[true]' });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelector('lightning-input').checked).toBe(true);
    });

    it('keeps pair ids unique across remove then add', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"a":"1","b":"2"}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const removers = buttonIcons(el).filter((b) => b.alternativeText === 'Remove');
        removers[0].click();
        expect(seen[0].detail).toEqual({ value: '[{"b":"2"}]' });
        el.value = '[{"b":"2"}]';
        await flush();
        findButton(el, 'Add Property').click();
        expect(seen[1].detail).toEqual({ value: '[{"b":"2"}]' });
        el.value = '[{"b":"2","":"x"}]';
        await flush();
        expect(el.shadowRoot.textContent).toContain('Key is required.');
    });

    it('converts number pairs to string without losing the digits', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"n":3.5}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        el.shadowRoot.querySelector('lightning-combobox').dispatchEvent(new CustomEvent('change', { detail: { value: 'string' } }));
        expect(seen[0].detail).toEqual({ value: '[{"n":"3.5"}]' });
    });

    it('coerces invalid number pair values to null', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"n":3}]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        const valInput = Array.from(el.shadowRoot.querySelectorAll('lightning-input')).find((i) => i.placeholder === 'Value');
        valInput.value = 'oops';
        valInput.dispatchEvent(new CustomEvent('change'));
        expect(seen[0].detail).toEqual({ value: '[{"n":null}]' });
    });

    it('flags whitespace-only keys as required', async () => {
        const el = makeElement({ itemType: 'object', value: '[{"   ":"x"}]' });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.textContent).toContain('Key is required.');
    });

    it('treats undefined value as empty with an empty preview', async () => {
        const el = makeElement({ value: undefined, showJsonPreview: true });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelectorAll('li.slds-item')).toHaveLength(0);
        expect(el.shadowRoot.querySelector('code').textContent).toBe('[]');
    });

    it('emits only the value key in arraychange detail', async () => {
        const el = makeElement({ value: '["a"]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        findButton(el, 'Clear All').click();
        expect(Object.keys(seen[0].detail)).toEqual(['value']);
    });

    it('edits rows through detail value when the target has none', async () => {
        const fields = [{ label: 'Name', value: 'Name' }];
        const el = makeElement({ value: '["a"]', availableFields: fields });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        el.shadowRoot.querySelector('c-smart-lookup').dispatchEvent(new CustomEvent('change', { detail: { value: 'b', label: 'b' } }));
        expect(seen[0].detail).toEqual({ value: '["b"]' });
    });

    it('adds number rows with a zero default through the button', async () => {
        const el = makeElement({ itemType: 'number', value: '[]' });
        const seen = listen(el);
        document.body.appendChild(el);
        await flush();
        findButton(el, 'Add Item').click();
        expect(seen[0].detail).toEqual({ value: '[0]' });
    });

    it('shows the add control even for empty object rows', async () => {
        const el = makeElement({ itemType: 'object', value: '[{}]' });
        document.body.appendChild(el);
        await flush();
        expect(el.shadowRoot.querySelectorAll('li.slds-item')).toHaveLength(1);
        expect(findButton(el, 'Add Property')).toBeDefined();
        expect(el.shadowRoot.textContent).not.toContain('Key is required.');
        document.body.removeChild(el);

        const emptyKey = makeElement({ itemType: 'object', value: '[{"":"x"}]' });
        document.body.appendChild(emptyKey);
        await flush();
        expect(emptyKey.shadowRoot.textContent).toContain('Key is required.');
    });
});
