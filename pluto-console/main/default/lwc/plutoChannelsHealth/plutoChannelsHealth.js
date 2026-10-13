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

import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getChannelsHealth from '@salesforce/apex/PlutoChannelsController.getChannelsHealth';
import installChannelsSweep from '@salesforce/apex/PlutoChannelsController.installChannelsSweep';
import retryChannelMessage from '@salesforce/apex/PlutoChannelsController.retryChannelMessage';

/** Agent Channels health on the Pluto Overview: message counts, the hourly sweep, and parked emails to retry. */
export default class PlutoChannelsHealth extends NavigationMixin(LightningElement) {
    health;
    busy = false;
    errorMessage;

    connectedCallback() {
        this.load();
    }

    load = async () => {
        await this.run(async () => {
            this.health = await getChannelsHealth();
        });
    };

    get available() {
        return this.health?.available === true;
    }

    get snapshot() {
        return this.health?.snapshot || {};
    }

    get sweepMissing() {
        return this.available && this.snapshot.sweepInstalled !== true;
    }

    get tiles() {
        const snapshot = this.snapshot;
        return [
            { key: 'received', label: 'Waiting to start', value: snapshot.overdueReceived ?? 0, tone: 'error' },
            { key: 'queued', label: 'Queued over 15 minutes', value: snapshot.overdueQueued ?? 0, tone: 'warning' },
            { key: 'long', label: 'With a run over 24 hours', value: snapshot.longRunning ?? 0, tone: 'warning' },
            { key: 'parked', label: 'Parked', value: snapshot.parked ?? 0, tone: 'warning' }
        ].map((tile) => ({ ...tile, className: `tile${tile.value > 0 ? ` tile_${tile.tone}` : ''}` }));
    }

    get parkedMessages() {
        return (this.health?.parked || []).map((message) => ({ ...message, retryLabel: `Retry ${message.name}` }));
    }

    get hasParked() {
        return this.parkedMessages.length > 0;
    }

    async handleInstall() {
        if (await this.run(() => installChannelsSweep())) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Channel sweep installed', variant: 'success' }));
            await this.load();
        }
    }

    async handleRetry(event) {
        const messageId = event.target.dataset.id;
        let accepted;
        if (
            await this.run(async () => {
                accepted = await retryChannelMessage({ messageId });
            })
        ) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: accepted ? 'Message accepted' : 'Still parked',
                    message: accepted ? 'The message goes to its agent.' : 'Fix the cause shown in its issue code, then retry.',
                    variant: accepted ? 'success' : 'warning'
                })
            );
            await this.load();
        }
    }

    handleOpenMessages() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: { objectApiName: 'AgentChannelMessage__c', actionName: 'list' },
            state: { filterName: 'Recent' }
        });
    }

    async run(work) {
        this.busy = true;
        this.errorMessage = undefined;
        try {
            await work();
            return true;
        } catch (error) {
            this.errorMessage = error?.body?.message || error?.message || 'Agent Channels health is unavailable.';
            return false;
        } finally {
            this.busy = false;
        }
    }
}
