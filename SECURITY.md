# Security

## Report a vulnerability

Do not open a public issue for a suspected vulnerability.

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability**. This opens a private advisory that only
   the maintainer sees.
3. Include the affected package and version, the steps to reproduce it, and
   what an attacker could do.

The maintainer aims to reply within 48 hours and to send a first assessment
within one week. The time to a fix depends on how severe the problem is.

## Supported versions

Security fixes target the current Pluto Core 1.0 release. Development builds
from before a release are not maintained.

## Run Pluto safely

The [Pluto docs](https://iamsonal.github.io/aiAgentStudio/) explain each of these:

1. Keep model API keys and other secrets in Named Credentials and External
   Credentials. Never put them in instructions, records, or code. See
   [Connect a model](https://iamsonal.github.io/aiAgentStudio/setup/model/).
2. Give the operator, approver, execution user, and sensitive-data permission
   sets only to the users who need them. See
   [Give people access](https://iamsonal.github.io/aiAgentStudio/setup/permissions/).
3. Require approval for tools that change records or call outside systems,
   unless an authorization policy you reviewed allows the call. See
   [Require approval](https://iamsonal.github.io/aiAgentStudio/approvals/require/).
4. Check the retention settings before you send customer data to a model
   provider. See [Retention and erasure](https://iamsonal.github.io/aiAgentStudio/data/retention/).
5. Turn on Core's recovery and retention schedules, and check Agent Core
   Health. See [Check health](https://iamsonal.github.io/aiAgentStudio/operate/health/).
6. Limit who holds Modify All Data. The trust vault keeps real values as plain
   text until retention removes them. Use Salesforce Shield Platform
   Encryption if you need encryption at rest. See
   [Sensitive data](https://iamsonal.github.io/aiAgentStudio/data/sensitive/).
7. Do not rely on tokens alone. Core turns emails, phone numbers, card
   numbers, and classified fields into tokens, but other personal data in free
   text reaches the model as written. Classify sensitive fields, return
   records as record sets, and keep each tool's Input Schema closed with
   `"additionalProperties": false`. See [Sensitive data](https://iamsonal.github.io/aiAgentStudio/data/sensitive/).
8. Never change run, command, or event records by hand. Use the supported
   actions in [Fix a stuck run](https://iamsonal.github.io/aiAgentStudio/operate/stuck-run/). In Apex, use
   `AgentRunService` to change a run and the paged `AgentTraceService` methods
   to read its history.
