---
title: Operational issues
description: Failures that need a person are kept as Agent Operational Issues. Find them, fix them, and close them.
---

When something fails that a person must handle, Core opens an **Agent Operational Issue**. Each issue names what failed, how often, the run or approval it concerns, and its **Next Step**.

Only operators and admins see issues.

## Find them

Open the **Agent Operational Issues** tab and choose the **Open** list view. The **Agent Core Health** card also counts them under **Review open issues**.

## How issues behave

- The same failure on the same subject adds to one open issue instead of opening a new one.
- Core closes an issue itself when it sees the failure recover, for example a notice that later goes through.
- Close the rest yourself once you handle them, with the **Dismiss Agent Operational Issue** Flow action and a reason.
- Closed issues are deleted after 30 days.

## Common issues

| Code | Means | Do this |
| --- | --- | --- |
| `FLOW_START_LOST` | A Flow started a run, but the start never happened. One issue per start, naming the agent and the record. | Start the agent again for the record, with the same Correlation Key if one was used. |
| `FLOW_START_FAILED` | A Flow's start of a run failed. | Fix the reason in **Detail**, such as the agent's sharing or its execution identity, then start the run again. |
| `WORKER_FAILED` | A step's job failed. | Nothing at first. Recovery retries the step. If the run paused, rescue or cancel it. |
| `WORKER_FAILURE_RECOVERY_FAILED` | Recovery could not handle a failed step. | Click **Run Recovery Now** on the Health card. If the run paused, rescue or cancel it. |
| `DISPATCH_RETRY_FAILED` | Core could not start a run's next step as the execution user. | Click **Verify** on the Agent Execution Identity. Recovery tries again within 10 minutes. |
| `RECOVERY_ITEM_FAILED` | Recovery failed on one item and skips it for 15 minutes. | If it keeps failing, open the run and rescue or cancel it. |

Any other issue says: open the related run or record, fix the cause, then dismiss the issue.
