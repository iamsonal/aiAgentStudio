---
title: Connect a model
description: Connect OpenAI, Azure OpenAI, or another Responses API endpoint, and create the Agent Model record agents use.
---

Pluto Core does not call any model provider by itself. A model adapter does. Pluto Model Adapters ships one adapter, `OpenAIResponsesModelProvider`. It works with OpenAI and with any endpoint that serves the OpenAI Responses API, such as Azure OpenAI.

For another provider, a developer writes an `IModelProvider` class. See [Extend Pluto](/extend/).

## Connect OpenAI

1. Install the Pluto Model Adapters package. See [Install](/start/install/).
2. In Setup, open **Named Credentials**, then the **External Credentials** tab, then **OpenAIEC**.
3. Under **Principals**, edit the **OpenAI** principal. Add an authentication parameter named `OpenAIKey` with your API key as its value. Save.
4. Assign the `AgentModelAdapters` permission set to every user a run can act as: each execution user, and each person who starts an agent that has no Agent Execution Identity. It gives them use of the key.
5. Create the Agent Model record. See [Create the Agent Model](#create-the-agent-model).

The key stays in the External Credential. It never appears in source, logs, or run records.

## Connect Azure OpenAI

The adapter calls `/v1/responses` under the Named Credential's URL. The URL carries the host and any base path.

1. In Setup, create an External Credential with the **Custom** authentication protocol. Add a principal.
2. Add a custom header named `api-key` whose value is your Azure key.
3. Create a Named Credential with the URL `https://<your-resource>.openai.azure.com/openai` and that External Credential.
4. In a permission set, give **External Credential Principal Access** to the principal from step 1. Assign it to the same users as in step 4 of [Connect OpenAI](#connect-openai).
5. Create the Agent Model record with your Named Credential, and the Azure deployment name as the Model Identifier.

## Create the Agent Model

An Agent Model is a custom metadata record. Agents name it in their **Model** field.

1. In Setup, open **Custom Metadata Types**, then **Agent Model**, then **Manage Records**.
2. Click **New** and fill in:

   | Field | Value |
   | --- | --- |
   | Label and Agent Model Name | A name such as `OpenAI_GPT_5`. Agents use the Agent Model Name. |
   | Model Adapter Class | `OpenAIResponsesModelProvider` |
   | Named Credential | `OpenAI_API`, or your own Named Credential's API name |
   | Model Identifier | The provider's exact model name, such as `gpt-5`. It is case-sensitive. |
   | Active | Checked |
   | Max Output Tokens | Optional. Blank uses 8,000. |
   | Input and Output Price per Million Tokens | Optional. Set both to record an estimated cost on each model call. |

3. Save.

## What to expect

| Item | Value |
| --- | --- |
| Time per model call | One callout, limited by the agent's Model Timeout. The most is 120 seconds, the Apex callout limit. |
| Longest answer | Max Output Tokens, including the model's reasoning. Blank is 8,000. |
| Temporary provider errors | Retried, up to the agent's Max Retries. |
| An answer cut off at the limit | The run pauses with `MODEL_OUTPUT_TRUNCATED`. Raise Max Output Tokens, then rescue the run. |
| The provider refuses to answer | The run pauses with `MODEL_REFUSED`. |
| Wrong or missing key | The run pauses. The error names "the model endpoint" and the HTTP status. A 401 or 403 means: check the External Credential. |

The largest models can come close to 120 seconds on long turns. For agents a person waits on, choose a faster model.

A run uses only the model on its agent. Pluto never falls back to another model on its own.
