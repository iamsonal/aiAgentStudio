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

/**
 * Record-page style save error indicator: an error icon beside the Save
 * button that opens a "We hit a snag." popover. The host owns the errors and
 * the open state; this component only renders them and reports clicks.
 *
 * Events: `toggle`, `close`, and `fieldselect` (detail: { fieldApiName }).
 */
export default class PlutoSaveErrorPopover extends LightningElement {
    /** [{ key, message }] messages that belong to no shown field. */
    @api pageErrors = [];
    /** [{ fieldApiName, label }] fields that have an error. */
    @api errorFields = [];
    @api open = false;
    /** 'below' under a header button, 'above' over a footer button. */
    @api placement = 'above';

    @api
    focusPopover() {
        this.template.querySelector('[data-id="error-summary"]')?.focus();
    }

    get hasPageErrors() {
        return this.pageErrors?.length > 0;
    }

    get hasErrorFields() {
        return this.errorFields?.length > 0;
    }

    get ariaExpanded() {
        return this.open ? 'true' : 'false';
    }

    get popoverClass() {
        return this.placement === 'below'
            ? 'slds-popover slds-popover_error slds-nubbin_top-right popover popover_below'
            : 'slds-popover slds-popover_error slds-nubbin_bottom popover popover_above';
    }

    handleToggle() {
        this.dispatchEvent(new CustomEvent('toggle'));
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    handleKeyDown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.handleClose();
        }
    }

    handleFieldClick(event) {
        event.preventDefault();
        this.dispatchEvent(new CustomEvent('fieldselect', { detail: { fieldApiName: event.currentTarget.dataset.field } }));
    }
}
