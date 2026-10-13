---
title: Run a Flow
description: Let an agent run an autolaunched Flow, and pick the tool type that matches what the Flow does.
---

A Flow tool runs one active, autolaunched Flow. Use it for work that takes several steps or that your team already built in Flow.

## Pick the tool type

| The Flow | Tool Type | If the call fails |
| --- | --- | --- |
| Only reads or changes this org's records | `RunFlow` | Its changes are undone and the agent gets the error. |
| Makes callouts, sends email, or publishes events | `RunFlowWithExternalEffects` | Core never repeats an unconfirmed run. It marks the call `Unknown` for an operator to check. |

When unsure, use `RunFlowWithExternalEffects`. A `RunFlow` tool whose Flow sends an email or starts a job ends as `Unknown` anyway, and a callout fails and pauses the run.

## Build one

1. Build an autolaunched Flow. Mark each input variable **Available for input** and each result **Available for output**.
2. Activate it.
3. Create an Agent Tool with the Tool Type from the table.
4. In Implementation Configuration, enter:

   ```json
   { "flowApiName": "Close_Case_With_Comment", "allowSystemContext": true }
   ```

5. Save. Core builds one optional input for each text, number, date, or checkbox input variable of the active Flow version, on each run. The variable's description is what the model reads, so write one in Flow Builder. Collection, record, and Apex-defined variables are left out.
6. Under **What the model sees**, mark the inputs the Flow needs as required. To keep a text input to a few values, click **Limit values** and list them. To shorten it, click **Limit length**. These edits are stored in Implementation Configuration:

   ```json
   {
     "flowApiName": "Close_Case_With_Comment",
     "allowSystemContext": true,
     "inputOverrides": { "recordId": { "required": true }, "comment": { "required": true, "maxLength": 1000 } }
   }
   ```

## Why allowSystemContext is required

A Flow started from Apex runs with system access to objects and fields, even when the Flow's **How to Run the Flow** setting is Default Mode. `allowSystemContext: true` is you saying "I checked what this Flow can change." Core refuses the tool without it.

:::caution
Before you set it, read the Flow. Check every record it reads or changes. Limit it to the records the agent should touch.
:::

On a run a person started, Core refuses to run the Flow unless the person can edit every record whose Id is a Flow input.

## What the agent gets back

- The Flow's output variables, as JSON.
- `{"flowCompleted": true}` when the Flow has no outputs.
- Record output variables come back as records, with field access and sensitive-data protection applied. A Flow may not mix record and plain outputs.

## Limits

- Screen Flows, record-triggered Flows, and scheduled Flows cannot be used.
- Only Flows in your org's own namespace are used. A packaged Flow with the same API name is never run instead.
