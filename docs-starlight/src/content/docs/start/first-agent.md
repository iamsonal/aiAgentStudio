---
title: Your first agent
description: Build an agent that triages each new Case, sets its priority, and posts a note to the Case feed.
---

This example builds a **Case Triage** agent. When someone creates a Case, a Flow starts the agent. The agent reads the Case, sets its Priority, and posts a short note to the Case's Chatter feed.

It takes about 20 minutes. Each run makes 2 or 3 model calls and finishes in under a minute.

:::note[Before you start]
Finish the steps in [Install](/start/install/) and [Connect a model](/setup/model/).
:::

The agent has no Agent Execution Identity, so it runs as the person who creates the Case and can do only what that person can do.

## 1. Choose what the agent reads

1. In Object Manager, open **Case**, then **Field Sets**, and click **New**.
2. Name it `Agent_Triage`.
3. Add **Subject**, **Description**, **Origin**, and **Status**. Save.

## 2. Create the agent

Create an **Agent Definition** record. With Pluto Console installed, use the **Agent Definitions** tab in the Pluto app.

| Field | Value |
| --- | --- |
| Name | Case Triage |
| Developer Name | `case_triage` |
| Model | The developer name of your Agent Model, such as `OpenAI_GPT_5` |
| Agent Execution Identity | Leave blank |
| Instructions | See below |
| Is Active | Checked |

Instructions:

```text
You triage new support cases.
Read the case. Set Priority to High, Medium, or Low:
- High: the customer cannot work, or the case mentions a security problem.
- Medium: something is broken but there is a workaround.
- Low: questions and requests.
Then post one note to the case of at most three sentences: the priority you chose and why.
Do not invent facts that are not in the case.
```

## 3. Give it the Case

On the agent, add an **Agent Context Provider**:

| Field | Value |
| --- | --- |
| Developer Name | `case_fields` |
| Implementation Type | Field Set |
| Context Subject | Anchor Record |
| Object API Name | `Case` |
| Field Set API Name | `Agent_Triage` |
| Is Active | Checked |

The agent now sees these four fields on every model call. It needs no tool to read them.

## 4. Add two tools

Add an **Agent Tool** that sets the priority:

| Field | Value |
| --- | --- |
| Developer Name | `set_case_priority` |
| Tool Type | `UpdateRecord` |
| Description | Sets the Priority of the case this run is about. |
| Implementation Configuration | `{"objectApiName": "Case", "fields": ["Priority"], "anchorRecordOnly": true}` |
| Is Active | Checked |

Leave Input Schema blank. Core builds the input on each run, with Priority's current picklist values.

Add a second tool that posts the note:

| Field | Value |
| --- | --- |
| Developer Name | `post_triage_note` |
| Tool Type | `PostChatter` |
| Description | Posts a short note to the feed of the case this run is about. |
| Implementation Configuration | Blank, so it posts to the run's record |
| Is Active | Checked |

## 5. Let people use it

1. Create a public group for the people who create Cases, or use an existing one.
2. Share the **Case Triage** Agent Definition with that group: add a sharing rule on Agent Definition, or click **Sharing** on the record.
3. Assign these permission sets to the same people: `AgentKernelRunAgents` and `AgentModelAdapters`.

Without the share, a run fails with "You can't run agent Case Triage. Ask your admin to share it with you."

## 6. Start it from a Flow

1. In Flow Builder, create a **Record-Triggered Flow** on Case, triggered when a record is created, optimized for **Actions and Related Records**.
2. Add the **Start Agent Run** action:

   | Input | Value |
   | --- | --- |
   | Agent Developer Name | `case_triage` |
   | Anchor Record ID | `{!$Record.Id}` |
   | Input | `Triage this new case.` |
   | Correlation Key | `{!$Record.Id}-triage` |

3. Save and activate the Flow.

The Correlation Key makes the start safe to repeat. If the Flow fires twice for the same Case, it gets the same run back instead of a second one.

## 7. Try it

1. Create a Case with the subject "Cannot sign in, whole team blocked".
2. Wait about 30 seconds and refresh. Priority should be High, and the feed should have the agent's note.
3. Open the **Agent Runs** tab and open the newest run. In Pluto Console, the run story shows each model call and tool call.

If the run is **Paused** or **Failed**, its error code says why. See [Fix a stuck run](/operate/stuck-run/).

## What to try next

- Have a person approve the priority change first: [Require approval](/approvals/require/).
- Run it for Cases created by email or by integrations: give the agent an [execution identity](/setup/execution-identity/).
- Read related records, such as the account's other open cases: [Read records](/build/query-records/).
