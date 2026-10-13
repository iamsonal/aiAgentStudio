---
title: Check health
description: Use the Agent Core Health card to find schedules, identities, runs, and issues that need a person.
---

The **Agent Core Health** card gives one verdict on Core and lists at most six actions. Each action has its reason, its numbers, and where to fix it. If the card lists nothing, nothing needs you.

Find it in the **Pluto** app, on the **Pluto Home** tab, under **Overview**. You can add it to any app or home page in Lightning App Builder. Without Pluto Console, developers can call `AgentKernelHealthService`.

## The six actions

| Action | Means | Do this |
| --- | --- | --- |
| Install or repair schedules | A schedule is missing or stuck, or recovery or retention work is waiting. | Click **Install or Repair Schedules** at the bottom of the card. |
| Fix execution identities | An identity failed Verify or changed since it passed, or a user can use an execution user's credential without needing it. | Fix what the identity's **Verification Result** says and click **Verify**. Remove credential access from the listed users. See [Create an execution identity](/setup/execution-identity/#how-it-fails). |
| Rescue or cancel paused runs | Runs stopped and need a person. Split into runs you can rescue, runs only their starter can continue, and runs whose data was already cleared, which you can only cancel. | See [Fix a stuck run](/operate/stuck-run/). |
| Reconcile unknown tool calls | A tool may have changed something outside Salesforce, and Core cannot tell. | See [Settle an Unknown call](/operate/unknown/). |
| Review open issues | Open Agent Operational Issues and setup warnings. | See [Operational issues](/operate/issues/). |
| Reduce load | The org is near a daily limit, or recovery is behind. | See [Limits and cost](/operate/limits/). |

## Credential review

For operators and admins, the card also lists users who can use an execution identity's Named Credential but hold no permission set that starts, replies to, approves, or operates runs, and own no Core schedule. Remove their access. They don't need it.

## Run recovery now

**Run Recovery Now**, at the bottom of the card, runs one recovery pass at once instead of waiting up to 10 minutes.
