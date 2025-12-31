---
layout: default
title: Architecture
nav_order: 5
parent: Reference
---

# Architecture Overview
{: .no_toc }

Understanding how the framework processes requests and executes actions.
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Request Flow

```
┌─────────────┐     ┌──────────────┐     ┌─────────────────┐
│   User      │────▶│  Controller  │────▶│  Orchestrator   │
│   Input     │     │              │     │                 │
└─────────────┘     └──────────────┘     └────────┬────────┘
                                                  │
                    ┌─────────────────────────────┘
                    ▼
┌─────────────────────────────────────────────────────────┐
│                    Async Processing                      │
│  ┌─────────────┐     ┌─────────────┐     ┌───────────┐  │
│  │    LLM      │────▶│    Tool     │────▶│  Follow   │  │
│  │  Provider   │     │  Execution  │     │  Up LLM   │  │
│  └─────────────┘     └─────────────┘     └───────────┘  │
└─────────────────────────────────────────────────────────┘
                                                  │
                    ┌─────────────────────────────┘
                    ▼
              ┌───────────┐
              │  Response │
              │  to User  │
              └───────────┘
```

---

## Core Components

### Entry Points

| Component | Purpose | Use Case |
|:----------|:--------|:---------|
| `AgentExecutionService` | Main programmatic entry | Apex integrations |
| `ConversationalChatController` | LWC controller | Chat UI |
| `AIAgentRestService` | REST API | External integrations |

### Orchestrators

Orchestrators manage the execution flow for different agent types.

| Orchestrator | Agent Type | Behavior |
|:-------------|:-----------|:---------|
| `ConversationalOrchestrator` | Conversational | Multi-turn with memory |
| `FunctionOrchestrator` | Function | Single-shot execution |
| `WorkflowOrchestrator` | Workflow | Multi-step sequences |

### Core Services

| Service | Responsibility |
|:--------|:---------------|
| `LLMInteractionService` | Communicates with AI providers |
| `OrchestrationService` | Coordinates LLM and tool execution |
| `CapabilityExecutionService` | Executes agent actions |
| `AgentStateService` | Manages execution lifecycle |
| `ContextManagerService` | Handles memory and context |

---

## AI Provider Integration

### Adapter Pattern

The framework uses adapters to support multiple AI providers with a consistent interface.

```
┌─────────────────────────────────────────────────────────┐
│                  LLMInteractionService                   │
└─────────────────────────┬───────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          ▼               ▼               ▼
┌─────────────────┐ ┌─────────────┐ ┌─────────────────┐
│ OpenAIProvider  │ │ ClaudeProvider│ │ GeminiProvider  │
│    Adapter      │ │    Adapter    │ │    Adapter      │
└─────────────────┘ └─────────────┘ └─────────────────┘
          │               │               │
          ▼               ▼               ▼
┌─────────────────┐ ┌─────────────┐ ┌─────────────────┐
│   OpenAI API    │ │ Anthropic   │ │   Google AI     │
│                 │ │    API      │ │                 │
└─────────────────┘ └─────────────┘ └─────────────────┘
```

### Available Adapters

| Adapter | Provider | Models |
|:--------|:---------|:-------|
| `OpenAIProviderAdapter` | OpenAI | GPT-4o, GPT-4o-mini, GPT-4-turbo |
| `ClaudeProviderAdapter` | Anthropic | Claude 3 Sonnet, Claude 3.5 Sonnet |
| `GeminiProviderAdapter` | Google | Gemini 1.5 Pro, Gemini 1.5 Flash |

---

## Memory Management

### Buffer Window Strategy

Keeps the last N conversation turns verbatim.

```
Turn 1: User asks about accounts     ─┐
Turn 2: Agent responds               │
Turn 3: User asks follow-up          │ Kept in context
Turn 4: Agent responds               │
Turn 5: User asks another question   ─┘
Turn 6: (Turn 1 dropped when limit reached)
```

**Best for**: Short conversations, precise context needed

### Summary Buffer Strategy

Summarizes older turns to preserve context while reducing tokens.

```
[Summary of turns 1-5]              ─┐
Turn 6: Recent user message          │ Sent to LLM
Turn 7: Recent agent response        │
Turn 8: Current user message        ─┘
```

**Best for**: Long conversations, cost optimization

---

## Tool Execution

### Execution Flow

1. **LLM decides** to use a tool based on user request
2. **Framework validates** permissions and parameters
3. **Action executes** the Salesforce operation
4. **Results returned** to LLM for formatting
5. **LLM generates** user-friendly response

### Action Types

| Type | Implementation | Use Case |
|:-----|:---------------|:---------|
| Standard | Built-in classes | Common operations |
| Apex | Custom `IAgentAction` | Complex logic |
| Flow | Salesforce Flow | No-code automation |

---

## Observability

### Decision Steps

Every interaction is logged to `AgentDecisionStep__c`:

| Field | Content |
|:------|:--------|
| `UserInput__c` | What the user said |
| `LLMRequest__c` | Full request to AI provider |
| `LLMResponse__c` | Full response from AI |
| `ToolCalls__c` | Tools the AI decided to use |
| `ToolResults__c` | Results from tool execution |
| `TokensUsed__c` | Token consumption |
| `ExecutionTime__c` | Processing duration |

### Querying Decision Steps

```sql
SELECT Id, UserInput__c, LLMResponse__c, TokensUsed__c
FROM AgentDecisionStep__c
WHERE AgentExecution__c = :executionId
ORDER BY CreatedDate ASC
```

---

## Extension Points

### Adding New Agent Types

Implement `IAgentOrchestrator`:

```apex
public interface IAgentOrchestrator {
    void initialize(AIAgentDefinition__c agent);
    AgentResponse process(AgentRequest request);
    void cleanup();
}
```

### Adding New AI Providers

Extend `BaseProviderAdapter`:

```apex
public class MyProviderAdapter extends BaseProviderAdapter {
    public override LLMResponse sendRequest(LLMRequest request) {
        // Implementation
    }
}
```

### Adding Custom Actions

Implement `IAgentAction`:

```apex
public interface IAgentAction {
    ActionResult execute(ActionContext context);
    Boolean validatePermissions(ActionContext context);
}
```

### Adding Memory Strategies

Implement `IMemoryManager`:

```apex
public interface IMemoryManager {
    List<Message> getContextMessages(String executionId);
    void saveMessage(String executionId, Message msg);
    void summarize(String executionId);
}
```

---

## Performance Considerations

### Token Optimization

- Use appropriate `HistoryTurnLimit__c`
- Choose `SummaryBuffer` for long conversations
- Keep capability descriptions concise but clear
- Limit fields in `BackendConfiguration__c`

### Concurrency

| Mode | Limit | Best For |
|:-----|:------|:---------|
| Platform Events | High | Production, many users |
| Queueables | ~50 concurrent | Development, debugging |

### Caching

The framework caches:
- Agent definitions
- LLM configurations
- Capability metadata

Cache is invalidated on configuration changes.
