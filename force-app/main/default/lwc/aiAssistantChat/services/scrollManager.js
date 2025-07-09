/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

const SCROLL_TOLERANCE = 10;

export class ScrollManager {
    constructor(template, loadingManager) {
        this.template = template;
        this.loadingManager = loadingManager;
        this.isUserScrolledUp = false;
        this.pendingAutoScroll = false;
        this.topMessageKeyBeforeLoad = null;
    }

    handleScroll(event) {
        const container = event.target;
        const isAtBottom = container.scrollHeight - container.scrollTop - container.clientHeight <= SCROLL_TOLERANCE;
        this.isUserScrolledUp = !isAtBottom;
    }

    handleRenderedCallback() {
        if (this.pendingAutoScroll) {
            this.pendingAutoScroll = false;
            if (!this.loadingManager.isLoading('loadingMore') && !this.isUserScrolledUp) {
                this.scrollToBottom();
            }
        }

        if (this.topMessageKeyBeforeLoad) {
            this._restoreScrollPosition();
        }
    }

    requestAutoScroll() {
        this.pendingAutoScroll = true;
        this.isUserScrolledUp = false;
    }

    scrollToBottom() {
        const container = this.template?.querySelector('.chat-container');
        if (container) {
            container.scrollTop = container.scrollHeight;
        }
    }

    setTopMessageKeyBeforeLoad(key) {
        this.topMessageKeyBeforeLoad = key;
    }

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

    cleanup() {
        this.pendingAutoScroll = false;
        this.topMessageKeyBeforeLoad = null;
    }
}
