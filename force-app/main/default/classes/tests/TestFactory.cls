/**
 * @description Comprehensive test data factory for AI Agent Framework.
 *              Provides fluent builder patterns and utility methods for creating test data
 *              for all framework objects and standard Salesforce objects.
 *              Supports both in-memory and persisted data creation with relationship management.
 *
 * @usage
 *   // Simple usage
 *   TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();
 *
 *   // Builder pattern
 *   Account acc = TestFactory.newAccount()
 *       .withName('Test Corp')
 *       .withIndustry('Technology')
 *       .save();
 *
 *   // Bulk data
 *   List<Contact> contacts = TestFactory.createContacts(100).save();
 */
@IsTest
public class TestFactory {
    // ===================================================================================
    // FRAMEWORK OBJECTS - COMPLETE AGENT SETUP
    // ===================================================================================

    /**
     * @description Creates a complete agent setup with all dependencies
     * @return AgentSetupBuilder for fluent configuration
     */
    public static AgentSetupBuilder createFullAgentSetup() {
        return new AgentSetupBuilder();
    }

    /**
     * @description Fluent builder for complete agent setup
     */
    public class AgentSetupBuilder {
        private AgentSetup setup = new AgentSetup();

        public AgentSetupBuilder() {
            // Initialize with defaults
            setup.llmConfig = newLLMConfiguration().build();
            setup.agentDefinition = newAgentDefinition().build();
            setup.capabilities = new List<AgentCapability__c>();
            setup.contextConfigs = new List<AgentContextConfig__c>();
        }

        public AgentSetupBuilder withLLM(LLMConfiguration__c llm) {
            setup.llmConfig = llm;
            return this;
        }

        public AgentSetupBuilder withAgent(AIAgentDefinition__c agent) {
            setup.agentDefinition = agent;
            return this;
        }

        public AgentSetupBuilder withMemoryStrategy(String strategy) {
            setup.agentDefinition.MemoryStrategy__c = strategy;
            return this;
        }

        public AgentSetupBuilder withHistoryTurnLimit(Integer limitValue) {
            setup.agentDefinition.HistoryTurnLimit__c = limitValue;
            return this;
        }

        public AgentSetupBuilder withStandardActions() {
            setup.capabilities.addAll(createStandardCapabilities());
            return this;
        }

        public AgentSetupBuilder withCapability(AgentCapability__c capability) {
            setup.capabilities.add(capability);
            return this;
        }

        public AgentSetupBuilder withContextConfig(AgentContextConfig__c config) {
            setup.contextConfigs.add(config);
            return this;
        }

        public AgentSetup build() {
            return setup;
        }

        public AgentSetup save() {
            // Insert in correct order with relationships
            insert setup.llmConfig;

            setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
            insert setup.agentDefinition;

            for (AgentCapability__c cap : setup.capabilities) {
                cap.AIAgentDefinition__c = setup.agentDefinition.Id;
            }
            if (!setup.capabilities.isEmpty()) {
                insert setup.capabilities;
            }

            for (AgentContextConfig__c config : setup.contextConfigs) {
                config.AIAgentDefinition__c = setup.agentDefinition.Id;
            }
            if (!setup.contextConfigs.isEmpty()) {
                insert setup.contextConfigs;
            }

            // Create agent execution
            setup.agentExecution = new AgentExecution__c(
                User__c = UserInfo.getUserId(),
                AIAgentDefinition__c = setup.agentDefinition.Id,
                ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                ExecutionType__c = 'Conversational'
            );
            insert setup.agentExecution;

            return setup;
        }
    }

    // ===================================================================================
    // FRAMEWORK OBJECTS - FUNCTION AGENT SETUP
    // ===================================================================================

    public static FunctionAgentSetupBuilder createFunctionAgentSetup() {
        return new FunctionAgentSetupBuilder();
    }

    public class FunctionAgentSetupBuilder {
        private FunctionAgentSetup setup = new FunctionAgentSetup();
        private Boolean createExecution = false;

        public FunctionAgentSetupBuilder() {
            setup.llmConfig = newLLMConfiguration().build();
            setup.agentDefinition = newAgentDefinition().withType('Function').build();
            setup.capabilities = new List<AgentCapability__c>();
        }

        public FunctionAgentSetupBuilder withLLM(LLMConfiguration__c llm) {
            setup.llmConfig = llm;
            return this;
        }

        public FunctionAgentSetupBuilder withAgent(AIAgentDefinition__c agent) {
            setup.agentDefinition = agent;
            return this;
        }

        public FunctionAgentSetupBuilder withAuditLevel(String auditLevel) {
            setup.agentDefinition.AuditLevel__c = auditLevel;
            return this;
        }

        public FunctionAgentSetupBuilder withCapability(AgentCapability__c capability) {
            setup.capabilities.add(capability);
            return this;
        }

        public FunctionAgentSetupBuilder withStandardActions() {
            setup.capabilities.addAll(createStandardCapabilities());
            return this;
        }

        public FunctionAgentSetupBuilder withExecution() {
            createExecution = true;
            return this;
        }

        public FunctionAgentSetup save() {
            insert setup.llmConfig;

            setup.agentDefinition.LLMConfiguration__c = setup.llmConfig.Id;
            insert setup.agentDefinition;

            for (AgentCapability__c cap : setup.capabilities) {
                cap.AIAgentDefinition__c = setup.agentDefinition.Id;
            }
            if (!setup.capabilities.isEmpty()) {
                insert setup.capabilities;
            }

            if (createExecution) {
                setup.execution = new AgentExecution__c(
                    User__c = UserInfo.getUserId(),
                    AIAgentDefinition__c = setup.agentDefinition.Id,
                    ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                    ExecutionType__c = 'Function'
                );
                insert setup.execution;
            }

            return setup;
        }
    }

    // ===================================================================================
    // FRAMEWORK OBJECTS - WORKFLOW SETUP
    // ===================================================================================

    public static WorkflowSetupBuilder createWorkflowSetup() {
        return new WorkflowSetupBuilder();
    }

    public class WorkflowSetupBuilder {
        private WorkflowSetup setup = new WorkflowSetup();
        private Integer stepCount = 2;
        private Boolean createExecution = false;

        public WorkflowSetupBuilder() {
            setup.llmConfig = newLLMConfiguration().build();
            setup.workflowAgent = newAgentDefinition().withType('Workflow').build();
            setup.childAgents = new List<AIAgentDefinition__c>();
            setup.steps = new List<AgentWorkflowStep__c>();
        }

        public WorkflowSetupBuilder withLLM(LLMConfiguration__c llm) {
            setup.llmConfig = llm;
            return this;
        }

        public WorkflowSetupBuilder withWorkflowAgent(AIAgentDefinition__c workflowAgent) {
            setup.workflowAgent = workflowAgent;
            return this;
        }

        public WorkflowSetupBuilder withStepCount(Integer count) {
            stepCount = count;
            return this;
        }

        public WorkflowSetupBuilder withChildAgent(AIAgentDefinition__c childAgent) {
            setup.childAgents.add(childAgent);
            return this;
        }

        public WorkflowSetupBuilder withExecution() {
            createExecution = true;
            return this;
        }

        public WorkflowSetup save() {
            insert setup.llmConfig;

            setup.workflowAgent.LLMConfiguration__c = setup.llmConfig.Id;
            insert setup.workflowAgent;

            if (setup.childAgents.isEmpty()) {
                for (Integer i = 1; i <= stepCount; i++) {
                    AIAgentDefinition__c childAgent = newAgentDefinition()
                        .withName('Workflow_Step_' + i + '_' + generateRandomString(6))
                        .withType('Function')
                        .withLLM(setup.llmConfig.Id)
                        .build();
                    setup.childAgents.add(childAgent);
                }
            }

            insert setup.childAgents;

            Integer order = 1;
            for (AIAgentDefinition__c child : setup.childAgents) {
                setup.steps.add(
                    new AgentWorkflowStep__c(WorkflowAgent__c = setup.workflowAgent.Id, ChildAgent__c = child.Id, ExecutionOrder__c = order, IsActive__c = true)
                );
                order++;
            }
            if (!setup.steps.isEmpty()) {
                insert setup.steps;
            }

            if (createExecution) {
                setup.execution = new AgentExecution__c(
                    User__c = UserInfo.getUserId(),
                    AIAgentDefinition__c = setup.workflowAgent.Id,
                    ProcessingStatus__c = AIAgentConstants.STATUS_IDLE,
                    ExecutionType__c = 'Workflow'
                );
                insert setup.execution;
            }

            return setup;
        }
    }

    // ===================================================================================
    // LLM CONFIGURATION BUILDERS
    // ===================================================================================

    public static LLMConfigurationBuilder newLLMConfiguration() {
        return new LLMConfigurationBuilder();
    }

    public class LLMConfigurationBuilder {
        private LLMConfiguration__c record = new LLMConfiguration__c(
            Name = 'Test LLM ' + generateRandomString(6),
            DeveloperName__c = 'Test_LLM_' + generateRandomString(6),
            ProviderAdapterClass__c = 'OpenAIProviderAdapter',
            NamedCredential__c = 'OpenAI_API_Test',
            DefaultModelIdentifier__c = 'gpt-4o-mini',
            IsActive__c = true,
            DefaultTemperature__c = 0.7
        );

        public LLMConfigurationBuilder withName(String name) {
            record.Name = name;
            return this;
        }

        public LLMConfigurationBuilder withProvider(String providerClass) {
            record.ProviderAdapterClass__c = providerClass;
            return this;
        }

        public LLMConfigurationBuilder withModel(String model) {
            record.DefaultModelIdentifier__c = model;
            return this;
        }

        public LLMConfigurationBuilder withTemperature(Decimal temp) {
            record.DefaultTemperature__c = temp;
            return this;
        }

        public LLMConfigurationBuilder inactive() {
            record.IsActive__c = false;
            return this;
        }

        public LLMConfiguration__c build() {
            return record;
        }

        public LLMConfiguration__c save() {
            insert record;
            return record;
        }
    }

    // ===================================================================================
    // AGENT DEFINITION BUILDERS
    // ===================================================================================

    public static AgentDefinitionBuilder newAgentDefinition() {
        return new AgentDefinitionBuilder();
    }

    public class AgentDefinitionBuilder {
        private AIAgentDefinition__c record = new AIAgentDefinition__c(
            Name = 'Test Agent ' + generateRandomString(6),
            DeveloperName__c = 'Test_Agent_' + generateRandomString(6),
            WelcomeMessageTemplate__c = 'Hello {User.FirstName}, how can I help you today?',
            IsActive__c = true,
            AgentType__c = 'Conversational',
            MemoryStrategy__c = 'Buffer Window',
            HistoryTurnLimit__c = 10,
            EnableParallelToolCalling__c = true,
            AsyncDispatchType__c = 'High'
        );

        public AgentDefinitionBuilder withName(String name) {
            record.Name = name;
            record.DeveloperName__c = name.replaceAll('\\W', '_');
            return this;
        }

        public AgentDefinitionBuilder withLLM(Id llmId) {
            record.LLMConfiguration__c = llmId;
            return this;
        }

        public AgentDefinitionBuilder withType(String agentType) {
            record.AgentType__c = agentType;
            return this;
        }

        public AgentDefinitionBuilder withMemoryStrategy(String strategy) {
            record.MemoryStrategy__c = strategy;
            return this;
        }

        public AgentDefinitionBuilder withHistoryTurnLimit(Integer limitValue) {
            record.HistoryTurnLimit__c = limitValue;
            return this;
        }

        public AgentDefinitionBuilder withSequentialTools() {
            record.EnableParallelToolCalling__c = false;
            return this;
        }

        public AgentDefinitionBuilder withAsyncDispatchType(String dispatchType) {
            record.AsyncDispatchType__c = dispatchType;
            return this;
        }

        public AgentDefinitionBuilder withAuditLevel(String auditLevel) {
            record.AuditLevel__c = auditLevel;
            return this;
        }

        public AgentDefinitionBuilder inactive() {
            record.IsActive__c = false;
            return this;
        }

        public AIAgentDefinition__c build() {
            return record;
        }

        public AIAgentDefinition__c save() {
            insert record;
            return record;
        }
    }

    // ===================================================================================
    // AGENT CAPABILITY BUILDERS
    // ===================================================================================

    /**
     * @description Creates standard capabilities for all action types
     */
    public static List<AgentCapability__c> createStandardCapabilities() {
        return new List<AgentCapability__c>{
            newCapability().forCreateRecord('Opportunity').build(),
            newCapability().forUpdateRecord('Account').build(),
            newCapability().forGetRecords('Contact').build(),
            // FindEntities removed - action class doesn't exist
            newCapability().forPostChatter().build(),
            newCapability().forSearchKnowledge().build(),
            newCapability().forFlowHandler('Test_Flow').build()
        };
    }

    public static CapabilityBuilder newCapability() {
        return new CapabilityBuilder();
    }

    public class CapabilityBuilder {
        private AgentCapability__c record = new AgentCapability__c(
            CapabilityName__c = 'test_capability_' + generateRandomString(6),
            Description__c = 'Test capability for unit testing',
            ExposureLevel__c = 'External',
            RunAsynchronously__c = false
        );

        public CapabilityBuilder withAgent(Id agentId) {
            record.AIAgentDefinition__c = agentId;
            return this;
        }

        public CapabilityBuilder withName(String name) {
            record.CapabilityName__c = name;
            return this;
        }

        public CapabilityBuilder withDescription(String description) {
            record.Description__c = description;
            return this;
        }

        public CapabilityBuilder async() {
            record.RunAsynchronously__c = true;
            return this;
        }

        public CapabilityBuilder requiresApproval() {
            record.HITLMode__c = 'Approval';
            return this;
        }

        public CapabilityBuilder withHITLMode(String mode) {
            record.HITLMode__c = mode;
            return this;
        }

        // Action-specific builders
        public CapabilityBuilder forCreateRecord(String objectName) {
            record.CapabilityName__c = 'create_' + objectName.toLowerCase();
            record.Description__c = 'Creates a new ' + objectName + ' record';
            record.ImplementationType__c = 'Standard';
            record.StandardActionType__c = 'CreateRecord';
            record.BackendConfiguration__c = '{"objectApiName":"' + objectName + '"}';
            record.Parameters__c = '{"type":"object","properties":{"recordData":{"type":"object","additionalProperties":true}},"required":[]}';
            return this;
        }

        public CapabilityBuilder forUpdateRecord(String objectName) {
            record.CapabilityName__c = 'update_' + objectName.toLowerCase();
            record.Description__c = 'Updates an existing ' + objectName + ' record';
            record.ImplementationType__c = 'Standard';
            record.StandardActionType__c = 'UpdateRecord';
            record.BackendConfiguration__c = '{}';
            record.Parameters__c = '{"type":"object","properties":{"recordId":{"type":"string","format":"salesforce-id"},"recordData":{"type":"object","additionalProperties":true}},"required":["recordId","recordData"]}';
            return this;
        }

        public CapabilityBuilder forGetRecords(String objectName) {
            return forGetRecordDetails(objectName, new List<String>{ 'Id', 'Name' });
        }

        public CapabilityBuilder forGetRecordDetails(String objectName, List<String> defaultFields) {
            record.CapabilityName__c = 'get_' + objectName.toLowerCase() + '_details';
            record.Description__c = 'Retrieves ' + objectName + ' record details';
            record.ImplementationType__c = 'Standard';
            record.StandardActionType__c = 'GetRecordDetails';
            record.BackendConfiguration__c = '{"objectApiName":"' + objectName + '","defaultFields":' + JSON.serialize(defaultFields) + '}';
            record.Parameters__c = '{"type":"object","properties":{"Id":{"type":"string","format":"salesforce-id"}},"additionalProperties":false}';
            return this;
        }

        public CapabilityBuilder forPostChatter() {
            record.CapabilityName__c = 'post_chatter';
            record.Description__c = 'Posts a message to Chatter';
            record.ImplementationType__c = 'Standard';
            record.StandardActionType__c = 'PostChatter';
            record.Parameters__c = '{"type":"object","properties":{"messageText":{"type":"string"},"topics":{"type":"array"}},"required":["messageText"]}';
            return this;
        }

        public CapabilityBuilder forSearchKnowledge() {
            record.CapabilityName__c = 'search_knowledge';
            record.Description__c = 'Searches knowledge articles';
            record.ImplementationType__c = 'Standard';
            record.StandardActionType__c = 'SearchKnowledge';
            record.Parameters__c = '{"type":"object","properties":{"searchQuery":{"type":"string"},"language":{"type":"string"}}}';
            return this;
        }

        public CapabilityBuilder forFlowHandler(String flowName) {
            record.CapabilityName__c = 'run_flow_' + flowName.toLowerCase();
            record.Description__c = 'Executes the ' + flowName + ' Flow';
            record.ImplementationType__c = 'Flow';
            record.ImplementationDetail__c = flowName;
            record.BackendConfiguration__c = '{"flowApiName":"' + flowName + '"}';
            record.Parameters__c = '{"type":"object","properties":{"inputParameters":{"type":"object","additionalProperties":true}}}';
            return this;
        }

        public CapabilityBuilder forCustomApex(String className) {
            record.ImplementationType__c = 'Apex';
            record.ImplementationDetail__c = className;
            return this;
        }

        public AgentCapability__c build() {
            return record;
        }

        public AgentCapability__c save() {
            insert record;
            return record;
        }
    }

    // ===================================================================================
    // AGENT EXECUTION & STEPS
    // ===================================================================================

    public static ExecutionBuilder newExecution() {
        return new ExecutionBuilder();
    }

    public class ExecutionBuilder {
        private AgentExecution__c record = new AgentExecution__c(
            ExecutionType__c = 'Conversational',
            ExecutionStatus__c = 'Pending',
            ProcessingStatus__c = 'Idle',
            TriggerSource__c = 'Test',
            TriggerPayload__c = 'Test execution'
        );

        public ExecutionBuilder withAgent(Id agentId) {
            record.AIAgentDefinition__c = agentId;
            return this;
        }

        public ExecutionBuilder withUser(Id userId) {
            record.User__c = userId;
            record.OwnerId = userId;
            return this;
        }

        public ExecutionBuilder withExecutionType(String executionType) {
            record.ExecutionType__c = executionType;
            return this;
        }

        public ExecutionBuilder withStatus(String status) {
            record.ExecutionStatus__c = status;
            return this;
        }

        public ExecutionBuilder withProcessingStatus(String status) {
            record.ProcessingStatus__c = status;
            return this;
        }

        public ExecutionBuilder withTurnIdentifier(String turnId) {
            record.CurrentTurnIdentifier__c = turnId;
            return this;
        }

        public ExecutionBuilder withBatchId(String batchId) {
            record.BatchId__c = batchId;
            return this;
        }

        public ExecutionBuilder withPriority(Integer priority) {
            record.Priority__c = priority;
            return this;
        }

        public ExecutionBuilder processing() {
            record.ProcessingStatus__c = 'Processing';
            return this;
        }

        public ExecutionBuilder withSourceRecord(Id recordId) {
            record.SourceRecordId__c = recordId;
            return this;
        }

        public AgentExecution__c build() {
            return record;
        }

        public AgentExecution__c save() {
            insert record;
            return record;
        }
    }

    /**
     * @description Creates a conversation history with alternating user/assistant messages
     */
    public static List<ExecutionStep__c> createConversation(Id executionId, Integer turns) {
        List<ExecutionStep__c> steps = new List<ExecutionStep__c>();
        Datetime now = Datetime.now();

        for (Integer i = 1; i <= turns; i++) {
            String turnId = UUID.randomUUID().toString();

            // User message
            steps.add(
                new ExecutionStep__c(
                    AgentExecution__c = executionId,
                    StepType__c = 'UserInput',
                    StepRole__c = 'user',
                    Content__c = 'User message ' + i,
                    ContentType__c = 'Text',
                    TurnIdentifier__c = turnId,
                    TurnCount__c = i,
                    Timestamp__c = now.addMinutes(i * 2 - 1),
                    ExternalId__c = UUID.randomUUID().toString()
                )
            );

            // Assistant response
            steps.add(
                new ExecutionStep__c(
                    AgentExecution__c = executionId,
                    StepType__c = 'AgentResponse',
                    StepRole__c = 'assistant',
                    Content__c = 'Assistant response ' + i,
                    ContentType__c = 'Text',
                    TurnIdentifier__c = turnId,
                    TurnCount__c = i,
                    Timestamp__c = now.addMinutes(i * 2),
                    ExternalId__c = UUID.randomUUID().toString()
                )
            );
        }

        insert steps;
        return steps;
    }

    /**
     * @description Creates a tool call sequence
     */
    public static List<ExecutionStep__c> createToolCallSequence(Id executionId, String toolName) {
        String turnId = UUID.randomUUID().toString();
        String toolCallId = 'call_' + generateRandomString(8);

        List<ExecutionStep__c> steps = new List<ExecutionStep__c>{
            // Tool call
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'ToolCall',
                StepRole__c = 'assistant',
                ToolCallId__c = toolCallId,
                ToolName__c = toolName,
                ToolArguments__c = '{"param1":"value1"}',
                TurnIdentifier__c = turnId,
                ExternalId__c = UUID.randomUUID().toString()
            ),
            // Tool result
            new ExecutionStep__c(
                AgentExecution__c = executionId,
                StepType__c = 'ToolResult',
                StepRole__c = 'tool',
                ToolCallId__c = toolCallId,
                ToolName__c = toolName,
                ToolResult__c = '{"success":true,"data":"result"}',
                Content__c = 'Tool executed successfully',
                TurnIdentifier__c = turnId,
                ExternalId__c = UUID.randomUUID().toString()
            )
        };

        insert steps;
        return steps;
    }

    // ===================================================================================
    // ORCHESTRATION HELPERS
    // ===================================================================================

    public static Map<String, String> createToolCallAction(String name, String argumentsJson, String toolCallId) {
        Map<String, String> action = new Map<String, String>();
        action.put('id', String.isNotBlank(toolCallId) ? toolCallId : ('call_' + generateRandomString(8)));
        action.put('name', name);
        action.put('arguments', argumentsJson);
        return action;
    }

    public static LLMInteractionService.LLMInteractionResult createLlmTextResult(String content) {
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = content;
        providerResult.promptTokens = 100;
        providerResult.completionTokens = 50;
        providerResult.totalTokens = 150;
        providerResult.requestedActions = new List<Map<String, String>>();

        LLMInteractionService.MessageData messageData = new LLMInteractionService.MessageData();
        messageData.role = 'assistant';
        messageData.content = content;
        messageData.processingTimeMs = 100;
        messageData.tokensUsed = 150;

        return new LLMInteractionService.LLMInteractionResult(providerResult, messageData);
    }

    public static LLMInteractionService.LLMInteractionResult createLlmToolCallResult(String assistantContent, List<Map<String, String>> actions) {
        ProviderResult providerResult = new ProviderResult();
        providerResult.content = assistantContent;
        providerResult.promptTokens = 100;
        providerResult.completionTokens = 50;
        providerResult.totalTokens = 150;
        providerResult.requestedActions = (actions == null) ? new List<Map<String, String>>() : actions;

        LLMInteractionService.MessageData messageData = new LLMInteractionService.MessageData();
        messageData.role = 'assistant';
        messageData.content = assistantContent;
        messageData.processingTimeMs = 100;
        messageData.tokensUsed = 150;

        return new LLMInteractionService.LLMInteractionResult(providerResult, messageData);
    }

    public static LLMInteractionService.MessageData createUserMessage(String content) {
        LLMInteractionService.MessageData message = new LLMInteractionService.MessageData();
        message.role = 'user';
        message.content = content;
        return message;
    }

    public static OrchestrationContextBuilder newOrchestrationContext() {
        return new OrchestrationContextBuilder();
    }

    public class OrchestrationContextBuilder {
        private LLMInteractionService.LLMInteractionResult llmResult;
        private Id executionId;
        private Id originalUserId;
        private Id executionUserId;
        private Id agentDefinitionId;
        private String turnIdentifier = 'turn-' + generateRandomString(6);
        private Integer currentTurnCount = 1;
        private LLMInteractionService.MessageData userMessageData;
        private Id pageRecordId;

        public OrchestrationContextBuilder withLlmResult(LLMInteractionService.LLMInteractionResult result) {
            llmResult = result;
            return this;
        }

        public OrchestrationContextBuilder withExecution(Id execId) {
            executionId = execId;
            return this;
        }

        public OrchestrationContextBuilder withAgent(Id agentId) {
            agentDefinitionId = agentId;
            return this;
        }

        public OrchestrationContextBuilder withUsers(Id origUserId, Id execUserId) {
            originalUserId = origUserId;
            executionUserId = execUserId;
            return this;
        }

        public OrchestrationContextBuilder withTurn(String turnId, Integer turnCount) {
            turnIdentifier = turnId;
            currentTurnCount = turnCount;
            return this;
        }

        public OrchestrationContextBuilder withUserMessage(String content) {
            userMessageData = createUserMessage(content);
            return this;
        }

        public OrchestrationContextBuilder withPageRecord(Id recordId) {
            pageRecordId = recordId;
            return this;
        }

        public OrchestrationContextBuilder withSetup(AgentSetup setup) {
            executionId = setup.agentExecution != null ? setup.agentExecution.Id : null;
            agentDefinitionId = setup.agentDefinition != null ? setup.agentDefinition.Id : null;
            return this;
        }

        public OrchestrationContext build() {
            Id origUser = (originalUserId != null) ? originalUserId : UserInfo.getUserId();
            Id execUser = (executionUserId != null) ? executionUserId : origUser;

            AgentStateService stateSvc = new AgentStateService();
            CapabilityExecutionService actionSvc = new CapabilityExecutionService();
            AgentJobEnqueuer dispatchSvc = new AgentJobEnqueuer();
            ContextManagerService contextSvc = new ContextManagerService();
            IDecisionStepLogger.ILogger logger = IDecisionStepLogger.create(executionId, turnIdentifier);

            return new OrchestrationContext(
                llmResult,
                executionId,
                origUser,
                execUser,
                agentDefinitionId,
                turnIdentifier,
                currentTurnCount,
                userMessageData,
                stateSvc,
                actionSvc,
                dispatchSvc,
                contextSvc,
                pageRecordId,
                logger
            );
        }
    }

    // ===================================================================================
    // EXECUTION PAYLOAD BUILDER
    // ===================================================================================

    public static ExecutionPayloadBuilder newExecutionPayload() {
        return new ExecutionPayloadBuilder();
    }

    public class ExecutionPayloadBuilder {
        private AgentExecutionService.ExecutionPayload payload = new AgentExecutionService.ExecutionPayload();

        public ExecutionPayloadBuilder withUser(Id userId) {
            payload.userId = userId;
            return this;
        }

        public ExecutionPayloadBuilder withServiceUser(Id userId) {
            payload.serviceUserId = userId;
            return this;
        }

        public ExecutionPayloadBuilder withSourceRecord(Id recordId) {
            payload.sourceRecordId = recordId;
            payload.currentRecordId = recordId;
            return this;
        }

        public ExecutionPayloadBuilder withSourceRecords(List<Id> recordIds) {
            payload.sourceRecordIds = recordIds;
            return this;
        }

        public ExecutionPayloadBuilder withUserMessage(String message) {
            payload.userMessage = message;
            return this;
        }

        public ExecutionPayloadBuilder withTriggerSource(String source) {
            payload.triggerSource = source;
            return this;
        }

        public ExecutionPayloadBuilder withTurn(String turnId) {
            payload.turnIdentifier = turnId;
            return this;
        }

        public ExecutionPayloadBuilder withExistingExecution(Id executionId) {
            payload.existingExecutionId = executionId;
            return this;
        }

        public AgentExecutionService.ExecutionPayload build() {
            return payload;
        }
    }

    // ===================================================================================
    // STANDARD SALESFORCE OBJECTS
    // ===================================================================================

    public static AccountBuilder newAccount() {
        return new AccountBuilder();
    }

    public class AccountBuilder {
        private Account record = new Account(
            Name = 'Test Account ' + generateRandomString(6),
            Industry = 'Technology',
            AnnualRevenue = 1000000,
            NumberOfEmployees = 100,
            Phone = '555-0100',
            Website = 'https://test.example.com'
        );

        public AccountBuilder withName(String name) {
            record.Name = name;
            return this;
        }

        public AccountBuilder withIndustry(String industry) {
            record.Industry = industry;
            return this;
        }

        public AccountBuilder withRevenue(Decimal revenue) {
            record.AnnualRevenue = revenue;
            return this;
        }

        public AccountBuilder withParent(Id parentId) {
            record.ParentId = parentId;
            return this;
        }

        public AccountBuilder withDescription(String description) {
            record.Description = description;
            return this;
        }

        public AccountBuilder withType(String accountType) {
            record.Type = accountType;
            return this;
        }

        public AccountBuilder withPhone(String phone) {
            record.Phone = phone;
            return this;
        }

        public Account build() {
            return record;
        }

        public Account save() {
            insert record;
            return record;
        }
    }

    public static ContactBuilder newContact() {
        return new ContactBuilder();
    }

    public class ContactBuilder {
        private Contact record = new Contact(
            FirstName = 'Test',
            LastName = 'Contact ' + generateRandomString(6),
            Email = 'test' + generateRandomString(6) + '@example.com',
            Phone = '555-0200',
            Title = 'Test Title'
        );

        public ContactBuilder withName(String firstName, String lastName) {
            record.FirstName = firstName;
            record.LastName = lastName;
            return this;
        }

        public ContactBuilder withEmail(String email) {
            record.Email = email;
            return this;
        }

        public ContactBuilder withAccount(Id accountId) {
            record.AccountId = accountId;
            return this;
        }

        public Contact build() {
            return record;
        }

        public Contact save() {
            insert record;
            return record;
        }
    }

    public static OpportunityBuilder newOpportunity() {
        return new OpportunityBuilder();
    }

    public class OpportunityBuilder {
        private Opportunity record = new Opportunity(
            Name = 'Test Opportunity ' + generateRandomString(6),
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Amount = 50000,
            Probability = 10
        );

        public OpportunityBuilder withName(String name) {
            record.Name = name;
            return this;
        }

        public OpportunityBuilder withStage(String stage) {
            record.StageName = stage;
            return this;
        }

        public OpportunityBuilder withAmount(Decimal amount) {
            record.Amount = amount;
            return this;
        }

        public OpportunityBuilder withAccount(Id accountId) {
            record.AccountId = accountId;
            return this;
        }

        public OpportunityBuilder closingIn(Integer days) {
            record.CloseDate = Date.today().addDays(days);
            return this;
        }

        public Opportunity build() {
            return record;
        }

        public Opportunity save() {
            insert record;
            return record;
        }
    }

    public static CaseBuilder newCase() {
        return new CaseBuilder();
    }

    public class CaseBuilder {
        private Case record = new Case(Subject = 'Test Case ' + generateRandomString(6), Status = 'New', Origin = 'Web', Priority = 'Medium');

        public CaseBuilder withSubject(String subject) {
            record.Subject = subject;
            return this;
        }

        public CaseBuilder withStatus(String status) {
            record.Status = status;
            return this;
        }

        public CaseBuilder withAccount(Id accountId) {
            record.AccountId = accountId;
            return this;
        }

        public CaseBuilder withContact(Id contactId) {
            record.ContactId = contactId;
            return this;
        }

        public Case build() {
            return record;
        }

        public Case save() {
            insert record;
            return record;
        }
    }

    public static TaskBuilder newTask() {
        return new TaskBuilder();
    }

    public class TaskBuilder {
        private Task record = new Task(
            Subject = 'Test Task ' + generateRandomString(6),
            Status = 'Not Started',
            Priority = 'Normal',
            ActivityDate = Date.today().addDays(7)
        );

        public TaskBuilder withSubject(String subject) {
            record.Subject = subject;
            return this;
        }

        public TaskBuilder withStatus(String status) {
            record.Status = status;
            return this;
        }

        public TaskBuilder assignedTo(Id userId) {
            record.OwnerId = userId;
            return this;
        }

        public TaskBuilder relatedTo(Id recordId) {
            record.WhatId = recordId;
            return this;
        }

        public Task build() {
            return record;
        }

        public Task save() {
            insert record;
            return record;
        }
    }

    // ===================================================================================
    // BULK DATA CREATION
    // ===================================================================================

    public static BulkDataBuilder createAccounts(Integer count) {
        return new BulkDataBuilder('Account', count);
    }

    public static BulkDataBuilder createContacts(Integer count) {
        return new BulkDataBuilder('Contact', count);
    }

    public static BulkDataBuilder createOpportunities(Integer count) {
        return new BulkDataBuilder('Opportunity', count);
    }

    public class BulkDataBuilder {
        private String objectType;
        private Integer count;
        private Map<String, Object> commonFields = new Map<String, Object>();

        public BulkDataBuilder(String objectType, Integer count) {
            this.objectType = objectType;
            this.count = count;
        }

        public BulkDataBuilder with(String fieldName, Object value) {
            commonFields.put(fieldName, value);
            return this;
        }

        public List<SObject> save() {
            List<SObject> records = new List<SObject>();
            Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectType);

            for (Integer i = 0; i < count; i++) {
                SObject record = sObjType.newSObject();

                // Set common fields
                for (String fieldName : commonFields.keySet()) {
                    record.put(fieldName, commonFields.get(fieldName));
                }

                // Set default fields based on object type
                if (objectType == 'Account') {
                    record.put('Name', 'Test Account ' + i);
                } else if (objectType == 'Contact') {
                    record.put('FirstName', 'Test');
                    record.put('LastName', 'Contact ' + i);
                } else if (objectType == 'Opportunity') {
                    record.put('Name', 'Test Opportunity ' + i);
                    record.put('StageName', 'Prospecting');
                    record.put('CloseDate', Date.today().addDays(30));
                }

                records.add(record);
            }

            insert records;
            return records;
        }
    }

    // ===================================================================================
    // UTILITY METHODS
    // ===================================================================================

    /**
     * @description Generates a random alphanumeric string
     */
    private static String generateRandomString(Integer length) {
        String chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
        String result = '';
        for (Integer i = 0; i < length; i++) {
            Integer index = Math.mod(Math.abs(Crypto.getRandomInteger()), chars.length());
            result += chars.substring(index, index + 1);
        }
        return result;
    }

    /**
     * @description Creates a test user with specified profile
     */
    public static User createTestUser(String profileName) {
        String uniqueId = generateRandomString(8);
        User testUser = new User(
            FirstName = 'Test',
            LastName = 'User ' + uniqueId,
            Email = 'testuser' + uniqueId + '@test.example.com',
            Username = 'testuser' + uniqueId + '@test.example.com.' + uniqueId,
            Alias = uniqueId.substring(0, 5),
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = [SELECT Id FROM Profile WHERE Name = :profileName LIMIT 1]
            .Id
        );
        insert testUser;
        return testUser;
    }

    /**
     * @description Generates a fake/mock Salesforce ID for testing purposes
     * @param sObjectType The SObject type to generate an ID for
     * @return A valid-format (but fake) Salesforce ID
     */
    public static Id generateMockId(Schema.SObjectType sObjectType) {
        String prefix = sObjectType.getDescribe().getKeyPrefix();
        // Salesforce IDs are 15 characters: 3 char prefix + 12 alphanumeric
        // Generate 12 characters of padding (0-9, A-Z)
        String padding = '0'.repeat(12);
        String fakeId = prefix + padding;
        return Id.valueOf(fakeId);
    }

    // ===================================================================================
    // DATA TRANSFER OBJECTS
    // ===================================================================================

    /**
     * @description Container for complete agent setup
     */
    public class AgentSetup {
        public LLMConfiguration__c llmConfig { get; set; }
        public AIAgentDefinition__c agentDefinition { get; set; }
        public AgentExecution__c agentExecution { get; set; }
        public List<AgentCapability__c> capabilities { get; set; }
        public List<AgentContextConfig__c> contextConfigs { get; set; }
    }

    public class FunctionAgentSetup {
        public LLMConfiguration__c llmConfig { get; set; }
        public AIAgentDefinition__c agentDefinition { get; set; }
        public AgentExecution__c execution { get; set; }
        public List<AgentCapability__c> capabilities { get; set; }
    }

    public class WorkflowSetup {
        public LLMConfiguration__c llmConfig { get; set; }
        public AIAgentDefinition__c workflowAgent { get; set; }
        public AgentExecution__c execution { get; set; }
        public List<AIAgentDefinition__c> childAgents { get; set; }
        public List<AgentWorkflowStep__c> steps { get; set; }
    }
}
