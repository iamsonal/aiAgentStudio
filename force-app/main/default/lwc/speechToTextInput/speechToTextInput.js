/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Speech to Text Input Component
 *
 * A pluggable, reusable component that provides speech recognition capabilities.
 * Can be integrated into any Lightning Web Component that needs voice input functionality.
 *
 * Features:
 * - Browser speech recognition integration
 * - Real-time transcription with interim results
 * - Visual feedback for recording state
 * - Configurable language and behavior
 * - Event-based communication with parent components
 * - Accessibility compliant
 *
 * Events Emitted:
 * - speechstart: Fired when speech recognition starts
 * - speechend: Fired when speech recognition ends
 * - speechresult: Fired when final speech result is available
 * - speechinterim: Fired for interim (live) speech results
 * - speecherror: Fired when an error occurs
 */
import { LightningElement, api } from 'lwc';
import { SpeechToTextService } from './services/speechToTextService';
import { SpeechUtils } from './utils/speechConstants';

export default class SpeechToTextInput extends LightningElement {
    _language = 'en-US';
    _continuous;
    _interimResults;
    _confidenceThreshold = 0.6;
    _silenceDetectionDelay = 1500;

    /**
     * Language code for speech recognition (e.g., 'en-US', 'es-ES')
     * @type {string}
     */
    @api
    get language() {
        return this._language;
    }
    set language(value) {
        const nextValue = value || 'en-US';
        if (nextValue === this._language) {
            return;
        }
        this._language = nextValue;
        if (this._speechService) {
            this._speechService.setLanguage(this._language);
        }
    }

    /**
     * Whether the component is disabled
     * @type {boolean}
     */
    @api disabled = false;

    /**
     * Continuous recognition mode (keeps listening until manually stopped)
     * Default: true (handled in service initialization)
     * @type {boolean}
     */
    @api
    get continuous() {
        return this._continuous;
    }
    set continuous(value) {
        const nextValue = this._normalizeBoolean(value);
        if (nextValue === this._continuous) {
            return;
        }
        this._continuous = nextValue;
        if (this._speechService) {
            this._speechService.setContinuous(this._continuous);
        }
    }

    /**
     * Enable interim results (live transcription)
     * Default: true (handled in service initialization)
     * @type {boolean}
     */
    @api
    get interimResults() {
        return this._interimResults;
    }
    set interimResults(value) {
        const nextValue = this._normalizeBoolean(value);
        if (nextValue === this._interimResults) {
            return;
        }
        this._interimResults = nextValue;
        if (this._speechService) {
            this._speechService.setInterimResults(this._interimResults);
        }
    }

    /**
     * Confidence threshold for accepting results (0-1)
     * @type {number}
     */
    @api
    get confidenceThreshold() {
        return this._confidenceThreshold;
    }
    set confidenceThreshold(value) {
        const nextValue = Number(value);
        if (!Number.isFinite(nextValue)) {
            return;
        }
        if (nextValue === this._confidenceThreshold) {
            return;
        }
        this._confidenceThreshold = nextValue;
        if (this._speechService) {
            this._speechService.setConfidenceThreshold(this._confidenceThreshold);
        }
    }

    /**
     * Silence detection delay in milliseconds
     * @type {number}
     */
    @api
    get silenceDetectionDelay() {
        return this._silenceDetectionDelay;
    }
    set silenceDetectionDelay(value) {
        const nextValue = Number(value);
        if (!Number.isFinite(nextValue)) {
            return;
        }
        if (nextValue === this._silenceDetectionDelay) {
            return;
        }
        this._silenceDetectionDelay = nextValue;
        if (this._speechService) {
            this._speechService.setSilenceDetectionDelay(this._silenceDetectionDelay);
        }
    }

    /**
     * Button variant when not listening
     * @type {string}
     */
    @api buttonVariant = 'border-filled';

    /**
     * Button size
     * @type {string}
     */
    @api buttonSize = 'small';

    /**
     * Custom CSS class for the button
     * @type {string}
     */
    @api customClass = '';

    /**
     * Show visual pulse animation when recording
     * Default: true (handled in getter)
     * @type {boolean}
     */
    @api showPulseAnimation;

    // Internal state
    speechSupported = false;
    speechState = {
        isListening: false,
        isError: false,
        errorMessage: '',
        interimText: '',
        finalText: '',
        confidence: 0
    };

    _speechService = null;

    /**
     * Lifecycle: Initialize speech service
     */
    connectedCallback() {
        this.speechSupported = SpeechUtils.isSupported();

        if (this.speechSupported) {
            this._initializeSpeechService();
        }
    }

    /**
     * Lifecycle: Cleanup speech service
     */
    disconnectedCallback() {
        this._cleanupSpeechService();
    }

    /**
     * Public API: Start speech recognition
     */
    @api
    async start() {
        if (!this._speechService || !this.speechSupported) {
            return false;
        }

        return await this._speechService.start();
    }

    /**
     * Public API: Stop speech recognition
     */
    @api
    stop() {
        if (this._speechService) {
            this._speechService.stop();
        }
    }

    /**
     * Public API: Check if currently listening
     */
    @api
    isListening() {
        return this.speechState.isListening;
    }

    /**
     * Public API: Get current transcript
     */
    @api
    getCurrentTranscript() {
        return (
            this._speechService?.getCurrentTranscript() || {
                final: '',
                interim: '',
                combined: ''
            }
        );
    }

    /**
     * Initialize the speech-to-text service
     * @private
     */
    _initializeSpeechService() {
        try {
            this._speechService = new SpeechToTextService({
                language: this._language,
                continuous: this._continuous,
                interimResults: this._interimResults,
                confidenceThreshold: this._confidenceThreshold,
                silenceDetectionDelay: this._silenceDetectionDelay,

                onStart: () => {
                    this.speechState = {
                        ...this.speechState,
                        isListening: true,
                        isError: false,
                        errorMessage: '',
                        interimText: '',
                        finalText: ''
                    };

                    this.dispatchEvent(
                        new CustomEvent('speechstart', {
                            detail: {
                                timestamp: Date.now()
                            }
                        })
                    );
                },

                onResult: (result) => {
                    if (result.isFinal && result.transcript.trim()) {
                        this.speechState = {
                            ...this.speechState,
                            interimText: '',
                            finalText: result.transcript
                        };

                        this.dispatchEvent(
                            new CustomEvent('speechresult', {
                                detail: {
                                    transcript: result.transcript.trim(),
                                    confidence: result.confidence,
                                    fullTranscript: result.fullTranscript,
                                    timestamp: Date.now()
                                }
                            })
                        );
                    }
                },

                onInterimResult: (result) => {
                    this.speechState = {
                        ...this.speechState,
                        interimText: result.transcript,
                        confidence: result.confidence
                    };

                    this.dispatchEvent(
                        new CustomEvent('speechinterim', {
                            detail: {
                                transcript: result.transcript.trim(),
                                confidence: result.confidence,
                                timestamp: Date.now()
                            }
                        })
                    );
                },

                onEnd: () => {
                    this.speechState = {
                        ...this.speechState,
                        isListening: false,
                        interimText: ''
                    };

                    this.dispatchEvent(
                        new CustomEvent('speechend', {
                            detail: {
                                finalText: this.speechState.finalText,
                                timestamp: Date.now()
                            }
                        })
                    );
                },

                onError: (error) => {
                    this.speechState = {
                        ...this.speechState,
                        isListening: false,
                        isError: true,
                        errorMessage: error.message,
                        interimText: ''
                    };

                    this.dispatchEvent(
                        new CustomEvent('speecherror', {
                            detail: {
                                error: error.error,
                                message: error.message,
                                canRetry: error.canRetry,
                                timestamp: Date.now()
                            }
                        })
                    );
                },

                onNoSpeech: (message) => {
                    this.dispatchEvent(
                        new CustomEvent('speechnospeech', {
                            detail: {
                                message: message,
                                timestamp: Date.now()
                            }
                        })
                    );
                }
            });

            console.info('[speechToTextInput] Speech service initialized successfully');
        } catch (error) {
            console.error('[speechToTextInput] Failed to initialize speech service:', error);
            this.speechSupported = false;
        }
    }

    /**
     * Cleanup speech service
     * @private
     */
    _cleanupSpeechService() {
        if (this._speechService) {
            this._speechService.destroy();
            this._speechService = null;
        }
    }

    /**
     * Handler for speech button click
     */
    handleSpeechToggle() {
        if (!this._speechService || !this.speechSupported || this.disabled) {
            return;
        }

        if (this.speechState.isListening) {
            this._speechService.stop();
        } else {
            this._speechService.start();
        }
    }

    // === Getters for Template ===

    /**
     * Returns the appropriate icon for the speech button
     */
    get speechButtonIcon() {
        if (this.speechState.isListening) {
            return 'utility:record';
        }
        if (this.speechState.isError) {
            return 'utility:warning';
        }
        return 'utility:unmuted';
    }

    /**
     * Returns the button variant based on state
     */
    get computedButtonVariant() {
        if (this.speechState.isListening) {
            return 'destructive';
        }
        if (this.speechState.isError) {
            return 'destructive';
        }
        return this.buttonVariant;
    }

    /**
     * Returns the alternative text for the speech button
     */
    get speechButtonAltText() {
        if (this.speechState.isListening) {
            return 'Stop recording';
        }
        return 'Start voice input';
    }

    /**
     * Returns the title for the speech button
     */
    get speechButtonTitle() {
        if (this.speechState.isListening) {
            return 'Click to stop recording your voice';
        }
        if (this.speechState.isError) {
            return `Speech error: ${this.speechState.errorMessage}`;
        }
        if (!this.speechSupported) {
            return 'Speech recognition not supported in this browser';
        }
        return 'Click to start voice input (requires microphone permission)';
    }

    /**
     * Returns true if the speech button should be disabled
     */
    get isSpeechDisabled() {
        return this.disabled || !this.speechSupported;
    }

    /**
     * Returns the CSS class for the speech button
     */
    get speechButtonClass() {
        let classes = 'speech-button';

        if (this.customClass) {
            classes += ` ${this.customClass}`;
        }

        if (this.speechState.isListening) {
            classes += ' speech-button-listening';
            // Default showPulseAnimation to true if not explicitly set to false
            if (this.showPulseAnimation !== false) {
                classes += ' speech-button-pulse';
            }
        }

        if (this.speechState.isError) {
            classes += ' speech-button-error';
        }

        return classes;
    }

    /**
     * Returns screen reader status text
     */
    get speechStatusText() {
        if (!this.speechSupported) {
            return 'Speech recognition not supported';
        }
        if (this.speechState.isError) {
            return `Speech recognition error: ${this.speechState.errorMessage}`;
        }
        if (this.speechState.isListening) {
            return 'Listening for speech';
        }
        return 'Voice input idle';
    }

    /**
     * Returns true if the component should be visible
     */
    get isVisible() {
        return this.speechSupported;
    }

    /**
     * Returns interim text for display (can be used by parent)
     */
    get interimText() {
        return this.speechState.interimText;
    }

    /**
     * Returns final text for display (can be used by parent)
     */
    get finalText() {
        return this.speechState.finalText;
    }

    _normalizeBoolean(value) {
        if (value === true || value === 'true') {
            return true;
        }
        if (value === false || value === 'false') {
            return false;
        }
        return undefined;
    }
}
