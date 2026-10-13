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
import { NavigationMixin } from 'lightning/navigation';

/** A record's own Lightning page. Agents, tools, and execution identities open there in the Pluto editor. */
export function recordPage(recordId, objectApiName) {
    return { type: 'standard__recordPage', attributes: { recordId, ...(objectApiName ? { objectApiName } : {}), actionName: 'view' } };
}

export function relatedListPage(recordId, objectApiName, relationshipApiName) {
    return { type: 'standard__recordRelationshipPage', attributes: { recordId, objectApiName, relationshipApiName, actionName: 'view' } };
}

/**
 * A link to a page reference. It carries the real URL, so opening it in a new
 * tab or copying it works, and a plain click navigates inside the app.
 */
export default class PlutoLink extends NavigationMixin(LightningElement) {
    @api label;
    @api title;
    /** 'link' (default), 'icon', or 'button'. */
    @api variant = 'link';
    @api iconName = 'utility:open';

    href;
    _pageReference;
    _referenceKey;
    connected = false;

    @api
    get pageReference() {
        return this._pageReference;
    }

    set pageReference(value) {
        // Parents often rebuild the same reference on each render; only a new target needs a new URL.
        const key = JSON.stringify(value || null);
        if (key === this._referenceKey) {
            return;
        }
        this._referenceKey = key;
        this._pageReference = value;
        if (this.connected) {
            this.generateUrl();
        }
    }

    connectedCallback() {
        this.connected = true;
        this.generateUrl();
    }

    disconnectedCallback() {
        this.connected = false;
    }

    get isIcon() {
        return this.variant === 'icon';
    }

    get isButton() {
        return this.variant === 'button';
    }

    async generateUrl() {
        const reference = this._pageReference;
        this.href = undefined;
        if (!reference) {
            return;
        }
        try {
            const url = await this[NavigationMixin.GenerateUrl](reference);
            if (reference === this._pageReference) {
                this.href = url;
            }
        } catch (error) {
            // Without a URL the link still navigates on click.
        }
    }

    handleClick(event) {
        // New-tab and new-window clicks go to the real URL.
        if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || !this._pageReference) {
            return;
        }
        event.preventDefault();
        event.stopPropagation();
        this[NavigationMixin.Navigate](this._pageReference);
    }
}
