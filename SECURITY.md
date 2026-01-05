# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in AI Agent Studio, please report it responsibly.

**Do NOT open a public GitHub issue for security vulnerabilities.**

Instead, please email the maintainer directly or use GitHub's private vulnerability reporting feature.

### How to Report

1. Go to the [Security tab](https://github.com/iamsonal/aiAgentStudio/security) of this repository
2. Click "Report a vulnerability"
3. Provide details about the vulnerability

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fixes (optional)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Resolution**: Depends on severity and complexity

## Security Best Practices

When using AI Agent Studio, follow these security guidelines:

1. **API Keys**: Never commit API keys to source control. Use Named Credentials.
2. **Permissions**: Follow least-privilege principles when assigning agent permissions.
3. **Approval Workflows**: Enable approval for capabilities that modify data.
4. **Audit Logs**: Regularly review `AgentDecisionStep__c` records for anomalies.
5. **Data Privacy**: Be aware that user inputs are sent to external AI providers.

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| Latest  | :white_check_mark: |

## More Information

For detailed security configuration, see the [Security Guide](https://iamsonal.github.io/aiAgentStudio/security.html) in our documentation.
