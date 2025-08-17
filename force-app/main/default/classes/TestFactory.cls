/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Provides utility methods for creating AI Agent Framework records in-memory for Apex tests.
 *              This factory prepares SObjects but does not perform DML, allowing the calling test
 *              method to control when records are inserted.
 * @see AgentTestDataFactory
 */
@TestVisible
public with sharing class TestFactory {
    // --- Static counter to ensure unique developer names across multiple calls in a single test ---
    private static Integer counter = 1;

    /**
     * @description Creates a complete, ready-to-insert agent setup including LLM, Agent, Actions, and Bindings.
     * @return A DTO containing all related records, ready for insertion.
     */
    public static AgentSetupData createFullAgentSetup() {
        AgentSetupData setup = new AgentSetupData();

        // 1. LLM Configuration
        setup.llmConfig = createLLMConfiguration();

        // 2. Agent Definition (linked to the LLM config)
        setup.agentDefinition = createAgentDefinition(null); // Will be linked after insert

        // 3. Agent Capabilities
        setup.capabilities = createStandardCapabilities(null);

        // 4. Context Provider Configs
        setup.contextConfigs = createContextConfigs(null);

        return setup;
    }

    /**
     * @description Creates a standard LLMConfiguration__c record in memory.
     * @return A new LLMConfiguration__c SObject.
     */
    public static LLMConfiguration__c createLLMConfiguration() {
        return new LLMConfiguration__c(
            Name = 'Test OpenAI LLM ' + counter,
            DeveloperName__c = 'Test_OpenAI_LLM_' + counter++,
            ProviderAdapterClass__c = OpenAIProviderAdapter.class.getName(),
            NamedCredential__c = 'OpenAI_API_Test', // A placeholder name
            DefaultModelIdentifier__c = 'gpt-4o-mini',
            IsActive__c = true
        );
    }

    /**
     * @description Creates a standard AIAgentDefinition__c record in memory.
     * @param llmConfigId The ID of the parent LLMConfiguration__c record. Can be null if linking after insert.
     * @return A new AIAgentDefinition__c SObject.
     */
    public static AIAgentDefinition__c createAgentDefinition(Id llmConfigId) {
        return new AIAgentDefinition__c(
            Name = 'Test Sales Agent ' + counter,
            DeveloperName__c = 'Test_Sales_Agent_' + counter++,
            LLMConfiguration__c = llmConfigId,
            SystemPrompt__c = 'You are a test sales agent.',
            IsActive__c = true,
            MemoryStrategy__c = 'Buffer Window'
        );
    }

    /**
     * @description (NEW) Creates a list of standard, self-contained AgentCapability__c records.
     * @param agentDefId The ID of the parent AIAgentDefinition__c. Can be null if linking after insert.
     * @return A List of new AgentCapability__c SObjects.
     */
    public static List<AgentCapability__c> createStandardCapabilities(Id agentDefId) {
        List<AgentCapability__c> capabilities = new List<AgentCapability__c>();

        // Capability 1: Find Records (Standard Action)
        capabilities.add(
            createSingleCapability(
                agentDefId,
                'find_sales_records',
                'Searches for records like Accounts or Contacts.',
                '{"type":"object","properties":{"searchQuery":{"type":"string"}},"required":["searchQuery"]}',
                'Standard',
                null, // No ImplementationDetail for Standard
                'FindEntities',
                false,
                null // No BackendConfiguration for FindEntities
            )
        );

        // Capability 2: Create Opportunity (Standard Action with Backend Config)
        capabilities.add(
            createSingleCapability(
                agentDefId,
                'create_opportunity',
                'Creates a new sales Opportunity.',
                '{"type":"object","properties":{"Name":{"type":"string"}, "StageName":{"type":"string"}},"required":["Name", "StageName"]}',
                'Standard',
                null,
                'CreateRecord',
                false,
                '{"objectApiName": "Opportunity"}' // Backend config tells the action what to create
            )
        );

        return capabilities;
    }

    /**
     * @description Helper to create a single, fully-defined AgentCapability__c sObject.
     */
    public static AgentCapability__c createSingleCapability(
        Id agentDefId,
        String capabilityName,
        String description,
        String parametersJson,
        String implType,
        String implDetail,
        String stdActionType,
        Boolean runAsync,
        String backendConfigJson
    ) {
        return new AgentCapability__c(
            AIAgentDefinition__c = agentDefId,
            CapabilityName__c = capabilityName + '_' + counter++,
            Description__c = description,
            Parameters__c = parametersJson,
            ImplementationType__c = implType,
            ImplementationDetail__c = implDetail,
            StandardActionType__c = stdActionType,
            RunAsynchronously__c = runAsync,
            BackendConfiguration__c = backendConfigJson,
            ExecutionPriority__c = 10
        );
    }

    /**
     * @description Creates a list of AgentContextConfig__c records in memory.
     * @param agentDefId The ID of the parent AIAgentDefinition__c.
     * @return A List of new AgentContextConfig__c SObjects.
     */
    public static List<AgentContextConfig__c> createContextConfigs(Id agentDefId) {
        return new List<AgentContextConfig__c>{
            new AgentContextConfig__c(
                AIAgentDefinition__c = agentDefId,
                ContextLabel__c = 'Test User Context',
                ImplementationType__c = 'Apex',
                ImplementationName__c = 'UserDetailsProvider', // Assuming this mock provider exists
                ExecutionOrder__c = 10,
                IsActive__c = true
            )
        };
    }

    /**
     * @description Creates a ChatSession__c record in memory.
     * @param agentDefId The ID of the parent AIAgentDefinition__c.
     * @param userId The ID of the user owning the session.
     * @return A new ChatSession__c SObject.
     */
    public static ChatSession__c createChatSession(Id agentDefId, Id userId) {
        return new ChatSession__c(
            AIAgentDefinition__c = agentDefId,
            OwnerId = userId,
            User__c = userId,
            ProcessingStatus__c = 'Idle',
            SessionLabel__c = 'Test Session ' + counter++
        );
    }

    /**
     * @description Creates a list of ChatMessage__c records in memory for a session.
     * @param sessionId The ID of the parent ChatSession__c.
     * @param count The number of user/assistant message pairs to create.
     * @return A List of new ChatMessage__c SObjects.
     */
    public static List<ChatMessage__c> createChatMessages(Id sessionId, Integer count) {
        List<ChatMessage__c> messages = new List<ChatMessage__c>();
        Datetime now = Datetime.now();

        for (Integer i = 1; i <= count; i++) {
            // User Message
            messages.add(
                new ChatMessage__c(
                    ChatSession__c = sessionId,
                    Role__c = 'user',
                    Content__c = 'This is user message number ' + i,
                    Timestamp__c = now.addMinutes(i * 2 - 1),
                    ExternalId__c = UuidUtils.generateUUID()
                )
            );
            // Assistant Response
            messages.add(
                new ChatMessage__c(
                    ChatSession__c = sessionId,
                    Role__c = 'assistant',
                    Content__c = 'This is assistant response number ' + i,
                    Timestamp__c = now.addMinutes(i * 2),
                    ExternalId__c = UuidUtils.generateUUID()
                )
            );
        }
        return messages;
    }

    /**
     * @description DTO class to hold all records for a complete agent setup.
     */
    public class AgentSetupData {
        public LLMConfiguration__c llmConfig { get; set; }
        public AIAgentDefinition__c agentDefinition { get; set; }
        public List<AgentCapability__c> capabilities { get; set; }
        public List<AgentContextConfig__c> contextConfigs { get; set; }
    }
}
