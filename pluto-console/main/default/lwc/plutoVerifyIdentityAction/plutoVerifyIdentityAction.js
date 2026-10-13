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
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import verifyExecutionIdentity from '@salesforce/apex/AgentRunOperatorController.verifyExecutionIdentity';

/**
 * Verify in the execution identity record page's highlights panel. Signs in
 * through the credential as the current user, stores the result on the
 * identity, and refreshes the page so it shows that result.
 */
export default class PlutoVerifyIdentityAction extends LightningElement {
    @api recordId;
    running = false;

    @api
    async invoke() {
        if (this.running) {
            return;
        }
        this.running = true;
        try {
            const result = await verifyExecutionIdentity({ identityId: this.recordId });
            this.dispatchEvent(
                new ShowToastEvent({
                    title: result.verified ? 'Execution identity verified' : 'Verify found a problem',
                    message: result.message,
                    variant: result.verified ? 'success' : 'warning'
                })
            );
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]).catch(() => {});
        } catch (error) {
            const message = error?.body?.message || 'Verify could not run.';
            this.dispatchEvent(new ShowToastEvent({ title: 'Verify failed', message, variant: 'error' }));
        } finally {
            this.running = false;
        }
    }
}
