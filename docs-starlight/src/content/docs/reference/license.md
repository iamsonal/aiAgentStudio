---
title: License
description: What the AGPL-3.0-only license lets you do with Pluto, and what it asks of you.
---

Pluto is licensed under the [GNU Affero General Public License, version 3 only](https://github.com/iamsonal/aiAgentStudio/blob/main/LICENSE) (AGPL-3.0-only), with the [Pluto Extension Exception](https://github.com/iamsonal/aiAgentStudio/blob/main/LICENSE-EXCEPTION). Copyright (c) 2026 Sonal.

The license covers Pluto Core, Pluto Model Adapters, and Pluto Console. The full text in the LICENSE and LICENSE-EXCEPTION files is what counts. This page explains it in plain words and is not legal advice.

## What you may do

1. Install the packages in any org, including production, at no cost.
2. Use Pluto for work, including for your customers.
3. Read, change, and share the code.

## What the license asks of you

| What you do                                                             | What you must do                                                                                                                                                      |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Install the packages unchanged                                          | Nothing.                                                                                                                                                              |
| Change Pluto's code and use it only yourself                            | Nothing, as long as no one else uses your changed version.                                                                                                            |
| Change Pluto's code, and people use your changed version over a network | Offer those people the full source of your changed version under the AGPL. This includes users in your Salesforce org and people who reach an agent by email or chat. |
| Share a changed version, for example as your own package                | Share its full source under the AGPL, with the license and the copyright notices.                                                                                     |
| Write your own extension that uses only Pluto's public interface        | Nothing. Your extension can use any license and stay private.                                                                                                         |

Every source file carries a copyright and license notice. Keep it when you copy or change a file.

## Custom tools and other extensions

The Pluto Extension Exception lets your own code stay private. It covers code that uses Pluto only through its public interface:

1. Apex types and methods that Pluto declares as `global`, such as `ITool`, `IModelProvider`, `IContextProvider`, and `IToolAuthorizationPolicy`.
2. Invocable actions and platform events that Pluto ships.
3. Custom objects, fields, and custom metadata types that Pluto ships.
4. The rules in the [extension contract](/extend/contract/).

Such code can use any license. You do not have to share its source, even when people use it over a network. This is true when it runs in the same org, is called by Pluto, or is deployed in the same package.

The exception does not cover changes to Pluto's own files, or a copy of Pluto code inside your class. Those stay under the AGPL. If your extension needs a Pluto class that is not `global`, open an issue to ask for a public interface instead of changing Pluto.

## Name and logo

The license covers the code only. It does not let you use the Pluto name or logo for a fork or a product. See [Trademarks](https://github.com/iamsonal/aiAgentStudio/blob/main/TRADEMARKS.md).

## Contributions

Each author signs the [Pluto Contributor License Agreement](https://github.com/iamsonal/aiAgentStudio/blob/main/CLA.md) once, before their first pull request is merged. Authors keep the copyright to their work. The agreement lets the maintainer release it under other licenses as well as the AGPL.

## Earlier versions

Versions released before the change to the AGPL stay under the Mozilla Public License 2.0. The AGPL applies to each release from the change on.
