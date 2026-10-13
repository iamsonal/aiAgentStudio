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

import { api } from 'lwc';
import LightningModal from 'lightning/modal';

/**
 * Shows a hand-written Input Schema and lets the admin paste or edit it. The
 * modal never changes the inputs itself: Apply hands the JSON to applySchema, and
 * the modal closes only when that reports no problems. Cancel changes nothing.
 */
export default class ToolInputSchemaJsonModal extends LightningModal {
    /** The schema the tool would save now; blank when there is none yet. */
    @api inputSchema = '';
    /** Shown instead of the schema when it is blank and the modal is read-only. */
    @api emptyMessage = '';
    /** Shows the schema without editing, as when the tool is locked. */
    @api readOnly = false;
    /** Checks the JSON with Core and uses it; resolves to the problems that stop it, empty once applied. */
    @api applySchema;

    draft = '';
    problems = [];
    isApplying = false;

    connectedCallback() {
        this.draft = this.inputSchema || '';
    }

    get hasProblems() {
        return this.problems.length > 0;
    }

    handleChange(event) {
        this.draft = event.detail.value;
    }

    async handleApply() {
        const editor = this.template.querySelector('c-json-editor');
        if (editor && !editor.reportValidity()) {
            return;
        }
        this.isApplying = true;
        this.disableClose = true;
        let problems;
        try {
            problems = (await this.applySchema(this.draft)) || [];
        } catch (error) {
            problems = [error?.body?.message || error?.message || 'The Input Schema could not be read.'];
        }
        this.isApplying = false;
        this.disableClose = false;
        this.problems = problems;
        if (!problems.length) {
            this.close('applied');
            return;
        }
        // Move focus to the problems so a screen reader announces them.
        Promise.resolve().then(() => this.template.querySelector('[data-problems]')?.focus());
    }

    handleCancel() {
        this.close();
    }
}
