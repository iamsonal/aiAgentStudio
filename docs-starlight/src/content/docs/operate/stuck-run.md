---
title: Fix a stuck run
description: Find out why a run stopped, then rescue, pause, or cancel it without code.
---

A run that needs a person has status **Paused**, or stays **Waiting** longer than you expect. Its **Error Code** says why.

## Find the cause

1. Open the run. In Pluto Console, the run story shows a box at the top that says what stopped it and what to do next.
2. Read the **Error Code**. Look it up in [Pause and error codes](/reference/pause-codes/).
3. Fix the cause. For example, raise a limit on the agent or fix the execution identity.

## Act on the run

In Pluto Console, click **Operate** on the run. Each action asks for your reason and records who did it.

| Action | Use it when | What happens |
| --- | --- | --- |
| Rescue | The run is Paused and you fixed the cause. | The run continues from the step that stopped. You can add guidance for the model, such as "The customer confirmed the address. Continue." |
| Reconcile | A tool call is Unknown. | See [Settle an Unknown call](/operate/unknown/). |
| Pause | You want to stop a running run before its next step, for example to change the agent. | The run pauses. Rescue it later. |
| Cancel | The work is no longer needed, or the run cannot be rescued. | The run ends as Cancelled. A pending approval it waits for is closed. |

You need `AgentKernelOperator` or `AgentKernelAdmin`.

Without Pluto Console, use the **Rescue Agent Run**, **Reconcile Agent Tool Call**, **Pause Agent Run**, and **Cancel Agent Run** Flow actions in a screen Flow. Give each the Run ID and your reason.

## Runs only the starter can continue

A run of an agent without an Agent Execution Identity runs as the person who started it. Only that person can rescue it, or let it continue after a reconcile. An operator can still cancel it, or reconcile its Unknown call as failed with the run paused.

## Runs that cannot be rescued

A paused run whose data retention already cleared cannot be rescued. Cancel it and start a new run if the work is still needed.

## Out of budget

When a run pauses with `BUDGET_EXCEEDED`, **Operate** shows each limit as used of allowed, in red when used up. **Rescue** stays off until you raise every limit it names.

1. Open the agent and raise the limits **Operate** names.
2. Back on the run, click **Check again**, then **Rescue**.

When tool calls run out, raise Max Model Calls as well. The agent needs a model call to read each tool result.

:::danger[Never edit run records by hand]
Changing an Agent Run, Agent Command, or Agent Event record directly can break recovery. Use the actions above.
:::
