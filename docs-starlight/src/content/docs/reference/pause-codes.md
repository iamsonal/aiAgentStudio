---
title: Pause and error codes
description: The codes a run shows when it pauses or a tool call fails, and what to do for each.
---

A paused run shows its code in **Error Code**. After you fix the cause, rescue the run. See [Fix a stuck run](/operate/stuck-run/).

## Run pauses

| Code | Means | Do this |
| --- | --- | --- |
| `BUDGET_EXCEEDED` | The run used up Max Model Calls, Max Tool Calls, or Max Total Tokens. | Raise the limits **Operate** names on the agent, then rescue. |
| `MODEL_OUTPUT_TRUNCATED` | The model's answer hit Max Output Tokens. | Raise Max Output Tokens on the Agent Model, then rescue. |
| `MODEL_REFUSED` | The model refused to answer. | Read the run story. Rescue with guidance, or cancel. |
| `DISPATCH_UNDELIVERABLE` | Core tried three times, waiting longer each time, to start the next step as the execution user and could not. | Check that the execution user is active and that **Verify** passes on its identity. Make sure whoever continues runs can use the Named Credential. Then rescue. |
| `UNKNOWN_UNRESOLVED` | Nobody reconciled an Unknown call before the run's payload retention ended. | Reconcile the call, or cancel the run. See [Settle an Unknown call](/operate/unknown/). |
| `WAIT_EXPIRED` | An outside wait, or an approval set to **Pause for Operator**, ran out of time. | Rescue to let the agent continue without it, or cancel. |
| `TOOL_BINDING_CHANGED` | A tool changed or was deactivated after the call started. | Restore the tool as it was, or cancel the run and start a new one. |
| `TOOL_AUTHORIZATION_POLICY_INVALID` | The agent's policy asked for approval without naming a user or queue, with no reason, or with a deadline out of range. A tool whose Approval is Decided by Policy also pauses with this code when its agent has no policy class. | Fix the policy class, then rescue. |
| `APPROVAL_ASSIGNMENT_UNRESOLVED` | Nobody eligible could be found to approve the call. | For an Always Required tool, fix Approver Type, Approver User, or Approver Queue. For a Decided by Policy tool, fix the queue or user the policy names. Then rescue. |
| `INITIATING_USER_APPROVAL_UNSUPPORTED` | A call needed approval, but the agent has no execution identity. | Give the agent an identity, or change the policy. Then start a new run. |

## Tool call results the agent sees

These do not stop the run. The agent reads them and decides what to do next.

| Code | Means |
| --- | --- |
| `TOOL_APPROVAL_DENIED` | The approver rejected the call. The agent gets the approver's comment. |
| `TOOL_APPROVAL_EXPIRED` | Nobody decided in time, and the tool is set to **Deny and Continue**. |
| `TOOL_AUTHORIZATION_DENIED` | The agent's policy denied the call. The agent gets the policy's reason. |
| `TOOL_NOT_RUN` | Core did not run the call, for example the rest of a batch after one call failed. |
| `TOOL_BATCH_NOT_ALLOWED` | The model asked for several tools at once, but the agent allows one per turn. Core asks again. |

A tool's own errors, such as a validation rule message, also go back to the agent with the tool's code.
