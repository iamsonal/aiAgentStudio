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

export default class ToolJsonReadOnlyPreview extends LightningElement {
    @api label = 'JSON';
    @api description = '';
    @api height = '300px';
    @api value = '';
    copied = false;

    get formattedValue() {
        if (!this.value) {
            return '{}';
        }
        try {
            return JSON.stringify(JSON.parse(this.value), null, 2);
        } catch (error) {
            return this.value;
        }
    }

    get containerStyle() {
        return `max-height: ${this.height}; overflow: auto;`;
    }

    get copyLabel() {
        return this.copied ? 'Copied' : 'Copy JSON';
    }

    async handleCopy() {
        try {
            await navigator.clipboard.writeText(this.formattedValue);
            this.copied = true;
            setTimeout(() => {
                this.copied = false;
            }, 2000);
        } catch (error) {
            this.copied = false;
        }
    }
}
