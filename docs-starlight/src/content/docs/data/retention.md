---
title: Retention and erasure
description: How long run data is kept, how to change it, and how to erase one person's data.
---

Core's daily retention schedule clears run data in two stages.

| Stage | Default | What happens |
| --- | --- | --- |
| Payload purge | 30 days after the run ends | Inputs, model requests and replies, tool inputs and results, approval comments, and vault values are cleared. Who did what, and when, stays. |
| Record deletion | Never | The run and its steps are deleted. |

## Change the defaults

The defaults live in the **Agent Data Policy** custom metadata type.

1. In Setup, open **Custom Metadata Types**, then **Agent Data Policy**, then **Manage Records**.
2. Create a record with the Agent Data Policy Name `OrgDefaults`, or edit it if it exists. Core reads only this record. Set:

   | Field | Default | Range |
   | --- | --- | --- |
   | Payload Retention Days | 30 | 0 to 3,650 |
   | Record Retention Days | Blank: keep forever | Payload Retention Days to 3,650 |
   | Payload Retention Mode | Redacted | **Redacted** stores tokens, not real values. **Full** stores raw content. **Hash Only** and **None** store less. |

Changes apply to runs that start after the change. Runs already started keep their own values.

## Erase one person's data

For a data subject request, a developer calls `PayloadRetentionPurgeService.scheduleErasure` with the Ids of the person's records, such as their Contact and User. Core moves the purge and deletion dates of every run started by them, or about those records, to now. The next retention pass clears them.

- A paused run loses its data but keeps its record.
- A running or waiting run is only counted. Cancel it, then call `scheduleErasure` again.

## Capacity

Each daily pass clears about 10,000 run payloads and deletes about 5,000 runs. If you start more than about 5,000 runs a day with Record Retention Days set, deletion falls behind. The **Agent Core Health** card shows the backlog.

## What stays forever

With Record Retention Days blank, the run, its steps, and its approvals stay after the payload purge. They show who started the run, which tools ran, who approved, and how long each step took, without the content.

Agent Operational Issues are deleted 30 days after they are closed.
