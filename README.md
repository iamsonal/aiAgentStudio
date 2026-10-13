<p align="center">
    <img src="docs-starlight/src/assets/logo.svg" alt="Pluto logo" width="96">
</p>

<h1 align="center">Pluto</h1>

Pluto runs AI agents inside Salesforce, on standard Salesforce licenses, with
any model provider. Pluto Core is the engine. Every other package is optional.

| Package                                      | What it adds                                                            |
| -------------------------------------------- | ----------------------------------------------------------------------- |
| [Pluto Core](force-app)                      | The agent engine: runs, tools, approvals, recovery, and data protection |
| [Pluto Model Adapters](pluto-model-adapters) | Ready-made OpenAI connections                                           |
| [Pluto Console](pluto-console)               | Admin console: set up agents, follow runs, decide approvals             |

## Install

Pluto installs as unlocked packages. Try them in a sandbox first.

The current version is 2.0.

1. Open the [Install](https://iamsonal.github.io/aiAgentStudio/start/install/) page of the Pluto docs.
2. Install Pluto Core, then Pluto Model Adapters. Optionally install Pluto
   Console.
3. Turn on Core's recovery and retention schedules, as the Install page
   describes.
4. Follow [Your first agent](https://iamsonal.github.io/aiAgentStudio/start/first-agent/).

## Before you use it

- A model can be wrong. Try each agent in a sandbox first, and start with
  tools that only read records.
- To have a person check a change before it happens, check **Always Require
  Approval** on the tool. The agent never approves its own work. See
  [Require approval](https://iamsonal.github.io/aiAgentStudio/approvals/require/).
- Pluto sends the agent's instructions, the records its tools read, and tool
  results to the model provider you connect. Core first replaces email
  addresses, phone numbers, payment cards, US SSNs, IBANs, and classified
  fields with tokens. Names, street addresses, and other free text reach the
  model as written. See [Sensitive data](https://iamsonal.github.io/aiAgentStudio/data/sensitive/).
- By default a run stops at 10 model calls, 15 tool calls, or 250,000 tokens.
  Set prices on the Agent Model to see an estimated cost for each model call.
  See [Limits and cost](https://iamsonal.github.io/aiAgentStudio/operate/limits/).
- By default, Core clears a run's inputs, model requests and replies, and tool
  results 30 days after the run ends. See
  [Retention and erasure](https://iamsonal.github.io/aiAgentStudio/data/retention/).

## Documentation

1. The [Pluto docs](https://iamsonal.github.io/aiAgentStudio/) cover setup, building agents, and operations.
2. Developers who add tools, model providers, context, or policies follow the
   [extension contract](force-app/contracts/EXTENSIONS.md).
3. To report a security problem, see [Security](SECURITY.md).

## Official source

Pluto is free. The only official source is this repository and the packages
it publishes. Pluto is not sold on AppExchange. If you paid for a copy of
Pluto, or see it listed under another name, it did not come from this project.

## Support the project

To support Pluto's development, use
[GitHub Sponsors](https://github.com/sponsors/iamsonal) or
[Buy Me a Coffee](https://buymeacoffee.com/iamsonal).

## License

Pluto is licensed under the
[GNU Affero General Public License, version 3 only](LICENSE) (AGPL-3.0-only),
with the [Pluto Extension Exception](LICENSE-EXCEPTION). Copyright (c) 2026
Sonal.

1. You may use, change, and share the code, including at work.
2. If you share a changed version, you must share its full source under the
   AGPL.
3. If you change Pluto and people use your changed version over a network,
   you must offer those people its source. This includes users in a Salesforce
   org and people who reach an agent by email or chat.
4. Your own extensions can stay private. A custom tool, model provider,
   context provider, policy, Flow, or Apex class that uses only Pluto's global
   Apex, invocable actions, and shipped objects may use any license. The
   exception does not cover changes to Pluto's own files.
5. Every source file carries a copyright and license notice. Keep it.
6. The license does not cover the Pluto name or logo. See
   [Trademarks](TRADEMARKS.md).
7. Code from other projects keeps its own license. See
   [Third-party notices](THIRD-PARTY-NOTICES.md).

## Contributing

Each author signs the [Pluto Contributor License Agreement](CLA.md) once,
before their first pull request is merged. See
[Contributing](CONTRIBUTING.md).
