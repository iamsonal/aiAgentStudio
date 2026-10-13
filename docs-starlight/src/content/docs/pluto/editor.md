---
title: The Pluto editor
description: How Pluto Console edits agents, tools, context providers, and execution identities.
---

Pluto Console opens one editor for Agent Definitions, Agent Tools, Agent Context Providers, and Agent Execution Identities, in the Pluto app. It looks like a standard Lightning record page and follows the object's page layout.

## Where it opens

- In the Pluto app, the record page shows the editor. Click a field's pencil to edit the whole form in place.
- **Edit** in the page header opens the standard Salesforce form.
- **New** opens the standard Salesforce form. After you save, the record opens in the editor.

The page header has **Edit** and **Delete**. Tools also have **Try Tool**. Execution identities have **Verify**. Agents and execution identities have **Change Owner** and **Sharing**.

Agents and execution identities have a **Details** tab and a **Related** tab. On an agent, **Related** shows who the agent runs as and who it is shared with.

## Editing a tool

A tool has three parts: **Implementation Type** and **Tool Type**, **Settings**, and **What the model sees**. Most tools need no JSON.

To add a tool:

1. Open the **Agent Tools** tab.
2. Click **New**. The standard Salesforce form opens.
3. Fill in the required fields and click **Save**. The tool's record page opens.
4. Click a field's pencil to set up the tool in the Pluto editor.

To set up a Create Record tool:

1. In **Implementation Type**, choose **Standard**. **Tool Type** then lists only the standard tool types.
2. In **Tool Type**, choose **Create Record**. **Object** appears. Nothing is marked wrong until you have filled in the required settings or clicked **Save**.
3. In **Object**, search for and choose the object, such as **Case**. **Record Type**, **Fields the Agent May Set**, and **Fixed Field Values** appear. **Fields the Agent May Set** starts with the fields a case cannot be saved without, and **What the model sees** fills in.
4. In **Record Type**, choose the record type new records get. It decides which picklist values the agent may choose. **Record Type** appears only when the object has record types.
5. In **Fields the Agent May Set**, move each field the agent may set to **Selected**. Each one appears as a row under **What the model sees**.
6. To give every new record a value the agent cannot change, click **Add Value** under **Fixed Field Values** and choose the field. Then either enter the value, or use **Set to** to choose one Pluto fills in on each call, such as **The run's record** or **End of this month**. A field is either fixed or one the agent may set, so each list leaves out the other's fields. A fixed field does not appear under **What the model sees**. See [Dates relative to today](/build/record-tools/#dates-relative-to-today).
7. Edit the rows under **What the model sees** if you need to:
    - **Edit description** changes what the model reads about the input.
    - **Required** makes an optional input required. An input the tool requires is already checked and cannot be cleared.
    - **Limit values** keeps some of a picklist's values, or limits a text input to values you list, one per line.
    - **Limit length** lowers the most characters a text input takes.
    - **Reset** removes your edit, and the row goes back to what Pluto builds.
8. Click **Show JSON**, next to **What the model sees**, to see the exact schema the model receives.
9. Click **Save**. Nothing is saved before this.

Other tool types work the same way. Query Records has one setting, **Query**. Suggestions appear as you type. **Enter** or **Tab** picks one, the arrow keys move, **Esc** closes the list, and **Ctrl+Space** opens it again. Each `:name` in the query becomes an input. Run Flow has **Flow**, and each input variable of the Flow becomes an optional input. Post to Chatter has **Post To**: the run's record, a user, a group, or another record.

Pluto builds the inputs again on every run, so a new picklist value, a deactivated value, or a new Flow variable reaches the agent without saving the tool. If a value you limited an input to is deactivated, the tool page says so.

Changing **Implementation Type**, **Tool Type**, or **Object** asks first, then clears the settings and edits that depend on it.

### Tools whose inputs you list

Pluto cannot work out what some tools take, such as Call API, Read from API, the MCP tools, and some custom Apex tools. For these, **What the model sees** is a list you build.

1. Fill in **Settings**. Each setting has its own control, such as a Named Credential list. A custom tool type that does not describe its settings shows one JSON box, and its developer documents what to enter.
2. Click **Add input**.
3. Enter the **Name** the model sends, such as `orderNumber`, and choose the **Type**: Text, Picklist, Whole number, Number, Checkbox, Record Id, Date, Date and time, Email, Group, or List.
4. Leave **Required** checked if the model must always send it.
5. In **Description the model reads**, say what to send, with an example.
6. Fill in the type's limits: **Max length** for text, the values for a picklist, or **Minimum** and **Maximum** for a number. For a Group, click **Add input to this group**. For a List, choose what the list holds in **List of**.
7. Click **Save**. An input with a missing name or description is marked in red, and nothing is saved until you fix it.

To paste a schema instead, click **Edit as JSON**, paste it, and click **Apply**. When Core accepts it, the box closes and the inputs show in the list. A tool with no inputs saves as one that takes none.

## Errors

Core checks every save. Problems show on each field and in a summary next to **Save**.

## Change the layout

- To move or add a field, edit the object's page layout in Setup.
- To change a list's columns, edit the object's **All** list view.
