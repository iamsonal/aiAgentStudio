/**
 * Speech-to-Text Constants and Configuration
 * 
 * Centralized configuration for speech recognition functionality
 */

export const SPEECH_CONFIG = {
    // Default language settings
    DEFAULT_LANGUAGE: 'en-US',

    // Recognition settings
    CONFIDENCE_THRESHOLD: 0.6,
    SILENCE_TIMEOUT: 2500, // 2.5 seconds of silence before auto-stop (natural end of speech)
    SPEECH_END_TIMEOUT: 4000, // 4 seconds after speech ends (fallback only)
    THINKING_PAUSE_THRESHOLD: 6000, // 6 seconds for extended thinking before first speech

    // UI settings
    INTERIM_DISPLAY_DELAY: 100, // ms
    ERROR_DISPLAY_DURATION: 5000, // 5 seconds

    // Supported languages with display names
    SUPPORTED_LANGUAGES: [
        { code: 'en-US', name: 'English (US)', flag: '🇺🇸' },
        { code: 'en-GB', name: 'English (UK)', flag: '🇬🇧' },
        { code: 'es-ES', name: 'Spanish (Spain)', flag: '🇪🇸' },
        { code: 'es-MX', name: 'Spanish (Mexico)', flag: '🇲🇽' },
        { code: 'fr-FR', name: 'French (France)', flag: '🇫🇷' },
        { code: 'de-DE', name: 'German (Germany)', flag: '🇩🇪' },
        { code: 'it-IT', name: 'Italian (Italy)', flag: '🇮🇹' },
        { code: 'pt-BR', name: 'Portuguese (Brazil)', flag: '🇧🇷' },
        { code: 'ja-JP', name: 'Japanese (Japan)', flag: '🇯🇵' },
        { code: 'ko-KR', name: 'Korean (South Korea)', flag: '🇰🇷' },
        { code: 'zh-CN', name: 'Chinese (Simplified)', flag: '🇨🇳' },
        { code: 'zh-TW', name: 'Chinese (Traditional)', flag: '🇹🇼' },
        { code: 'ar-SA', name: 'Arabic (Saudi Arabia)', flag: '🇸🇦' },
        { code: 'hi-IN', name: 'Hindi (India)', flag: '🇮🇳' },
        { code: 'ru-RU', name: 'Russian (Russia)', flag: '🇷🇺' }
    ]
};

export const SPEECH_ERRORS = {
    NOT_SUPPORTED: {
        code: 'not-supported',
        message: 'Speech recognition is not supported in this browser. Please use Chrome, Edge, or Safari.',
        canRetry: false,
        severity: 'error'
    },
    PERMISSION_DENIED: {
        code: 'permission-denied',
        message: 'Microphone access was denied. Please enable microphone permissions in your browser settings.',
        canRetry: true,
        severity: 'error'
    },
    NO_SPEECH: {
        code: 'no-speech',
        message: 'No speech was detected. Please try speaking closer to your microphone.',
        canRetry: true,
        severity: 'warning'
    },
    AUDIO_CAPTURE: {
        code: 'audio-capture',
        message: 'Audio capture failed. Please check your microphone connection.',
        canRetry: true,
        severity: 'error'
    },
    NETWORK_ERROR: {
        code: 'network',
        message: 'Network error occurred. Please check your internet connection.',
        canRetry: true,
        severity: 'error'
    },
    SERVICE_NOT_ALLOWED: {
        code: 'service-not-allowed',
        message: 'Speech recognition service is not allowed.',
        canRetry: false,
        severity: 'error'
    },
    LANGUAGE_NOT_SUPPORTED: {
        code: 'language-not-supported',
        message: 'The selected language is not supported.',
        canRetry: true,
        severity: 'error'
    },

};

export const SPEECH_STATES = {
    IDLE: 'idle',
    LISTENING: 'listening',
    PROCESSING: 'processing',
    ERROR: 'error',
    PERMISSION_REQUIRED: 'permission-required'
};

export const ACCESSIBILITY_LABELS = {
    SPEECH_BUTTON_START: 'Start voice input - automatically detects when you finish speaking',
    SPEECH_BUTTON_LISTENING: 'Listening for speech - take your time, thinking pauses are okay',
    SPEECH_BUTTON_ERROR: 'Speech recognition error occurred',
    SPEECH_STATUS_LISTENING: 'Currently listening - speak naturally with pauses as needed',
    SPEECH_STATUS_PROCESSING: 'Processing speech input',
    SPEECH_INTERIM_RESULTS: 'Live speech transcription',
    MICROPHONE_PERMISSION: 'Microphone permission required for voice input'
};

/**
 * Utility functions for speech recognition
 */
export class SpeechUtils {
    /**
     * Get browser-specific speech recognition constructor
     * @returns {Function|null} Speech recognition constructor or null if not supported
     */
    static getSpeechRecognitionConstructor() {
        return window.SpeechRecognition || window.webkitSpeechRecognition || null;
    }

    /**
     * Check if speech recognition is supported
     * @returns {boolean} True if supported
     */
    static isSupported() {
        return !!this.getSpeechRecognitionConstructor();
    }

    /**
     * Get user's preferred language from browser settings
     * @returns {string} Language code
     */
    static getUserLanguage() {
        const browserLang = navigator.language || navigator.userLanguage || SPEECH_CONFIG.DEFAULT_LANGUAGE;

        // Check if the browser language is in our supported list
        const supportedLang = SPEECH_CONFIG.SUPPORTED_LANGUAGES.find(
            lang => lang.code === browserLang || lang.code.startsWith(browserLang.split('-')[0])
        );

        return supportedLang ? supportedLang.code : SPEECH_CONFIG.DEFAULT_LANGUAGE;
    }

    /**
     * Format confidence score for display
     * @param {number} confidence - Confidence score (0-1)
     * @returns {string} Formatted confidence percentage
     */
    static formatConfidence(confidence) {
        return `${Math.round(confidence * 100)}%`;
    }

    /**
     * Get error details by error code
     * @param {string} errorCode - Error code from speech recognition
     * @returns {Object} Error details object
     */
    static getErrorDetails(errorCode) {
        return SPEECH_ERRORS[errorCode.toUpperCase().replace('-', '_')] || {
            code: errorCode,
            message: `Unknown speech recognition error: ${errorCode}`,
            canRetry: true,
            severity: 'error'
        };
    }

    /**
     * Check if error is recoverable
     * @param {string} errorCode - Error code
     * @returns {boolean} True if error is recoverable
     */
    static isRecoverableError(errorCode) {
        const errorDetails = this.getErrorDetails(errorCode);
        return errorDetails.canRetry;
    }

    /**
     * Sanitize speech input text
     * @param {string} text - Raw speech text
     * @returns {string} Sanitized text
     */
    static sanitizeText(text) {
        if (!text || typeof text !== 'string') {
            return '';
        }

        return text
            .trim()
            .replace(/\s+/g, ' ') // Replace multiple spaces with single space
            .replace(/[^\w\s.,!?;:'"()-]/g, '') // Remove special characters except common punctuation
            .substring(0, 32000); // Ensure it doesn't exceed max length
    }

    /**
     * Check if browser supports specific speech recognition features
     * @returns {Object} Feature support object
     */
    static getFeatureSupport() {
        const SpeechRecognition = this.getSpeechRecognitionConstructor();

        if (!SpeechRecognition) {
            return {
                basic: false,
                continuous: false,
                interimResults: false,
                maxAlternatives: false
            };
        }

        // Create a temporary instance to check feature support
        try {
            const tempRecognition = new SpeechRecognition();
            return {
                basic: true,
                continuous: 'continuous' in tempRecognition,
                interimResults: 'interimResults' in tempRecognition,
                maxAlternatives: 'maxAlternatives' in tempRecognition
            };
        } catch (error) {
            return {
                basic: false,
                continuous: false,
                interimResults: false,
                maxAlternatives: false
            };
        }
    }
}