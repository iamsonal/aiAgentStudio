# ActionSendEmail Usage Examples

The `ActionSendEmail` action provides comprehensive email sending capabilities within the AI Agent Framework. This document provides detailed examples of how to configure and use this action.

## Basic Configuration

### 1. Create Agent Capability

```json
{
  "CapabilityName__c": "send_email",
  "DisplayName__c": "Send Email",
  "ImplementationType__c": "Standard",
  "StandardActionType__c": "SendEmail",
  "Parameters__c": "{\"type\":\"object\",\"properties\":{\"toAddresses\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"format\":\"email\"},\"minItems\":1},\"subject\":{\"type\":\"string\",\"minLength\":1},\"body\":{\"type\":\"string\"},\"ccAddresses\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"format\":\"email\"}},\"bccAddresses\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"format\":\"email\"}},\"htmlBody\":{\"type\":\"string\"},\"plainTextBody\":{\"type\":\"string\"},\"templateId\":{\"type\":\"string\"},\"fromName\":{\"type\":\"string\"},\"replyTo\":{\"type\":\"string\",\"format\":\"email\"},\"attachments\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"fileName\":{\"type\":\"string\"},\"contentType\":{\"type\":\"string\"},\"body\":{\"type\":\"string\"}}}}},\"required\":[\"toAddresses\",\"subject\"]}"
}
```

### 2. Action Configuration (Optional)

```json
{
  "defaultFromName": "AI Assistant",
  "defaultReplyTo": "noreply@company.com",
  "maxRecipients": 100,
  "maxAttachments": 10,
  "requireApproval": false
}
```

## Usage Examples

### 1. Basic Email

```json
{
  "toAddresses": ["user@example.com"],
  "subject": "Welcome to our service",
  "body": "Thank you for signing up! We're excited to have you on board."
}
```

### 2. HTML Email with CC and BCC

```json
{
  "toAddresses": ["primary@example.com"],
  "ccAddresses": ["manager@example.com"],
  "bccAddresses": ["archive@example.com"],
  "subject": "Project Update",
  "htmlBody": "<h1>Project Status</h1><p>Here's the latest update on our project.</p>",
  "plainTextBody": "Project Status - Here's the latest update on our project.",
  "fromName": "Project Manager",
  "replyTo": "project@company.com"
}
```

### 3. Email with Attachments

```json
{
  "toAddresses": ["client@example.com"],
  "subject": "Monthly Report",
  "body": "Please find the monthly report attached.",
  "attachments": [
    {
      "fileName": "monthly_report.pdf",
      "contentType": "application/pdf",
      "body": "base64EncodedPdfContent"
    },
    {
      "fileName": "summary.xlsx",
      "contentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "body": "base64EncodedExcelContent"
    }
  ]
}
```

### 4. Template Email

```json
{
  "toAddresses": ["customer@example.com"],
  "subject": "Order Confirmation",
  "templateId": "00X000000000000",
  "whatId": "a01000000000001AAA",
  "targetObjectId": "a02000000000001AAA",
  "saveAsActivity": true
}
```

### 5. Email with All Options

```json
{
  "toAddresses": ["recipient@example.com"],
  "ccAddresses": ["cc1@example.com", "cc2@example.com"],
  "bccAddresses": ["bcc@example.com"],
  "subject": "Complete Email Example",
  "htmlBody": "<h1>HTML Content</h1><p>This is the HTML version.</p>",
  "plainTextBody": "Plain text version of the email.",
  "fromName": "Custom Sender",
  "replyTo": "custom-reply@company.com",
  "whatId": "a01000000000001AAA",
  "targetObjectId": "a02000000000001AAA",
  "saveAsActivity": true,
  "useSignature": true,
  "treatBodiesAsTemplate": false,
  "attachments": [
    {
      "fileName": "document.pdf",
      "contentType": "application/pdf",
      "body": "base64EncodedContent"
    }
  ]
}
```

## Parameter Reference

### Required Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `toAddresses` | `List<String>` | Primary email recipients (at least one required) |
| `subject` | `String` | Email subject line |

### Optional Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `ccAddresses` | `List<String>` | CC recipients |
| `bccAddresses` | `List<String>` | BCC recipients |
| `body` | `String` | Plain text email body (at least one body type required) |
| `htmlBody` | `String` | HTML email body |
| `plainTextBody` | `String` | Plain text email body (alternative to `body`) |
| `fromName` | `String` | Display name for sender |
| `replyTo` | `String` | Reply-to email address |
| `templateId` | `String` | Salesforce email template ID |
| `whatId` | `String` | Related record ID for template context (must be supported as task whatId: Contact, Lead, Opportunity, etc.) |
| `targetObjectId` | `String` | Target object ID for template context |
| `saveAsActivity` | `Boolean` | Whether to save as activity on related record (must be false when sending to users) |
| `attachments` | `List<Map>` | Email attachments |
| `useSignature` | `Boolean` | Whether to include user signature |
| `treatBodiesAsTemplate` | `Boolean` | Whether to treat body content as template |

### Attachment Structure

```json
{
  "fileName": "document.pdf",
  "contentType": "application/pdf",
  "body": "base64EncodedContent"
}
```

## Configuration Options

### Default Values

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `defaultFromName` | `String` | null | Default sender display name |
| `defaultReplyTo` | `String` | null | Default reply-to address |
| `maxRecipients` | `Integer` | 100 | Maximum total recipients |
| `maxAttachments` | `Integer` | 10 | Maximum attachments |
| `requireApproval` | `Boolean` | false | Whether to require approval before sending |

## Error Handling

The action provides comprehensive error handling for various scenarios:

- **Validation Errors**: Missing required parameters, invalid email formats, too many recipients/attachments
- **Permission Errors**: Insufficient permissions to send emails
- **Configuration Errors**: Invalid template IDs, missing configuration
- **System Errors**: Salesforce platform limits, unexpected errors

## Security Considerations

1. **Email Address Validation**: All email addresses are validated for proper format
2. **Recipient Limits**: Configurable limits prevent abuse
3. **Attachment Limits**: Configurable limits on attachment count and size
4. **Permission Checks**: Validates organization email settings and user permissions
5. **Approval Workflow**: Optional approval requirement for sensitive emails
6. **Salesforce Limits**: Respects Salesforce daily email limits and governor limits

## Best Practices

1. **Use HTML and Plain Text**: Provide both HTML and plain text versions for better compatibility
2. **Validate Attachments**: Ensure attachments are properly encoded and within size limits
3. **Set Appropriate Limits**: Configure reasonable limits for recipients and attachments
4. **Use Templates**: Leverage Salesforce email templates for consistent formatting
5. **Test Thoroughly**: Test with various email clients and configurations
6. **Monitor Usage**: Track email sending patterns and adjust limits as needed
7. **Handle saveAsActivity Correctly**: Set `saveAsActivity=false` when sending to users, `true` for Contacts/Leads
8. **Use Valid whatId Values**: Only use Contact, Lead, Opportunity, or other task-supported objects as `whatId`

## Integration with AI Agents

The ActionSendEmail integrates seamlessly with AI agents:

1. **Natural Language Processing**: Agents can generate email content from user requests
2. **Context Awareness**: Use related record IDs for personalized emails
3. **Dynamic Content**: Generate email content based on data and user preferences
4. **Approval Workflows**: Integrate with human approval processes when needed
5. **Audit Trail**: Complete logging and tracking of email activities

## Example Agent Capability Configuration

```json
{
  "CapabilityName__c": "send_welcome_email",
  "DisplayName__c": "Send Welcome Email",
  "Description__c": "Sends a personalized welcome email to new users",
  "ImplementationType__c": "Standard",
  "StandardActionType__c": "SendEmail",
  "Parameters__c": "{\"type\":\"object\",\"properties\":{\"toAddresses\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"format\":\"email\"},\"minItems\":1},\"subject\":{\"type\":\"string\",\"minLength\":1},\"htmlBody\":{\"type\":\"string\"},\"plainTextBody\":{\"type\":\"string\"},\"fromName\":{\"type\":\"string\"}},\"required\":[\"toAddresses\",\"subject\",\"htmlBody\",\"plainTextBody\"]}",
  "ActionConfiguration__c": "{\"defaultFromName\":\"Welcome Team\",\"defaultReplyTo\":\"welcome@company.com\",\"maxRecipients\":50}"
}
```

This configuration creates a specialized email capability for sending welcome emails with predefined defaults and validation rules.
