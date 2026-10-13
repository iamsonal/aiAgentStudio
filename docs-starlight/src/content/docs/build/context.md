---
title: Give the agent context
description: Send fields from the run's record or the starting user to the model on every call, without a tool.
---

A context provider adds information to every model call. The agent does not have to ask for it, so it saves a tool call and a model call per run.

## Use a Field Set

1. In Object Manager, create a Field Set on the object with the fields the agent needs. Use 1 to 30 fields on the object itself. Parent fields such as `Account.Name` are not supported.
2. On the agent, add an **Agent Context Provider**:

   | Field | Value |
   | --- | --- |
   | Developer Name | A short name, such as `case_fields` |
   | Implementation Type | Field Set |
   | Context Subject | **Anchor Record** for the run's record, or **Initiating User** for the person who started the run |
   | Object API Name | The object. For Initiating User, `User`. |
   | Field Set API Name | Your Field Set |
   | Sort Order | Lower numbers are sent first |
   | Is Active | Checked |

3. Save.

With **Anchor Record**, every run of the agent must start with an Anchor Record ID of that object.

## Whose access

The run's user needs sharing access to the record and read access to the object and fields. On a run a person started, Core sends only the fields that person can read. Classified fields reach the model as tokens.

## Limits

- Each provider sends at most 16,000 characters.
- All context together must fit in the agent's **Max Model Request Characters**. When it does not, Core cuts it and marks it as cut.
- A provider that fails, or runs out of its share of Salesforce limits, is left out of that call. The run continues. The run story shows it as **Failed** or **Skipped**.

## Custom context

A developer can write an Apex class that implements `IContextProvider`, for example to read data that needs more than one query. Set Implementation Type to **Apex** and pick the class in **Implementation Reference**. Ask the developer which settings it needs in **Implementation Configuration**. See [Extend Pluto](/extend/).
