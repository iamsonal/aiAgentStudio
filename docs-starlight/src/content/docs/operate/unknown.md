---
title: Settle an Unknown call
description: What to do when Core cannot tell whether a tool changed something outside Salesforce.
---

A tool call is **Unknown** when it may have changed something outside Salesforce, but Core cannot prove whether it did. For example, a payment API timed out after the request was sent. The refund may or may not exist.

Core never repeats an Unknown call by itself, because repeating it could do the work twice. It waits for a person to check.

## Settle it

1. Open the run in Pluto Console. Find the call marked Unknown and note its **operation key**.
2. In the outside system, check whether the call changed anything. If the system supports idempotency keys, search for the operation key.
3. Click **Operate**, then **Reconcile**, and choose:

| What you found | Choose | What happens |
| --- | --- | --- |
| It changed something | Succeeded. Enter what you found, such as the refund Id. | The agent gets your result and continues. The call is not repeated. |
| It changed nothing | Failed. Enter what went wrong. | The agent is told the call failed and continues. Or check **Pause Run** to keep the run paused. |
| It changed nothing, and sending it again cannot do the work twice | Retry, with **Safe to Retry** checked | Core sends the call again with the same operation key. |

You need `AgentKernelOperator` or `AgentKernelAdmin`. The run's own execution user can never reconcile it.

## When nobody settles it

An Unknown call waits until the run's payload retention ends, 30 days by default. Then recovery pauses the run with `UNKNOWN_UNRESOLVED`. The call is still not repeated. You can still reconcile it, or cancel the run. After retention clears the run's data, you can only cancel it.

## Fewer Unknown calls

- Use a tool type with the right Effects. Only **Changes Outside Systems** tools can end as Unknown. See [Effects](/build/tools/#effects).
- Ask the outside system to treat the operation key as an idempotency key. A developer can then mark the tool as safe to retry.
