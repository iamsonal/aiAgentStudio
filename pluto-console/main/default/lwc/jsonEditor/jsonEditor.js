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
import plutoJsonEditor from '@salesforce/resourceUrl/plutoJsonEditor';

/** JSON text remains a draft until the owning form saves it. */
export default class JsonEditor extends LightningElement {
    @api label;
    @api variant = 'standard';
    @api required = false;
    @api objectOnly = false;
    @api maxLength;
    validationMessage = '';

    _channel = `json-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    _value = '';
    _disabled = false;
    _customValidity = '';

    connectedCallback() {
        window.addEventListener('message', this.handleWindowMessage);
    }

    disconnectedCallback() {
        window.removeEventListener('message', this.handleWindowMessage);
    }

    @api
    get value() {
        return this._value;
    }

    set value(value) {
        const next = value == null ? '' : String(value);
        if (next !== this._value) {
            this._value = next;
            this.sendToFrame('setValue', { value: next });
            if (this.validationMessage) {
                this.reportValidity();
            }
        }
    }

    @api
    get disabled() {
        return this._disabled;
    }

    set disabled(value) {
        this._disabled = value === true;
        if (this._disabled) {
            this.validationMessage = '';
        }
        this.sendToFrame('setDisabled', { disabled: this._disabled });
    }

    get editorSrc() {
        return `${plutoJsonEditor}/editor.html?channel=${encodeURIComponent(this._channel)}&parentOrigin=${encodeURIComponent(window.location.origin)}`;
    }

    get frameTitle() {
        return this.label || 'JSON configuration';
    }

    get labelClass() {
        return this.variant === 'label-hidden' ? 'slds-assistive-text' : 'slds-form-element__label slds-m-right_auto';
    }

    get editorClass() {
        return this.validationMessage ? 'editor-container has-error' : 'editor-container';
    }

    get formattedValue() {
        if (!this._value.trim()) {
            return '';
        }
        try {
            return JSON.stringify(JSON.parse(this._value), null, 2);
        } catch (error) {
            return this._value;
        }
    }

    get frameOrigin() {
        return new URL(this.editorSrc, window.location.href).origin;
    }

    get errorMessage() {
        if (this.disabled) {
            return '';
        }
        if (this._customValidity) {
            return this._customValidity;
        }
        if (!this._value.trim()) {
            return this.required ? 'Complete this field.' : '';
        }
        if (this.maxLength && this._value.length > this.maxLength) {
            return `Use no more than ${this.maxLength} characters.`;
        }
        let parsed;
        try {
            parsed = JSON.parse(this._value);
        } catch (error) {
            return 'Enter valid JSON. Check quotes, commas, and brackets.';
        }
        if (this.objectOnly && (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object')) {
            return 'Enter a JSON object, for example {"option": "value"}.';
        }
        return '';
    }

    @api
    setCustomValidity(message) {
        this._customValidity = message || '';
    }

    @api
    checkValidity() {
        return !this.errorMessage;
    }

    @api
    reportValidity() {
        this.validationMessage = this.errorMessage;
        return !this.validationMessage;
    }

    @api
    focus() {
        if (this.disabled) {
            this.template.querySelector('pre')?.focus();
        } else {
            this.sendToFrame('focus');
        }
    }

    handleFormat() {
        if (!this.reportValidity() || !this._value.trim()) {
            return;
        }
        const formatted = JSON.stringify(JSON.parse(this._value), null, 2);
        // Formatting must not expand a valid draft past its field limit.
        if (this.maxLength && formatted.length > this.maxLength) {
            this.validationMessage = `Formatted JSON exceeds ${this.maxLength} characters. Keep the compact version.`;
            return;
        }
        this.value = formatted;
        this.emitChange();
    }

    handleIframeLoad() {
        this.sendToFrame('initialize', { value: this._value, disabled: this.disabled, label: this.frameTitle });
    }

    handleWindowMessage = (event) => {
        const frame = this.template.querySelector('iframe');
        if (!frame || event.source !== frame.contentWindow || event.origin !== this.frameOrigin || event.data?.channel !== this._channel) {
            return;
        }
        if (event.data.type === 'ready') {
            this.handleIframeLoad();
        } else if (event.data.type === 'change' && !this.disabled && typeof event.data.payload?.value === 'string') {
            const value = event.data.payload.value;
            if (value !== this._value) {
                this._value = value;
                this._customValidity = '';
                this.reportValidity();
                this.emitChange();
            }
        }
    };

    emitChange() {
        this.dispatchEvent(new CustomEvent('change', { detail: { value: this._value }, bubbles: true, composed: true }));
    }

    sendToFrame(type, payload = {}) {
        const frame = this.template.querySelector('iframe');
        frame?.contentWindow?.postMessage({ channel: this._channel, type, payload }, this.frameOrigin);
    }
}
