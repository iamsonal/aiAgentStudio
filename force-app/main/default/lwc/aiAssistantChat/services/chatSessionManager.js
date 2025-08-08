/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

import { formatDisplayMessages } from '../utils/messageFormatter';
import { INITIAL_HISTORY_LOAD_SIZE } from '../utils/constants';

import sendMessage from '@salesforce/apex/AIAssistantController.sendMessage';
import createNewChatSession from '@salesforce/apex/AIAssistantController.createNewChatSession';
import getChatHistory from '@salesforce/apex/AIAssistantController.getChatHistory';
import getMostRecentSession from '@salesforce/apex/AIAssistantController.getMostRecentSession';

export class ChatSessionManager {
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

    async initializeSession(contextRecordId) {
        try {
            const sessionDetails = await getMostRecentSession({
                agentDeveloperName: this.agentDeveloperName,
                recordId: contextRecordId
            });

            if (sessionDetails?.sessionId) {
                console.log(`Resuming session: ${sessionDetails.sessionId}`);
                this.currentSessionId = sessionDetails.sessionId;
                this.onSessionChanged(this.currentSessionId);

                if (sessionDetails.transientMessagesEnabled) {
                    this.eventManager.initializeTransientSubscription();
                }

                await this._loadSessionContent(sessionDetails.welcomeMessage);
            } else {
                console.log('No recent session found. Creating new one.');
                await this.startNewSession(contextRecordId);
            }
        } catch (error) {
            this.errorHandler.handleError('Failed to initialize session', error);
            throw error;
        }
    }

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

    async sendMessage(messageText, contextRecordId, turnIdentifier) {
        if (!this.currentSessionId) {
            throw new Error('No active session');
        }

        try {
            this._addUserMessage(messageText, turnIdentifier);
            this.loadingManager.setLoading('sending', true);

            await sendMessage({
                sessionId: this.currentSessionId,
                userMessage: messageText,
                currentRecordId: contextRecordId,
                turnIdentifier: turnIdentifier
            });

            console.log('Message sent successfully, waiting for response...');
        } catch (error) {
            this.loadingManager.setLoading('sending', false);
            this._addSystemErrorMessage('Failed to send message. Please try again.');
            throw error;
        }
    }

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

    async reloadHistory() {
        await this._loadSessionContent();
    }

    handleAgentResponse(response) {
        const payload = response?.data?.payload;
        if (!payload || payload.ChatSessionId__c !== this.currentSessionId) {
            return;
        }

        this.loadingManager.setLoading('sending', false);

        if (payload.IsSuccess__c && payload.FinalMessageContent__c) {
            if (!this.messages.some((msg) => msg.id === payload.FinalAssistantMessageId__c)) {
                this._addAssistantMessage(payload.FinalMessageContent__c, payload.FinalAssistantMessageId__c);
            }
        } else if (!payload.IsSuccess__c) {
            const errorMsg = payload.ErrorDetails__c || 'Agent processing failed';
            this._addSystemErrorMessage(errorMsg);
        }
    }

    addTransientAssistantMessage(content, messageId) {
        if (this.messages.some((msg) => msg.id === messageId)) {
            console.log(`Transient message with ID ${messageId} already exists. Skipping.`);
            return;
        }
        console.log(`Adding transient message with ID ${messageId}`);
        this._addTransientAssistantMessage(content, messageId);
    }

    canLoadMore() {
        return this.hasMoreHistory && !this.loadingManager.isLoading('history');
    }

    getTopMessageKeyBeforeLoad() {
        return this.topMessageKeyBeforeLoad;
    }

    clearTopMessageKey() {
        this.topMessageKeyBeforeLoad = null;
    }

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
                const formatted = formatDisplayMessages(historyResult);
                this.messages = formatted;
                this.oldestMessageTimestamp = formatted[0].timestamp;
                this.hasMoreHistory = historyResult.length === INITIAL_HISTORY_LOAD_SIZE;
            } else {
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

    async _fetchWelcomeMessage() {
        try {
            const details = await getMostRecentSession({
                agentDeveloperName: this.agentDeveloperName,
                recordId: null
            });
            return details?.welcomeMessage;
        } catch (error) {
            console.warn('Failed to fetch welcome message:', error);
            return null;
        }
    }

    _addUserMessage(content, turnIdentifier) {
        const userMsg = {
            role: 'user',
            content,
            timestamp: Date.now(),
            externalId: turnIdentifier
        };
        const formatted = formatDisplayMessages([userMsg], this.messages.length)[0];
        this.messages = [...this.messages, formatted];
        this.onMessagesUpdated([...this.messages]);
    }

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

    _clearState() {
        this.messages = [];
        this.oldestMessageTimestamp = null;
        this.hasMoreHistory = false;
        this.topMessageKeyBeforeLoad = null;
    }
}
