/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description
 * IAgentContextProvider defines the contract for all custom context providers that supply relevant data to AI agents.
 *
 * Responsibilities:
 *   - Securely and efficiently query Salesforce data based on contextual anchors (records, users, etc.)
 *   - Enforce security boundaries (FLS/CRUD, user permissions) and bulk-safe query patterns
 *   - Provide a consistent interface for agent orchestration to retrieve context blocks for LLM and agent actions
 *
 * Security & Bulk Requirements:
 *   - Use 'WITH USER_MODE' in SOQL queries for automatic FLS/CRUD enforcement
 *   - Handle Set<Id> parameters efficiently with single queries (WHERE Id IN :anchorIds)
 *   - Validate user permissions for sensitive data access
 *   - Implement proper error handling for security violations
 *
 * This interface is intended for extension by all context providers in the agent framework, ensuring that context retrieval
 * is always secure, efficient, and consistent across implementations.
 */
public interface IAgentContextProvider {
    /**
     * Retrieves context data for a set of anchor record IDs in a bulk-safe, security-compliant manner.
     *
     * @param anchorIds         Set of Salesforce IDs serving as context anchors. All IDs will be of the SObject type(s)
     *                         specified in the provider's AgentContextConfig__c. For providers not requiring a record context,
     *                         this set will contain the User ID.
     * @param userId            Salesforce ID of the user initiating the request. Always provided for reference and for enforcing
     *                         user context-specific logic or permissions if needed.
     * @param configurationJson JSON string containing custom configuration parameters for this provider instance, as defined in
     *                         AgentContextConfig__c.ImplementationConfigJson__c. May be null or blank.
     * @return Map<String, List<SObject>>
     *         - Keys: String labels representing logical context blocks (e.g., "Open Cases").
     *         - Values: Lists of SObjects containing the queried data.
     *         Return an empty map or a map with empty lists if no relevant context is found.
     *
     * @example
     * public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configJson) {
     *     Map<String, List<SObject>> results = new Map<String, List<SObject>>();
     *     // Securely and in bulk query data based on the set of anchorIds
     *     List<Case> highPriCases = [SELECT Id, CaseNumber FROM Case WHERE AccountId IN :anchorIds WITH USER_MODE];
     *     results.put('High Priority Related Cases', highPriCases);
     *     return results;
     * }
     */
    Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson);
}
