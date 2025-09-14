/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * AI Assistant Chat LWC
 *
 * Provides a robust, real-time chat interface for AI-powered conversations in both Lightning Experience and Experience Cloud.
 * Handles session management, message history, transient ("thinking...") messages, error handling, and responsive UI.
 *
 * Main Features:
 * - Real-time, bidirectional communication with AI agents
 * - Automatic session management and message persistence
 * - Transient message support (e.g., "Assistant is typing...")
 * - Responsive, accessible design
 * - Robust error handling and connection recovery
 * - Message history with pagination and start-over branching
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
    /**
     * The recordId context for the chat session (optional).
     * @type {string}
     */
    @api recordId;
    /**
     * The card title displayed in the UI.
     * @type {string}
     */
    @api cardTitle = 'AI Assistant';
    /**
     * The developer name of the AI agent to use.
     * @type {string}
     */
    @api agentDeveloperName = 'Order_Management_Copilot';
    /**
     * Enables the "Start Over" feature for conversation branching.
     * @type {boolean}
     */
    @api enableStartOver = false;
    /**
     * Set to true for Community/Experience Cloud environments.
     * @type {boolean}
     */
    @api useCommunityMode = false;

    // --- State ---
    chatMessages = [];
    userMessageInput = '';
    currentSessionId = null;
    criticalError = null;
    loadingState = { initial: true, history: false, sending: false, loadingMore: false };

    // --- Service Instances ---
    _sessionManager;
    _eventManager;
    _scrollManager;
    _loadingManager;
    _errorHandler;

    _currentRecordId = null;
    _visibilityChangeHandler = null;

    /**
     * Watches for page reference changes to update the current record context.
     */
    @wire(CurrentPageReference)
    pageRefChanged(pageRef) {
        this._currentRecordId = pageRef?.attributes?.recordId || null;
    }

    /**
     * Lifecycle: Initializes services and chat session on component mount.
     */
    async connectedCallback() {
        try {
            await this._initializeServices();
            await this._initializeChat();
            this._setupVisibilityListener();
        } catch (error) {
            this._errorHandler?.handleCriticalError('Failed to initialize component', error);
        }
    }

    /**
     * Lifecycle: Cleans up services and listeners on component unmount.
     */
    disconnectedCallback() {
        this._cleanupServices();
        this._cleanupVisibilityListener();
    }

    /**
     * Lifecycle: Handles scroll management after each render.
     */
    renderedCallback() {
        this._scrollManager?.handleRenderedCallback();
    }

    /**
     * Initializes all service modules required for chat operation.
     * Handles both synchronous and asynchronous service setup.
     * @private
     */
    async _initializeServices() {
        try {
            this._errorHandler = new ErrorHandler(this);
            this._loadingManager = new LoadingStateManager({
                onStateChange: (newState) => {
                    this.loadingState = { ...newState };
                }
            });
            this._scrollManager = new ScrollManager(this.template, this._loadingManager);

            // Event manager must be initialized before session manager
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
            // Log with context for troubleshooting
            console.error('[aiAssistantChat] Service initialization failed:', error);
            throw error;
        }
    }

    /**
     * Cleans up service instances.
     * @private
     */
    _cleanupServices() {
        this._eventManager?.cleanup();
        this._scrollManager?.cleanup();
    }

    /**
     * Sets up a listener to handle page visibility changes (e.g., tab focus/blur).
     * Used to trigger reconnection logic if the page becomes visible after being hidden.
     * @private
     */
    _setupVisibilityListener() {
        this._visibilityChangeHandler = () => {
            if (!document.hidden && this._eventManager) {
                // Page became visible, check connection health
                setTimeout(async () => {
                    try {
                        if (!this._eventManager.isConnected()) {
                            // Log with context
                            console.info('[aiAssistantChat] Page became active, reconnecting event subscriptions...');
                            await this._eventManager.reconnect();
                        }
                    } catch (error) {
                        this._errorHandler.handleError('Failed to reconnect on page visibility', error);
                    }
                }, 1000); // Small delay to ensure page is fully active
            }
        };
        document.addEventListener('visibilitychange', this._visibilityChangeHandler);
    }

    /**
     * Removes the page visibility listener.
     * @private
     */
    _cleanupVisibilityListener() {
        if (this._visibilityChangeHandler) {
            document.removeEventListener('visibilitychange', this._visibilityChangeHandler);
            this._visibilityChangeHandler = null;
        }
    }

    /**
     * Initializes the chat session (restores or creates new as needed).
     * @private
     */
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

    // === Event Handlers ===

    /**
     * Updates the chat message list and triggers auto-scroll when messages change.
     * @param {Array} messages
     * @private
     */
    _handleMessagesUpdated(messages) {
        this.chatMessages = messages;
        this._scrollManager.requestAutoScroll();
    }

    /**
     * Updates the current session ID when the session changes.
     * @param {string} sessionId
     * @private
     */
    _handleSessionChanged(sessionId) {
        this.currentSessionId = sessionId;
    }

    /**
     * Handles agent response events from the event manager.
     * @param {Object} response
     * @private
     */
    _handleAgentResponse(response) {
        this._sessionManager.handleAgentResponse(response);
    }

    /**
     * Handles transient ("thinking...") message events from the event manager.
     * @param {Object} response
     * @private
     */
    _handleTransientMessage(response) {
        const payload = response?.data?.payload;
        if (payload && payload.ChatSessionId__c === this.currentSessionId) {
            this._sessionManager.addTransientAssistantMessage(payload.MessageContent__c, payload.MessageId__c);
        }
    }

    // === User Actions ===

    /**
     * Handler for the "New Chat" button. Starts a new session.
     */
    async handleNewChatClick() {
        if (this.isLoading) return;
        try {
            const contextRecordId = this.recordId || null;
            await this._sessionManager.startNewSession(contextRecordId);
        } catch (error) {
            this._errorHandler.handleError('Failed to start new chat', error);
        }
    }

    /**
     * Handler for the "Send" button. Sends the user message.
     */
    async handleSendMessageClick() {
        await this._sendMessage();
    }

    /**
     * Handler for loading more chat history (pagination).
     */
    async handleLoadMoreHistory() {
        try {
            await this._sessionManager.loadMoreHistory();
        } catch (error) {
            this._errorHandler.handleError('Failed to load more history', error);
        }
    }

    /**
     * Sends the user's message after validation and connection checks.
     * @private
     */
    async _sendMessage() {
        const messageText = this.userMessageInput.trim();
        // Input validation
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
            // Ensure event connection is healthy before sending
            if (!this._eventManager.isConnected()) {
                // Log with context and log level
                console.warn('[aiAssistantChat] Event connection lost, attempting to reconnect...');
                try {
                    await this._eventManager.reconnect();
                } catch (reconnectError) {
                    this._errorHandler.handleError('Failed to reconnect before sending message', reconnectError);
                    return; // Don't proceed if reconnection fails
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

    // === Input Handlers ===

    /**
     * Updates the user input state as the textarea changes.
     */
    handleInputChange(event) {
        this.userMessageInput = event.target.value;
    }

    /**
     * Handles keydown events in the textarea (Enter to send, Shift+Enter for newline).
     */
    handleKeyDown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this._sendMessage();
        }
        // Shift+Enter for new lines (default behavior)
    }

    /**
     * Handles scroll events in the chat container, triggers history load if near top.
     */
    handleScroll(event) {
        this._scrollManager.handleScroll(event);
        const container = event.target;
        if (container.scrollTop <= 10 && this._sessionManager.canLoadMore() && !this.isLoading) {
            this.handleLoadMoreHistory();
        }
    }

    // === Getters for Template ===

    /**
     * Returns true if any loading state is active.
     */
    get isLoading() {
        return Object.values(this.loadingState).some((state) => state === true);
    }

    /**
     * Returns true if the input should be disabled (e.g., loading, no session, or error).
     */
    get isInputDisabled() {
        return this.loadingState.sending || !this.currentSessionId || !!this.criticalError;
    }

    /**
     * Returns true if the "Load More" button should be shown.
     */
    get showLoadMoreButton() {
        return this._sessionManager?.canLoadMore() && !this.loadingState.history && !this.loadingState.loadingMore;
    }

    /**
     * Returns true if chat history is currently loading more messages.
     */
    get isLoadingMoreHistory() {
        return this.loadingState.loadingMore || false;
    }

    /**
     * Tooltip for the "New Chat" button.
     */
    get newChatTooltip() {
        return 'Start a fresh conversation. This is useful when changing topics to ensure the AI has a clean context.';
    }

    /**
     * Returns true if the "New Chat" button should be disabled.
     */
    get isNewChatDisabled() {
        return this.isLoading;
    }

    /**
     * Handler for the "Start Over" button on a message. Branches the conversation from a specific message.
     */
    async handleStartOverClick(event) {
        const externalId = event.target.dataset.messageId;
        if (!externalId) return;
        this._loadingManager.setLoading('sending', true);
        try {
            await startOverFromMessage({
                sessionId: this.currentSessionId,
                externalId: externalId
            });
            // Reload history to show the new conversation state
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

    /**
     * Shows a validation error to the user (toast).
     * @param {string} message
     * @private
     */
    _showValidationError(message) {
        this._errorHandler._showToast('Validation Error', message, 'warning');
    }

    /**
     * Returns true if the "Start Over" button should be shown.
     */
    get showStartOverButton() {
        return this.enableStartOver && !this.isLoading;
    }

    /**
     * Returns the placeholder text for the input area based on state.
     */
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

    /**
     * Returns the title for the send button based on state.
     */
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
