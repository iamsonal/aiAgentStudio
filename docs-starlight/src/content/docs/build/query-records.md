---
title: Read records
description: Give an agent one SOQL query it can run, with values it fills in.
---

A **Query Records** tool runs one SOQL query that you write. The agent fills in only the values you mark with `:name`. It can never change the query itself.

## Build one

1. Create an Agent Tool with Tool Type `QueryRecords`.
2. In Implementation Configuration, enter the query:

   ```json
   {"query": "SELECT Subject, Status FROM Case WHERE CaseNumber = :caseNumber LIMIT 1"}
   ```

3. Leave Input Schema blank. Core builds one required input for each `:name` on each run, typed from the field it is compared to.
4. Save. Core runs the query once with empty values to check it. Any problem shows as a field error.

In Pluto Console, type the query in the **SOQL query** box instead. It suggests objects, fields, and parameter names as you type. **Parameters**, below it, shows each input as soon as you stop typing.

## Run values

Core fills in these names itself. The agent never fills them in, and they are not inputs.

| Run value | Core fills in | Compare it to |
| --- | --- | --- |
| `:anchorId` | The Anchor Record ID of the run | Id or a lookup field, with `=` |
| `:initiatingUserId` | The run's Initiating User | A lookup that can point to a user, such as `OwnerId` |
| `:principalUserId` | The run's Resolved Principal User | A lookup that can point to a user |
| `:today` | Today's date | A Date field |
| `:now` | The current date and time | A Date/Time field |

Use `:anchorId` to keep the agent on the record the run started from:

```sql
SELECT CaseNumber, Status FROM Case
WHERE AccountId = :anchorId AND Status = :status
ORDER BY CreatedDate DESC LIMIT 10
```

A run value cannot follow `IN` or be used in `LIMIT` or `OFFSET`. For dates, the SOQL literals such as `TODAY` and `LAST_N_DAYS:7` also work. The same run values work in [Fixed Field Values](/build/record-tools/#run-values).

## What a query may contain

| Works | Notes |
| --- | --- |
| `:name` compared to a field | `Status = :status`, `Status IN :statuses`, in `WHERE` or a subquery. |
| `LIMIT :count` and `OFFSET :skip` | The agent picks the number. |
| Parent fields | `Account.Name` |
| Child subqueries | `(SELECT LastName FROM Contacts)` |
| `TYPEOF`, and fields such as `What.Name` | |
| `toLabel()`, `FORMAT()`, `convertCurrency()` | In `SELECT`, without an alias. |
| `WITH DATA CATEGORY` | |

| Refused | Why | Use instead |
| --- | --- | --- |
| `COUNT()`, other totals, `GROUP BY` | Core cannot check access on totals. | A custom tool from your developers. |
| Pluto Core objects | The agent may not read its own run records. | Nothing. |
| `WITH USER_MODE`, `WITH SECURITY_ENFORCED` | Core already runs every query as the run's user. Salesforce refuses a second access level. | Leave them out. |
| `WITH SYSTEM_MODE`, `FOR` clauses, `USING SCOPE` | Core cannot protect them. | Nothing. |
| Aliases | Core returns values only under field names. | Leave them out. |

## Limits

`LIMIT` is optional, but Core returns at most 200 records to the agent, child records included. A query that returns more fails with "Structured record output exceeds the 200-record limit". Add a `LIMIT` when a query can match many records.

## Whose access

The query runs as the run's user. On a run a person started, Core also hides records and fields that person cannot read, including parent and child records. Classified fields reach the model as tokens. See [Sensitive data](/data/sensitive/).

## Cost

One SOQL query per call, plus the model call that reads the result. The records count toward the run's Max Model Request Characters.
