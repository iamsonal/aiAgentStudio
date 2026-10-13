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

import { LightningElement, api } from 'lwc';
import getFieldOptions from '@salesforce/apex/ToolAuthoringController.getFieldOptions';
import getChildRelationshipOptions from '@salesforce/apex/ToolAuthoringController.getChildRelationshipOptions';
import searchStandardTargetSObjects from '@salesforce/apex/ToolAuthoringController.searchStandardTargetSObjects';
import { QUERY_TOOL_TYPE, readQueryContext, suggest } from './queryAssist';

const OBJECT_SEARCH_DELAY = 250;
const SUGGESTION_WIDTH = 384;
const MIRRORED_STYLES = [
    'borderTopWidth',
    'borderRightWidth',
    'borderBottomWidth',
    'borderLeftWidth',
    'borderStyle',
    'paddingTop',
    'paddingRight',
    'paddingBottom',
    'paddingLeft',
    'fontFamily',
    'fontSize',
    'fontWeight',
    'fontStyle',
    'letterSpacing',
    'lineHeight',
    'textTransform',
    'wordSpacing',
    'tabSize',
    'textIndent'
];

/**
 * The query of a Query Records tool. Core reads the query and builds one
 * input for each :name, so the page refreshes the inputs whenever it
 * changes. Controlled: the parent passes value and gets each edit in a
 * querychange event.
 */
export default class ToolQueryEditor extends LightningElement {
    @api disabled = false;
    @api label = 'SOQL Query';
    @api required = false;

    query = '';

    suggestions = [];
    suggestionMessage = '';
    suggestionStyle = '';
    activeIndex = 0;
    _replaceFrom = 0;
    _replaceTo = 0;
    _suggestVersion = 0;
    _fieldsByObject = new Map();
    _childrenByObject = new Map();
    _objectSearchTimer = null;

    @api
    get value() {
        return this.query;
    }

    set value(next) {
        const text = next === null || next === undefined ? '' : String(next);
        if (text !== this.query) {
            this.query = text;
        }
    }

    disconnectedCallback() {
        clearTimeout(this._objectSearchTimer);
    }

    notifyChange() {
        this.dispatchEvent(new CustomEvent('querychange', { detail: { value: this.query } }));
    }

    /** A native textarea has no value attribute; set its text only when it differs, so typing keeps the cursor. */
    renderedCallback() {
        const textarea = this.textarea;
        if (textarea && textarea.value !== this.query) {
            textarea.value = this.query;
        }
    }

    get textarea() {
        return this.template.querySelector('textarea');
    }

    get showSuggestions() {
        return this.suggestions.length > 0 || !!this.suggestionMessage;
    }

    get suggestionOptions() {
        return this.suggestions.map((item, index) => ({
            ...item,
            index,
            id: `query-option-${index}`,
            ariaSelected: index === this.activeIndex ? 'true' : 'false',
            className:
                index === this.activeIndex
                    ? 'slds-media slds-listbox__option slds-listbox__option_entity slds-has-focus'
                    : 'slds-media slds-listbox__option slds-listbox__option_entity'
        }));
    }

    get activeOptionId() {
        return this.suggestions.length ? `query-option-${this.activeIndex}` : null;
    }

    get suggestionStatus() {
        if (!this.suggestions.length) {
            return this.suggestionMessage;
        }
        return this.suggestions.length === 1 ? '1 suggestion' : `${this.suggestions.length} suggestions`;
    }

    handleQueryInput(event) {
        this.query = event.target.value;
        this.notifyChange();
        this.refreshSuggestions();
    }

    handleCaretMove(event) {
        if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
            this.refreshSuggestions();
        }
    }

    handleQueryClick() {
        this.refreshSuggestions();
    }

    handleQueryBlur() {
        this.closeSuggestions();
    }

    handleQueryScroll() {
        if (this.showSuggestions) {
            this.suggestionStyle = this.styleAtCaret(this._replaceFrom);
        }
    }

    /**
     * Places the list under the word being typed. A textarea does not say
     * where its caret is, so a hidden copy with the same font, padding, and
     * width lays out the text before it and reports where it ends.
     */
    styleAtCaret(index) {
        const textarea = this.textarea;
        const mirror = this.template.querySelector('.query-mirror');
        if (!textarea || !mirror) {
            return '';
        }
        const style = window.getComputedStyle(textarea);
        MIRRORED_STYLES.forEach((property) => {
            mirror.style[property] = style[property];
        });
        const pixels = (value) => parseFloat(value) || 0;
        mirror.style.boxSizing = 'content-box';
        mirror.style.width = `${Math.max(0, textarea.clientWidth - pixels(style.paddingLeft) - pixels(style.paddingRight))}px`;
        mirror.textContent = this.query.slice(0, index);
        const marker = document.createElement('span');
        marker.textContent = '\u200b';
        mirror.appendChild(marker);
        const lineHeight = pixels(style.lineHeight) || pixels(style.fontSize) * 1.5;
        const caretTop = pixels(style.borderTopWidth) + marker.offsetTop - textarea.scrollTop;
        const top = Math.min(Math.max(caretTop, 0), Math.max(0, textarea.offsetHeight - lineHeight)) + lineHeight;
        const left = Math.max(0, Math.min(pixels(style.borderLeftWidth) + marker.offsetLeft - textarea.scrollLeft, textarea.offsetWidth - SUGGESTION_WIDTH));
        mirror.textContent = '';
        return `top: ${Math.round(top)}px; left: ${Math.round(left)}px;`;
    }

    handleQueryKeydown(event) {
        if (event.key === ' ' && event.ctrlKey) {
            event.preventDefault();
            this.refreshSuggestions();
            return;
        }
        if (!this.suggestions.length) {
            if (event.key === 'Escape' && this.suggestionMessage) {
                event.stopPropagation();
                this.closeSuggestions();
            }
            return;
        }
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault();
            const step = event.key === 'ArrowDown' ? 1 : -1;
            this.activeIndex = (this.activeIndex + step + this.suggestions.length) % this.suggestions.length;
            this.template.querySelector(`[data-index="${this.activeIndex}"]`)?.scrollIntoView?.({ block: 'nearest' });
        } else if (event.key === 'Tab' || (event.key === 'Enter' && !event.shiftKey)) {
            event.preventDefault();
            this.insertSuggestion(this.activeIndex);
        } else if (event.key === 'Escape') {
            event.preventDefault();
            event.stopPropagation();
            this.closeSuggestions();
        }
    }

    /** Keeps focus in the query box, so the click does not close the list first. */
    handleOptionMouseDown(event) {
        event.preventDefault();
        this.insertSuggestion(Number(event.currentTarget.dataset.index));
    }

    insertSuggestion(index) {
        const item = this.suggestions[index];
        const textarea = this.textarea;
        if (!item || !textarea) {
            return;
        }
        const after = this.query.slice(this._replaceTo);
        const spacer = item.value.endsWith('.') || item.value.endsWith(' ') || /^[\s),]/.test(after) ? '' : ' ';
        const inserted = item.value + spacer;
        this.query = this.query.slice(0, this._replaceFrom) + inserted + after;
        textarea.value = this.query;
        const caret = this._replaceFrom + inserted.length;
        textarea.setSelectionRange(caret, caret);
        this.notifyChange();
        this.refreshSuggestions();
    }

    closeSuggestions() {
        this._suggestVersion++;
        clearTimeout(this._objectSearchTimer);
        this.suggestions = [];
        this.suggestionMessage = '';
    }

    /** Reads the text at the caret and shows what fits there, loading an object's fields the first time they are needed. */
    async refreshSuggestions() {
        const version = ++this._suggestVersion;
        clearTimeout(this._objectSearchTimer);
        const textarea = this.textarea;
        if (this.disabled || !textarea) {
            this.showResult({ items: [] });
            return;
        }
        const context = readQueryContext(this.query, textarea.selectionStart);
        const fieldsOf = (objectName) => this._fieldsByObject.get(String(objectName).toLowerCase());
        const childrenOf = (objectName) => this._childrenByObject.get(String(objectName).toLowerCase());
        let result = suggest(context, fieldsOf, childrenOf);
        while (result.needsObject || result.needsChildren) {
            await (result.needsObject
                ? this.loadDescribe(this._fieldsByObject, result.needsObject, getFieldOptions)
                : this.loadDescribe(this._childrenByObject, result.needsChildren, getChildRelationshipOptions));
            if (version !== this._suggestVersion) {
                return;
            }
            result = suggest(context, fieldsOf, childrenOf);
        }
        if (result.searchObjects) {
            this.showResult({ items: this.suggestions.length && this._replaceFrom === context.replaceFrom ? this.suggestions : [] }, context);
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._objectSearchTimer = setTimeout(() => this.searchObjects(result.searchObjects, context, version), OBJECT_SEARCH_DELAY);
            return;
        }
        this.showResult(result, context);
    }

    async searchObjects(term, context, version) {
        let items = [];
        try {
            const options = (await searchStandardTargetSObjects({ term, operation: QUERY_TOOL_TYPE })) || [];
            items = options.map((option) => ({ value: option.value, label: option.value, detail: (option.label || '').split(' • ')[0] }));
        } catch (error) {
            items = [];
        }
        if (version === this._suggestVersion) {
            this.showResult({ items }, context);
        }
    }

    /** Loads an object's fields or child relationships once; an unknown object or a failed call caches an empty list. */
    async loadDescribe(cache, objectName, load) {
        const key = String(objectName).toLowerCase();
        if (cache.has(key)) {
            return;
        }
        let options = [];
        try {
            options = (await load({ objectApiName: objectName })) || [];
        } catch (error) {
            options = [];
        }
        cache.set(key, options);
    }

    showResult(result, context) {
        const items = result.items || [];
        const onlyTyped = items.length === 1 && context && items[0].value.toLowerCase() === context.term.toLowerCase();
        this.suggestions = onlyTyped ? [] : items;
        this.suggestionMessage = this.suggestions.length ? '' : result.message || '';
        this.activeIndex = 0;
        if (context) {
            this._replaceFrom = context.replaceFrom;
            this._replaceTo = context.replaceTo;
        }
        if (this.showSuggestions) {
            this.suggestionStyle = this.styleAtCaret(this._replaceFrom);
        }
    }
}
