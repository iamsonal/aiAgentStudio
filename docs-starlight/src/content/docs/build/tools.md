---
title: Choose a tool type
description: The tools Core ships, the fields every tool has, and what Effects means for recovery.
---

A tool is something the agent may do. Each **Agent Tool** record belongs to one agent and has one tool type. The agent can only do what its active tools allow.

## Tool types Core ships

| Tool type | Name | Use it to |
| --- | --- | --- |
| Query Records | `QueryRecords` | Read records with one SOQL query you write. See [Read records](/build/query-records/). |
| Create Record | `CreateRecord` | Create one record with the fields you list. See [Create and update records](/build/record-tools/). |
| Update Record | `UpdateRecord` | Change the fields you list on one record. See [Create and update records](/build/record-tools/). |
| Run Flow | `RunFlow` | Run an autolaunched Flow that only reads or changes this org. See [Run a Flow](/build/run-flow/). |
| Run Flow With External Effects | `RunFlowWithExternalEffects` | Run an autolaunched Flow that makes callouts, sends email, or publishes events. See [Run a Flow](/build/run-flow/). |
| Post to Chatter | `PostChatter` | Post one message to a feed. See [Post to Chatter](/build/post-chatter/). |

Developers can add more tool types in Apex. See [Extend Pluto](/extend/).

## Fields every tool has

| Field | What to enter |
| --- | --- |
| Developer Name | The name the model calls the tool by, such as `set_case_priority`. Unique within the agent. |
| Description | What the tool does, what it needs, and what it changes, written for the model. The model reads this to decide when to call the tool. |
| Tool Type | One of the names above, or a custom type from your developers. |
| Implementation Configuration | The tool's settings, as JSON. The model never sees them. |
| Input Schema | The inputs the model may send, as JSON Schema. Leave it blank for a tool type that builds its inputs: every Core tool type, and Search Knowledge, Run Report, and the channel tools. Fill it in for Call API, Read from API, the MCP tools, and a custom type that does not build its inputs. |
| Sort Order | Lower numbers are listed to the model first. |
| Is Active | Unchecked by default. Check it to give the tool to the agent. |
| Always Require Approval and the approval fields | See [Require approval](/approvals/require/). |
| Allowed Sensitive Data Categories | Leave empty unless the tool needs real values, such as a real email address to send to. See [Sensitive data](/data/sensitive/). |

In Pluto Console, the tool editor shows a form for the settings, so most tools need no JSON.

## Write a good description

- Start with a verb: "Sets the Priority of the case this run is about."
- Say what the tool needs and what it returns.
- Say what it changes, and what it never does.
- Keep it short. The model reads every description on every call.

## Effects

Each tool type has an **Effects** value. It tells Core what to do when a call fails or its outcome is unclear. It also decides where the call runs. A **Stays in This Org** call runs in the same job as the model turn or **Reads Outside Systems** call before it, so it adds no wait. The others run in a job of their own. Calls always run in the order the agent asked for them.

| Effects | Meaning | When a call fails or is lost |
| --- | --- | --- |
| Stays in This Org | The tool only reads or changes records in this org. | Core undoes the tool's changes and tries again or tells the agent. Never Unknown. |
| Reads Outside Systems | The tool calls an outside system but only reads. | Core tries again. Running it twice is harmless. |
| Changes Outside Systems | The tool may create, change, send, or delete something outside the org. | Core never repeats an unconfirmed call. It marks the call `Unknown` and waits for an operator to check. See [Settle an Unknown call](/operate/unknown/). |

Effects is set on the tool type by the developer, not on each tool. The [Tool types reference](/reference/generated/tool-types/) lists the value for each type.
