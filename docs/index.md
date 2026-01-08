---
layout: default
title: Home
nav_order: 1
description: "Enterprise-Grade AI Platform for Salesforce - Build intelligent AI agents powered by Large Language Models"
permalink: /
---

<div class="hero-section">
  <img src="{{ '/assets/images/logo.png' | relative_url }}" alt="AI Agent Studio Logo" class="hero-logo">
  <h1 class="hero-title">AI Agent Studio</h1>
  <p class="hero-subtitle">Build intelligent AI agents powered by Large Language Models that seamlessly integrate with your Salesforce environment.</p>
  <div class="hero-buttons">
    <a href="#quick-start" class="btn-sf btn-primary">Get Started</a>
    <a href="https://github.com/iamsonal/aiAgentStudio" class="btn-sf btn-secondary">View on GitHub</a>
  </div>
  <div class="hero-badges">
    <a href="https://github.com/iamsonal/aiAgentStudio/stargazers"><img src="https://img.shields.io/github/stars/iamsonal/aiAgentStudio?style=social" alt="GitHub Stars"></a>
    <a href="https://github.com/iamsonal/aiAgentStudio/network/members"><img src="https://img.shields.io/github/forks/iamsonal/aiAgentStudio?style=social" alt="GitHub Forks"></a>
    <img src="https://img.shields.io/badge/Salesforce-API%20v63.0-00A1E0" alt="Salesforce API">
    <img src="https://img.shields.io/badge/License-MPL%202.0-brightgreen" alt="License">
  </div>
</div>

<div class="repo-notice">
  <div class="notice-title">📦 Repository Notice</div>
  <p>This repository contains the <strong>core AI Agent Framework only</strong>. The <code>aiAgentStudioAddons</code> folder contains proprietary extensions including additional orchestrators, LLM providers, actions, and UI components that are <strong>not part of the open-source repository</strong>.</p>
</div>

---

<div class="value-prop">
  <h2>Why AI Agent Studio?</h2>
  <ul>
    <li><strong>No Code Required</strong> — Configure AI agents with point-and-click tools</li>
    <li><strong>Enterprise Security</strong> — Automatic CRUD, FLS, sharing rules, plus PII masking and jailbreak protection</li>
    <li><strong>Multiple AI Providers</strong> — OpenAI included, extensible for Claude, Gemini, and more</li>
    <li><strong>Full Observability</strong> — Every interaction logged for transparency and debugging</li>
    <li><strong>Open Source</strong> — Free forever under MPL-2.0 license</li>
  </ul>
</div>

## Who is this for?

<div class="audience-grid">
  <div class="audience-card">
    <div class="audience-icon">⚙️</div>
    <h4>Admins</h4>
    <p>Configure AI agents without code using point-and-click tools</p>
  </div>
  <div class="audience-card">
    <div class="audience-icon">📊</div>
    <h4>Managers</h4>
    <p>Understand what AI agents can do for your team</p>
  </div>
  <div class="audience-card">
    <div class="audience-icon">💻</div>
    <h4>Developers</h4>
    <p>Extend the framework with custom actions and integrations</p>
  </div>
</div>

---

## Three Types of AI Agents

<div class="feature-grid">
  <div class="feature-card">
    <h3>💬 Conversational Agents</h3>
    <p>Interactive chat assistants with multi-turn conversations and memory. Perfect for customer support, sales assistance, and help desks. <strong>Included in core framework.</strong></p>
  </div>
  <div class="feature-card">
    <h3>⚡ Function Agents</h3>
    <p>Single-task specialists for one-shot operations like summarization, classification, or data enrichment. Fast execution with automatic pattern selection based on complexity.</p>
  </div>
  <div class="feature-card">
    <h3>🔄 Workflow Agents</h3>
    <p>Multi-agent orchestration that coordinates complex processes with multiple specialized agents. Sequential execution with state management and bulk processing support.</p>
  </div>
</div>

---

## Key Features

<div class="feature-grid">
  <div class="feature-card">
    <h3>🧠 Smart Memory</h3>
    <p>Buffer window and summary-based conversation history management</p>
  </div>
  <div class="feature-card">
    <h3>🔒 Built-in Security</h3>
    <p>Automatic CRUD, FLS, and sharing rule enforcement</p>
  </div>
  <div class="feature-card">
    <h3>🤖 Multiple AI Providers</h3>
    <p>OpenAI included, more in addons, extensible adapter pattern</p>
  </div>
  <div class="feature-card">
    <h3>🛠️ Standard Actions</h3>
    <p>Create/update records, Chatter, flows, and more</p>
  </div>
  <div class="feature-card">
    <h3>⚙️ Async Processing</h3>
    <p>Platform Events or Queueables for your needs</p>
  </div>
  <div class="feature-card">
    <h3>📊 Deep Observability</h3>
    <p>Full logging of inputs, outputs, and tool executions</p>
  </div>
  <div class="feature-card">
    <h3>🔐 PII Masking <span class="badge badge-beta">Beta</span></h3>
    <p>Automatic masking of sensitive data before sending to LLMs</p>
  </div>
  <div class="feature-card">
    <h3>🛡️ Prompt Safety <span class="badge badge-beta">Beta</span></h3>
    <p>Multi-layered jailbreak and prompt injection detection</p>
  </div>
</div>

---

## Quick Start

<div class="tldr-box">
  <div class="tldr-title">TL;DR</div>
  <p>Deploy the framework → Configure Named Credentials with your AI API key → Create an LLM Configuration → Create an Agent → Add capabilities → Drop the chat component on a page → Start chatting!</p>
</div>

<div class="callout callout-tip">
  <div class="callout-title">⏱️ Time to First Agent</div>
  <p>You can have your first AI agent running in under 30 minutes!</p>
</div>

### Prerequisites

- Salesforce org (Sandbox recommended)
- System Administrator access
- API key from an AI provider (OpenAI, Claude, or Gemini)

<div class="steps-container" markdown="1">

<div class="step-section" markdown="1">
<div class="step-number">1</div>

**Deploy the Framework**

```bash
sf project deploy start -d force-app/main/default -o your-org-alias
```

</div>

<div class="step-section" markdown="1">
<div class="step-number">2</div>

**Set Up AI Provider Authentication**

Navigate to **Setup → Named Credentials → New**

- **Label**: OpenAI API
- **URL**: `https://api.openai.com`
- Add your API key as authentication

</div>

<div class="step-section" markdown="1">
<div class="step-number">3</div>

**Create LLM Configuration**

**App Launcher → LLM Configurations → New**

- **Developer Name**: OpenAI_GPT4o
- **Named Credential**: OpenAI_API
- **Provider Adapter Class**: OpenAIProviderAdapter
- **Default Model**: gpt-4o-mini
- **Temperature**: 0.7
- **Is Active**: ✓

</div>

<div class="step-section" markdown="1">
<div class="step-number">4</div>

**Create Your First Agent**

**App Launcher → AI Agent Definitions → New**

- **Name**: Sales Assistant
- **Agent Type**: Conversational
- **LLM Configuration**: OpenAI_GPT4o
- **Memory Strategy**: BufferWindow
- **Identity Prompt**: "You are a helpful Salesforce assistant."

</div>

<div class="step-section" markdown="1">
<div class="step-number">5</div>

**Add the Chat Component**

- Edit any Lightning page
- Drag **aiAssistantChat** component to the page
- Configure with your agent's developer name
- Save and activate

</div>

<div class="step-section" markdown="1">
<div class="step-number">6</div>

**Start Chatting!**

- "Find contacts named John Smith"
- "Show me all accounts in California"
- "Create a task to follow up with Acme Corp"

</div>

</div>

<div class="callout callout-note">
  <div class="callout-title">📖 Need more details?</div>
  <p>Check out the <a href="getting-started.html">complete Getting Started guide</a> for step-by-step instructions with screenshots.</p>
</div>

---

## Standard Actions

| Action | Description |
|:-------|:------------|
| `ActionGetRecordDetails` | Retrieve and search Salesforce records |
| `ActionCreateRecord` | Create any Salesforce record |
| `ActionUpdateRecord` | Update existing records |
| `ActionPostChatter` | Post to Chatter feeds |
| `ActionFlowHandler` | Execute Salesforce Flows |

Additional actions are available in the addon package.

[View all actions →](actions.html)

---

## Security

<div class="callout callout-important">
  <div class="callout-title">🔒 Security First</div>
  <p>Agents always run in the user's context. There is no privilege escalation — agents can only access what the user can access.</p>
</div>

The framework enforces security at every level:

1. **User Context** — Agents run as the requesting user
2. **CRUD Checks** — Validates object-level permissions
3. **FLS Enforcement** — Validates field-level permissions
4. **Sharing Rules** — Respects record-level access
5. **Audit Trail** — All actions logged in `AgentDecisionStep__c`

[Learn more about security →](security.html)

---

<div class="sponsor-section">
  <h3>💖 Support This Project</h3>
  <p>AI Agent Studio is <strong>free and open-source</strong> and will always remain so.<br>If you find it useful, consider supporting ongoing development.</p>
  <div style="margin-top: 1rem;">
    <a href="https://github.com/sponsors/iamsonal" class="btn-sf btn-primary">GitHub Sponsors</a>
    <a href="https://buymeacoffee.com/iamsonal" class="btn-sf btn-secondary" style="margin-left: 0.5rem;">Buy Me a Coffee</a>
  </div>
</div>

---

## License

Licensed under the [Mozilla Public License 2.0](https://opensource.org/licenses/MPL-2.0).

- ✅ Commercial use allowed
- ✅ Modification allowed
- ✅ Distribution allowed
- ⚠️ Must disclose source if distributing modifications

<div class="related-pages">
  <h3>📚 Continue Learning</h3>
  <ul>
    <li><a href="getting-started.html">Complete Getting Started Guide</a> — Detailed walkthrough with all configuration options</li>
    <li><a href="configuration.html">Configuration Reference</a> — Deep dive into agent and capability settings</li>
    <li><a href="examples.html">Real-World Examples</a> — Customer support, sales assistant, and more</li>
    <li><a href="architecture.html">Architecture Overview</a> — Understand how the framework works</li>
  </ul>
</div>
