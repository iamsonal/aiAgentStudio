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
 * Runs one leased tool command: checks, invocation, and outcome. A tool type
 * whose Effects are Stays in This Org runs inside a savepoint, so its failures
 * are undone and may repeat; an unconfirmed call of a Changes Outside Systems
 * tool type is never retried blindly. ToolCommandQueueable runs it in its own
 * job; InPlaceToolRunner runs a Stays in This Org call in the transaction of the
 * model turn or Reads Outside Systems call before it.
 */
public without sharing class ToolCommandExecutor {
    private final Id runId;
    private final Id commandId;
    private final Decimal expectedRevision;
    private final String operationKey;
    private final String leaseToken;
    private AgentKernelModels.OperationalTelemetry attemptTelemetry;
    private AgentDefinition__c definition;
    private Integer completedAttemptCount;
    private Integer retryAfterSeconds;
    private String providerToolCallId;
    private CommandAttemptRuntime attemptRuntime;
    /** Time this worker waited in the async queue before it started; the per-hop latency operators see. */
    private Long queueWaitMilliseconds;
    /** True when the call runs in the transaction of the model turn that asked for it. */
    private Boolean ranInline = false;
    /** Admitted as Stays in This Org: Core undoes a failed call inside a savepoint. */
    private Boolean transactional;
    /** Admitted as Stays in This Org or Reads Outside Systems: a failed or lost call may run again. */
    private Boolean repeatable;
    /** Open while a tool's DML can still be undone. */
    private Savepoint toolSavepoint;
    private Boolean invoked = false;
    private Integer publishImmediateBefore;
    private Integer emailInvocationsBefore;
    private Integer queueableJobsBefore;
    private Integer futureCallsBefore;
    /** The person an attended run works for; tool text they might not be allowed to read is withheld. */
    private Id attendedBy;
    /** True when tool-authored text may reach the model: the run is unattended, or the tool class is an IRequesterFilteredTool. */
    private Boolean toolTextFiltered = false;
    /** The command whose lease this job owned, or null when it owned none and did nothing. */
    public AgentCommand__c ownedCommand { get; private set; }
    /** Dispatches whatever command is current after this job commits; a worker of its own shares it with later in-place calls. */
    public CommandContinuationFinalizer continuationFinalizer { get; private set; }
    @TestVisible
    private static final String WITHHELD_OUTPUT = '{"outputWithheld":true,"reason":"The call succeeded, but this tool does not filter its output to what the person you are helping may see, so the output is withheld."}';
    @TestVisible
    private static final String WITHHELD_ERROR = 'The tool did not succeed. Its details are withheld because this tool does not filter its text to what the person you are helping may see. Try another approach or tell the person.';

    public ToolCommandExecutor(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String leaseToken) {
        this.runId = runId;
        this.commandId = commandId;
        this.expectedRevision = expectedRevision;
        this.operationKey = operationKey;
        this.leaseToken = leaseToken;
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    /**
     * Runs the command when this job owns its lease. A worker of its own
     * passes no finalizer, so the executor attaches one; the model worker
     * passes its own, which dispatches whatever command is current after its
     * single commit.
     */
    public void run(Id workerJobId, CommandContinuationFinalizer sharedFinalizer) {
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
                AttendedBy__c
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
                ToolName__c,
                ProviderToolCallId__c,
                AttemptNumber__c,
                PolicyApproved__c,
                ApprovalFingerprint__c,
                AdmittedEffects__c,
                AdmittedToolBindingHash__c,
                DeliveryAnomalyCount__c
            FROM AgentCommand__c
            WHERE Id = :commandId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (
            runs.isEmpty() ||
            commands.isEmpty() ||
            !CommandWorkerSupport.ownsLease(runs[0], commands[0], expectedRevision, operationKey, leaseToken, workerJobId, AgentKernelModels.COMMAND_TYPE_TOOL)
        ) {
            return;
        }

        AgentRun__c run = runs[0];
        AgentCommand__c command = commands[0];
        ownedCommand = command;
        ranInline = sharedFinalizer != null;
        queueWaitMilliseconds = ranInline ? 0 : CommandWorkerSupport.queueWait(command);
        attendedBy = run.AttendedBy__c;
        transactional = AgentToolTypeService.runsInSavepoint(command);
        repeatable = AgentToolTypeService.isRetrySafe(command);
        providerToolCallId = command.ProviderToolCallId__c;
        ExecutionIdentityService.assertEstablishedBusinessPrincipal(run);
        continuationFinalizer = sharedFinalizer;
        if (continuationFinalizer == null) {
            continuationFinalizer = new CommandContinuationFinalizer(runId, commandId, leaseToken);
            if (workerJobId != null) {
                System.attachFinalizer(continuationFinalizer);
            }
        }
        completedAttemptCount = command.AttemptNumber__c == null ? 0 : Integer.valueOf(command.AttemptNumber__c);
        attemptRuntime = new CommandAttemptRuntime(
            runId,
            commandId,
            expectedRevision,
            operationKey,
            leaseToken,
            completedAttemptCount,
            'Tool',
            providerToolCallId,
            continuationFinalizer
        );
        AgentExecutionPolicyService.Policy executionPolicy;
        try {
            definition = AgentRunConfigurationService.getDefinition(run.Id);
            executionPolicy = AgentRunConfigurationService.getExecutionPolicy(run.Id);
        } catch (Exception unavailable) {
            stopForUnavailableConfiguration(command, 'CONFIGURATION_UNAVAILABLE', 'The agent definition or execution policy could not be loaded.');
            return;
        }
        attemptRuntime.configureExecutionPolicy(executionPolicy);
        AgentTool__c tool;
        try {
            tool = AgentRunConfigurationService.getTool(run.Id, command.ToolName__c);
            attemptRuntime.setConfigurationHash(AgentRunConfigurationService.getConfigurationHash(run.Id));
        } catch (Exception configurationError) {
            stopForUnavailableConfiguration(command, 'TOOL_CONFIGURATION_ERROR', 'The configured tool could not be resolved.');
            return;
        }
        if (String.isBlank(command.AdmittedToolBindingHash__c) || command.AdmittedToolBindingHash__c != AgentToolTypeService.bindingHash(tool)) {
            if (!repeatable && priorInvocationMayHaveOccurred(command)) {
                unknown('TOOL_BINDING_CHANGED', 'The admitted tool binding changed after an earlier attempt.');
            } else {
                pauseForIntervention('TOOL_BINDING_CHANGED', 'The admitted tool binding is missing or no longer active.');
            }
            return;
        }
        try {
            validateTokenizedToolShape(command.Input__c);
            TrustService.validateTokens(run.Id, command.Input__c);
        } catch (TrustService.TokenUseException invalidToken) {
            continueAfterFailure(
                TrustService.TOKEN_INVALID,
                'The tool input used a protected-value placeholder that does not exist in this conversation or has expired. ' +
                'Copy placeholders exactly as you received them, or leave the value out.'
            );
            return;
        } catch (Exception invalidShape) {
            continueAfterFailure('TOOL_INPUT_SCHEMA_INVALID', 'Tool input must be a JSON object.');
            return;
        }
        if (ExecutionIdentityService.principalHoldsApprovalAuthority(run)) {
            pauseForIntervention(
                'PRINCIPAL_HAS_APPROVAL_AUTHORITY',
                'The execution user holds Agent Kernel Human Decision or Approval Relay, so it cannot run model-chosen tools. Remove that access.'
            );
            return;
        }
        if (!evaluatePolicy(run, command, tool)) {
            return;
        }
        // Built again in this transaction, so a value removed since the model's turn is refused before the tool runs.
        ToolSchemaService.Resolution schema = ToolSchemaService.effectiveSchema(tool);
        if (schema.problem != null) {
            pauseForIntervention(
                'TOOL_SCHEMA_UNAVAILABLE',
                'Tool ' + tool.DeveloperName__c + ' cannot build its inputs: ' + schema.problem + ' Fix the tool, then retry the run. The tool did not run.'
            );
            return;
        }
        AgentKernelModels.ToolRequest request = new AgentKernelModels.ToolRequest();
        request.runId = run.Id;
        request.toolName = tool.DeveloperName__c;
        request.input = command.Input__c;
        request.implementationConfiguration = AgentConfigService.toolConfiguration(tool);
        request.operationKey = command.OperationKey__c;
        request.principal = AgentKernelModels.principalOf(run);
        attemptRuntime.setInvocationRequest(protectContent(JSON.serialize(request)));
        // Set after the evidence copy above, so the key is never stored.
        request.resumeKey = AgentKernel.resumeKey(run.Id, command.OperationKey__c);
        try {
            request.input = TrustService.resolveForTool(run.Id, command.Id, leaseToken, command.Input__c);
            ToolJsonSchemaValidator.validateInstance(request.input, schema.schema, 'Tool input');
        } catch (ToolJsonSchemaValidator.ValidationException invalidInput) {
            continueAfterFailure('TOOL_INPUT_SCHEMA_INVALID', invalidInput.getMessage());
            return;
        } catch (TrustService.TokenUseException misusedToken) {
            // Nothing was released: the model learns which value it may not send here and can rewrite the call.
            continueAfterFailure(misusedToken.code, misusedToken.getMessage() + ' Rewrite the input without it, or ask the person for another way.');
            return;
        } catch (Exception blockedSensitiveData) {
            pauseForIntervention('TRUST_PROTECTION_ERROR', 'Protected values in the tool input could not be resolved for this tool.');
            return;
        }
        if (!ExtensionExecutionGuard.hasRequiredHeadroom()) {
            pauseForIntervention('TOOL_EXTENSION_BUDGET_EXCEEDED', 'Insufficient governor headroom remains for tool initialization.');
            return;
        }
        ITool implementation;
        Exception toolConfigurationError;
        ExtensionExecutionGuard.Boundary toolBoundary = ExtensionExecutionGuard.open();
        try {
            implementation = AgentExtensionInvoker.newTool(tool);
        } catch (Exception configurationError) {
            toolConfigurationError = configurationError;
        }
        ExtensionExecutionGuard.Result toolIsolation = ExtensionExecutionGuard.close(toolBoundary);
        if (
            toolIsolation.budgetExceeded ||
            toolIsolation.performedDml ||
            toolIsolation.performedCallout ||
            toolIsolation.performedProhibitedAsync() ||
            toolConfigurationError != null
        ) {
            pauseForIntervention('TOOL_CONFIGURATION_ERROR', 'The configured tool could not be initialized.');
            return;
        }
        toolTextFiltered = attendedBy == null || implementation instanceof IRequesterFilteredTool;

        Long invocationStartedAtMilliseconds = attemptRuntime.startInvocation();
        beginToolEffects();
        invoked = true;
        AgentKernelModels.ToolResponse response;
        Boolean validResponse = true;
        try {
            response = AgentExtensionInvoker.executeTool(implementation, request);
            try {
                ExtensionResponseValidator.validateTool(response);
            } catch (AgentKernelException.PermanentException invalidResponse) {
                validResponse = false;
            }
        } catch (AgentKernelException.OutcomeUnknownException e) {
            attemptTelemetry = measuredTelemetry(invocationStartedAtMilliseconds);
            attemptRuntime.setTelemetry(attemptTelemetry);
            unknown('TOOL_OUTCOME_UNKNOWN', toolText(e.getMessage(), 'The tool outcome could not be confirmed.'));
            return;
        } catch (AgentKernelException.RetryableException e) {
            // The tool asserts that repeating this call is safe.
            attemptTelemetry = measuredTelemetry(invocationStartedAtMilliseconds);
            attemptRuntime.setTelemetry(attemptTelemetry);
            retry('TOOL_RETRYABLE_ERROR', toolText(e.getMessage(), 'The tool requested a retry.'));
            return;
        } catch (AgentKernelException.PermanentException e) {
            attemptTelemetry = measuredTelemetry(invocationStartedAtMilliseconds);
            attemptRuntime.setTelemetry(attemptTelemetry);
            continueAfterFailure('TOOL_PERMANENT_ERROR', toolText(e.getMessage(), 'The tool rejected the request.'));
            return;
        } catch (System.CalloutException e) {
            attemptTelemetry = measuredTelemetry(invocationStartedAtMilliseconds);
            attemptRuntime.setTelemetry(attemptTelemetry);
            if (toolSavepoint != null) {
                // The savepoint blocks callouts, so none reached the target.
                discardToolEffects();
                pauseForIntervention(
                    'TOOL_CONFIGURATION_ERROR',
                    'The tool attempted a callout, so its tool type\'s Effects must be Reads Outside Systems or Changes Outside Systems.'
                );
            } else if (repeatable) {
                retry('TOOL_CALLOUT_FAILED', 'The tool\'s callout failed before a confirmed outcome.');
            } else {
                unknown('TOOL_OUTCOME_UNKNOWN', 'The tool outcome could not be confirmed.');
            }
            return;
        } catch (Exception e) {
            attemptTelemetry = measuredTelemetry(invocationStartedAtMilliseconds);
            attemptRuntime.setTelemetry(attemptTelemetry);
            if (repeatable && isTransient(e)) {
                retry('TOOL_EXECUTION_ERROR', 'Tool execution failed before a confirmed outcome.');
            } else if (repeatable) {
                // The call was rolled back and would fail the same way again, so the model decides what to do next.
                continueAfterFailure(
                    'TOOL_EXECUTION_ERROR',
                    'The tool failed with an unexpected ' + e.getTypeName() + '. Repeating the same call will fail again; try another approach.'
                );
            } else {
                unknown('TOOL_OUTCOME_UNKNOWN', 'The tool outcome could not be confirmed.');
            }
            return;
        }
        // Settlement stays outside the invocation handlers. A failure to persist
        // the outcome is not a tool failure: it fails this job, the whole
        // transaction (including kept tool DML) rolls back, and the finalizer
        // recovers the leased command.
        if (!validResponse) {
            postInvocationInvalid(tool, 'MALFORMED_TOOL_OUTPUT', 'The tool returned an invalid response.');
            return;
        }
        attemptRuntime.setNativeEvidence(response == null ? null : response.nativeRequestEvidence, response == null ? null : response.nativeResponseEvidence);
        if (response != null) {
            response.nativeRequestEvidence = null;
            response.nativeResponseEvidence = null;
        }
        attemptTelemetry = telemetryFrom(response, System.now().getTime() - invocationStartedAtMilliseconds);
        attemptRuntime.setTelemetry(attemptTelemetry);
        handleResponse(response, tool);
    }

    private void handleResponse(AgentKernelModels.ToolResponse response, AgentTool__c tool) {
        if (response == null) {
            attemptRuntime.setInvocationResponse('null');
            postInvocationInvalid(tool, 'MALFORMED_TOOL_OUTPUT', 'The tool returned no response.');
            return;
        }
        Boolean hasStructuredOutput = response.recordSets != null && !response.recordSets.isEmpty();
        // Core filters record sets for the requester; text is withheld unless the tool type filters it itself.
        Boolean withheldForRequester = !toolTextFiltered && !hasStructuredOutput && !String.isBlank(response.output);
        response.errorMessage = toolText(response.errorMessage, null);
        if (hasStructuredOutput && !String.isBlank(response.output)) {
            postInvocationInvalid(tool, 'MALFORMED_TOOL_OUTPUT', 'A tool response cannot contain both output and structured record sets.');
            return;
        }
        if (hasStructuredOutput) {
            try {
                response.output = attemptRuntime.protectRecordSets(response.recordSets);
                response.recordSets = null;
            } catch (Exception invalidStructuredOutput) {
                postInvocationInvalid(tool, 'TRUST_PROTECTION_ERROR', 'The trust layer rejected structured tool output.');
                return;
            }
        }
        Boolean ordinarySuccess = response.isSuccess == true && response.outcomeUnknown != true && response.awaitingExternalInput != true;
        if (ordinarySuccess) {
            if (String.isBlank(response.output)) {
                postInvocationInvalid(tool, 'MALFORMED_TOOL_OUTPUT', 'A successful tool response requires output.');
                return;
            }
            try {
                ToolJsonSchemaValidator.validateInstance(response.output, ToolJsonSchemaValidator.TOOL_RESULT_SCHEMA, 'Tool output');
            } catch (ToolJsonSchemaValidator.ValidationException invalidOutput) {
                postInvocationInvalid(tool, 'MALFORMED_TOOL_OUTPUT', 'A successful tool response must be a JSON object.');
                return;
            }
        }
        // Any successful output reaches the model, including the output of a call that waits for external input.
        if (withheldForRequester && response.isSuccess == true) {
            response.output = WITHHELD_OUTPUT;
            AgentOperationsLog.emit(LoggingLevel.WARN, 'TOOL_OUTPUT_WITHHELD', runId, commandId, null, operationKey);
        }
        try {
            // Protecting record sets already checked the tokens in their raw data; their
            // output now holds tokens minted in this attempt, which are saved later.
            if (!hasStructuredOutput) {
                TrustService.validateTokens(runId, response.output);
            }
            response.output = protectContent(response.output);
            response.errorMessage = protectContent(response.errorMessage);
            response.waitingReason = protectContent(response.waitingReason);
            response.externalReference = protectContent(response.externalReference);
            attemptRuntime.protectNativeEvidence();
            if (attemptTelemetry != null) {
                attemptTelemetry.externalReference = response.externalReference;
            }
        } catch (Exception trustFailure) {
            attemptRuntime.setInvocationResponse('{"trustProtection":"error"}');
            postInvocationInvalid(tool, 'TRUST_PROTECTION_ERROR', 'The trust layer rejected tool output.');
            return;
        }
        attemptRuntime.setInvocationResponse(JSON.serialize(response));
        if (response.outcomeUnknown == true) {
            unknown(
                CommandWorkerSupport.defaultCode(response.errorCode, 'TOOL_OUTCOME_UNKNOWN'),
                CommandWorkerSupport.defaultMessage(response.errorMessage, 'The tool outcome could not be confirmed.')
            );
            return;
        }
        if (response.awaitingExternalInput == true) {
            waitForExternalInput(response, tool);
            return;
        }
        if (response.isSuccess == false) {
            if (response.retryable == true) {
                // The tool asserts that repeating this call is safe.
                retryAfterSeconds = response.retryAfterSeconds;
                retry(
                    CommandWorkerSupport.defaultCode(response.errorCode, 'TOOL_RETRYABLE_ERROR'),
                    CommandWorkerSupport.defaultMessage(response.errorMessage, 'The tool requested a retry.')
                );
            } else {
                continueAfterFailure(
                    CommandWorkerSupport.defaultCode(response.errorCode, 'TOOL_ERROR'),
                    CommandWorkerSupport.defaultMessage(response.errorMessage, 'The tool rejected the request.')
                );
            }
            return;
        }
        if (escapedTransaction()) {
            keepToolEffects();
            unknown('TOOL_OUTCOME_UNKNOWN', ESCAPED_MESSAGE);
            return;
        }
        keepToolEffects();
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.continueWith(
            runId,
            commandId,
            expectedRevision,
            operationKey,
            response.output,
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, response.output, null)
        );
        outcome.eventType = AgentKernelModels.EVENT_TOOL_COMPLETED;
        outcome.summary = 'Tool completed.';
        applyTelemetry(outcome);
        outcome.payload = telemetryPayload();
        submit(outcome);
    }

    private Boolean evaluatePolicy(AgentRun__c run, AgentCommand__c command, AgentTool__c tool) {
        Boolean approvalValid;
        AgentKernelModels.ToolAuthorizationResponse response;
        // Only the policy evaluation is policy's fault; approval assignment and the
        // wait transition below report their own errors.
        try {
            approvalValid =
                command.PolicyApproved__c == true &&
                !String.isBlank(command.ApprovalFingerprint__c) &&
                command.ApprovalFingerprint__c == ToolApprovalFingerprint.compute(command, tool, definition);
            AgentKernelModels.ToolAuthorizationRequest request = new AgentKernelModels.ToolAuthorizationRequest();
            request.runId = run.Id;
            request.commandId = command.Id;
            request.definitionId = run.AgentDefinition__c;
            request.toolName = command.ToolName__c;
            request.input = command.Input__c;
            request.operationKey = command.OperationKey__c;
            request.attemptNumber = completedAttemptCount;
            request.hasExternalEffects = AgentToolTypeService.admittedEffects(command) != AgentToolTypeService.EFFECTS_IN_ORG;
            request.initiatingActorId = run.InitiatingUser__c;
            request.attendedById = run.AttendedBy__c;
            request.resolvedPrincipalId = run.ResolvedPrincipalUser__c;
            request.executionIdentityId = run.ExecutionIdentity__c;
            if (String.isBlank(definition.ToolAuthorizationPolicyClass__c)) {
                response = defaultPolicy(tool);
            } else {
                Exception policyFailure;
                ExtensionExecutionGuard.Boundary boundary = ExtensionExecutionGuard.open();
                try {
                    response = AgentExtensionInvoker.evaluatePolicy(definition, request);
                } catch (Exception caughtFailure) {
                    policyFailure = caughtFailure;
                }
                ExtensionExecutionGuard.Result isolation = ExtensionExecutionGuard.close(boundary);
                if (isolation.budgetExceeded) {
                    pauseForIntervention('TOOL_AUTHORIZATION_POLICY_BUDGET_EXCEEDED', 'Tool authorization policy exceeded its governor budget.');
                    return false;
                }
                if (isolation.performedDml || isolation.performedCallout || isolation.performedProhibitedAsync() || policyFailure instanceof CalloutException) {
                    pauseForIntervention('TOOL_AUTHORIZATION_POLICY_INVALID', 'Tool authorization policy evaluation must remain query-only.');
                    return false;
                }
                if (policyFailure != null) {
                    throw policyFailure;
                }
            }
        } catch (Exception policyFailure) {
            pauseForIntervention('TOOL_AUTHORIZATION_POLICY_ERROR', 'Tool authorization policy evaluation failed closed.');
            return false;
        }
        if (response == null || response.decision == null) {
            pauseForIntervention('TOOL_AUTHORIZATION_POLICY_INVALID', 'Tool authorization policy returned no decision.');
            return false;
        }
        if (response.decision == AgentKernelModels.ToolAuthorizationDecision.Deny) {
            continueAfterFailure(
                AgentKernelModels.ERROR_TOOL_AUTHORIZATION_DENIED,
                CommandWorkerSupport.defaultMessage(response.reason, 'The authorization policy denied this tool call.')
            );
            return false;
        }
        Boolean policyRequiresApproval = response.decision == AgentKernelModels.ToolAuthorizationDecision.RequireApproval;
        if (!policyRequiresApproval && response.decision != AgentKernelModels.ToolAuthorizationDecision.Allow) {
            pauseForIntervention('TOOL_AUTHORIZATION_POLICY_INVALID', 'Tool authorization policy returned an unsupported decision.');
            return false;
        }
        if (approvalValid || (!policyRequiresApproval && tool.RequiresApproval__c != true)) {
            return true;
        }
        if (!ExecutionIdentityService.usesIdentity(run)) {
            pauseForIntervention(
                'INITIATING_USER_APPROVAL_UNSUPPORTED',
                'The authorization policy asked for approval, but this agent has no Agent Execution Identity, so its runs cannot wait for approval.'
            );
            return false;
        }
        if (
            policyRequiresApproval &&
            (String.isBlank(response.reason) || (response.timeoutSeconds != null && (response.timeoutSeconds < 60 || response.timeoutSeconds > 604800)))
        ) {
            pauseForIntervention(
                'TOOL_AUTHORIZATION_POLICY_INVALID',
                'Approval authorization result requires a reason and a timeout from 60 to 604,800 seconds.'
            );
            return false;
        }
        AgentApprovalService.Request approval;
        try {
            approval = policyRequiresApproval
                ? AgentApprovalService.request(run, tool, response.reason, response.timeoutSeconds, response.approverId)
                : AgentApprovalService.request(run, tool, 'Tool configuration requires approval.', null, null);
        } catch (AgentApprovalService.AssignmentException unassigned) {
            pauseForIntervention('APPROVAL_ASSIGNMENT_UNRESOLVED', unassigned.getMessage());
            return false;
        } catch (Exception assignmentFailure) {
            pauseForIntervention('APPROVAL_ASSIGNMENT_UNRESOLVED', 'The approver could not be resolved for this tool call.');
            return false;
        }
        // A failed wait transition is a worker failure: the finalizer recovers the leased command.
        AgentKernel.waitForApproval(run.Id, command.Id, expectedRevision, operationKey, leaseToken, approval);
        return false;
    }

    private static AgentKernelModels.ToolAuthorizationResponse defaultPolicy(AgentTool__c tool) {
        AgentKernelModels.ToolAuthorizationResponse response = new AgentKernelModels.ToolAuthorizationResponse();
        response.decision = AgentKernelModels.ToolAuthorizationDecision.Allow;
        response.reason = 'No contextual authorization policy is configured.';
        return response;
    }

    private void waitForExternalInput(AgentKernelModels.ToolResponse response, AgentTool__c tool) {
        if (response.isSuccess != true || String.isBlank(response.waitingReason)) {
            postInvocationInvalid(tool, 'MALFORMED_TOOL_OUTPUT', 'An intentional wait requires success and a waiting reason.');
            return;
        }
        Integer timeoutSeconds = response.waitTimeoutSeconds == null ? 86400 : response.waitTimeoutSeconds;
        if (timeoutSeconds < 60 || timeoutSeconds > 604800) {
            postInvocationInvalid(tool, 'MALFORMED_TOOL_OUTPUT', 'Intentional wait timeout is outside the supported range.');
            return;
        }
        try {
            ToolJsonSchemaValidator.validateSchema(response.resumeJsonSchema, 'Resume schema');
        } catch (Exception invalidSchema) {
            postInvocationInvalid(tool, 'MALFORMED_TOOL_OUTPUT', 'Intentional wait resume schema is invalid.');
            return;
        }
        if (escapedTransaction()) {
            keepToolEffects();
            unknown('TOOL_OUTCOME_UNKNOWN', ESCAPED_MESSAGE);
            return;
        }
        keepToolEffects();
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.waitForResume(runId, commandId, expectedRevision, operationKey, response.output);
        outcome.waitingReason = response.waitingReason;
        outcome.resumeJsonSchema = response.resumeJsonSchema;
        outcome.waitExpiresAt = System.now().addSeconds(timeoutSeconds);
        outcome.continuationMode = AgentKernelModels.CONTINUATION_MODEL;
        applyTelemetry(outcome);
        submit(outcome);
    }

    private void stopForUnavailableConfiguration(AgentCommand__c command, String errorCode, String errorMessage) {
        if (!repeatable && priorInvocationMayHaveOccurred(command)) {
            unknown(errorCode, 'The admitted tool configuration is unavailable and its prior effect cannot be ruled out.');
        } else {
            pauseForIntervention(errorCode, errorMessage);
        }
    }

    @SuppressWarnings('PMD.ApexCRUDViolation')
    private Boolean priorInvocationMayHaveOccurred(AgentCommand__c command) {
        if (completedAttemptCount <= 1) {
            return false;
        }
        Integer recordedInvocations = [
            SELECT COUNT()
            FROM AgentInvocation__c
            WHERE AgentCommand__c = :command.Id AND InvocationType__c = 'Tool'
            WITH SYSTEM_MODE
        ];
        if (recordedInvocations > 0) {
            return true;
        }
        return [
                SELECT COUNT()
                FROM AgentEvent__c
                WHERE AgentRun__c = :runId AND CommandKey__c = :command.OperationKey__c AND EventType__c = :AgentKernelModels.EVENT_TOOL_OUTCOME_UNKNOWN
                WITH SYSTEM_MODE
            ] > 0;
    }

    private void retry(String errorCode, String errorMessage) {
        if (failedEffectsEscaped()) {
            unknown('TOOL_OUTCOME_UNKNOWN', ESCAPED_MESSAGE);
            return;
        }
        attemptRuntime.scheduleRetry(errorCode, errorMessage, retryAfterSeconds, null);
    }

    private void pauseForIntervention(String errorCode, String errorMessage) {
        if (failedEffectsEscaped()) {
            unknown('TOOL_OUTCOME_UNKNOWN', ESCAPED_MESSAGE);
            return;
        }
        errorMessage = protectContent(errorMessage);
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.pause(runId, commandId, expectedRevision, operationKey, errorCode, errorMessage);
        outcome.toolNotInvoked = !invoked;
        applyTelemetry(outcome);
        outcome.payload = telemetryPayload();
        submit(outcome);
    }

    /** Failure text a tool wrote, withheld on attended runs unless its tool type filters text for the requester. */
    private String toolText(String text, String fallback) {
        if (String.isBlank(text)) {
            return fallback;
        }
        if (toolTextFiltered) {
            return text;
        }
        AgentOperationsLog.emit(LoggingLevel.WARN, 'TOOL_ERROR_WITHHELD', runId, commandId, null, operationKey);
        return WITHHELD_ERROR;
    }

    private void continueAfterFailure(String errorCode, String errorMessage) {
        if (failedEffectsEscaped()) {
            unknown('TOOL_OUTCOME_UNKNOWN', ESCAPED_MESSAGE);
            return;
        }
        errorMessage = protectContent(errorMessage);
        String failurePayload = AgentKernelModels.toolFailurePayload(errorCode, errorMessage);
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.continueAfterToolFailure(
            runId,
            commandId,
            expectedRevision,
            operationKey,
            errorCode,
            errorMessage,
            new AgentKernelModels.CommandSpec(AgentKernelModels.COMMAND_TYPE_MODEL, failurePayload, null)
        );
        applyTelemetry(outcome);
        outcome.payload = continuePayload(errorCode);
        submit(outcome);
    }

    private void unknown(String errorCode, String errorMessage) {
        if (toolSavepoint != null && !failedEffectsEscaped()) {
            // The rollback proves the call left nothing behind.
            continueAfterFailure(errorCode, errorMessage);
            return;
        }
        errorMessage = protectContent(errorMessage);
        AgentKernelModels.CommandOutcome outcome = AgentKernelModels.unknown(runId, commandId, expectedRevision, operationKey, errorCode, errorMessage);
        applyTelemetry(outcome);
        outcome.payload = telemetryPayload();
        submit(outcome);
    }

    private void postInvocationInvalid(AgentTool__c tool, String errorCode, String errorMessage) {
        if (repeatable) {
            pauseForIntervention(errorCode, errorMessage);
        } else {
            unknown('TOOL_OUTCOME_UNKNOWN', 'The tool outcome could not be confirmed.');
        }
    }

    private void submit(AgentKernelModels.CommandOutcome outcome) {
        attemptRuntime.submit(outcome);
    }

    private static final String ESCAPED_MESSAGE = 'A tool whose Effects are Stays in This Org sent an email, published an immediate event, or queued async work, so its outcome must be reconciled. Change its tool type to Changes Outside Systems.';

    /** Opens the savepoint for a tool without external effects and records the counters that reveal effects a rollback cannot undo. */
    private void beginToolEffects() {
        if (!transactional) {
            return;
        }
        publishImmediateBefore = Limits.getPublishImmediateDML();
        emailInvocationsBefore = Limits.getEmailInvocations();
        queueableJobsBefore = Limits.getQueueableJobs();
        futureCallsBefore = Limits.getFutureCalls();
        toolSavepoint = Database.setSavepoint();
    }

    private Boolean escapedTransaction() {
        return toolSavepoint != null &&
            (Limits.getPublishImmediateDML() != publishImmediateBefore ||
            Limits.getEmailInvocations() != emailInvocationsBefore ||
            Limits.getQueueableJobs() != queueableJobsBefore ||
            Limits.getFutureCalls() != futureCallsBefore);
    }

    /**
     * Settles a call without external effects that did not succeed. Returns true
     * when it reached beyond this transaction, so its effects are kept and
     * the outcome is Unknown; otherwise its DML is rolled back.
     */
    private Boolean failedEffectsEscaped() {
        if (toolSavepoint == null) {
            return false;
        }
        Boolean escaped = escapedTransaction();
        if (escaped) {
            keepToolEffects();
        } else {
            discardToolEffects();
        }
        return escaped;
    }

    private void keepToolEffects() {
        if (toolSavepoint != null) {
            Database.releaseSavepoint(toolSavepoint);
            toolSavepoint = null;
        }
    }

    private void discardToolEffects() {
        if (toolSavepoint != null) {
            Database.rollback(toolSavepoint);
            Database.releaseSavepoint(toolSavepoint);
            toolSavepoint = null;
        }
    }

    private static AgentKernelModels.OperationalTelemetry telemetryFrom(AgentKernelModels.ToolResponse response, Long measuredDuration) {
        AgentKernelModels.OperationalTelemetry telemetry = new AgentKernelModels.OperationalTelemetry();
        telemetry.durationMilliseconds = response != null &&
            response.durationMilliseconds != null &&
            response.durationMilliseconds >= 0
            ? response.durationMilliseconds
            : measuredDuration;
        if (response != null) {
            telemetry.externalReference = response.externalReference;
        }
        return telemetry;
    }

    private static AgentKernelModels.OperationalTelemetry measuredTelemetry(Long invocationStartedAt) {
        AgentKernelModels.OperationalTelemetry telemetry = new AgentKernelModels.OperationalTelemetry();
        telemetry.durationMilliseconds = System.now().getTime() - invocationStartedAt;
        return telemetry;
    }

    private void applyTelemetry(AgentKernelModels.CommandOutcome outcome) {
        if (attemptTelemetry == null) {
            return;
        }
        outcome.durationMilliseconds = attemptTelemetry.durationMilliseconds;
        outcome.externalReference = attemptTelemetry.externalReference;
    }

    private String telemetryPayload() {
        Map<String, Object> payload = new Map<String, Object>();
        if (attemptTelemetry != null) {
            if (attemptTelemetry.durationMilliseconds != null && attemptTelemetry.durationMilliseconds >= 0) {
                payload.put('durationMs', attemptTelemetry.durationMilliseconds);
            }
            String externalReference = CommandWorkerSupport.boundedIdentifier(attemptTelemetry.externalReference);
            if (externalReference != null) {
                payload.put('externalReference', externalReference);
            }
        }
        if (queueWaitMilliseconds != null) {
            payload.put('queueWaitMs', queueWaitMilliseconds);
        }
        if (ranInline) {
            payload.put('ranInline', true);
        }
        return payload.isEmpty() ? null : JSON.serialize(payload);
    }

    private String continuePayload(String errorCode) {
        Map<String, Object> payload = new Map<String, Object>{ 'continuedAfterFailure' => true, 'errorCode' => errorCode };
        if (attemptTelemetry != null) {
            if (attemptTelemetry.durationMilliseconds != null && attemptTelemetry.durationMilliseconds >= 0) {
                payload.put('durationMs', attemptTelemetry.durationMilliseconds);
            }
            String externalReference = CommandWorkerSupport.boundedIdentifier(attemptTelemetry.externalReference);
            if (externalReference != null) {
                payload.put('externalReference', externalReference);
            }
        }
        if (queueWaitMilliseconds != null) {
            payload.put('queueWaitMs', queueWaitMilliseconds);
        }
        if (ranInline) {
            payload.put('ranInline', true);
        }
        return JSON.serialize(payload);
    }

    /** Row-lock contention clears on its own; other unexpected exceptions recur on every attempt. */
    @TestVisible
    private static Boolean isTransient(Exception failure) {
        if (failure instanceof DmlException) {
            DmlException dml = (DmlException) failure;
            String message = String.valueOf(dml.getMessage());
            // A DmlException a tool constructs itself has no DML rows, and reading
            // them throws an exception Apex cannot catch; judge it by its message.
            if (!message.contains('First exception on row')) {
                return message.contains(String.valueOf(StatusCode.UNABLE_TO_LOCK_ROW));
            }
            for (Integer index = 0; index < dml.getNumDml(); index++) {
                if (dml.getDmlType(index) == StatusCode.UNABLE_TO_LOCK_ROW) {
                    return true;
                }
            }
            return false;
        }
        // A locked row in a FOR UPDATE query has no status code, only this message.
        return failure instanceof QueryException && String.valueOf(failure.getMessage()).contains('Record Currently Unavailable');
    }

    private static void validateTokenizedToolShape(String input) {
        if (!(JSON.deserializeUntyped(input) instanceof Map<String, Object>)) {
            throw new AgentKernelException.ConfigurationException('Tool input must be a JSON object.');
        }
    }

    private String protectContent(String content) {
        return attemptRuntime.protect(content);
    }
}
