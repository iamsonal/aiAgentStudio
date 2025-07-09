/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export class ErrorHandler {
    constructor(component) {
        this.component = component;
    }

    handleError(summary, error, showToast = true) {
        const message = this._extractErrorMessage(error);
        console.error(`[${summary}]`, message, error);

        if (showToast) {
            this._showToast(summary, message, 'error');
        }

        return message;
    }

    handleCriticalError(summary, error) {
        const message = this.handleError(summary, error, true);
        this.component.criticalError = `${summary}. Please refresh or contact support. Details: ${message.substring(0, 200)}...`;
    }

    _extractErrorMessage(error) {
        if (!error) return 'An unknown error occurred.';

        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(', ');
        }

        if (error.body?.message) {
            return error.body.message;
        }

        if (error.message) {
            return error.message;
        }

        try {
            return JSON.stringify(error);
        } catch {
            return 'An unknown error occurred.';
        }
    }

    _showToast(title, message, variant = 'info', mode = 'dismissible') {
        const shortMessage = message.length > 200 ? message.substring(0, 200) + '...' : message;

        this.component.dispatchEvent(
            new ShowToastEvent({
                title,
                message: shortMessage,
                variant,
                mode: variant === 'error' ? 'sticky' : mode
            })
        );
    }
}
