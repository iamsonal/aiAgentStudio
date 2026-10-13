---
title: Approve by rule
description: Use a policy class to allow, deny, or require approval for each tool call by rule, such as by amount.
---

A policy decides call by call. For example: refunds of $25 or less run at once, refunds up to $200 go to the support queue, and larger ones go to finance.

A policy is an Apex class that a developer writes. It implements `IToolAuthorizationPolicy`. See the [extension contract](/extend/contract/).

## Turn it on

1. Ask your developer for the policy class and which tools it covers.
2. On the agent, pick the class in **Tool Authorization Policy Class**.
3. On each tool the policy covers, set **Approver Type** and leave **Always Require Approval** unchecked.

## What a policy can decide

Core asks the policy about every tool call, before it runs.

| Decision | What happens |
| --- | --- |
| Allow | The call runs, unless the tool has Always Require Approval checked. |
| Deny | The call does not run. The agent gets `TOOL_AUTHORIZATION_DENIED` with the policy's reason and continues. |
| Require Approval | The call waits for approval. The policy gives the reason, and may set a different deadline (1 minute to 7 days) or a different approver, such as a finance queue for large amounts. |

A policy can only narrow what the agent may do. It cannot skip a permission check, and it cannot approve a call.

## When a policy fails

| Error code | Cause | Fix |
| --- | --- | --- |
| `TOOL_AUTHORIZATION_POLICY_INVALID` | The policy asked for approval with no reason, or a deadline out of range. | Ask the developer to fix the class, then rescue the run. |
| `APPROVAL_ASSIGNMENT_UNRESOLVED` | Neither the policy nor the tool named anyone who may approve. | Set Approver Type on the tool, then rescue the run. |
| `INITIATING_USER_APPROVAL_UNSUPPORTED` | The policy asked for approval on an agent without an identity. | Give the agent an identity, or change the policy to allow or deny. |
