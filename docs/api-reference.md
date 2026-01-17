---
layout: default
title: API Reference
nav_order: 4
parent: Reference
---

# API Reference
{: .no_toc }

Complete REST API documentation for AI Agent Studio.
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Overview

AI Agent Studio provides a REST API for processing agent messages and executing human-in-the-loop (HITL) approved actions. All endpoints use JSON for request and response payloads.

### Base URL

```
https://YOUR-INSTANCE.salesforce.com/services/apexrest/ai/agent
```

### Authentication

All API endpoints require Salesforce authentication via one of the following methods:

- **Session ID**: Standard Salesforce session token
- **OAuth 2.0**: JWT Bearer Flow or Named Credential
- **Connected App**: For external integrations

Include authentication in the `Authorization` header:
```text
Authorization: Bearer YOUR_ACCESS_TOKEN
```

### Content Type

All requests must include:
```text
Content-Type: application/json
```

---

## Endpoints

### Process Chat Message

Process a user message through an AI agent with full conversation context.

#### Request

**Endpoint:** `POST /services/apexrest/ai/agent/process`

**Headers:**
```text
Authorization: Bearer YOUR_ACCESS_TOKEN
Content-Type: application/json
```

**Body Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `sessionId` | String (ID) | Yes | Unique identifier for the agent execution session |
| `originalUserId` | String (ID) | Yes | Salesforce User ID who initiated the request |
| `agentDefinitionId` | String (ID) | Yes | ID of the AIAgentDefinition__c record |
| `turnIdentifier` | String | Yes | Unique identifier for this conversation turn |
| `userMessage` | String | Yes | The user's message text |
| `currentRecordId` | String (ID) | No | Contextual Salesforce record ID (e.g., Case, Account) |

**Example Request:**

```text
POST /services/apexrest/ai/agent/process
Content-Type: application/json
Authorization: Bearer YOUR_SESSION_TOKEN
```

```json
{
  "sessionId": "a0X5g000001234567",
  "originalUserId": "0055g000001234567",
  "agentDefinitionId": "a0Y5g000001234567",
  "turnIdentifier": "turn-2024-01-15-12-30-45-abc123",
  "userMessage": "Create a follow-up task for this case",
  "currentRecordId": "5005g000001234567"
}
```

#### Response

**Success Response (200 OK):**

```json
{
  "success": true,
  "outcome": "Processing",
  "error": null,
  "requestId": "12345678"
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `success` | Boolean | Indicates if the request was successfully accepted |
| `outcome` | String | Processing status: "Processing", "Completed", "Failed" |
| `error` | String | Error message if success is false, otherwise null |
| `requestId` | String | Unique request identifier for troubleshooting |

**Error Responses:**

| Status Code | Description | Example Response |
|-------------|-------------|------------------|
| 400 Bad Request | Invalid request format or missing required fields | `{"success": false, "error": "sessionId is required", "requestId": "12345678"}` |
| 403 Forbidden | Authentication or authorization failure | `{"success": false, "error": "Access denied: Insufficient privileges", "requestId": "12345678"}` |
| 500 Internal Server Error | Unexpected server error | `{"success": false, "error": "Internal server error: <details>", "requestId": "12345678"}` |

#### Status Codes

- `200 OK` - Request successfully processed
- `400 Bad Request` - Invalid input data
- `403 Forbidden` - Access denied
- `500 Internal Server Error` - Server-side error

---

### Execute HITL Approved Tool

Execute a tool that has been approved through the Human-in-the-Loop workflow. This endpoint is called after a user approves an action that requires human confirmation or approval.

#### Request

**Endpoint:** `POST /services/apexrest/ai/agent/hitl/execute`

**Headers:**
```text
Authorization: Bearer YOUR_ACCESS_TOKEN
Content-Type: application/json
```

**Body Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `pendingActionId` | String (ID) | Yes | ID of the PendingHITLAction__c record |
| `executionId` | String (ID) | Yes | ID of the AgentExecution__c record |
| `capabilityId` | String (ID) | Yes | ID of the AgentCapability__c to execute |
| `toolCallId` | String | No | LLM tool call identifier |
| `toolName` | String | No | Name of the tool being executed |
| `toolArguments` | String (JSON) | No | JSON string of tool arguments |
| `turnIdentifier` | String | No | Conversation turn identifier |
| `turnCount` | Decimal | No | Current turn count in the conversation |
| `sourceRecordId` | String (ID) | No | Contextual Salesforce record ID |
| `requestingUserId` | String (ID) | No | User ID who requested the action (for notifications) |
| `needsFollowUp` | Boolean | No | Whether a follow-up LLM call is needed after execution |

**Example Request:**

```text
POST /services/apexrest/ai/agent/hitl/execute
Content-Type: application/json
Authorization: Bearer YOUR_SESSION_TOKEN
```

```json
{
  "pendingActionId": "a0Z5g000001234567",
  "executionId": "a0X5g000001234567",
  "capabilityId": "a0W5g000001234567",
  "toolCallId": "call_abc123xyz789",
  "toolName": "CreateTask",
  "toolArguments": "{\"Subject\":\"Follow up on case\",\"Priority\":\"High\"}",
  "turnIdentifier": "turn-2024-01-15-12-30-45-abc123",
  "turnCount": 3,
  "sourceRecordId": "5005g000001234567",
  "requestingUserId": "0055g000001234567",
  "needsFollowUp": true
}
```

#### Response

**Success Response (200 OK):**

```json
{
  "success": true,
  "outcome": "Tool executed successfully",
  "error": null,
  "requestId": "12345678"
}
```

**Error Responses:**

| Status Code | Description | Example Response |
|-------------|-------------|------------------|
| 400 Bad Request | Invalid request or capability not found | `{"success": false, "error": "capabilityId is required", "requestId": "12345678"}` |
| 403 Forbidden | Insufficient permissions | `{"success": false, "error": "Access denied", "requestId": "12345678"}` |
| 500 Internal Server Error | Tool execution failure | `{"success": false, "error": "Internal server error: DML exception", "requestId": "12345678"}` |

---

## Data Types

### Agent Execution Session

An agent execution session represents an ongoing conversation between a user and an AI agent.

```json
{
  "Id": "a0X5g000001234567",
  "User__c": "0055g000001234567",
  "AIAgentDefinition__c": "a0Y5g000001234567",
  "ExecutionStatus__c": "Processing",
  "CurrentTurnIdentifier__c": "turn-2024-01-15-12-30-45-abc123"
}
```

### Agent Capability

Represents a tool or action that an agent can execute.

```json
{
  "Id": "a0W5g000001234567",
  "CapabilityName__c": "CreateTask",
  "Description__c": "Creates a Salesforce Task",
  "ImplementationType__c": "StandardAction",
  "HITLMode__c": "Approval",
  "ExposureLevel__c": "External"
}
```

### Pending HITL Action

Represents an action awaiting human approval.

```json
{
  "Id": "a0Z5g000001234567",
  "AgentExecution__c": "a0X5g000001234567",
  "AgentCapability__c": "a0W5g000001234567",
  "Status__c": "Pending",
  "RequestedBy__c": "0055g000001234567",
  "AssignedTo__c": "0055g000001234568",
  "RequestMessage__c": "Approve task creation"
}
```

---

## Error Handling

### Error Response Format

All error responses follow this format:

```json
{
  "success": false,
  "outcome": null,
  "error": "ERROR_MESSAGE_HERE",
  "requestId": "UNIQUE_REQUEST_ID"
}
```

### Common Error Codes

| Error Message | Cause | Solution |
|---------------|-------|----------|
| `sessionId is required` | Missing required field | Include sessionId in request body |
| `Invalid sessionId format` | Malformed Salesforce ID | Provide valid 15 or 18-character ID |
| `Agent definition not found` | Invalid or inactive agent | Verify agent exists and is active |
| `Access denied: Insufficient privileges` | User lacks permissions | Grant required permissions |
| `Configuration error: Capability not found` | Invalid capability ID | Verify capability exists |
| `Internal server error` | Unexpected system error | Check logs and contact support |

### Request ID

Every response includes a `requestId` field for troubleshooting. When reporting issues, include this ID to help diagnose problems quickly.

---

## Rate Limits

- **Chat Message Processing**: 100 requests per minute per user
- **HITL Tool Execution**: 50 requests per minute per user
- **Concurrent Sessions**: 10 active sessions per user

Exceeding rate limits returns:
```json
{
  "success": false,
  "error": "Rate limit exceeded. Please retry after 60 seconds.",
  "requestId": "12345678"
}
```

---

## Security Considerations

### User Context Management

- **Chat Processing**: Executes in service user context (elevated permissions)
- **HITL Execution**: Executes in authenticated user context (user-specific permissions)

### Best Practices

1. **Always validate user input** before passing to API
2. **Use HTTPS** for all API calls
3. **Rotate access tokens** regularly
4. **Implement request logging** for audit trails
5. **Monitor rate limits** to avoid throttling
6. **Validate Salesforce IDs** before making requests

### Field-Level Security

All actions respect Salesforce Field-Level Security (FLS) and Object-Level Security (OLS). Users can only access data they have permission to see.

---

## Examples

### Complete Chat Conversation Flow

```javascript
// 1. Start a new conversation
const startResponse = await fetch('https://instance.salesforce.com/services/apexrest/ai/agent/process', {
  method: 'POST',
  headers: {
    'Authorization': 'Bearer ' + accessToken,
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    sessionId: newSessionId,
    originalUserId: currentUserId,
    agentDefinitionId: agentDefId,
    turnIdentifier: generateTurnId(),
    userMessage: 'Help me close this case',
    currentRecordId: caseId
  })
});

const result = await startResponse.json();
console.log('Status:', result.outcome); // "Processing"

// 2. Continue the conversation
const followUpResponse = await fetch('https://instance.salesforce.com/services/apexrest/ai/agent/process', {
  method: 'POST',
  headers: {
    'Authorization': 'Bearer ' + accessToken,
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    sessionId: newSessionId, // Same session
    originalUserId: currentUserId,
    agentDefinitionId: agentDefId,
    turnIdentifier: generateTurnId(), // New turn ID
    userMessage: 'Yes, please create a follow-up task',
    currentRecordId: caseId
  })
});
```

### Execute Approved HITL Tool

```javascript
// After user approves an action in the UI
const executeResponse = await fetch('https://instance.salesforce.com/services/apexrest/ai/agent/hitl/execute', {
  method: 'POST',
  headers: {
    'Authorization': 'Bearer ' + accessToken,
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    pendingActionId: pendingActionRecord.Id,
    executionId: sessionId,
    capabilityId: capability.Id,
    toolCallId: 'call_abc123',
    toolName: 'CreateTask',
    toolArguments: JSON.stringify({
      Subject: 'Follow up on case',
      Priority: 'High',
      WhatId: caseId
    }),
    turnIdentifier: currentTurnId,
    turnCount: 3,
    requestingUserId: currentUserId,
    needsFollowUp: true
  })
});

const result = await executeResponse.json();
if (result.success) {
  console.log('Tool executed successfully');
}
```

---

## OpenAPI Specification

For automated API client generation, see our complete [OpenAPI 3.0 specification](./openapi.yml).

Download the spec:
- [openapi.yml](./openapi.yml) - YAML format
- [openapi.json](./openapi.json) - JSON format

Use with tools like:
- **Swagger UI**: Interactive API documentation
- **Postman**: Import for testing
- **OpenAPI Generator**: Generate client SDKs

---

{: .fs-3 }
[Download OpenAPI Spec](./openapi.yml){: .btn .btn-primary .fs-5 .mb-4 .mb-md-0 }
