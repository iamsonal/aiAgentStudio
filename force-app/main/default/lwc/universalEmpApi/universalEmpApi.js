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
import fetchSessionId from '@salesforce/apex/ConversationalChatController.fetchSessionId';

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
        this.maxReconnectAttempts = 5;
        this.handshakeTimeout = null;
        this.communityMode = false; // Track the mode setting
        this.errorListenerRegistered = false; // Track if error listener is registered
        this.cometdScriptLoaded = false; // Track if CometD script is loaded
        this.initializationInProgress = false; // Prevent race conditions
        this.reconnectTimeout = null; // Track reconnection timeout
        this.lastActivityTime = Date.now(); // Track last activity for idle detection
    }

    /**
     * Initialize the Universal EmpApi
     * @param {Function} errorCallback - Optional callback for error handling
     * @param {boolean} forceCommunityMode - Optional flag to force community mode (CometD)
     */
    async initialize(errorCallback = null, forceCommunityMode = null) {
        if (this.initialized) return;

        // Prevent race conditions from multiple simultaneous initialize calls
        if (this.initializationInProgress) {
            console.warn('UniversalEmpApi: Initialization already in progress');
            return;
        }

        this.initializationInProgress = true;
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
        this.initializationInProgress = false;
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
        this._updateActivityTime();

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
        console.info('UniversalEmpApi: Starting cleanup');

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

        // Clear any pending reconnect timeout
        if (this.reconnectTimeout) {
            clearTimeout(this.reconnectTimeout);
            this.reconnectTimeout = null;
        }

        // Unsubscribe from all channels
        const channels = Array.from(this.subscriptions.keys());
        for (const channel of channels) {
            try {
                this.unsubscribe(channel);
            } catch (error) {
                console.warn(`UniversalEmpApi: Error unsubscribing from ${channel}:`, error);
            }
        }

        // Properly disconnect CometD if used
        if (this.useCometD && this.cometd) {
            try {
                if (typeof this.cometd.disconnect === 'function') {
                    this.cometd.disconnect();
                }
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
        this.errorListenerRegistered = false;
        this.initializationInProgress = false;

        console.info('UniversalEmpApi: Cleanup complete');
    }

    /**
     * Initialize CometD for Community/Experience Cloud environments.
     * Loads the CometD library, fetches a session ID, and performs handshake.
     * @private
     */
    async _initializeCometD() {
        try {
            this.sessionId = await fetchSessionId();

            // Only load the script if it hasn't been loaded yet
            if (!this.cometdScriptLoaded) {
                await loadScript(this, cometdLib + '/cometd.js');
                this.cometdScriptLoaded = true;
            }

            if (!window.org || !window.org.cometd || !window.org.cometd.CometD) {
                throw new Error('CometD library not properly loaded');
            }

            // Clean up existing CometD instance if present
            if (this.cometd) {
                try {
                    if (typeof this.cometd.disconnect === 'function') {
                        this.cometd.disconnect();
                    }
                } catch (error) {
                    console.warn('UniversalEmpApi: Error disconnecting existing CometD:', error);
                }
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
            // Wrap the callback to update activity time and handle errors
            const wrappedCallback = (message) => {
                this._updateActivityTime();
                try {
                    callback(message);
                } catch (callbackError) {
                    const serializedError = this._serializeError(callbackError);
                    console.error(`UniversalEmpApi: Error in callback for ${channel}:`, serializedError);
                    this._handleError(`Callback error for ${channel}`, serializedError);
                }
            };

            return await subscribe(channel, replayId, wrappedCallback);
        } catch (error) {
            const serializedError = this._serializeError(error);
            this._handleError(`EmpApi subscription to ${channel} failed`, serializedError);
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
                    // Update activity time when message is received
                    this._updateActivityTime();

                    try {
                        // Transform CometD message format to match empApi format
                        const transformedMessage = {
                            data: {
                                payload: message.data.payload
                            }
                        };
                        callback(transformedMessage);
                    } catch (callbackError) {
                        const serializedError = this._serializeError(callbackError);
                        console.error(`UniversalEmpApi: Error in callback for ${channel}:`, serializedError);
                        this._handleError(`Callback error for ${channel}`, serializedError);
                    }
                },
                { replay: replayId },
                (subscriptionReply) => {
                    if (!subscriptionReply.successful) {
                        const errorMsg = subscriptionReply.error || 'Unknown subscription error';
                        const serializedError = this._serializeError(errorMsg);
                        this._handleError(`CometD subscription to ${channel} failed`, serializedError);
                    }
                }
            );
        } catch (error) {
            const serializedError = this._serializeError(error);
            this._handleError(`CometD subscription to ${channel} failed`, serializedError);
            throw error;
        }
    }

    /**
     * Register a global error listener for EmpApi errors.
     * @private
     */
    _registerErrorListener() {
        // Only register once to prevent memory leaks
        if (this.errorListenerRegistered) {
            return;
        }

        onError((error) => {
            // Pass the raw error object, let _handleError serialize it
            this._handleError('EmpApi streaming error', error);
        });

        this.errorListenerRegistered = true;
    }

    /**
     * Handle errors by invoking the error callback or logging to the console.
     * @private
     * @param {string} message - Error message/context
     * @param {any} error - Error object or string
     * @param {boolean} silent - If true, only log to console without invoking callback
     */
    _handleError(message, error, silent = false) {
        // Serialize error if it's an object to prevent display issues
        const processedError = error && typeof error === 'object' ? this._serializeError(error) : error;

        // Always log to console for debugging
        console.error(`UniversalEmpApi: ${message}`, processedError, error);

        // Only invoke callback if not silent mode
        if (!silent && this.errorCallback) {
            this.errorCallback(message, processedError);
        }
    }

    /**
     * Serialize error objects to extract meaningful information.
     * Prevents incomplete error messages like "message:" in toasts.
     * @private
     */
    _serializeError(error) {
        if (!error) {
            return 'Unknown error';
        }

        // If it's already a string, return it
        if (typeof error === 'string') {
            return error;
        }

        // Extract error information from various error formats
        try {
            // EmpApi errors might be objects with different structures
            if (error.message) {
                return error.message;
            }

            // CometD errors might have error property
            if (error.error) {
                if (typeof error.error === 'string') {
                    return error.error;
                }
                if (error.error.message) {
                    return error.error.message;
                }
            }

            // Salesforce Apex errors might have body
            if (error.body) {
                if (error.body.message) {
                    return error.body.message;
                }
                if (typeof error.body === 'string') {
                    return error.body;
                }
            }

            // Check for statusText (HTTP errors)
            if (error.statusText) {
                return error.statusText;
            }

            // For objects without clear error message, try JSON stringify
            // But catch circular reference errors
            try {
                // Create a safe copy with only serializable properties
                const safeError = {};
                for (const key in error) {
                    if (Object.prototype.hasOwnProperty.call(error, key)) {
                        const value = error[key];
                        // Only include primitive values and avoid functions/circular refs
                        if (value !== null && typeof value !== 'function' && typeof value !== 'undefined') {
                            if (typeof value === 'object') {
                                // For nested objects, just use toString
                                safeError[key] = String(value);
                            } else {
                                safeError[key] = value;
                            }
                        }
                    }
                }

                const stringified = JSON.stringify(safeError);
                // Only return if it's meaningful (not just "{}")
                if (stringified && stringified !== '{}' && stringified !== '[]') {
                    return stringified;
                }
            } catch (jsonError) {
                console.warn('UniversalEmpApi: Error serializing error object:', jsonError);
            }

            // Last resort: convert to string
            const errorString = String(error);
            // If toString just gives [object Object], try to extract constructor name
            if (errorString === '[object Object]') {
                const constructorName = error.constructor?.name || 'Unknown';
                return `${constructorName} error (no message available)`;
            }
            return errorString;
        } catch (serializationError) {
            console.warn('UniversalEmpApi: Error during error serialization:', serializationError);
            return 'Error occurred but could not be serialized';
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
     * Update last activity time
     * @private
     */
    _updateActivityTime() {
        this.lastActivityTime = Date.now();
    }

    /**
     * Check if connection is healthy and attempt reconnection if needed
     * Monitors idle state and triggers reconnection for CometD connections.
     * @private
     */
    async _checkConnectionHealth() {
        if (!this.initialized) return;

        try {
            const isConnected = this.isConnected();
            const timeSinceLastActivity = Date.now() - this.lastActivityTime;
            const isIdle = timeSinceLastActivity > 120000; // 2 minutes idle

            // If disconnected and we have active subscriptions, attempt reconnection
            if (!isConnected && this.subscriptions.size > 0) {
                console.warn('UniversalEmpApi: Connection lost, attempting reconnection', {
                    useCometD: this.useCometD,
                    isEmpApiEnabled: this.isEmpApiEnabled,
                    reconnectAttempts: this.reconnectAttempts,
                    activeSubscriptions: this.subscriptions.size
                });

                await this._scheduleReconnection(false); // Not silent, user should know
            }
            // For CometD, check idle state and preemptively refresh connection
            else if (this.useCometD && isIdle && this.subscriptions.size > 0) {
                console.debug('UniversalEmpApi: Idle state detected for CometD, refreshing connection');
                this._updateActivityTime(); // Reset to prevent constant reconnection
                await this._scheduleReconnection(true); // Silent mode for proactive reconnection
            }
        } catch (error) {
            console.error('UniversalEmpApi: Error during connection health check:', error);
            // Silent for health checks - these are proactive and shouldn't spam the user
            this._handleError('Connection health check failed', error, true);
        }
    }

    /**
     * Schedule a reconnection attempt with exponential backoff
     * @private
     * @param {boolean} silent - If true, suppress error toasts
     */
    async _scheduleReconnection(silent = false) {
        // Check if we've exceeded max attempts
        if (this.reconnectAttempts >= this.maxReconnectAttempts) {
            console.error('UniversalEmpApi: Max reconnection attempts reached. Please refresh the page.');
            this._handleError(
                'Max reconnection attempts reached',
                `Failed to reconnect after ${this.maxReconnectAttempts} attempts. Please refresh the page.`,
                false // Not silent - user needs to know
            );
            return;
        }

        // Clear any existing reconnect timeout
        if (this.reconnectTimeout) {
            clearTimeout(this.reconnectTimeout);
            this.reconnectTimeout = null;
        }

        this.reconnectAttempts++;

        // Calculate exponential backoff delay: 1s, 2s, 4s, 8s, 16s
        const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempts - 1), 16000);

        console.info(`UniversalEmpApi: Scheduling reconnection attempt ${this.reconnectAttempts}/${this.maxReconnectAttempts} in ${delay}ms`);

        this.reconnectTimeout = setTimeout(async () => {
            try {
                await this._attemptReconnection();
                console.info('UniversalEmpApi: Reconnection successful');
                this.reconnectAttempts = 0; // Reset on success
            } catch (error) {
                console.error('UniversalEmpApi: Reconnection attempt failed:', error);
                // Only show error toast if not in silent mode
                this._handleError('Reconnection failed', error, silent);

                // Schedule another attempt if we haven't reached max
                if (this.reconnectAttempts < this.maxReconnectAttempts) {
                    await this._scheduleReconnection(silent);
                }
            }
        }, delay);
    }

    /**
     * Attempt to reconnect the streaming connection
     * @private
     */
    async _attemptReconnection() {
        console.info('UniversalEmpApi: Starting reconnection attempt');

        try {
            if (this.useCometD && this.cometd) {
                // Store subscription info before disconnecting
                const subscriptionsToRestore = new Map(this.subscriptionCallbacks);

                // Disconnect existing connection
                try {
                    if (typeof this.cometd.disconnect === 'function') {
                        this.cometd.disconnect();
                    }
                } catch (disconnectError) {
                    console.warn('UniversalEmpApi: Error during disconnect:', disconnectError);
                }

                this.subscriptions.clear();

                // Reinitialize CometD (will fetch new session if needed)
                await this._initializeCometD();

                // Resubscribe to all channels with stored callbacks
                let successCount = 0;
                let failCount = 0;

                for (const [channel, { callback, replayId }] of subscriptionsToRestore) {
                    try {
                        const subscription = await this._subscribeCometD(channel, replayId, callback);
                        this.subscriptions.set(channel, subscription);
                        successCount++;
                        console.info(`UniversalEmpApi: Successfully resubscribed to ${channel}`);
                    } catch (error) {
                        failCount++;
                        const serializedError = this._serializeError(error);
                        console.error(`UniversalEmpApi: Failed to resubscribe to ${channel}:`, serializedError);
                        // Remove failed subscription from callbacks
                        this.subscriptionCallbacks.delete(channel);
                    }
                }

                console.info(`UniversalEmpApi: Reconnection complete. Success: ${successCount}, Failed: ${failCount}`);

                if (failCount > 0 && successCount === 0) {
                    throw new Error(`All ${failCount} subscription(s) failed to reconnect`);
                }
            } else {
                // For EmpApi, subscriptions should persist
                // Just verify they're still working
                console.info('UniversalEmpApi: EmpApi reconnection - verifying subscriptions');

                const subscriptionsToCheck = new Map(this.subscriptionCallbacks);
                for (const [channel, { callback, replayId }] of subscriptionsToCheck) {
                    try {
                        // For EmpApi, we don't need to resubscribe unless the connection is truly lost
                        // Just log that we're monitoring
                        console.debug(`UniversalEmpApi: EmpApi subscription to ${channel} being monitored`);
                    } catch (error) {
                        const serializedError = this._serializeError(error);
                        console.warn(`UniversalEmpApi: EmpApi subscription to ${channel} may have issues:`, serializedError);
                    }
                }
            }

            this._updateActivityTime(); // Reset activity timer after successful reconnection
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
