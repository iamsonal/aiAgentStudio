---
layout: default
title: Troubleshooting
nav_order: 7
parent: Guides
---

# Troubleshooting
{: .no_toc }

Common issues and how to resolve them.
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Agent Not Responding

### Symptoms
- Chat shows loading indefinitely
- No response after sending message
- Timeout errors

### Solutions

**Check Named Credential**
1. Go to Setup → Named Credentials
2. Verify the credential is active
3. Test the connection

**Verify API Key**
1. Check API key is valid and not expired
2. Verify account has available credits
3. Test key directly with provider's API

**Check Agent Status**
1. Open the AI Agent Definition
2. Ensure `IsActive__c` is checked
3. Verify `LLMConfiguration__c` is set

**Review Debug Logs**
1. Enable debug logging for your user
2. Reproduce the issue
3. Check for errors in the log

---

## Permission Denied Errors

### Symptoms
- "Insufficient privileges" messages
- Agent can't access certain records
- Fields missing from responses

### Solutions

**Check Object Permissions**
```sql
-- Query to check user's object access
SELECT Id, Name, Profile.Name
FROM User
WHERE Id = :userId
```

Then verify the profile/permission set grants CRUD on target objects.

**Check Field-Level Security**
1. Go to Setup → Object Manager → [Object] → Fields
2. Click on the field
3. Check "Field-Level Security"
4. Ensure user's profile has access

**Check Sharing Rules**
1. Go to Setup → Sharing Settings
2. Review OWD for the object
3. Check sharing rules
4. Verify user has access to specific records

---

## High CPU Time / Timeouts

### Symptoms
- "CPU time limit exceeded" errors
- Slow responses
- Incomplete executions

### Solutions

**Reduce History**
- Lower `HistoryTurnLimit__c` (try 5-7)
- Switch to `SummaryBuffer` memory strategy

**Simplify Capabilities**
- Reduce number of active capabilities
- Simplify parameter schemas
- Shorten descriptions

**Use Async Processing**
- Set `AsyncDispatchType__c` to "High"
- Enable `RunAsynchronously__c` on heavy capabilities

**Optimize Queries**
- Add indexes to frequently queried fields
- Limit fields in `BackendConfiguration__c`
- Use selective filters

---

## Unexpected Tool Calls

### Symptoms
- Agent uses wrong capability
- Agent calls tools unnecessarily
- Inconsistent behavior

### Solutions

**Improve Descriptions**

<div class="code-wrong" markdown="1">

```
Gets contacts
```

</div>

Too vague - the AI won't know when to use this.

<div class="code-correct" markdown="1">

```
Search for contacts by name, email, or account.
Use when users ask to find contact information.
Do NOT use for creating contacts or searching accounts.
```

</div>

**Add Examples**
```
Examples of when to use:
- "Find John Smith's contact info"
- "Who is the contact at Acme Corp?"
- "Look up contacts with @gmail.com emails"
```

**Lower Temperature**
- Reduce `Temperature__c` in LLM Configuration
- Try 0.3-0.5 for more predictable behavior

**Review Parameters**
- Ensure JSON Schema is valid
- Add clear descriptions to each parameter
- Use enums where appropriate

---

## Context Lost Between Turns

### Symptoms
- Agent forgets previous messages
- Asks for information already provided
- Doesn't maintain conversation flow

### Solutions

**Check Memory Strategy**
1. Open AI Agent Definition
2. Verify `MemoryStrategy__c` is set
3. Try `BufferWindow` for precise context

**Increase History Limit**
- Raise `HistoryTurnLimit__c` (try 10-15)
- Balance with token costs

**Verify Execution Steps**
```sql
SELECT Id, UserMessage__c, AssistantMessage__c
FROM ExecutionStep__c
WHERE AgentExecution__c = :executionId
ORDER BY CreatedDate ASC
```

Ensure steps are being created for each turn.

---

## JSON Parse Errors

### Symptoms
- "Invalid JSON" errors
- Capability configuration failures
- Parameter validation errors

### Solutions

**Validate JSON**
Use a JSON validator to check:
- `BackendConfiguration__c`
- `Parameters__c`

**Common Issues**

<div class="code-wrong" markdown="1">

```json
{
  "field": "value",
}
```

</div>

Trailing commas are not allowed in JSON.

<div class="code-correct" markdown="1">

```json
{
  "field": "value"
}
```

</div>

<div class="code-wrong" markdown="1">

```json
{
  'field': 'value'
}
```

</div>

JSON requires double quotes, not single quotes.

<div class="code-correct" markdown="1">

```json
{
  "field": "value"
}
```

</div>

---

## Debug Tips

### 1. Check Decision Steps

Query `AgentDecisionStep__c` to see exactly what happened:

```sql
SELECT
  UserInput__c,
  LLMRequest__c,
  LLMResponse__c,
  ToolCalls__c,
  ToolResults__c,
  ErrorMessage__c
FROM AgentDecisionStep__c
WHERE AgentExecution__c = :executionId
ORDER BY CreatedDate ASC
```

### 2. Enable Debug Logging

1. Setup → Debug Logs
2. Add your user
3. Set levels:
   - Apex Code: DEBUG
   - Callout: DEBUG
   - System: DEBUG

### 3. Test Capabilities Individually

Use Developer Console or Workbench to test capabilities in isolation:

```apex
// Test a capability directly
AgentCapability__c cap = [SELECT Id FROM AgentCapability__c WHERE CapabilityName__c = 'search_contacts'];
Map<String, Object> params = new Map<String, Object>{
    'lastName' => 'Smith'
};
// Execute and check results
```

### 4. Monitor Token Usage

```sql
SELECT
  SUM(TokensUsed__c) totalTokens,
  COUNT(Id) interactions,
  AVG(TokensUsed__c) avgTokens
FROM AgentDecisionStep__c
WHERE CreatedDate = TODAY
GROUP BY AgentExecution__r.AIAgentDefinition__c
```

### 5. Check Platform Events

If using High Concurrency mode:
1. Setup → Platform Events
2. Check event delivery status
3. Review any failed deliveries

---

## Getting Help

### Before Asking for Help

Gather this information:
1. Agent configuration (type, memory, history limit)
2. Capability configuration (description, parameters)
3. Error messages (exact text)
4. Decision step data (if available)
5. Debug log excerpts (relevant sections)

### Resources

- [GitHub Issues](https://github.com/iamsonal/aiAgentStudio/issues) - Report bugs
- [GitHub Discussions](https://github.com/iamsonal/aiAgentStudio/discussions) - Ask questions
- [Salesforce Developer Forums](https://developer.salesforce.com/forums) - General Salesforce help
