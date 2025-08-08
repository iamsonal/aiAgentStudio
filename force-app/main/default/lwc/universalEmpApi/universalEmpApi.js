/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';
import { loadScript } from 'lightning/platformResourceLoader';
import cometdLib from '@salesforce/resourceUrl/cometdlwc';
import fetchSessionId from '@salesforce/apex/EventSubscriptionHelper.fetchSessionId';

export class UniversalEmpApi {
    constructor() {
        this.subscriptions = new Map();
        this.subscriptionCallbacks = new Map();
        this.isEmpApiEnabled = false;
        this.useCometD = false;
        this.cometd = null;
        this.sessionId = null;
        this.initialized = false;
        this.errorCallback = null;
        this.connectionHealthInterval = null;
        this.reconnectAttempts = 0;
        this.maxReconnectAttempts = 3;
        this.handshakeTimeout = null;
        this.communityMode = false;
    }

    async initialize(errorCallback = null, forceCommunityMode = null) {
        if (this.initialized) return;

        this.errorCallback = errorCallback;

        const isCommunity = forceCommunityMode === true;
        this.communityMode = isCommunity;

        console.log('UniversalEmpApi: Environment mode -', {
            isCommunity: isCommunity,
            forceCommunityMode: forceCommunityMode,
            mode: isCommunity ? 'Community (CometD)' : 'Lightning Experience (EmpApi)'
        });

        if (isCommunity) {
            console.log('UniversalEmpApi: Using CometD for Community environment');
            this.useCometD = true;
            this.isEmpApiEnabled = false;
            await this._initializeCometD();
        } else {
            console.log('UniversalEmpApi: Using EmpApi for Lightning Experience');
            try {
                this.isEmpApiEnabled = await isEmpEnabled();
                this.useCometD = false;
                if (this.isEmpApiEnabled) {
                    this._registerErrorListener();
                    console.log('UniversalEmpApi: EmpApi enabled and initialized');
                } else {
                    console.warn('UniversalEmpApi: EmpApi not enabled, falling back to CometD');
                    this.useCometD = true;
                    await this._initializeCometD();
                }
            } catch (error) {
                console.warn('UniversalEmpApi: EmpApi initialization failed, falling back to CometD:', error);
                this.useCometD = true;
                this.isEmpApiEnabled = false;
                await this._initializeCometD();
            }
        }

        this._startConnectionHealthMonitoring();
        this.initialized = true;
    }

    async subscribe(channel, replayId = -1, callback) {
        this._validateConnection();

        let subscription;

        if (this.useCometD) {
            subscription = await this._subscribeCometD(channel, replayId, callback);
        } else {
            subscription = await this._subscribeEmpApi(channel, replayId, callback);
        }

        this.subscriptions.set(channel, subscription);
        this.subscriptionCallbacks.set(channel, { callback, replayId });
        return subscription;
    }

    async unsubscribe(channel) {
        const subscription = this.subscriptions.get(channel);
        if (!subscription) return;

        try {
            if (this.useCometD && this.cometd) {
                this.cometd.unsubscribe(subscription);
            } else {
                unsubscribe(subscription);
            }
        } catch (error) {
            console.warn(`Error unsubscribing from ${channel}:`, error);
        }

        this.subscriptions.delete(channel);
        this.subscriptionCallbacks.delete(channel);
    }

    isConnected() {
        if (this.useCometD && this.cometd) {
            if (typeof this.cometd.isConnected === 'function') {
                try {
                    return this.cometd.isConnected();
                } catch (error) {
                    console.warn('Error checking CometD connection status:', error);
                    return false;
                }
            } else {
                return this.cometd !== null;
            }
        }
        return this.isEmpApiEnabled && this.initialized;
    }

    getConnectionInfo() {
        return {
            initialized: this.initialized,
            useCometD: this.useCometD,
            isEmpApiEnabled: this.isEmpApiEnabled,
            isConnected: this.isConnected(),
            activeSubscriptions: Array.from(this.subscriptions.keys()),
            environment: this.communityMode ? 'Community' : 'Lightning Experience',
            cometdExists: this.cometd !== null,
            reconnectAttempts: this.reconnectAttempts
        };
    }

    cleanup() {
        if (this.connectionHealthInterval) {
            clearInterval(this.connectionHealthInterval);
            this.connectionHealthInterval = null;
        }

        if (this.handshakeTimeout) {
            clearTimeout(this.handshakeTimeout);
            this.handshakeTimeout = null;
        }

        for (const channel of this.subscriptions.keys()) {
            this.unsubscribe(channel);
        }

        if (this.useCometD && this.cometd) {
            try {
                this.cometd.disconnect();
                this.cometd = null;
            } catch (error) {
                console.warn('Error during CometD cleanup:', error);
            }
        }

        this.subscriptions.clear();
        this.subscriptionCallbacks.clear();
        this.sessionId = null;
        this.initialized = false;
        this.reconnectAttempts = 0;
        this.communityMode = false;
    }

    async _initializeCometD() {
        try {
            this.sessionId = await fetchSessionId();
            await loadScript(this, cometdLib + '/cometd.js');

            if (!window.org || !window.org.cometd || !window.org.cometd.CometD) {
                throw new Error('CometD library not properly loaded');
            }

            this.cometd = new window.org.cometd.CometD();
            const cometdUrl = `${window.location.protocol}//${window.location.hostname}/cometd/63.0`;

            this.cometd.configure({
                url: cometdUrl,
                requestHeaders: {
                    Authorization: `OAuth ${this.sessionId}`
                },
                appendMessageTypeToURL: false
            });

            this.cometd.websocketEnabled = false;

            return new Promise((resolve, reject) => {
                this.handshakeTimeout = setTimeout(() => {
                    this.handshakeTimeout = null;
                    reject(new Error('CometD handshake timeout after 10 seconds'));
                }, 10000);

                this.cometd.handshake((handshakeReply) => {
                    if (this.handshakeTimeout) {
                        clearTimeout(this.handshakeTimeout);
                        this.handshakeTimeout = null;
                    }

                    if (handshakeReply.successful) {
                        this.reconnectAttempts = 0;
                        resolve();
                    } else {
                        const errorMsg = handshakeReply.error || 'Unknown handshake error';
                        reject(new Error(`CometD handshake failed: ${errorMsg}`));
                    }
                });
            });
        } catch (error) {
            this._handleError('CometD initialization failed', error);
            throw error;
        }
    }

    async _subscribeEmpApi(channel, replayId, callback) {
        try {
            return await subscribe(channel, replayId, callback);
        } catch (error) {
            this._handleError(`EmpApi subscription to ${channel} failed`, error);
            throw error;
        }
    }

    async _subscribeCometD(channel, replayId, callback) {
        try {
            return this.cometd.subscribe(
                channel,
                (message) => {
                    const transformedMessage = {
                        data: {
                            payload: message.data.payload
                        }
                    };
                    callback(transformedMessage);
                },
                { replay: replayId },
                (subscriptionReply) => {
                    if (!subscriptionReply.successful) {
                        this._handleError(`CometD subscription to ${channel} failed`, new Error(subscriptionReply.error));
                    }
                }
            );
        } catch (error) {
            this._handleError(`CometD subscription to ${channel} failed`, error);
            throw error;
        }
    }

    _registerErrorListener() {
        onError((error) => {
            this._handleError('EmpApi streaming error', error);
        });
    }

    _handleError(message, error) {
        if (this.errorCallback) {
            this.errorCallback(message, error);
        } else {
            console.error(`UniversalEmpApi: ${message}`, error);
        }
    }

    _startConnectionHealthMonitoring() {
        this.connectionHealthInterval = setInterval(() => {
            this._checkConnectionHealth();
        }, 30000);
    }

    async _checkConnectionHealth() {
        if (!this.initialized) return;

        try {
            const isConnected = this.isConnected();

            if (!isConnected) {
                console.debug('UniversalEmpApi: Connection health check - not connected', {
                    useCometD: this.useCometD,
                    isEmpApiEnabled: this.isEmpApiEnabled,
                    cometdExists: this.cometd !== null,
                    reconnectAttempts: this.reconnectAttempts
                });
            }
        } catch (error) {
            console.error('Error during connection health check:', error);

            if (!error.message.includes('isConnected')) {
                this._handleError('Connection health check failed', error);
            }
        }
    }

    async _attemptReconnection() {
        try {
            if (this.useCometD && this.cometd) {
                const subscriptionsToRestore = new Map(this.subscriptionCallbacks);

                this.cometd.disconnect();
                this.subscriptions.clear();
                await this._initializeCometD();

                for (const [channel, { callback, replayId }] of subscriptionsToRestore) {
                    try {
                        const subscription = await this._subscribeCometD(channel, replayId, callback);
                        this.subscriptions.set(channel, subscription);
                        console.log(`Successfully resubscribed to ${channel}`);
                    } catch (error) {
                        console.error(`Failed to resubscribe to ${channel}:`, error);

                        this.subscriptionCallbacks.delete(channel);
                    }
                }
            } else {
                this._registerErrorListener();

                const subscriptionsToCheck = new Map(this.subscriptionCallbacks);
                for (const [channel, { callback, replayId }] of subscriptionsToCheck) {
                    try {
                        const subscription = await this._subscribeEmpApi(channel, replayId, callback);
                        this.subscriptions.set(channel, subscription);
                    } catch (error) {
                        console.warn(`EmpApi subscription to ${channel} may be stale:`, error);
                    }
                }
            }
        } catch (error) {
            console.error('Reconnection attempt failed:', error);
            throw error;
        }
    }

    _validateConnection() {
        if (!this.initialized) {
            throw new Error('UniversalEmpApi not initialized');
        }

        if (!this.isConnected()) {
            throw new Error('UniversalEmpApi connection is not active');
        }
    }
}
