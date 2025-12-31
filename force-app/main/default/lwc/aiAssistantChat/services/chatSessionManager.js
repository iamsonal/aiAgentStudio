/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Handles agent execution lifecycle, conversation history, and message sending for the AI Assistant Chat LWC.
 * Now operates on the unified AgentExecution__c and ExecutionStep__c data model.
 * Manages session restoration, new session creation, message formatting, and error handling.
 */
import { formatDisplayMessages } from '../utils/messageFormatter';
import { INITIAL_HISTORY_LOAD_SIZE } from '../utils/constants';

import sendMessage from '@salesforce/apex/ConversationalChatController.sendMessage';
import createNewChatSession from '@salesforce/apex/ConversationalChatController.createNewChatSession';
import getChatHistory from '@salesforce/apex/ConversationalChatController.getChatHistory';
import getMostRecentSession from '@salesforce/apex/ConversationalChatController.getMostRecentSession';

export class ChatSessionManager {
    /**
     * @param {Object} options
     * @param {string} options.agentDeveloperName
     * @param {ErrorHandler} options.errorHandler
     * @param {LoadingStateManager} options.loadingManager
     * @param {EventSubscriptionManager} options.eventManager
     * @param {Function} options.onMessagesUpdated
     * @param {Function} options.onSessionChanged
     */
    constructor({ agentDeveloperName, errorHandler, loadingManager, eventManager, onMessagesUpdated, onSessionChanged }) {
        this.agentDeveloperName = agentDeveloperName;
        this.errorHandler = errorHandler;
        this.loadingManager = loadingManager;
        this.eventManager = eventManager;
        this.onMessagesUpdated = onMessagesUpdated;
        this.onSessionChanged = onSessionChanged;

        this.currentSessionId = null;
        this.messages = [];
        this.oldestMessageTimestamp = null;
        this.hasMoreHistory = false;
        this.topMessageKeyBeforeLoad = null;
    }

    // === Public Methods ===
    /**
     * Initializes the chat session (restores or creates new as needed).
     * @param {string|null} contextRecordId
     */
    async initializeSession(contextRecordId) {
        try {
            const sessionDetails = await getMostRecentSession({
                agentDeveloperName: this.agentDeveloperName,
                recordId: contextRecordId
            });

            if (sessionDetails?.sessionId) {
                this.currentSessionId = sessionDetails.sessionId;
                this.onSessionChanged(this.currentSessionId);
                if (sessionDetails.transientMessagesEnabled) {
                    this.eventManager.initializeTransientSubscription();
                }
                await this._loadSessionContent(sessionDetails.welcomeMessage);
            } else {
                await this.startNewSession(contextRecordId);
            }
        } catch (error) {
            this.errorHandler.handleError('Failed to initialize session', error);
            throw error;
        }
    }

    /**
     * Starts a new chat session and resets state.
     * @param {string|null} contextRecordId
     */
    async startNewSession(contextRecordId) {
        try {
            this.loadingManager.setLoading('history', true);
            const sessionDetails = await createNewChatSession({
                recordId: contextRecordId,
                requestedAgentDevName: this.agentDeveloperName
            });
            this.currentSessionId = sessionDetails.sessionId;
            this.onSessionChanged(this.currentSessionId);
            this._clearState();
            if (sessionDetails.transientMessagesEnabled) {
                this.eventManager.initializeTransientSubscription();
            }
            await this._loadSessionContent(sessionDetails.welcomeMessage);
        } catch (error) {
            this.errorHandler.handleError('Failed to start new session', error);
            throw error;
        } finally {
            this.loadingManager.setLoading('history', false);
        }
    }

    /**
     * Sends a user message to the server and updates state.
     * @param {string} messageText
     * @param {string|null} contextRecordId
     * @param {string} turnIdentifier
     */
    async sendMessage(messageText, contextRecordId, turnIdentifier) {
        if (!this.currentSessionId) {
            throw new Error('No active session');
        }
        try {
            this._addUserMessage(messageText, turnIdentifier);
            this.loadingManager.setLoading('sending', true);
            const response = await sendMessage({
                sessionId: this.currentSessionId,
                userMessage: messageText,
                currentRecordId: contextRecordId,
                turnIdentifier: turnIdentifier
            });
            
            // Check if the response indicates an error
            if (response && response.success === false) {
                this.loadingManager.setLoading('sending', false);
                const errorMessage = response.error || 'Failed to send message. Please try again.';
                this._addSystemErrorMessage(errorMessage);
                throw new Error(errorMessage);
            }
        } catch (error) {
            this.loadingManager.setLoading('sending', false);
            // Only add system error message if we haven't already added one
            if (!error.message || !error.message.includes('Processing error:')) {
                this._addSystemErrorMessage('Failed to send message. Please try again.');
            }
            throw error;
        }
    }

    /**
     * Loads more chat history (older messages) if available.
     */
    async loadMoreHistory() {
        if (!this.canLoadMore() || this.loadingManager.isLoading('loadingMore')) {
            return;
        }
        try {
            this.loadingManager.setLoading('loadingMore', true);
            this.topMessageKeyBeforeLoad = this.messages[0]?.displayKey || null;
            const olderMessages = await getChatHistory({
                sessionId: this.currentSessionId,
                limitCount: INITIAL_HISTORY_LOAD_SIZE,
                oldestMessageTimestamp: this.oldestMessageTimestamp
            });
            if (olderMessages?.length > 0) {
                const formatted = formatDisplayMessages(olderMessages);
                this.messages = [...formatted, ...this.messages];
                this.oldestMessageTimestamp = formatted[0].timestamp;
                this.hasMoreHistory = olderMessages.length === INITIAL_HISTORY_LOAD_SIZE;
                this.onMessagesUpdated([...this.messages]);
            } else {
                this.hasMoreHistory = false;
            }
        } catch (error) {
            this.errorHandler.handleError('Failed to load more history', error);
        } finally {
            this.loadingManager.setLoading('loadingMore', false);
        }
    }

    /**
     * Reloads the chat history for the current session.
     */
    async reloadHistory() {
        await this._loadSessionContent();
    }

    /**
     * Handles agent response events and updates message state.
     * @param {Object} response
     */
    handleAgentResponse(response) {
        const payload = response?.data?.payload;
        if (!payload || payload.AgentExecutionId__c !== this.currentSessionId) {
            return;
        }
        this.loadingManager.setLoading('sending', false);
        // Only add a message IF there is final content. The transient message is already displayed.
        if (payload.IsSuccess__c && payload.FinalMessageContent__c) {
            // Check if this message was already added via the transient event
            if (!this.messages.some((msg) => msg.id === payload.FinalAssistantMessageId__c)) {
                this._addAssistantMessage(payload.FinalMessageContent__c, payload.FinalAssistantMessageId__c);
            }
        } else if (!payload.IsSuccess__c) {
            const errorMsg = payload.ErrorDetails__c || 'Agent processing failed';
            this._addSystemErrorMessage(errorMsg);
        }
    }

    /**
     * Adds a transient ("thinking...") assistant message if not already present.
     * @param {string} content
     * @param {string} messageId
     */
    addTransientAssistantMessage(content, messageId) {
        // De-duplication is critical in case of event replay
        if (this.messages.some((msg) => msg.id === messageId)) {
            return;
        }
        this._addTransientAssistantMessage(content, messageId);
    }

    /**
     * Returns true if more history can be loaded.
     */
    canLoadMore() {
        return this.hasMoreHistory && !this.loadingManager.isLoading('history');
    }

    /**
     * Returns the key of the top message before loading more history.
     */
    getTopMessageKeyBeforeLoad() {
        return this.topMessageKeyBeforeLoad;
    }
    /**
     * Clears the stored top message key.
     */
    clearTopMessageKey() {
        this.topMessageKeyBeforeLoad = null;
    }

    // === Private Methods ===
    /**
     * Loads the session content (history or welcome message).
     * @param {string|null} prefetchedWelcomeMessage
     * @private
     */
    async _loadSessionContent(prefetchedWelcomeMessage = null) {
        if (!this.currentSessionId) return;
        try {
            this.loadingManager.setLoading('history', true);
            this._clearState();
            const historyResult = await getChatHistory({
                sessionId: this.currentSessionId,
                limitCount: INITIAL_HISTORY_LOAD_SIZE,
                oldestMessageTimestamp: null
            });
            if (historyResult?.length > 0) {
                // Load existing history
                const formatted = formatDisplayMessages(historyResult);
                this.messages = formatted;
                this.oldestMessageTimestamp = formatted[0].timestamp;
                this.hasMoreHistory = historyResult.length === INITIAL_HISTORY_LOAD_SIZE;
            } else {
                // Show welcome message for empty session
                this.hasMoreHistory = false;
                const welcomeMsg = prefetchedWelcomeMessage || (await this._fetchWelcomeMessage());
                if (welcomeMsg) {
                    this._addWelcomeMessage(welcomeMsg);
                }
            }
            this.onMessagesUpdated([...this.messages]);
        } catch (error) {
            this.errorHandler.handleError('Failed to load session content', error);
        } finally {
            this.loadingManager.setLoading('history', false);
        }
    }

    /**
     * Fetches the welcome message for a new/empty session.
     * @private
     */
    async _fetchWelcomeMessage() {
        try {
            const details = await getMostRecentSession({
                agentDeveloperName: this.agentDeveloperName,
                recordId: null
            });
            return details?.welcomeMessage;
        } catch (error) {
            return null;
        }
    }

    /**
     * Adds a user message to the local message list.
     * @param {string} content
     * @param {string} turnIdentifier
     * @private
     */
    _addUserMessage(content, turnIdentifier) {
        const userMsg = {
            role: 'user',
            content,
            timestamp: Date.now(),
            externalId: turnIdentifier,
            turnIdentifier: turnIdentifier
        };
        const formatted = formatDisplayMessages([userMsg], this.messages.length)[0];
        this.messages = [...this.messages, formatted];
        this.onMessagesUpdated([...this.messages]);
    }

    /**
     * Adds an assistant message to the local message list.
     * @param {string} content
     * @param {string} messageId
     * @private
     */
    _addAssistantMessage(content, messageId) {
        const assistantMsg = {
            id: messageId,
            role: 'assistant',
            content,
            timestamp: Date.now(),
            externalId: `msg-${messageId}`
        };
        const formatted = formatDisplayMessages([assistantMsg], this.messages.length)[0];
        this.messages = [...this.messages, formatted];
        this.onMessagesUpdated([...this.messages]);
    }

    /**
     * Adds a transient assistant message to the local message list.
     * @param {string} content
     * @param {string} messageId
     * @private
     */
    _addTransientAssistantMessage(content, messageId) {
        const transientMsg = {
            id: messageId,
            role: 'assistant',
            content,
            timestamp: Date.now(),
            externalId: `transient-${messageId}`,
            isTransient: true
        };
        const formatted = formatDisplayMessages([transientMsg], this.messages.length)[0];
        this.messages = [...this.messages, formatted];
        this.onMessagesUpdated([...this.messages]);
    }

    /**
     * Adds a welcome message to the local message list.
     * @param {string} content
     * @private
     */
    _addWelcomeMessage(content) {
        const welcomeMsg = {
            role: 'assistant',
            content,
            timestamp: Date.now(),
            externalId: `welcome-${this.currentSessionId}`
        };
        const formatted = formatDisplayMessages([welcomeMsg], this.messages.length)[0];
        this.messages = [formatted];
        this.onMessagesUpdated([...this.messages]);
    }

    /**
     * Adds a system error message to the local message list.
     * @param {string} errorMessage
     * @private
     */
    _addSystemErrorMessage(errorMessage) {
        const systemMsg = {
            role: 'system',
            content: `System Error: ${errorMessage}`,
            timestamp: Date.now(),
            externalId: `error-${Date.now()}`,
            isSystemError: true
        };
        const formatted = formatDisplayMessages([systemMsg], this.messages.length)[0];
        this.messages = [...this.messages, formatted];
        this.onMessagesUpdated([...this.messages]);
    }

    /**
     * Clears all local state for a new session.
     * @private
     */
    _clearState() {
        this.messages = [];
        this.oldestMessageTimestamp = null;
        this.hasMoreHistory = false;
        this.topMessageKeyBeforeLoad = null;
    }
}
