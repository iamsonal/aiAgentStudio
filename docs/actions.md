---
layout: default
title: Standard Actions
nav_order: 4
parent: Reference
---

# Standard Actions
{: .no_toc }

Built-in actions that agents can perform out of the box.
{: .fs-6 .fw-300 }

## Table of contents
{: .no_toc .text-delta }

1. TOC
{:toc}

---

## ActionGetRecordDetails

Retrieve and search Salesforce records.

**Standard Action Type**: `GetRecordDetails`

**Backend Configuration**:
```json
{
  "objectApiName": "Contact",
  "defaultFields": ["Id", "Name", "Email", "Phone"],
  "defaultLimit": 25
}
```

**Parameters Schema**:
```json
{
  "type": "object",
  "properties": {
    "searchTerm": {
      "type": "string",
      "description": "Text to search for"
    },
    "filters": {
      "type": "object",
      "description": "Field-value pairs to filter by"
    }
  }
}
```

---

### ActionCreateRecord

Create any Salesforce record.

**Standard Action Type**: `CreateRecord`

**Backend Configuration**:
```json
{
  "objectApiName": "Task",
  "defaultValues": {
    "Status": "Not Started"
  }
}
```

**Parameters Schema**:
```json
{
  "type": "object",
  "required": ["Subject"],
  "properties": {
    "Subject": {
      "type": "string",
      "description": "Task subject"
    },
    "Description": {
      "type": "string",
      "description": "Task description"
    },
    "ActivityDate": {
      "type": "string",
      "description": "Due date (YYYY-MM-DD)"
    }
  }
}
```

---

### ActionUpdateRecord

Update existing Salesforce records.

**Standard Action Type**: `UpdateRecord`

**Backend Configuration**:
```json
{
  "objectApiName": "Case"
}
```

**Parameters Schema**:
```json
{
  "type": "object",
  "required": ["recordId"],
  "properties": {
    "recordId": {
      "type": "string",
      "description": "ID of the record to update"
    },
    "Status": {
      "type": "string",
      "description": "New status value"
    },
    "Priority": {
      "type": "string",
      "enum": ["High", "Medium", "Low"]
    }
  }
}
```

---

### ActionPostChatter

Post messages to Chatter feeds.

**Standard Action Type**: `PostChatter`

**Parameters Schema**:
```json
{
  "type": "object",
  "required": ["message"],
  "properties": {
    "message": {
      "type": "string",
      "description": "Message to post"
    },
    "recordId": {
      "type": "string",
      "description": "Record to post to (optional, defaults to user feed)"
    },
    "mentionUserIds": {
      "type": "array",
      "items": {"type": "string"},
      "description": "User IDs to @mention"
    }
  }
}
```

---

### ActionFlowHandler

Execute Salesforce Flows.

**Standard Action Type**: `FlowHandler`

**Configuration**: Set `ImplementationDetail__c` to the Flow API name.

**Backend Configuration** (optional default input values):
```json
{
  "defaultInputValues": {
    "source": "AI_Agent"
  }
}
```

**Parameters Schema**:
```json
{
  "type": "object",
  "properties": {
    "recordId": {
      "type": "string",
      "description": "Record ID to pass to flow"
    },
    "inputVariables": {
      "type": "object",
      "description": "Additional flow input variables"
    }
  }
}
```

---

## Best Practices

### Choosing the Right Action

| Need | Action |
|:-----|:-------|
| Find records | `ActionGetRecordDetails` |
| Create a record | `ActionCreateRecord` |
| Update a record | `ActionUpdateRecord` |
| Post to Chatter | `ActionPostChatter` |
| Run automation | `ActionFlowHandler` |

Additional actions for notifications, reports, and knowledge search are available in the addon package.

### Security Recommendations

1. **Enable approval** for create/update actions in production
2. **Limit fields** in backend configuration to only what's needed
3. **Use specific object types** rather than generic configurations
4. **Test with realistic user profiles** to verify permissions
