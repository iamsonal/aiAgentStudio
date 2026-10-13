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
import { highlightJson } from 'c/plutoRunStoryModel';

/** One step input or output, shown as colour-coded JSON. */
export default class PlutoRunStoryPayload extends LightningElement {
    @api label;
    @api emptyText = 'Nothing recorded.';

    _value;
    highlighted = { pretty: '', tokens: [], isJson: false };
    // idle, copied, or failed: the clipboard can be blocked by browser or Lightning security settings.
    copyState = 'idle';

    @api
    get value() {
        return this._value;
    }

    set value(text) {
        this._value = text;
        this.highlighted = highlightJson(text);
    }

    get hasValue() {
        return this._value !== null && this._value !== undefined && this._value !== '';
    }

    get hasSensitive() {
        return this.highlighted.tokens.some((token) => token.cls === 'json-sensitive');
    }

    get copyIcon() {
        return { copied: 'utility:check', failed: 'utility:warning' }[this.copyState] || 'utility:copy';
    }

    get copyText() {
        return { copied: 'Copied', failed: "Couldn't copy. Select the text instead." }[this.copyState] || `Copy ${this.label || 'value'}`;
    }

    get copyFailed() {
        return this.copyState === 'failed';
    }

    async handleCopy() {
        try {
            await navigator.clipboard.writeText(this.highlighted.pretty);
            this.copyState = 'copied';
        } catch (error) {
            this.copyState = 'failed';
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(
            () => {
                this.copyState = 'idle';
            },
            this.copyState === 'failed' ? 4000 : 1500
        );
    }
}
