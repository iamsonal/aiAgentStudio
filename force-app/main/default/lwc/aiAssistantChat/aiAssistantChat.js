/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CurrentPageReference } from 'lightning/navigation';
import { subscribe, unsubscribe, onError, setDebugFlag, isEmpEnabled } from 'lightning/empApi';

import { NEW_SESSION_VALUE, INITIAL_HISTORY_LOAD_SIZE } from './utils/constants';
import { formatDisplayMessages } from './utils/messageFormatter';

import sendMessage from '@salesforce/apex/AIAssistantController.sendMessage';
import createNewChatSession from '@salesforce/apex/AIAssistantController.createNewChatSession';
import getChatHistory from '@salesforce/apex/AIAssistantController.getChatHistory';
import getPreviousChatSessions from '@salesforce/apex/AIAssistantController.getPreviousChatSessions';
import getChatMessageById from '@salesforce/apex/AIAssistantController.getChatMessageById';

const SCROLL_TOLERANCE = 10;

export default class AiAssistantChat extends LightningElement {
    @api recordId;
    @api agentDeveloperName = 'SalesCopilot';
    @api cardTitle = 'AI Assistant';

    placeholderMessage = 'Start a new chat session to begin your conversation.';

    currentSessionId = null;
    chatMessages = [];
    userMessageInput = '';
    loadingState = this.getDefaultLoadingState();
    criticalError = null;
    allSessionOptions = [];
    selectedSessionValue = null;

    oldestMessageTimestamp = null;
    hasMoreHistory = false;
    isLoadingMoreHistory = false;

    _isUserScrolledUp = false;
    _isInitialLoadComplete = false;
    _currentContextRecordId = null;
    _topMessageKeyBeforeLoad = null;
    _pendingAutoScroll = false;

    channelName = '/event/AgentResponse__e';
    subscription = {};
    isSubscribed = false;

    @wire(CurrentPageReference) pageRef;

    connectedCallback() {
        this._initializeComponent();
        this._currentContextRecordId = this.recordId || null;
        this.loadPreviousSessionsAndPotentiallyDefault(this._currentContextRecordId);

        this.registerErrorListener();
        this.handleSubscribe();
    }

    disconnectedCallback() {
        this.handleUnsubscribe();
    }

    renderedCallback() {
        if (this._pendingAutoScroll) {
            this._pendingAutoScroll = false;
            if (!this.isLoadingMoreHistory && !this._isUserScrolledUp) {
                this.scrollToBottom();
            }
        }
        if (this._topMessageKeyBeforeLoad && this.refs.chatList) {
            const targetElement = this.refs.chatList.querySelector(`li[data-key="${this._topMessageKeyBeforeLoad}"]`);
            if (targetElement) {
                requestAnimationFrame(() => {
                    const container = this.template.querySelector('.chat-container');
                    if (container && targetElement) {
                        container.scrollTop = targetElement.offsetTop - container.offsetTop - 10;
                    }
                });
            }
            this._topMessageKeyBeforeLoad = null;
        }
    }

    _initializeComponent() {
        this.cardTitle = this.cardTitle || `AI Assistant (${this.agentDeveloperName})`;
        this.allSessionOptions = [{ label: 'Start New Session', value: NEW_SESSION_VALUE }];
        this.selectedSessionValue = null;
    }

    getDefaultLoadingState() {
        return {
            initial: true,
            sessions: false,
            history: false,
            sending: false,
            updatingLabel: false,
            exporting: false
        };
    }

    _resetComponentState() {
        this.currentSessionId = null;
        this.chatMessages = [];
        this.userMessageInput = '';

        this.allSessionOptions = [{ label: 'Start New Session', value: NEW_SESSION_VALUE }];
        this.selectedSessionValue = null;
        this.criticalError = null;
        this.loadingState = this.getDefaultLoadingState();
        this.oldestMessageTimestamp = null;
        this.hasMoreHistory = false;
        this.isLoadingMoreHistory = false;
        this._isUserScrolledUp = false;
        this._isInitialLoadComplete = false;
        this._pendingAutoScroll = false;
        this._topMessageKeyBeforeLoad = null;
    }

    async loadPreviousSessionsAndPotentiallyDefault(contextRecordId) {
        await this.runWithLoading('sessions', async () => {
            this._resetComponentState();
            this.updateLoadingState({ initial: true });

            let sessions = [];
            try {
                sessions = await getPreviousChatSessions({
                    agentDeveloperName: this.agentDeveloperName,
                    recordId: contextRecordId
                });
            } catch (e) {
                this.handleError('Loading session list', e, true);
                return;
            }

            this.allSessionOptions = [
                { label: 'Start New Session', value: NEW_SESSION_VALUE },
                ...sessions.map((s) => ({
                    label: s.displayLabel,
                    value: s.sessionId,
                    name: s.sessionName,
                    currentLabel: s.sessionLabel
                }))
            ];

            if (sessions.length) {
                const latestId = this.allSessionOptions[1].value;
                if (!this.selectedSessionValue || this.selectedSessionValue === NEW_SESSION_VALUE) {
                    this.selectedSessionValue = latestId;
                    this.currentSessionId = latestId;
                    await this.loadInitialHistory();
                }
            }
            this._isInitialLoadComplete = true;
            this.updateLoadingState({ initial: false });
        });
    }

    updateLoadingState(partial) {
        this.loadingState = { ...this.loadingState, ...partial };
    }

    async handleSessionChange(event) {
        const selectedValue = event.detail.value;
        if (selectedValue === this.selectedSessionValue || this.criticalError) return;

        this._clearChatAreaState();
        this.selectedSessionValue = selectedValue;

        if (selectedValue === NEW_SESSION_VALUE) {
            await this.startNewSession(this._currentContextRecordId);
        } else {
            this.currentSessionId = selectedValue;
            await this.loadInitialHistory();
        }
    }

    async runWithLoading(flag, fn) {
        if (this.loadingState[flag]) return;
        this.updateLoadingState({ [flag]: true });
        try {
            return await fn();
        } finally {
            this.updateLoadingState({ [flag]: false });
        }
    }

    async startNewSession(contextRecordId) {
        await this.runWithLoading('history', async () => {
            try {
                const newId = await createNewChatSession({
                    agentDeveloperName: this.agentDeveloperName,
                    recordId: contextRecordId
                });
                this.currentSessionId = newId;
                this.selectedSessionValue = newId;

                this.chatMessages = [];
                this.hasMoreHistory = false;
                this.oldestMessageTimestamp = null;
                this._isInitialLoadComplete = true;

                this.showToast('Success', 'New session started.', 'success');

                this.loadPreviousSessionsAndSetSelection(this._currentContextRecordId, newId);
            } catch (e) {
                this.handleError('Error starting new session', e, true);
                this.selectedSessionValue = null;
            }
        });
    }

    handleError(context, err, toast = false) {
        const msg = err?.body?.message || err?.message || JSON.stringify(err);

        console.error(`[${context}]`, msg);
        if (toast) this.showToast('Error', `${context}: ${msg}`, 'error');
    }

    showToast(title, message, variant = 'info') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    async loadPreviousSessionsAndSetSelection(contextRecordId, sessionIdToSelect) {
        this.loadingState = { ...this.loadingState, sessions: true };
        try {
            const sessions = await getPreviousChatSessions({
                agentDeveloperName: this.agentDeveloperName,
                recordId: contextRecordId
            });

            const newSessionOptions = [
                { label: 'Start New Session', value: NEW_SESSION_VALUE },
                ...sessions.map((session) => ({
                    label: session.displayLabel,
                    value: session.sessionId,
                    name: session.sessionName,
                    currentLabel: session.sessionLabel
                }))
            ];
            this.allSessionOptions = newSessionOptions;

            this.selectedSessionValue = sessionIdToSelect;

            console.log('Session dropdown refreshed after new session creation.');
        } catch (error) {
            console.error('Non-critical error refreshing session list after new session creation:', error);
            this.showToast('Warning', 'Could not refresh session list.', 'warning');
        } finally {
            this.loadingState = { ...this.loadingState, sessions: false };
        }
    }

    _clearChatAreaState() {
        this.chatMessages = [];
        this.oldestMessageTimestamp = null;
        this.hasMoreHistory = false;
        this._topMessageKeyBeforeLoad = null;
    }

    async loadInitialHistory() {
        if (!this.currentSessionId || this.loadingState.history) return;

        console.log(`Loading initial history for session ${this.currentSessionId}`);
        this.loadingState = { ...this.loadingState, history: true, initial: !this._isInitialLoadComplete };

        this.chatMessages = [];
        this.oldestMessageTimestamp = null;
        this.hasMoreHistory = false;
        this._isUserScrolledUp = false;

        try {
            const historyResult = await getChatHistory({
                sessionId: this.currentSessionId,
                limitCount: INITIAL_HISTORY_LOAD_SIZE,
                oldestMessageTimestamp: null
            });

            if (historyResult && historyResult.length > 0) {
                const formatted = formatDisplayMessages(historyResult);
                this.chatMessages = formatted;
                this.oldestMessageTimestamp = formatted[0].timestamp;
                this.hasMoreHistory = historyResult.length === INITIAL_HISTORY_LOAD_SIZE;
                console.log(`Loaded ${formatted.length} initial messages. HasMore: ${this.hasMoreHistory}`);
            } else {
                console.log('Initial history is empty.');
                this.hasMoreHistory = false;
            }
            this._requestAutoScroll();
        } catch (error) {
            this.handleError('Error loading initial chat history', error, true);
            this.chatMessages = [];
            this.hasMoreHistory = false;
        } finally {
            this.loadingState = { ...this.loadingState, history: false, initial: false };
            this._isInitialLoadComplete = true;
        }
    }

    async handleLoadMoreHistory() {
        if (!this.currentSessionId || this.isLoadingMoreHistory || !this.hasMoreHistory || this.criticalError) return;

        console.log(`Loading more history before ${this.oldestMessageTimestamp}`);
        this.isLoadingMoreHistory = true;

        this._topMessageKeyBeforeLoad = this.chatMessages.length > 0 ? this.chatMessages[0].displayKey : null;
        console.log('Tracking top message key:', this._topMessageKeyBeforeLoad);

        try {
            const olderHistoryResult = await getChatHistory({
                sessionId: this.currentSessionId,
                limitCount: INITIAL_HISTORY_LOAD_SIZE,
                oldestMessageTimestamp: this.oldestMessageTimestamp
            });

            if (olderHistoryResult && olderHistoryResult.length > 0) {
                const newMessages = formatDisplayMessages(olderHistoryResult);
                this.chatMessages = [...newMessages, ...this.chatMessages];
                this.oldestMessageTimestamp = newMessages[0].timestamp;
                this.hasMoreHistory = olderHistoryResult.length === INITIAL_HISTORY_LOAD_SIZE;
                console.log(`Loaded ${newMessages.length} older messages. HasMore: ${this.hasMoreHistory}`);
            } else {
                console.log('No more older messages found.');
                this.hasMoreHistory = false;
                this._topMessageKeyBeforeLoad = null;
            }
        } catch (error) {
            this.handleError('Error loading more chat history', error);
            this.hasMoreHistory = false;
            this._topMessageKeyBeforeLoad = null;
        } finally {
            this.isLoadingMoreHistory = false;
        }
    }

    handleInputChange(event) {
        this.userMessageInput = event.target.value;
    }

    handleKeyDown(event) {
        if (event.key === 'Enter' && !event.shiftKey) {
            event.preventDefault();
            this.handleSendMessage();
        }
    }

    handleSendMessageClick() {
        this.handleSendMessage();
    }

    async handleSendMessage() {
        const messageText = this.userMessageInput.trim();

        if (!messageText || !this.currentSessionId || this.isLoading || this.criticalError) return;

        console.log(`Sending message in session ${this.currentSessionId}`);
        this._isUserScrolledUp = false;

        const userMsgData = {
            role: 'user',
            content: messageText,
            timestamp: Date.now(),
            externalId: `local-user-${Date.now()}`
        };
        const userMsgForDisplay = formatDisplayMessages([userMsgData])[0];
        this.chatMessages = [...this.chatMessages, userMsgForDisplay];

        const messageToSendToApex = this.userMessageInput;
        this.userMessageInput = '';
        this.loadingState = { ...this.loadingState, sending: true };
        this.criticalError = null;
        this._requestAutoScroll();

        try {
            const result = await sendMessage({
                sessionId: this.currentSessionId,
                userMessage: messageToSendToApex
            });

            console.log('sendMessage Apex call successful, queuing started. Waiting for Platform Event...');
        } catch (error) {
            const errorMsgContent = `Failed to initiate agent request. Please check connection or try again.`;
            this.handleError('Error Sending Message', error);

            this.displayFrameworkError(errorMsgContent);

            this.loadingState = { ...this.loadingState, sending: false };
            this._requestAutoScroll();
        }
    }

    handleScroll(event) {
        const container = event.target;
        const isAtBottom = container.scrollHeight - container.scrollTop - container.clientHeight <= SCROLL_TOLERANCE;
        this._isUserScrolledUp = !isAtBottom;

        if (container.scrollTop <= SCROLL_TOLERANCE && this.hasMoreHistory && !this.isLoadingMoreHistory) {
            this.handleLoadMoreHistory();
        }
    }

    _requestAutoScroll() {
        this._pendingAutoScroll = true;
    }

    scrollToBottom() {
        const container = this.template.querySelector('.chat-container');
        if (container) {
            container.scrollTop = container.scrollHeight;
            console.log('Scrolled to bottom.');
        }
    }

    handleError(summary, error, isCritical = false) {
        console.error(summary + ' Details:', error);

        let message = 'An unknown error occurred.';
        if (error) {
            if (Array.isArray(error.body)) {
                message = error.body.map((e) => e.message).join(', ');
            } else if (error.body && typeof error.body.message === 'string') {
                message = error.body.message;
            } else if (typeof error.message === 'string') {
                message = error.message;
            }

            if (message === 'An unknown error occurred.' || message === '[object Object]') {
                try {
                    message = JSON.stringify(error);
                } catch (e) {}
            }
        }

        if (isCritical) {
            this.criticalError = `${summary}. Please refresh or contact support if the issue persists. Details: ${message.substring(0, 200)}...`;
        }

        this.showToast(summary, message, 'error', 'sticky');
    }

    showToast(title, message, variant = 'info', mode = 'dismissible') {
        const shortMessage = message && message.length > 200 ? message.substring(0, 200) + '...' : message;
        this.dispatchEvent(new ShowToastEvent({ title, message: shortMessage, variant, mode }));
    }

    async handleSubscribe() {
        if (this.isSubscribed) {
            console.log('Already subscribed.');
            return;
        }
        try {
            const empEnabled = await isEmpEnabled();
            if (!empEnabled) {
                console.error('EMP API is not enabled. Cannot subscribe to events.');
                this.handleError('Event Subscription Error', 'Streaming API is disabled or inaccessible.', true);
                return;
            }

            const messageCallback = (response) => {
                this.handleAgentResponseEvent(response);
            };

            console.log(`Subscribing to channel: ${this.channelName}`);
            const sub = await subscribe(this.channelName, -1, messageCallback);
            this.subscription = sub;
            this.isSubscribed = true;
            console.log(`Subscription successful for channel: ${this.channelName}`, this.subscription);
        } catch (error) {
            this.isSubscribed = false;
            this.handleError('Event Subscription Failed', error);
            console.error(`Error subscribing to ${this.channelName}:`, JSON.stringify(error));
        }
    }

    handleUnsubscribe() {
        if (!this.isSubscribed || !this.subscription || !this.subscription.channel) {
            console.log('Not subscribed or subscription object invalid, skipping unsubscribe.');
            return;
        }
        unsubscribe(this.subscription, (response) => {
            console.log(`Unsubscribe response for channel ${this.subscription?.channel}:`, JSON.stringify(response));
            this.subscription = {};
            this.isSubscribed = false;
        }).catch((error) => {
            this.handleError('Event Unsubscription Failed', error);
            console.error(`Error unsubscribing from ${this.subscription?.channel}:`, JSON.stringify(error));

            this.subscription = {};
            this.isSubscribed = false;
        });
    }

    registerErrorListener() {
        onError((error) => {
            console.error('Received EMP API error: ', JSON.stringify(error));
            this.handleError('Streaming Error', `Received streaming error: ${error?.message || 'Unknown EMP error'}`);
        });
    }

    async handleAgentResponseEvent(response) {
        console.log('Received raw event:', JSON.stringify(response));
        const payload = response?.data?.payload;
        if (!payload) {
            console.warn('Received event without payload:', response);
            return;
        }

        const eventSessionId = payload.ChatSessionId__c;

        if (eventSessionId !== this.currentSessionId) {
            console.log(`Ignoring event for session ${eventSessionId}, current session is ${this.currentSessionId}`);
            return;
        }

        console.log(`Processing AgentResponse__e for session ${eventSessionId}`);
        this.loadingState = { ...this.loadingState, sending: false };

        const isSuccess = payload.IsSuccess__c;
        const finalMsgId = payload.FinalAssistantMessageId__c;
        const errorDetails = payload.ErrorDetails__c;

        try {
            if (isSuccess && finalMsgId) {
                console.log(`Fetching final assistant message: ${finalMsgId}`);
                const finalMessage = await getChatMessageById({ messageId: finalMsgId });

                if (finalMessage) {
                    console.log(`ChatMessages length BEFORE update: ${this.chatMessages.length}`);
                    const messageCountBefore = this.chatMessages.length;

                    const formattedMsg = formatDisplayMessages([finalMessage], this.chatMessages.length)[0];

                    console.log('Formatted message object:', JSON.stringify(formattedMsg));
                    if (!formattedMsg || !formattedMsg.displayKey) {
                        console.error('CRITICAL: formatDisplayMessages returned invalid object!', formattedMsg);
                        this.displayFrameworkError('Internal error formatting the agent response.');
                        return;
                    }

                    this.chatMessages = [...this.chatMessages, formattedMsg];

                    console.log(`ChatMessages length AFTER update: ${this.chatMessages.length}`);
                    if (this.chatMessages.length <= messageCountBefore) {
                        console.error('CRITICAL: chatMessages array length did NOT increase after update!');
                    } else {
                        console.log(
                            'Last item key after update:',
                            this.chatMessages[this.chatMessages.length - 1]?.displayKey
                        );
                    }

                    console.log('Appended final message to chat.');
                    this._requestAutoScroll();
                } else {
                    console.warn(`Could not find ChatMessage for final ID: ${finalMsgId}. Displaying fallback.`);

                    this.displayFrameworkError(
                        'Agent processing complete, but failed to load the final message content.'
                    );
                }
            } else if (isSuccess && !finalMsgId) {
                console.log('Agent processing completed successfully without a final textual message.');
            } else {
                console.error(`Agent Turn Failed. Details: ${errorDetails}`);
                const agentFailMsgData = {
                    role: 'system',
                    content: `Agent processing failed. Details: ${errorDetails || 'No details provided.'}`,
                    timestamp: Date.now(),
                    externalId: `agent-error-${Date.now()}`,
                    isAgentError: true,
                    isSystemError: false
                };
                const agentFailMsgForDisplay = formatDisplayMessages([agentFailMsgData], this.chatMessages.length)[0];
                this.chatMessages = [...this.chatMessages, agentFailMsgForDisplay];
                this.showToast(
                    'Agent Processing Error',
                    errorDetails || 'The agent failed to complete the request.',
                    'error'
                );
                this._requestAutoScroll();
            }
        } catch (error) {
            this.handleError('Error processing agent response event', error);
            this.displayFrameworkError(`An internal error occurred while displaying the agent's response.`);
        }
    }

    displayFrameworkError(message) {
        const frameworkErrorData = {
            role: 'system',
            content: `System Error: ${message}`,
            timestamp: Date.now(),
            externalId: `framework-error-${Date.now()}`,
            isAgentError: false,
            isSystemError: true
        };
        const frameworkErrorMsgForDisplay = formatDisplayMessages([frameworkErrorData], this.chatMessages.length)[0];
        this.chatMessages = [...this.chatMessages, frameworkErrorMsgForDisplay];
        this._requestAutoScroll();
    }

    get isLoading() {
        return Object.values(this.loadingState).some((state) => state === true) || this.isLoadingMoreHistory;
    }

    get isSessionControlDisabled() {
        return this.loadingState.initial || !!this.criticalError || this.loadingState.sessions;
    }

    get isInputDisabled() {
        return this.loadingState.sending || !this.currentSessionId || !!this.criticalError;
    }

    get sessionSelectorPlaceholder() {
        if (this.loadingState.initial || this.loadingState.sessions) return 'Loading sessions...';
        return 'Select Session / Start New';
    }

    get showLoadMoreButton() {
        return this.hasMoreHistory && !this.loadingState.history && !this.isLoadingMoreHistory;
    }
}
