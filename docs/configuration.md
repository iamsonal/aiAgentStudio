---
layout: default
title: Configuration
nav_order: 3
parent: Guides
---

# Configuration Guide
{: .no_toc }

Complete reference for all agent and capability settings.
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Agent Configuration

### Basic Settings

| Field | Type | Description |
|:------|:-----|:------------|
| `Name` | Text | Display name for the agent |
| `DeveloperName__c` | Text | Unique API identifier (no spaces) |
| `AgentType__c` | Picklist | Conversational, Function, Workflow, or Email |
| `IsActive__c` | Checkbox | Enable/disable the agent |

### AI Provider Settings

| Field | Type | Description |
|:------|:-----|:------------|
| `LLMConfiguration__c` | Lookup | Which AI provider configuration to use |
| `MemoryStrategy__c` | Picklist | How to manage conversation history |
| `HistoryTurnLimit__c` | Number | Number of conversation turns to remember |

### Memory Strategies

| Strategy | Description | Best For |
|:---------|:------------|:---------|
| `BufferWindow` | Keeps last N turns verbatim | Short conversations, precise context |
| `SummaryBuffer` | Summarizes older turns | Long conversations, cost optimization |

### Behavior Settings

| Field | Type | Description |
|:------|:-----|:------------|
| `IdentityPrompt__c` | Long Text | Defines who the agent is (persona) |
| `InstructionsPrompt__c` | Long Text | How the agent should behave |
| `EnableActionTransparency__c` | Checkbox | Show tool execution details to users |
| `EnableToolReasoning__c` | Checkbox | Require LLM to explain tool selection for better transparency |
| `AuditLevel__c` | Picklist | None, Standard, or Detailed logging |
| `EnableDependencyValidation__c` | Checkbox | Enforce tool dependency graph at runtime |
| `ToolDependencyGraph__c` | Long Text | JSON dependency graph (approved) |
| `EnableNextStepSuggestion__c` | Checkbox | Injects `_nextStepSuggestion` into tools (experimental) |

### Performance Settings

| Field | Type | Description |
|:------|:-----|:------------|
| `AsyncDispatchType__c` | Picklist | High (Platform Events) or Low (Queueables) |
| `EnableParallelToolCalling__c` | Checkbox | Execute multiple tools simultaneously |
| `MaxProcessingCycles__c` | Number | Max LLM cycles per execution |

### Service User Context (Optional)

| Field | Type | Description |
|:------|:-----|:------------|
| `RequiresServiceUserContext__c` | Checkbox | Route execution through service user context via REST callout |
| `ServiceUserNamedCredential__c` | Text | Named Credential for loopback callouts |

### Trust & Safety

| Field | Type | Description |
|:------|:-----|:------------|
| `PIIMaskingMode__c` | Picklist | Hybrid, Schema-Only, or Pattern-Only |
| `SensitiveClassifications__c` | Multi-Select | Data classifications to mask |
| `PIIPatternCategories__c` | Multi-Select | Regex pattern categories to enable |
| `PromptSafetyMode__c` | Picklist | Block, Sanitize, Flag, or LogOnly |
| `SafetyThreshold__c` | Number | Threat score threshold (0.0–1.0) |
| `SafetyPatternCategories__c` | Multi-Select | Which jailbreak categories to enable |

---

## Async Dispatch Types

### High Concurrency (Platform Events)

Best for production environments with many concurrent users.

- Handles thousands of simultaneous conversations
- Event-driven architecture
- Better scalability
- Harder to debug

### Low Concurrency (Queueables)

Best for development, testing, and debugging.

- Sequential processing
- Full debug log support
- Guaranteed execution order
- Limited concurrent executions

---

## LLM Configuration

| Field | Type | Description |
|:------|:-----|:------------|
| `DeveloperName__c` | Text | Unique identifier |
| `NamedCredential__c` | Text | Named Credential API name |
| `ProviderAdapterClass__c` | Text | Apex class for provider integration |
| `DefaultModelIdentifier__c` | Text | Model identifier (e.g., gpt-4o) |
| `DefaultTemperature__c` | Number | Creativity level (0.0 - 1.0) |
| `IsActive__c` | Checkbox | Enable this configuration |

### Temperature Guide

| Value | Behavior | Use Case |
|:------|:---------|:---------|
| 0.0 - 0.3 | Deterministic, focused | Data retrieval, classification |
| 0.4 - 0.7 | Balanced | General assistance |
| 0.8 - 1.0 | Creative, varied | Content generation |

---

## Capability Configuration

### Basic Info

| Field | Type | Description |
|:------|:-----|:------------|
| `CapabilityName__c` | Text | Tool name shown to AI (use snake_case) |
| `Description__c` | Long Text | When and how to use this tool |
| `ImplementationType__c` | Picklist | Standard, Apex, or Flow |

### Implementation Types

| Type | Description | Use Case |
|:-----|:------------|:---------|
| `Standard` | Built-in actions | Common Salesforce operations |
| `Apex` | Custom Apex class | Complex business logic |
| `Flow` | Salesforce Flow | No-code automation |

### Execution Settings

| Field | Type | Description |
|:------|:-----|:------------|
| `HITLMode__c` | Picklist | Human-in-the-Loop mode: blank (no HITL), Confirmation (LLM asks in chat), Approval (formal approval process), or ConfirmationThenApproval (both) |
| `HITLNotificationPreference__c` | Picklist | Controls when to send notifications for HITL actions: "Always Notify" (default) sends notifications for approvals, rejections, and errors; "Notify on Rejection Only" only sends notifications when actions are rejected. Only applies when `HITLMode__c` is "Approval" or "ConfirmationThenApproval". |
| `RunAsynchronously__c` | Checkbox | Execute in separate transaction |
| `FailFastOnError__c` | Checkbox | Stop immediately on error |
| `ExposureLevel__c` | Picklist | External (visible to LLM), Internal (framework only), or Disabled |

### Configuration Fields

| Field | Type | Description |
|:------|:-----|:------------|
| `BackendConfiguration__c` | Long Text | Admin settings (JSON) |
| `Parameters__c` | Long Text | Tool parameters (JSON Schema) |

---

## Writing Effective Descriptions

The capability description is crucial for the AI to understand when to use a tool.

### Good Description Example

```
Search for contacts in Salesforce by name, email, or account.
Use this capability when:
- User asks to find a contact
- User wants contact information
- User mentions a person's name in a business context

Do NOT use when:
- User is asking about accounts (use search_accounts instead)
- User wants to create a new contact (use create_contact instead)
```

### Bad Description Example

```
Gets contacts
```

---

## JSON Schema for Parameters

Parameters use [JSON Schema](https://json-schema.org/) format.

### Basic Example

```json
{
  "type": "object",
  "properties": {
    "name": {
      "type": "string",
      "description": "The contact's full name"
    }
  }
}
```

### With Required Fields

```json
{
  "type": "object",
  "required": ["email"],
  "properties": {
    "email": {
      "type": "string",
      "description": "Email address (required)"
    },
    "name": {
      "type": "string",
      "description": "Optional name filter"
    }
  }
}
```

### With Enums

```json
{
  "type": "object",
  "properties": {
    "priority": {
      "type": "string",
      "enum": ["High", "Normal", "Low"],
      "description": "Task priority level"
    }
  }
}
```

### Complex Example

```json
{
  "type": "object",
  "required": ["objectType"],
  "properties": {
    "objectType": {
      "type": "string",
      "enum": ["Account", "Contact", "Opportunity"],
      "description": "Salesforce object to search"
    },
    "filters": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "field": {"type": "string"},
          "operator": {"type": "string", "enum": ["=", "!=", "LIKE"]},
          "value": {"type": "string"}
        }
      },
      "description": "Search filters to apply"
    },
    "limit": {
      "type": "integer",
      "minimum": 1,
      "maximum": 100,
      "default": 10,
      "description": "Maximum records to return"
    }
  }
}
```

---

## Backend Configuration Examples

### GetRecords Action

```json
{
  "objectApiName": "Contact",
  "defaultFields": ["Id", "Name", "Email", "Phone", "Account.Name"],
  "defaultLimit": 25
}
```

### CreateRecord Action

```json
{
  "objectApiName": "Task",
  "defaultValues": {
    "OwnerId": "{!$User.Id}",
    "Status": "Not Started"
  }
}
```

### Flow Action

For Flow implementation, set `ImplementationType__c` to `Flow` and put the Flow API name in `ImplementationDetail__c`.

```json
{
  "defaultInputValues": {
    "source": "AI_Agent"
  }
}
```
