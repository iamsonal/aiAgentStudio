---
title: Create and update records
description: Let an agent create one record, or change listed fields on one record.
---

**Create Record** and **Update Record** tools write only the fields you list. The agent cannot touch any other field. Core builds the inputs from your settings on each run, with each field's type, length, and current picklist values. Input Schema stays blank.

## Create Record

1. Create an Agent Tool with Tool Type `CreateRecord`.
2. In Implementation Configuration, enter the settings:

   ```json
   {
     "objectApiName": "Task",
     "fields": ["Subject", "Description", "ActivityDate"],
     "defaultFieldValues": { "Status": "Not Started" },
     "recordTypeDeveloperName": "Follow_Up"
   }
   ```

3. Leave Input Schema blank and save.

| Setting | Required | Meaning |
| --- | --- | --- |
| `objectApiName` | Yes | The object, such as `Task`. |
| `fields` | Yes | 1 to 30 field API names the agent may set. |
| `defaultFieldValues` | No | Values every new record gets. The agent cannot change them. |
| `recordTypeDeveloperName` | No | The record type every new record gets. Picklists then offer only that record type's values. |

The schema marks a listed field required when the record cannot be saved without it, unless the platform fills it, it is a checkbox, or `defaultFieldValues` sets it.

The tool returns the new record's Id.

## Update Record

1. Create an Agent Tool with Tool Type `UpdateRecord`.
2. In Implementation Configuration, enter the settings:

   ```json
   { "objectApiName": "Case", "fields": ["Priority", "Status"], "anchorRecordOnly": true }
   ```

3. Leave Input Schema blank and save.

| Setting | Required | Meaning |
| --- | --- | --- |
| `objectApiName` | Yes | The object, such as `Case`. |
| `fields` | Yes | 1 to 30 field API names the agent may change. |
| `defaultFieldValues` | No | Values every update sets. The agent cannot change them. |
| `anchorRecordOnly` | No | `true` updates only the record the run started from, and the agent does not send an Id. Blank or `false` lets the agent pick any record of the object the run's user can edit. |

Set `anchorRecordOnly` to `true` whenever the agent reads customer text, such as emails or case comments. That text could otherwise ask the agent to change a different record. Without it, Core warns when you validate an agent that has an Agent Execution Identity, unless the tool has Always Require Approval checked.

## Run values

A value in `defaultFieldValues` can be a run value. Core fills it in on each call. The agent never sees it and cannot change it.

| Run value | Core fills in | Fits |
| --- | --- | --- |
| `:anchorId` | The Anchor Record ID of the run | Id or a lookup field, such as `AccountId` |
| `:initiatingUserId` | The run's Initiating User | A lookup that can point to a user, such as `OwnerId` |
| `:principalUserId` | The run's Resolved Principal User, which the run's tools act as | A lookup that can point to a user |
| `:today` | Today's date, in the Resolved Principal User's time zone | A Date field |
| `:now` | The current date and time | A Date/Time field |

For example, this Create Record tool adds a follow-up Task to the run's record, owned by the person who started the run:

```json
{
  "objectApiName": "Task",
  "fields": ["Subject", "Description"],
  "defaultFieldValues": { "WhatId": ":anchorId", "OwnerId": ":initiatingUserId", "ActivityDate": ":today" }
}
```

### Dates relative to today

A Date field can also take a date relative to today. Write `:today` or a period name, then an optional offset. The offset is `+` or `-`, a number, and a unit: `d` (days), `w` (weeks), `m` (months), or `y` (years). Core moves today by the offset first, then goes to the start or end of the period.

| Value | Core fills in |
| --- | --- |
| `:today-1d` | Yesterday |
| `:today+2w` | Two weeks from today |
| `:today+1y` | One year from today |
| `:startOfWeek`, `:endOfWeek` | The first or last day of this week |
| `:startOfMonth`, `:endOfMonth` | The first or last day of this month |
| `:startOfQuarter`, `:endOfQuarter` | The first or last day of this calendar quarter |
| `:startOfYear`, `:endOfYear` | January 1 or December 31 of this year |
| `:startOfWeek+1w` | The first day of next week |
| `:endOfMonth-1m` | The last day of last month |
| `:endOfMonth+1m` | The last day of next month. From January 31, that is February 28, or 29 in a leap year. |

Quarters and years are calendar ones, not your org's fiscal year. A week starts on the day the Resolved Principal User's locale starts it, such as Sunday in the United States and Monday in much of Europe. A Date/Time field takes `:now` with an offset in hours (`h`) or days (`d`), such as `:now+4h`.

These work only in `defaultFieldValues`. In a Query Records query, use the SOQL date literals, such as `THIS_MONTH`.

When you save, Core refuses a run value in a field it does not fit, and a `:name` that is not a run value. When the tool runs, the call fails with an error if the run has no such value, for example `:anchorId` on a run that did not start on a record, or a record of a type the field cannot point to.

## In Pluto Console

Pick the object and fields from lists instead of typing JSON. **Record Type**, **Fields the Agent May Set**, and **Fixed Field Values** appear once you choose the object. Under **Fixed Field Values**, each row has a **Field** and, when Pluto can fill in a value for that field, a **Set to** choice. For a date, **Set to** has five choices: **A date you choose**, **Today**, **Days, weeks, months, or years from today** (enter an amount and a unit; a minus sign means before today), and **The start of** or **The end of a week, month, quarter, or year** (choose **This**, **Next**, or **Last**, and the period). A line under the row says what Pluto fills in, such as "Pluto fills in the end of next quarter on each call." A Date/Time field offers **Now** and **Hours or days from now**. To enter a value yourself, the row shows a control for the field's type, such as a date picker, a number box, a picklist, or a record picker. **Anchor Record Only** is a checkbox. On the **Parameters** list, you can reword a field's description, make a field required, or offer only some picklist values. Pluto Console saves your changes to the Input Schema. Fields you did not change keep following the object.

## Checks on save

- Each field must exist and be writable.
- A field in `defaultFieldValues` cannot also be in `fields`.
- Each value in `defaultFieldValues` must fit its field: a run value of the right kind, or a value of the field's type, such as a whole number or a `yyyy-MM-dd` date. A value in a restricted picklist must be one of its active values.
- On an agent with an Agent Execution Identity, Core checks that the execution user can create or edit the object and fields. If you later take that access away, runs fail at the tool call with an access error.

## When a call fails

Both tool types only change this org, so a failed call is undone and the agent gets the error. For example, a validation rule's message goes back to the agent, which can correct its input and try again. These tools never end as `Unknown`.
