---
title: Give people access
description: Which permission set each person needs, and how sharing decides who may run an agent.
---

Two things decide who may run an agent: a permission set, and a share of the Agent Definition. A user needs both.

## Permission sets

| Who | Permission set |
| --- | --- |
| Core administrators, and the owner of Core's schedules | `AgentKernelAdmin` |
| People and integrations that start runs | `AgentKernelRunAgents` |
| Operators who rescue, reconcile, pause, or cancel runs | `AgentKernelOperator` |
| Approvers | `AgentKernelHumanDecision` |
| Execution users | `AgentKernelServicePrincipal` |
| Users of an approval relay, such as an approval process integration | `AgentKernelApprovalRelay` |
| People who may read a run's final answer with real values instead of tokens | `AgentKernelTrustResolver` |
| Temporary access to stored payloads, for an investigation | `AgentKernelSensitiveData` |
| Every user a run can act as, when you use Pluto Model Adapters | `AgentModelAdapters` |
| Pluto Console admins, together with `AgentKernelAdmin` | `PlutoAdmin` |

`AgentKernelAdmin` and `AgentKernelOperator` can also cancel any run and reply to a waiting conversation for the person.

The [Permission sets reference](/reference/generated/permission-sets/) lists what each one grants.

## Share the agent

Agent Definitions are private. Sharing decides who may run each one.

1. Create a public group for the people and integrations that start the agent.
2. On **Agent Definition**, add a sharing rule to that group with **Read Only** access. Or open the agent and click **Sharing**.
3. Include the running user of every Flow, trigger, or integration that starts the agent.

Someone without a share gets "You can't run agent X. Ask your admin to share it with you." In Pluto Console, the agent's **Related** tab shows who it is shared with.

## Rules that never change

- An execution user can never approve. Core refuses an identity whose user holds approval permissions.
- The agent never approves its own work.
- A run a person starts is limited to that person's access, even on an agent with an identity.
- Only operators and admins see Agent Operational Issues.
