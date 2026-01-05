/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Provides centralized error handling and toast notification logic for the AI Assistant Chat LWC.
 * Extracts error messages, logs errors, and updates the component's critical error state as needed.
 */
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export class ErrorHandler {
    /**
     * @param {LightningElement} component - The LWC component instance to dispatch events and set error state.
     */
    constructor(component) {
        this.component = component;
    }

    /**
     * Handles a non-critical error: logs, shows toast, and returns the error message.
     * @param {string} summary
     * @param {any} error
     * @param {boolean} [showToast=true]
     * @returns {string} Extracted error message
     */
    handleError(summary, error, showToast = true) {
        const message = this._extractErrorMessage(error);
        console.error(`[${summary}]`, message, error);
        if (showToast) {
            this._showToast(summary, message, 'error');
        }
        return message;
    }

    /**
     * Handles a critical error: logs, shows toast, and sets the component's criticalError property.
     * @param {string} summary
     * @param {any} error
     */
    handleCriticalError(summary, error) {
        const message = this.handleError(summary, error, true);
        this.component.criticalError = `${summary}. Please refresh or contact support. Details: ${message.substring(0, 200)}...`;
    }

    /**
     * Extracts a user-friendly error message from various error object shapes.
     * @param {any} error
     * @returns {string}
     * @private
     */
    _extractErrorMessage(error) {
        if (!error) return 'An unknown error occurred.';
        // Handle Salesforce LWC error structure
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

    /**
     * Shows a toast notification in the UI.
     * @param {string} title
     * @param {string} message
     * @param {string} [variant='info']
     * @param {string} [mode='dismissible']
     * @private
     */
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
