/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

export class LoadingStateManager {
    constructor({ onStateChange } = {}) {
        this.state = {
            initial: false,
            history: false,
            sending: false,
            loadingMore: false
        };
        this.onStateChange = onStateChange;
    }

    setLoading(key, value) {
        this.state = { ...this.state, [key]: value };
        if (this.onStateChange) {
            this.onStateChange(this.state);
        }
    }

    isLoading(key) {
        return this.state[key] || false;
    }

    isAnyLoading() {
        return Object.values(this.state).some((loading) => loading);
    }

    getState() {
        return { ...this.state };
    }

    reset() {
        Object.keys(this.state).forEach((key) => {
            this.state[key] = false;
        });
    }
}
