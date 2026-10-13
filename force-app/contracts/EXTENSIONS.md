# Pluto Core extension contract

Implementations of `IModelProvider`, `ITool` (with the optional
`IToolAuthoring`), `IContextProvider`, and `IToolAuthorizationPolicy` run inside Core's lifecycle but do not own its
state. Core constructs and invokes each one through a `with sharing` boundary,
so an `inherited sharing` extension sees the execution user's record sharing.
That grants no object or field access.

Same-org Apex in the empty namespace is trusted, and Core does not isolate it:
it can call public helpers or use system-mode DML. Review extension classes
and their dependencies before granting them execution.

## Duties shared by every extension

- Enforce sharing, CRUD, FLS, and business authorization for every business
  record you touch. Use `with sharing` or `inherited sharing`,
  `WITH USER_MODE` or `AccessLevel.USER_MODE`, and the `ToolSecurity`
  helpers.
- Never query or change Pluto Core lifecycle records. Return a DTO; Core
  commits the outcome.
- Never log credentials, authorization headers, plaintext trust-token values,
  complete prompts, or unbounded provider payloads.
- Keep each returned string within 131,072 characters, all of them within
  262,144 in total, and collections within the DTO limits. Core rejects
  oversized responses before trust scanning or persistence.
- An operation key (`runId:commandSequence:commandType[:toolName]`) is unique
  per logical operation and stable across retries, recovery, and rescue, so
  it can serve as a downstream idempotency key. A Changes Outside Systems tool
  that asks for a retry must make the target deduplicate on it.
- `ToolRequest.principal` and `ContextRequest.principal` carry the
  `ExecutionPrincipal`: initiating user, `executionIdentityId`, run user, and
  `anchorRecordId`. Tools and context providers run as the run user: the
  identity's execution user when `executionIdentityId` is set, the starting
  user when it is null.
- When `principal.attendedByUserId` is set, a person started a run of an
  agent with an identity, and the run must not exceed that person's access:
    - Core filters returned `recordSets` for them.
    - Code that reads or changes records any other way calls
      `ToolSecurity.assertRequesterCanRead`, `assertRequesterCanEdit`, or
      `assertRequesterCanCreate` (no-ops on unattended runs).
    - Core withholds a tool's text `output` and error messages unless its
      class implements `IRequesterFilteredTool`. Implement it only if the
      class filters record data in that text with
      `ToolSecurity.requesterReadable`, or writes none there (for example,
      only IDs it just created). Data from an outside system qualifies only
      when anyone may see it, because the system answers for its own
      credential, not for the person.

## `IModelProvider`

- Use the Named Credential and model name in `ModelRequest`. Core reads them
  from the `AgentModel__mdt` record whose Model Adapter Class names your
  class. Never accept secrets in metadata or the request.
- Honor `ModelRequest.timeoutSeconds` for the single callout.
- Cap the provider's output at `ModelRequest.maxOutputTokens` when it is set.
  When it is null, choose a cap that finishes within the timeout.
- Only `ModelRequest.instructions` and the tool definitions are instructions.
  Send every `contexts` item and every transcript entry with
  `untrusted = true` in user or tool roles, delimited from the instructions,
  never in the system role.
- Pass protected-value tokens such as `{{EMAIL_3_9f2c61ab}}` through
  unchanged.
- Send each tool's `inputSchema` as written, including the `_rationale`
  property Core adds to reviewable tools and replayed calls. Core records it
  as the call's reason.
- When `ModelRequest.allowMultipleToolCalls` is `false`, request at most one
  tool call (for example OpenAI's `parallel_tool_calls: false`). Core answers a batch with
  `TOOL_BATCH_NOT_ALLOWED` and asks again. `null` allows several.
- Return exactly one of a final, schema-valid `output`, or one through eight
  active `ModelToolCall` values with bounded JSON input.
- Throw `AgentKernelException.RetryableException` only for an explicitly
  transient condition; Core also retries `System.CalloutException`. Throw
  `PermanentException` for configuration, programming, authentication,
  schema, or deterministic request faults. Any other exception is permanent.

`ModelRequest.transcript` holds every turn, oldest first; there is no separate
input field. Map each entry by `type`:

| Type                     | Source                                                                                                         | Role                |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- | ------------------- |
| `OriginalInput`          | The run's input; always first. A run started from a record sends `{"record":{"object","id","name"},"input":…}` | User                |
| `ToolCall`, `ToolResult` | A call and its result, sharing a `toolCallId` (Core synthesizes one if the provider gave none)                 | Assistant, tool     |
| `UserInput`              | A human response to a wait, including a conversational agent's next message                                    | User                |
| `AssistantOutput`        | The agent's earlier answer in a conversational run                                                             | Assistant           |
| `OperatorGuidance`       | Rescue guidance: only the operator's words and Core's error code                                               | System or developer |
| `ModelFeedback`          | Why Core rejected the previous response (invalid output or tool call)                                          | System or developer |

A failed tool result carries the tool's `errorCode` and a bounded, tokenized
`errorMessage`, or one of: `TOOL_APPROVAL_DENIED` with the reviewer's
tokenized comment; `TOOL_APPROVAL_EXPIRED` when nobody decided in time;
`TOOL_AUTHORIZATION_DENIED` for a policy denial; `TOOL_NOT_RUN` when Core
never ran the call, such as the rest of a batch after one call failed or
waited; or the operator's error code and message when an operator confirms an
`Unknown` call failed.

## `ITool`

Register the class with an Agent Tool Type (`AgentToolType__mdt`) record
deployed with it. Admins pick it on `AgentTool__c.ToolType__c` and never see
the class name.

- Set `Tool Class` to the class and keep `Implementation Type` at `Apex`.
  `Standard` and `Flow` mark Core's own types, listed in
  [Tool types](https://iamsonal.github.io/aiAgentStudio/reference/generated/tool-types/).
- Set `Effects`. It is required:
    - `Stays in This Org` when the tool only reads or changes this org's records.
    - `Reads Outside Systems` when it calls outside systems but only reads,
      so running a call twice has the same effect as once, such as a GET
      lookup.
    - `Changes Outside Systems` for anything else Core cannot roll back: a
      callout that may create, change, send, or delete, an email, or async
      work. When unsure, choose this one.
- Check `Requires Object` when the configuration names one object in
  `objectApiName`.

Core checks that the tool type exists and its class implements `ITool` at
validation and before invocation. That grants no data access.

`validateConfiguration` gets the Implementation Configuration and the input
schema the tool has (hand-written, or built with the admin's edits) when an
active tool is saved and before each run starts. It runs as
the saving admin and must stay query-only; DML, callouts, or async work fail
the save. Check what you can without side effects, such as object, field, and
flow names, option values, and existence; leave the run user's access to
`execute`. Return one admin-readable message per problem, or an empty list.

Settings and inputs (optional):

Implement `IToolAuthoring` so an authoring screen shows each setting as a
control instead of a JSON box. When the tool's inputs follow from its
settings, `describe` also builds them, so the admin fills in only the
settings and the tool has a blank Input Schema. Core calls `describe` on each run, so a picklist, field,
or Flow change reaches the model without saving the tool. `describe` gets a
`ToolConfiguration` with the Implementation Configuration and returns a
`ToolAuthoring`:

- `settings`: each Implementation Configuration key the admin fills in, with
  a label, type, whether it is required, help text, and allowed values when
  there is a fixed set. `blankMeaning` says what a blank optional setting
  does, such as "The run's record". List settings in the order the admin
  decides them. The type picks the control an authoring screen shows:

    | Type                                             | Value                                                                                    |
    | ------------------------------------------------ | ---------------------------------------------------------------------------------------- |
    | `string`, `text`, `integer`, `number`, `boolean` | A plain value. `text` is several lines.                                                  |
    | `textList`                                       | A list of text values, one per line.                                                     |
    | `keyValues`                                      | An object of names to text values. `allowedValues` limits the values.                    |
    | `object`                                         | An object API name.                                                                      |
    | `recordType`                                     | A record type developer name of the object named by `objectSetting`.                     |
    | `fields`                                         | A list of field API names of the object named by `objectSetting` or `objectApiName`.     |
    | `fieldValues`                                    | An object of field API name to value, for the object named by `objectSetting`.           |
    | `record`                                         | A record ID of one of `recordObjects`, such as `User` and `CollaborationGroup`.          |
    | `query`                                          | A SOQL query.                                                                            |
    | `flow`                                           | An autolaunched Flow API name.                                                           |
    | `report`                                         | A report API name.                                                                       |
    | `queue`                                          | A queue API name.                                                                        |
    | `namedCredential`                                | A Named Credential API name.                                                             |
    | `json`                                           | Any JSON value. Screens show unknown types this way.                                     |

- `inputSchema`: the closed input schema the settings give the model.
- `problem`: when the settings cannot build a schema yet, what the admin must
  fix. Return `inputSchema` or `problem`.
- `inputsWrittenByAdmin`: set it to true when only the admin knows the
  inputs, as for an API call. Core then ignores `inputSchema` and `problem`,
  and the admin writes the inputs in Input Schema.
  Check settings problems in `validateConfiguration` instead.

`describe` runs on each run, save, and preview, as whoever is running, inside
the same query-only boundary as `validateConfiguration`. Keep it cheap: Core
calls it once per tool per transaction. Do not throw; Core turns a thrown
exception into `problem`. When a run cannot build a tool's schema, the run
pauses with `TOOL_SCHEMA_UNAVAILABLE` and the problem, and an operator retries
it after the fix. Core's record, query, Chatter, and Flow tools implement it.

The admin narrows the built inputs with edits that Core stores and applies,
so a class never handles them. They sit in Implementation Configuration under
`inputOverrides`, by input path:

```json
"inputOverrides": {
    "recordData.Subject": { "description": "One line naming the product." },
    "recordData.Description": { "required": true },
    "recordData.Priority": { "allowedValues": ["Medium", "High"] },
    "decision": { "allowedValues": ["released", "hold"] },
    "reason": { "maxLength": 255 }
}
```

An edit can replace a description, make an optional input required, keep
some of the values an input offers, limit free text to a list of values, or
lower a text input's length limit. Save refuses an edit that names an input
the tool does not build or that would widen it. On a run, a kept value the
tool no longer offers is dropped. Do not declare a setting named
`inputOverrides`.

A tool whose class does not implement `IToolAuthoring`, or sets
`inputsWrittenByAdmin`, needs a hand-written Input Schema, and
`validateConfiguration` gets it in `inputSchema`. A tool that takes no inputs
has `{"type":"object","properties":{},"additionalProperties":false}`.

Input and output:

- Every executable input schema, including nested objects, must set
  `additionalProperties: false`.
- Do not declare a top-level input named `_rationale`. Core adds it to
  reviewable tools and strips it before validation.
- Return a bounded `ToolResponse` with `output` or `recordSets`, not both.
  Structured output allows at most 10 named sets and 200 records, before
  Core's stricter serialization and trust checks.
- Return Salesforce records as `recordSets`, never serialized into `output`.
  Core tokenizes classified fields only in `recordSets`.

Errors and outcomes:

- Write `PermanentException` messages and `errorMessage` for the model. Core
  returns the code and up to 2,000 characters of the message so the model can
  correct the call, and tokenizes detected sensitive values. Never include
  secrets.
- Use `PermanentException` only for a confirmed permanent failure.
- Throw `RetryableException`, or return `retryable = true`, only when a repeat
  is safe: nothing happened, or the target deduplicates on the operation key.
  Core trusts that claim for every tool type.
- Use `OutcomeUnknownException`, or `outcomeUnknown = true`, only when a real
  side effect may have happened and the target cannot prove the result.
- To wait for another system's answer, return `awaitingExternalInput = true`
  with a `waitingReason` and a `resumeJsonSchema`. Give that system
  `ToolRequest.resumeKey`; its callback passes the key and the answer to the
  **Resume Agent Wait** Flow action or `AgentRunService.resumeWait`. The key
  resumes only this call's wait. Treat it as a secret: never log it or put it
  in `output`.

`Effects` is the complete recovery contract:

- `Stays in This Org`: no callouts, emails, immediate platform events, or async
  work. Core runs the tool in a savepoint and rolls back its DML on any
  outcome but success or an intentional wait. The call is returned to the
  model or retried, never `Unknown`, and a lost worker is safe to repeat. A
  callout fails at the savepoint and pauses the run; an email, immediate
  event, or enqueued job makes the outcome `Unknown`. The call may run in
  the same transaction as the model turn or `Reads Outside Systems` call
  before it, after other calls from that turn, so the tool must not rely on a fresh transaction or
  on governor limits no other call has used.
- `Reads Outside Systems`: the tool runs outside a savepoint, but Core
  handles failures as it does for `Stays in This Org`: a callout failure or lost
  worker repeats the call within the run's retry limits, an unexpected
  exception returns to the model, and a malformed response pauses the run.
  The tool is not asked for `_rationale` unless an approval or policy needs
  it. A tool that throws `OutcomeUnknownException` is still `Unknown`.
- `Changes Outside Systems`, or a value Core does not recognize: an
  unexpected exception, a malformed or oversized response, or a lost worker
  makes the outcome `Unknown`. Core repeats the call only when the tool asks
  for a retry.

A `Stays in This Org` tool must not start work that a rollback cannot undo. Core
detects some of it and makes the outcome `Unknown`; the rest it cannot see, so
such work would repeat when the call is retried. Choose **Changes Outside
Systems** for any tool that does any of these:

| Work the tool starts                        | Core detects it                                   |
| ------------------------------------------- | ------------------------------------------------- |
| Callout                                     | Yes: it fails at the savepoint and pauses the run |
| Email (`Messaging.sendEmail`)               | Yes: `Unknown`                                    |
| Platform event that publishes immediately   | Yes: `Unknown`                                    |
| `System.enqueueJob`                         | Yes: `Unknown`                                    |
| `@future` method                            | Yes: `Unknown`                                    |
| `Database.executeBatch`                     | No                                                |
| `System.schedule` or `System.scheduleBatch` | No                                                |

DML, including platform events that publish after commit, is rolled back with
the savepoint, so it is safe.

At a command's first lease, Core records the tool type's Effects and a hash
of the binding (tool type, class, Effects, configuration). Recovery,
retry, and cancellation use these even if the records change later. If the
active tool no longer matches, Core pauses the command before its first
invocation, or records `Unknown` for reconciliation if an earlier attempt may
have had a side effect. Restore the original binding or start a new
operation; never edit a leased command.

## `IContextProvider`

- Query-only. DML, callouts, email, future work, and Queueable enqueue are
  prohibited and rolled back.
- Providers run in configured order under per-extension query, row, CPU, and
  heap budgets. Core skips providers once its lifecycle reserve is reached.
  A failed, invalid, or over-budget provider is omitted and recorded as
  `SkippedBudget`, `SkippedGovernorBudget`, or `Failed`.
- Return a unique source name and exactly one of bounded text `content` or
  bounded `recordSets`. Prefer `recordSets` for records: Core tokenizes their
  classified fields and filters them for an attended run's person. Core omits
  text `content` from attended runs (`WithheldForRequester`).
- Core enforces the aggregate context budget and caps each provider at 16,000
  characters. Oversized record sets keep whole leading records of each set
  and are marked `Truncated`, so put the most needed records first. Text
  `content` is cut at the budget.

The built-in `FieldSetContextProvider` uses
`ImplementationType__c = Field Set`. Set `ObjectApiName__c`,
`FieldSetName__c`, and `ContextSubject__c`; leave the Apex reference and JSON
configuration blank.

- `Anchor Record` requires `StartRequest.anchorRecordId`; it never infers a
  record from input. `Initiating User` requires the `User` object.
- Field sets support 1 through 30 direct fields.
- The run user needs sharing access to the record and read access to the
  object and fields.

## `IToolAuthorizationPolicy`

Policies follow the same query-only rule and governor reserve as context
providers. Core evaluates the policy for every call; return `Allow`, `Deny`,
or `RequireApproval`.

- `Deny` always stops the call. The model gets `TOOL_AUTHORIZATION_DENIED`
  with your `reason` and continues, so write the reason for the model.
- If the tool's `Always Require Approval` is checked, the call waits for approval
  even on `Allow`. Otherwise `Allow` runs it and `RequireApproval` waits.
- `RequireApproval` needs a nonblank `reason`. Optional `timeoutSeconds` is 60
  through 604,800; blank uses the tool's Approval Timeout. Optional
  `approverId` names a user or queue that decides this call instead of the
  tool's approver, for example to escalate by amount.
- Core pauses the run with `TOOL_AUTHORIZATION_POLICY_INVALID` for a blank
  reason or out-of-range timeout, and with `APPROVAL_ASSIGNMENT_UNRESOLVED`
  when neither policy nor tool names an eligible approver.
- Runs of agents without an identity cannot wait: `RequireApproval` pauses
  them with `INITIATING_USER_APPROVAL_UNSUPPORTED`. Return `Allow` or `Deny`
  when `request.executionIdentityId` is null.
- Upgrading from `executionMode`: `executionMode == 'Delegated Principal'`
  becomes `executionIdentityId != null`, and `'Initiating User'` becomes
  `executionIdentityId == null`. `ExecutionPrincipal`'s constructor takes the
  identity Id in place of the mode.

Core creates the Agent Approval and decides who may approve it; see
[Require approval](https://iamsonal.github.io/aiAgentStudio/approvals/require/).

## Testing an extension

Test against the exact Pluto Core source you will deploy. At minimum, cover
sharing and FLS under a standard user, timeouts, permanent versus retryable
classification, oversized responses, schema rejection, operation-key
deduplication, and the `Unknown` path for an ambiguous external effect.
