/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';

const AGENT_RESPONSE_CHANNEL = '/event/AgentResponse__e';
const TRANSIENT_MESSAGE_CHANNEL = '/event/TransientMessage__e';

export class EventSubscriptionManager {
    constructor({ errorHandler, onAgentResponse, onTransientMessage }) {
        this.errorHandler = errorHandler;
        this.onAgentResponse = onAgentResponse;
        this.onTransientMessage = onTransientMessage;

        this.agentResponseSubscription = null;
        this.transientMessageSubscription = null;
        this.isEmpApiEnabled = false;

        this._initialize();
    }

    async _initialize() {
        this._registerErrorListener();
        this.isEmpApiEnabled = await isEmpEnabled();
        if (!this.isEmpApiEnabled) {
            this.errorHandler.handleError('EMP API is not enabled', new Error('Streaming API is disabled for this user.'));
            return;
        }

        this._subscribeToAgentResponses();
    }

    async initializeTransientSubscription() {
        if (!this.isEmpApiEnabled || this.transientMessageSubscription) {
            return;
        }
        await this._subscribeToTransientMessages();
    }

    async _subscribeToAgentResponses() {
        try {
            console.log(`Subscribing to: ${AGENT_RESPONSE_CHANNEL}`);
            this.agentResponseSubscription = await subscribe(AGENT_RESPONSE_CHANNEL, -1, this.onAgentResponse.bind(this));
        } catch (error) {
            this.errorHandler.handleError('Agent Response subscription failed', error);
        }
    }

    async _subscribeToTransientMessages() {
        try {
            console.log(`Subscribing to: ${TRANSIENT_MESSAGE_CHANNEL}`);
            this.transientMessageSubscription = await subscribe(TRANSIENT_MESSAGE_CHANNEL, -1, this.onTransientMessage.bind(this));
        } catch (error) {
            this.errorHandler.handleError('Transient Message subscription failed', error);
        }
    }

    _registerErrorListener() {
        onError((error) => {
            console.error('EMP API error:', error);
            this.errorHandler.handleError('Streaming API error', error, false);
        });
    }

    cleanup() {
        if (this.agentResponseSubscription) {
            unsubscribe(this.agentResponseSubscription, (response) => console.log('Unsubscribed from AgentResponse__e:', response));
        }
        if (this.transientMessageSubscription) {
            unsubscribe(this.transientMessageSubscription, (response) => console.log('Unsubscribed from TransientMessage__e:', response));
        }
    }
}
