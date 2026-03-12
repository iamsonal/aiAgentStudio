/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * Speech-to-Text Service for AI Assistant Chat
 *
 * Provides robust speech recognition capabilities with enterprise-grade features:
 * - Browser compatibility detection and fallbacks
 * - Real-time transcription with interim results
 * - Noise handling and confidence scoring
 * - Accessibility compliance
 * - Error recovery and reconnection logic
 * - Multi-language support
 */

import { SPEECH_CONFIG, SPEECH_ERRORS, SpeechUtils } from '../utils/speechConstants';

export class SpeechToTextService {
    constructor(options = {}) {
        this.onResult = options.onResult || (() => {});
        this.onInterimResult = options.onInterimResult || (() => {});
        this.onStart = options.onStart || (() => {});
        this.onEnd = options.onEnd || (() => {});
        this.onError = options.onError || (() => {});
        this.onNoSpeech = options.onNoSpeech || (() => {});

        // Configuration
        this.language = options.language || SpeechUtils.getUserLanguage();
        this.continuous = options.continuous !== false; // Default true
        this.interimResults = options.interimResults !== false; // Default true
        this.maxAlternatives = options.maxAlternatives || 1;
        this.confidenceThreshold = options.confidenceThreshold || SPEECH_CONFIG.CONFIDENCE_THRESHOLD;
        this.silenceDetectionDelay = options.silenceDetectionDelay || SPEECH_CONFIG.SILENCE_DETECTION_DELAY;

        // State management
        this.isListening = false;
        this.isSupported = false;
        this.recognition = null;
        this.finalTranscript = '';
        this.interimTranscript = '';
        this.lastSpeechTime = null;
        this.lastResultTime = null; // Track last time we received any result (final or interim)
        this.silenceTimer = null;
        this.hasSpeechInput = false; // Track if any actual speech was detected
        this.hasInterimResults = false; // Track if we're receiving interim results
        this.speechActivityMonitor = null;

        this._initializeRecognition();
    }

    /**
     * Initialize the speech recognition engine
     * @private
     */
    _initializeRecognition() {
        // Check for browser support
        const SpeechRecognition = SpeechUtils.getSpeechRecognitionConstructor();

        if (!SpeechRecognition) {
            console.warn('[SpeechToTextService] Speech recognition not supported in this browser');
            this.isSupported = false;
            return;
        }

        this.isSupported = true;
        this.recognition = new SpeechRecognition();

        // Configure recognition settings
        this.recognition.continuous = this.continuous;
        this.recognition.interimResults = this.interimResults;
        this.recognition.lang = this.language;
        this.recognition.maxAlternatives = this.maxAlternatives;

        // Bind event handlers
        this._bindEventHandlers();
    }

    /**
     * Bind speech recognition event handlers
     * @private
     */
    _bindEventHandlers() {
        if (!this.recognition) return;

        this.recognition.onstart = () => {
            this.isListening = true;
            this.finalTranscript = '';
            this.interimTranscript = '';
            this.lastSpeechTime = Date.now();
            this.lastResultTime = Date.now();
            this.hasSpeechInput = false;
            this.hasInterimResults = false;
            this._startSilenceDetection();
            this.onStart();
        };

        this.recognition.onresult = (event) => {
            this._handleResults(event);
        };

        this.recognition.onerror = (event) => {
            this._handleError(event);
        };

        this.recognition.onend = () => {
            this.isListening = false;
            this._stopSilenceDetection();
            this.onEnd();
        };

        this.recognition.onspeechstart = () => {
            this.lastSpeechTime = Date.now();
            this.hasSpeechInput = true;
            // Reset silence detection when speech starts
            this._resetSilenceTimer();
        };

        this.recognition.onspeechend = () => {
            // Mark the time speech ended for silence detection
            this.lastSpeechTime = Date.now();
            // Start monitoring for silence after speech ends
            this._startSilenceTimer();
        };

        this.recognition.onnomatch = () => {
            this.onNoSpeech('No speech was detected');
        };
    }

    /**
     * Process speech recognition results
     * @private
     */
    _handleResults(event) {
        let interimTranscript = '';
        let finalTranscript = this.finalTranscript;
        let hasInterimInBatch = false;

        for (let i = event.resultIndex; i < event.results.length; i++) {
            const result = event.results[i];
            const transcript = result[0].transcript;
            const confidence = result[0].confidence;

            if (result.isFinal) {
                // Only accept results above confidence threshold
                if (confidence >= this.confidenceThreshold) {
                    finalTranscript += transcript;
                    this.finalTranscript = finalTranscript;
                    this.hasSpeechInput = true;
                    this.hasInterimResults = false; // Reset interim flag on final result
                    this.onResult({
                        transcript: transcript.trim(),
                        confidence: confidence,
                        isFinal: true,
                        fullTranscript: finalTranscript.trim()
                    });
                }
            } else {
                interimTranscript += transcript;
                this.interimTranscript = interimTranscript;
                this.hasInterimResults = true;
                hasInterimInBatch = true;
                this.onInterimResult({
                    transcript: interimTranscript.trim(),
                    confidence: confidence,
                    isFinal: false
                });
            }
        }

        // Update tracking times on any result
        this.lastResultTime = Date.now();
        if (hasInterimInBatch || finalTranscript !== this.finalTranscript) {
            this.lastSpeechTime = Date.now();
        }

        // Reset silence timer when we get results (especially interim results)
        this._resetSilenceTimer();
    }

    /**
     * Handle speech recognition errors
     * @private
     */
    _handleError(event) {
        const errorMessages = {
            'no-speech': 'No speech was detected. Please try speaking closer to your microphone.',
            'audio-capture': 'Audio capture failed. Please check your microphone permissions.',
            'not-allowed': 'Microphone access was denied. Please enable microphone permissions.',
            network: 'Network error occurred. Please check your internet connection.',
            'service-not-allowed': 'Speech recognition service is not allowed.',
            'bad-grammar': 'Grammar error in speech recognition.',
            'language-not-supported': `Language '${this.language}' is not supported.`
        };

        const errorMessage = errorMessages[event.error] || `Speech recognition error: ${event.error}`;

        console.error('[SpeechToTextService] Recognition error:', event.error, errorMessage);

        this.onError({
            error: event.error,
            message: errorMessage,
            canRetry: this._canRetryAfterError(event.error)
        });

        // Auto-retry for certain recoverable errors
        if (this._shouldAutoRetry(event.error)) {
            setTimeout(() => {
                if (!this.isListening) {
                    this.start();
                }
            }, 1000);
        }
    }

    /**
     * Start intelligent silence detection monitoring
     * Monitors for periods of silence and stops recording after configured delay
     * Enterprise-grade: Only stops when we have speech input AND sufficient silence period
     * Does NOT stop if actively receiving interim results (user is still speaking)
     * @private
     */
    _startSilenceDetection() {
        this._stopSilenceDetection();

        // Monitor speech activity at regular intervals
        this.speechActivityMonitor = setInterval(() => {
            if (!this.isListening) {
                this._stopSilenceDetection();
                return;
            }

            // Don't stop if we're actively receiving interim results (user is still speaking)
            if (this.hasInterimResults) {
                return;
            }

            // Check if we have any speech input and if silence threshold exceeded
            if (this.hasSpeechInput && this.lastSpeechTime) {
                const silenceDuration = Date.now() - this.lastSpeechTime;

                // If silence exceeds threshold and no interim results, stop listening
                if (silenceDuration >= this.silenceDetectionDelay) {
                    console.info('[SpeechToTextService] Stopping due to silence detection:', `${silenceDuration}ms of silence after speech completion`);
                    this.stop();
                }
            }
        }, SPEECH_CONFIG.SPEECH_ACTIVITY_CHECK_INTERVAL);
    }

    /**
     * Stop silence detection monitoring
     * @private
     */
    _stopSilenceDetection() {
        if (this.speechActivityMonitor) {
            clearInterval(this.speechActivityMonitor);
            this.speechActivityMonitor = null;
        }
        this._clearSilenceTimer();
    }

    /**
     * Start the silence timer after speech ends
     * This is triggered when onspeechend fires
     * Enterprise-grade: Waits for configured delay, but respects ongoing interim results
     * @private
     */
    _startSilenceTimer() {
        this._clearSilenceTimer();

        // Only start timer if we have had speech input
        if (!this.hasSpeechInput) {
            return;
        }

        this.silenceTimer = setTimeout(() => {
            // Don't stop if we're still receiving interim results
            if (this.isListening && this.hasSpeechInput && !this.hasInterimResults) {
                const silenceDuration = Date.now() - this.lastSpeechTime;

                // Double-check silence duration before stopping
                if (silenceDuration >= this.silenceDetectionDelay) {
                    console.info('[SpeechToTextService] Auto-stopping after silence period');
                    this.stop();
                }
            }
        }, this.silenceDetectionDelay);
    }

    /**
     * Reset/clear the silence timer
     * Called when new speech is detected
     * @private
     */
    _resetSilenceTimer() {
        this._clearSilenceTimer();
    }

    /**
     * Clear the silence timer
     * @private
     */
    _clearSilenceTimer() {
        if (this.silenceTimer) {
            clearTimeout(this.silenceTimer);
            this.silenceTimer = null;
        }
    }

    /**
     * Determine if error is recoverable
     * @private
     */
    _canRetryAfterError(error) {
        const retryableErrors = ['network', 'no-speech', 'audio-capture'];
        return retryableErrors.includes(error);
    }

    /**
     * Determine if should auto-retry after error
     * @private
     */
    _shouldAutoRetry(error) {
        const autoRetryErrors = ['network'];
        return autoRetryErrors.includes(error);
    }

    /**
     * Start speech recognition
     * @returns {Promise<boolean>} Success status
     */
    async start() {
        if (!this.isSupported) {
            this.onError({
                error: 'not-supported',
                message: 'Speech recognition is not supported in this browser. Please use Chrome, Edge, or Safari.',
                canRetry: false
            });
            return false;
        }

        if (this.isListening) {
            console.warn('[SpeechToTextService] Already listening');
            return true;
        }

        try {
            // Request microphone permission first
            const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            stream.getTracks().forEach((track) => track.stop()); // Stop the stream, we just needed permission

            this.recognition.start();
            return true;
        } catch (error) {
            console.error('[SpeechToTextService] Failed to start recognition:', error);
            this.onError({
                error: 'permission-denied',
                message: 'Microphone access is required for speech recognition. Please enable microphone permissions.',
                canRetry: true
            });
            return false;
        }
    }

    /**
     * Stop speech recognition
     */
    stop() {
        if (!this.recognition || !this.isListening) {
            return;
        }

        try {
            this.recognition.stop();
        } catch (error) {
            console.error('[SpeechToTextService] Error stopping recognition:', error);
        }
    }

    /**
     * Abort speech recognition immediately
     */
    abort() {
        if (!this.recognition) {
            return;
        }

        try {
            this.recognition.abort();
            this.isListening = false;
            this._stopSilenceDetection();
        } catch (error) {
            console.error('[SpeechToTextService] Error aborting recognition:', error);
        }
    }

    /**
     * Change recognition language
     * @param {string} language - Language code (e.g., 'en-US', 'es-ES')
     */
    setLanguage(language) {
        this.language = language;
        if (this.recognition) {
            this.recognition.lang = language;
        }
    }

    /**
     * Update continuous recognition setting
     * @param {boolean} value
     */
    setContinuous(value) {
        this.continuous = value !== false;
        if (this.recognition) {
            this.recognition.continuous = this.continuous;
        }
    }

    /**
     * Update interim results setting
     * @param {boolean} value
     */
    setInterimResults(value) {
        this.interimResults = value !== false;
        if (this.recognition) {
            this.recognition.interimResults = this.interimResults;
        }
    }

    /**
     * Update confidence threshold
     * @param {number} value
     */
    setConfidenceThreshold(value) {
        if (typeof value !== 'number' || Number.isNaN(value)) {
            return;
        }
        this.confidenceThreshold = value;
    }

    /**
     * Update silence detection delay
     * @param {number} value
     */
    setSilenceDetectionDelay(value) {
        if (typeof value !== 'number' || Number.isNaN(value)) {
            return;
        }
        this.silenceDetectionDelay = value;
    }

    /**
     * Get current transcript
     * @returns {Object} Current transcript state
     */
    getCurrentTranscript() {
        return {
            final: this.finalTranscript.trim(),
            interim: this.interimTranscript.trim(),
            combined: (this.finalTranscript + this.interimTranscript).trim()
        };
    }

    /**
     * Check if speech recognition is supported
     * @returns {boolean}
     */
    static isSupported() {
        return !!(window.SpeechRecognition || window.webkitSpeechRecognition);
    }

    /**
     * Get supported languages (basic list)
     * @returns {Array} Array of language objects
     */
    static getSupportedLanguages() {
        return [
            { code: 'en-US', name: 'English (US)' },
            { code: 'en-GB', name: 'English (UK)' },
            { code: 'es-ES', name: 'Spanish (Spain)' },
            { code: 'es-MX', name: 'Spanish (Mexico)' },
            { code: 'fr-FR', name: 'French (France)' },
            { code: 'de-DE', name: 'German (Germany)' },
            { code: 'it-IT', name: 'Italian (Italy)' },
            { code: 'pt-BR', name: 'Portuguese (Brazil)' },
            { code: 'ja-JP', name: 'Japanese (Japan)' },
            { code: 'ko-KR', name: 'Korean (South Korea)' },
            { code: 'zh-CN', name: 'Chinese (Simplified)' },
            { code: 'zh-TW', name: 'Chinese (Traditional)' }
        ];
    }

    /**
     * Cleanup resources
     */
    destroy() {
        this.abort();
        this._stopSilenceDetection();
        this.recognition = null;
        this.onResult = null;
        this.onInterimResult = null;
        this.onStart = null;
        this.onEnd = null;
        this.onError = null;
        this.onNoSpeech = null;
    }
}
