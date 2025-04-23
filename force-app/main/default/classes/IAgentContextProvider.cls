/*
 * Copyright (c) 2025 Sonal
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */


/**
 * @description Interface for custom Apex classes that provide context data to the AI Agent Framework.
 *              Implementations of this interface allow developers to inject highly customized or complex
 *              data structures into the agent's context, beyond what the declarative graph sources provide.
 *              The framework's ContextService will instantiate and call the `getContext` method
 *              when a ContextGraphSource__c record is configured with ImplementationType__c = 'Apex'.
 */
public interface IAgentContextProvider {
    /**
     * @description Retrieves context data based on the provided anchor and user information.
     *              This method should contain the custom logic to query, calculate, or fetch
     *              relevant SObjects or data points. It must handle security (e.g., use WITH USER_MODE)
     *              to ensure data visibility aligns with the requesting user's permissions.
     *
     * @param anchorId The Salesforce ID of the anchor point for context gathering.
     *                 This will be the User ID if the corresponding ContextGraphSource__c record's
     *                 SourceType__c is 'User Anchored', or the specific Record ID if it's 'Record Anchored'.
     *                 Implementations should check the type of the ID if behavior differs.
     * @param userId The Salesforce ID of the user initiating the request that triggered context gathering.
     *               Useful for querying user-specific information or enforcing permissions manually if needed.
     * @param configurationJson A JSON String containing custom configuration parameters specific to this provider instance,
     *                          as defined in the ContextGraphSource__c record's ProviderConfiguration__c field.
     *                          Implementations are responsible for parsing this JSON if needed. Can be null or blank.
     *
     * @return Map<String, List<SObject>> A map where:
     *           - Keys are String labels used to identify the context block (e.g., "Open Cases", "Related Contacts").
     *           - Values are Lists of SObjects representing the context data gathered for that block.
     *         The ContextService will aggregate the *first* non-empty List<SObject> found in the returned map
     *         under the configured label (or a generated label).
     *         Return an empty map or a map with empty lists if no relevant context is found or an error occurs
     *         that should not halt overall context gathering. Avoid throwing unhandled exceptions unless necessary.
     *
     * @example
     *
     * public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configJson) {
     *     Map<String, List<SObject>> results = new Map<String, List<SObject>>();
     *     if (anchorId.getSObjectType() == Opportunity.SObjectType) {
     *         List<Case> highPriCases = [SELECT Id, CaseNumber, Subject FROM Case ... WHERE OpportunityId__c = :anchorId AND Priority = 'High'];
     *         results.put('High Priority Related Cases', highPriCases);
     *     }
     *     return results;
     * }
     */
    Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson);
}
