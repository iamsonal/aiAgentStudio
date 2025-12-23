# Salesforce AI Agent Framework

> **Enterprise-Grade AI Platform for Salesforce**

Build intelligent AI agents powered by Large Language Models that seamlessly integrate with your Salesforce environment. Designed for security, scalability, and ease of use.

[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Salesforce](https://img.shields.io/badge/Salesforce-API%20v63.0-blue.svg)](https://developer.salesforce.com/)

---

## ⚠️ Repository Notice

**This repository contains the core AI Agent Framework only.** The `aiAgentStudioAddons` folder visible in the codebase contains proprietary extensions and enhanced UI components that are **NOT part of the open-source repository**. These addons include:

- Function and Workflow orchestrators
- Additional LLM provider adapters (Claude, Gemini)
- Extended action handlers (ManageTasks, RunReport, SearchKnowledge, SendNotification)
- Advanced UI components (Agent Storyboard, Capability Configurator)
- Bulk execution capabilities
- Trigger handlers and validation logic

If you're cloning this repository, you will have access to the core framework in the `force-app` directory, which provides all fundamental capabilities for building conversational AI agents with OpenAI.

---

## 🎯 What is This?

The Salesforce AI Agent Framework lets you create AI-powered assistants that can:

- 💬 **Chat naturally** with users and remember conversation context
- 🔍 **Search and retrieve** Salesforce data intelligently
- ✏️ **Create and update** records based on user requests
- 🔄 **Execute workflows** with multiple steps automatically
- 🔒 **Respect permissions** - agents only access what users can access
- 🎯 **Work with multiple AI providers** - OpenAI, Claude, Gemini

**Who is this for?**
- **Admins**: Configure AI agents without code using point-and-click tools
- **Managers**: Understand what AI agents can do for your team
- **Developers**: Extend the framework with custom actions and integrations

---

## ✨ Key Features

### Three Types of AI Agents

**Conversational Agents** - Interactive chat assistants
- Multi-turn conversations with memory
- Perfect for customer support, sales assistance, help desks
- Example: "Find all open cases for Acme Corp" → "Update the priority to High"

**Function Agents** - Single-task specialists
- One-shot operations like summarization or classification
- Fast, stateless execution
- Example: "Summarize this case" → Instant summary

**Workflow Agents** - Multi-step automation
- Orchestrate complex processes with multiple agents
- Sequential execution with checkpoints
- Example: New case → Classify → Route → Notify → Follow-up

### Smart Memory Management

- **Buffer Window**: Remembers the last N conversation turns
- **Summary Buffer**: Automatically summarizes old conversations to save context
- Prevents token overload while maintaining conversation flow

### Built-in Security

- Automatic CRUD and Field-Level Security (FLS) enforcement
- Respects Salesforce sharing rules
- User context tracking for audit trails
- No privilege escalation - agents work within user permissions

### Multiple AI Providers

- **OpenAI**: GPT-4o, GPT-4o-mini, GPT-4-turbo
- **Claude**: Claude 3 Sonnet, Claude 3.5 Sonnet
- **Gemini**: Gemini 1.5 Pro, Gemini 1.5 Flash
- Easy to add more providers through adapter pattern

### Standard Actions (Tools)

The framework includes ready-to-use actions that agents can perform:

**Data Operations**
- `ActionCreateRecord` - Create any Salesforce record
- `ActionUpdateRecord` - Update existing records
- `ActionGetRecordDetails` - Retrieve and search records

**Communication**
- `ActionPostChatter` - Post to Chatter feeds
- `ActionSendEmail` - Send emails
- `ActionSendNotification` - Send custom notifications

**Automation**
- `ActionFlowHandler` - Execute Salesforce Flows
- `ActionManageTasks` - Create and manage tasks
- `ActionRunReport` - Execute reports and retrieve results

**Knowledge & Search**
- `ActionSearchKnowledge` - Search knowledge articles

### Async Processing Options

Choose the right processing mode for your needs:

**High Concurrency Mode** (Platform Events)
- Best for: Many concurrent users, chat applications
- Handles thousands of simultaneous conversations
- Event-driven architecture

**Low Concurrency Mode** (Queueables)
- Best for: Sequential processing, debugging, testing
- Easier to troubleshoot with debug logs
- Guaranteed execution order

### Deep Observability

Every agent interaction is logged for transparency:
- User inputs and agent responses
- LLM requests and responses
- Tool executions and results
- Token usage and performance metrics
- Error tracking with full context

Query `AgentDecisionStep__c` to see exactly what your agent is thinking and doing.

---

## 🏗️ Architecture Overview

### Core Components

**Entry Points**
- `AgentExecutionService` - Main entry for starting agent executions
- `ConversationalChatController` - Lightning Web Component controller
- `AIAgentRestService` - REST API endpoint

**Orchestrators** (Agent Type Handlers)
- `ConversationalOrchestrator` - Handles chat-based agents
- `FunctionOrchestrator` - Handles single-task agents
- `WorkflowOrchestrator` - Handles multi-step workflows

**Core Services**
- `LLMInteractionService` - Manages communication with AI providers
- `OrchestrationService` - Coordinates LLM responses and tool execution
- `CapabilityExecutionService` - Executes agent actions/tools
- `AgentStateService` - Manages execution lifecycle
- `ContextManagerService` - Handles memory and context

**AI Provider Adapters**
- `OpenAIProviderAdapter` - OpenAI/Azure OpenAI integration
- `ClaudeProviderAdapter` - Anthropic Claude integration
- `GeminiProviderAdapter` - Google Gemini integration
- `BaseProviderAdapter` - Base class for custom providers

**Memory Managers**
- `BufferWindowMemoryManager` - Fixed-window conversation history
- `SummaryBufferMemoryManager` - Summarized conversation history

**Action Handlers**
- `BaseAgentAction` - Base class for all actions
- Standard actions (see list above)
- Custom actions via `IAgentAction` interface

### How It Works

1. **User sends message** → Controller receives input
2. **Orchestrator dispatches** → Async processing begins
3. **LLM processes request** → AI provider analyzes message
4. **Tools execute** → Actions perform Salesforce operations
5. **Follow-up LLM call** → AI formats results for user
6. **Response delivered** → User sees final answer

### Extension Points

Want to customize? Implement these interfaces:

- `IAgentOrchestrator` - Add new agent types
- `ILLMProviderAdapter` - Add new AI providers
- `IAgentAction` - Add custom actions/tools
- `IMemoryManager` - Add custom memory strategies
- `IAgentContextProvider` - Add custom context sources

---

## 🚀 Quick Start

### Prerequisites

- Salesforce org (Sandbox recommended)
- System Administrator access
- API key from an AI provider (OpenAI, Claude, or Gemini)

### Installation Steps

**1. Deploy the Framework**

Using Salesforce CLI:
```bash
sf project deploy start -d force-app/main/default -o your-org-alias
```

**2. Set Up AI Provider Authentication**

Navigate to Setup → Named Credentials → New

- **Label**: OpenAI API (or your provider name)
- **Name**: OpenAI_API
- **URL**: `https://api.openai.com`
- Add your API key as authentication

**3. Create LLM Configuration**

App Launcher → LLM Configurations → New

- **Developer Name**: OpenAI_GPT4o
- **Named Credential**: OpenAI_API
- **Provider Adapter Class**: OpenAIProviderAdapter
- **Default Model**: gpt-4o-mini (cost-effective) or gpt-4o (more powerful)
- **Temperature**: 0.7
- **Is Active**: ✓

**4. Create Your First Agent**

App Launcher → AI Agent Definitions → New

- **Name**: Sales Assistant
- **Developer Name**: Sales_Assistant
- **Agent Type**: Conversational
- **LLM Configuration**: OpenAI_GPT4o
- **Memory Strategy**: BufferWindow
- **History Turn Limit**: 10
- **Is Active**: ✓
- **Identity Prompt**: "You are a helpful Salesforce assistant. You help users find and manage their Salesforce data."
- **Instructions Prompt**: "Always confirm before making changes. Be clear and concise."

**5. Add Capabilities (Tools)**

Create capabilities to define what your agent can do:

**Example: Get Contact Information**

App Launcher → Agent Capabilities → New

- **Capability Name**: get_contact_info
- **Description**: "Retrieves contact information by name or email"
- **Implementation Type**: Standard
- **Standard Action Type**: GetRecords
- **AI Agent Definition**: Sales Assistant
- **Backend Configuration**:
  ```json
  {
    "objectApiName": "Contact"
  }
  ```
- **Parameters** (JSON Schema):
  ```json
  {
    "type": "object",
    "properties": {
      "firstName": {"type": "string", "description": "First name"},
      "lastName": {"type": "string", "description": "Last name"},
      "email": {"type": "string", "description": "Email address"}
    }
  }
  ```

**6. Add Chat to Your Page**

- Edit any Lightning page
- Drag **aiAssistantChat** component to the page
- Configure:
  - **Agent Developer Name**: Sales_Assistant
- Save and activate

**7. Test It!**

Start chatting with your agent:
- "Find contacts named John Smith"
- "Show me all accounts in California"
- "Create a task to follow up with Acme Corp"

---

## 📊 Configuration Guide

### Agent Configuration Fields

**Basic Settings**
- `Name` - Display name for the agent
- `DeveloperName__c` - Unique API identifier
- `AgentType__c` - Conversational, Function, or Workflow
- `IsActive__c` - Enable/disable the agent

**AI Provider Settings**
- `LLMConfiguration__c` - Which AI provider to use
- `MemoryStrategy__c` - How to manage conversation history
- `HistoryTurnLimit__c` - Number of turns to remember

**Behavior Settings**
- `IdentityPrompt__c` - Who the agent is (persona)
- `InstructionsPrompt__c` - How the agent should behave
- `EnableActionTransparency__c` - Show tool execution to users
- `ErrorHandlingPolicy__c` - Fail-Fast or Autonomous Recovery

**Performance Settings**
- `AsyncDispatchType__c` - High (Platform Events) or Low (Queueables)
- `EnableParallelToolCalling__c` - Execute multiple tools simultaneously

### Capability Configuration

**Basic Info**
- `CapabilityName__c` - Tool name (shown to AI)
- `Description__c` - When and how to use this tool
- `ImplementationType__c` - Standard, Apex, or Flow

**Execution Settings**
- `RequiresApproval__c` - Require human approval before execution
- `RunAsynchronously__c` - Execute in separate transaction
- `FailFastOnError__c` - Stop immediately on error

**Configuration**
- `BackendConfiguration__c` - Admin settings (JSON)
- `Parameters__c` - Tool parameters (JSON Schema)

---

## 🔒 Security & Permissions

### How Security Works

1. **User Context**: Agents run in the user's context
2. **CRUD Checks**: Validates object-level permissions
3. **FLS Enforcement**: Validates field-level permissions
4. **Sharing Rules**: Respects record-level access
5. **Audit Trail**: All actions logged in `AgentDecisionStep__c`

### Required Permissions

**For Admins Setting Up Agents:**
- Read/Write on `AIAgentDefinition__c`
- Read/Write on `AgentCapability__c`
- Read/Write on `LLMConfiguration__c`
- Modify All Data (for initial setup)

**For Users Using Agents:**
- Read on `AIAgentDefinition__c`
- Read/Write on `AgentExecution__c`
- Read/Write on `ExecutionStep__c`
- Permissions for objects the agent will access

### Best Practices

✓ Start with read-only capabilities
✓ Use approval workflows for data modifications
✓ Test in sandbox with realistic user profiles
✓ Review `AgentDecisionStep__c` regularly for anomalies
✓ Set appropriate `HistoryTurnLimit__c` to control costs
✓ Monitor API usage and token consumption

---

## 🛠️ Troubleshooting

### Common Issues

**Agent Not Responding**
- Check Named Credential is configured correctly
- Verify API key is valid and has credits
- Ensure agent `IsActive__c` is checked
- Check debug logs for errors

**Permission Denied Errors**
- Verify user has CRUD permissions on target objects
- Check Field-Level Security settings
- Review sharing rules
- Ensure user can access the agent definition

**High CPU Time / Timeouts**
- Reduce `HistoryTurnLimit__c`
- Use Function agents for one-shot operations
- Enable async dispatch for long-running operations
- Simplify tool descriptions

**Unexpected Tool Calls**
- Improve capability descriptions - be specific
- Add examples in the description
- Lower LLM temperature for more predictable behavior
- Review parameters JSON Schema for clarity

**Context Lost Between Turns**
- Check `MemoryStrategy__c` is set correctly
- Increase `HistoryTurnLimit__c` if needed
- Verify `ExecutionStep__c` records are being created

### Debug Tips

1. **Check Decision Steps**: Query `AgentDecisionStep__c` to see LLM interactions
2. **Review Debug Logs**: Look for errors in Apex debug logs
3. **Test Capabilities Individually**: Use Agent Storyboard to test tools
4. **Monitor Token Usage**: Check `ExecutionStep__c` for token consumption
5. **Verify Configuration**: Ensure JSON in capabilities is valid

---

## 💡 Use Cases & Examples

### Customer Support

**Scenario**: Help desk agent that can search cases, update status, and create tasks

**Agent Type**: Conversational
**Capabilities**:
- Search cases by number, contact, or subject
- Update case status and priority
- Create follow-up tasks
- Search knowledge articles

### Sales Assistance

**Scenario**: Sales copilot that helps reps find leads and opportunities

**Agent Type**: Conversational
**Capabilities**:
- Search accounts and contacts
- Find open opportunities
- Create tasks and events
- Update opportunity stages

### Case Summarization

**Scenario**: One-click case summary for quick review

**Agent Type**: Function
**Capabilities**:
- Get case details with comments
- Generate concise summary

### Lead Qualification Workflow

**Scenario**: Multi-step process to qualify and route leads

**Agent Type**: Workflow
**Steps**:
1. Classify lead (Function agent)
2. Enrich data (Function agent)
3. Score lead (Function agent)
4. Route to owner (Function agent)

--- conversations

## ⚠️ Important Notes

### Use at Your Own Risk

This framework is provided "as is" without warranties. Always test thoroughly in a sandbox environment before deploying to production.

### AI-Generated Content

⚠️ **All AI-generated responses should be verified before being relied upon.**

- LLMs can produce inaccurate or inappropriate content
- Hallucinations (false information) can occur
- Always review automated actions before execution
- Use approval workflows for critical operations

### Data & Privacy

- User inputs are sent to external AI providers
- Conversation history is stored in Salesforce
- Ensure compliance with your organization's data policies
- Review AI provider data handling policies
- Consider data residency requirements

### Cost Considerations

- AI API calls have per-token pricing
- Long conversations = higher costs
- Monitor token consumption via `ExecutionStep__c`
- Set appropriate `HistoryTurnLimit__c` to control costs

---

## 🤝 Contributing

We welcome contributions! Here's how you can help:

**Ways to Contribute**
- Report bugs with detailed reproduction steps
- Suggest features and improvements
- Submit pull requests with code or documentation
- Share your use cases and examples

**Development Guidelines**
- Follow existing code patterns
- Add test coverage for new features
- Update documentation for changes
- Test in a scratch org before submitting

---

## 📞 Support & Resources

### Getting Help

- 📖 **Documentation**: This README and inline code docs
- 🐛 **Bug Reports**: Open an issue on GitHub
- 💡 **Feature Requests**: Open an issue with [Feature Request] prefix
- 💬 **Questions**: Use GitHub Discussions

### Useful Resources

- [Salesforce Developer Documentation](https://developer.salesforce.com/docs)
- [OpenAI API Documentation](https://platform.openai.com/docs)
- [Anthropic Claude Documentation](https://docs.anthropic.com)
- [Google Gemini Documentation](https://ai.google.dev/docs)

---

## 📄 License

Copyright © 2025 Sonal

Licensed under the **Mozilla Public License 2.0** (MPL-2.0).

**Key Points:**
- ✅ Commercial use allowed
- ✅ Modification allowed
- ✅ Distribution allowed
- ⚠️ Must disclose source if distributing modifications

See the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

Built with:
- **Salesforce Platform** - Enterprise CRM
- **OpenAI GPT Models** - GPT-4o, GPT-4o-mini
- **Anthropic Claude** - Claude 3 Sonnet, Claude 3.5 Sonnet
- **Google Gemini** - Gemini 1.5 Pro, Gemini 1.5 Flash
- **Lightning Web Components** - Modern UI framework
- **Community Feedback** - Thank you to all contributors!

---

<div align="center">

**Made with 🤖 and 💡 in 2025**

*Empowering Salesforce teams to build intelligent AI experiences*

</div>
