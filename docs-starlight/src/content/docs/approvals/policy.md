---
title: Approve by rule
description: Use a policy class to allow, deny, or require approval for each tool call by rule, such as by amount.
---

A policy decides call by call. For example: refunds of $25 or less run at once, refunds up to $200 go to the support queue, and larger ones go to finance.

A policy is an Apex class that a developer writes. It implements `IToolAuthorizationPolicy`. See the [extension contract](/extend/contract/).

## Turn it on

1. Ask your developer for the policy class, which tools it covers, and which queues or users it names.
2. Check that each queue the policy names exists and lists Agent Approval under **Supported Objects**.
3. On the agent, pick the class in **Tool Authorization Policy Class**.
4. On each tool the policy covers, set **Approval** to **Decided by Policy**. Leave Approver Type, Approver User, and Approver Queue blank. The policy names the approver.
5. On each of those tools, choose **When Approval Expires**. Optionally set **Approval Timeout (Minutes)** for calls where the policy gives no deadline.

The tool page saves without an error when the setup is valid. It refuses a Decided by Policy tool on an agent with no policy class. It also refuses clearing the policy class while the agent has an active Decided by Policy tool, and names those tools.

## Who decides

Core asks the policy only about tools whose Approval is Decided by Policy. Tools set to Not Required or Always Required never reach it.

| Policy answer | What happens |
| --- | --- |
| Allow | The call runs. |
| Deny | The call does not run. The agent gets `TOOL_AUTHORIZATION_DENIED` with the policy's reason and continues. |
| Require Approval | The call waits for the user or queue the policy names. The policy must name one. The deadline is the policy's, then the tool's Approval Timeout, then 1440 minutes (24 hours). |

A deadline from the policy replaces the tool's Approval Timeout, so a large refund can get a shorter deadline than a small one. When Approval Expires on the tool applies to every call.

Core runs the policy again before an approved call runs. A deny still stops the call. Any other answer lets the approved call run, so a call never waits for a second approval.

A policy can only narrow what the agent may do. It cannot skip a permission check or approve a call.

Core's configuration check, `AgentConfigurationValidationService.validate`, returns the warning `POLICY_NEVER_RUNS` when the agent has a policy class but no active tool whose Approval is Decided by Policy.

## See why a call waited

Open the run's **Run Waiting** event. Its `requiredBy` key is `Tool Setting` for an Always Required tool, or `Policy` for a Decided by Policy tool.

## When a policy fails

| Error code | Cause | Fix |
| --- | --- | --- |
| `TOOL_AUTHORIZATION_POLICY_INVALID` | The policy asked for approval without naming a user or queue, with no reason, or with a deadline out of range. It may also have named a user Id that is not a user. | Ask the developer to fix the class, then rescue the run. |
| `APPROVAL_ASSIGNMENT_UNRESOLVED` | The queue the policy named does not exist or does not support Agent Approval, or the user it named cannot decide approvals. The error names the queue or user. | Create the queue, add Agent Approval to its **Supported Objects**, or give the user `AgentKernelHumanDecision`. Then rescue the run. |
| `INITIATING_USER_APPROVAL_UNSUPPORTED` | The policy asked for approval on an agent without an identity. | Give the agent an identity, or change the policy to allow or deny. |
