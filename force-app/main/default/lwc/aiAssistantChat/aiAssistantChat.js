/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

import { LightningElement, api, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';

import { ChatSessionManager } from './services/chatSessionManager';
import { EventSubscriptionManager } from './services/eventSubscriptionManager';
import { ScrollManager } from './services/scrollManager';
import { LoadingStateManager } from './services/loadingStateManager';
import { ErrorHandler } from './services/errorHandler';
import { UuidUtils } from './utils/uuid';

import startOverFromMessage from '@salesforce/apex/AIAssistantController.startOverFromMessage';

export default class AiAssistantChat extends LightningElement {
    @api recordId;
    @api cardTitle = 'AI Assistant';
    @api agentDeveloperName = 'SalesCopilot';
    @api enableStartOver = false;
    @api useCommunityMode = false;

    chatMessages = [];
    userMessageInput = '';
    currentSessionId = null;
    criticalError = null;
    loadingState = { initial: true, history: false, sending: false, loadingMore: false };

    _sessionManager;
    _eventManager;
    _scrollManager;
    _loadingManager;
    _errorHandler;

    _currentRecordId = null;
    _visibilityChangeHandler = null;

    @wire(CurrentPageReference)
    pageRefChanged(pageRef) {
        this._currentRecordId = pageRef?.attributes?.recordId || null;
    }

    async connectedCallback() {
        try {
            await this._initializeServices();
            await this._initializeChat();
            this._setupVisibilityListener();
        } catch (error) {
            this._errorHandler?.handleCriticalError('Failed to initialize component', error);
        }
    }

    disconnectedCallback() {
        this._cleanupServices();
        this._cleanupVisibilityListener();
    }

    renderedCallback() {
        this._scrollManager?.handleRenderedCallback();
    }

    async _initializeServices() {
        try {
            this._errorHandler = new ErrorHandler(this);
            this._loadingManager = new LoadingStateManager({
                onStateChange: (newState) => {
                    this.loadingState = { ...newState };
                }
            });
            this._scrollManager = new ScrollManager(this.template, this._loadingManager);

            this._eventManager = new EventSubscriptionManager({
                errorHandler: this._errorHandler,
                onAgentResponse: (response) => this._handleAgentResponse(response),
                onTransientMessage: (response) => this._handleTransientMessage(response),
                useCommunityMode: this.useCommunityMode
            });

            await this._eventManager.waitForInitialization();

            this._sessionManager = new ChatSessionManager({
                agentDeveloperName: this.agentDeveloperName,
                errorHandler: this._errorHandler,
                loadingManager: this._loadingManager,
                eventManager: this._eventManager,
                onMessagesUpdated: (messages) => this._handleMessagesUpdated(messages),
                onSessionChanged: (sessionId) => this._handleSessionChanged(sessionId)
            });
        } catch (error) {
            console.error('Service initialization failed:', error);
            throw error;
        }
    }

    _cleanupServices() {
        this._eventManager?.cleanup();
        this._scrollManager?.cleanup();
    }

    _setupVisibilityListener() {
        this._visibilityChangeHandler = () => {
            if (!document.hidden && this._eventManager) {
                setTimeout(async () => {
                    try {
                        if (!this._eventManager.isConnected()) {
                            console.log('Page became active, reconnecting event subscriptions...');
                            await this._eventManager.reconnect();
                        }
                    } catch (error) {
                        this._errorHandler.handleError('Failed to reconnect on page visibility', error);
                    }
                }, 1000);
            }
        };

        document.addEventListener('visibilitychange', this._visibilityChangeHandler);
    }

    _cleanupVisibilityListener() {
        if (this._visibilityChangeHandler) {
            document.removeEventListener('visibilitychange', this._visibilityChangeHandler);
            this._visibilityChangeHandler = null;
        }
    }

    async _initializeChat() {
        try {
            this.loadingState = { ...this.loadingState, initial: true };
            const contextRecordId = this.recordId || null;
            await this._sessionManager.initializeSession(contextRecordId);
        } catch (error) {
            this._errorHandler.handleCriticalError('Failed to initialize chat', error);
        } finally {
            this.loadingState = { ...this.loadingState, initial: false };
        }
    }

    _handleMessagesUpdated(messages) {
        this.chatMessages = messages;
        this._scrollManager.requestAutoScroll();
    }

    _handleSessionChanged(sessionId) {
        this.currentSessionId = sessionId;
    }

    _handleAgentResponse(response) {
        this._sessionManager.handleAgentResponse(response);
    }

    _handleTransientMessage(response) {
        const payload = response?.data?.payload;
        if (payload && payload.ChatSessionId__c === this.currentSessionId) {
            this._sessionManager.addTransientAssistantMessage(payload.MessageContent__c, payload.MessageId__c);
        }
    }

    async handleNewChatClick() {
        if (this.isLoading) return;

        try {
            const contextRecordId = this.recordId || null;
            await this._sessionManager.startNewSession(contextRecordId);
        } catch (error) {
            this._errorHandler.handleError('Failed to start new chat', error);
        }
    }

    async handleSendMessageClick() {
        await this._sendMessage();
    }

    async handleLoadMoreHistory() {
        try {
            await this._sessionManager.loadMoreHistory();
        } catch (error) {
            this._errorHandler.handleError('Failed to load more history', error);
        }
    }

    async _sendMessage() {
        const messageText = this.userMessageInput.trim();

        if (!messageText) {
            this._showValidationError('Please enter a message before sending.');
            return;
        }

        if (messageText.length > 32000) {
            this._showValidationError('Message is too long. Please keep it under 32,000 characters.');
            return;
        }

        if (this.isLoading || this.criticalError) {
            return;
        }

        try {
            if (!this._eventManager.isConnected()) {
                console.warn('Event connection lost, attempting to reconnect...');
                try {
                    await this._eventManager.reconnect();
                } catch (reconnectError) {
                    this._errorHandler.handleError('Failed to reconnect before sending message', reconnectError);
                    return;
                }
            }

            const contextRecordId = this._currentRecordId;
            const turnIdentifier = UuidUtils.generateUUID();

            await this._sessionManager.sendMessage(messageText, contextRecordId, turnIdentifier);
            this.userMessageInput = '';
        } catch (error) {
            this._errorHandler.handleError('Failed to send message', error);
        }
    }

    handleInputChange(event) {
        this.userMessageInput = event.target.value;
    }

    handleKeyDown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this._sendMessage();
        }
    }

    handleScroll(event) {
        this._scrollManager.handleScroll(event);

        const container = event.target;
        if (container.scrollTop <= 10 && this._sessionManager.canLoadMore() && !this.isLoading) {
            this.handleLoadMoreHistory();
        }
    }

    get isLoading() {
        return Object.values(this.loadingState).some((state) => state === true);
    }

    get isInputDisabled() {
        return this.loadingState.sending || !this.currentSessionId || !!this.criticalError;
    }

    get showLoadMoreButton() {
        return this._sessionManager?.canLoadMore() && !this.loadingState.history && !this.loadingState.loadingMore;
    }

    get isLoadingMoreHistory() {
        return this.loadingState.loadingMore || false;
    }

    get newChatTooltip() {
        return 'Start a fresh conversation. This is useful when changing topics to ensure the AI has a clean context.';
    }

    get isNewChatDisabled() {
        return this.isLoading;
    }

    async handleStartOverClick(event) {
        const externalId = event.target.dataset.messageId;
        if (!externalId) return;

        this._loadingManager.setLoading('sending', true);
        try {
            await startOverFromMessage({
                sessionId: this.currentSessionId,
                externalId: externalId
            });

            try {
                await this._sessionManager.reloadHistory();
            } catch (reloadError) {
                this._errorHandler.handleError('Failed to reload history after start over', reloadError);
            }
        } catch (error) {
            this._errorHandler.handleError('Failed to start over from message', error);
        } finally {
            this._loadingManager.setLoading('sending', false);
        }
    }

    _showValidationError(message) {
        this._errorHandler._showToast('Validation Error', message, 'warning');
    }

    get showStartOverButton() {
        return this.enableStartOver && !this.isLoading;
    }

    get inputPlaceholder() {
        if (this.criticalError) {
            return 'Chat is unavailable...';
        }
        if (this.loadingState.sending) {
            return 'Sending message...';
        }
        if (!this.currentSessionId) {
            return 'Initializing chat...';
        }
        return 'Type your message...';
    }

    get sendButtonTitle() {
        if (this.criticalError) {
            return 'Chat is unavailable';
        }
        if (this.loadingState.sending) {
            return 'Sending message...';
        }
        if (!this.currentSessionId) {
            return 'Initializing...';
        }
        return 'Send message (Enter)';
    }
}
