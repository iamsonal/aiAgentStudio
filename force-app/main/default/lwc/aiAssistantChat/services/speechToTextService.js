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
        this.onResult = options.onResult || (() => { });
        this.onInterimResult = options.onInterimResult || (() => { });
        this.onStart = options.onStart || (() => { });
        this.onEnd = options.onEnd || (() => { });
        this.onError = options.onError || (() => { });
        this.onNoSpeech = options.onNoSpeech || (() => { });

        // Configuration
        this.language = options.language || SpeechUtils.getUserLanguage();
        this.continuous = options.continuous !== false; // Default true
        this.interimResults = options.interimResults !== false; // Default true
        this.maxAlternatives = options.maxAlternatives || 1;
        this.confidenceThreshold = options.confidenceThreshold || SPEECH_CONFIG.CONFIDENCE_THRESHOLD;

        // State management
        this.isListening = false;
        this.isSupported = false;
        this.recognition = null;
        this.finalTranscript = '';
        this.interimTranscript = '';
        this.lastSpeechTime = null;
        this.lastResultTime = null;
        this.silenceTimer = null;
        this.speechEndTimer = null;
        this.thinkingPauseTimer = null;
        this.hasSpeechStarted = false;
        this.hasReceivedFinalResults = false;
        this.speechSegmentCount = 0;
        this.silenceTimeout = options.silenceTimeout || SPEECH_CONFIG.SILENCE_TIMEOUT;
        this.speechEndTimeout = options.speechEndTimeout || SPEECH_CONFIG.SPEECH_END_TIMEOUT;
        this.thinkingPauseTimeout = options.thinkingPauseTimeout || SPEECH_CONFIG.THINKING_PAUSE_THRESHOLD;

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
            this.lastSpeechTime = null;
            this.lastResultTime = null;
            this.hasSpeechStarted = false;
            this.hasReceivedFinalResults = false;
            this.speechSegmentCount = 0;
            this._clearAllTimers();
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
            this._clearAllTimers();
            this.onEnd();
        };

        this.recognition.onspeechstart = () => {
            this.lastSpeechTime = Date.now();
            this.hasSpeechStarted = true;
            // Clear all timers when new speech is detected
            this._clearAllTimers();
            console.info('[SpeechToTextService] Speech detected, continuing recognition');
        };

        this.recognition.onspeechend = () => {
            console.info('[SpeechToTextService] Browser detected speech end, starting silence detection');
            this._handleSpeechEnd();
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
        let hasNewFinalResult = false;

        for (let i = event.resultIndex; i < event.results.length; i++) {
            const result = event.results[i];
            const transcript = result[0].transcript;
            const confidence = result[0].confidence;

            if (result.isFinal) {
                // Only accept results above confidence threshold
                if (confidence >= this.confidenceThreshold) {
                    finalTranscript += transcript;
                    this.finalTranscript = finalTranscript;
                    hasNewFinalResult = true;
                    this.hasReceivedFinalResults = true;
                    this.speechSegmentCount++;
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
                this.onInterimResult({
                    transcript: interimTranscript.trim(),
                    confidence: confidence,
                    isFinal: false
                });
                
                // Clear speech end timer if we're getting interim results (user is still speaking)
                this._clearSpeechEndTimer();
            }
        }

        this.lastResultTime = Date.now();

        // Reset silence timer since we got new results (don't start speech end timer here)
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
            'network': 'Network error occurred. Please check your internet connection.',
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
     * Handle speech end detection - start silence timer only
     * @private
     */
    _handleSpeechEnd() {
        if (this.hasSpeechStarted && this.isListening) {
            // Only start silence timer - let natural pauses determine when to stop
            this._startSilenceTimer();
        }
    }

    /**
     * Start silence timer to detect when user has finished speaking
     * Uses intelligent timing based on speech context
     * @private
     */
    _startSilenceTimer() {
        this._clearSilenceTimer();

        // Use longer timeout if we haven't received any final results yet (user might be thinking)
        // Use standard timeout if we have final results but be more conservative
        let timeout;
        if (!this.hasReceivedFinalResults) {
            // User hasn't started speaking meaningfully yet
            timeout = this.thinkingPauseTimeout;
        } else {
            // User has spoken - use standard silence timeout but be more forgiving
            timeout = this.silenceTimeout;
        }

        this.silenceTimer = setTimeout(() => {
            if (this.isListening) {
                const contextMessage = this.hasReceivedFinalResults
                    ? `Silence detected after ${this.speechSegmentCount} speech segment(s)`
                    : 'Extended thinking pause detected';
                console.info(`[SpeechToTextService] ${contextMessage}, stopping recognition`);
                this.stop();
            }
        }, timeout);
    }

    /**
     * Reset silence timer (called when new speech results are received)
     * @private
     */
    _resetSilenceTimer() {
        // Always restart silence timer when we get new results
        // This ensures we don't stop while user is actively speaking
        if (this.hasSpeechStarted) {
            this._startSilenceTimer();
        }
    }

    /**
     * Clear silence timer
     * @private
     */
    _clearSilenceTimer() {
        if (this.silenceTimer) {
            clearTimeout(this.silenceTimer);
            this.silenceTimer = null;
        }
    }

    /**
     * Start speech end timer (after final results are received)
     * @private
     */
    _startSpeechEndTimer() {
        this._clearSpeechEndTimer();
        this.speechEndTimer = setTimeout(() => {
            if (this.isListening) {
                console.info('[SpeechToTextService] Speech end timeout reached, stopping recognition');
                this.stop();
            }
        }, this.speechEndTimeout);
    }

    /**
     * Clear speech end timer
     * @private
     */
    _clearSpeechEndTimer() {
        if (this.speechEndTimer) {
            clearTimeout(this.speechEndTimer);
            this.speechEndTimer = null;
        }
    }

    /**
     * Clear thinking pause timer
     * @private
     */
    _clearThinkingPauseTimer() {
        if (this.thinkingPauseTimer) {
            clearTimeout(this.thinkingPauseTimer);
            this.thinkingPauseTimer = null;
        }
    }

    /**
     * Clear all timers
     * @private
     */
    _clearAllTimers() {
        this._clearSilenceTimer();
        this._clearSpeechEndTimer();
        this._clearThinkingPauseTimer();
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
            stream.getTracks().forEach(track => track.stop()); // Stop the stream, we just needed permission

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
            this._clearAllTimers();
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
        this._clearAllTimers();
        this.recognition = null;
        this.onResult = null;
        this.onInterimResult = null;
        this.onStart = null;
        this.onEnd = null;
        this.onError = null;
        this.onNoSpeech = null;
    }
}