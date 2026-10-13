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
 * Salesforce-native sensitive-data tokenization boundary.
 *
 * Detection is deliberately limited to high-confidence, package-maintained
 * categories. Original values are durable only in the restricted token vault;
 * models, commands, events, and evidence receive opaque run-scoped tokens.
 */
@SuppressWarnings('PMD.ApexCRUDViolation')
global without sharing class TrustService {
    public static final String CATEGORY_EMAIL = 'Email';
    public static final String CATEGORY_PHONE = 'Phone';
    public static final String CATEGORY_PAYMENT_CARD = 'Payment Card';
    public static final String CATEGORY_US_SSN = 'US SSN';
    public static final String CATEGORY_IBAN = 'IBAN';
    public static final String CATEGORY_SALESFORCE_CLASSIFIED = 'Salesforce Classified';
    public static final Integer MAX_CONTENT_CHARACTERS = 131072;
    /** Longest stretch one detector scan reads; longer content is scanned in safe pieces. */
    private static final Integer DETECTION_CHUNK_CHARACTERS = 8192;
    @TestVisible
    private static Boolean failDetectionForTest = false;
    private static final Integer MAX_STRUCTURED_RECORDS = 200;
    private static final Integer MAX_STRUCTURED_DEPTH = 5;
    private static final Integer MAX_SCAN_CANDIDATES = 2000;
    public static final Integer MAX_FINAL_OUTPUTS_PER_CALL = 200;
    /** A run-scoped token: its category, its number in the run, and a random suffix, such as {{EMAIL_3_9f2c61ab}}. */
    private static final String PLACEHOLDER_REGEX = '\\{\\{(?:EMAIL|PHONE|CARD|SSN|IBAN|CLASSIFIED)_[0-9]{1,5}_[0-9a-f]{8}\\}\\}';
    private static final Map<String, String> TOKEN_LABELS = new Map<String, String>{
        CATEGORY_EMAIL => 'EMAIL',
        CATEGORY_PHONE => 'PHONE',
        CATEGORY_PAYMENT_CARD => 'CARD',
        CATEGORY_US_SSN => 'SSN',
        CATEGORY_IBAN => 'IBAN',
        CATEGORY_SALESFORCE_CLASSIFIED => 'CLASSIFIED'
    };
    private static final Pattern PLACEHOLDER_PATTERN = Pattern.compile(PLACEHOLDER_REGEX);
    private static final Pattern EMAIL_PATTERN = Pattern.compile(
        '(?i)(?<![A-Z0-9._%+\\-])[A-Z0-9._%+\\-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+(?![A-Z0-9_%+\\-])'
    );
    private static final Pattern SSN_PATTERN = Pattern.compile('(?<![0-9])(?!000|666|9[0-9]{2})[0-9]{3}[- ](?!00)[0-9]{2}[- ](?!0000)[0-9]{4}(?![0-9])');
    /**
     * Nine bare digits written right after their name, such as "SSN: 123456789".
     * Bare nine-digit numbers elsewhere are order or account numbers far more
     * often than SSNs. Group 1 is the number. Run only on text with digits,
     * and starting from a literal keyword, so it stays cheap on large content.
     */
    private static final Pattern SSN_KEYWORD_PATTERN = Pattern.compile(
        '(?i)\\b(?:ssn|tin|social security number|social security no\\.?|social security)[^0-9a-z]{1,10}([0-9]{9})(?![0-9])'
    );
    private static final Pattern PAYMENT_CARD_PATTERN = Pattern.compile('(?<![0-9])(?:[0-9][ -]?){12,18}[0-9](?![0-9])');
    private static final Pattern IBAN_PATTERN = Pattern.compile('(?i)(?<![A-Z0-9])[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]){11,30}(?![A-Z0-9])');
    private static final Pattern PHONE_PATTERN = Pattern.compile(
        '(?<![0-9])(?:\\+[1-9][0-9 .()\\-]{7,20}[0-9]|\\([2-9][0-9]{2}\\)[ .\\-]?[0-9]{3}[ .\\-][0-9]{4}|[2-9][0-9]{2}[ .\\-][0-9]{3}[ .\\-][0-9]{4})(?![0-9])'
    );
    private static Boolean purgeAuthorized = false;
    private static Boolean provenanceDowngradeAuthorized = false;

    /**
     * A protected-value token the model used wrongly: one that does not exist
     * in this run, has expired, or names a category the tool may not receive.
     * Core returns it to the model as a tool error instead of pausing the run.
     */
    public class TokenUseException extends AgentKernelException {
        public String code;

        public TokenUseException(String code, String message) {
            this(message);
            this.code = code;
        }
    }

    public static final String TOKEN_INVALID = 'TRUST_TOKEN_INVALID';
    public static final String TOKEN_CATEGORY_DENIED = 'TRUST_CATEGORY_DENIED';

    public class ProtectionContext {
        public Id runId { get; private set; }
        public Map<String, AgentTrustToken__c> tokensByFingerprint { get; private set; }
        public Map<String, AgentTrustToken__c> tokensByValue { get; private set; }
        public List<AgentTrustToken__c> pendingTokens { get; private set; }
        /** Saved model-authored mappings that org data also holds; save() stops releasing them to every tool. */
        private Map<Id, AgentTrustToken__c> provenanceDowngrades = new Map<Id, AgentTrustToken__c>();
        private Integer existingTokenCount;
        private Integer maxTokens;
        private Integer remainingScanCandidates;
        private Boolean requesterLoaded = false;
        private Boolean modelAuthored = false;
        private Id requesterId;

        private ProtectionContext(Id runId) {
            this.runId = runId;
            this.tokensByFingerprint = new Map<String, AgentTrustToken__c>();
            this.tokensByValue = new Map<String, AgentTrustToken__c>();
            this.pendingTokens = new List<AgentTrustToken__c>();
            this.existingTokenCount = 0;
            this.maxTokens = Math.min(
                AgentExecutionPolicyService.MAX_TRUST_TOKENS_PER_RUN_CEILING,
                Math.max(1, AgentExecutionPolicyService.resolve().maxTrustTokensPerRun)
            );
            this.remainingScanCandidates = MAX_SCAN_CANDIDATES;
        }
    }

    public static ProtectionContext open(Id runId) {
        if (runId == null) {
            throw configuration('A run is required for trust protection.');
        }
        assertProtectionAuthorized(runId);
        return newContext(runId);
    }

    /**
     * Opens a context for a lifecycle transition that has already authorized
     * its caller, such as an approver's rejection comment or an operator's
     * reason. Protection only replaces values with tokens; it never reveals a
     * stored value, so it needs no run-control authority of its own.
     */
    public static ProtectionContext openForAuthorizedTransition(Id runId) {
        if (runId == null) {
            throw configuration('A run is required for trust protection.');
        }
        return newContext(runId);
    }

    private static ProtectionContext newContext(Id runId) {
        ProtectionContext context = new ProtectionContext(runId);
        context.existingTokenCount = [SELECT COUNT() FROM AgentTrustToken__c WHERE AgentRun__c = :runId WITH SYSTEM_MODE];
        return context;
    }

    public static Boolean needsProtection(List<String> contents) {
        for (String content : contents == null ? new List<String>() : contents) {
            if (!String.isBlank(content) && (containsToken(content) || containsDetectableValue(content))) {
                return true;
            }
        }
        return false;
    }

    /** True when content holds a raw value a detector would tokenize; existing tokens are ignored. */
    /** Whether the text contains a protected-value token. */
    public static Boolean containsToken(String content) {
        return !String.isBlank(content) && content.contains('{{') && PLACEHOLDER_PATTERN.matcher(content).find();
    }

    /** Whether the whole value is one token, which stands in for a value that is checked once it is resolved. */
    public static Boolean isToken(String content) {
        return !String.isBlank(content) && content.startsWith('{{') && PLACEHOLDER_PATTERN.matcher(content).matches();
    }

    public static Boolean containsDetectableValue(String content) {
        return !String.isBlank(content) &&
            ((content.contains('@') && emailPattern().matcher(content).find()) ||
            (containsDigit(content) &&
            (ssnPattern().matcher(content).find() ||
            !keywordSsns(content).isEmpty() ||
            paymentCardPattern().matcher(content).find() ||
            ibanPattern().matcher(content).find() ||
            phonePattern().matcher(content).find())));
    }

    public static String protect(ProtectionContext context, String content) {
        return protect(context, content, false);
    }

    /**
     * Protects text. When modelAuthored is true the text is the model's own
     * output: the model never saw a plaintext value from the org (those reach
     * it only as tokens), so a value it wrote itself stays usable by any tool.
     */
    public static String protect(ProtectionContext context, String content, Boolean modelAuthored) {
        requireContext(context);
        context.modelAuthored = modelAuthored == true;
        if (content == null || content == '') {
            return content;
        }
        assertBounded(content);
        hydrateReferencedTokens(context, content);
        validateContextTokens(context, content);
        List<String> protectedParts = new List<String>();
        try {
            for (String part : detectionChunks(content)) {
                hydrateDetectedFingerprints(context, part);
                protectedParts.add(protectChunk(context, part));
            }
        } catch (AgentKernelException deliberateLimit) {
            // Token ceilings, oversized values, and expired references are Core's own refusals.
            throw deliberateLimit;
        } catch (Exception detectionFailure) {
            // Fail closed: content whose detection could not finish is never stored or sent as written.
            return withheld(detectionFailure);
        }
        return String.join(protectedParts, '');
    }

    private static String protectChunk(ProtectionContext context, String content) {
        if (Test.isRunningTest() && failDetectionForTest) {
            throw new StringException('Simulated detection failure.');
        }
        String result = content;
        result = replaceMatches(context, result, CATEGORY_EMAIL, emailPattern(), false);
        result = replaceMatches(context, result, CATEGORY_US_SSN, ssnPattern(), false);
        result = replaceKeywordSsns(context, result);
        result = replaceMatches(context, result, CATEGORY_IBAN, ibanPattern(), true);
        result = replaceMatches(context, result, CATEGORY_PAYMENT_CARD, paymentCardPattern(), true);
        result = replaceMatches(context, result, CATEGORY_PHONE, phonePattern(), false);
        return result;
    }

    /**
     * Splits long content so each detector scan stays within the platform's
     * regex limits. Cuts fall only where no detected value can span: after a
     * line break, or after a comma that ends a JSON member (a raw `,"` never
     * occurs inside a JSON string). A stretch with no such cut stays whole.
     */
    @TestVisible
    private static List<String> detectionChunks(String content) {
        if (content.length() <= DETECTION_CHUNK_CHARACTERS) {
            return new List<String>{ content };
        }
        List<String> parts = new List<String>();
        Integer start = 0;
        while (start < content.length()) {
            Integer limitEnd = Math.min(content.length(), start + DETECTION_CHUNK_CHARACTERS);
            if (limitEnd == content.length()) {
                parts.add(content.substring(start));
                break;
            }
            Integer cut = Math.max(content.lastIndexOf('\n', limitEnd - 1), content.lastIndexOf(',"', limitEnd - 2));
            if (cut < start) {
                // No safe cut inside the window: extend to the next one, or the end.
                Integer newline = content.indexOf('\n', limitEnd);
                Integer member = content.indexOf(',"', limitEnd);
                Integer next = newline < 0 ? member : (member < 0 ? newline : Math.min(newline, member));
                cut = next < 0 ? content.length() - 1 : next;
            }
            parts.add(content.substring(start, cut + 1));
            start = cut + 1;
        }
        return parts;
    }

    /** What is stored or sent when detection could not finish: no content, only that it was withheld and why. */
    private static String withheld(Exception detectionFailure) {
        return JSON.serialize(
            new Map<String, Object>{
                'contentWithheld' => true,
                'reason' => 'Sensitive-value detection could not finish, so this content was withheld.',
                'errorType' => detectionFailure.getTypeName()
            }
        );
    }

    public static String protectRecordSets(ProtectionContext context, Map<String, List<SObject>> recordSets) {
        requireContext(context);
        // Record data is never the model's own text, including the classified values tokenized below.
        context.modelAuthored = false;
        return protect(context, JSON.serialize(normalizeRecordSets(context, recordSets)));
    }

    public static String serializeRecordSets(Map<String, List<SObject>> recordSets) {
        String serialized = JSON.serialize(normalizeRecordSets(null, recordSets));
        assertBounded(serialized);
        return serialized;
    }

    private static Map<String, Object> normalizeRecordSets(ProtectionContext context, Map<String, List<SObject>> recordSets) {
        if (recordSets == null || recordSets.isEmpty()) {
            return new Map<String, Object>();
        }
        StructuredRecordState state = new StructuredRecordState();
        Map<String, List<SObject>> readableSets = new Map<String, List<SObject>>();
        for (String sourceName : recordSets.keySet()) {
            if (String.isBlank(sourceName)) {
                throw configuration('Structured record-set names must be nonblank.');
            }
            List<SObject> sourceRecords = recordSets.get(sourceName) == null ? new List<SObject>() : recordSets.get(sourceName);
            readableSets.put(
                sourceName,
                sourceRecords.isEmpty() ? new List<SObject>() : Security.stripInaccessible(AccessType.READABLE, sourceRecords).getRecords()
            );
        }
        Id requesterId = context == null ? null : attendedRequester(context);
        if (requesterId != null) {
            state.requesterView = new RequesterView(requesterId, readableSets.values());
        }
        Map<String, Object> protectedSets = new Map<String, Object>();
        for (String sourceName : readableSets.keySet()) {
            List<Object> serializedRecords = new List<Object>();
            for (SObject record : readableSets.get(sourceName)) {
                Map<String, Object> serialized = protectRecord(context, record, 0, state);
                if (serialized != null) {
                    serializedRecords.add(serialized);
                }
            }
            protectedSets.put(sourceName, serializedRecords);
        }
        return protectedSets;
    }

    /** The person an attended run works for; the run's records are limited to what they can read. */
    private static Id attendedRequester(ProtectionContext context) {
        if (!context.requesterLoaded) {
            List<AgentRun__c> runs = [SELECT AttendedBy__c FROM AgentRun__c WHERE Id = :context.runId WITH SYSTEM_MODE LIMIT 1];
            context.requesterId = runs.isEmpty() ? null : runs[0].AttendedBy__c;
            context.requesterLoaded = true;
        }
        return context.requesterId;
    }

    public static void save(ProtectionContext context) {
        requireContext(context);
        if (!context.provenanceDowngrades.isEmpty()) {
            provenanceDowngradeAuthorized = true;
            try {
                Database.update(context.provenanceDowngrades.values(), AccessLevel.SYSTEM_MODE);
            } finally {
                provenanceDowngradeAuthorized = false;
            }
            context.provenanceDowngrades.clear();
        }
        if (context.pendingTokens.isEmpty()) {
            return;
        }
        Integer before = context.existingTokenCount;
        if (before + context.pendingTokens.size() > context.maxTokens) {
            throw configuration('Trust token count exceeds the configured per-run limit.');
        }
        Database.insert(context.pendingTokens, AccessLevel.SYSTEM_MODE);
        for (AgentTrustToken__c mapping : context.pendingTokens) {
            context.tokensByFingerprint.put(mapping.ValueFingerprint__c, mapping);
            context.tokensByValue.put(mapping.Token__c, mapping);
        }
        context.existingTokenCount += context.pendingTokens.size();
        context.pendingTokens.clear();
        Integer warningThreshold = (context.maxTokens * 4) / 5;
        if (before < warningThreshold && context.existingTokenCount >= warningThreshold) {
            AgentOperationsLog.emit(LoggingLevel.WARN, 'TRUST_TOKEN_BUDGET_80_PERCENT', context.runId, null, context.existingTokenCount, null);
        }
    }

    public static String resolveForTool(Id runId, Id commandId, String leaseToken, String content) {
        if (content == null || content == '') {
            return content;
        }
        assertBounded(content);
        Set<String> allowed = authorizedToolCategories(runId, commandId, leaseToken);
        return resolve(runId, content, allowed, true);
    }

    /**
     * Checks that every placeholder in the content is a live token of this run.
     * Content without placeholders reads no mapping, so it needs no
     * authorization check; content with them is checked before any read.
     */
    public static void validateTokens(Id runId, String content) {
        if (runId == null || String.isBlank(content)) {
            return;
        }
        Matcher matcher = PLACEHOLDER_PATTERN.matcher(content);
        Set<String> referenced = new Set<String>();
        while (matcher.find()) {
            referenced.add(matcher.group());
        }
        if (referenced.isEmpty()) {
            return;
        }
        assertProtectionAuthorized(runId);
        Integer validCount = 0;
        for (AgentTrustToken__c mapping : queryMappings(runId, referenced, null)) {
            if (mapping.OriginalValue__c != null && mapping.PurgedAt__c == null) {
                validCount++;
            }
        }
        if (validCount != referenced.size()) {
            throw new TokenUseException(TOKEN_INVALID, 'Content contains an unknown, expired, or cross-run protected-value token.');
        }
    }

    /** One run's resolved answer, or why it could not be resolved. */
    public class FinalOutput {
        public String output;
        public Exception failure;
    }

    global static String resolveFinalOutput(Id runId) {
        FinalOutput result = resolveFinalOutputs(new Set<Id>{ runId }).get(runId);
        if (result.failure != null) {
            throw result.failure;
        }
        return result.output;
    }

    /**
     * Resolves the answers of up to 200 runs with a fixed number of queries and
     * one audit write, so a bulk Flow stays within limits. Each requested run
     * gets an entry; one run's failure never affects the others.
     */
    public static Map<Id, FinalOutput> resolveFinalOutputs(Set<Id> runIds) {
        if (!isFinalOutputResolutionPermitted()) {
            throw new AgentKernelException.AuthorizationException('Trust resolution permission is required.');
        }
        Set<Id> requested = runIds == null ? new Set<Id>() : runIds.clone();
        requested.remove(null);
        if (requested.size() > MAX_FINAL_OUTPUTS_PER_CALL) {
            throw new AgentKernelException.InvalidTransitionException('Resolve at most ' + MAX_FINAL_OUTPUTS_PER_CALL + ' run answers at once.');
        }
        Map<Id, AgentRun__c> visible = new Map<Id, AgentRun__c>();
        if (!requested.isEmpty()) {
            try {
                visible = new Map<Id, AgentRun__c>(
                    [SELECT Id, Status__c, ContinuationMode__c, Output__c FROM AgentRun__c WHERE Id IN :requested WITH USER_MODE]
                );
            } catch (Exception inaccessible) {
                visible = new Map<Id, AgentRun__c>();
            }
        }
        Map<Id, FinalOutput> results = new Map<Id, FinalOutput>();
        Map<Id, Set<String>> referencedByRun = new Map<Id, Set<String>>();
        Set<String> allReferenced = new Set<String>();
        for (Id runId : requested) {
            FinalOutput result = new FinalOutput();
            results.put(runId, result);
            AgentRun__c run = visible.get(runId);
            if (run == null) {
                result.failure = new AgentKernelException.NotFoundException('The run was not found or is inaccessible.');
                continue;
            }
            if (!hasResolvableAnswer(run.Status__c, run.ContinuationMode__c)) {
                result.failure = new AgentKernelException.InvalidTransitionException(
                    'Only a succeeded run, or a conversation waiting for a reply, has a resolvable answer.'
                );
                continue;
            }
            result.output = run.Output__c;
            Set<String> referenced = referencedTokens(run.Output__c);
            // Nothing protected is revealed without tokens, so there is nothing to audit and no reason to lock the run.
            if (!referenced.isEmpty()) {
                referencedByRun.put(runId, referenced);
                allReferenced.addAll(referenced);
            }
        }
        if (referencedByRun.isEmpty()) {
            return results;
        }
        Map<Id, Map<String, AgentTrustToken__c>> mappingsByRun = new Map<Id, Map<String, AgentTrustToken__c>>();
        for (AgentTrustToken__c mapping : queryMappings(referencedByRun.keySet(), allReferenced)) {
            if (!mappingsByRun.containsKey(mapping.AgentRun__c)) {
                mappingsByRun.put(mapping.AgentRun__c, new Map<String, AgentTrustToken__c>());
            }
            mappingsByRun.get(mapping.AgentRun__c).put(mapping.Token__c, mapping);
        }
        Map<Id, Set<String>> categoriesByRun = new Map<Id, Set<String>>();
        Map<Id, Integer> tokenCountByRun = new Map<Id, Integer>();
        for (Id runId : referencedByRun.keySet()) {
            FinalOutput result = results.get(runId);
            Set<String> referenced = referencedByRun.get(runId);
            Map<String, AgentTrustToken__c> mappings = mappingsByRun.containsKey(runId) ? mappingsByRun.get(runId) : new Map<String, AgentTrustToken__c>();
            try {
                result.output = resolveWith(result.output, referenced, mappings, supportedCategories(), false);
            } catch (TokenUseException unresolvable) {
                result.output = null;
                result.failure = unresolvable;
                continue;
            }
            Set<String> categories = new Set<String>();
            for (AgentTrustToken__c mapping : mappings.values()) {
                categories.add(mapping.Category__c);
            }
            categoriesByRun.put(runId, categories);
            tokenCountByRun.put(runId, referenced.size());
        }
        if (!categoriesByRun.isEmpty()) {
            AgentKernel.recordTrustOutputResolutions(categoriesByRun, tokenCountByRun);
        }
        return results;
    }

    /**
     * Detokenizes a waiting tool command's input so a Human Decision holder can
     * see what they approve. Every resolution is audited on the run.
     */
    /** Plaintext input of a waiting tool call. AgentApprovalService authorizes the reviewer first. */
    public static String resolveWaitingToolInput(Id runId, Id commandId) {
        AgentHumanDecisionGuard.assertAuthorized();
        List<AgentCommand__c> commands = [
            SELECT Id, Status__c, CommandType__c, OperationKey__c, Input__c
            FROM AgentCommand__c
            WHERE Id = :commandId AND AgentRun__c = :runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (commands.isEmpty()) {
            throw new AgentKernelException.NotFoundException('The approval command was not found.');
        }
        AgentCommand__c command = commands[0];
        if (command.Status__c != AgentKernelModels.COMMAND_STATUS_WAITING || command.CommandType__c != AgentKernelModels.COMMAND_TYPE_TOOL) {
            throw new AgentKernelException.InvalidTransitionException('Only a waiting tool command has an approval input to review.');
        }
        Set<String> referenced = referencedTokens(command.Input__c);
        if (referenced.isEmpty()) {
            return command.Input__c;
        }
        Set<String> categories = new Set<String>();
        for (AgentTrustToken__c mapping : queryMappings(runId, referenced, null)) {
            categories.add(mapping.Category__c);
        }
        String resolved = resolve(runId, command.Input__c, supportedCategories(), false);
        AgentKernel.recordTrustApprovalInputResolution(runId, command, categories, referenced.size());
        return resolved;
    }

    /** A succeeded run's final answer, or a conversation's latest answer while it waits for the reply. */
    public static Boolean hasResolvableAnswer(String status, String continuationMode) {
        return status == AgentKernelModels.RUN_STATUS_SUCCEEDED ||
            (status == AgentKernelModels.RUN_STATUS_WAITING &&
            continuationMode == AgentKernelModels.CONTINUATION_CONVERSATION);
    }

    public static Boolean isFinalOutputResolutionPermitted() {
        return FeatureManagement.checkPermission('AgentKernelTrustResolution');
    }

    public static Integer purgeBounded(Set<Id> runIds, Integer requestedLimit) {
        if (runIds == null || runIds.isEmpty()) {
            return 0;
        }
        if (!PayloadRetentionPurgeService.isTrustPurgeAuthorized()) {
            throw new AgentKernelException.AuthorizationException('Trust-token purge permission is required.');
        }
        Integer safeLimit = Math.max(1, Math.min(2000, requestedLimit == null ? 1000 : requestedLimit));
        List<AgentTrustToken__c> dueMappings = (List<AgentTrustToken__c>) Database.query(
            'SELECT Id FROM AgentTrustToken__c' + ' WHERE AgentRun__c IN :runIds AND PurgedAt__c = NULL' + ' LIMIT :safeLimit FOR UPDATE',
            AccessLevel.SYSTEM_MODE
        );
        return purgeMappings(dueMappings);
    }

    /**
     * Purges every live mapping after a sandbox copy, when no production
     * operator could have authorized the copy's vault contents.
     */
    public static Integer purgeCopiedVault(List<AgentTrustToken__c> mappings) {
        return purgeMappings(mappings);
    }

    private static Integer purgeMappings(List<AgentTrustToken__c> mappings) {
        List<AgentTrustToken__c> updates = new List<AgentTrustToken__c>();
        for (AgentTrustToken__c mapping : mappings) {
            updates.add(new AgentTrustToken__c(Id = mapping.Id, OriginalValue__c = null, ValueFingerprint__c = null, PurgedAt__c = System.now()));
        }
        if (!updates.isEmpty()) {
            purgeAuthorized = true;
            try {
                Database.update(updates, AccessLevel.SYSTEM_MODE);
            } finally {
                purgeAuthorized = false;
            }
        }
        return updates.size();
    }

    public static Boolean isPurgeAuthorized() {
        return purgeAuthorized;
    }

    public static Boolean isProvenanceDowngradeAuthorized() {
        return provenanceDowngradeAuthorized;
    }

    private static String replaceMatches(ProtectionContext context, String content, String category, Pattern detector, Boolean requiresValidation) {
        Matcher matcher = detector.matcher(content);
        Matcher trustTokenMatcher = PLACEHOLDER_PATTERN.matcher(content);
        Boolean hasTrustToken = trustTokenMatcher.find();
        List<Integer> starts = new List<Integer>();
        List<Integer> ends = new List<Integer>();
        List<String> values = new List<String>();
        while (matcher.find()) {
            context.remainingScanCandidates--;
            if (context.remainingScanCandidates < 0) {
                throw configuration('TRUST_SCAN_WORK_LIMIT_EXCEEDED');
            }
            while (hasTrustToken && trustTokenMatcher.end() <= matcher.start()) {
                hasTrustToken = trustTokenMatcher.find();
            }
            if (hasTrustToken && trustTokenMatcher.start() < matcher.end()) {
                continue;
            }
            String value = matcher.group();
            if (!requiresValidation || isValid(category, value)) {
                if (value.length() > MAX_CONTENT_CHARACTERS) {
                    throw configuration('A detected sensitive value exceeds the protected-value limit.');
                }
                starts.add(matcher.start());
                ends.add(matcher.end());
                values.add(value);
            }
        }
        if (values.isEmpty()) {
            return content;
        }
        List<String> segments = new List<String>();
        Integer cursor = 0;
        for (Integer index = 0; index < values.size(); index++) {
            segments.add(content.substring(cursor, starts[index]));
            segments.add(tokenFor(context, category, values[index]));
            cursor = ends[index];
        }
        segments.add(content.substring(cursor));
        return String.join(segments, '');
    }

    /** Start and end of each plausible keyword-anchored SSN; empty for text without digits. */
    private static List<List<Integer>> keywordSsns(String content) {
        List<List<Integer>> spans = new List<List<Integer>>();
        if (String.isBlank(content) || !containsDigit(content)) {
            return spans;
        }
        Matcher matcher = SSN_KEYWORD_PATTERN.matcher(content);
        while (matcher.find()) {
            String value = matcher.group(1);
            String area = value.left(3);
            if (area != '000' && area != '666' && !area.startsWith('9') && value.mid(3, 2) != '00' && value.right(4) != '0000') {
                spans.add(new List<Integer>{ matcher.start(1), matcher.end(1) });
            }
        }
        return spans;
    }

    private static String replaceKeywordSsns(ProtectionContext context, String content) {
        List<List<Integer>> spans = keywordSsns(content);
        if (spans.isEmpty()) {
            return content;
        }
        List<String> segments = new List<String>();
        Integer cursor = 0;
        for (List<Integer> span : spans) {
            context.remainingScanCandidates--;
            if (context.remainingScanCandidates < 0) {
                throw configuration('TRUST_SCAN_WORK_LIMIT_EXCEEDED');
            }
            segments.add(content.substring(cursor, span[0]));
            segments.add(tokenFor(context, CATEGORY_US_SSN, content.substring(span[0], span[1])));
            cursor = span[1];
        }
        segments.add(content.substring(cursor));
        return String.join(segments, '');
    }

    private static String tokenFor(ProtectionContext context, String category, String value) {
        if (value != null && value.length() > MAX_CONTENT_CHARACTERS) {
            throw configuration('A sensitive value exceeds the protected-value limit.');
        }
        String fingerprint = fingerprint(context.runId, category, value);
        AgentTrustToken__c existing = context.tokensByFingerprint.get(fingerprint);
        if (existing != null) {
            if (existing.OriginalValue__c == null) {
                throw new AgentKernelException.AuthorizationException('A referenced sensitive value has expired.');
            }
            if (!context.modelAuthored && existing.ModelAuthored__c == true) {
                // The value also came from org data, so only tools allowed its category may receive it.
                existing.ModelAuthored__c = false;
                if (existing.Id != null) {
                    context.provenanceDowngrades.put(existing.Id, new AgentTrustToken__c(Id = existing.Id, ModelAuthored__c = false));
                }
            }
            return existing.Token__c;
        }
        if (context.existingTokenCount + context.pendingTokens.size() >= context.maxTokens) {
            throw configuration('Trust token count exceeds the configured per-run limit.');
        }
        // Resolution is scoped to the run, so the token needs no secrecy; the
        // category label and number help the model copy and reason about it.
        String opaqueReference =
            '{{' +
            TOKEN_LABELS.get(category) +
            '_' +
            (context.existingTokenCount +
            context.pendingTokens.size() +
            1) +
            '_' +
            EncodingUtil.convertToHex(Crypto.generateAesKey(128)).substring(0, 8).toLowerCase() +
            '}}';
        AgentTrustToken__c mapping = new AgentTrustToken__c(
            AgentRun__c = context.runId,
            Token__c = opaqueReference,
            Category__c = category,
            OriginalValue__c = value,
            ValueFingerprint__c = fingerprint,
            ModelAuthored__c = context.modelAuthored
        );
        context.tokensByFingerprint.put(fingerprint, mapping);
        context.tokensByValue.put(opaqueReference, mapping);
        context.pendingTokens.add(mapping);
        return opaqueReference;
    }

    private static String resolve(Id runId, String content, Set<String> allowed, Boolean rejectDisallowed) {
        if (runId == null || content == null || content == '') {
            return content;
        }
        Set<String> referenced = referencedTokens(content);
        if (referenced.isEmpty()) {
            return content;
        }
        Map<String, AgentTrustToken__c> mappings = new Map<String, AgentTrustToken__c>();
        for (AgentTrustToken__c mapping : queryMappings(runId, referenced, null)) {
            mappings.put(mapping.Token__c, mapping);
        }
        return resolveWith(content, referenced, mappings, allowed, rejectDisallowed);
    }

    /** Replaces referenced tokens with their run's loaded mappings; every token must have a live mapping. */
    private static String resolveWith(
        String content,
        Set<String> referenced,
        Map<String, AgentTrustToken__c> mappings,
        Set<String> allowed,
        Boolean rejectDisallowed
    ) {
        if (mappings.size() != referenced.size()) {
            throw new TokenUseException(TOKEN_INVALID, 'Content contains an unknown or cross-run protected-value token.');
        }
        for (String opaqueReference : referenced) {
            AgentTrustToken__c mapping = mappings.get(opaqueReference);
            if (mapping.OriginalValue__c == null || mapping.PurgedAt__c != null) {
                throw new TokenUseException(TOKEN_INVALID, 'A referenced protected value has expired.');
            }
            if (!isReleasable(mapping, allowed) && rejectDisallowed) {
                throw new TokenUseException(
                    TOKEN_CATEGORY_DENIED,
                    'This tool may not receive protected ' + mapping.Category__c + ' values such as ' + opaqueReference + '.'
                );
            }
        }
        Object parsed = parseJsonContainer(content);
        if (parsed != null) {
            // An original value is untrusted text: it may only ever become part
            // of one string leaf, never a key, sibling, or container.
            return JSON.serialize(resolveJsonNode(parsed, mappings, allowed));
        }
        return substitute(content, mappings, allowed);
    }

    /** A value is released for an allowed category, or when the model wrote it itself. */
    private static Boolean isReleasable(AgentTrustToken__c mapping, Set<String> allowed) {
        return allowed.contains(mapping.Category__c) || mapping.ModelAuthored__c == true;
    }

    private static Object parseJsonContainer(String content) {
        String trimmed = content.trim();
        if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
            return null;
        }
        try {
            return JSON.deserializeUntyped(content);
        } catch (JSONException notJson) {
            return null;
        }
    }

    private static Object resolveJsonNode(Object node, Map<String, AgentTrustToken__c> mappings, Set<String> allowed) {
        if (node instanceof String) {
            return substitute((String) node, mappings, allowed);
        }
        if (node instanceof Map<String, Object>) {
            Map<String, Object> source = (Map<String, Object>) node;
            Map<String, Object> resolved = new Map<String, Object>();
            for (String key : source.keySet()) {
                resolved.put(key, resolveJsonNode(source.get(key), mappings, allowed));
            }
            return resolved;
        }
        if (node instanceof List<Object>) {
            List<Object> resolved = new List<Object>();
            for (Object item : (List<Object>) node) {
                resolved.add(resolveJsonNode(item, mappings, allowed));
            }
            return resolved;
        }
        return node;
    }

    private static String substitute(String content, Map<String, AgentTrustToken__c> mappings, Set<String> allowed) {
        List<String> segments = new List<String>();
        Matcher matcher = PLACEHOLDER_PATTERN.matcher(content);
        Integer cursor = 0;
        while (matcher.find()) {
            String opaqueReference = matcher.group();
            AgentTrustToken__c mapping = mappings.get(opaqueReference);
            segments.add(content.substring(cursor, matcher.start()));
            segments.add(mapping != null && isReleasable(mapping, allowed) ? mapping.OriginalValue__c : opaqueReference);
            cursor = matcher.end();
        }
        segments.add(content.substring(cursor));
        return String.join(segments, '');
    }

    /**
     * Vault records deliberately remain hidden by FLS from execution users.
     * Only this trusted Core boundary may load their raw values.
     */
    private static List<AgentTrustToken__c> queryMappings(Id runId, Set<String> tokens, Integer maxRows) {
        // Mappings from before the current key (a copied sandbox vault awaiting
        // purge) are never resolvable, even before their rows are purged.
        Datetime keyCreatedAt = TrustKeyProvider.currentKeyCreatedAt();
        String queryText =
            'SELECT Id, AgentRun__c, Token__c, Category__c, OriginalValue__c,' +
            ' ValueFingerprint__c, PurgedAt__c, ModelAuthored__c' +
            ' FROM AgentTrustToken__c WHERE AgentRun__c = :runId AND CreatedDate >= :keyCreatedAt';
        if (tokens != null) {
            queryText += ' AND Token__c IN :tokens';
        }
        if (maxRows != null) {
            queryText += ' LIMIT :maxRows';
        }
        return (List<AgentTrustToken__c>) Database.query(queryText, AccessLevel.SYSTEM_MODE);
    }

    /** The mappings of several runs' referenced tokens in one query, with the same key rule as a single run. */
    private static List<AgentTrustToken__c> queryMappings(Set<Id> runIds, Set<String> tokens) {
        Datetime keyCreatedAt = TrustKeyProvider.currentKeyCreatedAt();
        return [
            SELECT Id, AgentRun__c, Token__c, Category__c, OriginalValue__c, ValueFingerprint__c, PurgedAt__c, ModelAuthored__c
            FROM AgentTrustToken__c
            WHERE AgentRun__c IN :runIds AND Token__c IN :tokens AND CreatedDate >= :keyCreatedAt
            WITH SYSTEM_MODE
        ];
    }

    private static void hydrateReferencedTokens(ProtectionContext context, String content) {
        Set<String> missing = referencedTokens(content);
        missing.removeAll(context.tokensByValue.keySet());
        if (missing.isEmpty()) {
            return;
        }
        hydrate(context, queryMappings(context.runId, missing, null));
    }

    private static void hydrateDetectedFingerprints(ProtectionContext context, String content) {
        Set<String> fingerprints = new Set<String>();
        collectFingerprints(context, content, CATEGORY_EMAIL, emailPattern(), false, fingerprints);
        collectFingerprints(context, content, CATEGORY_US_SSN, ssnPattern(), false, fingerprints);
        for (List<Integer> span : keywordSsns(content)) {
            fingerprints.add(fingerprint(context.runId, CATEGORY_US_SSN, content.substring(span[0], span[1])));
        }
        collectFingerprints(context, content, CATEGORY_IBAN, ibanPattern(), true, fingerprints);
        collectFingerprints(context, content, CATEGORY_PAYMENT_CARD, paymentCardPattern(), true, fingerprints);
        collectFingerprints(context, content, CATEGORY_PHONE, phonePattern(), false, fingerprints);
        fingerprints.removeAll(context.tokensByFingerprint.keySet());
        if (fingerprints.isEmpty()) {
            return;
        }
        hydrate(context, queryMappingsByFingerprints(context.runId, fingerprints));
    }

    private static void collectFingerprints(
        ProtectionContext context,
        String content,
        String category,
        Pattern detector,
        Boolean requiresValidation,
        Set<String> fingerprints
    ) {
        if ((category == CATEGORY_EMAIL && !content.contains('@')) || (category != CATEGORY_EMAIL && !containsDigit(content))) {
            return;
        }
        Matcher matcher = detector.matcher(content);
        while (matcher.find()) {
            context.remainingScanCandidates--;
            if (context.remainingScanCandidates < 0) {
                throw configuration('TRUST_SCAN_WORK_LIMIT_EXCEEDED');
            }
            String value = matcher.group();
            if (!requiresValidation || isValid(category, value)) {
                fingerprints.add(fingerprint(context.runId, category, value));
            }
        }
    }

    private static List<AgentTrustToken__c> queryMappingsByFingerprints(Id runId, Set<String> fingerprints) {
        Datetime keyCreatedAt = TrustKeyProvider.currentKeyCreatedAt();
        return [
            SELECT Id, AgentRun__c, Token__c, Category__c, OriginalValue__c, ValueFingerprint__c, PurgedAt__c, ModelAuthored__c
            FROM AgentTrustToken__c
            WHERE AgentRun__c = :runId AND ValueFingerprint__c IN :fingerprints AND CreatedDate >= :keyCreatedAt
            WITH SYSTEM_MODE
        ];
    }

    private static void hydrate(ProtectionContext context, List<AgentTrustToken__c> mappings) {
        for (AgentTrustToken__c mapping : mappings) {
            context.tokensByFingerprint.put(mapping.ValueFingerprint__c, mapping);
            context.tokensByValue.put(mapping.Token__c, mapping);
        }
    }

    /** Native scan: an Apex character loop over maximum-size content costs seconds of CPU. */
    private static Boolean containsDigit(String content) {
        return content != null && content.containsAny('0123456789');
    }

    private static Set<String> parseAllowedCategories(String configured) {
        Set<String> result = new Set<String>();
        if (String.isBlank(configured)) {
            return result;
        }
        Set<String> supported = supportedCategories();
        for (String value : configured.split(';')) {
            if (!supported.contains(value)) {
                throw configuration('The tool contains an unsupported sensitive-data category.');
            }
            result.add(value);
        }
        return result;
    }

    /**
     * Sensitive values are released only to the current leased tool command.
     * Categories are taken from the active configured tool, never from a
     * caller-supplied string.
     */
    private static Set<String> authorizedToolCategories(Id runId, Id commandId, String leaseToken) {
        if (runId == null || commandId == null || String.isBlank(leaseToken)) {
            throw new AgentKernelException.AuthorizationException('A leased tool command is required to resolve sensitive data.');
        }
        List<AgentCommand__c> commands = [
            SELECT AgentRun__c, CommandType__c, Status__c, LeaseToken__c, ToolName__c
            FROM AgentCommand__c
            WHERE Id = :commandId AND AgentRun__c = :runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (
            commands.size() != 1 ||
            commands[0].CommandType__c != AgentKernelModels.COMMAND_TYPE_TOOL ||
            commands[0].Status__c != AgentKernelModels.COMMAND_STATUS_LEASED ||
            !leaseToken.equals(commands[0].LeaseToken__c)
        ) {
            throw new AgentKernelException.AuthorizationException('The tool command no longer owns sensitive-data resolution.');
        }
        AgentRun__c run = [
            SELECT
                Id,
                InitiatingUser__c,
                ExecutionIdentity__c,
                LoopbackNamedCredential__c,
                ExpectedPrincipalUser__c,
                ResolvedPrincipalUser__c,
                ExecutionContextStatus__c
            FROM AgentRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        ExecutionIdentityService.assertEstablishedBusinessPrincipal(run);
        return parseAllowedCategories(AgentRunConfigurationService.getTool(runId, commands[0].ToolName__c).AllowedSensitiveDataCategories__c);
    }

    private static void assertProtectionAuthorized(Id runId) {
        List<AgentRun__c> runs = [
            SELECT InitiatingUser__c, ExecutionIdentity__c, ExpectedPrincipalUser__c, ResolvedPrincipalUser__c, ExecutionContextStatus__c
            FROM AgentRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (runs.isEmpty()) {
            throw new AgentKernelException.NotFoundException('Agent run was not found.');
        }
        AgentRun__c run = runs[0];
        if (run.InitiatingUser__c == UserInfo.getUserId()) {
            return;
        }
        if (
            ExecutionIdentityService.usesIdentity(run) &&
            run.ExpectedPrincipalUser__c == UserInfo.getUserId() &&
            run.ResolvedPrincipalUser__c == UserInfo.getUserId() &&
            run.ExecutionContextStatus__c == ExecutionIdentityService.CONTEXT_ESTABLISHED
        ) {
            return;
        }
        try {
            ExecutionIdentityService.assertCanResume(run);
            return;
        } catch (AgentKernelException.ConfigurationException notRunController) {
            // Fall through to the uniform vault authorization failure.
        }
        throw new AgentKernelException.AuthorizationException('The current principal is not authorized for this run trust context.');
    }

    private static Set<String> referencedTokens(String content) {
        Set<String> referenced = new Set<String>();
        if (String.isBlank(content)) {
            return referenced;
        }
        Matcher matcher = PLACEHOLDER_PATTERN.matcher(content);
        while (matcher.find()) {
            referenced.add(matcher.group());
        }
        return referenced;
    }

    private static void validateContextTokens(ProtectionContext context, String content) {
        for (String opaqueReference : referencedTokens(content)) {
            AgentTrustToken__c mapping = context.tokensByValue.get(opaqueReference);
            if (mapping == null || mapping.OriginalValue__c == null) {
                throw new TokenUseException(TOKEN_INVALID, 'Content contains an unknown, expired, or cross-run protected-value token.');
            }
        }
    }

    private static Set<String> supportedCategories() {
        return new Set<String>{ CATEGORY_EMAIL, CATEGORY_PHONE, CATEGORY_PAYMENT_CARD, CATEGORY_US_SSN, CATEGORY_IBAN, CATEGORY_SALESFORCE_CLASSIFIED };
    }

    private static Map<String, Object> protectRecord(ProtectionContext context, SObject record, Integer depth, StructuredRecordState state) {
        if (record == null) {
            return null;
        }
        if (depth > MAX_STRUCTURED_DEPTH) {
            throw configuration('Structured record output exceeds the supported relationship depth.');
        }
        state.recordCount++;
        if (state.recordCount > MAX_STRUCTURED_RECORDS) {
            throw configuration('Structured record output exceeds the 200-record limit.');
        }
        Schema.DescribeSObjectResult describe = record.getSObjectType().getDescribe();
        String objectApiName = describe.getName();
        Map<String, Schema.SObjectField> fields = describe.fields.getMap();
        Map<String, Object> result = new Map<String, Object>();
        Map<String, Object> populated = record.getPopulatedFieldsAsMap();
        RequesterView requester = state.requesterView;
        if (requester != null && !requester.canReadRecord(populated)) {
            return null;
        }
        for (String fieldName : populated.keySet()) {
            Object value = populated.get(fieldName);
            if (
                requester != null &&
                !(value instanceof List<SObject>) &&
                !requester.canReadField(record.getSObjectType(), fieldName, value instanceof SObject)
            ) {
                continue;
            }
            // Child records first: Apex also reports a child record list as an SObject.
            if (value instanceof List<SObject>) {
                List<Object> children = new List<Object>();
                for (SObject child : (List<SObject>) value) {
                    Map<String, Object> serializedChild = protectRecord(context, child, depth + 1, state);
                    if (serializedChild != null) {
                        children.add(serializedChild);
                    }
                }
                result.put(fieldName, children);
                continue;
            }
            if (value instanceof SObject) {
                Map<String, Object> parent = protectRecord(context, (SObject) value, depth + 1, state);
                if (parent != null) {
                    result.put(fieldName, parent);
                }
                continue;
            }
            Schema.SObjectField fieldToken = fields.get(fieldName);
            if (fieldToken == null || !fieldToken.getDescribe().isAccessible()) {
                continue;
            }
            if (context != null && value != null && SchemaFieldClassificationService.isSensitive(objectApiName, fieldToken.getDescribe().getName())) {
                result.put(fieldName, tokenFor(context, CATEGORY_SALESFORCE_CLASSIFIED, String.valueOf(value)));
            } else {
                result.put(fieldName, value);
            }
        }
        return result;
    }

    private class StructuredRecordState {
        Integer recordCount = 0;
        RequesterView requesterView;
    }

    /**
     * What the person an attended run works for may read among the records a
     * tool or context provider returned: records they can see, and fields
     * their field-level security allows. Parent relationships follow their
     * lookup field; child records are checked on their own.
     */
    private class RequesterView {
        private final Set<Id> readableIds;
        private final Map<Schema.SObjectType, Set<String>> readableFields = new Map<Schema.SObjectType, Set<String>>();

        RequesterView(Id requesterId, List<List<SObject>> recordSets) {
            Set<Id> recordIds = new Set<Id>();
            Map<Schema.SObjectType, Set<String>> requestedFields = new Map<Schema.SObjectType, Set<String>>();
            for (List<SObject> records : recordSets) {
                collect(records, recordIds, requestedFields, 0);
            }
            readableIds = AttendedAccessService.readableRecordIds(requesterId, recordIds);
            for (Schema.SObjectType objectType : requestedFields.keySet()) {
                Set<String> permitted = new Set<String>();
                for (
                    String fieldName : AttendedAccessService.permittedFields(
                        requesterId,
                        objectType,
                        requestedFields.get(objectType),
                        AttendedAccessService.Operation.READABLE
                    )
                ) {
                    permitted.add(fieldName.toLowerCase());
                }
                readableFields.put(objectType, permitted);
            }
        }

        /** A record without an Id has no provable sharing, so the requester never sees it. */
        Boolean canReadRecord(Map<String, Object> populated) {
            Object recordId = populated.get('Id');
            return recordId instanceof Id && readableIds.contains((Id) recordId);
        }

        Boolean canReadField(Schema.SObjectType objectType, String fieldName, Boolean isRelationship) {
            if (fieldName == 'Id') {
                return true;
            }
            Set<String> permitted = readableFields.get(objectType);
            String lookupField = isRelationship ? lookupFieldFor(objectType, fieldName) : null;
            return permitted != null && permitted.contains((lookupField == null ? fieldName : lookupField).toLowerCase());
        }

        private void collect(List<SObject> records, Set<Id> recordIds, Map<Schema.SObjectType, Set<String>> requestedFields, Integer depth) {
            if (records == null || depth > MAX_STRUCTURED_DEPTH) {
                return;
            }
            for (SObject record : records) {
                if (record == null) {
                    continue;
                }
                Schema.SObjectType objectType = record.getSObjectType();
                if (!requestedFields.containsKey(objectType)) {
                    requestedFields.put(objectType, new Set<String>());
                }
                Map<String, Object> populated = record.getPopulatedFieldsAsMap();
                for (String fieldName : populated.keySet()) {
                    Object value = populated.get(fieldName);
                    if (fieldName == 'Id') {
                        recordIds.add((Id) value);
                    } else if (value instanceof List<SObject>) {
                        collect((List<SObject>) value, recordIds, requestedFields, depth + 1);
                    } else if (value instanceof SObject) {
                        String lookupField = lookupFieldFor(objectType, fieldName);
                        requestedFields.get(objectType).add(lookupField == null ? fieldName : lookupField);
                        collect(new List<SObject>{ (SObject) value }, recordIds, requestedFields, depth + 1);
                    } else {
                        requestedFields.get(objectType).add(fieldName);
                    }
                }
            }
        }
    }

    private static Map<Schema.SObjectType, Map<String, String>> lookupFieldsByRelationship = new Map<Schema.SObjectType, Map<String, String>>();

    /** The lookup field behind a parent relationship name, such as AccountId for Account; null for other names. */
    private static String lookupFieldFor(Schema.SObjectType objectType, String relationshipName) {
        if (!lookupFieldsByRelationship.containsKey(objectType)) {
            Map<String, String> byRelationship = new Map<String, String>();
            for (Schema.SObjectField field : objectType.getDescribe().fields.getMap().values()) {
                Schema.DescribeFieldResult describe = field.getDescribe();
                if (!String.isBlank(describe.getRelationshipName())) {
                    byRelationship.put(describe.getRelationshipName().toLowerCase(), describe.getName());
                }
            }
            lookupFieldsByRelationship.put(objectType, byRelationship);
        }
        return relationshipName == null ? null : lookupFieldsByRelationship.get(objectType).get(relationshipName.toLowerCase());
    }

    private static Boolean isValid(String category, String value) {
        if (category == CATEGORY_PAYMENT_CARD) {
            String cardDigits = digits(value);
            return hasCardNetworkPrefix(cardDigits) && passesLuhn(cardDigits);
        }
        if (category == CATEGORY_IBAN) {
            return passesIban(value);
        }
        return true;
    }

    /**
     * Luhn alone accepts about one in ten arbitrary digit runs, such as order
     * and tracking numbers, so a card must also carry a card-network prefix
     * with a length that network issues.
     */
    @TestVisible
    private static Boolean hasCardNetworkPrefix(String value) {
        if (String.isBlank(value)) {
            return false;
        }
        Integer length = value.length();
        Integer two = Integer.valueOf(value.left(2));
        Integer three = Integer.valueOf(value.left(3));
        Integer four = Integer.valueOf(value.left(4));
        if (value.startsWith('4')) {
            return length == 13 || length == 16 || length == 19;
        }
        if ((two >= 51 && two <= 55) || (four >= 2221 && four <= 2720)) {
            return length == 16;
        }
        if (two == 34 || two == 37) {
            return length == 15;
        }
        if (four == 6011 || (three >= 644 && three <= 649) || two == 65 || two == 62 || (four >= 3528 && four <= 3589)) {
            return length >= 16 && length <= 19;
        }
        if ((three >= 300 && three <= 305) || two == 36 || two == 38 || two == 39) {
            return length >= 14 && length <= 19;
        }
        if (new Set<Integer>{ 5018, 5020, 5038, 5893, 6304, 6759, 6761, 6762, 6763 }.contains(four)) {
            return length >= 12 && length <= 19;
        }
        return false;
    }

    @TestVisible
    private static Boolean passesLuhn(String value) {
        if (String.isBlank(value) || value.length() < 13 || value.length() > 19) {
            return false;
        }
        Integer sum = 0;
        Boolean doubleDigit = false;
        for (Integer index = value.length() - 1; index >= 0; index--) {
            Integer digit = Integer.valueOf(value.substring(index, index + 1));
            if (doubleDigit) {
                digit *= 2;
                if (digit > 9) {
                    digit -= 9;
                }
            }
            sum += digit;
            doubleDigit = !doubleDigit;
        }
        return Math.mod(sum, 10) == 0;
    }

    @TestVisible
    private static Boolean passesIban(String value) {
        String normalized = value.replace(' ', '').toUpperCase();
        if (normalized.length() < 15 || normalized.length() > 34) {
            return false;
        }
        String rearranged = normalized.substring(4) + normalized.substring(0, 4);
        Integer remainder = 0;
        for (Integer index = 0; index < rearranged.length(); index++) {
            String character = rearranged.substring(index, index + 1);
            String expanded;
            if (Pattern.matches('[0-9]', character)) {
                expanded = character;
            } else if (Pattern.matches('[A-Z]', character)) {
                expanded = String.valueOf(character.charAt(0) - 55);
            } else {
                return false;
            }
            for (Integer digitIndex = 0; digitIndex < expanded.length(); digitIndex++) {
                remainder = Math.mod(remainder * 10 + Integer.valueOf(expanded.substring(digitIndex, digitIndex + 1)), 97);
            }
        }
        return remainder == 1;
    }

    private static String digits(String value) {
        return value == null ? null : value.replaceAll('[^0-9]', '');
    }

    private static String fingerprint(Id runId, String category, String value) {
        Blob mac = Crypto.generateMac('HmacSHA256', Blob.valueOf(String.valueOf(runId) + '|' + category + '|' + value), TrustKeyProvider.currentKey());
        return EncodingUtil.convertToHex(mac).toLowerCase();
    }

    private static Pattern emailPattern() {
        return EMAIL_PATTERN;
    }

    private static Pattern ssnPattern() {
        return SSN_PATTERN;
    }

    private static Pattern paymentCardPattern() {
        return PAYMENT_CARD_PATTERN;
    }

    private static Pattern ibanPattern() {
        return IBAN_PATTERN;
    }

    private static Pattern phonePattern() {
        return PHONE_PATTERN;
    }

    private static void requireContext(ProtectionContext context) {
        if (context == null || context.runId == null) {
            throw configuration('An open trust protection context is required.');
        }
    }

    private static void assertBounded(String content) {
        if (content != null && content.length() > MAX_CONTENT_CHARACTERS) {
            throw configuration('Trust content exceeds the package character limit.');
        }
    }

    private static AgentKernelException.ConfigurationException configuration(String message) {
        return new AgentKernelException.ConfigurationException(message);
    }
}
