---
layout: default
title: Examples
nav_order: 8
parent: Guides
---

# Use Cases & Examples
{: .no_toc }

Real-world scenarios and implementation patterns.
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Customer Support Agent

Help desk agent that searches cases, updates status, and creates tasks.

### Agent Configuration

| Setting | Value |
|:--------|:------|
| Agent Type | Conversational |
| Memory Strategy | BufferWindow |
| History Limit | 10 |

**Identity Prompt**:
```
You are a customer support assistant for the service team.
You help agents find case information, update case status, and create follow-up tasks.
Always be helpful and professional.
```

**Instructions Prompt**:
```
- Search for cases before asking users for case numbers
- Confirm before updating case status or priority
- Create tasks for any follow-up actions mentioned
- Summarize case details clearly
```

### Capabilities

**Search Cases**
```json
{
  "capabilityName": "search_cases",
  "description": "Search for support cases by number, contact, account, or subject",
  "implementationType": "Standard",
  "standardActionType": "GetRecords",
  "backendConfiguration": {
    "objectApiName": "Case",
    "defaultFields": ["CaseNumber", "Subject", "Status", "Priority", "Contact.Name", "Account.Name"]
  }
}
```

**Update Case**
```json
{
  "capabilityName": "update_case",
  "description": "Update case status, priority, or other fields",
  "implementationType": "Standard",
  "standardActionType": "UpdateRecord",
  "requiresApproval": true,
  "backendConfiguration": {
    "objectApiName": "Case"
  }
}
```

**Create Follow-up Task**
```json
{
  "capabilityName": "create_followup",
  "description": "Create a follow-up task for a case",
  "implementationType": "Standard",
  "standardActionType": "CreateRecord",
  "backendConfiguration": {
    "objectApiName": "Task",
    "defaultValues": {
      "Status": "Not Started",
      "Priority": "Normal"
    }
  }
}
```

### Sample Conversation

```
User: Find cases for Acme Corp

Agent: I found 3 open cases for Acme Corp:
       1. Case #00001234 - Login issues (High Priority)
       2. Case #00001235 - Billing question (Normal)
       3. Case #00001236 - Feature request (Low)

       Would you like details on any of these?

User: Update the billing question to high priority

Agent: I'll update Case #00001235 to High priority.
       [Approval Required]
       Confirm this change?

User: Yes

Agent: ✓ Case #00001235 priority updated to High.
```

---

## Sales Assistant

Sales copilot that helps reps find leads, opportunities, and manage their pipeline.

### Agent Configuration

| Setting | Value |
|:--------|:------|
| Agent Type | Conversational |
| Memory Strategy | SummaryBuffer |
| History Limit | 15 |

**Identity Prompt**:
```
You are a sales assistant helping account executives manage their pipeline.
You can find accounts, contacts, opportunities, and help with sales tasks.
Be proactive in suggesting next steps.
```

### Capabilities

**Search Opportunities**
```json
{
  "capabilityName": "search_opportunities",
  "description": "Find opportunities by account, stage, amount, or close date",
  "backendConfiguration": {
    "objectApiName": "Opportunity",
    "defaultFields": ["Name", "Account.Name", "Amount", "StageName", "CloseDate", "Probability"]
  }
}
```

**Search Contacts**
```json
{
  "capabilityName": "search_contacts",
  "description": "Find contacts by name, title, account, or email",
  "backendConfiguration": {
    "objectApiName": "Contact",
    "defaultFields": ["Name", "Title", "Email", "Phone", "Account.Name"]
  }
}
```

**Log Activity**
```json
{
  "capabilityName": "log_activity",
  "description": "Log a call, email, or meeting with a contact or account",
  "implementationType": "Standard",
  "standardActionType": "CreateRecord",
  "backendConfiguration": {
    "objectApiName": "Task",
    "defaultValues": {
      "Status": "Completed",
      "Type": "Call"
    }
  }
}
```

---

## Case Summarizer (Function Agent)

One-click case summary for quick review.

### Agent Configuration

| Setting | Value |
|:--------|:------|
| Agent Type | Function |
| Memory Strategy | None |

**Identity Prompt**:
```
You are a case summarization assistant.
Given case details, provide a concise summary including:
- Issue description
- Current status
- Key interactions
- Recommended next steps
```

### Capability

**Get Case Details**
```json
{
  "capabilityName": "get_case_details",
  "description": "Retrieve full case details including comments and history",
  "backendConfiguration": {
    "objectApiName": "Case",
    "defaultFields": ["CaseNumber", "Subject", "Description", "Status", "Priority",
                      "Contact.Name", "Account.Name", "CreatedDate", "LastModifiedDate"],
    "includeRelated": ["CaseComments"]
  }
}
```

### Usage

```apex
// Invoke from a button or quick action
AgentExecutionService.executeFunction('Case_Summarizer', new Map<String, Object>{
    'recordId' => caseId
});
```

---

## Lead Qualification Workflow

Multi-step process to qualify and route leads.

### Agent Configuration

| Setting | Value |
|:--------|:------|
| Agent Type | Workflow |

### Workflow Steps

**Step 1: Classify Lead**
```json
{
  "stepName": "classify",
  "agentType": "Function",
  "prompt": "Classify this lead as Hot, Warm, or Cold based on company size, industry, and engagement"
}
```

**Step 2: Enrich Data**
```json
{
  "stepName": "enrich",
  "agentType": "Function",
  "prompt": "Look up additional company information and add to lead record"
}
```

**Step 3: Score Lead**
```json
{
  "stepName": "score",
  "agentType": "Function",
  "prompt": "Calculate lead score based on classification and enrichment data"
}
```

**Step 4: Route Lead**
```json
{
  "stepName": "route",
  "agentType": "Function",
  "prompt": "Assign lead to appropriate sales rep based on territory and score"
}
```

---

## Knowledge Search Agent

Agent that searches knowledge articles to answer questions.

### Capabilities

**Search Knowledge**
```json
{
  "capabilityName": "search_knowledge",
  "description": "Search knowledge articles for answers to questions",
  "implementationType": "Standard",
  "standardActionType": "SearchKnowledge",
  "parameters": {
    "type": "object",
    "properties": {
      "searchTerm": {
        "type": "string",
        "description": "Keywords or question to search for"
      },
      "articleTypes": {
        "type": "array",
        "items": {"type": "string"},
        "description": "Types of articles to search (FAQ, How-To, etc.)"
      }
    }
  }
}
```

**Identity Prompt**:
```
You are a knowledge assistant. When users ask questions:
1. Search the knowledge base for relevant articles
2. Summarize the answer in your own words
3. Cite the article title and number
4. If no article found, say so and suggest contacting support
```

---

## Report Runner

Agent that executes reports and summarizes results.

### Capability

**Run Report**
```json
{
  "capabilityName": "run_report",
  "description": "Execute a Salesforce report and return results",
  "implementationType": "Standard",
  "standardActionType": "RunReport",
  "parameters": {
    "type": "object",
    "required": ["reportName"],
    "properties": {
      "reportName": {
        "type": "string",
        "description": "Name of the report to run"
      },
      "dateFilter": {
        "type": "string",
        "enum": ["TODAY", "THIS_WEEK", "THIS_MONTH", "THIS_QUARTER"],
        "description": "Date range filter"
      }
    }
  }
}
```

### Sample Conversation

```
User: Run the pipeline report for this quarter

Agent: Running "Q4 Pipeline Report"...

       Summary:
       - Total Pipeline: $2.4M
       - Deals in Negotiation: 12 ($890K)
       - Deals in Proposal: 8 ($650K)
       - New Opportunities: 15 ($860K)

       Top 3 Opportunities:
       1. Acme Corp - Enterprise Deal ($450K)
       2. TechStart Inc - Platform License ($280K)
       3. Global Services - Annual Renewal ($160K)
```

---

## Best Practices

### Capability Design

1. **One purpose per capability** - Don't combine search and update
2. **Clear descriptions** - Tell the AI exactly when to use it
3. **Appropriate parameters** - Only expose what's needed
4. **Enable approval** - For any data modifications

### Prompt Engineering

1. **Be specific** about the agent's role
2. **Include constraints** (what NOT to do)
3. **Provide examples** of good responses
4. **Set expectations** for tone and format

### Testing

1. **Test edge cases** - Empty results, errors, permissions
2. **Test with real users** - Different profiles and permissions
3. **Monitor decision steps** - Verify AI reasoning
4. **Iterate on prompts** - Refine based on actual usage
