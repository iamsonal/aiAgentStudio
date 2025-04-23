# Salesforce AI Agent Framework

## Overview

This Salesforce AI Agent Framework provides a robust and extensible platform for integrating advanced AI Agents, powered by Large Language Models (LLMs), directly within your Salesforce environment. It enables the creation of sophisticated conversational assistants that can understand user intent, access relevant Salesforce data securely, perform actions within Salesforce (like creating/updating records, posting to Chatter), and provide intelligent responses through a chat interface.

The framework prioritizes configurability, security, asynchronous processing, and observability, allowing technical teams to build, manage, and debug AI-driven workflows effectively.

---

## Core Features & Capabilities

*   **Reliable & Configurable:** Define agent personas, LLM connections, context rules, and actions declaratively using Salesforce objects/metadata. Crucially, the framework includes robust validation triggers and utilities to ensure configuration quality and prevent common setup errors, reducing runtime issues. Includes detailed field descriptions and help texts to simplify setup and maintenance.
*   **Asynchronous Architecture & Managed Execution:** Handles LLM API calls and complex actions in the background using Salesforce Queueables (and optional Platform Events). Actively manages state transitions and job dependencies for multi-step interactions, preventing timeouts and ensuring a responsive user interface. Includes logic to handle potentially stale background jobs.
*   **Extensible by Design:**
    *   **LLM Agnostic (Adapter Pattern):** Integrate with various LLM providers (like OpenAI, Anthropic, etc.) by implementing a standard `ILLMProviderAdapter` interface. An OpenAI adapter is included.
    *   **Custom Actions:** Extend agent capabilities beyond the included standard actions (Get/Create/Update Records, Chatter, Flow, etc.) by creating custom Apex classes (`IAgentAction`).
    *   **Custom Context:** Implement custom Apex logic (`IAgentContextProvider`) to fetch and structure complex or proprietary data for the agent, supplementing the declarative context rules. Examples include providers for relevant Salesforce Knowledge Articles, a user's recent activity across records, or complex calculated metrics.
*   **Security Integrated:** Operates securely within Salesforce's sharing model. Automatically enforces Object permissions (CRUD) and Field-Level Security (FLS) during context gathering and action execution (e.g., `WITH USER_MODE`, internal checks), ensuring agents only see and modify data the user is permitted to access.
*   **Intelligent Context Gathering & Schema Awareness:** Define rules (`ContextGraphSource__c`) to automatically pull relevant data based on the record the user is viewing or the user themselves. Supports traversing relationships (parent/child) and applying filters/ordering.
*   **Standardized Tool/Action Framework:** Configure actions (tools) with clear descriptions and structured input parameters (JSON Schema) for the LLM, enabling reliable function calling. The framework provides a `BaseAgentAction` class and utility helpers (`ActionParamUtils`, `SecurityUtils`) promoting consistent, secure, and maintainable development of both standard and custom actions.
*   **Built-in Observability & Turn-Based Debugging:** Detailed logging (`OrchestrationLog__c`) captures each step of the agent's processing turn. Manages the end-to-end processing of a single user message as a distinct 'turn' (tracked by `TurnIdentifier__c`), enabling reliable correlation of asynchronous steps. Note: A sample LWC (`chatSessionVisualizer`) for visualizing logs is provided but considered optional (see Architecture section).
*   **Ready-to-Use UI:** Includes a sample chat LWC (`aiAssistantChat`) providing a foundation for user interaction. *Note: This is considered optional (see Architecture section).*
*   **Robust Error Handling:** The framework includes retry logic for LLM callouts and standardized error handling within the action execution base class.
*   **Potential for Interaction Refinements:** While the current focus is direct execution, future patterns could be implemented to allow the agent to ask the user clarifying questions if the LLM is unsure about action parameters or the exact tool required, preventing execution errors due to ambiguity.

---

## Architecture & Key Concepts

This framework employs several key architectural principles:

1.  **Configuration-Driven Engine:** At its heart, the framework uses Salesforce metadata (Custom Objects, Metadata Types, Custom Settings) to define how an agent behaves, what data it can access, and what actions it can perform. This decouples the agent's capabilities from the core orchestration code.
    *   `AIAgentDefinition__c` defines *the agent*.
    *   `LLMConfiguration__c` defines *the connection to the LLM*.
    *   `ActionDefinition__c` defines *reusable backend logic* (an action).
    *   `AgentCapabilityBinding__c` defines *how a specific agent uses* a specific action (what the LLM sees).
    *   `ContextGraphSource__c` defines *a rule for getting specific data*.
    *   `AgentContextBinding__c` links *an agent to the context rules* it should use.
2.  **Asynchronous Orchestration:** To handle the potential latency of LLM calls and action executions, the processing of a user message (a "turn") is managed by a chain of asynchronous Apex Queueable jobs. This prevents blocking the user interface and avoids hitting Salesforce synchronous limits.
3.  **State Machine:** The `ChatSession__c` object acts as a state machine, tracking the progress of each turn (e.g., `AwaitingLLMResponse`, `ExecutingActions`, `Idle`, `Failed`) via the `ProcessingStatus__c` field. A dedicated service (`ChatSessionStateService`) manages state transitions atomically to prevent race conditions.
4.  **Event-Driven Decoupling (Optional):** For complex interactions involving multiple back-and-forth steps between the LLM and actions, an optional Platform Event mechanism can be enabled (`AIAgentFrameworkSettings__c.MitigateChainingLimitsViaEvent__c`). This further breaks down the asynchronous chain, which can be **essential in developer/scratch orgs** due to stricter governor limits on Queueable chaining.
5.  **Modular Interfaces:** Core components like LLM communication (`ILLMProviderAdapter`), action execution (`IAgentAction`), and context provision (`IAgentContextProvider`) are defined by interfaces, allowing for custom implementations to be easily integrated.
6.  **Separated Data Model:** Conversation history (`ChatMessage__c`) and processing state (`ChatSession__c`) are stored separately from the configuration and execution logic, allowing for clear data management and auditing.
7.  **Separation of Core Framework and UI/Setup Tooling:** To maintain a clear separation of concerns and keep the core framework lightweight and modular, Lightning pages, LWC visualizers (like the Session and Context Graph Visualizers mentioned below), and setup assistants are intentionally excluded from this repository. These components are highly implementation-specific and are better suited as optional, pluggable extensions that can be developed or customized based on individual project needs. By doing this, the framework remains focused on its primary purpose—enabling powerful AI agents within Salesforce—without being tied to a specific UI or setup flow. This approach promotes flexibility, encourages best practices in enterprise architecture, and allows teams to integrate their own visual layers or setup tooling as needed.

---

## Core Components (Simplified View)

*   **Configuration:** Managed through Custom Objects (`AIAgentDefinition__c`, `LLMConfiguration__c`, `ActionDefinition__c`, `AgentCapabilityBinding__c`, `ContextGraphSource__c`, `AgentContextBinding__c`), Custom Metadata (`StandardActionHandler__mdt`), and Custom Settings (`AIAgentFrameworkSettings__c`).
*   **Orchestration Engine:** A series of Apex Queueable classes (`PrepareLLMCallQueueable`, `ExecuteLLMCallQueueable`, `ExecuteActionsQueueable`, `FinalizeTurnQueueable`) that manage the step-by-step processing of a user request. Includes `ChatSessionStateService` for managing state.
*   **LLM Integration:** Components responsible for communicating with the LLM provider API (`ILLMProviderAdapter` interface, `OpenAIProviderAdapter` implementation, `LLMProviderFactory`).
*   **Action Framework:** Enables agents to perform tasks (`IAgentAction` interface, `BaseAgentAction` abstract class, `ActionRegistry` factory, Standard Action implementations).
*   **Context Framework:** Gathers relevant Salesforce data (`ContextService`, `IAgentContextProvider` interface, `ContextQueryBuilder`).
*   **Data Model:** Stores conversation history and state (`ChatSession__c`, `ChatMessage__c`).
*   **Observability:** Logs detailed execution steps for debugging (`OrchestrationLog__c`).
*   **User Interface (Optional Samples):** Sample chat component (`aiAssistantChat` LWC) and a debug visualizer (`chatSessionVisualizer` LWC) are provided but are considered optional extensions, not core framework requirements.

---

## The Role of the Administrator / Configurator

While the framework provides the engine, the power and effectiveness of an AI Agent built with it largely depend on the configuration provided by Salesforce Administrators or technical configurators.

*   **Clear Instructions are Key:** The quality of the `System Prompt__c` on `AIAgentDefinition__c` and the `Description__c` fields on `AgentCapabilityBinding__c` (which describe actions/tools to the LLM) is paramount. These fields need to clearly articulate the agent's role, limitations, and precisely *when* and *why* it should use a specific capability (action). Vague or ambiguous instructions will lead to poor LLM performance and incorrect tool usage.
*   **Understanding Context:** Configuring `ContextGraphSource__c` records effectively requires understanding the data model and how different pieces of information relate to user or record context. Well-defined context ensures the LLM has the necessary information without being overloaded.
*   **Token Awareness:** Remember that everything sent to the LLM (prompts, context, message history, tool definitions) consumes tokens, which often translates to cost and can impact performance limits. Admins should be mindful of keeping prompts, descriptions, and context concise yet effective to minimize token usage. Prioritize essential context and avoid including overly verbose or irrelevant data.

Effective agent configuration is an iterative process of defining capabilities, testing, and refining the instructions provided to the LLM.

---

## Getting Started / Setup

Follow these steps to deploy and configure the framework:

1.  **Deploy Components:** Deploy all Custom Objects, Fields, Apex Classes, Triggers, LWCs (if desired for sample UI/visualizer), Custom Metadata, and the Custom Setting (`AIAgentFrameworkSettings__c`) to your Salesforce org.

2.  **Field Set Prerequisites:** Ensure the Salesforce **Field Sets** referenced by any `ContextGraphSource__c` records you plan to use exist on the relevant SObjects. You can create these manually via the Object Manager in Setup.
    *   *(Optional Utility):* The repository includes an *example* utility class `AgentFrameworkFieldSetSetup` that can create *sample* Field Sets. Its usage might require specific permissions or one-time setup.

3.  **Configure Your Agent (Manual Setup):** The core of the setup involves creating configuration records. You can do this manually via Salesforce Setup or potentially build/use custom setup tools. This typically involves:
    *   **(A) LLM Configuration:** Create an `LLMConfiguration__c` record defining the LLM provider, model, adapter class (e.g., `OpenAIProviderAdapter`), and the Named Credential to use (see next step).
    *   **(B) Agent Definition:** Create an `AIAgentDefinition__c` record. Define the agent's persona (`SystemPrompt__c`), link it to the `LLMConfiguration__c` record, and set activation status.
    *   **(C) Action Definitions (Optional):** Create `ActionDefinition__c` records for each *reusable* action (Standard, Apex, or Flow) your agents will use, specifying the implementation type and details.
    *   **(D) Context Graph Sources (Optional):** Create `ContextGraphSource__c` records defining rules for fetching declarative context.
    *   **(E) Capability Bindings (Essential):** Link your `AIAgentDefinition__c` to `ActionDefinition__c` records via `AgentCapabilityBinding__c`. This defines *how the agent sees and uses the action* (name, description for LLM, optional config).
    *   **(F) Context Bindings (Optional):** Link your `AIAgentDefinition__c` to `ContextGraphSource__c` (or Recipes) using `AgentContextBinding__c` records to specify which context rules the agent uses.

4.  **Configure Named Credential:**
    *   Create an **External Credential** (Setup -> Security) for your LLM Provider. Configure authentication (e.g., Custom Header for API Key). Create a **Principal** linking the auth details.
    *   Create a **Named Credential** (Setup -> Security) matching the name referenced in your `LLMConfiguration__c`. Link it to the External Credential and set the URL to the LLM provider's API base (e.g., `https://api.openai.com`). **Do not hardcode API keys.**

5.  **Configure Framework Settings (IMPORTANT FOR DEV/SCRATCH ORGS):**
    *   Go to Setup -> Custom Settings -> AI Agent Framework Settings -> Manage -> New/Edit.
    *   **Check the "Use Decoupling for Complex Actions" (`MitigateChainingLimitsViaEvent__c`) checkbox, especially for non-production orgs to avoid queueable chaining limits.**
    *   Review and adjust other defaults (retries, turns, etc.) if needed. Save.

6.  **Assign Permissions:** Create and assign Permission Sets granting users access to:
    *   Framework Custom Objects (Read essential, CRUD as needed).
    *   Apex Classes (Controller, Queueables, Services, Adapters, Actions).
    *   LWCs (`aiAssistantChat`, `chatSessionVisualizer`) if using the optional sample UI.

7.  **Deploy LWC (Optional):** If using the sample UI, add `aiAssistantChat` to relevant Lightning Pages. Set the `agentDeveloperName` property in the LWC's configuration to match your `AIAgentDefinition__c` Developer Name.

8.  **(Optional Demo Data):** The repository contains utility classes (`AgentTestDataFactory`, `AgentFrameworkContextSourceSetup`) designed *solely for demonstration purposes* to create sample configurations and test data. They are not required for a manual setup. Execute them via Anonymous Apex only if you want to explore the pre-configured "SalesCopilot" example.

---

## Known Limitations & Potential Future Enhancements

While robust, the framework has areas for potential evolution and refinement:

*   **Multi-LLM Provider Strategy (Enhancement):** Currently, an agent is tied to one LLM Configuration. A key future enhancement would be to support more dynamic selection or routing to different LLM models (potentially from different providers) based on cost, complexity, or task suitability, potentially configured at the Agent Definition or even dynamically during orchestration.
*   **Refine State Management:** The asynchronous nature requires careful state management (`ProcessingStatus__c`). Future iterations could involve adding stricter state transition validation or monitoring for sessions stuck in intermediate states.
*   **Enhance Error Granularity & Debugging:** While logs exist, returning more specific error codes from Actions and improving the correlation of low-level failures (e.g., specific filter validation errors) up through the orchestration layer would aid debugging.
*   **Optimize Context Gathering:** For agents with many context sources, the current sequential gathering within the Queueable could be optimized, perhaps exploring parallel retrieval options (e.g., via `@future` methods or dedicated Queueables) if latency becomes an issue.
*   **Refine Tool Result Saving:** The current process saves all tool results before proceeding. Adding more granular error handling or options for partial success in the `ExecuteActionsQueueable` step could improve resilience in complex multi-tool scenarios.
*   **Improve LWC Resilience:** The sample LWC relies on Platform Events. Adding manual refresh/sync options or alternative status polling could make the UI more resilient to potential event delivery issues.
*   **Configuration UI:** As mentioned, a dedicated setup UI would greatly improve the ease of configuring and managing agents, actions, and context rules compared to manual record creation.

---

## Contributing

*(Placeholder - Add contribution guidelines if applicable).*

---

## License

*(Copyright (c) 2025 Sonal)*

This source code is licensed under the MIT license. See the LICENSE file for details.