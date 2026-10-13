---
title: Decide an approval
description: How an approver finds a pending approval, reviews it, and approves or rejects it.
---

## Find your approvals

Open the **Agent Approvals** tab. Use a list view filtered to **Pending** and assigned to you or your queues. Add the tab to the approvers' app, or send them the list view link.

## Decide

1. Open the approval and click **Decide**.
2. Read, from top to bottom:
   - The record the run is about, and the time left.
   - Why approval is needed.
   - The values the tool will use, with input names written as words.
   - The agent's explanation, shown as a quote. The model wrote it. Nothing checked it.
   - What happens at the deadline.
3. Add a comment. It goes back to the agent on a rejection, so say what to do instead.
4. Click **Approve** or **Reject**.

Sensitive values show as placeholders, such as `{{EMAIL_3_9f2c61ab}}`. The tool gets the real values when it runs.

The record is named only if you can open it.

## Without Pluto Console

**Decide** is a quick action that Pluto Console adds to Agent Approval. Without Pluto Console, build a screen Flow with the **Decide Agent Approval** action. It takes the Approval ID, Approved (true or false), and a comment.

## After the decision

- The run continues within seconds. If the approver cannot use the agent's Named Credential, it continues at the next recovery pass, up to 10 minutes later.
- The comment is kept until the run's payload retention ends. After that, only who decided, the outcome, and when remain.
