# Pluto Core

Pluto Core runs AI agents inside Salesforce. It sends work to a model, runs
the tools the model asks for, waits for approvals, recovers from failures, and
keeps a record of everything a run did. It needs no other package.

## Documentation

Setup and operations are in the [Pluto docs](https://iamsonal.github.io/aiAgentStudio/).

| To                                     | Read                                                                                               |
| -------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Install Core and turn on its schedules | [Install](https://iamsonal.github.io/aiAgentStudio/start/install/)                                 |
| Build and run a first agent            | [Your first agent](https://iamsonal.github.io/aiAgentStudio/start/first-agent/)                    |
| Create the user an agent runs as       | [Create an execution identity](https://iamsonal.github.io/aiAgentStudio/setup/execution-identity/) |
| Assign permission sets                 | [Give people access](https://iamsonal.github.io/aiAgentStudio/setup/permissions/)                  |
| Start runs from Flow or Apex           | [Start a run](https://iamsonal.github.io/aiAgentStudio/run/start/)                                 |
| Fix a run that stopped                 | [Fix a stuck run](https://iamsonal.github.io/aiAgentStudio/operate/stuck-run/)                     |
| Plan for limits and cost               | [Limits and cost](https://iamsonal.github.io/aiAgentStudio/operate/limits/)                        |

Developers who add tools, model providers, context, or policies follow the
[extension contract](contracts/EXTENSIONS.md).
