---
title: Extend Pluto
description: The four Apex interfaces developers implement to add tools, model providers, context, and rules.
---

Developers extend Pluto Core through four interfaces. Nothing else is a supported extension point.

| Interface | Add | Admins then |
| --- | --- | --- |
| `ITool` | A new tool type, such as a call to your order system. Optionally with `IToolAuthoring`, so admins fill in settings instead of writing an Input Schema. | Pick the new name in a tool's **Tool Type**. |
| `IModelProvider` | A connection to another model provider. | Name the class in an Agent Model's **Model Adapter Class**. |
| `IContextProvider` | Context that needs more than a Field Set. | Pick the class in a context provider's **Implementation Reference**. |
| `IToolAuthorizationPolicy` | Rules that allow, deny, or require approval call by call. | Pick the class in the agent's **Tool Authorization Policy Class**. |

Core runs each one inside its own lifecycle. The extension returns a result. Core records it, retries it, or pauses the run. An extension never writes Core's records itself.

## Before you write one

1. Read the [extension contract](/extend/contract/). It lists every rule Core relies on: access checks, size limits, error types, and how to report an outcome Core cannot see.
2. Choose the tool type's **Effects** carefully. It decides whether Core may repeat a call. See [Effects](/build/tools/#effects).
3. Return records as record sets, not as text. Core protects sensitive fields and filters records for the person only in record sets.
4. Use only Pluto's `global` Apex and the contract's rules. Then your extension can stay private under any license. See [License](/reference/license/#custom-tools-and-other-extensions).

## Register a tool type

A tool class needs an **Agent Tool Type** custom metadata record, deployed with it:

| Field | Value |
| --- | --- |
| Label and name | What admins type in **Tool Type**, such as `LookupOrder` |
| Tool Class | Your class |
| Implementation Type | `Apex` |
| Effects | Stays in This Org, Reads Outside Systems, or Changes Outside Systems |
| Description | One sentence for admins |

## Test it

Test against the exact Pluto Core version you will install. At least cover: sharing and field access under a standard user, timeouts, permanent and retryable errors, oversized responses, schema rejection, deduplication on the operation key, and the Unknown path for an outside effect Core cannot confirm.

:::caution
Same-org Apex is trusted. Core does not sandbox it. Review extension classes, and the classes they call, before you deploy them.
:::
