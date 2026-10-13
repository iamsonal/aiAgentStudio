---
title: Start a run
description: Start an agent from a Flow or Apex, decide whose access the run gets, and read its result.
---

## From a Flow

Use the **Start Agent Run** action. It works in record-triggered, scheduled, screen, and platform event-triggered Flows.

| Input | Required | What to enter |
| --- | --- | --- |
| Agent Developer Name | Yes | The agent's Developer Name. |
| Input | No | What the agent should do, as text or JSON. |
| Anchor Record ID | No | The record the run is about. The agent sees its name and object. Both the starter and the agent must be able to read it. |
| Correlation Key | No | Recommended in record-triggered Flows. A second start with the same key returns the first run instead of starting another. Example: `{!$Record.Id}-triage`. |
| Parent Run ID | No | The run this one continues. See [Chain agents](/run/chain/). |

The action returns the **Run ID** at once. The run continues in the background. An error, such as an agent not shared with the user, comes back in **Error Message** instead of failing the Flow.

## Who may start a run

A user needs the `AgentKernelRunAgents` permission set and a share of the Agent Definition. See [Give people access](/setup/permissions/).

## Whose access the run gets

How the run starts decides this. The starter cannot choose.

| Started by | Agent with an identity | Agent without an identity |
| --- | --- | --- |
| A person's click, screen Flow, or record save (including a record-triggered Flow their save fires) | The execution user, limited to what that person can see | The person |
| A scheduled Flow, scheduled path, platform event Flow, Apex trigger, or background job | The execution user | Refused. Nobody owns this access. |

For work that needs the execution user's full access after a save, start the run from a scheduled path or a platform event-triggered Flow. Give that Flow's running user `AgentKernelRunAgents`, a share of the agent, and use of the identity's Named Credential.

## Read the result

Use the **Get Agent Run Result** action with the Run ID. It returns:

| Output | Meaning |
| --- | --- |
| Status | Running, Waiting, Paused, Succeeded, Failed, or Cancelled. |
| Output | The final answer. Sensitive values stay as tokens unless the user has `AgentKernelTrustResolver`. |
| Error Code and Error Message | Why a run paused or failed. |

A run takes seconds to minutes. To act when it finishes, subscribe a platform event-triggered Flow to **Agent Lifecycle Event**, as in [Chain agents](/run/chain/). Always read the run's status with Get Agent Run Result. The event is a hint, not proof.

## From Apex

Call `AgentRunService.start`. Developers can read a run's full history with `AgentTraceService`. See [Extend Pluto](/extend/).

## Cost

| Start | Cost |
| --- | --- |
| Agent with an identity, started by someone other than its execution user | 2 jobs and 1 API call |
| Agent with an identity, started by its execution user | 1 job |
| Each model or tool step | 1 job |
| A typical run with 3 tool calls | About 8 jobs |

See [Limits and cost](/operate/limits/).
