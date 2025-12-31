---
layout: default
title: Security
nav_order: 6
parent: Reference
---

# Security Guide
{: .no_toc }

Understanding and configuring security for AI agents.
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## Security Model

The framework enforces security at multiple levels:

```
┌─────────────────────────────────────────────────────────┐
│                    User Request                          │
└─────────────────────────┬───────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              1. User Context Validation                  │
│         (Agent runs as the requesting user)              │
└─────────────────────────┬───────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              2. Object-Level Security                    │
│              (CRUD permission checks)                    │
└─────────────────────────┬───────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              3. Field-Level Security                     │
│              (FLS enforcement)                           │
└─────────────────────────┬───────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              4. Record-Level Security                    │
│              (Sharing rules)                             │
└─────────────────────────┬───────────────────────────────┘
                          ▼
┌─────────────────────────────────────────────────────────┐
│              5. Audit Trail                              │
│              (All actions logged)                        │
└─────────────────────────────────────────────────────────┘
```

---

## Permission Enforcement

### User Context

Agents always run in the context of the requesting user. There is no privilege escalation.

```apex
// The framework automatically uses the current user's context
// No "without sharing" or "system mode" execution
```

### CRUD Checks

Before any data operation, the framework validates:

- **Create**: User can create records of this type
- **Read**: User can read records of this type
- **Update**: User can update records of this type
- **Delete**: User can delete records of this type

### Field-Level Security

The framework respects FLS:

- Fields the user cannot read are excluded from queries
- Fields the user cannot edit are rejected in create/update operations
- Hidden fields are never exposed to the AI or user

### Sharing Rules

All queries respect:

- Organization-wide defaults
- Role hierarchy
- Sharing rules
- Manual shares
- Team/territory sharing

---

## Required Permissions

### For Administrators

Admins who configure agents need:

| Object | Permissions |
|:-------|:------------|
| `AIAgentDefinition__c` | Read, Create, Edit, Delete |
| `AgentCapability__c` | Read, Create, Edit, Delete |
| `LLMConfiguration__c` | Read, Create, Edit, Delete |
| Named Credentials | View, Manage |

### For End Users

Users who interact with agents need:

| Object | Permissions |
|:-------|:------------|
| `AIAgentDefinition__c` | Read |
| `AgentExecution__c` | Read, Create, Edit |
| `ExecutionStep__c` | Read, Create |
| Target objects | Appropriate CRUD for agent capabilities |

### Permission Set Example

Create a permission set for agent users:

```
Permission Set: AI Agent User
├── Object Permissions
│   ├── AIAgentDefinition__c: Read
│   ├── AgentExecution__c: Read, Create, Edit
│   ├── ExecutionStep__c: Read, Create
│   └── AgentDecisionStep__c: Read
└── Field Permissions
    └── (All fields on above objects): Read, Edit
```

---

## Approval Workflows

For sensitive operations, enable approval on capabilities:

### Configuration

Set `RequiresApproval__c = true` on the capability.

### User Experience

1. User requests action (e.g., "Delete this account")
2. Agent prepares the action but pauses
3. User sees approval prompt with details
4. User approves or rejects
5. Action executes only if approved

### Best Practices

Enable approval for:
- Record deletion
- Bulk updates
- Email sending
- External integrations
- Financial data modifications

---

## Audit Trail

### What's Logged

Every agent interaction creates records in `AgentDecisionStep__c`:

| Field | Description |
|:------|:------------|
| `UserInput__c` | Original user message |
| `LLMRequest__c` | Full request sent to AI |
| `LLMResponse__c` | Full response from AI |
| `ToolCalls__c` | Tools the AI decided to use |
| `ToolResults__c` | Results from tool execution |
| `ExecutingUser__c` | User who made the request |
| `Timestamp__c` | When the action occurred |

### Querying Audit Data

```sql
-- Find all actions by a specific user
SELECT Id, UserInput__c, ToolCalls__c, CreatedDate
FROM AgentDecisionStep__c
WHERE ExecutingUser__c = :userId
ORDER BY CreatedDate DESC

-- Find all data modifications
SELECT Id, UserInput__c, ToolCalls__c, ToolResults__c
FROM AgentDecisionStep__c
WHERE ToolCalls__c LIKE '%CreateRecord%'
   OR ToolCalls__c LIKE '%UpdateRecord%'
   OR ToolCalls__c LIKE '%DeleteRecord%'
```

### Retention

Consider your data retention policies:
- Decision steps can accumulate quickly
- Implement archival or deletion jobs as needed
- Balance audit needs with storage costs

---

## Data Privacy

### External AI Providers

User inputs are sent to external AI providers. Consider:

| Concern | Mitigation |
|:--------|:-----------|
| Data residency | Choose providers with appropriate regions |
| Data retention | Review provider data handling policies |
| PII exposure | Implement input sanitization if needed |
| Compliance | Ensure provider meets your requirements |

### Provider Data Policies

- [OpenAI Data Usage Policy](https://openai.com/policies/api-data-usage-policies)
- [Anthropic Privacy Policy](https://www.anthropic.com/privacy)
- [Google AI Data Governance](https://ai.google.dev/docs/safety_guidance)

### Recommendations

1. **Review policies** before enabling in production
2. **Inform users** that data is sent to external services
3. **Avoid PII** in agent conversations when possible
4. **Consider Azure OpenAI** for enterprise data residency needs

---

## Best Practices

### Configuration

✅ **Do**:
- Start with read-only capabilities
- Enable approval for write operations
- Test with realistic user profiles
- Review audit logs regularly
- Use specific object configurations

❌ **Don't**:
- Grant Modify All Data to agent users
- Skip approval for delete operations
- Expose sensitive fields unnecessarily
- Ignore audit trail data

### Monitoring

Set up monitoring for:
- Unusual query patterns
- High-volume tool executions
- Failed permission checks
- Error rates

### Incident Response

If you suspect misuse:
1. Disable the agent (`IsActive__c = false`)
2. Review `AgentDecisionStep__c` records
3. Check Salesforce audit trail
4. Investigate user activity
5. Implement additional controls as needed

---

## Compliance Considerations

### GDPR

- User data is processed by external AI providers
- Implement data subject access requests
- Consider right to deletion for conversation history

### HIPAA

- Avoid PHI in agent conversations
- Use BAA-covered AI providers if needed
- Implement additional access controls

### SOC 2

- Audit trail supports compliance requirements
- Access controls align with least privilege
- Monitoring capabilities support detection
