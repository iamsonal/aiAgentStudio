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

/**
 * UniversalEmpApi
 *
 * A reusable service for subscribing to Salesforce Platform Events in both Lightning Experience and Communities.
 * Selects the appropriate streaming method based on the environment mode:
 *   - Lightning Experience: Uses native lightning/empApi
 *   - Community/Experience Cloud: Uses CometD with session-based authentication
 *
 * Provides a unified API for subscribing, unsubscribing, and managing event streaming connections.
 */
export class UniversalEmpApi {
    constructor() {
        this.subscriptions = new Map();
        this.subscriptionCallbacks = new Map(); // Store callbacks for reconnection
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
        this.communityMode = false; // Track the mode setting
    }

    /**
     * Initialize the Universal EmpApi
     * @param {Function} errorCallback - Optional callback for error handling
     * @param {boolean} forceCommunityMode - Optional flag to force community mode (CometD)
     */
    async initialize(errorCallback = null, forceCommunityMode = null) {
        if (this.initialized) return;

        this.errorCallback = errorCallback;

        // Use provided mode or default to Lightning Experience (EmpApi)
        const isCommunity = forceCommunityMode === true;
        this.communityMode = isCommunity; // Store the mode setting

        console.info('UniversalEmpApi: Initializing. Environment mode:', {
            isCommunity,
            forceCommunityMode,
            mode: isCommunity ? 'Community (CometD)' : 'Lightning Experience (EmpApi)'
        });

        if (isCommunity) {
            console.info('UniversalEmpApi: Using CometD for Community environment');
            this.useCometD = true;
            this.isEmpApiEnabled = false;
            await this._initializeCometD();
        } else {
            console.info('UniversalEmpApi: Using EmpApi for Lightning Experience');
            try {
                this.isEmpApiEnabled = await isEmpEnabled();
                this.useCometD = false;
                if (this.isEmpApiEnabled) {
                    this._registerErrorListener();
                    console.info('UniversalEmpApi: EmpApi enabled and initialized');
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

        // Start connection health monitoring
        this._startConnectionHealthMonitoring();
        this.initialized = true;
    }

    /**
     * Subscribe to a platform event channel
     * @param {string} channel - The platform event channel (e.g., '/event/MyEvent__e')
     * @param {number} replayId - Replay ID (-1 for only new events, -2 for all retained events)
     * @param {Function} callback - Callback function to handle received messages
     * @returns {Promise<Object>} Subscription object
     */
    async subscribe(channel, replayId = -1, callback) {
        this._validateConnection();

        let subscription;

        if (this.useCometD) {
            subscription = await this._subscribeCometD(channel, replayId, callback);
        } else {
            subscription = await this._subscribeEmpApi(channel, replayId, callback);
        }

        // Store subscription and callback for cleanup and reconnection
        this.subscriptions.set(channel, subscription);
        this.subscriptionCallbacks.set(channel, { callback, replayId });
        return subscription;
    }

    /**
     * Unsubscribe from a platform event channel
     * @param {string} channel - The platform event channel to unsubscribe from
     */
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
            console.warn(`UniversalEmpApi: Error unsubscribing from ${channel}:`, error);
        }

        this.subscriptions.delete(channel);
        this.subscriptionCallbacks.delete(channel);
    }

    /**
     * Check if the service is connected and ready
     * @returns {boolean} Connection status
     */
    isConnected() {
        if (this.useCometD && this.cometd) {
            // Check if isConnected method exists and call it, otherwise check if cometd exists
            if (typeof this.cometd.isConnected === 'function') {
                try {
                    return this.cometd.isConnected();
                } catch (error) {
                    console.warn('UniversalEmpApi: Error checking CometD connection status:', error);
                    return false;
                }
            } else {
                // Fallback: if isConnected method doesn't exist, assume connected if cometd object exists
                return this.cometd !== null;
            }
        }
        return this.isEmpApiEnabled && this.initialized;
    }

    /**
     * Get information about the current connection
     * @returns {Object} Connection information
     */
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

    /**
     * Clean up all subscriptions and connections
     */
    cleanup() {
        // Clear connection health monitoring
        if (this.connectionHealthInterval) {
            clearInterval(this.connectionHealthInterval);
            this.connectionHealthInterval = null;
        }

        // Clear any pending handshake timeout
        if (this.handshakeTimeout) {
            clearTimeout(this.handshakeTimeout);
            this.handshakeTimeout = null;
        }

        // Unsubscribe from all channels
        for (const channel of this.subscriptions.keys()) {
            this.unsubscribe(channel);
        }

        // Properly disconnect CometD if used
        if (this.useCometD && this.cometd) {
            try {
                this.cometd.disconnect();
                this.cometd = null;
            } catch (error) {
                console.warn('UniversalEmpApi: Error during CometD cleanup:', error);
            }
        }

        // Clear all references
        this.subscriptions.clear();
        this.subscriptionCallbacks.clear();
        this.sessionId = null;
        this.initialized = false;
        this.reconnectAttempts = 0;
        this.communityMode = false;
    }

    /**
     * Initialize CometD for Community/Experience Cloud environments.
     * Loads the CometD library, fetches a session ID, and performs handshake.
     * @private
     */
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
                        this.reconnectAttempts = 0; // Reset on successful connection
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

    /**
     * Subscribe to a channel using EmpApi.
     * @private
     */
    async _subscribeEmpApi(channel, replayId, callback) {
        try {
            return await subscribe(channel, replayId, callback);
        } catch (error) {
            this._handleError(`EmpApi subscription to ${channel} failed`, error);
            throw error;
        }
    }

    /**
     * Subscribe to a channel using CometD.
     * @private
     */
    async _subscribeCometD(channel, replayId, callback) {
        try {
            return this.cometd.subscribe(
                channel,
                (message) => {
                    // Transform CometD message format to match empApi format
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

    /**
     * Register a global error listener for EmpApi errors.
     * @private
     */
    _registerErrorListener() {
        onError((error) => {
            this._handleError('EmpApi streaming error', error);
        });
    }

    /**
     * Handle errors by invoking the error callback or logging to the console.
     * @private
     */
    _handleError(message, error) {
        if (this.errorCallback) {
            this.errorCallback(message, error);
        } else {
            console.error(`UniversalEmpApi: ${message}`, error);
        }
    }

    /**
     * Start monitoring connection health and auto-reconnect if needed
     * @private
     */
    _startConnectionHealthMonitoring() {
        // Check connection health every 30 seconds
        this.connectionHealthInterval = setInterval(() => {
            this._checkConnectionHealth();
        }, 30000);
    }

    /**
     * Check if connection is healthy and attempt reconnection if needed
     * Only logs connection issues; does not attempt reconnection automatically.
     * @private
     */
    async _checkConnectionHealth() {
        if (!this.initialized) return;

        try {
            const isConnected = this.isConnected();

            // Only log connection issues, don't attempt reconnection during normal health checks
            // Reconnection should be triggered by actual failures, not periodic checks
            if (!isConnected) {
                console.debug('UniversalEmpApi: Connection health check - not connected', {
                    useCometD: this.useCometD,
                    isEmpApiEnabled: this.isEmpApiEnabled,
                    cometdExists: this.cometd !== null,
                    reconnectAttempts: this.reconnectAttempts
                });
            }
        } catch (error) {
            console.error('UniversalEmpApi: Error during connection health check:', error);
            // Only handle error if it's not related to the isConnected check itself
            if (!error.message.includes('isConnected')) {
                this._handleError('Connection health check failed', error);
            }
        }
    }

    /**
     * Attempt to reconnect the streaming connection
     * @private
     */
    async _attemptReconnection() {
        try {
            if (this.useCometD && this.cometd) {
                // Store subscription info before disconnecting
                const subscriptionsToRestore = new Map(this.subscriptionCallbacks);

                // Disconnect and reinitialize
                this.cometd.disconnect();
                this.subscriptions.clear();
                await this._initializeCometD();

                // Resubscribe to all channels with stored callbacks
                for (const [channel, { callback, replayId }] of subscriptionsToRestore) {
                    try {
                        const subscription = await this._subscribeCometD(channel, replayId, callback);
                        this.subscriptions.set(channel, subscription);
                        console.info(`UniversalEmpApi: Successfully resubscribed to ${channel}`);
                    } catch (error) {
                        console.error(`UniversalEmpApi: Failed to resubscribe to ${channel}:`, error);
                        // Remove failed subscription from callbacks
                        this.subscriptionCallbacks.delete(channel);
                    }
                }
            } else {
                // For EmpApi, reinitialize the error listener
                this._registerErrorListener();

                // EmpApi subscriptions should still be active, but verify
                const subscriptionsToCheck = new Map(this.subscriptionCallbacks);
                for (const [channel, { callback, replayId }] of subscriptionsToCheck) {
                    try {
                        // Test if subscription is still active by attempting to resubscribe
                        // This will either succeed or throw an error
                        const subscription = await this._subscribeEmpApi(channel, replayId, callback);
                        this.subscriptions.set(channel, subscription);
                    } catch (error) {
                        console.warn(`UniversalEmpApi: EmpApi subscription to ${channel} may be stale:`, error);
                    }
                }
            }
        } catch (error) {
            console.error('UniversalEmpApi: Reconnection attempt failed:', error);
            throw error;
        }
    }

    /**
     * Validate connection before performing operations
     * @private
     */
    _validateConnection() {
        if (!this.initialized) {
            throw new Error('UniversalEmpApi not initialized');
        }

        if (!this.isConnected()) {
            throw new Error('UniversalEmpApi connection is not active');
        }
    }
}
