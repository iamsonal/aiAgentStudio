# Speech-to-Text Input Component

A production-ready, pluggable Lightning Web Component that provides robust speech recognition capabilities for Salesforce applications.

## 🎯 Overview

The `speechToTextInput` component is a reusable, enterprise-grade voice input solution that integrates browser-native speech recognition (Web Speech API) into any Salesforce Lightning application. It provides real-time transcription, visual feedback, intelligent silence detection, and comprehensive error handling.

## ✨ Key Features

- **Browser-Native Speech Recognition** - Leverages Web Speech API with cross-browser support
- **Real-Time Transcription** - Live interim results as users speak
- **Intelligent Silence Detection** - Automatically stops recording after speech completion
- **Visual Feedback** - Animated button with customizable pulse effects during recording
- **Multi-Language Support** - Supports 15+ languages out of the box
- **Confidence Scoring** - Configurable threshold to filter low-quality transcriptions
- **Error Recovery** - Automatic retry logic for recoverable errors
- **Accessibility Compliant** - ARIA labels, live status announcements, keyboard navigation
- **Responsive Design** - Works seamlessly across desktop, tablet, and mobile devices
- **Dark Mode Support** - Automatic adaptation to user's color scheme preferences
- **Event-Driven Architecture** - Comprehensive custom events for parent component integration
- **Zero External Dependencies** - Pure JavaScript implementation

## 🏗️ Architecture

```
speechToTextInput/
├── speechToTextInput.js           # Main component (UI & API layer)
├── speechToTextInput.html         # Template (button interface)
├── speechToTextInput.css          # Styling (responsive, accessible)
├── speechToTextInput.js-meta.xml  # Component metadata
├── services/
│   └── speechToTextService.js     # Core speech recognition logic
└── utils/
    └── speechConstants.js         # Configuration & utilities
```

### Component Layers

1. **Presentation Layer** (`speechToTextInput.js/html`) - Handles UI rendering and user interactions
2. **Service Layer** (`speechToTextService.js`) - Manages speech recognition lifecycle and state
3. **Utility Layer** (`speechConstants.js`) - Provides configuration, constants, and helper functions

## 📋 Browser Support

| Browser | Version | Support Level |
| ------- | ------- | ------------- |
| Chrome  | 25+     | ✅ Full       |
| Edge    | 79+     | ✅ Full       |
| Safari  | 14.1+   | ✅ Full       |
| Firefox | ❌      | Not Supported |
| Opera   | 27+     | ✅ Full       |

> **Note**: The component gracefully handles unsupported browsers by hiding the speech button and providing fallback mechanisms.

## 🚀 Quick Start

### Basic Usage

```html
<!-- Minimal implementation -->
<c-speech-to-text-input onspeechresult="{handleSpeechResult}"> </c-speech-to-text-input>
```

```javascript
// Handle speech results
handleSpeechResult(event) {
    const transcript = event.detail.transcript;
    const confidence = event.detail.confidence;

    console.log('User said:', transcript);
    console.log('Confidence:', confidence);
}
```

### Advanced Usage with All Options

```html
<c-speech-to-text-input
    language="en-US"
    disabled="{isInputDisabled}"
    continuous="{true}"
    interim-results="{true}"
    confidence-threshold="{0.7}"
    silence-detection-delay="{2000}"
    button-variant="brand"
    button-size="medium"
    custom-class="my-custom-speech-btn"
    show-pulse-animation="{true}"
    onspeechstart="{handleSpeechStart}"
    onspeechend="{handleSpeechEnd}"
    onspeechresult="{handleSpeechResult}"
    onspeechinterim="{handleInterimResult}"
    onspeecherror="{handleSpeechError}"
    onspeechnospeech="{handleNoSpeech}">
</c-speech-to-text-input>
```

## 🔧 API Reference

### Public Properties

| Property                | Type    | Default           | Description                                                            |
| ----------------------- | ------- | ----------------- | ---------------------------------------------------------------------- |
| `language`              | String  | `'en-US'`         | Language code for speech recognition (e.g., 'en-US', 'es-ES', 'fr-FR') |
| `disabled`              | Boolean | `false`           | Disables the speech button                                             |
| `continuous`            | Boolean | `true`            | Keeps listening until manually stopped                                 |
| `interimResults`        | Boolean | `true`            | Enables live transcription as user speaks                              |
| `confidenceThreshold`   | Number  | `0.6`             | Minimum confidence score (0-1) to accept transcriptions                |
| `silenceDetectionDelay` | Number  | `1500`            | Milliseconds of silence before auto-stopping (ms)                      |
| `buttonVariant`         | String  | `'border-filled'` | Lightning button variant when not listening                            |
| `buttonSize`            | String  | `'small'`         | Button size: 'small', 'medium', 'large'                                |
| `customClass`           | String  | `''`              | Custom CSS class for additional styling                                |
| `showPulseAnimation`    | Boolean | `true`            | Shows pulse animation during recording                                 |

### Public Methods

#### `start()`

Starts speech recognition programmatically.

```javascript
// Get reference to component
const speechComponent = this.template.querySelector('c-speech-to-text-input');

// Start listening
const success = await speechComponent.start();
if (success) {
    console.log('Speech recognition started');
}
```

**Returns**: `Promise<Boolean>` - `true` if started successfully, `false` otherwise

---

#### `stop()`

Stops speech recognition programmatically.

```javascript
const speechComponent = this.template.querySelector('c-speech-to-text-input');
speechComponent.stop();
```

**Returns**: `void`

---

#### `isListening()`

Checks if speech recognition is currently active.

```javascript
const speechComponent = this.template.querySelector('c-speech-to-text-input');
const listening = speechComponent.isListening();
console.log('Is listening:', listening);
```

**Returns**: `Boolean` - `true` if currently listening, `false` otherwise

---

#### `getCurrentTranscript()`

Gets the current transcript state.

```javascript
const speechComponent = this.template.querySelector('c-speech-to-text-input');
const transcript = speechComponent.getCurrentTranscript();

console.log('Final:', transcript.final); // Completed transcriptions
console.log('Interim:', transcript.interim); // Current live transcription
console.log('Combined:', transcript.combined); // Both combined
```

**Returns**: `Object`

```javascript
{
    final: String,    // Completed transcriptions
    interim: String,  // Current interim results
    combined: String  // Concatenated final + interim
}
```

### Events

All events include a `timestamp` field with the event occurrence time (`Date.now()`).

#### `speechstart`

Fired when speech recognition starts.

```javascript
handleSpeechStart(event) {
    console.log('Started at:', event.detail.timestamp);
}
```

**Event Detail**:

```javascript
{
    timestamp: Number;
}
```

---

#### `speechend`

Fired when speech recognition ends.

```javascript
handleSpeechEnd(event) {
    console.log('Ended at:', event.detail.timestamp);
    console.log('Final text:', event.detail.finalText);
}
```

**Event Detail**:

```javascript
{
    finalText: String,    // Complete transcript from session
    timestamp: Number
}
```

---

#### `speechresult`

Fired when a final (completed) speech result is available.

```javascript
handleSpeechResult(event) {
    const { transcript, confidence, fullTranscript } = event.detail;

    if (confidence > 0.8) {
        // High confidence result
        this.processUserInput(transcript);
    }
}
```

**Event Detail**:

```javascript
{
    transcript: String,      // This segment's transcript
    confidence: Number,      // Confidence score (0-1)
    fullTranscript: String,  // Complete transcript so far
    timestamp: Number
}
```

---

#### `speechinterim`

Fired continuously during speech for live transcription.

```javascript
handleInterimResult(event) {
    // Update UI with live preview
    this.liveTranscript = event.detail.transcript;
}
```

**Event Detail**:

```javascript
{
    transcript: String,   // Current interim transcript
    confidence: Number,   // Confidence score (0-1)
    timestamp: Number
}
```

---

#### `speecherror`

Fired when an error occurs during speech recognition.

```javascript
handleSpeechError(event) {
    const { error, message, canRetry } = event.detail;

    if (canRetry) {
        // Show retry option to user
        this.showRetryDialog(message);
    } else {
        // Show permanent error message
        this.showError(message);
    }
}
```

**Event Detail**:

```javascript
{
    error: String,      // Error code (e.g., 'no-speech', 'not-allowed')
    message: String,    // User-friendly error message
    canRetry: Boolean,  // Whether error is recoverable
    timestamp: Number
}
```

**Common Error Codes**:

- `no-speech` - No speech detected
- `audio-capture` - Microphone access failed
- `not-allowed` - Permission denied
- `network` - Network error
- `not-supported` - Browser doesn't support speech recognition

---

#### `speechnospeech`

Fired when no speech is detected during recognition.

```javascript
handleNoSpeech(event) {
    console.log('No speech detected:', event.detail.message);
}
```

**Event Detail**:

```javascript
{
    message: String,
    timestamp: Number
}
```

## 🌍 Supported Languages

The component supports 15+ languages by default:

| Language            | Code    | Language              | Code    |
| ------------------- | ------- | --------------------- | ------- |
| English (US)        | `en-US` | Japanese              | `ja-JP` |
| English (UK)        | `en-GB` | Korean                | `ko-KR` |
| Spanish (Spain)     | `es-ES` | Chinese (Simplified)  | `zh-CN` |
| Spanish (Mexico)    | `es-MX` | Chinese (Traditional) | `zh-TW` |
| French              | `fr-FR` | Arabic                | `ar-SA` |
| German              | `de-DE` | Hindi                 | `hi-IN` |
| Italian             | `it-IT` | Russian               | `ru-RU` |
| Portuguese (Brazil) | `pt-BR` |                       |         |

### Changing Language Dynamically

```javascript
// In your parent component
handleLanguageChange(event) {
    this.selectedLanguage = event.target.value;
}
```

```html
<lightning-combobox label="Language" value="{selectedLanguage}" options="{languageOptions}" onchange="{handleLanguageChange}"> </lightning-combobox>

<c-speech-to-text-input language="{selectedLanguage}" onspeechresult="{handleSpeechResult}"> </c-speech-to-text-input>
```

## 💡 Usage Examples

### Example 1: Chat Input with Voice

```html
<!-- chatComponent.html -->
<template>
    <div class="chat-input-container">
        <lightning-textarea value="{messageText}" placeholder="Type or speak your message"> </lightning-textarea>

        <c-speech-to-text-input onspeechresult="{handleVoiceInput}" onspeechinterim="{handleInterimVoice}"> </c-speech-to-text-input>

        <lightning-button label="Send" onclick="{handleSend}"> </lightning-button>
    </div>
</template>
```

```javascript
// chatComponent.js
import { LightningElement, track } from 'lwc';

export default class ChatComponent extends LightningElement {
    @track messageText = '';

    handleVoiceInput(event) {
        // Append voice transcript to existing text
        const voiceText = event.detail.transcript;
        this.messageText = this.messageText ? `${this.messageText} ${voiceText}` : voiceText;
    }

    handleInterimVoice(event) {
        // Show live preview in a separate area
        this.interimPreview = event.detail.transcript;
    }

    handleSend() {
        // Send the message
        this.sendMessage(this.messageText);
        this.messageText = '';
    }
}
```

### Example 2: Search with Voice Command

```html
<!-- searchComponent.html -->
<template>
    <lightning-card title="Voice Search">
        <div class="search-container">
            <lightning-input label="Search" value="{searchTerm}" placeholder="Type or speak to search"> </lightning-input>

            <c-speech-to-text-input continuous="{false}" silence-detection-delay="{1000}" onspeechresult="{handleVoiceSearch}" custom-class="search-voice-btn">
            </c-speech-to-text-input>
        </div>

        <div if:true="{searchResults}">
            <!-- Display search results -->
        </div>
    </lightning-card>
</template>
```

```javascript
// searchComponent.js
import { LightningElement, track } from 'lwc';

export default class SearchComponent extends LightningElement {
    @track searchTerm = '';
    @track searchResults;

    handleVoiceSearch(event) {
        // Automatically trigger search with voice input
        this.searchTerm = event.detail.transcript;
        this.performSearch();
    }

    async performSearch() {
        // Your search logic here
        this.searchResults = await this.searchRecords(this.searchTerm);
    }
}
```

### Example 3: Form Field with Voice Input

```html
<!-- formComponent.html -->
<template>
    <lightning-record-edit-form object-api-name="Case">
        <lightning-messages></lightning-messages>

        <div class="form-field-with-voice">
            <lightning-input-field field-name="Subject" value="{subjectValue}"> </lightning-input-field>

            <c-speech-to-text-input onspeechresult="{handleSubjectVoice}"> </c-speech-to-text-input>
        </div>

        <div class="form-field-with-voice">
            <lightning-input-field field-name="Description" value="{descriptionValue}"> </lightning-input-field>

            <c-speech-to-text-input onspeechresult="{handleDescriptionVoice}"> </c-speech-to-text-input>
        </div>

        <lightning-button type="submit" label="Create Case"> </lightning-button>
    </lightning-record-edit-form>
</template>
```

```javascript
// formComponent.js
import { LightningElement, track } from 'lwc';

export default class FormComponent extends LightningElement {
    @track subjectValue = '';
    @track descriptionValue = '';

    handleSubjectVoice(event) {
        this.subjectValue = event.detail.transcript;
    }

    handleDescriptionVoice(event) {
        this.descriptionValue = event.detail.transcript;
    }
}
```

### Example 4: Programmatic Control

```html
<!-- controlledComponent.html -->
<template>
    <lightning-button
        label={isListening ? 'Stop Recording' : 'Start Recording'}
        variant={isListening ? 'destructive' : 'brand'}
        onclick={toggleRecording}>
    </lightning-button>

    <c-speech-to-text-input
        onspeechstart={handleStart}
        onspeechend={handleEnd}
        onspeechresult={handleResult}>
    </c-speech-to-text-input>

    <div class="transcript">
        <p>You said: {transcript}</p>
        <p class="interim">Live: {interimText}</p>
    </div>
</template>
```

```javascript
// controlledComponent.js
import { LightningElement, track } from 'lwc';

export default class ControlledComponent extends LightningElement {
    @track isListening = false;
    @track transcript = '';
    @track interimText = '';

    async toggleRecording() {
        const speechComponent = this.template.querySelector('c-speech-to-text-input');

        if (this.isListening) {
            speechComponent.stop();
        } else {
            const started = await speechComponent.start();
            if (!started) {
                // Handle error - permission denied or not supported
                this.showToast('Error', 'Could not start speech recognition', 'error');
            }
        }
    }

    handleStart() {
        this.isListening = true;
        this.transcript = '';
        this.interimText = '';
    }

    handleEnd() {
        this.isListening = false;
        this.interimText = '';
    }

    handleResult(event) {
        this.transcript += ' ' + event.detail.transcript;
    }
}
```

## 🎨 Styling and Customization

### Custom Button Styling

```css
/* Add to your parent component's CSS */
.my-custom-speech-btn {
    margin-left: 8px;
}

/* Override hover effects */
.my-custom-speech-btn:hover {
    transform: scale(1.15);
}

/* Custom pulse color */
.my-custom-speech-btn.speech-button-pulse {
    animation: custom-pulse 2s infinite;
}

@keyframes custom-pulse {
    0% {
        box-shadow: 0 0 0 0 rgba(0, 112, 210, 0.7);
    }
    70% {
        box-shadow: 0 0 0 15px rgba(0, 112, 210, 0);
    }
    100% {
        box-shadow: 0 0 0 0 rgba(0, 112, 210, 0);
    }
}
```

### Button Variants

The component uses Lightning button variants for different states:

- **Default State**: Uses `buttonVariant` prop (default: `border-filled`)
- **Listening State**: Automatically switches to `destructive` (red)
- **Error State**: Uses `destructive` variant

```html
<!-- Different button styles -->
<c-speech-to-text-input button-variant="brand"></c-speech-to-text-input>
<c-speech-to-text-input button-variant="neutral"></c-speech-to-text-input>
<c-speech-to-text-input button-variant="border-filled"></c-speech-to-text-input>
```

### Responsive Design

The component automatically adapts to different screen sizes:

```css
/* Built-in responsive styles */
@media (max-width: 480px) {
    .speech-button {
        width: 28px;
        height: 28px;
    }
}
```

### Dark Mode Support

The component automatically adapts to user's color scheme preference:

```css
/* Automatic dark mode adaptation */
@media (prefers-color-scheme: dark) {
    /* Component automatically adjusts colors */
}
```

### Accessibility Features

The component includes comprehensive accessibility support:

- **ARIA Labels**: Descriptive labels for screen readers
- **Live Status Announcements**: State changes are announced
- **Keyboard Navigation**: Full keyboard support
- **Focus Indicators**: Clear focus states for keyboard navigation
- **Reduced Motion**: Respects user's motion preferences
- **High Contrast**: Adapts to high contrast mode

```css
/* Built-in accessibility features */
@media (prefers-reduced-motion: reduce) {
    /* Animations are disabled */
}

@media (prefers-contrast: high) {
    /* Enhanced contrast for borders */
}
```

## ⚙️ Configuration

### Default Configuration

```javascript
// speechConstants.js
export const SPEECH_CONFIG = {
    DEFAULT_LANGUAGE: 'en-US',
    CONFIDENCE_THRESHOLD: 0.6,
    SILENCE_DETECTION_DELAY: 1500,
    SPEECH_ACTIVITY_CHECK_INTERVAL: 250
};
```

### Custom Configuration

You can override defaults by passing props:

```html
<c-speech-to-text-input confidence-threshold="{0.8}" silence-detection-delay="{2500}"> </c-speech-to-text-input>
```

## 🔒 Security and Privacy

### Microphone Permissions

The component requests microphone permission when speech recognition starts. It handles permission states gracefully:

```javascript
// Permission is requested on first start() call
const started = await speechComponent.start();

if (!started) {
    // Permission denied or not supported
    console.error('Speech recognition unavailable');
}
```

### Data Privacy

- **No Server Communication**: All speech processing happens in the browser
- **No Data Storage**: Transcripts are not stored or cached by the component
- **Event-Based**: Parent component controls what to do with transcripts
- **Browser API**: Uses native browser speech recognition (typically Google's service)

> **Note**: While the component itself doesn't transmit data, the browser's speech recognition service may send audio to external services (e.g., Google Cloud Speech API). This is controlled by the browser, not the component.

## 🐛 Error Handling

### Error Recovery

The component includes intelligent error recovery:

```javascript
handleSpeechError(event) {
    const { error, message, canRetry } = event.detail;

    switch(error) {
        case 'no-speech':
            // User didn't speak, allow retry
            this.showToast('Info', message, 'info');
            break;

        case 'not-allowed':
            // Permission denied, guide user
            this.showPermissionHelp();
            break;

        case 'network':
            // Network error, auto-retry
            setTimeout(() => {
                this.retryRecognition();
            }, 2000);
            break;

        default:
            this.showToast('Error', message, 'error');
    }
}
```

### Common Issues and Solutions

#### Issue: Button doesn't appear

**Solution**: Check browser support. The component automatically hides in unsupported browsers.

```javascript
// Check support before using
if (SpeechToTextService.isSupported()) {
    // Show speech features
} else {
    // Show fallback UI
}
```

#### Issue: Permission denied

**Solution**: Guide users to enable microphone permissions in browser settings.

```javascript
handleSpeechError(event) {
    if (event.detail.error === 'not-allowed') {
        this.showToast(
            'Microphone Required',
            'Please enable microphone access in your browser settings',
            'warning'
        );
    }
}
```

#### Issue: No speech detected

**Solution**: Increase `silenceDetectionDelay` or check microphone setup.

```html
<c-speech-to-text-input silence-detection-delay="{3000}"> </c-speech-to-text-input>
```

#### Issue: Low accuracy

**Solution**: Increase `confidenceThreshold` to filter low-quality results.

```html
<c-speech-to-text-input confidence-threshold="{0.8}"> </c-speech-to-text-input>
```

## 🧪 Testing

### Unit Testing Example

```javascript
// speechToTextInput.test.js
import { createElement } from 'lwc';
import SpeechToTextInput from 'c/speechToTextInput';

describe('c-speech-to-text-input', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('should render speech button when supported', () => {
        const element = createElement('c-speech-to-text-input', {
            is: SpeechToTextInput
        });
        document.body.appendChild(element);

        const button = element.shadowRoot.querySelector('lightning-button-icon');
        expect(button).not.toBeNull();
    });

    it('should emit speechresult event', async () => {
        const element = createElement('c-speech-to-text-input', {
            is: SpeechToTextInput
        });

        const handler = jest.fn();
        element.addEventListener('speechresult', handler);

        document.body.appendChild(element);

        // Simulate speech result
        // (Requires mocking SpeechRecognition API)

        await Promise.resolve();

        expect(handler).toHaveBeenCalled();
    });
});
```

### Integration Testing

Test the component integrated with parent components:

```javascript
// Test speech input integration with chat
it('should append voice input to chat message', async () => {
    const chatComponent = createElement('c-chat-component', {
        is: ChatComponent
    });
    document.body.appendChild(chatComponent);

    const speechInput = chatComponent.shadowRoot.querySelector('c-speech-to-text-input');

    // Simulate speech result
    speechInput.dispatchEvent(
        new CustomEvent('speechresult', {
            detail: { transcript: 'Hello World', confidence: 0.9 }
        })
    );

    await Promise.resolve();

    const textarea = chatComponent.shadowRoot.querySelector('lightning-textarea');
    expect(textarea.value).toContain('Hello World');
});
```

## 📊 Performance Considerations

### Resource Usage

- **Memory**: Minimal (< 1MB) - Component manages its own lifecycle
- **CPU**: Depends on browser's speech recognition implementation
- **Battery**: Speech recognition can be battery-intensive on mobile devices

### Best Practices

1. **Stop When Not Needed**: Always call `stop()` when recognition is no longer needed

    ```javascript
    disconnectedCallback() {
        const speechComponent = this.template.querySelector('c-speech-to-text-input');
        if (speechComponent) {
            speechComponent.stop();
        }
    }
    ```

2. **Use Appropriate Silence Delay**: Balance between responsiveness and premature stopping

    ```html
    <!-- For quick commands -->
    <c-speech-to-text-input silence-detection-delay="{1000}"></c-speech-to-text-input>

    <!-- For longer dictation -->
    <c-speech-to-text-input silence-detection-delay="{3000}"></c-speech-to-text-input>
    ```

3. **Optimize Interim Results**: Only enable if needed for your use case
    ```html
    <!-- Disable interim results for better performance -->
    <c-speech-to-text-input interim-results="{false}"></c-speech-to-text-input>
    ```

## 🔄 Lifecycle and State Management

### Component Lifecycle

```javascript
// Component lifecycle
connectedCallback()
    ├── Check browser support
    ├── Initialize speech service
    └── Set up event listeners

disconnectedCallback()
    ├── Stop active recognition
    ├── Clean up service
    └── Remove event listeners
```

### State Transitions

```
IDLE → LISTENING → PROCESSING → IDLE
  ↓        ↓           ↓
ERROR ← ERROR ←── ERROR
```

### State Management in Parent Component

```javascript
export default class ParentComponent extends LightningElement {
    speechState = 'idle'; // idle | listening | processing | error

    handleSpeechStart() {
        this.speechState = 'listening';
    }

    handleSpeechEnd() {
        this.speechState = 'processing';
        // Process the final transcript
        this.processSpeech();
    }

    handleSpeechError() {
        this.speechState = 'error';
    }

    processSpeech() {
        // Your processing logic
        this.speechState = 'idle';
    }
}
```

## 🚨 Troubleshooting

### Debug Mode

Enable detailed console logging by setting up event handlers:

```javascript
handleSpeechStart(event) {
    console.log('[DEBUG] Speech started:', event.detail);
}

handleSpeechEnd(event) {
    console.log('[DEBUG] Speech ended:', event.detail);
}

handleSpeechResult(event) {
    console.log('[DEBUG] Result:', event.detail);
}

handleInterimResult(event) {
    console.log('[DEBUG] Interim:', event.detail);
}

handleSpeechError(event) {
    console.error('[DEBUG] Error:', event.detail);
}
```

### Common Error Messages

| Error Code      | Meaning                                    | Solution                               |
| --------------- | ------------------------------------------ | -------------------------------------- |
| `not-supported` | Browser doesn't support speech recognition | Use Chrome, Edge, or Safari            |
| `not-allowed`   | Microphone permission denied               | Enable permissions in browser settings |
| `no-speech`     | No speech detected                         | Speak closer to microphone             |
| `audio-capture` | Microphone not available                   | Check microphone connection            |
| `network`       | Network error                              | Check internet connection              |

## 📚 Advanced Topics

### Extending the Component

You can extend the component for custom behavior:

```javascript
// customSpeechInput.js
import SpeechToTextInput from 'c/speechToTextInput';

export default class CustomSpeechInput extends SpeechToTextInput {
    // Override methods
    handleSpeechToggle() {
        // Custom logic before starting
        this.logAnalytics('speech_button_clicked');

        // Call parent method
        super.handleSpeechToggle();
    }

    // Add custom methods
    logAnalytics(eventName) {
        // Your analytics logic
    }
}
```

### Custom Error Handling

```javascript
// Implement sophisticated error handling
handleSpeechError(event) {
    const { error, message, canRetry } = event.detail;

    // Log to monitoring service
    this.logError({
        component: 'speechToText',
        error: error,
        message: message,
        timestamp: new Date().toISOString()
    });

    // User feedback based on error severity
    if (error === 'not-allowed') {
        this.showModal({
            title: 'Microphone Access Required',
            content: this.getMicrophoneGuide(),
            actions: ['Open Settings', 'Cancel']
        });
    } else if (canRetry) {
        this.showRetryNotification(message);
    } else {
        this.disableSpeechFeature();
    }
}
```

### Multi-Language Application

```javascript
// languageAwareComponent.js
export default class LanguageAwareComponent extends LightningElement {
    @track currentLanguage = 'en-US';

    get languageOptions() {
        return [
            { label: 'English (US)', value: 'en-US' },
            { label: 'Spanish', value: 'es-ES' },
            { label: 'French', value: 'fr-FR' },
            { label: 'German', value: 'de-DE' }
        ];
    }

    handleLanguageChange(event) {
        this.currentLanguage = event.detail.value;

        // Stop current recognition
        const speechComponent = this.template.querySelector('c-speech-to-text-input');
        if (speechComponent.isListening()) {
            speechComponent.stop();
        }
    }
}
```

## 📖 References

### Web Speech API

- [MDN Web Speech API Documentation](https://developer.mozilla.org/en-US/docs/Web/API/Web_Speech_API)
- [W3C Speech API Specification](https://w3c.github.io/speech-api/)

### Lightning Web Components

- [LWC Developer Guide](https://developer.salesforce.com/docs/component-library/documentation/en/lwc)
- [Lightning Design System](https://www.lightningdesignsystem.com/)

## 📄 License

This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

Copyright (c) 2025 Sonal

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!

### Development Guidelines

1. **Code Style**: Follow LWC and JavaScript best practices
2. **Documentation**: Update README for any API changes
3. **Testing**: Add tests for new features
4. **Accessibility**: Maintain WCAG 2.1 AA compliance
5. **Performance**: Profile and optimize for mobile devices

---

## 📞 Support

For issues, questions, or feature requests, please refer to the project's issue tracker or contact the maintainer.

---

**Last Updated**: 2025-10-10
**Component Version**: 1.0.0
**API Version**: 63.0
