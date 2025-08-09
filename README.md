# Salesforce AI Agent Studio

## Overview

The Salesforce AI Agent Studio is a robust, enterprise-grade, and extensible platform for integrating advanced AI Agents, powered by Large Language Models (LLMs), directly within your Salesforce environment. It has evolved into a comprehensive suite for building sophisticated conversational assistants that can understand user intent, access relevant Salesforce data securely, perform complex multi-step processes, and provide intelligent, context-aware responses through a chat interface.

The framework is designed around a "clicks, not code" philosophy for orchestration, featuring a visual **Graph Builder** for defining complex, multi-step agent behaviors with conditional logic. It prioritizes robust security with features like **Run As User**, scalable asynchronous processing via Platform Events, and deep observability through a "flight recorder" style logging system. This allows technical teams to build, manage, and debug powerful AI-driven workflows entirely within the Salesforce ecosystem.

---

## Target Audience

This framework is designed for:

*   **Salesforce Administrators:** To declaratively build, configure, and manage powerful AI agents and their capabilities—including complex business processes using the visual Graph Builder—without writing Apex code.
*   **Salesforce Developers:** To extend the framework with custom actions (`IAgentAction`), context providers (`IAgentContextProvider`), and LLM integrations (`ILLMProviderAdapter`) to meet unique business requirements.
*   **Salesforce Architects:** To design and implement secure, scalable, and observable AI solutions that integrate seamlessly with the Salesforce platform's security and data models.

---

## Core Features & Capabilities

This framework is designed to empower teams to build, manage, and scale powerful AI assistants on the Salesforce platform. Its key features are focused on providing a balance of flexibility, control, and enterprise-grade reliability.

#### **Declarative Orchestration Engine (Graph Builder)**

*   **Visual Process Builder:** Define complex, multi-step agent workflows visually using the **Graph Builder**. Instead of rigid prerequisite chains, admins can create sophisticated flowcharts (`GraphNode__c`) with conditional branches (`ConditionalEdges__c`) to guide the agent's decision-making process, all without writing Apex code.
*   **Synchronous & Asynchronous Steps:** Seamlessly mix fast, synchronous actions with long-running, asynchronous tasks within a single graph. The framework's transaction control automatically manages state, pausing the graph to dispatch an async job and resuming it upon completion.
*   **Intelligent Error Recovery:** Configure how an agent behaves when a tool fails. The `HaltAndReportError__c` flag on a capability determines whether the agent stops and explains the problem to the user or receives the error as context to attempt an autonomous recovery with a different tool or approach.

#### **Intelligence & Actions**

*   **Intelligent Context Ledger:** The framework gives agents a persistent conversational memory (`ChatSession__c.EntityHistoryJson__c`) managed by the `ContextManagerService`. It uses relevance scoring and temporal decay to remember key records mentioned across interactions, ensuring users don't have to repeat themselves and the agent gets smarter as the conversation progresses.
*   **Built-in Managerial Approvals:** For high-stakes actions, require formal sign-off. The framework can automatically create a `HumanApprovalRequest__c` record and submit it into a standard Salesforce Approval Process, pausing the action until a manager approves or rejects it.
*   **Real-time "Thinking" Display:** Enhance the user experience with an optional streaming-like interface, powered by the `TransientMessage__e` Platform Event. Users can see the agent's intermediate thoughts in near real-time while it works on a longer task, making the interaction feel more dynamic and transparent.
*   **Advanced Search & Knowledge:** Standard actions like `FindEntities` and `SearchKnowledge` are powered by sophisticated backends featuring pattern analysis (`SearchPatternAnalyzer.cls`), intelligent scoring, and caching (`SearchResultCache.cls`) to deliver highly relevant results efficiently.

#### **Integration & Extensibility**

*   **Connect to Any AI Model:** The framework is not locked into one AI provider. Using the Adapter Pattern (`ILLMProviderAdapter` interface) and a simple `LLMConfiguration__c` record, you can connect to different Large Language Models (e.g., OpenAI, Anthropic, Google), allowing you to choose the best model for your needs.
*   **Create Any Custom Action:** Go beyond the powerful standard actions. The `BaseAgentAction` abstract class provides a simplified template for developers to build custom tools that interact with any part of Salesforce—or even external systems—by implementing a single `executeAction` method.
*   **Modular Prompt Engineering:** Structure prompts for maximum clarity and control. The `SystemPromptBuilder` composes the final system prompt from distinct, configurable parts on the `AIAgentDefinition__c` record, including `IdentityPrompt__c`, `InstructionsPrompt__c`, and `ExamplesPrompt__c`.

#### **Trust & Safety**

*   **Built on Salesforce Security:** The agent fundamentally respects your existing security model. It acts as the user, meaning it can only access data the user is permitted to see. The framework automatically enforces Sharing Rules, Profiles, and Field-Level Security (FLS) during every step.
*   **Delegated Execution with "Run As User":** Configure agents to run under a designated service account via the `RunAsUser__c` field on the `AIAgentDefinition__c`. This allows agents to perform actions with specific permissions while maintaining the security context of the original user for business logic.
*   **Scalable & Performant Processing:** The framework's architecture uses a highly scalable, event-driven model powered by the `AsyncFrameworkRequest__e` Platform Event. This ensures the agent remains responsive and avoids hitting governor limits even in high-volume organizations.

#### **Advanced Observability & Debugging**
*   **Orchestration "Flight Recorder":** A detailed `OrchestrationLogger` captures every step of an agent's decision-making process into the `OrchestrationLog__c` object. This provides deep, step-by-step visibility into prompt composition, tool selection, action execution, and graph transitions, making debugging complex interactions straightforward.
*   **Graph Execution Logs:** For graph-based capabilities, every node execution, state transition, and input/output is logged to `GraphExecutionLog__c`, providing a complete audit trail of the automated process.

---

## Architectural Layers

To better understand the framework, it's helpful to view it as two distinct but interconnected layers: the **Core Agent Framework** and the **Graph Orchestration Engine**.

1.  **The Core Agent Framework (Foundation)**
    This is the foundational layer responsible for all conversational AI interactions. It includes:
    *   Session and message management (`ChatSession__c`, `ChatMessage__c`).
    *   LLM connectivity and interaction (`LLMInteractionService`, `ILLMProviderAdapter`).
    *   Context gathering and prompt construction (`ContextManagerService`, `SystemPromptBuilder`).
    *   The execution of single-step **"Primitive" capabilities** (Standard, Apex, or Flow actions).

    You can build a fully functional, powerful conversational agent using only the Core Framework.

2.  **The Graph Orchestration Engine (Advanced Process Automation)**
    This is an advanced layer built *on top of* the Core Framework. It allows you to chain Primitive capabilities together to execute complex, multi-step business processes. It includes:
    *   **Backend Components:** The `GraphNode__c` object to define steps, and the `GraphExecutionService` to run the process.
    *   **Configuration:** An `AgentCapability__c` with `ImplementationType__c = 'Graph'` serves as the entry point.

    While the backend components for running graphs are included in this package, the **`graphBuilder` suite of Lightning Web Components is considered a separate, specialized design tool.** It is not part of the core runtime framework itself but is a purpose-built UI for administrators to visually configure the Graph Orchestration Engine. This separation ensures the core agent runtime remains lean while providing powerful visual tooling for those who need it.

---

## Architecture & Key Concepts

This AI Agent framework is built on several modern design patterns to ensure flexibility, scalability, and maintainability:

*   **Configuration First:** Core behavior is defined in Custom Objects (`AIAgentDefinition__c`, `LLMConfiguration__c`, `AgentCapability__c`, `GraphNode__c`) and Custom Metadata (`StandardActionHandler__mdt`, `SObjectConfig__mdt`). This makes the framework highly adaptable.
*   **Decoupled Asynchronous Processing:** Logic classes (`AsyncActionProcessor`, `FollowUpLLMProcessor`, `GraphExecutionService`) are separated from their invocation mechanism. The `AsyncFrameworkRequest__e` Platform Event is the primary transport, handled by `AsyncFrameworkRequestTriggerHandler`, ensuring scalability.
*   **Strategy Pattern for Response Handling:** The `OrchestrationService` uses a factory method to select the correct strategy (`ToolCallResponseHandler` or `ContentResponseHandler`) based on the LLM's output.
*   **Centralized Prompt & Context Composition:** `SystemPromptBuilder` assembles the final system prompt. `ContextResolverService` uses the `ContextManagerService` (the "Ledger") to orchestrate the gathering of all relevant data from multiple `IAgentContextProvider` implementations in a bulk-safe way.
*   **Template Method for Actions:** `BaseAgentAction` provides a simplified execution template, ensuring consistent error handling, validation, and result wrapping for all actions.
*   **Graph Execution Engine:** The `GraphExecutionService` manages the state and execution of multi-step graph-based capabilities, handling both synchronous node chains and asynchronous hand-offs.
*   **Event-Driven UI:** Platform Events (`AgentResponse__e`, `TransientMessage__e`) notify the LWC about final results and intermediate messages, decoupling the backend processing from the UI.

---

## Core Component Types

*   **Configuration:**
    *   Custom Objects: `AIAgentDefinition__c`, `LLMConfiguration__c`, `AgentCapability__c`, `AgentContextConfig__c`, `HumanApprovalRequest__c`, **`GraphNode__c`**.
    *   Custom Metadata: `StandardActionHandler__mdt`, `SObjectConfig__mdt`.
    *   Custom Settings: `AIAgentFrameworkSettings__c`.
*   **Services:** Apex classes handling specific tasks (Orchestration, LLM Interaction, Action Execution, **Graph Execution**, Context Resolution & Management, State, Persistence).
*   **Interfaces:** Define contracts for extensibility (`ILLMProviderAdapter`, `IAgentAction`, `IAgentContextProvider`).
*   **Action Framework:** `BaseAgentAction`, `ActionRegistry`, and standard action implementations (e.g., `ActionGetRecords`, `ActionRunReport`).
*   **Data Model:** `ChatSession__c`, `ChatMessage__c`, **`OrchestrationLog__c`**, **`GraphExecutionLog__c`**.
*   **Platform Events:** `AgentResponse__e`, `TransientMessage__e`, `AsyncFrameworkRequest__e`, **`UserContextSwitchEvent__e`**.
*   **Utilities:** Helpers for security, schema, parameters, retries, etc.
*   **LWC UI:** Includes `aiAssistantChat`, and the new **`graphBuilder`** suite of components.

---

## Administrator / Configurator Responsibilities
*   **Clear Instructions (Prompts & Descriptions):** The quality of `AIAgentDefinition__c` prompts (`IdentityPrompt__c`, `InstructionsPrompt__c`) and `AgentCapability__c.Description__c` is paramount. These must clearly define the agent's role, limitations, and how/when to use specific tools.
*   **Accurate Tool Schemas:** The `Parameters__c` JSON Schema on `AgentCapability__c` must accurately reflect the arguments the LLM needs to provide for an action.
*   **Graph Design:** Thoughtfully design `GraphNode__c` flows with logical conditional edges to guide the agent through robust business processes.
*   **Contextual Relevance:** Configure `AgentContextConfig__c` records effectively to provide necessary, but not excessive, information to the LLM to manage token usage.
*   **Security & Permissions:** Admins are responsible for assigning appropriate permissions to users for the framework objects, Apex classes, and the underlying data the agent might access. Configure the `RunAsUser__c` for agents requiring elevated or specific permissions.
*   **Named Credential Setup:** Correctly configure Named Credentials for LLM provider authentication. API keys must not be hardcoded.

---

## Execution Flow (Conceptual)

```mermaid
sequenceDiagram
    actor U as User
    participant UI as LWC Interface
    participant SF as Salesforce Agent Framework
    participant LLM as External LLM
    
    U->>UI: 1. Send Message
    UI->>SF: 2. AIAssistantController.sendMessage()
    SF->>SF: 3. Resolve Context & Prepare Prompt
    SF->>LLM: 4. Call LLM for next step
    LLM-->>SF: 5. LLM Response (Content or Tool Call)
    
    alt 6a. Content-Only Response
        SF->>SF: Save Messages & Finalize Turn
        SF-->>UI: 7a. Push Final Response (via AgentResponse__e)
        UI-->>U: Response delivered
    else 6b. Tool Call Requested
        SF->>SF: 7b. Dispatch Action/Graph
        
        alt Synchronous Action / Graph (Fast)
            SF->>SF: 8a. Execute Action or Graph Steps Synchronously
            note right of SF: Runs simple actions OR graph chains<br/>that don't require an async handoff.
            SF->>LLM: 9a. Follow-up with Final Result
            LLM-->>SF: 10a. Final Content Response
            SF->>SF: 11a. Save Messages & Finalize Turn
            SF-->>UI: 12a. Push Final Response (via AgentResponse__e)
            UI-->>U: Final response delivered
        else Asynchronous Action / Graph (Slow / Callout)
            SF->>SF: 8b. Enqueue Background Job
            note right of SF: For single async actions, graphs starting<br/>async, or graphs transitioning to async.
            SF-->>UI: 9b. Update Status to "Processing..."
            UI-->>U: Status update delivered
            
            note right of SF: Initial request ends. The rest happens in the background.
            
            SF->>SF: 10b. Background Job Executes Action/Graph Step(s)
            SF->>LLM: 11b. Follow-up with Result
            LLM-->>SF: 12b. Final Content Response
            SF->>SF: 13b. Save Messages & Finalize Turn
            SF-->>UI: 14b. Push Final Response (via AgentResponse__e)
            UI-->>U: Final response delivered
        end
    end
```
---

## Developer's Corner: Creating a Custom Action

Developers can easily extend the framework by creating custom Apex actions. By inheriting from `BaseAgentAction`, you get standardized error handling, validation, and result wrapping for free.

**Example: A custom action to get the current user's details.**

1.  **Create the Apex Class:**
    ```apex
    // File: classes/actions/ActionGetUserDetails.cls
    public class ActionGetUserDetails extends BaseAgentAction {
        // This is the only method you need to implement!
        public override Object executeAction(Map<String, Object> params) {
            // No input parameters are needed for this action.
            // The framework provides user context automatically via this.actionContext.
            Id userId = this.actionContext.originalUserId;

            User u = [SELECT Name, Email, Title, Department FROM User WHERE Id = :userId];
            
            // Return a simple map. The framework will wrap it in a standard success response.
            // The 'message' key will be used for the user-facing success message.
            return new Map<String, Object>{
                'message' => 'I have retrieved the current user\'s details.',
                'userDetails' => u
            };
        }
    }
    ```

2.  **Register as a Capability:** Create an `AgentCapability__c` record:
    *   **Capability Name:** `get_user_details`
    *   **Description:** "Retrieves the full name, email, title, and department of the current user."
    *   **Implementation Type:** `Apex`
    *   **Implementation Detail:** `ActionGetUserDetails`
    *   **Parameters:** `{"type": "object", "properties": {}}` (since no LLM input is needed).

---

## Configuration Deep Dive: JSON Examples

Here are examples of the key JSON configuration fields to help guide setup.

#### 1. `Parameters__c` (on AgentCapability__c)
Defines the inputs an action expects from the LLM. This uses a standard JSON Schema format.

**Example for an action that creates a Contact:**
```json
{
  "type": "object",
  "properties": {
    "lastName": {
      "type": "string",
      "description": "The last name of the contact."
    },
    "firstName": {
      "type": "string",
      "description": "The first name of the contact."
    },
    "email": {
      "type": "string",
      "description": "The primary email address of the contact."
    }
  },
  "required": ["lastName", "firstName"]
}
```

#### 2. `BackendConfiguration__c` (on AgentCapability__c)
Provides static, backend-only configuration to a standard action handler. The LLM never sees this.

**Example for a "CreateRecord" standard action to create a Contact:**
```json
{
  "objectApiName": "Contact",
  "defaultFieldValues": {
    "LeadSource": "AI Assistant"
  }
}
```

#### 3. `ConditionalEdges__c` (on GraphNode__c)
Defines the routing logic from one node to the next in a graph. The framework evaluates these in order.

**Example for a node that checks a case status:**
```json
[
  {
    "condition": "{!result.isSuccess} == true && {!node.check_case_status.output.Status} == 'Closed'",
    "nextNode": "send_survey_node"
  },
  {
    "condition": "{!result.isSuccess} == true",
    "nextNode": "escalate_case_node"
  },
  {
    "condition": "true",
    "nextNode": "handle_error_node"
  }
]
```

---

## Setup

1.  **Deploy All Components:** Deploy all metadata components in this repository. The `sfdx-project.json` is configured for standard source deployment.
2.  **Configure Named Credential:**
    *   Go to Setup -> Named Credentials -> External Credentials. Create a new one for your LLM provider.
    *   For OpenAI, set Authentication Protocol to "Custom" and add a Header with the name `Authorization` and the value `Bearer {!$Credential.OpenAI.APIKey}`.
    *   Create a Principal for your API key.
    *   Go to Setup -> Named Credentials -> Named Credentials. Create a new one. Link it to the External Credential you just created. The URL should be `https://api.openai.com`.
3.  **Configure `LLMConfiguration__c`:**
    *   Create at least one record specifying a `DeveloperName__c`, the `NamedCredential__c` from step 2, the `ProviderAdapterClass__c` (e.g., `OpenAIProviderAdapter`), and the `DefaultModelIdentifier__c`.
4.  **Configure `AIAgentDefinition__c`:**
    *   Create an agent record. Assign a `DeveloperName__c`, link it to an `LLMConfiguration__c`, and fill out the prompt fields (`IdentityPrompt__c`, `InstructionsPrompt__c`, etc.).
5.  **(Optional) Configure `StandardActionHandler__mdt`:**
    *   Verify records exist for standard actions like `GetRecords`, `CreateRecord`, etc., mapping them to their respective handler classes (e.g., `ActionGetRecords`). These should be deployed with the framework.
6.  **Configure `AgentCapability__c` records:**
    *   For each `AIAgentDefinition__c`, create `AgentCapability__c` records for the tools it should use.
    *   Critically, define `CapabilityName__c` (the function name for the LLM), `Description__c`, `ImplementationType__c` ('Standard', 'Apex', 'Flow', or **'Graph'**), and `Parameters__c` (JSON schema).
    *   Configure advanced options like `RequiresApproval__c`, `RunAsynchronously__c`, and `HaltAndReportError__c` as needed.
7.  **Configure `GraphNode__c` records (if using Graphs):**
    *   For any `AgentCapability__c` of type 'Graph', use the **Graph Builder** LWC (available on the capability's record page) to visually design the flow and create the underlying `GraphNode__c` records.
8.  **Configure `AIAgentFrameworkSettings__c` (Custom Setting):**
    *   Go to Setup -> Custom Settings -> AI Agent Framework Settings -> Manage. Configure global defaults.
9.  **Assign Permissions:**
    *   Grant users access to essential Custom Objects (CRUD as appropriate: `ChatSession__c`, `ChatMessage__c` for users; more for admins).
    *   Grant users access to the controller Apex class (`AIAssistantController`).
    *   Grant admins access to configuration objects and setup/debug LWCs.
10. **(Optional) Configure Approval Process:**
    *   If using the `RequiresApproval__c` feature, create a standard Salesforce Approval Process on the `HumanApprovalRequest__c` object.
11. **Add LWC to Page:** Add `aiAssistantChat` to a Lightning Record Page, App Page, or Utility Bar.

---

## Known Limitations & Potential Future Enhancements

*   **Current State:** The framework has robust backend logging (`OrchestrationLog__c`, `GraphExecutionLog__c`) that acts as a "flight recorder" for every agent turn.
*   **Potential Enhancement: Observability UI.** Create a dedicated LWC that visualizes the `OrchestrationLog__c` and `GraphExecutionLog__c` records. This would provide administrators with an interactive timeline of the agent's decision-making process, making it easier to debug complex interactions and graph executions without needing to write SOQL queries.

*   **Current State:** Context is managed by a sophisticated "Context Ledger" (`ContextManagerService`) that intelligently tracks Salesforce records with relevance scoring.
*   **Potential Enhancement: Native Retrieval-Augmented Generation (RAG).** Integrate with a Vector Database to allow the agent to perform semantic searches against external knowledge bases (e.g., documentation, help articles). This would augment the agent's knowledge beyond what is stored in Salesforce records, enabling it to answer a wider range of questions.

*   **Current State:** Asynchronous processing relies on Salesforce Platform Events, which are highly scalable but offer limited out-of-the-box monitoring for specific job statuses.
*   **Potential Enhancement: Proactive Session Monitoring.** Implement a Scheduled Apex job that runs periodically to check for `ChatSession__c` records that may have become "stuck" in a processing state (e.g., `Awaiting Action`) due to an unhandled platform-level error. The job could reset these sessions to a `Failed` state and notify an administrator.

*   **Current State:** An `AIAgentDefinition__c` is statically linked to a single `LLMConfiguration__c`.
*   **Potential Enhancement: Dynamic LLM Routing.** Develop an advanced routing mechanism that allows a single agent to choose the most appropriate LLM model (or even provider) on-the-fly based on the complexity, cost, or specific requirements of the user's prompt. For example, using a small, fast model for simple queries and a larger, more powerful model for complex reasoning tasks.

*   **Current State:** Configuration of Primitive capabilities and Context Providers is done through standard Salesforce record edit pages.
*   **Potential Enhancement: Guided Configuration Wizards.** Develop LWCs to provide a guided setup experience for creating `AgentCapability__c` and `AgentContextConfig__c` records. These wizards could help admins correctly format JSON schemas and provide real-time validation, reducing configuration errors.

---

## ⚠️ Important Disclaimer

This AI Agent Framework is provided "as is" and "with all faults." The developers make no warranties, express or implied, and hereby disclaim all other warranties, including without limitation, any implied warranties of merchantability, fitness for a particular purpose, or non-infringement.

**Use at Your Own Risk:**
*   **AI-Generated Content:** Responses and actions are driven by a Large Language Model (LLM) and may be inaccurate, incomplete, or inappropriate. **All AI-generated output should be independently verified before being relied upon.**
*   **Automated Actions:** The agent can perform actions that modify data within your Salesforce organization (e.g., creating/updating records, posting to Chatter). You are solely responsible for configuring the agent's capabilities and for any actions it performs.
*   **No Liability:** In no event shall the authors or copyright holders be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software.

It is your responsibility to test this framework thoroughly in a sandbox environment and to configure its permissions and capabilities in a way that aligns with your organization's security and data governance policies.

---

## License

Copyright (c) 2025 Sonal

This source code is licensed under the **Mozilla Public License 2.0**. See the `LICENSE` file for details.