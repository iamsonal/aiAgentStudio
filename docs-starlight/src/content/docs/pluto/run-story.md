---
title: The run story
description: Read what a run did, who approved it, where the time went, and what to do if it stopped.
---

Open any **Agent Run** in Pluto Console to see its run story: every step of the run, in order, on one page.

## What it shows

| Part | Shows |
| --- | --- |
| Header | The run's status, who it acts as, and colored pills for what changed the outcome, such as "1 approval rejected" or "Paused 3 times". Click a pill to jump to that step. |
| Attention box | When the run stopped: why, and what to do next. For a budget pause, which limit ran out and by how much. |
| Measures | One tile per measure: model calls, tool calls, tokens, and time. An agent's limit shows on the tile it limits. |
| Time bar | Where the time went, model and tools in different colors. |
| Timeline | Each model call and tool call as a card. When one model reply asks for several tools, they share one box. |
| Answer | The final answer, with a green check. |

## Reading the timeline

- A model card lists the tools the model was offered. Each links to the tool's page.
- A tool card shows the input and result in a readable form. Click to see the raw record Core stored instead.
- The reason the model gave for a tool call shows as a blue quote. Core does not check it.
- A tool the approver rejected shows **Rejected** in red. An expired approval shows **Not run** in orange.
- A pause, the rescue that ended it, and any agent change the rescue used are one row. For example: "Paused for 16 m 54 s: Out of tool calls. Pat Lee raised Max Tool Calls from 3 to 4 and resumed the run."
- A step an operator steered has a person icon.
- A cancelled run is orange.

While a run is still going, the page refreshes on its own and keeps your place.

## Act on the run

Click **Operate** to rescue, reconcile, pause, or cancel. See [Fix a stuck run](/operate/stuck-run/).
