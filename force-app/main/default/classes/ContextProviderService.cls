/*
 * This file is part of Pluto. It is licensed under the GNU Affero General
 * Public License, version 3 only. See the LICENSE file at the root of this
 * repository, or https://www.gnu.org/licenses/agpl-3.0.html.
 *
 * The Pluto Extension Exception in the LICENSE-EXCEPTION file lets code that
 * uses only Pluto's public interface stay under its own license.
 *
 * SPDX-License-Identifier: AGPL-3.0-only
 *
 * Copyright (c) 2026 Sonal
 */

/**
 * Query-only context collection with deterministic ordering, hard bounds, and
 * metadata-only telemetry. Subscriber execution is rolled back before Core
 * continues, so prohibited side effects cannot leak into the worker transaction.
 */
public inherited sharing class ContextProviderService {
    private static final Integer DEFAULT_BUDGET = 8000;
    private static final Integer MAX_SOURCE_CHARACTERS = 16000;
    private static final Integer MAX_SOURCE_NAME_LENGTH = 100;
    /** Each attempt serializes and protects the record sets again. */
    private static final Integer MAX_RECORD_TRIM_ATTEMPTS = 3;

    public class ContextProviderDmlException extends Exception {
    }

    public class CollectionResult {
        public List<AgentKernelModels.ContextItem> contexts = new List<AgentKernelModels.ContextItem>();
        public List<Object> sourceMetadata = new List<Object>();
        public TrustService.ProtectionContext trustContext;
    }

    public static CollectionResult collect(
        AgentDefinition__c definition,
        Id runId,
        AgentKernelModels.ExecutionPrincipal principal,
        String operationKey,
        String originalInput,
        String currentInput
    ) {
        CollectionResult result = new CollectionResult();
        List<AgentContextProvider__c> providers = runId == null
            ? AgentConfigService.getActiveContextProviders(definition.Id)
            : AgentRunConfigurationService.getContextProviders(runId);
        Integer budget = runId == null
            ? AgentExecutionPolicyService.resolve().contextCharacterBudget
            : AgentRunConfigurationService.getExecutionPolicy(runId).contextCharacterBudget;
        Integer remaining = Math.min(AgentConfigService.MAX_CONTEXT_CHARACTERS, Math.max(0, budget == null ? DEFAULT_BUDGET : budget));
        Set<String> sourceNames = new Set<String>();

        for (AgentContextProvider__c provider : providers) {
            String providerName = provider.DeveloperName__c;
            if (remaining == 0 || !ExtensionExecutionGuard.hasRequiredHeadroom()) {
                result.sourceMetadata.add(metadata(providerName, null, 'SkippedBudget', 0));
                continue;
            }

            AgentKernelModels.ContextRequest request = new AgentKernelModels.ContextRequest();
            request.runId = runId;
            request.definitionId = definition.Id;
            request.anchorRecordId = principal?.anchorRecordId;
            request.principal = principal;
            request.operationKey = operationKey;
            request.originalInput = originalInput;
            request.currentInput = currentInput;
            request.implementationConfiguration = provider.ImplementationConfiguration__c;
            request.objectApiName = provider.ObjectApiName__c;
            request.fieldSetName = provider.FieldSetName__c;
            request.contextSubject = provider.ContextSubject__c;

            AgentKernelModels.ContextResponse response;
            Exception providerFailure;
            ExtensionExecutionGuard.Boundary boundary = ExtensionExecutionGuard.open();
            try {
                response = AgentExtensionInvoker.provideContext(provider, request);
            } catch (Exception caughtFailure) {
                providerFailure = caughtFailure;
            }
            ExtensionExecutionGuard.Result isolation = ExtensionExecutionGuard.close(boundary);
            if (isolation.budgetExceeded) {
                result.sourceMetadata.add(metadata(providerName, null, 'SkippedGovernorBudget', 0));
                continue;
            }
            if (isolation.performedDml) {
                throw new ContextProviderDmlException('Context provider performed prohibited DML: ' + providerName);
            }
            if (isolation.performedCallout || providerFailure instanceof CalloutException) {
                throw new ContextProviderDmlException('Context provider performed a prohibited callout: ' + providerName);
            }
            if (isolation.performedProhibitedAsync()) {
                throw new ContextProviderDmlException('Context provider performed prohibited asynchronous work: ' + providerName);
            }
            if (providerFailure != null) {
                String status = providerFailure instanceof FieldSetContextProvider.RecordUnavailableException
                    ? 'RecordUnavailable'
                    : providerFailure instanceof AgentKernelException.AuthorizationException ? 'AccessDenied' : 'Failed';
                result.sourceMetadata.add(metadata(providerName, null, status, 0));
                continue;
            }

            Boolean hasText = response != null && !String.isBlank(response.content);
            Boolean hasRecords = response != null && response.recordSets != null && !response.recordSets.isEmpty();
            if (response == null || hasText == hasRecords) {
                result.sourceMetadata.add(metadata(providerName, null, 'Failed', 0));
                continue;
            }
            // Text cannot be filtered to what the person an attended run works for may read; record sets are.
            if (hasText && principal != null && principal.attendedByUserId != null) {
                result.sourceMetadata.add(metadata(providerName, null, 'WithheldForRequester', 0));
                continue;
            }
            String sourceName = String.isBlank(response.sourceName) ? providerName : response.sourceName;
            sourceName = sourceName.replace('\r', ' ').replace('\n', ' ').trim();
            if (sourceName.length() > MAX_SOURCE_NAME_LENGTH || sourceNames.contains(sourceName.toLowerCase())) {
                result.sourceMetadata.add(metadata(providerName, null, 'Failed', 0));
                continue;
            }
            sourceNames.add(sourceName.toLowerCase());

            String content = response.content;
            Boolean recordsDropped = false;
            if (hasRecords) {
                Integer allowed = Math.min(remaining, MAX_SOURCE_CHARACTERS);
                Map<String, List<SObject>> recordSets = response.recordSets;
                try {
                    if (runId != null && result.trustContext == null) {
                        result.trustContext = TrustService.open(runId);
                    }
                    content = serializeRecords(result.trustContext, recordSets);
                    // Whole records are kept from the start of each set, so a provider puts what matters most first.
                    for (Integer attempt = 0; content != null && content.length() > allowed && attempt < MAX_RECORD_TRIM_ATTEMPTS; attempt++) {
                        recordSets = leadingRecords(recordSets, (Decimal) allowed / content.length());
                        content = recordSets == null ? null : serializeRecords(result.trustContext, recordSets);
                        recordsDropped = true;
                    }
                } catch (Exception invalidRecords) {
                    result.sourceMetadata.add(metadata(providerName, null, 'Failed', 0));
                    continue;
                }
                if (content == null || content.length() > allowed) {
                    result.sourceMetadata.add(metadata(providerName, null, 'SkippedBudget', 0));
                    continue;
                }
            }
            Integer includedCharacters = Math.min(remaining, Math.min(MAX_SOURCE_CHARACTERS, content.length()));
            Boolean truncated = recordsDropped || includedCharacters < content.length();
            AgentKernelModels.ContextItem item = new AgentKernelModels.ContextItem();
            item.sourceName = sourceName;
            item.content = content.substring(0, includedCharacters);
            item.truncated = truncated;
            item.untrusted = true;
            result.contexts.add(item);
            result.sourceMetadata.add(metadata(providerName, sourceName, truncated ? 'Truncated' : 'Included', includedCharacters));
            remaining -= includedCharacters;
        }
        return result;
    }

    private static String serializeRecords(TrustService.ProtectionContext trustContext, Map<String, List<SObject>> recordSets) {
        return trustContext == null ? TrustService.serializeRecordSets(recordSets) : TrustService.protectRecordSets(trustContext, recordSets);
    }

    /** The leading records of each set, shrunk by the share that fits and by at least one record; null when none are left. */
    private static Map<String, List<SObject>> leadingRecords(Map<String, List<SObject>> recordSets, Decimal share) {
        Map<String, List<SObject>> result = new Map<String, List<SObject>>();
        Integer kept = 0;
        for (String name : recordSets.keySet()) {
            List<SObject> records = recordSets.get(name);
            Integer size = records == null ? 0 : records.size();
            Integer keep = Math.min(size - 1, (Integer) Math.floor(size * share));
            List<SObject> leading = new List<SObject>();
            for (Integer index = 0; index < keep; index++) {
                leading.add(records[index]);
            }
            if (!leading.isEmpty()) {
                result.put(name, leading);
                kept += leading.size();
            }
        }
        return kept == 0 ? null : result;
    }

    private static Map<String, Object> metadata(String className, String sourceName, String status, Integer includedCharacters) {
        return new Map<String, Object>{ 'className' => className, 'sourceName' => sourceName, 'status' => status, 'includedCharacters' => includedCharacters };
    }
}
