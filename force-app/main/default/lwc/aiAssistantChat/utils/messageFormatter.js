/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


import { RELATIVE_TIME_THRESHOLD_MS } from './constants';

function _formatJsonForDisplayInternal(data) {
    if (data === null || data === undefined) return '';
    try {
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
        );
    } catch (e) {
        console.warn('Could not stringify data for display:', data, e);
        try {
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

export function formatTimestamp(timestampInput) {
    if (!timestampInput) return 'Pending...';
    try {
        const timestamp = new Date(timestampInput);

        if (isNaN(timestamp.getTime())) {
            console.warn('Invalid Date encountered in formatTimestamp:', timestampInput);
            return 'Invalid Date';
        }
        const now = new Date();
        const diff = now.getTime() - timestamp.getTime();

        if (diff < 0) {
            if (Math.abs(diff) < 5 * 60 * 1000) {
                return 'Just now';
            } else {
                return timestamp.toLocaleString([], {
                    year: 'numeric',
                    month: 'short',
                    day: 'numeric',
                    hour: 'numeric',
                    minute: '2-digit'
                });
            }
        }

        if (diff < RELATIVE_TIME_THRESHOLD_MS) {
            return timestamp.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
        } else if (now.getFullYear() === timestamp.getFullYear()) {
            return timestamp.toLocaleDateString([], {
                month: 'short',
                day: 'numeric',
                hour: 'numeric',
                minute: '2-digit'
            });
        } else {
            return timestamp.toLocaleDateString([], {
                year: 'numeric',
                month: 'short',
                day: 'numeric',
                hour: 'numeric',
                minute: '2-digit'
            });
        }
    } catch (e) {
        console.error('Error formatting timestamp:', timestampInput, e);
        return 'Date Error';
    }
}

function tryParseJson(jsonString) {
    if (!jsonString || typeof jsonString !== 'string') {
        return null;
    }
    try {
        return JSON.parse(jsonString);
    } catch (e) {
        console.warn('Failed to parse JSON:', e, jsonString.substring(0, 100));

        return {
            _parsing_error: e.message || 'Unknown Error',
            raw_data_preview: jsonString.substring(0, 200) + (jsonString.length > 200 ? '...' : '')
        };
    }
}

export function formatDisplayMessages(messages, existingCount = 0) {
    let counter = existingCount;
    return messages.map((msg) => {
        const sourceRole = msg.Role__c || msg.role;
        const role = sourceRole?.toLowerCase() || 'system';

        const sourceExternalId = msg.ExternalId__c || msg.externalId;
        const key =
            sourceExternalId ||
            msg.id ||
            `msg-${Date.now()}-${counter++}-${Math.random().toString(36).substring(2, 7)}`;

        const isOutbound = role === 'user';
        const isAgentError = msg.isAgentError || false;
        const isSystemError = msg.isSystemError || false;
        const isError = isAgentError || isSystemError;

        const parsedCalls = msg.toolCallsData ? tryParseJson(msg.toolCallsData) : null;
        const parsedResult = msg.toolResultData ? tryParseJson(msg.toolResultData) : null;
        const timestampValue = msg.Timestamp__c || msg.timestamp;
        const formattedTimestamp = formatTimestamp(timestampValue);

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

        const toolInfoAvailable =
            (role === 'assistant' && msg.toolCallsData) ||
            (role === 'tool' && (msg.toolFunctionName || msg.toolResultData));

        const formattedMsg = {
            id: msg.Id || null,
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
            avatarIcon: avatarIcon,
            avatarSrc: null,
            avatarVariant: avatarVariant,

            _parsedToolCallsData: parsedCalls,
            _parsedToolResultData: parsedResult,

            toolCallsData: msg.toolCallsData,
            toolResultData: msg.toolResultData,
            toolFunctionName: msg.toolFunctionName,

            get isInbound() {
                return !this.isOutbound;
            },

            get roleLabel() {
                if (this.isOutbound) return 'You';
                if (this.isSystemError) return 'System';
                if (this.isAgentError) return 'Assistant';
                if (this.role === 'tool') return 'Tool';
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
                return `slds-chat-listitem slds-has-bottom-space ${this.isOutbound ? 'slds-chat-listitem_outbound' : 'slds-chat-listitem_inbound'}`;
            },

            get textBubbleClass() {
                return `slds-chat-message__text ${this.isOutbound ? 'slds-chat-message__text_outbound' : 'slds-chat-message__text_inbound'}`;
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
