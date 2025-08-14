/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Manages scroll position and auto-scroll logic for the chat message container in the AI Assistant Chat LWC.
 * Handles scroll restoration after loading history and user scroll detection.
 */
const SCROLL_TOLERANCE = 10;

export class ScrollManager {
    /**
     * @param {HTMLElement} template - The LWC template instance.
     * @param {LoadingStateManager} loadingManager
     */
    constructor(template, loadingManager) {
        this.template = template;
        this.loadingManager = loadingManager;
        this.isUserScrolledUp = false;
        this.pendingAutoScroll = false;
        this.topMessageKeyBeforeLoad = null;
    }

    /**
     * Handles scroll events and updates user scroll state.
     * @param {Event} event
     */
    handleScroll(event) {
        const container = event.target;
        const isAtBottom = container.scrollHeight - container.scrollTop - container.clientHeight <= SCROLL_TOLERANCE;
        this.isUserScrolledUp = !isAtBottom;
    }

    /**
     * Handles scroll and restoration logic after render.
     */
    handleRenderedCallback() {
        if (this.pendingAutoScroll) {
            this.pendingAutoScroll = false;
            if (!this.loadingManager.isLoading('loadingMore') && !this.isUserScrolledUp) {
                this.scrollToBottom();
            }
        }
        // Restore scroll position after loading more history
        if (this.topMessageKeyBeforeLoad) {
            this._restoreScrollPosition();
        }
    }

    /**
     * Requests auto-scroll to bottom on next render.
     */
    requestAutoScroll() {
        this.pendingAutoScroll = true;
        this.isUserScrolledUp = false;
    }

    /**
     * Scrolls the chat container to the bottom.
     */
    scrollToBottom() {
        const container = this.template?.querySelector('.chat-container');
        if (container) {
            container.scrollTop = container.scrollHeight;
        }
    }

    /**
     * Sets the key of the top message before loading more history.
     * @param {string} key
     */
    setTopMessageKeyBeforeLoad(key) {
        this.topMessageKeyBeforeLoad = key;
    }

    /**
     * Restores scroll position to the previously top message after loading more history.
     * @private
     */
    _restoreScrollPosition() {
        const chatList = this.template?.querySelector('[lwc\\:ref="chatList"]');
        const targetElement = chatList?.querySelector(`li[data-key="${this.topMessageKeyBeforeLoad}"]`);
        if (targetElement) {
            requestAnimationFrame(() => {
                const container = this.template?.querySelector('.chat-container');
                if (container) {
                    container.scrollTop = targetElement.offsetTop - container.offsetTop - 10;
                }
            });
        }
        this.topMessageKeyBeforeLoad = null;
    }

    /**
     * Cleans up any pending scroll operations.
     */
    cleanup() {
        this.pendingAutoScroll = false;
        this.topMessageKeyBeforeLoad = null;
    }
}
