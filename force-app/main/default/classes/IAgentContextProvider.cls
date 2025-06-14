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
 * @important Implementers MUST ensure their data retrieval logic respects Salesforce security.
 *            Use 'WITH USER_MODE' for SOQL queries OR explicitly check FLS and object permissions
 *            using Schema methods if dynamic SOQL or other methods are used. The ContextProviderRunner
 *            invokes these providers within the user's context, but the provider's internal logic
 *            dictates final data access. Only query fields necessary for the context.
 */
public interface IAgentContextProvider {
    /**
     * @description Retrieves context data relevant to the agent's current situation.
     *
     * @param anchorId The Salesforce ID serving as the primary context anchor.
     *                 - If the corresponding AgentContextConfig__c record's RequiresRecordContext__c is TRUE
     *                   and the agent is invoked from a record page matching ApplicableSObjectTypes__c,
     *                   this will be the Record ID.
     *                 - Otherwise (or if RequiresRecordContext__c is FALSE), this will typically be the User ID.
     *                 Implementations should be prepared to handle either ID type based on their configuration.
     * @param userId The Salesforce ID of the user initiating the request. Always provided for reference
     *               and enforcing user context-specific logic or permissions if needed.
     * @param configurationJson A JSON String containing custom configuration parameters specific to this
     *                          provider instance, as defined in the AgentContextConfig__c record's
     *                          ConfigurationJson__c field. Providers must parse this if needed. Can be null/blank.
     *
     * @return Map<String, List<SObject>> A map where:
     *           - Keys are String labels representing a logical block of context (e.g., "Open Cases", "Account Details").
     *             These labels MAY be used by the ContextProviderRunner in the final formatted output.
     *           - Values are Lists of SObjects containing the queried data for that block. Only include necessary fields.
     *         Return an empty map or a map with empty lists if no relevant context is found or an error occurs
     *         that should be handled gracefully (log the error internally). Throw exceptions only for
     *         unrecoverable configuration or system errors.
     *
     * @example
     * public Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configJson) {
     *     Map<String, List<SObject>> results = new Map<String, List<SObject>>();
     *
     *     List<Case> highPriCases = [SELECT Id, CaseNumber, Subject FROM Case ... WITH USER_MODE];
     *     results.put('High Priority Related Cases', highPriCases);
     *     return results;
     * }
     */
    Map<String, List<SObject>> getContext(Id anchorId, Id userId, String configurationJson);
}
