/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Manages loading state flags for the AI Assistant Chat LWC, supporting granular and global loading checks.
 * Notifies listeners on state changes.
 */
export class LoadingStateManager {
    /**
     * @param {Object} [options]
     * @param {Function} [options.onStateChange] - Callback invoked when state changes.
     */
    constructor({ onStateChange } = {}) {
        this.state = {
            initial: false,
            history: false,
            sending: false,
            loadingMore: false
        };
        this.onStateChange = onStateChange;
    }

    /**
     * Sets a loading flag and notifies listeners.
     * @param {string} key
     * @param {boolean} value
     */
    setLoading(key, value) {
        this.state = { ...this.state, [key]: value };
        if (this.onStateChange) {
            this.onStateChange(this.state);
        }
    }

    /**
     * Returns true if the specified loading flag is set.
     * @param {string} key
     * @returns {boolean}
     */
    isLoading(key) {
        return this.state[key] || false;
    }

    /**
     * Returns true if any loading flag is set.
     * @returns {boolean}
     */
    isAnyLoading() {
        return Object.values(this.state).some((loading) => loading);
    }

    /**
     * Returns a shallow copy of the current state.
     * @returns {Object}
     */
    getState() {
        return { ...this.state };
    }

    /**
     * Resets all loading flags to false.
     */
    reset() {
        Object.keys(this.state).forEach((key) => {
            this.state[key] = false;
        });
    }
}
