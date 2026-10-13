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
import toastUiEditor from '@salesforce/resourceUrl/toastUiEditor';

export default class ToastUiMarkdownEditor extends LightningElement {
    @api label;
    @api height = '200px';

    _channel = `toast-ui-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    _disabled = false;
    _value = '';
    _frameReady = false;

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
        const nextValue = value || '';
        if (nextValue === this._value) {
            return;
        }
        this._value = nextValue;
        this.sendToFrame('setValue', { value: this._value });
    }

    @api
    get disabled() {
        return this._disabled;
    }

    set disabled(value) {
        this._disabled = value === true;
        this.sendToFrame('setDisabled', { disabled: this._disabled });
    }

    get editorSrc() {
        return `${toastUiEditor}/editor.html?channel=${encodeURIComponent(this._channel)}`;
    }

    get editorStyle() {
        return `height: ${this.height};`;
    }

    @api
    getMarkdown() {
        return this._value;
    }

    @api
    setMarkdown(value) {
        this.value = value;
    }

    @api
    focus() {
        this.sendToFrame('focus');
    }

    handleIframeLoad() {
        this.initializeFrame();
    }

    handleWindowMessage = (event) => {
        const frame = this.template.querySelector('iframe');
        if (!frame || event.source !== frame.contentWindow || !event.data || event.data.channel !== this._channel) {
            return;
        }
        if (event.data.type === 'ready') {
            this._frameReady = true;
            this.initializeFrame();
            return;
        }
        if (event.data.type === 'change') {
            const value = event.data.payload?.value || '';
            if (value === this._value) {
                return;
            }
            this._value = value;
            this.dispatchEvent(
                new CustomEvent('change', {
                    detail: { value },
                    bubbles: true,
                    composed: true
                })
            );
        }
    };

    initializeFrame() {
        this.sendToFrame('initialize', { value: this._value });
        this.sendToFrame('setDisabled', { disabled: this._disabled });
    }

    sendToFrame(type, payload = {}) {
        const frame = this.template.querySelector('iframe');
        if (!frame || !frame.contentWindow) {
            return;
        }
        frame.contentWindow.postMessage(
            {
                channel: this._channel,
                type,
                payload,
                parentOrigin: window.location.origin
            },
            this.frameOrigin
        );
    }

    get frameOrigin() {
        return new URL(this.editorSrc, window.location.href).origin;
    }
}
