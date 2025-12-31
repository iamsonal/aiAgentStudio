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

## Data Operations

### ActionGetRecordDetails

Retrieve and search Salesforce records.

**Standard Action Type**: `GetRecords`

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

## Communication

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

### ActionSendEmail

Send emails from Salesforce.

**Standard Action Type**: `SendEmail`

**Parameters Schema**:
```json
{
  "type": "object",
  "required": ["toAddress", "subject", "body"],
  "properties": {
    "toAddress": {
      "type": "string",
      "description": "Recipient email address"
    },
    "subject": {
      "type": "string",
      "description": "Email subject"
    },
    "body": {
      "type": "string",
      "description": "Email body (plain text or HTML)"
    },
    "isHtml": {
      "type": "boolean",
      "description": "Whether body is HTML"
    }
  }
}
```

---

### ActionSendNotification

Send custom notifications to users.

**Standard Action Type**: `SendNotification`

**Backend Configuration**:
```json
{
  "notificationTypeApiName": "Custom_Alert"
}
```

**Parameters Schema**:
```json
{
  "type": "object",
  "required": ["title", "body", "targetId"],
  "properties": {
    "title": {
      "type": "string",
      "description": "Notification title"
    },
    "body": {
      "type": "string",
      "description": "Notification message"
    },
    "targetId": {
      "type": "string",
      "description": "Record ID to link to"
    },
    "recipientIds": {
      "type": "array",
      "items": {"type": "string"},
      "description": "User IDs to notify"
    }
  }
}
```

---

## Automation

### ActionFlowHandler

Execute Salesforce Flows.

**Standard Action Type**: `RunFlow`

**Backend Configuration**:
```json
{
  "flowApiName": "Lead_Assignment_Flow"
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

### ActionManageTasks

Create and manage tasks with advanced options.

**Standard Action Type**: `ManageTasks`

**Parameters Schema**:
```json
{
  "type": "object",
  "required": ["action"],
  "properties": {
    "action": {
      "type": "string",
      "enum": ["create", "update", "complete", "reassign"],
      "description": "Task action to perform"
    },
    "taskId": {
      "type": "string",
      "description": "Task ID (for update/complete/reassign)"
    },
    "subject": {
      "type": "string",
      "description": "Task subject (for create)"
    },
    "assigneeId": {
      "type": "string",
      "description": "User ID to assign task to"
    }
  }
}
```

---

### ActionRunReport

Execute Salesforce reports and retrieve results.

**Standard Action Type**: `RunReport`

**Parameters Schema**:
```json
{
  "type": "object",
  "required": ["reportId"],
  "properties": {
    "reportId": {
      "type": "string",
      "description": "Report ID to execute"
    },
    "filters": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "column": {"type": "string"},
          "operator": {"type": "string"},
          "value": {"type": "string"}
        }
      },
      "description": "Runtime filter overrides"
    }
  }
}
```

---

## Knowledge & Search

### ActionSearchKnowledge

Search knowledge articles.

**Standard Action Type**: `SearchKnowledge`

**Parameters Schema**:
```json
{
  "type": "object",
  "required": ["searchTerm"],
  "properties": {
    "searchTerm": {
      "type": "string",
      "description": "Text to search for in articles"
    },
    "articleTypes": {
      "type": "array",
      "items": {"type": "string"},
      "description": "Article types to search"
    },
    "language": {
      "type": "string",
      "description": "Article language (e.g., 'en_US')"
    },
    "limit": {
      "type": "integer",
      "description": "Maximum articles to return"
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
| Send email | `ActionSendEmail` |
| Run automation | `ActionFlowHandler` |
| Search articles | `ActionSearchKnowledge` |

### Security Recommendations

1. **Enable approval** for create/update actions in production
2. **Limit fields** in backend configuration to only what's needed
3. **Use specific object types** rather than generic configurations
4. **Test with realistic user profiles** to verify permissions
