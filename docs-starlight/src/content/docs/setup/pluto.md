---
title: Install Pluto Console
description: Install Pluto Console, the admin console, assign it, and know what it changes in your org.
---

Pluto Console is the admin console for Pluto Core. It edits Core's setup records, shows each run step by step, and lets operators rescue runs. It keeps no state of its own. Core runs without it.

Pluto Console installs on Pluto Core alone.

## Install

1. Install Pluto Core and turn on its schedules. See [Install](/start/install/).
2. Install Pluto Console from the same page.
3. Assign `PlutoAdmin` and `AgentKernelAdmin` to admins.
4. Optional: add the **Agent Core Health** card to an app or home page that operators use.

Pluto Console applies each user's sharing and field access. Core still checks every save.

## What Pluto Console changes in your org

Pluto Console changes no buttons on Core's objects. In the Pluto app, Agent Definition, Agent Tool, Agent Context Provider, and Agent Execution Identity records open on Pluto record pages on desktop. Other apps and the Salesforce mobile app show the standard record pages.

On a Pluto record page, **Edit** opens the Pluto editor. **New** opens the standard Salesforce form. Core checks the record when you save it.

## Change a page

- To move or add a field, edit the object's page layout in Setup. The Pluto editor follows the layout assigned to the user.
- To change a record page, open it in Lightning App Builder. Upgrading Pluto Console puts back the shipped page.
- To change a setup list's columns, open the object's **All** list view and use **Select Fields to Display**. Refresh Pluto Console afterwards.

## Remove Pluto Console

1. In Setup, open **Installed Packages**.
2. Uninstall Pluto Console.
