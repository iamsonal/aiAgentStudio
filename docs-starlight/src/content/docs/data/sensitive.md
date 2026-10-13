---
title: Sensitive data
description: What Core replaces with tokens before the model sees it, what it does not cover, and how tools get real values.
---

Before anything reaches the model or is stored on a run, Core replaces sensitive values with tokens such as `{{EMAIL_3_9f2c61ab}}`. The model works with the token. Only tools you allow get the real value back.

## What is replaced

| Category | Where Core finds it |
| --- | --- |
| Email | Anywhere in text and records |
| Phone | Anywhere, in common formats |
| Payment Card | Anywhere |
| US SSN | Anywhere |
| IBAN | Anywhere |
| Salesforce Classified | Fields with a data classification, in records a tool or context provider returns as records |

## What is not covered

:::caution
Other personal data in free text reaches the model as written: names, street addresses, birth dates, passport numbers, and anything else not in the table.
:::

To protect a field:

1. Set its **Data Sensitivity Level** or **Compliance Categorization** in Object Manager.
2. Read it with a tool that returns records, such as Query Records, or a Field Set context provider.

A classified field that a tool pastes into plain text is not protected.

## Give a tool real values

A tool that must send a real email address or card number needs it back.

1. Open the Agent Tool.
2. In **Allowed Sensitive Data Categories**, select only the categories the tool needs.

Core turns tokens of those categories back into real values in memory, just before the tool runs. They are never stored as real values on the run.

## Who sees real values

| Who | Sees |
| --- | --- |
| The model | Tokens only |
| A tool with allowed categories | Real values of those categories |
| An approver in **Decide** | Placeholders |
| A user reading a run's answer | Tokens, unless they hold `AgentKernelTrustResolver` |

Each time Core reveals a real value, it records who and when.

## Where real values are kept

Core keeps each real value in a vault object so it can give it back to allowed tools. The vault is cleared by retention, on the same schedule as the run. Field access hides the vault, but a user with **Modify All Data** can give themselves access. Limit who holds Modify All Data.

The trust key that makes tokens is the protected custom setting `AgentTrustKey__c`. Core installs without a namespace, so admins can still read it. It only makes token fingerprints. It does not unlock the vault.

## A run's tokens stay in the run

A token works only inside the run that made it. To pass data to another run, pass record Ids, not values.
