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

const SEARCH_DELAY = 200;

// Callers pass these as attributes (`required`, `allow-free-text="true"`).
function normalizeBoolean(value) {
    if (typeof value === 'string') {
        return value === '' || value.toLowerCase() === 'true';
    }
    return value === true;
}

/**
 * SLDS lookup over caller-supplied options: `{ label, value, subtitle?, icon? }`.
 *
 * Strict mode (default) accepts only a listed option; `allow-free-text` also
 * accepts typed text and fires `change` on every keystroke. Fires `search`
 * (detail: { searchTerm }) after typing pauses, so a caller can load
 * matching options. Validity works like lightning-input: `required`,
 * `checkValidity`, `reportValidity`, and `setCustomValidity`.
 */
export default class SmartLookup extends LightningElement {
    @api label = '';
    @api placeholder = 'Type to search...';
    @api variant = 'standard';

    _required = false;
    _allowFreeText = false;
    _disabled = false;
    _options = [];
    _value = '';
    _customValidity = '';
    _hasFocus = false;
    _isUserEditing = false;
    _searchTimeout;
    _blurTimeout;

    searchTerm = '';
    filteredOptions = [];
    isDropdownOpen = false;
    focusedIndex = -1;
    reportedMessage = '';
    announceMessage = '';

    @api
    get required() {
        return this._required;
    }
    set required(value) {
        this._required = normalizeBoolean(value);
    }

    @api
    get allowFreeText() {
        return this._allowFreeText;
    }
    set allowFreeText(value) {
        this._allowFreeText = normalizeBoolean(value);
    }

    @api
    get disabled() {
        return this._disabled;
    }
    set disabled(value) {
        this._disabled = normalizeBoolean(value);
        if (this._disabled) {
            this.closeDropdown();
            if (!this.allowFreeText) {
                this._isUserEditing = false;
                this.syncDisplayWithValue();
            }
        }
    }

    @api
    get options() {
        return this._options;
    }
    set options(value) {
        this._options = Array.isArray(value) ? value : [];
        // Never rewrite what the user is typing when results arrive.
        if (!this._hasFocus && !this._isUserEditing) {
            this.syncDisplayWithValue();
        }
        this.refreshFilteredOptions();
    }

    @api
    get value() {
        return this._value;
    }
    set value(newValue) {
        const nextValue = newValue || '';
        // A host echoing back the text just typed must not replace it with
        // a matching option's label under the cursor.
        if (nextValue === this._value && this._hasFocus) {
            return;
        }
        this._value = nextValue;
        this._isUserEditing = false;
        this.syncDisplayWithValue();
        this.refreshFilteredOptions();
        this.refreshReportedValidity();
    }

    @api
    setOptions(newOptions) {
        this.options = newOptions || [];
    }

    @api
    checkValidity() {
        this.applyValidationState();
        return !this.currentValidationMessage;
    }

    /**
     * Shows the message inline with the SLDS error style instead of the
     * browser's validation bubble, matching lightning-input.
     */
    @api
    reportValidity() {
        this.applyValidationState();
        this.reportedMessage = this.currentValidationMessage;
        if (this.reportedMessage) {
            this.announceMessage = this.reportedMessage;
        }
        return !this.reportedMessage;
    }

    /** A non-empty message marks the lookup invalid, e.g. a server field error. */
    @api
    setCustomValidity(message) {
        this._customValidity = message || '';
        this.applyValidationState();
        this.refreshReportedValidity();
    }

    @api
    focus() {
        this.inputElement?.focus();
    }

    connectedCallback() {
        this.syncDisplayWithValue();
        this.refreshFilteredOptions();
    }

    disconnectedCallback() {
        clearTimeout(this._searchTimeout);
        clearTimeout(this._blurTimeout);
    }

    // ===== STATE =====

    get inputElement() {
        return this.template.querySelector('input');
    }

    get selectedOption() {
        return this._options.find((option) => option.value === this._value);
    }

    get showSelectedValueState() {
        return !this.allowFreeText && !!this._value && !!this.selectedOption && !this._isUserEditing;
    }

    syncDisplayWithValue() {
        const option = this.selectedOption;
        this.searchTerm = option ? String(option.label ?? option.value) : this._value;
    }

    refreshFilteredOptions() {
        const search = (this.searchTerm || '').trim().toLowerCase();
        // An unedited selection shows the full list, not just itself.
        const filterBy = this._isUserEditing || this.allowFreeText ? search : '';
        this.filteredOptions = filterBy
            ? this._options.filter((option) =>
                  [option.label, option.value, option.subtitle].some((text) =>
                      String(text ?? '')
                          .toLowerCase()
                          .includes(filterBy)
                  )
              )
            : this._options;
        if (this.focusedIndex >= this.filteredOptions.length) {
            this.focusedIndex = -1;
        }
        if (this.isDropdownOpen) {
            const count = this.filteredOptions.length;
            this.announceMessage = count === 0 ? 'No results found' : `${count} ${count === 1 ? 'result' : 'results'} available`;
        }
    }

    get currentValidationMessage() {
        if (this.disabled) {
            return '';
        }
        if (this._customValidity) {
            return this._customValidity;
        }
        if (!this.required) {
            return '';
        }
        // A stored value is valid before search results load; only text the
        // user typed without choosing an option is rejected.
        if (!this.allowFreeText && this._isUserEditing) {
            return this.searchTerm.trim() ? 'Select a value from the list.' : 'Complete this field.';
        }
        return this._value ? '' : 'Complete this field.';
    }

    applyValidationState() {
        this.inputElement?.setCustomValidity(this.currentValidationMessage);
    }

    refreshReportedValidity() {
        if (this.reportedMessage) {
            this.reportedMessage = this.currentValidationMessage;
        }
    }

    // ===== TEMPLATE GETTERS =====

    get showLabel() {
        return this.label && this.variant !== 'label-hidden';
    }

    get hasError() {
        return !!this.reportedMessage;
    }

    get describedBy() {
        return this.hasError ? 'help' : null;
    }

    get formElementClass() {
        return this.hasError ? 'slds-form-element slds-has-error' : 'slds-form-element';
    }

    get comboboxContainerClass() {
        return this.showSelectedValueState ? 'slds-combobox_container slds-has-selection' : 'slds-combobox_container';
    }

    get comboboxClass() {
        return this.showDropdown
            ? 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click slds-is-open'
            : 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click';
    }

    get inputContainerClass() {
        return this.showSelectedIcon
            ? 'slds-combobox__form-element slds-input-has-icon slds-input-has-icon_left-right'
            : 'slds-combobox__form-element slds-input-has-icon slds-input-has-icon_right';
    }

    get inputClass() {
        return this.showSelectedValueState ? 'slds-input slds-combobox__input slds-combobox__input-value' : 'slds-input slds-combobox__input';
    }

    get showSelectedIcon() {
        return this.showSelectedValueState && !!this.selectedOption.icon;
    }

    get selectedIcon() {
        return this.selectedOption?.icon;
    }

    get showClearButton() {
        return this.showSelectedValueState && !this.disabled;
    }

    get showSearchIcon() {
        return !this.showSelectedValueState;
    }

    get showDropdown() {
        return this.isDropdownOpen && !this.disabled && (this.hasOptions || !!this.searchTerm.trim());
    }

    get ariaExpanded() {
        return this.showDropdown ? 'true' : 'false';
    }

    get activeDescendant() {
        return this.showDropdown && this.focusedIndex >= 0 ? `option-${this.focusedIndex}` : null;
    }

    get hasOptions() {
        return this.filteredOptions.length > 0;
    }

    get emptyMessage() {
        return this.allowFreeText ? 'No suggestions. Type any value.' : 'No results found';
    }

    get normalizedOptions() {
        return this.filteredOptions.map((option, index) => ({
            key: `${index}-${option.value}`,
            id: `option-${index}`,
            index,
            value: option.value,
            icon: option.icon,
            label: String(option.label ?? option.value ?? ''),
            subtitle: option.subtitle ? String(option.subtitle) : '',
            ariaSelected: option.value === this._value ? 'true' : 'false',
            computedClass:
                index === this.focusedIndex
                    ? 'slds-media slds-listbox__option slds-listbox__option_entity slds-listbox__option_has-meta slds-has-focus'
                    : 'slds-media slds-listbox__option slds-listbox__option_entity slds-listbox__option_has-meta'
        }));
    }

    // ===== EVENT HANDLERS =====

    handleInputFocus() {
        this._hasFocus = true;
        if (this.disabled || this.showSelectedValueState) {
            return;
        }
        this.openDropdown();
    }

    handleInputChange(event) {
        this.searchTerm = event.target.value;
        this.focusedIndex = -1;
        this.isDropdownOpen = true;
        if (this.allowFreeText) {
            this._value = this.searchTerm;
            this.dispatchChangeEvent(this.searchTerm, this.searchTerm);
        } else {
            this._isUserEditing = true;
        }
        this.refreshFilteredOptions();
        this.refreshReportedValidity();
        this.scheduleSearchEvent();
    }

    handleInputBlur() {
        // Deferred so a click on an option lands before the list closes.
        this._blurTimeout = setTimeout(() => {
            this._hasFocus = false;
            this.closeDropdown();
            if (!this.allowFreeText) {
                // Emptying the text clears the value; other unmatched text
                // reverts to the current value.
                if (this._isUserEditing && !this.searchTerm.trim() && this._value) {
                    this._value = '';
                    this.dispatchChangeEvent('', '');
                }
                this._isUserEditing = false;
                this.syncDisplayWithValue();
            }
            this.reportValidity();
        }, 100);
    }

    handleDropdownMouseDown(event) {
        // Keeps focus in the input so choosing an option does not blur it.
        event.preventDefault();
    }

    handleKeyDown(event) {
        if (this.disabled) {
            return;
        }
        switch (event.key) {
            case 'ArrowDown':
            case 'ArrowUp':
                if (this.showSelectedValueState) {
                    return;
                }
                event.preventDefault();
                if (!this.isDropdownOpen) {
                    this.openDropdown();
                    return;
                }
                this.moveFocus(event.key === 'ArrowDown' ? 1 : -1);
                break;
            case 'Enter':
                if (this.isDropdownOpen && this.focusedIndex >= 0) {
                    event.preventDefault();
                    this.selectOption(this.filteredOptions[this.focusedIndex]);
                }
                break;
            case 'Escape':
                if (this.isDropdownOpen) {
                    event.preventDefault();
                    event.stopPropagation();
                    this.closeDropdown();
                    if (!this.allowFreeText) {
                        this._isUserEditing = false;
                        this.syncDisplayWithValue();
                    }
                }
                break;
            case 'Backspace':
            case 'Delete':
                if (this.showClearButton) {
                    event.preventDefault();
                    this.clearSelection();
                }
                break;
            default:
                break;
        }
    }

    handleOptionClick(event) {
        const option = this.filteredOptions[Number(event.currentTarget.dataset.index)];
        if (option) {
            this.selectOption(option);
        }
    }

    handleClearClick(event) {
        event.preventDefault();
        event.stopPropagation();
        if (this.showClearButton) {
            this.clearSelection();
        }
    }

    // ===== ACTIONS =====

    openDropdown() {
        this.isDropdownOpen = true;
        this.focusedIndex = -1;
        this.refreshFilteredOptions();
    }

    closeDropdown() {
        this.isDropdownOpen = false;
        this.focusedIndex = -1;
    }

    moveFocus(direction) {
        const count = this.filteredOptions.length;
        if (!count) {
            return;
        }
        this.focusedIndex = this.focusedIndex < 0 && direction < 0 ? count - 1 : (this.focusedIndex + direction + count) % count;
        Promise.resolve().then(() => this.template.querySelector(`[data-index="${this.focusedIndex}"]`)?.scrollIntoView?.({ block: 'nearest' }));
    }

    selectOption(option) {
        this._value = option.value ?? '';
        this.searchTerm = String(option.label ?? option.value ?? '');
        this._isUserEditing = false;
        this.closeDropdown();
        this.refreshFilteredOptions();
        this.refreshReportedValidity();
        this.dispatchChangeEvent(this._value, this.searchTerm);
    }

    clearSelection() {
        this._value = '';
        this.searchTerm = '';
        this._isUserEditing = true;
        this.refreshReportedValidity();
        this.dispatchChangeEvent('', '');
        this.inputElement?.focus();
        this.openDropdown();
    }

    scheduleSearchEvent() {
        clearTimeout(this._searchTimeout);
        this._searchTimeout = setTimeout(() => {
            this.dispatchEvent(new CustomEvent('search', { detail: { searchTerm: this.searchTerm } }));
        }, SEARCH_DELAY);
    }

    dispatchChangeEvent(value, label) {
        this.dispatchEvent(new CustomEvent('change', { detail: { value, label } }));
    }
}
