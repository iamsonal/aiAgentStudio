---
title: Agent settings
description: What each Agent Definition field does, its default, and when to change it.
---

An **Agent Definition** is one agent: its instructions, its model, its limits, and who it runs as. Its tools and context providers are related records.

Core checks the setup when you save it. A mistake shows as a field error on save, not as a failed run later.

## Required fields

| Field | What to enter |
| --- | --- |
| Name | A name people recognize, such as "Case Triage". |
| Developer Name | A stable name with letters, numbers, and underscores, such as `case_triage`. Flows and Apex start the agent by this name. Changing it breaks them. |
| Model | The Agent Model Name of an active [Agent Model](/setup/model/#create-the-agent-model). |
| Instructions | What the agent does, its limits, and how it should answer. The model gets this text on every call. |
| Is Active | Check it when the agent is ready. Unchecked, nobody can start it. |

## Who it runs as

| Field | Default | Notes |
| --- | --- | --- |
| Agent Execution Identity | Blank: the run acts as whoever starts it. | Set it for approvals, background work, and long waits. See [Create an execution identity](/setup/execution-identity/). |
| Tool Authorization Policy Class | Blank: no policy. | An Apex class that allows, denies, or sends tool calls for approval by rule. It decides only tools whose Approval is Decided by Policy. See [Approve by rule](/approvals/policy/). |

## Limits

Every limit counts the whole run. When a run reaches one, it pauses with `BUDGET_EXCEEDED`. Raise the limit and rescue the run to continue from where it stopped.

| Field | Default | Range |
| --- | --- | --- |
| Max Model Calls | 10 | 1 to 9,999 |
| Max Tool Calls | 15 | 0 to 9,999. 0 means the agent may call no tools. |
| Max Total Tokens | 250,000 | 1,000 to 100,000,000. Checked before each model call. |
| Max Retries | 3 | 0 to 99. Retries after a temporary failure. A retried model call does not count toward Max Model Calls. |
| Model Timeout Seconds | 120 | 10 to 120 |
| Max Model Request Characters | 50,000 | 5,000 to 400,000. Older history and context are cut to fit. |
| Transcript Turn Limit | 10 | 0 to 50. Earlier turns sent with each model call. |

Each tool result goes back to the model, so each tool call needs a model call after it. When you raise Max Tool Calls, check Max Model Calls too.

## Conversations

| Field | Default | Notes |
| --- | --- | --- |
| Wait for Reply (Hours) | Blank: the run ends after its answer. | 1 to 168. The run stays open for the person's next message, then ends with its last answer when the time runs out. See [Hold a conversation](/run/conversation/). With it set, the limits above apply to each reply on its own. |
| Allow Multiple Tool Calls Per Turn | Checked | The model may ask for several tools in one reply. Core runs them in order. This saves model calls. Uncheck it when each tool needs the result of the one before. |

## Structured answers

| Field | Notes |
| --- | --- |
| Output Schema | Optional. A JSON Schema for the final answer. Every object in it needs `"additionalProperties": false`. Core checks the answer against it and asks the model again when it does not match. |

Use an Output Schema when a Flow reads the answer, for example:

```json
{
  "type": "object",
  "properties": {
    "priority": { "type": "string", "enum": ["High", "Medium", "Low"] },
    "reason": { "type": "string" }
  },
  "required": ["priority", "reason"],
  "additionalProperties": false
}
```

## Write good instructions

- Say what the agent is for in one sentence, then its rules.
- Say what to do when information is missing: ask, stop, or hand back.
- Keep tool details in each tool's **Description**, not in the instructions.
- Never put secrets, IDs that change between orgs, or customer data in the instructions.
- The agent sees the record it started from by name. You do not need to tell it which record it is on.

## Changing an agent while it runs

Changes apply to the next step of runs already in progress. The run story in Pluto Console shows a **Configuration Changed** step that lists what changed, for example Max Tool Calls from 3 to 4.

All fields: [Agent Definition reference](/reference/generated/objects/agent-definition/).
