# Pluto Model Adapters

Ready-made model connections for Pluto Core, so an agent can run without
custom Apex.

| Provider | Adapter class                  | Named Credential | External Credential |
| -------- | ------------------------------ | ---------------- | ------------------- |
| OpenAI   | `OpenAIResponsesModelProvider` | `OpenAI_API`     | `OpenAIEC`          |

The same adapter works with Azure OpenAI and any other endpoint that serves
the OpenAI Responses API. To set one up, see
[Connect a model](https://iamsonal.github.io/aiAgentStudio/setup/model/). For another provider API, write an
`IModelProvider` class and follow the
[extension contract](../force-app/contracts/EXTENSIONS.md).
