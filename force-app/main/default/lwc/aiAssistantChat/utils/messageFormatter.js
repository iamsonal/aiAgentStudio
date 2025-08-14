/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Provides formatting utilities for chat messages, timestamps, and JSON data for the AI Assistant Chat LWC.
 */
import { RELATIVE_TIME_THRESHOLD_MS } from './constants';

/**
 * Safely formats potentially large JSON data for display within <pre> tags.
 * Truncates long strings within the JSON to prevent excessive rendering.
 * @param {any} data - Data to format (expected to be parsed JSON object/primitive).
 * @returns {string} Formatted JSON string or representation of the data.
 */
function _formatJsonForDisplayInternal(data) {
    if (data === null || data === undefined) return '';
    try {
        // Add a replacer function to truncate long strings within the JSON
        const MAX_STRING_LENGTH = 1000;
        return JSON.stringify(
            data,
            (key, value) => {
                if (typeof value === 'string' && value.length > MAX_STRING_LENGTH) {
                    return value.substring(0, MAX_STRING_LENGTH) + '... [String Truncated]';
                }
                return value;
            },
            2
        ); // Pretty print with 2 spaces indent
    } catch (e) {
        // Log with context for troubleshooting
        console.warn('[messageFormatter] Could not stringify data for display:', data, e);
        try {
            // Fallback: simple string conversion, truncated
            const MAX_FALLBACK_LENGTH = 2000;
            return (
                String(data).substring(0, MAX_FALLBACK_LENGTH) +
                (String(data).length > MAX_FALLBACK_LENGTH ? '...[Unserializable Data]' : '[Unserializable Data]')
            );
        } catch (strErr) {
            return '[Unformattable Data]';
        }
    }
}

/**
 * Formats a timestamp value into a user-friendly string relative to now.
 * @param {string|number|Date} timestampInput - The timestamp value.
 * @returns {string} A formatted string representation of the timestamp (e.g., "9:05 AM", "Apr 5, 9:05 AM", "4/5/2023, 9:05 AM").
 */
export function formatTimestamp(timestampInput) {
    if (!timestampInput) return 'Pending...';
    try {
        const timestamp = new Date(timestampInput);
        if (isNaN(timestamp.getTime())) {
            // Log with context
            console.warn('[messageFormatter] Invalid Date encountered in formatTimestamp:', timestampInput);
            return 'Invalid Date';
        }
        const now = new Date();
        const diff = now.getTime() - timestamp.getTime();
        if (diff < 0) {
            if (Math.abs(diff) < 5 * 60 * 1000) {
                return 'Just now';
            } else {
                return timestamp.toLocaleString([], { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
            }
        }
        if (diff < RELATIVE_TIME_THRESHOLD_MS) {
            return timestamp.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
        } else if (now.getFullYear() === timestamp.getFullYear()) {
            return timestamp.toLocaleDateString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
        } else {
            return timestamp.toLocaleDateString([], { year: 'numeric', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
        }
    } catch (e) {
        // Log with context
        console.error('[messageFormatter] Error formatting timestamp:', timestampInput, e);
        return 'Date Error';
    }
}

/**
 * Safely attempts to parse a JSON string.
 * Returns the parsed object or an object indicating failure if parsing errors occur.
 * @param {string} jsonString - The JSON string to parse.
 * @returns {Object|null} The parsed object, null if input is blank/null, or an error indicator object.
 */
function tryParseJson(jsonString) {
    if (!jsonString || typeof jsonString !== 'string') {
        return null;
    }
    try {
        return JSON.parse(jsonString);
    } catch (e) {
        // Log with context
        console.warn('[messageFormatter] Failed to parse JSON:', e, jsonString.substring(0, 100));
        return {
            _parsing_error: e.message || 'Unknown Error',
            raw_data_preview: jsonString.substring(0, 200) + (jsonString.length > 200 ? '...' : '')
        };
    }
}

/**
 * Transforms raw message data from Apex into enhanced objects suitable for rendering in the aiAssistantChat LWC.
 * Adds display keys, formatting, CSS class getters, avatar details, and accessibility properties.
 * @param {Array<Object>} messages - Array of raw message objects from Apex.
 * @param {number} [existingCount=0] - Optional offset for unique key generation.
 * @returns {Array<Object>} Array of formatted message objects with dynamic getters.
 */
export function formatDisplayMessages(messages, existingCount = 0) {
    let counter = existingCount;
    return messages.map((msg) => {
        // --- Basic Properties & Type Detection ---
        const sourceRole = msg.Role__c || msg.role;
        const role = sourceRole?.toLowerCase() || 'system';
        // Define Key Consistently
        const sourceExternalId = msg.ExternalId__c || msg.externalId;
        const key = sourceExternalId || msg.id || `msg-${Date.now()}-${counter++}-${Math.random().toString(36).substring(2, 7)}`;
        const isOutbound = role === 'user';
        const isAgentError = msg.isAgentError || false;
        const isSystemError = msg.isSystemError || false;
        const isError = isAgentError || isSystemError;
        // --- Data Parsing & Timestamp Handling ---
        const parsedCalls = msg.toolCallsData ? tryParseJson(msg.toolCallsData) : null;
        const parsedResult = msg.toolResultData ? tryParseJson(msg.toolResultData) : null;
        const timestampValue = msg.Timestamp__c || msg.timestamp;
        const formattedTimestamp = formatTimestamp(timestampValue);
        // --- Avatar Configuration ---
        let avatarIcon = 'utility:user';
        let avatarVariant = 'circle';
        if (!isOutbound) {
            avatarIcon = 'utility:einstein';
        }
        if (role === 'system' && !isError) {
            avatarIcon = isAgentError ? 'utility:einstein' : 'utility:info_alt';
            avatarVariant = 'square';
        } else if (isSystemError) {
            avatarIcon = 'utility:warning';
        }
        // Tool info check can remain the same
        const toolInfoAvailable = (role === 'assistant' && msg.toolCallsData) || (role === 'tool' && (msg.toolFunctionName || msg.toolResultData));
        // --- Transient Message Detection ---
        const isTransient = msg.isTransient || false;
        // Define the message object to return
        const formattedMsg = {
            id: msg.Id || msg.id || null,
            externalId: sourceExternalId || null,
            role: role,
            content: msg.Content__c || msg.content || '',
            timestamp: timestampValue || Date.now(),
            displayKey: key,
            formattedTimestamp: formattedTimestamp,
            toolInfoAvailable: toolInfoAvailable,
            isError: isError,
            isAgentError: isAgentError,
            isSystemError: isSystemError,
            isOutbound: isOutbound,
            isTransient: isTransient,
            avatarIcon: avatarIcon,
            avatarSrc: null,
            avatarVariant: avatarVariant,
            _parsedToolCallsData: parsedCalls,
            _parsedToolResultData: parsedResult,
            toolCallsData: msg.toolCallsData,
            toolResultData: msg.toolResultData,
            toolFunctionName: msg.toolFunctionName,
            // --- Dynamic Getters for Template ---
            get isInbound() {
                return !this.isOutbound;
            },
            get roleLabel() {
                if (this.isOutbound) return 'You';
                if (this.isSystemError) return 'System';
                if (this.isAgentError) return 'Assistant';
                if (this.role === 'tool') return 'Tool';
                if (this.isTransient) return 'Thinking...';
                return 'Assistant';
            },
            get prefix() {
                if (this.isSystemError) return 'System Error:';
                if (this.isAgentError) return 'Agent Error:';
                return null;
            },
            get prefixClass() {
                if (this.isAgentError) return 'message-prefix message-prefix-error';
                if (this.isSystemError) return 'message-prefix message-prefix-system';
                return 'message-prefix';
            },
            get listItemClass() {
                const baseClass = `slds-chat-listitem slds-has-bottom-space ${this.isOutbound ? 'slds-chat-listitem_outbound' : 'slds-chat-listitem_inbound'}`;
                return this.isTransient ? `${baseClass} slds-chat-listitem_transient` : baseClass;
            },
            get textBubbleClass() {
                const baseClass = `slds-chat-message__text ${this.isOutbound ? 'slds-chat-message__text_outbound' : 'slds-chat-message__text_inbound'}`;
                return this.isTransient ? `${baseClass} slds-chat-message__text_transient` : baseClass;
            },
            get toolDetailsClass() {
                return `tool-details-container ${this.isOutbound ? 'tool-details-outbound' : 'tool-details-inbound'}`;
            },
            get formattedToolCallsJson() {
                if (this._parsedToolCallsData?._parsing_error) {
                    return `[Failed to parse Request Payload: ${this._parsedToolCallsData._parsing_error}]\n${this._parsedToolCallsData.raw_data_preview}`;
                }
                return _formatJsonForDisplayInternal(this._parsedToolCallsData);
            },
            get formattedToolResultJson() {
                if (this._parsedToolResultData?._parsing_error) {
                    return `[Failed to parse Result Data: ${this._parsedToolResultData._parsing_error}]\n${this._parsedToolResultData.raw_data_preview}`;
                }
                return _formatJsonForDisplayInternal(this._parsedToolResultData);
            },
            get ariaLive() {
                return 'off';
            },
            get ariaLabelMeta() {
                return `Message from ${this.roleLabel} at ${this.formattedTimestamp}`;
            }
        };
        return formattedMsg;
    });
}
