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
 * Callout-safe model worker. Its pre-invocation phase is query-only; all
 * durable changes are submitted through AgentKernel after the provider returns.
 */
public without sharing class ModelCommandQueueable implements Queueable, Database.AllowsCallouts {
    private final Id runId;
    private final Id commandId;
    private final Decimal expectedRevision;
    private final String operationKey;
    private final String leaseToken;
    private List<Object> contextSourceMetadata = new List<Object>();
    private String finalOutputSchema;
    private AgentKernelModels.OperationalTelemetry attemptTelemetry;
    private Boolean transcriptTruncated = false;
    private Integer modelRequestCharacterBudget;
    private Integer modelRequestCharacterCount;
    private AgentDefinition__c definition;
    private Integer completedAttemptCount;
    private Integer retryAfterSeconds;
    private Map<String, AgentTool__c> availableToolsByName = new Map<String, AgentTool__c>();
    private CommandAttemptRuntime attemptRuntime;
    /** Time this worker waited in the async queue before it started; the per-hop latency operators see. */
    private Long queueWaitMilliseconds;
    private Id workerJobId;
    private CommandContinuationFinalizer continuationFinalizer;
    /** False after a delivery anomaly on this command, such as a failed worker: its tools then each run in their own job. */
    private Boolean mayRunToolsInPlace = false;

    public ModelCommandQueueable(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String leaseToken) {
        this.runId = runId;
        this.commandId = commandId;
        this.expectedRevision = expectedRevision;
        this.operationKey = operationKey;
        this.leaseToken = leaseToken;
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    public void execute(QueueableContext context) {
        List<AgentRun__c> runs = [
            SELECT
                Id,
                AgentDefinition__c,
                InitiatingUser__c,
                ExecutionIdentity__c,
                LoopbackNamedCredential__c,
                ExpectedPrincipalUser__c,
                ResolvedPrincipalUser__c,
                ExecutionContextStatus__c,
                Status__c,
                Revision__c,
                CurrentCommand__c,
                AnchorRecordId__c,
                AttendedBy__c,
                Input__c
            FROM AgentRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        List<AgentCommand__c> commands = [
            SELECT
                Id,
                AgentRun__c,
                CommandType__c,
                Status__c,
                ExpectedRunRevision__c,
                OperationKey__c,
                LeaseToken__c,
                WorkerJobId__c,
                WorkerEnqueuedAt__c,
                Input__c,
                InputSource__c,
                AttemptNumber__c,
                DeliveryAnomalyCount__c,
                CreatedDate
            FROM AgentCommand__c
            WHERE Id = :commandId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (
            runs.isEmpty() ||
            commands.isEmpty() ||
            !CommandWorkerSupport.ownsLease(
                runs[0],
                commands[0],
                expectedRevision,
                operationKey,
                leaseToken,
                context == null ? null : context.getJobId(),
                AgentKernelModels.COMMAND_TYPE_MODEL
            )
        ) {
            return;
        }

        AgentRun__c run = runs[0];
        AgentCommand__c command = commands[0];
        queueWaitMilliseconds = CommandWorkerSupport.queueWait(command);
        workerJobId = context == null ? null : context.getJobId();
        mayRunToolsInPlace = command.DeliveryAnomalyCount__c == null || command.DeliveryAnomalyCount__c == 0;
        ExecutionIdentityService.assertEstablishedBusinessPrincipal(run);
        continuationFinalizer = new CommandContinuationFinalizer(runId, commandId, leaseToken);
        if (context != null) {
            System.attachFinalizer(continuationFinalizer);
        }
        completedAttemptCount = command.AttemptNumber__c == null ? 0 : Integer.valueOf(command.AttemptNumber__c);
        attemptRuntime = new CommandAttemptRuntime(
            runId,
            commandId,
            expectedRevision,
            operationKey,
            leaseToken,
            completedAttemptCount,
            'Model',
            null,
            continuationFinalizer
        );
        AgentExecutionPolicyService.Policy executionPolicy;
        try {
            definition = AgentRunConfigurationService.getDefinition(run.Id);
            executionPolicy = AgentRunConfigurationService.getExecutionPolicy(run.Id);
        } catch (Exception unavailable) {
            pauseForIntervention('CONFIGURATION_UNAVAILABLE', 'The agent definition or execution policy could not be loaded.');
            return;
        }
        AgentModel__mdt model = AgentModelService.activeModel(definition.Model__c);
        if (model == null) {
            pauseForIntervention('MODEL_NOT_APPROVED', AgentModelService.unavailableMessage(definition.Model__c));
            return;
        }
        attemptRuntime.configureExecutionPolicy(executionPolicy);
        finalOutputSchema = definition.OutputSchema__c;
        List<AgentTool__c> tools = AgentRunConfigurationService.getTools(run.Id);
        attemptRuntime.setConfigurationHash(AgentConfigService.configurationHash(definition, tools, AgentRunConfigurationService.getContextProviders(run.Id)));
        availableToolsByName = InPlaceToolRunner.byName(tools);
        ModelRequestAssembler.Result assembly = ModelRequestAssembler.assemble(run, command, definition, model, tools, attemptRuntime);
        contextSourceMetadata = assembly.contextSourceMetadata;
        transcriptTruncated = assembly.transcriptTruncated;
        modelRequestCharacterBudget = assembly.characterBudget;
        modelRequestCharacterCount = assembly.characterCount;
        if (!assembly.isSuccess()) {
            pauseForIntervention(assembly.errorCode, assembly.errorMessage);
            return;
        }
        AgentKernelModels.ModelRequest request = assembly.request;
        attemptRuntime.setModel(model);
        if (!ExtensionExecutionGuard.hasRequiredHeadroom()) {
            pauseForIntervention('MODEL_EXTENSION_BUDGET_EXCEEDED', 'Insufficient governor headroom remains for model provider initialization.');
            return;
        }
        IModelProvider provider;
        ExtensionExecutionGuard.Boundary providerBoundary = ExtensionExecutionGuard.open();
        Exception providerConfigurationError;
        try {
            provider = AgentExtensionInvoker.newModelProvider(model);
        } catch (Exception configurationError) {
            providerConfigurationError = configurationError;
        }
        ExtensionExecutionGuard.Result providerIsolation = ExtensionExecutionGuard.close(providerBoundary);
        if (
            providerIsolation.budgetExceeded ||
            providerIsolation.performedDml ||
            providerIsolation.performedCallout ||
            providerIsolation.performedProhibitedAsync() ||
            providerConfigurationError != null
        ) {
            pauseForIntervention('MODEL_CONFIGURATION_ERROR', initializationMessage(providerIsolation, providerConfigurationError));
            return;
        }

        attemptRuntime.setInvocationRequest(JSON.serialize(request));
        Long invocationStartedAtMilliseconds = attemptRuntime.startInvocation();
        AgentKernelModels.ModelResponse response;
        try {
            response = AgentExtensionInvoker.invokeModel(provider, request);
            ExtensionResponseValidator.validateModel(response);
        } catch (AgentKernelException.RetryableException e) {
            attemptTelemetry = measuredTelemetry(invocationStartedAtMilliseconds);
            attemptRuntime.setTelemetry(attemptTelemetry);
            retry('MODEL_RETRYABLE_ERROR', CommandWorkerSupport.safeMessage(e, 'Model provider requested a retry.'));
            return;
        } catch (AgentKernelException.PermanentException e) {
            attemptTelemetry = measuredTelemetry(invocationStartedAtMilliseconds);
            attemptRuntime.setTelemetry(attemptTelemetry);
            pauseForIntervention('MODEL_PERMANENT_ERROR', CommandWorkerSupport.safeMessage(e, 'Model provider rejected the request.'));
            return;
        } catch (System.CalloutException e) {
            attemptTelemetry = measuredTelemetry(invocationStartedAtMilliseconds);
            attemptRuntime.setTelemetry(attemptTelemetry);
            retry('MODEL_CALLOUT_FAILED', 'Model provider callout failed.');
            return;
        } catch (Exception e) {
            attemptTelemetry = measuredTelemetry(invocationStartedAtMilliseconds);
            attemptRuntime.setTelemetry(attemptTelemetry);
            // The type tells the admin what broke without copying the adapter's message, which may hold request content.
            pauseForIntervention(
                'MODEL_INVOCATION_ERROR',
                'The model adapter failed with ' + e.getTypeName() + '. Check the adapter class for this Agent Model, then rescue the run.'
            );
            return;
        }
        attemptRuntime.setNativeEvidence(response == null ? null : response.nativeRequestEvidence, response == null ? null : response.nativeResponseEvidence);
        if (response != null) {
            response.nativeRequestEvidence = null;
            response.nativeResponseEvidence = null;
        }
        attemptTelemetry = telemetryFrom(response, System.now().getTime() - invocationStartedAtMilliseconds);
        attemptRuntime.setTelemetry(attemptTelemetry);
        handleResponse(response);
    }

    private static String initializationMessage(ExtensionExecutionGuard.Result isolation, Exception failure) {
        if (failure != null) {
            return 'The model adapter could not be created (' + failure.getTypeName() + '). Check the Model Adapter Class on the Agent Model.';
        }
        if (isolation.budgetExceeded) {
            return 'The model adapter used too many governor resources while it was created.';
        }
        return 'The model adapter must not change records, call out, or start async work while it is created.';
    }

    private void handleResponse(AgentKernelModels.ModelResponse response) {
        if (response == null) {
            attemptRuntime.setInvocationResponse('null');
            pauseForIntervention('MALFORMED_PROVIDER_OUTPUT', 'The model provider returned no response.');
            return;
        }
        String rawOutput = response.output;
        List<String> rawToolInputs = new List<String>();
        List<String> rationales = new List<String>();
        for (AgentKernelModels.ModelToolCall toolCall : response.toolCalls == null ? new List<AgentKernelModels.ModelToolCall>() : response.toolCalls) {
            // The rationale is explanation, not input: tools, fingerprints, and policies never see it,
            // and a mistake in it never costs the model call.
            ToolArguments arguments = withoutRationale(toolCall == null ? null : toolCall.toolInput);
            if (toolCall != null) {
                toolCall.toolInput = arguments.input;
            }
            rawToolInputs.add(arguments.input);
            rationales.add(protectedRationale(arguments.rationale));
        }
        try {
            // The model's answer and tool arguments are its own text; see CommandAttemptRuntime.protectModelOutput.
            if (response.output != null) {
                response.output = attemptRuntime.protectModelOutput(response.output);
            }
            for (AgentKernelModels.ModelToolCall toolCall : response.toolCalls == null ? new List<AgentKernelModels.ModelToolCall>() : response.toolCalls) {
                if (toolCall != null && toolCall.toolInput != null) {
                    toolCall.toolInput = attemptRuntime.protectModelOutput(toolCall.toolInput);
                }
            }
            response.errorMessage = protectContent(response.errorMessage);
            response.providerRequestId = protectContent(response.providerRequestId);
            attemptRuntime.protectNativeEvidence();
            if (attemptTelemetry != null) {
                attemptTelemetry.providerRequestId = response.providerRequestId;
            }
        } catch (TrustService.TokenUseException misusedToken) {
            attemptRuntime.setInvocationResponse('{"trustProtection":"unknownToken"}');
            reflect(
                TrustService.TOKEN_INVALID,
                'Your response used a protected-value placeholder that does not exist in this conversation. ' +
                'Copy placeholders exactly as you received them, or leave the value out.'
            );
            return;
        } catch (Exception trustFailure) {
            attemptRuntime.setInvocationResponse('{"trustProtection":"error"}');
            pauseForIntervention('TRUST_PROTECTION_ERROR', 'The trust layer rejected model output.');
            return;
        }
        attemptRuntime.setInvocationResponse(JSON.serialize(response));
        if (response.isSuccess == false) {
            if (response.retryable == true) {
                retryAfterSeconds = response.retryAfterSeconds;
                retry(
                    CommandWorkerSupport.defaultCode(response.errorCode, 'MODEL_RETRYABLE_ERROR'),
                    CommandWorkerSupport.defaultMessage(response.errorMessage, 'The model provider requested a retry.')
                );
            } else {
                pauseForIntervention(
                    CommandWorkerSupport.defaultCode(response.errorCode, 'MODEL_PROVIDER_ERROR'),
                    CommandWorkerSupport.defaultMessage(response.errorMessage, 'The model provider rejected the request.')
                );
            }
            return;
        }

        Boolean hasFinal = response.isFinal == true && !String.isBlank(response.output);
        List<AgentKernelModels.ModelToolCall> toolCalls = normalizedToolCalls(response);
        Boolean hasTools = response.isFinal != true && !toolCalls.isEmpty();
        if (hasFinal == hasTools) {
            reflect('MALFORMED_PROVIDER_OUTPUT', 'Return exactly one final response or one or more valid tool requests.');
            return;
        }

        AgentKernelModels.CommandOutcome outcome;
        if (hasFinal) {
            try {
                ToolJsonSchemaValidator.validateInstance(rawOutput, finalOutputSchema, 'Final model output');
            } catch (ToolJsonSchemaValidator.ValidationException invalidOutput) {
                reflect('MODEL_OUTPUT_SCHEMA_MISMATCH', 'Your final answer does not match the required output schema: ' + invalidOutput.getMessage());
                return;
            }
            outcome = AgentKernelModels.succeed(runId, commandId, expectedRevision, operationKey, response.output);
            applyTelemetry(outcome);
            outcome.payload = buildOutcomePayload(null);
        } else {
            if (toolCalls.size() > AgentKernelModels.MAX_TOOL_CALLS_PER_TURN) {
                reflect('TOOL_BATCH_LIMIT_EXCEEDED', 'A model turn may request at most ' + AgentKernelModels.MAX_TOOL_CALLS_PER_TURN + ' tools.');
                return;
            }
            // Adapters ask the provider for one call; a provider that ignores it is told and asked again.
            if (toolCalls.size() > 1 && definition.AllowMultipleToolCalls__c == false) {
                reflect('TOOL_BATCH_NOT_ALLOWED', 'This agent takes one tool call per turn. Request only the next tool.');
                return;
            }
            List<AgentKernelModels.CommandSpec> toolCommands = new List<AgentKernelModels.CommandSpec>();
            Set<String> callIds = new Set<String>();
            for (Integer toolIndex = 0; toolIndex < toolCalls.size(); toolIndex++) {
                AgentKernelModels.ModelToolCall toolCall = toolCalls[toolIndex];
                String rawToolInput = toolIndex < rawToolInputs.size() ? rawToolInputs[toolIndex] : toolCall.toolInput;
                if (
                    toolCall == null ||
                    String.isBlank(toolCall.toolName) ||
                    String.isBlank(toolCall.toolInput) ||
                    !availableToolsByName.containsKey(toolCall.toolName.trim().toLowerCase())
                ) {
                    reflect('MALFORMED_PROVIDER_OUTPUT', unavailableToolMessage(toolCall));
                    return;
                }
                AgentTool__c requestedTool = availableToolsByName.get(toolCall.toolName.trim().toLowerCase());
                // The same schema the request carried this turn: it was resolved once for the transaction.
                ToolSchemaService.Resolution schema = ToolSchemaService.effectiveSchema(requestedTool);
                if (schema.problem != null) {
                    pauseForIntervention(
                        'TOOL_SCHEMA_UNAVAILABLE',
                        'Tool ' + requestedTool.DeveloperName__c + ' cannot build its inputs: ' + schema.problem + ' Fix the tool, then retry the run.'
                    );
                    return;
                }
                try {
                    ToolJsonSchemaValidator.validateInstance(rawToolInput, schema.schema, 'Tool input');
                } catch (ToolJsonSchemaValidator.ValidationException invalidInput) {
                    reflect(
                        'TOOL_INPUT_SCHEMA_INVALID',
                        'The input for tool ' +
                            requestedTool.DeveloperName__c +
                            ' does not match its schema: ' +
                            invalidInput.getMessage() +
                            ' Fix that and call the tool again.'
                    );
                    return;
                }
                String boundedCallId = CommandWorkerSupport.boundedIdentifier(toolCall.toolCallId);
                if (!String.isBlank(boundedCallId) && callIds.contains(boundedCallId)) {
                    reflect('MALFORMED_PROVIDER_OUTPUT', 'Tool call identifiers must be unique within a model turn.');
                    return;
                }
                if (!String.isBlank(boundedCallId)) {
                    callIds.add(boundedCallId);
                }
                AgentKernelModels.CommandSpec toolCommand = new AgentKernelModels.CommandSpec(
                    AgentKernelModels.COMMAND_TYPE_TOOL,
                    toolCall.toolInput,
                    toolCall.toolName.trim()
                );
                toolCommand.toolCallId = boundedCallId;
                toolCommand.rationale = toolIndex < rationales.size() ? rationales[toolIndex] : null;
                toolCommands.add(toolCommand);
            }
            outcome = AgentKernelModels.continueWith(runId, commandId, expectedRevision, operationKey, null, null);
            outcome.nextCommands = toolCommands;
            applyTelemetry(outcome);
            outcome.summary = 'Model requested ' + toolCommands.size() + ' tool operation(s).';
            outcome.payload = buildOutcomePayload(new Map<String, Object>{ 'toolCount' => toolCommands.size() });
        }
        submit(outcome);
        if (hasTools) {
            runToolsInPlace();
        }
    }

    /**
     * Runs the reply's Stays in This Org calls in this transaction. A limit error
     * there loses the whole turn, which is safe because the model call may
     * repeat, and the retry runs each call in its own job.
     */
    private void runToolsInPlace() {
        if (mayRunToolsInPlace) {
            InPlaceToolRunner.runNext(runId, availableToolsByName, workerJobId, continuationFinalizer);
        }
    }

    /** Names the tool the model asked for, or what its call lacked, and the tools it may use instead. */
    private String unavailableToolMessage(AgentKernelModels.ModelToolCall toolCall) {
        List<String> names = new List<String>();
        for (AgentTool__c tool : availableToolsByName.values()) {
            names.add(tool.DeveloperName__c);
        }
        names.sort();
        String available = ' Available tools: ' + (names.isEmpty() ? 'none' : String.join(names, ', ')) + '.';
        if (toolCall == null || String.isBlank(toolCall.toolName)) {
            return 'A tool call had no tool name.' + available;
        }
        String name = toolCall.toolName.trim().abbreviate(80);
        if (!availableToolsByName.containsKey(toolCall.toolName.trim().toLowerCase())) {
            return 'There is no active tool named ' + name + '.' + available;
        }
        return 'The call to ' + name + ' had no input. Send its arguments as a JSON object.';
    }

    @TestVisible
    private class ToolArguments {
        @TestVisible
        String input;
        @TestVisible
        String rationale;
    }

    /**
     * Protects the rationale like other stored text. A placeholder the model
     * invented there drops the rationale instead of rejecting the response.
     */
    private String protectedRationale(String rationale) {
        if (String.isBlank(rationale)) {
            return null;
        }
        try {
            return protectContent(rationale);
        } catch (Exception unprotectable) {
            return null;
        }
    }

    /**
     * Splits the model's rationale from a tool call's arguments. The remaining
     * arguments are re-serialized, so Input__c may differ from the provider's
     * bytes in key order and number format; the native evidence keeps the
     * original, and approval fingerprints use Input__c consistently. A missing or
     * non-text rationale is dropped, never an error: it explains, it does not control.
     */
    @TestVisible
    private static ToolArguments withoutRationale(String toolInput) {
        ToolArguments result = new ToolArguments();
        result.input = toolInput;
        Object parsed;
        try {
            parsed = String.isBlank(toolInput) ? null : JSON.deserializeUntyped(toolInput);
        } catch (JSONException malformed) {
            return result;
        }
        if (!(parsed instanceof Map<String, Object>) || !((Map<String, Object>) parsed).containsKey(AgentKernelModels.TOOL_RATIONALE_PROPERTY)) {
            return result;
        }
        Map<String, Object> arguments = (Map<String, Object>) parsed;
        Object rationale = arguments.remove(AgentKernelModels.TOOL_RATIONALE_PROPERTY);
        if (rationale instanceof String && !String.isBlank((String) rationale)) {
            result.rationale = ((String) rationale).normalizeSpace().abbreviate(AgentKernelModels.MAX_TOOL_RATIONALE_CHARACTERS);
        }
        result.input = JSON.serialize(arguments);
        return result;
    }

    private static List<AgentKernelModels.ModelToolCall> normalizedToolCalls(AgentKernelModels.ModelResponse response) {
        return response.toolCalls == null ? new List<AgentKernelModels.ModelToolCall>() : response.toolCalls;
    }

    private void retry(String errorCode, String errorMessage) {
        attemptRuntime.scheduleRetry(errorCode, errorMessage, retryAfterSeconds, contextSourceMetadata);
    }

    private void pauseForIntervention(String errorCode, String errorMessage) {
        errorMessage = protectContent(errorMessage);
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.pause(runId, commandId, expectedRevision, operationKey, errorCode, errorMessage);
        applyTelemetry(outcome);
        outcome.payload = buildOutcomePayload(null);
        submit(outcome);
    }

    private void reflect(String errorCode, String errorMessage) {
        errorMessage = protectContent(errorMessage);
        String failurePayload = AgentKernelModels.modelFailurePayload(errorCode, errorMessage);
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.continueAfterModelFailure(
            runId,
            commandId,
            expectedRevision,
            operationKey,
            errorCode,
            errorMessage,
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, failurePayload, null)
        );
        applyTelemetry(outcome);
        outcome.payload = buildOutcomePayload(new Map<String, Object>{ 'reflection' => true, 'errorCode' => errorCode });
        submit(outcome);
    }

    private void submit(AgentKernelModels.CommandOutcome outcome) {
        attemptRuntime.submit(outcome);
    }

    private String buildOutcomePayload(Map<String, Object> details) {
        Map<String, Object> payload = details == null ? new Map<String, Object>() : details;
        if (!contextSourceMetadata.isEmpty()) {
            payload.put('contextSources', contextSourceMetadata);
        }
        if (transcriptTruncated) {
            payload.put('transcriptTruncated', true);
        }
        if (modelRequestCharacterBudget != null) {
            payload.put('modelRequestCharacterBudget', modelRequestCharacterBudget);
            payload.put('modelRequestCharacterCount', modelRequestCharacterCount);
        }
        addTelemetryPayload(payload, attemptTelemetry);
        if (queueWaitMilliseconds != null) {
            payload.put('queueWaitMs', queueWaitMilliseconds);
        }
        return payload.isEmpty() ? null : JSON.serialize(payload);
    }

    private String protectContent(String content) {
        return attemptRuntime.protect(content);
    }

    private static AgentKernelModels.OperationalTelemetry telemetryFrom(AgentKernelModels.ModelResponse response, Long measuredDuration) {
        AgentKernelModels.OperationalTelemetry telemetry = new AgentKernelModels.OperationalTelemetry();
        telemetry.durationMilliseconds = response != null &&
            response.durationMilliseconds != null &&
            response.durationMilliseconds >= 0
            ? response.durationMilliseconds
            : measuredDuration;
        if (response != null) {
            telemetry.providerRequestId = response.providerRequestId;
            telemetry.inputTokens = response.inputTokens;
            telemetry.outputTokens = response.outputTokens;
            telemetry.totalTokens = response.totalTokens;
        }
        return telemetry;
    }

    /**
     * Telemetry for an attempt that ended without a usable response, so the
     * provider reported no usage. The request was still sent and billed, so its
     * input is estimated at four characters per token and counted.
     */
    private AgentKernelModels.OperationalTelemetry measuredTelemetry(Long invocationStartedAt) {
        AgentKernelModels.OperationalTelemetry telemetry = new AgentKernelModels.OperationalTelemetry();
        telemetry.durationMilliseconds = System.now().getTime() - invocationStartedAt;
        if (modelRequestCharacterCount != null && modelRequestCharacterCount > 0) {
            Long estimated = ((Long) modelRequestCharacterCount + 3) / 4;
            telemetry.inputTokens = estimated;
            telemetry.totalTokens = estimated;
            telemetry.tokensEstimated = true;
        }
        return telemetry;
    }

    private void applyTelemetry(AgentKernelModels.CommandOutcome outcome) {
        if (attemptTelemetry == null) {
            return;
        }
        outcome.providerRequestId = attemptTelemetry.providerRequestId;
        outcome.durationMilliseconds = attemptTelemetry.durationMilliseconds;
        outcome.inputTokens = attemptTelemetry.inputTokens;
        outcome.outputTokens = attemptTelemetry.outputTokens;
        outcome.totalTokens = attemptTelemetry.totalTokens;
        outcome.tokensEstimated = attemptTelemetry.tokensEstimated;
    }

    private static void addTelemetryPayload(Map<String, Object> payload, AgentKernelModels.OperationalTelemetry telemetry) {
        if (telemetry == null) {
            return;
        }
        if (!String.isBlank(telemetry.providerRequestId)) {
            payload.put('providerRequestId', CommandWorkerSupport.boundedIdentifier(telemetry.providerRequestId));
        }
        if (telemetry.durationMilliseconds != null && telemetry.durationMilliseconds >= 0) {
            payload.put('durationMs', telemetry.durationMilliseconds);
        }
        if (telemetry.inputTokens != null && telemetry.inputTokens >= 0) {
            payload.put('inputTokens', telemetry.inputTokens);
        }
        if (telemetry.outputTokens != null && telemetry.outputTokens >= 0) {
            payload.put('outputTokens', telemetry.outputTokens);
        }
        if (telemetry.totalTokens != null && telemetry.totalTokens >= 0) {
            payload.put('totalTokens', telemetry.totalTokens);
        }
        if (telemetry.tokensEstimated == true) {
            payload.put('tokensEstimated', true);
        }
    }
}
