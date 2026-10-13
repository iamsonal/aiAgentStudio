---
title: Limits and cost
description: What a run costs in jobs, API calls, and model use, and how many runs an org can handle.
---

## Per-run budgets

Each agent limits its runs. The defaults:

| Limit | Default | When it is reached |
| --- | --- | --- |
| Max Model Calls | 10 | The run pauses with `BUDGET_EXCEEDED`. |
| Max Tool Calls | 15 | The run pauses with `BUDGET_EXCEEDED`. |
| Max Total Tokens | 250,000 | Checked before each model call. The run pauses with `BUDGET_EXCEEDED`. |

They count the whole run. For an agent with **Wait for Reply**, they count each reply on its own.

A model call retried after a temporary error does not count toward Max Model Calls. Max Retries limits it. Its tokens still count. When the provider reports no usage, for example after a timeout, Core estimates the input at four characters per token and shows the attempt under **Unmetered Model Attempts** on the run.

## Model cost

Set **Input** and **Output Price per Million Tokens** on the Agent Model. Each model call then records an estimated cost. Tokens per run are on the Agent Run record: **Input Token Count**, **Output Token Count**, and **Total Token Count**.

## Salesforce cost

Each model turn is one Queueable job. A **Stays in This Org** tool call runs in the job of the model turn or **Reads Outside Systems** call before it. Every other tool call is one job.

| Item | Cost |
| --- | --- |
| Start of a run with an identity, by someone else | 2 jobs and 1 API call |
| Start of a run with an identity, by its execution user | 1 job |
| Each model turn, with the Stays in This Org tool calls of its answer | 1 job |
| Each Reads Outside Systems tool call, with the Stays in This Org calls after it | 1 job |
| Each Changes Outside Systems tool call | 1 job |
| Each Stays in This Org call after a Changes Outside Systems call or an approval in the same answer | 1 job |
| Reply, approval, or rescue on a run with an identity | 2 jobs and 1 API call |
| A typical run with 4 model turns and 3 Stays in This Org tool calls | About 5 jobs |
| The same run with 3 outside tool calls | About 8 jobs |
| Recovery, every 10 minutes | Up to 25 commands, and up to 10 extra passes when more are due |
| Retention, daily | Clears about 10,000 run payloads and deletes about 5,000 runs |

## How many runs an org can handle

The daily async Apex limit is 250,000 jobs, or 200 per user license, whichever is larger. About 30,000 runs a day with outside tools, or about 50,000 with Stays in This Org tools, use all of it. Other async work in the org shares the same limit.

When the org gets close, the **Agent Core Health** card shows **Reduce load**.

## Large data volumes

Recovery, health, and retention filter on these fields: `Status__c`, `RecoveryCheckAt__c`, `DispatchDueAt__c`, `PurgeAfter__c`, and `DeleteAfter__c`. Above about a million Agent Command or Agent Event records, ask Salesforce Support for custom indexes on them.

## Time

A model call takes from a second to two minutes, depending on the model and the answer's length. Each job waits in the async queue before it starts, usually under a few seconds. The run story shows how long each step waited and ran. A tool call that ran in its model turn's job waited 0 ms.
