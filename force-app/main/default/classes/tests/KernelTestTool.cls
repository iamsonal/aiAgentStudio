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

@IsTest
public with sharing class KernelTestTool implements ITool {
    public static Integer invocationCount = 0;
    public static Long durationMilliseconds;
    public static String externalReference;
    public static Boolean awaitInput = false;
    public static Boolean throwUnexpected = false;
    public static Boolean throwRetryable = false;
    public static Boolean throwLockError = false;
    /** When true, the tool fails as a callout would, after any write it made. */
    public static Boolean throwCallout = false;
    public static Boolean returnRetryable = false;
    public static Boolean returnPermanentFailure = false;
    public static Boolean returnNull = false;
    public static Boolean combineOutputAndRecordSets = false;
    public static String outputOverride;
    public static AgentKernelModels.ToolRequest lastRequest;
    public static Map<String, List<SObject>> recordSets;
    public static List<String> configurationProblems = new List<String>();
    public static Integer validationCount = 0;
    /** When set, the tool writes an Account with this name before it responds. */
    public static String insertAccountName;
    /** When true, the tool queues async work, an effect a savepoint cannot undo. */
    public static Boolean enqueueAsync = false;
    /** When true, the tool publishes an immediate platform event, which a savepoint cannot undo. */
    public static Boolean publishImmediate = false;
    /** When true, the tool starts a batch job, which Core cannot detect; the extension contract forbids it. */
    public static Boolean startBatch = false;
    /** Calls per tool name. Static, so like a real outside effect it survives a rolled-back job. */
    public static Map<String, Integer> invocationsByTool = new Map<String, Integer>();
    /** When set, every call writes an Account named this prefix plus the tool name. */
    public static String accountPrefixPerTool;

    public List<String> validateConfiguration(AgentKernelModels.ToolConfiguration configuration) {
        validationCount++;
        return configurationProblems;
    }

    public AgentKernelModels.ToolResponse execute(AgentKernelModels.ToolRequest request) {
        invocationCount++;
        lastRequest = request;
        String toolName = request == null ? null : request.toolName;
        invocationsByTool.put(toolName, (invocationsByTool.containsKey(toolName) ? invocationsByTool.get(toolName) : 0) + 1);
        if (insertAccountName != null) {
            insert new Account(Name = insertAccountName);
        }
        if (accountPrefixPerTool != null) {
            insert new Account(Name = accountPrefixPerTool + toolName);
        }
        if (enqueueAsync) {
            System.enqueueJob(new NoopJob());
        }
        if (publishImmediate) {
            EventBus.publish(new AgentOperationalSignal__e(Code__c = 'TOOL_ESCAPE_PROBE', OccurredAt__c = System.now()));
        }
        if (startBatch) {
            Database.executeBatch(new KernelTestNoopBatch());
        }
        if (throwUnexpected) {
            throw new AgentKernelException.ConfigurationException('Unexpected test tool failure.');
        }
        if (throwLockError) {
            throw new DmlException('UNABLE_TO_LOCK_ROW, unable to obtain exclusive access to this record');
        }
        if (throwCallout) {
            throw new CalloutException('Read timed out');
        }
        if (throwRetryable) {
            throw new AgentKernelException.RetryableException('Retryable test tool failure.');
        }
        if (returnNull) {
            return null;
        }
        AgentKernelModels.ToolResponse response = new AgentKernelModels.ToolResponse();
        response.isSuccess = returnRetryable != true && returnPermanentFailure != true;
        response.retryable = returnRetryable == true;
        response.outcomeUnknown = false;
        response.errorCode = returnRetryable == true ? 'TEST_RETRYABLE' : (returnPermanentFailure == true ? 'TEST_PERMANENT' : null);
        response.errorMessage = returnRetryable == true
            ? 'Retryable test tool response.'
            : (returnPermanentFailure == true ? 'Permanent test tool failure.' : null);
        response.output = returnPermanentFailure == true ? null : (recordSets == null || combineOutputAndRecordSets ? '{"result":"test tool output"}' : null);
        if (outputOverride != null) {
            response.output = outputOverride;
        }
        response.recordSets = recordSets;
        response.durationMilliseconds = durationMilliseconds;
        response.externalReference = externalReference;
        if (awaitInput == true) {
            response.awaitingExternalInput = true;
            response.waitingReason = 'Waiting for an external answer.';
            response.resumeJsonSchema = '{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}';
            response.waitTimeoutSeconds = 3600;
        }
        return response;
    }

    public class NoopJob implements Queueable {
        public void execute(QueueableContext context) {
        }
    }
}
