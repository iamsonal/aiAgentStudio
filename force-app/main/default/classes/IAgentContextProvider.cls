/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Interface for custom Apex classes that provide contextual data for the AI Agent Framework.
 *              Implementations are responsible for securely querying and returning relevant SObject data
 *              based on the agent's current context (user and optional record).
 *
 * @important Implementers MUST ensure their data retrieval logic is BULK-SAFE and respects Salesforce security.
 *            The `getContext` method now receives a Set of IDs. The implementation MUST handle this set
 *            efficiently (e.g., using `WHERE Id IN :anchorIds` in a single query).
 *            Use 'WITH USER_MODE' for SOQL queries or explicitly check FLS and object permissions.
 */
public interface IAgentContextProvider {
    /**
     * @description (BULK-SAFE) Retrieves context data for a set of anchor record IDs.
     *
     * @param anchorIds A Set of Salesforce IDs serving as the context anchors. These will all be of the
     *                  SObject type(s) specified in the provider's AgentContextConfig__c record. For
     *                  providers that do not require a record context, this set will contain the User ID.
     * @param userId The Salesforce ID of the user initiating the request. Always provided for reference
     *               and enforcing user context-specific logic or permissions if needed.
     * @param configurationJson A JSON String containing custom configuration parameters specific to this
     *                          provider instance, as defined in the AgentContextConfig__c record's
     *                          ImplementationConfigJson__c field. Can be null/blank.
     *
     * @return Map<String, List<SObject>> A map where:
     *           - Keys are String labels representing a logical block of context (e.g., "Open Cases").
     *           - Values are Lists of SObjects containing the queried data.
     *         Return an empty map or a map with empty lists if no relevant context is found.
     *
     * @example
     * public Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configJson) {
     *     Map<String, List<SObject>> results = new Map<String, List<SObject>>();
     *
     *     List<Case> highPriCases = [SELECT Id, CaseNumber FROM Case WHERE AccountId IN :anchorIds WITH USER_MODE];
     *     results.put('High Priority Related Cases', highPriCases);
     *     return results;
     * }
     */
    Map<String, List<SObject>> getContext(Set<Id> anchorIds, Id userId, String configurationJson);
}
