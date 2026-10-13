/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * Refresh Event base class
 */
export const RefreshEventName = 'lightning__refresh';
export class RefreshEvent extends CustomEvent {
    constructor() {
        super(RefreshEventName, {
            composed: true,
            cancelable: true,
            bubbles: true
        });
    }
}

let eventHandler;
let elementToRefresh;
export const registerRefreshHandler = jest.fn((element, handler) => {
    elementToRefresh = element;
    eventHandler = handler;
    window.addEventListener(
        RefreshEventName,
        eventHandler.bind(elementToRefresh)
    );
});

export const unregisterRefreshHandler = jest.fn(() => {
    window.removeEventListener(
        RefreshEventName,
        eventHandler.bind(elementToRefresh)
    );
});
