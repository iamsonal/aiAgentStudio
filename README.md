<p align="center">
  <img src="docs-starlight/public/logo.png" alt="AI Agent Studio Logo" width="150">
</p>

<h1 align="center">Salesforce AI Agent Framework</h1>

<p align="center">
  <strong>Enterprise-Grade AI Platform for Salesforce</strong>
</p>

Build intelligent AI agents powered by Large Language Models that seamlessly integrate with your Salesforce environment. Designed for security, scalability, and ease of use.

[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Salesforce](https://img.shields.io/badge/Salesforce-API%20v63.0-blue.svg)](https://developer.salesforce.com/)
[![GitHub Pages](https://img.shields.io/badge/docs-GitHub%20Pages-blue?logo=github)](https://iamsonal.github.io/aiAgentStudio/)
[![GitHub stars](https://img.shields.io/github/stars/iamsonal/aiAgentStudio?style=social)](https://github.com/iamsonal/aiAgentStudio/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/iamsonal/aiAgentStudio?style=social)](https://github.com/iamsonal/aiAgentStudio/network/members)
[![GitHub last commit](https://img.shields.io/github/last-commit/iamsonal/aiAgentStudio)](https://github.com/iamsonal/aiAgentStudio/commits/main)
[![GitHub issues](https://img.shields.io/github/issues/iamsonal/aiAgentStudio)](https://github.com/iamsonal/aiAgentStudio/issues)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect-0077B5?style=flat&logo=linkedin)](https://www.linkedin.com/in/thesonal/)
[![Sponsor](https://img.shields.io/badge/Sponsor-❤-ea4aaa?style=for-the-badge&logo=github-sponsors)](https://github.com/sponsors/iamsonal)

---

## 🎥 Watch It In Action

**[Function Agents Demo →](https://youtu.be/-y9qDDPal0U)**

See how Function Agents orchestrate Account-Based Marketing campaigns with intelligent filtering, human-in-the-loop approvals, and error recovery.

---

## �  Documentation

**[View Full Documentation →](https://iamsonal.github.io/aiAgentStudio/)**

- [Getting Started Guide](https://iamsonal.github.io/aiAgentStudio/guides/getting-started/)
- [Configuration Reference](https://iamsonal.github.io/aiAgentStudio/guides/configuration/)
- [Standard Actions](https://iamsonal.github.io/aiAgentStudio/reference/actions/)
- [Developer Guide](https://iamsonal.github.io/aiAgentStudio/guides/developer-guide/) - Custom actions & context providers
- [Security Guide](https://iamsonal.github.io/aiAgentStudio/reference/security/)
- [Troubleshooting](https://iamsonal.github.io/aiAgentStudio/guides/troubleshooting/)

---

## 💖 Support This Project

AI Agent Studio is **free and open-source**. If you find it useful, consider supporting ongoing development.

☕ **[GitHub Sponsors](https://github.com/sponsors/iamsonal)** | **[Buy Me a Coffee](https://buymeacoffee.com/iamsonal)**

---

## ⚠️ Repository Notice

This repository contains the **core AI Agent Framework only**. The `aiAgentStudioAddons` folder contains proprietary extensions not included in the open-source release.

The core framework in `force-app` provides all fundamental capabilities for building conversational AI agents with OpenAI.

---

## 🎯 What is This?

Create AI-powered assistants that can:

- 💬 **Chat naturally** with users and remember conversation context
- 🔍 **Search and retrieve** Salesforce data intelligently
- ✏️ **Create and update** records based on user requests
- 🔄 **Execute workflows** with multiple steps automatically
- 🔒 **Respect permissions** - agents only access what users can access
- 🎯 **Work with multiple AI providers** - OpenAI included, extensible for others

---

## 💼 Use Cases

### Customer Support
Deploy AI copilots that help support agents resolve cases faster by automatically searching knowledge bases, pulling customer history, and suggesting solutions - all while respecting your existing security model.

### Sales Enablement
Give sales reps an intelligent assistant that can find accounts, surface open opportunities, create follow-up tasks, and provide real-time insights during customer conversations.

### Operations Automation
Build workflow agents that handle multi-step processes like lead qualification, case routing, or approval workflows - combining multiple AI-powered decisions into automated pipelines.

### Self-Service Portals
Embed conversational agents in Experience Cloud to let customers check order status, create support cases, or find answers from your knowledge base without waiting for human agents.

---

## 🔄 How It Works

```mermaid
flowchart LR
    subgraph Input
        A[👤 User Message]
    end

    subgraph Framework
        B[🎭 Orchestrator]
        C[🧠 LLM]
        D[🔧 Tools]
    end

    subgraph Salesforce
        E[📊 Data]
        F[📝 Context]
        G[💾 Memory]
    end

    A --> B
    B --> C
    C --> D
    D --> E
    F --> B
    G --> C
    D --> H[✅ Response]
```

1. **User sends a message** through the chat component or API
2. **Context is gathered** from the current record, user profile, and related data
3. **LLM analyzes** the request with full conversation history
4. **Tools execute** Salesforce operations (query, create, update, post)
5. **Response is delivered** back to the user with full audit trail

All operations run asynchronously using Platform Events or Queueables, ensuring scalability for enterprise workloads.

---

## ✨ Key Features

| Feature | Description |
|:--------|:------------|
| **Three Agent Types** | Conversational (chat), Function (single-task), Workflow (multi-agent orchestration) |
| **Smart Memory** | Buffer window and summary-based conversation history |
| **Built-in Security** | Automatic CRUD, FLS, and sharing rule enforcement |
| **Standard Actions** | Create, update, query records, post to Chatter, execute Flows |
| **Extensible** | Custom actions, context providers, LLM adapters, memory managers |
| **Observability** | Full logging of LLM interactions, tool executions, and token usage |
| **Async Processing** | Platform Events (high concurrency) or Queueables (debugging) |

---

## 🏆 Why This Framework?

| Challenge | How We Solve It |
|:----------|:----------------|
| **Security concerns with AI** | Runs in user context with automatic CRUD/FLS enforcement. No privilege escalation. Full audit trail. |
| **Integration complexity** | Native Salesforce - no external servers, middleware, or data sync. Works with your existing org. |
| **Vendor lock-in** | Bring your own LLM. OpenAI included, easily add Claude, Gemini, or others via adapter pattern. |
| **Scalability** | Async processing handles thousands of concurrent conversations. Choose Platform Events or Queueables. |
| **Customization needs** | Extensible architecture with interfaces for custom actions, context providers, and memory strategies. |
| **Governance & compliance** | Every interaction logged to `AgentDecisionStep__c`. See exactly what the AI decided and why. |

---

## 🚀 Quick Start

### Prerequisites

- Salesforce org (Sandbox recommended)
- System Administrator access
- OpenAI API key

### Installation

**Option 1: Unlocked Package (Recommended for Quick Start)**

Install directly via package URL:

- **Sandbox & Scratch Orgs:**  
  [https://test.salesforce.com/packaging/installPackage.apexp?p0=04tgK0000009qU1QAI](https://test.salesforce.com/packaging/installPackage.apexp?p0=04tgK0000009qU1QAI)

- **Production & Developer Edition Orgs:**  
  [https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgK0000009qU1QAI](https://login.salesforce.com/packaging/installPackage.apexp?p0=04tgK0000009qU1QAI)

After installation:
- Assign permission sets: `AIAgentStudioConfigurator` (for admins), `AIAgentStudioEndUser` (for users)
- Configure your LLM provider (OpenAI, Claude, or Gemini)
- Create your first agent

**Option 2: CumulusCI (Best for Development & Testing)**

If you have [CumulusCI](https://cumulusci.readthedocs.io/en/stable/get-started.html) set up:

```bash
cci flow run dev_org --org dev
```

This single command:
- Creates a scratch org with the framework deployed
- Deploys seed data and sample configurations
- Assigns required permission sets (`AIAgentStudioConfigurator`, `AIAgentStudioEndUser`)
- Enables Knowledge user and assigns `KnowledgeDemo` permission set
- Creates comprehensive sample data (agents, capabilities, test records)
- Sets up a Connected App for API access

**Option 3: Salesforce CLI (Source-Based)**

```bash
sf project deploy start -d force-app/main/default -o your-org-alias
```

### Optional: Load Test Data

If you need sample data to explore the framework (especially with Option 1 or 3):

1. **Deploy the test data factory** from the `seed-data` folder:
   ```bash
   sf project deploy start -d seed-data/main/default -o your-org-alias
   ```

2. **Execute in Developer Console** (or via Anonymous Apex):
   ```apex
   AgentTestDataFactory.createComprehensiveShowcase();
   ```

This creates sample agents, capabilities, accounts, contacts, and test scenarios to help you get started quickly.

### Configure OpenAI API Key

The framework includes pre-configured OpenAI named credentials. You just need to add your API key:

1. Navigate to **Setup** → **Named Credentials** → **External Credentials**
2. Find and open **OpenAIEC**
3. Under **Principals**, click **Edit** on the principal
4. In the **Authentication Parameters** section, add:
   - **Parameter**: `OpenAIKey`
   - **Value**: Your OpenAI API key (starts with `sk-`)
5. Click **Save**

The `OpenAILLM` named credential is now ready to use with the framework.

> **Note**: If you're using Claude or Gemini, similar external credentials may be included. Check the [Configuration Guide](https://iamsonal.github.io/aiAgentStudio/guides/configuration/) for details on other LLM providers.

### Setup

Once your API key is configured:

1. **Create or use existing LLM Configuration** (references the `OpenAILLM` named credential)
2. **Create AI Agent Definition** with identity/instruction prompts
3. **Add Capabilities** (tools) the agent can use
4. **Add Chat Component** to a Lightning page or use Quick Actions

👉 **[Full Getting Started Guide →](https://iamsonal.github.io/aiAgentStudio/guides/getting-started/)**

---

## 🏗️ Architecture

**Core Components:**
- `AgentExecutionService` - Main entry point for starting agent executions
- `ConversationalOrchestrator` - Manages multi-turn chat conversations
- `FunctionOrchestrator` - Handles single-task function agents
- `WorkflowOrchestrator` - Coordinates multi-agent workflows
- `LLMInteractionService` - Handles communication with AI providers
- `CapabilityExecutionService` - Executes tools/actions securely
- `OpenAIProviderAdapter` - OpenAI/Azure OpenAI integration
- `ClaudeProviderAdapter` - Anthropic Claude integration
- `GeminiProviderAdapter` - Google Gemini integration

**Extension Points:**
- `IAgentAction` - Build custom actions for any business logic
- `IAgentContextProvider` - Supply dynamic context to agents
- `ILLMProviderAdapter` - Add support for additional AI providers
- `IMemoryManager` - Implement custom conversation memory strategies
- `IAgentOrchestrator` - Create new agent types

👉 **[Architecture Details →](https://iamsonal.github.io/aiAgentStudio/reference/architecture/)** | **[Developer Guide →](https://iamsonal.github.io/aiAgentStudio/guides/developer-guide/)**

---

## ⚠️ Important Notes

- **Use at your own risk** - Test thoroughly in sandbox before production
- **AI content verification** - LLMs can hallucinate; review automated actions
- **Data privacy** - User inputs are sent to external AI providers
- **Cost awareness** - Monitor token consumption; set appropriate history limits

---

## 📄 License

Copyright © 2025 Sonal

Licensed under **[Mozilla Public License 2.0](LICENSE)** (MPL-2.0)

✅ Commercial use | ✅ Modification | ✅ Distribution | ⚠️ Disclose source for modifications

---

<div align="center">

**Made with 🤖 and 💡 in 2025**

*Empowering Salesforce teams to build intelligent AI experiences*

</div>
