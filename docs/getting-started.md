---
layout: default
title: Getting Started
nav_order: 2
parent: Guides
---

# Getting Started
{: .no_toc }

Complete guide to deploying and configuring your first AI agent.
{: .fs-6 .fw-300 }

<div class="reading-time">10 min read</div>

<div class="tldr-box">
  <div class="tldr-title">TL;DR</div>
  <p><strong>Fastest way:</strong> Run <code>cci flow run dev_org --org dev</code> with <a href="https://cumulusci.readthedocs.io/en/stable/get-started.html">CumulusCI</a></p>
  <p><strong>Manual setup:</strong> Clone repo, deploy with SF CLI, create Named Credential, create LLM Config, create Agent, add Capabilities, add chat component, test!</p>
</div>

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Prerequisites

<div class="callout callout-tip">
  <div class="callout-title">💡 Tip</div>
  <p>We recommend starting with a Sandbox org for initial setup and testing.</p>
</div>

Before you begin, ensure you have:

- **Salesforce org** (Sandbox recommended for initial setup)
- **System Administrator access** or equivalent permissions
- **API key** from an AI provider:
  - [OpenAI](https://platform.openai.com/api-keys)
  - [Anthropic Claude](https://console.anthropic.com/)
  - [Google Gemini](https://ai.google.dev/)
- **Salesforce CLI** installed ([Installation Guide](https://developer.salesforce.com/tools/salesforcecli))

---

## Step 1: Deploy the Framework

### Option 1: CumulusCI (Recommended for Scratch Orgs)

[CumulusCI](https://cumulusci.readthedocs.io/en/stable/get-started.html) provides the fastest way to get started with a fully configured scratch org.

```bash
# Clone the repository
git clone https://github.com/iamsonal/aiAgentStudio.git
cd aiAgentStudio

# Run the dev_org flow
cci flow run dev_org --org dev
```

This single command performs all of the following:

| Step | What it does |
|:-----|:-------------|
| Deploy Framework | Deploys all Apex classes, LWCs, objects, and metadata from `force-app` |
| Deploy Seed Data | Deploys utility classes from `seed-data` folder |
| Assign Permission Sets | Assigns `AIAgentStudioConfigurator` and `AIAgentStudioEndUser` |
| Enable Knowledge | Enables Knowledge user and assigns `KnowledgeDemo` permission set |
| Create Sample Data | Runs `AgentTestDataFactory.createComprehensiveShowcase()` to create sample agents and test data |
| Setup Connected App | Configures a Connected App for API access |

After the flow completes, open your scratch org:

```bash
cci org browser dev
```

You'll have working sample agents ready to test. Explore the `seed-data` folder and `AgentTestDataFactory` class to see what gets created.

### Option 2: Salesforce CLI (Manual Setup)

For existing orgs or when you need more control over the deployment:

```bash
# Clone the repository
git clone https://github.com/iamsonal/aiAgentStudio.git
cd aiAgentStudio

# Authenticate to your org
sf org login web -a your-org-alias

# Deploy the framework
sf project deploy start -d force-app/main/default -o your-org-alias
```

---

## Step 2: Configure Named Credentials

<div class="callout callout-warning">
  <div class="callout-title">⚠️ Security Note</div>
  <p>Never commit API keys to source control. Named Credentials keep your keys secure and separate from your code.</p>
</div>

Named Credentials securely store your AI provider API keys.

### For OpenAI

1. Go to **Setup → Named Credentials → New**
2. Configure:
   - **Label**: `OpenAI API`
   - **Name**: `OpenAI_API`
   - **URL**: `https://api.openai.com`
   - **Identity Type**: Named Principal
   - **Authentication Protocol**: Custom
3. Add External Credential with your API key as a header:
   - **Header Name**: `Authorization`
   - **Header Value**: `Bearer YOUR_API_KEY`

### For Claude (Anthropic)

1. Go to **Setup → Named Credentials → New**
2. Configure:
   - **Label**: `Claude API`
   - **Name**: `Claude_API`
   - **URL**: `https://api.anthropic.com`
3. Add header:
   - **Header Name**: `x-api-key`
   - **Header Value**: `YOUR_API_KEY`

### For Gemini (Google)

1. Go to **Setup → Named Credentials → New**
2. Configure:
   - **Label**: `Gemini API`
   - **Name**: `Gemini_API`
   - **URL**: `https://generativelanguage.googleapis.com`
3. Add your API key as a query parameter or header per Google's requirements

---

## Step 3: Create LLM Configuration

LLM Configurations define how to connect to your AI provider.

1. Open **App Launcher → LLM Configurations**
2. Click **New**
3. Fill in the fields:

| Field | Value | Description |
|:------|:------|:------------|
| Developer Name | `OpenAI_GPT4o` | Unique identifier |
| Named Credential | `OpenAI_API` | Your named credential |
| Provider Adapter Class | `OpenAIProviderAdapter` | Provider-specific adapter |
| Default Model | `gpt-4o-mini` | Model to use |
| Temperature | `0.7` | Creativity (0-1) |
| Max Tokens | `4096` | Maximum response length |
| Is Active | ✓ | Enable this configuration |

### Available Provider Adapters

| Provider | Adapter Class | Models |
|:---------|:--------------|:-------|
| OpenAI | `OpenAIProviderAdapter` | gpt-4o, gpt-4o-mini |

Additional provider adapters are available in the addon package. You can also create your own by extending `BaseProviderAdapter`.

---

## Step 4: Create Your First Agent

1. Open **App Launcher → AI Agent Definitions**
2. Click **New**
3. Configure basic settings:

| Field | Value |
|:------|:------|
| Name | `Sales Assistant` |
| Developer Name | `Sales_Assistant` |
| Agent Type | `Conversational` |
| LLM Configuration | `OpenAI_GPT4o` |
| Is Active | ✓ |

4. Configure memory settings:

| Field | Value | Description |
|:------|:------|:------------|
| Memory Strategy | `BufferWindow` | How to manage history |
| History Turn Limit | `10` | Conversations to remember |

5. Configure prompts:

**Identity Prompt** (Who the agent is):
```
You are a helpful Salesforce assistant for the sales team.
You help users find accounts, contacts, and opportunities.
You are professional, concise, and always confirm before making changes.
```

**Instructions Prompt** (How to behave):
```
- Always greet users warmly
- Ask clarifying questions when requests are ambiguous
- Confirm before creating or updating records
- Provide summaries of search results
- If you can't help, explain why and suggest alternatives
```

---

## Step 5: Add Capabilities

<div class="callout callout-note">
  <div class="callout-title">📝 Note</div>
  <p>Capabilities are the "tools" your agent can use. Start with read-only capabilities and add write capabilities once you're comfortable with the framework.</p>
</div>

Capabilities define what actions your agent can perform.

### Example: Search Contacts

1. Open **App Launcher → Agent Capabilities**
2. Click **New**
3. Configure:

| Field | Value |
|:------|:------|
| Capability Name | `search_contacts` |
| Description | `Search for contacts by name, email, or account. Use this when users ask to find contact information.` |
| Implementation Type | `Standard` |
| Standard Action Type | `GetRecordDetails` |
| AI Agent Definition | `Sales Assistant` |

4. Add Backend Configuration:
```json
{
  "objectApiName": "Contact"
}
```

5. Add Parameters (JSON Schema):
```json
{
  "type": "object",
  "properties": {
    "firstName": {
      "type": "string",
      "description": "Contact's first name"
    },
    "lastName": {
      "type": "string",
      "description": "Contact's last name"
    },
    "email": {
      "type": "string",
      "description": "Contact's email address"
    },
    "accountName": {
      "type": "string",
      "description": "Name of the contact's account"
    }
  }
}
```

### Example: Create Task

| Field | Value |
|:------|:------|
| Capability Name | `create_task` |
| Description | `Create a follow-up task. Use when users want to schedule reminders or to-dos.` |
| Implementation Type | `Standard` |
| Standard Action Type | `CreateRecord` |
| Requires Approval | ✓ |

Backend Configuration:
```json
{
  "objectApiName": "Task"
}
```

Parameters:
```json
{
  "type": "object",
  "required": ["Subject"],
  "properties": {
    "Subject": {
      "type": "string",
      "description": "Task subject/title"
    },
    "Description": {
      "type": "string",
      "description": "Task details"
    },
    "ActivityDate": {
      "type": "string",
      "description": "Due date in YYYY-MM-DD format"
    },
    "Priority": {
      "type": "string",
      "enum": ["High", "Normal", "Low"],
      "description": "Task priority"
    }
  }
}
```

---

## Step 6: Add Chat Component to a Page

1. Go to **Setup → Lightning App Builder**
2. Edit an existing page or create a new one
3. Find **aiAssistantChat** in the components panel
4. Drag it onto your page
5. Configure the component:
   - **Agent Developer Name**: `Sales_Assistant`
6. **Save** and **Activate** the page

---

## Step 7: Test Your Agent

Open the page with your chat component and try these conversations:

```
You: Hi there!
Agent: Hello! I'm your Sales Assistant. How can I help you today?

You: Find contacts at Acme Corp
Agent: [Searches and returns contacts]

You: Create a task to follow up with John Smith next week
Agent: I'll create a follow-up task for John Smith. Here are the details:
       - Subject: Follow up with John Smith
       - Due Date: [next week]
       Should I proceed?

You: Yes
Agent: ✓ Task created successfully!
```

---

## Next Steps

Now that you have a working agent, explore:

- [Configuration Guide](configuration.html) - Deep dive into all settings
- [Standard Actions](actions.html) - All available built-in actions
- [Custom Actions](developer-guide.html#custom-actions) - Build your own capabilities
- [Security](security.html) - Permissions and best practices
- [Troubleshooting](troubleshooting.html) - Common issues and solutions
