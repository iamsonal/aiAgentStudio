# Universal EmpApi

A reusable Lightning Web Component service that provides platform event streaming capabilities for both Lightning Experience and Communities.

## Features

- **Universal Compatibility**: Automatically detects environment and uses appropriate streaming method
- **Lightning Experience**: Uses native `lightning/empApi`
- **Communities**: Uses CometD with session-based authentication
- **Simple API**: Drop-in replacement for `lightning/empApi`
- **Error Handling**: Built-in error handling with optional custom error callbacks
- **Cleanup**: Automatic cleanup of subscriptions and connections

## Installation

1. Deploy the `universalEmpApi` component to your org
2. Ensure you have the `EventSubscriptionHelper` Apex class deployed
3. Ensure you have the `cometdlwc` static resource with CometD library

## Usage

### Basic Usage

```javascript
import { UniversalEmpApi } from 'c/universalEmpApi';

export default class MyComponent extends LightningElement {
    empApi = new UniversalEmpApi();

    async connectedCallback() {
        // Initialize the service (defaults to Lightning Experience mode)
        await this.empApi.initialize();

        // For Community environments, pass true as second parameter:
        // await this.empApi.initialize(null, true);

        // Subscribe to a platform event
        await this.empApi.subscribe('/event/MyEvent__e', -1, (message) => {
            console.log('Received message:', message.data.payload);
        });
    }

    disconnectedCallback() {
        // Clean up subscriptions
        this.empApi.cleanup();
    }
}
```

### Advanced Usage with Error Handling

```javascript
import { UniversalEmpApi } from 'c/universalEmpApi';

export default class MyComponent extends LightningElement {
    empApi = new UniversalEmpApi();

    async connectedCallback() {
        // Initialize with custom error handler (Lightning Experience mode)
        await this.empApi.initialize((message, error) => {
            console.error('EmpApi Error:', message, error);
            // Handle error in your component
        }, false); // false = Lightning Experience, true = Community

        // Subscribe to multiple channels
        await this.empApi.subscribe('/event/AgentResponse__e', -1, this.handleAgentResponse.bind(this));
        await this.empApi.subscribe('/event/TransientMessage__e', -1, this.handleTransientMessage.bind(this));
    }

    handleAgentResponse(message) {
        const payload = message.data.payload;
        // Handle agent response
    }

    handleTransientMessage(message) {
        const payload = message.data.payload;
        // Handle transient message
    }

    async unsubscribeFromChannel() {
        // Unsubscribe from specific channel
        await this.empApi.unsubscribe('/event/AgentResponse__e');
    }

    checkConnection() {
        // Check connection status
        const isConnected = this.empApi.isConnected();
        const info = this.empApi.getConnectionInfo();
        console.log('Connected:', isConnected, 'Info:', info);
    }

    disconnectedCallback() {
        this.empApi.cleanup();
    }
}
```

## API Reference

### Methods

#### `initialize(errorCallback?, forceCommunityMode?)`

Initialize the Universal EmpApi service.

- `errorCallback` (optional): Function to handle errors
- `forceCommunityMode` (optional): Boolean - true for Community/Experience Cloud, false or undefined for Lightning Experience

#### `subscribe(channel, replayId, callback)`

Subscribe to a platform event channel.

- `channel`: Platform event channel (e.g., '/event/MyEvent\_\_e')
- `replayId`: Replay ID (-1 for new events, -2 for all retained events)
- `callback`: Function to handle received messages

#### `unsubscribe(channel)`

Unsubscribe from a platform event channel.

- `channel`: Platform event channel to unsubscribe from

#### `isConnected()`

Check if the service is connected and ready.
Returns: `boolean`

#### `getConnectionInfo()`

Get information about the current connection.
Returns: `Object` with connection details

#### `cleanup()`

Clean up all subscriptions and connections.

## Requirements

- Salesforce org with platform events enabled
- `EventSubscriptionHelper` Apex class for session ID retrieval
- `cometdlwc` static resource with CometD library
- Proper permissions for Community users (if using in Communities)

## Environment Configuration

The service uses the appropriate streaming method based on the provided environment mode:

- **Lightning Experience**: Uses native `lightning/empApi` (default)
- **Community/Experience Cloud**: Uses CometD when `forceCommunityMode` is set to `true`

No automatic detection is performed - the environment must be explicitly specified.

## Error Handling

The service includes built-in error handling for:

- Initialization failures
- Subscription failures
- Connection issues
- Handshake failures (CometD)

Errors can be handled through the optional error callback or will be logged to console by default.
