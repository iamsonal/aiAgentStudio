/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

import { UniversalEmpApi } from 'c/universalEmpApi';

const AGENT_RESPONSE_CHANNEL = '/event/AgentResponse__e';
const TRANSIENT_MESSAGE_CHANNEL = '/event/TransientMessage__e';

export class EventSubscriptionManager {
    constructor({ errorHandler, onAgentResponse, onTransientMessage, useCommunityMode = false }) {
        this.errorHandler = errorHandler;
        this.onAgentResponse = onAgentResponse;
        this.onTransientMessage = onTransientMessage;
        this.useCommunityMode = useCommunityMode;

        this.empApi = new UniversalEmpApi();
        this.transientSubscriptionInitialized = false;
        this._initializationPromise = null;

        this._initializationPromise = this._initialize();
    }

    async _initialize() {
        try {
            await this.empApi.initialize((message, error) => {
                this.errorHandler.handleError(message, error);
            }, this.useCommunityMode);

            await this.empApi.subscribe(AGENT_RESPONSE_CHANNEL, -1, this.onAgentResponse.bind(this));
        } catch (error) {
            this.errorHandler.handleError('Failed to initialize event subscriptions', error);
            throw error;
        }
    }

    async waitForInitialization() {
        return this._initializationPromise;
    }

    async initializeTransientSubscription() {
        if (this.transientSubscriptionInitialized) {
            return;
        }

        try {
            await this.empApi.subscribe(TRANSIENT_MESSAGE_CHANNEL, -1, this.onTransientMessage.bind(this));
            this.transientSubscriptionInitialized = true;
        } catch (error) {
            this.errorHandler.handleError('Failed to subscribe to transient messages', error);
        }
    }

    async reconnect() {
        try {
            this.empApi.cleanup();

            this.empApi = new UniversalEmpApi();
            await this.empApi.initialize((message, error) => {
                this.errorHandler.handleError(message, error);
            }, this.useCommunityMode);

            try {
                await this.empApi.subscribe(AGENT_RESPONSE_CHANNEL, -1, this.onAgentResponse.bind(this));
            } catch (subscribeError) {
                console.error('Failed to resubscribe to agent response channel:', subscribeError);
                throw subscribeError;
            }

            if (this.transientSubscriptionInitialized) {
                try {
                    await this.empApi.subscribe(TRANSIENT_MESSAGE_CHANNEL, -1, this.onTransientMessage.bind(this));
                } catch (transientSubscribeError) {
                    console.error('Failed to resubscribe to transient message channel:', transientSubscribeError);

                    this.transientSubscriptionInitialized = false;
                }
            }

            console.log('EventSubscriptionManager: Reconnection successful');
        } catch (error) {
            this.errorHandler.handleError('Failed to reconnect event subscriptions', error);
            throw error;
        }
    }

    isConnected() {
        return this.empApi?.isConnected() || false;
    }

    cleanup() {
        this.empApi.cleanup();
    }
}
