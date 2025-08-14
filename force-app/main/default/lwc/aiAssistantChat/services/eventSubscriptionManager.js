/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Handles EMP API event channel subscriptions for agent responses and transient messages.
 * Manages initialization, reconnection, and cleanup for real-time chat events.
 */
import { UniversalEmpApi } from 'c/universalEmpApi';

const AGENT_RESPONSE_CHANNEL = '/event/AgentResponse__e';
const TRANSIENT_MESSAGE_CHANNEL = '/event/TransientMessage__e';

export class EventSubscriptionManager {
    /**
     * @param {Object} options
     * @param {ErrorHandler} options.errorHandler
     * @param {Function} options.onAgentResponse
     * @param {Function} options.onTransientMessage
     * @param {boolean} [options.useCommunityMode=false]
     */
    constructor({ errorHandler, onAgentResponse, onTransientMessage, useCommunityMode = false }) {
        this.errorHandler = errorHandler;
        this.onAgentResponse = onAgentResponse;
        this.onTransientMessage = onTransientMessage;
        this.useCommunityMode = useCommunityMode;
        this.empApi = new UniversalEmpApi();
        this.transientSubscriptionInitialized = false;
        this._initializationPromise = this._initialize();
    }

    /**
     * Initializes the EMP API and subscribes to agent response events.
     * @private
     */
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

    /**
     * Returns a promise that resolves when initialization is complete.
     */
    async waitForInitialization() {
        return this._initializationPromise;
    }

    /**
     * Subscribes to the transient message event channel if not already subscribed.
     */
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

    /**
     * Reconnects the EMP API and re-subscribes to all necessary channels.
     */
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
                console.error('[EventSubscriptionManager] Failed to resubscribe to agent response channel:', subscribeError);
                throw subscribeError;
            }
            if (this.transientSubscriptionInitialized) {
                try {
                    await this.empApi.subscribe(TRANSIENT_MESSAGE_CHANNEL, -1, this.onTransientMessage.bind(this));
                } catch (transientSubscribeError) {
                    console.error('[EventSubscriptionManager] Failed to resubscribe to transient message channel:', transientSubscribeError);
                    this.transientSubscriptionInitialized = false;
                }
            }
            console.info('[EventSubscriptionManager] Reconnection successful');
        } catch (error) {
            this.errorHandler.handleError('Failed to reconnect event subscriptions', error);
            throw error;
        }
    }

    /**
     * Returns true if the EMP API is connected.
     */
    isConnected() {
        return this.empApi?.isConnected() || false;
    }

    /**
     * Cleans up the EMP API connection.
     */
    cleanup() {
        this.empApi.cleanup();
    }
}
