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

/** DTOs used by Agent Core facades and extension interfaces. */
global inherited sharing class AgentKernelModels {
    public static final String RUN_STATUS_RUNNING = 'Running';
    public static final String RUN_STATUS_WAITING = 'Waiting';
    public static final String RUN_STATUS_PAUSED = 'Paused';
    public static final String RUN_STATUS_SUCCEEDED = 'Succeeded';
    public static final String RUN_STATUS_FAILED = 'Failed';
    public static final String RUN_STATUS_CANCELLED = 'Cancelled';

    public static final String INVOCATION_APEX = 'Apex';
    public static final String INVOCATION_FLOW = 'Flow';
    public static final String INVOCATION_REST = 'REST';
    public static final String INVOCATION_PLATFORM_EVENT = 'Platform Event';
    public static final String INVOCATION_CHAT = 'Chat';

    public static final String COMMAND_TYPE_MODEL = 'Model';
    public static final String COMMAND_TYPE_TOOL = 'Tool';

    public static final String COMMAND_STATUS_PENDING = 'Pending';
    public static final String COMMAND_STATUS_BLOCKED = 'Blocked';
    public static final String COMMAND_STATUS_LEASED = 'Leased';
    public static final String COMMAND_STATUS_SUCCEEDED = 'Succeeded';
    public static final String COMMAND_STATUS_RETRY_WAITING = 'Retry Waiting';
    public static final String COMMAND_STATUS_UNKNOWN = 'Unknown';
    public static final String COMMAND_STATUS_FAILED = 'Failed';
    public static final String COMMAND_STATUS_CANCELLED = 'Cancelled';
    public static final String COMMAND_STATUS_WAITING = 'Waiting';

    public static final String CONTINUATION_MODEL = 'Model';
    /** A conversational agent's answer waits for the person's next message. */
    public static final String CONTINUATION_CONVERSATION = 'Conversation';
    public static final String CONVERSATION_RESUME_SCHEMA = '{"type":"object","properties":{"message":{"type":"string","minLength":1,"maxLength":32000}},"required":["message"],"additionalProperties":false}';
    public static final String INPUT_SOURCE_HUMAN_RESPONSE = 'Human Response';
    public static final String INPUT_SOURCE_OPERATOR_GUIDANCE = 'Operator Guidance';
    public static final String INPUT_SOURCE_MODEL_FEEDBACK = 'Model Feedback';
    public static final String TRANSCRIPT_ORIGINAL_INPUT = 'OriginalInput';
    public static final String TRANSCRIPT_MODEL_FEEDBACK = 'ModelFeedback';
    public static final String TRANSCRIPT_USER_INPUT = 'UserInput';
    /** The agent's own earlier answer in a conversation; providers send it as an assistant message. */
    public static final String TRANSCRIPT_ASSISTANT_OUTPUT = 'AssistantOutput';
    public static final String TRANSCRIPT_OPERATOR_GUIDANCE = 'OperatorGuidance';
    public static final String TRANSCRIPT_TOOL_CALL = 'ToolCall';
    public static final String TRANSCRIPT_TOOL_RESULT = 'ToolResult';
    public static final String CONTINUATION_REINVOKE_TOOL = 'Reinvoke Tool';

    public static final String EVENT_RUN_STARTED = 'Run Started';
    public static final String EVENT_INPUT_ACCEPTED = 'Input Accepted';
    public static final String EVENT_MODEL_REQUESTED = 'Model Requested';
    public static final String EVENT_MODEL_COMPLETED = 'Model Completed';
    public static final String EVENT_TOOL_REQUESTED = 'Tool Requested';
    public static final String ERROR_TOOL_APPROVAL_DENIED = 'TOOL_APPROVAL_DENIED';
    public static final String ERROR_TOOL_APPROVAL_EXPIRED = 'TOOL_APPROVAL_EXPIRED';
    public static final String ERROR_TOOL_AUTHORIZATION_DENIED = 'TOOL_AUTHORIZATION_DENIED';
    public static final Integer MAX_TOOL_ERROR_MESSAGE_CHARACTERS = 2000;
    /** Tool calls one model turn may request; they run as one batch. */
    public static final Integer MAX_TOOL_CALLS_PER_TURN = 8;
    /**
     * Core adds this required property to every tool's input schema so the model
     * explains each call. Core removes it before validation, so tools, approval
     * fingerprints, and policies never see it; tools may not declare it.
     */
    public static final String TOOL_RATIONALE_PROPERTY = '_rationale';
    public static final Integer MAX_TOOL_RATIONALE_CHARACTERS = 1000;
    public static final String EVENT_TOOL_COMPLETED = 'Tool Completed';
    public static final String EVENT_TOOL_OUTCOME_UNKNOWN = 'Tool Outcome Unknown';
    public static final String EVENT_RUN_WAITING = 'Run Waiting';
    public static final String EVENT_RUN_PAUSED = 'Run Paused';
    public static final String EVENT_WAIT_EXPIRED = 'Wait Expired';
    public static final String EVENT_RUN_RESCUED = 'Run Rescued';
    public static final String EVENT_CONFIGURATION_CHANGED = 'Configuration Changed';
    public static final String EVENT_RUN_RESUMED = 'Run Resumed';
    public static final String EVENT_RUN_COMPLETED = 'Run Completed';
    public static final String EVENT_RUN_FAILED = 'Run Failed';
    public static final String EVENT_RUN_CANCELLED = 'Run Cancelled';
    public static final String EVENT_RUN_CANCELLATION_REQUESTED = 'Run Cancellation Requested';
    public static final String EVENT_COMMAND_RETRY_SCHEDULED = 'Command Retry Scheduled';
    public static final String EVENT_UNKNOWN_OUTCOME_RECONCILED = 'Unknown Outcome Reconciled';
    public static final String EVENT_TRUST_OUTPUT_RESOLVED = 'Trust Output Resolved';
    public static final String EVENT_TRUST_APPROVAL_INPUT_RESOLVED = 'Trust Approval Input Resolved';

    public static final String APPROVAL_STATUS_PENDING = 'Pending';
    public static final String APPROVAL_STATUS_APPROVED = 'Approved';
    public static final String APPROVAL_STATUS_REJECTED = 'Rejected';
    public static final String APPROVAL_STATUS_EXPIRED = 'Expired';
    public static final String APPROVAL_STATUS_CANCELLED = 'Cancelled';

    public static final String APPROVER_USER = 'User';
    public static final String APPROVER_QUEUE = 'Queue';
    public static final String APPROVER_ANCHOR_OWNER = 'Anchor Record Owner';
    public static final String APPROVER_REQUESTER_MANAGER = 'Requester\'s Manager';
    public static final String APPROVER_DELIVERY_CHANNEL = 'Delivery Channel';

    /** AgentTool__c.ApprovalMode__c. Blank means Not Required. */
    public static final String APPROVAL_NOT_REQUIRED = 'Not Required';
    public static final String APPROVAL_ALWAYS_REQUIRED = 'Always Required';
    public static final String APPROVAL_DECIDED_BY_POLICY = 'Decided by Policy';

    public static final String APPROVAL_EXPIRY_DENY = 'Deny and Continue';
    public static final String APPROVAL_EXPIRY_PAUSE = 'Pause for Operator';

    global enum ReconciliationDecision {
        ConfirmSucceeded,
        ConfirmFailed,
        Retry
    }

    global enum ToolAuthorizationDecision {
        Allow,
        Deny,
        RequireApproval
    }

    public class CommandSpec {
        public String commandType { get; set; }
        public String input { get; set; }
        public String toolName { get; set; }
        public String toolCallId { get; set; }
        /** The model's own, unverified explanation of a tool call, already trust-protected. */
        public String rationale { get; set; }
        public Datetime availableAt { get; set; }
        public Integer attemptNumber { get; set; }
        /** Set when a model command's input is its own transcript turn; see INPUT_SOURCE_*. */
        public String inputSource { get; set; }

        public CommandSpec() {
            attemptNumber = 0;
        }

        public CommandSpec(String commandType, String input, String toolName) {
            this();
            this.commandType = commandType;
            this.input = input;
            this.toolName = toolName;
        }
    }

    /** A leased attempt's request to run the same operation again after a retryable failure. */
    public class RetryRequest {
        public Id runId;
        public Id commandId;
        public Decimal expectedRevision;
        public String operationKey;
        public String leaseToken;
        public String errorCode;
        public String errorMessage;
        public Integer delaySeconds;
        public OperationalTelemetry telemetry;
        public List<Object> contextSources;
        public Integer exponentialSeconds;
        public Boolean retryAfterApplied;
        public Integer completedAttemptCount;
        public String configurationHash;
    }

    public class CommandOutcome {
        public Id runId { get; set; }
        public Id commandId { get; set; }
        public Decimal expectedRunRevision { get; set; }
        public String operationKey { get; set; }
        public String leaseToken { get; set; }
        public String commandStatus { get; set; }
        public String runStatus { get; set; }
        public String output { get; set; }
        public String eventType { get; set; }
        public String summary { get; set; }
        public String payload { get; set; }
        public String errorCode { get; set; }
        public String errorMessage { get; set; }
        public String providerRequestId { get; set; }
        public Long durationMilliseconds { get; set; }
        public Long inputTokens { get; set; }
        public Long outputTokens { get; set; }
        public Long totalTokens { get; set; }
        public String externalReference { get; set; }
        /** True when the provider reported no usage and the input tokens are Core's estimate. */
        public Boolean tokensEstimated { get; set; }
        /** Configuration hash the command ran with; a change from the run's last hash records Configuration Changed. */
        public String configurationHash { get; set; }
        public Integer retryIncrement { get; set; }
        public CommandSpec nextCommand { get; set; }
        public List<CommandSpec> nextCommands { get; set; }
        public Id nextCommandId { get; set; }
        public String waitingReason { get; set; }
        public String resumeJsonSchema { get; set; }
        public Datetime waitExpiresAt { get; set; }
        public String continuationMode { get; set; }
        /** The tool was never invoked, so this outcome does not count against Max Tool Calls. */
        public Boolean toolNotInvoked { get; set; }

        public CommandOutcome() {
            retryIncrement = 0;
        }
    }

    public static CommandOutcome continueWith(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String output, CommandSpec nextCommand) {
        CommandOutcome result = baseOutcome(runId, commandId, expectedRevision, operationKey);
        result.commandStatus = COMMAND_STATUS_SUCCEEDED;
        result.output = output;
        result.nextCommand = nextCommand;
        return result;
    }

    public static CommandOutcome succeed(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String output) {
        CommandOutcome result = baseOutcome(runId, commandId, expectedRevision, operationKey);
        result.commandStatus = COMMAND_STATUS_SUCCEEDED;
        result.runStatus = RUN_STATUS_SUCCEEDED;
        result.output = output;
        result.eventType = EVENT_RUN_COMPLETED;
        return result;
    }

    public static CommandOutcome terminalFailure(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String errorCode, String errorMessage) {
        CommandOutcome result = baseOutcome(runId, commandId, expectedRevision, operationKey);
        result.commandStatus = COMMAND_STATUS_FAILED;
        result.runStatus = RUN_STATUS_FAILED;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        result.eventType = EVENT_RUN_FAILED;
        return result;
    }

    /**
     * Stops execution at a durable operator-rescuable checkpoint. This is the
     * default for engine, provider, policy, trust, and configuration faults.
     */
    public static CommandOutcome pause(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String errorCode, String errorMessage) {
        CommandOutcome result = baseOutcome(runId, commandId, expectedRevision, operationKey);
        result.commandStatus = COMMAND_STATUS_FAILED;
        result.runStatus = RUN_STATUS_PAUSED;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        result.eventType = EVENT_RUN_PAUSED;
        result.summary = 'Run paused for operator intervention.';
        return result;
    }

    /**
     * Marks the tool command Failed and continues the run to a Model command so
     * the provider can adapt. Used for permanent business tool failures and human
     * tool-approval denials — not for hard policy Deny or operator cancel.
     */
    public static CommandOutcome continueAfterToolFailure(
        Id runId,
        Id commandId,
        Decimal expectedRevision,
        String operationKey,
        String errorCode,
        String errorMessage,
        CommandSpec nextModelCommand
    ) {
        CommandOutcome result = baseOutcome(runId, commandId, expectedRevision, operationKey);
        result.commandStatus = COMMAND_STATUS_FAILED;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        result.output = toolFailurePayload(errorCode, errorMessage);
        result.nextCommand = nextModelCommand;
        result.eventType = EVENT_TOOL_COMPLETED;
        result.summary = 'Tool failed; continuing to model.';
        return result;
    }

    /**
     * Records a model-generated protocol error as a durable failed command and
     * gives the provider one new turn containing bounded correction feedback.
     */
    public static CommandOutcome continueAfterModelFailure(
        Id runId,
        Id commandId,
        Decimal expectedRevision,
        String operationKey,
        String errorCode,
        String errorMessage,
        CommandSpec nextModelCommand
    ) {
        CommandOutcome result = baseOutcome(runId, commandId, expectedRevision, operationKey);
        result.commandStatus = COMMAND_STATUS_FAILED;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        result.output = modelFailurePayload(errorCode, errorMessage);
        if (nextModelCommand != null) {
            nextModelCommand.inputSource = INPUT_SOURCE_MODEL_FEEDBACK;
        }
        result.nextCommand = nextModelCommand;
        result.eventType = EVENT_MODEL_COMPLETED;
        result.summary = 'Model response rejected; requesting corrected output.';
        return result;
    }

    public static String modelFailurePayload(String errorCode, String errorMessage) {
        return JSON.serialize(
            new Map<String, Object>{
                'ok' => false,
                'errorCode' => String.isBlank(errorCode) ? 'MODEL_RESPONSE_INVALID' : errorCode,
                'errorMessage' => String.isBlank(errorMessage) ? 'The model response was invalid.' : errorMessage,
                'instruction' => 'Correct the response and comply with the supplied tool and output schemas.'
            }
        );
    }

    public static String toolFailurePayload(String errorCode, String errorMessage) {
        if (errorCode == ERROR_TOOL_APPROVAL_EXPIRED) {
            return JSON.serialize(
                new Map<String, Object>{
                    'ok' => false,
                    'errorCode' => ERROR_TOOL_APPROVAL_EXPIRED,
                    'errorMessage' => 'Nobody approved the tool call before its approval deadline, so it did not run.',
                    'instruction' => 'Do not assume the action happened; tell the user it still needs approval or choose another path.'
                }
            );
        }
        if (errorCode == ERROR_TOOL_APPROVAL_DENIED) {
            return JSON.serialize(
                new Map<String, Object>{
                    'ok' => false,
                    'errorCode' => ERROR_TOOL_APPROVAL_DENIED,
                    'errorMessage' => String.isBlank(errorMessage) ? 'A human reviewer denied the tool approval.' : errorMessage,
                    'instruction' => 'Do not repeat the same call unchanged; address the reviewer\'s reason or explain the denial to the user.'
                }
            );
        }
        if (errorCode == ERROR_TOOL_AUTHORIZATION_DENIED) {
            return JSON.serialize(
                new Map<String, Object>{
                    'ok' => false,
                    'errorCode' => ERROR_TOOL_AUTHORIZATION_DENIED,
                    'errorMessage' => String.isBlank(errorMessage) ? 'The authorization policy denied this tool call.' : errorMessage,
                    'instruction' => 'The call did not run. Do not retry it unchanged; choose another path or explain the limit to the user.'
                }
            );
        }
        // The tool's own code and message tell the model how to correct the call.
        return JSON.serialize(
            new Map<String, Object>{
                'ok' => false,
                'errorCode' => String.isBlank(errorCode) ? 'TOOL_ERROR' : errorCode,
                'errorMessage' => String.isBlank(errorMessage) ? 'The tool could not complete the request.' : boundedToolMessage(errorMessage)
            }
        );
    }

    private static String boundedToolMessage(String message) {
        return message.length() > MAX_TOOL_ERROR_MESSAGE_CHARACTERS ? message.substring(0, MAX_TOOL_ERROR_MESSAGE_CHARACTERS) : message;
    }

    public static CommandOutcome waitForResume(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String output) {
        CommandOutcome result = baseOutcome(runId, commandId, expectedRevision, operationKey);
        result.commandStatus = COMMAND_STATUS_SUCCEEDED;
        result.runStatus = RUN_STATUS_WAITING;
        result.output = output;
        result.eventType = EVENT_RUN_WAITING;
        return result;
    }

    public static CommandOutcome unknown(Id runId, Id commandId, Decimal expectedRevision, String operationKey, String errorCode, String errorMessage) {
        CommandOutcome result = baseOutcome(runId, commandId, expectedRevision, operationKey);
        result.commandStatus = COMMAND_STATUS_UNKNOWN;
        result.runStatus = RUN_STATUS_WAITING;
        result.errorCode = errorCode;
        result.errorMessage = errorMessage;
        result.eventType = EVENT_TOOL_OUTCOME_UNKNOWN;
        return result;
    }

    private static CommandOutcome baseOutcome(Id runId, Id commandId, Decimal expectedRevision, String operationKey) {
        CommandOutcome result = new CommandOutcome();
        result.runId = runId;
        result.commandId = commandId;
        result.expectedRunRevision = expectedRevision;
        result.operationKey = operationKey;
        return result;
    }

    global class StartResult {
        global Id runId { get; set; }
        global Id commandId { get; set; }
        global Decimal revision { get; set; }
        global String operationKey { get; set; }
        global Id anchorRecordId { get; set; }
        global Id parentRunId { get; set; }
        global String externalCorrelationKey { get; set; }
        global String invocationEntryPoint { get; set; }
        global Boolean deduplicated { get; set; }
        global String runStatus { get; set; }

        global StartResult() {
            deduplicated = false;
        }
    }

    global class StartRequest {
        global Id definitionId { get; set; }
        global String developerName { get; set; }
        global String input { get; set; }
        global Id anchorRecordId { get; set; }
        global Id parentRunId { get; set; }
        global String externalCorrelationKey { get; set; }

        global StartRequest() {
        }
    }

    global class ReconciliationRequest {
        global Id runId { get; set; }
        global Id commandId { get; set; }
        global Decimal expectedRunRevision { get; set; }
        global String operationKey { get; set; }
        global ReconciliationDecision decision { get; set; }
        global String confirmedOutput { get; set; }
        global String errorCode { get; set; }
        global String errorMessage { get; set; }
        global Boolean safeToRetryAttested { get; set; }
        global String reason { get; set; }
        /** ConfirmFailed only: true pauses the run for an operator; otherwise the model receives the failure and continues. */
        global Boolean pauseRun { get; set; }

        global ReconciliationRequest() {
        }
    }

    global class ReconciliationResult {
        global Id runId { get; set; }
        global Id reconciledCommandId { get; set; }
        global Id dispatchedCommandId { get; set; }
        global Decimal revision { get; set; }
        global String operationKey { get; set; }
        global String runStatus { get; set; }
        global String commandStatus { get; set; }

        global ReconciliationResult() {
        }
    }

    global class ResumeRequest {
        global Id runId { get; set; }
        global Decimal expectedRunRevision { get; set; }
        global String payload { get; set; }

        global ResumeRequest() {
        }
    }

    /**
     * A human decision on a tool-approval wait. deciderId is optional: blank
     * means the current user decided. Only the run's resolved service user may
     * record a decision made by another user, such as an approval channel.
     */
    /**
     * One approver's decision on an Agent Approval. deciderId is set only by an
     * approval channel relaying a decision made elsewhere; a direct approver
     * leaves it blank. comment reaches the model with a rejection.
     */
    global class ApprovalDecision {
        global Id approvalId { get; set; }
        global Boolean approved { get; set; }
        global String comment { get; set; }
        global Id deciderId { get; set; }

        global ApprovalDecision() {
        }
    }

    global class RescueRequest {
        global Id runId { get; set; }
        global Decimal expectedRunRevision { get; set; }
        global String guidance { get; set; }

        global RescueRequest() {
        }
    }

    /**
     * One call of a Decided by Policy tool for a policy to decide. Build the
     * answer with allow(), deny(reason), or requireApproval(reason) and an
     * approver, and read inputs with inputValue(name) or decimalInput(name).
     */
    global class ToolAuthorizationRequest {
        global Id runId { get; set; }
        global Id commandId { get; set; }
        global Id definitionId { get; set; }
        /** The tool's API name on this agent. An admin can change it; match on toolType to find a kind of tool. */
        global String toolName { get; set; }
        /** The API name of the tool's Agent Tool Type, such as UpdateRecord. */
        global String toolType { get; set; }
        /** The call's arguments as JSON, already checked against the tool's Input Schema. */
        global String input { get; set; }
        global String operationKey { get; set; }
        global Integer attemptNumber { get; set; }
        /** Whether the tool type can make callouts or other effects Core cannot roll back. */
        global Boolean hasExternalEffects { get; set; }
        global Id initiatingActorId { get; set; }
        /** The person a run of an agent with an identity works for, when that person started it; otherwise null. */
        global Id attendedById { get; set; }
        global Id resolvedPrincipalId { get; set; }
        /** The run's Agent Execution Identity; null when the run acts as the user who started it. */
        global Id executionIdentityId { get; set; }
        private transient Map<String, Object> arguments;

        /** One top-level input, or null when the call did not send it. */
        global Object inputValue(String name) {
            if (arguments == null) {
                Object parsed;
                try {
                    parsed = String.isBlank(input) ? null : JSON.deserializeUntyped(input);
                } catch (JSONException malformed) {
                    parsed = null;
                }
                arguments = parsed instanceof Map<String, Object> ? (Map<String, Object>) parsed : new Map<String, Object>();
            }
            return arguments.get(name);
        }

        /** One top-level number input, or null when it is missing or not a number. */
        global Decimal decimalInput(String name) {
            Object value = inputValue(name);
            if (value instanceof Decimal) {
                return (Decimal) value;
            }
            return value instanceof Integer || value instanceof Long || value instanceof Double ? Decimal.valueOf(String.valueOf(value)) : null;
        }

        global ToolAuthorizationResponse allow() {
            return new ToolAuthorizationResponse(ToolAuthorizationDecision.Allow, null);
        }

        /** The model receives TOOL_AUTHORIZATION_DENIED with this reason, so write it for the model. */
        global ToolAuthorizationResponse deny(String reason) {
            return new ToolAuthorizationResponse(ToolAuthorizationDecision.Deny, reason);
        }

        /** The approver sees this reason. Name the approver with byQueue or byUser; Core pauses the run if neither is named. */
        global ToolApprovalResponse requireApproval(String reason) {
            return new ToolApprovalResponse(reason);
        }
    }

    global virtual class ToolAuthorizationResponse {
        global ToolAuthorizationDecision decision { get; private set; }
        global String reason { get; private set; }

        public ToolAuthorizationResponse(ToolAuthorizationDecision decision, String reason) {
            this.decision = decision;
            this.reason = reason;
        }
    }

    /** A Require Approval answer: who approves the call, and optionally a deadline that replaces the tool's Approval Timeout. */
    global class ToolApprovalResponse extends ToolAuthorizationResponse {
        /** Whole minutes, 1 through 10,080 (7 days). Blank uses the tool's Approval Timeout. */
        global Integer timeoutMinutes { get; private set; }
        /** The API name of a queue that supports Agent Approval. Core pauses the run if it is missing. */
        global String approverQueue { get; private set; }
        global Id approverUserId { get; private set; }

        public ToolApprovalResponse(String reason) {
            super(ToolAuthorizationDecision.RequireApproval, reason);
        }

        /** Replaces any user named with byUser. */
        global ToolApprovalResponse byQueue(String queueApiName) {
            approverQueue = queueApiName;
            approverUserId = null;
            return this;
        }

        /** Replaces any queue named with byQueue. */
        global ToolApprovalResponse byUser(Id userId) {
            approverUserId = userId;
            approverQueue = null;
            return this;
        }

        global ToolApprovalResponse withTimeoutMinutes(Integer minutes) {
            timeoutMinutes = minutes;
            return this;
        }
    }

    /** Persistence-neutral readable projection of one agent run. */
    global class RunRecord {
        global Id id { get; set; }
        global Id agentDefinitionId { get; set; }
        global Id anchorRecordId { get; set; }
        global Id parentRunId { get; set; }
        global String externalCorrelationKey { get; set; }
        global String invocationEntryPoint { get; set; }
        global Id initiatingActorId { get; set; }
        /** The person a run of an agent with an identity works for; its data access is limited to theirs. */
        global Id attendedById { get; set; }
        /** Null when the run acts as the user who started it. */
        global Id executionIdentityId { get; set; }
        global Id expectedPrincipalId { get; set; }
        global Id resolvedPrincipalId { get; set; }
        global String loopbackNamedCredential { get; set; }
        global String executionContextStatus { get; set; }
        global String status { get; set; }
        global Decimal revision { get; set; }
        global Id currentCommandId { get; set; }
        global String input { get; set; }
        global String output { get; set; }
        global String inputHash { get; set; }
        global String outputHash { get; set; }
        global String payloadRetentionMode { get; set; }
        global Decimal retainedPayloadCharacters { get; set; }
        global Decimal modelCallCount { get; set; }
        global Decimal toolCallCount { get; set; }
        global Decimal retryCount { get; set; }
        global Decimal inputTokenCount { get; set; }
        global Decimal outputTokenCount { get; set; }
        global Decimal totalTokenCount { get; set; }
        global Decimal modelDurationMilliseconds { get; set; }
        global Decimal toolDurationMilliseconds { get; set; }
        global Datetime startedAt { get; set; }
        global Datetime lastActivityAt { get; set; }
        global Datetime completedAt { get; set; }
        global Datetime cancellationRequestedAt { get; set; }
        global String cancellationReason { get; set; }
        global String errorCode { get; set; }
        global String errorMessage { get; set; }
        global String waitingReason { get; set; }
        global String resumeJsonSchema { get; set; }
        global Datetime waitExpiresAt { get; set; }
        global String continuationMode { get; set; }
        global Id waitingCommandId { get; set; }

        global RunRecord() {
        }
    }

    /** Bounded projection of one Core approval wait for optional HITL adapters. */
    /** Persistence-neutral readable projection of one lifecycle event. */
    global class EventRecord {
        global Id id { get; set; }
        global Id runId { get; set; }
        global Decimal sequence { get; set; }
        global String eventType { get; set; }
        global String commandKey { get; set; }
        global Datetime occurredAt { get; set; }
        global String summary { get; set; }
        global String payload { get; set; }
        global String payloadHash { get; set; }
        global String payloadProtectionMode { get; set; }
        global Decimal originalPayloadLength { get; set; }
        global Boolean payloadTruncated { get; set; }
        global Boolean payloadRedacted { get; set; }

        global EventRecord() {
        }
    }

    /** Persistence-neutral readable projection of one durable command. */
    global class CommandRecord {
        global Id id { get; set; }
        global Id runId { get; set; }
        global String commandType { get; set; }
        global String status { get; set; }
        global Decimal expectedRunRevision { get; set; }
        global String operationKey { get; set; }
        global Decimal attemptNumber { get; set; }
        global Datetime leaseExpiresAt { get; set; }
        global Datetime availableAt { get; set; }
        global String input { get; set; }
        global String output { get; set; }
        global String inputHash { get; set; }
        global String outputHash { get; set; }
        global Datetime payloadPurgedAt { get; set; }
        global String toolName { get; set; }
        global String batchKey { get; set; }
        global Decimal batchOrdinal { get; set; }
        global Decimal batchSize { get; set; }
        global String errorCode { get; set; }
        global String errorMessage { get; set; }
        global String providerRequestId { get; set; }
        /** The model's own, unverified explanation of a tool call. Never a basis for authority. */
        global String rationale { get; set; }
        global String providerToolCallId { get; set; }
        global Decimal durationMilliseconds { get; set; }
        global Decimal inputTokens { get; set; }
        global Decimal outputTokens { get; set; }
        global Decimal totalTokens { get; set; }
        global String externalReference { get; set; }
        global Datetime createdAt { get; set; }

        global CommandRecord() {
        }
    }

    /** Persistence-neutral readable projection of one invocation attempt. */
    global class InvocationRecord {
        global Id id { get; set; }
        global Id runId { get; set; }
        global Id commandId { get; set; }
        global String invocationKey { get; set; }
        global Decimal attemptNumber { get; set; }
        global Decimal commandRevision { get; set; }
        global String invocationType { get; set; }
        global String outcome { get; set; }
        global String operationKey { get; set; }
        global String providerToolCallId { get; set; }
        global Datetime startedAt { get; set; }
        global Datetime completedAt { get; set; }
        global Decimal durationMilliseconds { get; set; }
        global Decimal inputTokens { get; set; }
        global Decimal outputTokens { get; set; }
        global Decimal totalTokens { get; set; }
        global String model { get; set; }
        global String modelAdapterClass { get; set; }
        global String modelIdentifier { get; set; }
        global Decimal estimatedCostUsd { get; set; }
        global Decimal appliedInputPricePerMillion { get; set; }
        global Decimal appliedOutputPricePerMillion { get; set; }
        global String providerRequestId { get; set; }
        /** ID of the Apex transaction that recorded the attempt. Attempts with the same value shared one transaction. */
        global String transactionId { get; set; }
        global String externalReference { get; set; }
        global String errorCode { get; set; }
        global String errorMessage { get; set; }
        global String request { get; set; }
        global String response { get; set; }
        global String nativeEvidence { get; set; }
        global String requestHash { get; set; }
        global String responseHash { get; set; }
        global String nativeEvidenceHash { get; set; }
        global String payloadProtectionMode { get; set; }
        global String evidenceMetadata { get; set; }
        global Datetime payloadPurgedAt { get; set; }
        global Datetime createdAt { get; set; }

        global InvocationRecord() {
        }
    }

    global class EventPageRequest {
        global Id runId { get; set; }
        global Decimal afterSequence { get; set; }
        global Id afterId { get; set; }
        global Integer limitSize { get; set; }

        global EventPageRequest() {
        }
    }

    global class EventPage {
        global List<EventRecord> events { get; set; }
        global Decimal nextSequence { get; set; }
        global Id nextId { get; set; }
        global Boolean hasMore { get; set; }

        global EventPage() {
            events = new List<EventRecord>();
            hasMore = false;
        }
    }

    global class CommandPageRequest {
        global Id runId { get; set; }
        global Datetime afterCreatedDate { get; set; }
        global Id afterId { get; set; }
        global Integer limitSize { get; set; }

        global CommandPageRequest() {
        }
    }

    global class CommandPage {
        global List<CommandRecord> commands { get; set; }
        global Datetime nextCreatedDate { get; set; }
        global Id nextId { get; set; }
        global Boolean hasMore { get; set; }

        global CommandPage() {
            commands = new List<CommandRecord>();
            hasMore = false;
        }
    }

    global class InvocationPageRequest {
        global Id runId { get; set; }
        global Datetime afterCreatedDate { get; set; }
        global Id afterId { get; set; }
        global Integer limitSize { get; set; }

        global InvocationPageRequest() {
        }
    }

    global class InvocationPage {
        global List<InvocationRecord> invocations { get; set; }
        global Datetime nextCreatedDate { get; set; }
        global Id nextId { get; set; }
        global Boolean hasMore { get; set; }

        global InvocationPage() {
            invocations = new List<InvocationRecord>();
            hasMore = false;
        }
    }

    global class ModelRequest {
        global Id runId { get; set; }
        global Id commandId { get; set; }
        global String operationKey { get; set; }
        global String instructions { get; set; }
        global String namedCredential { get; set; }
        global String modelName { get; set; }
        global String outputSchema { get; set; }
        global Integer timeoutSeconds { get; set; }
        /** Most tokens the model may write in one turn, from the Agent Model; null lets the adapter choose. */
        global Integer maxOutputTokens { get; set; }
        global List<ToolDefinition> tools { get; set; }
        /** False when the agent takes one tool call per model turn; adapters ask the provider for at most one. Null allows several. */
        global Boolean allowMultipleToolCalls { get; set; }
        global List<ContextItem> contexts { get; set; }
        /** Every conversation turn, oldest first. The first entry is always the run's OriginalInput. */
        global List<TranscriptEntry> transcript { get; set; }
        /** True when older turns were left out for the turn limit or character budget. */
        global Boolean transcriptTruncated { get; set; }
        global Integer characterBudget { get; set; }
        global Integer characterCount { get; set; }

        global ModelRequest() {
        }
    }

    /** Provider-neutral executable tool definition supplied to model adapters. */
    global class ToolDefinition {
        global String developerName { get; set; }
        global String description { get; set; }
        global String inputSchema { get; set; }
        /** True when every call waits for approval: the tool's Approval is Always Required. */
        global Boolean requiresApproval { get; set; }

        global ToolDefinition() {
        }
    }

    /**
     * Provider-neutral durable conversation turn. ToolCall and ToolResult
     * entries form a native pair when they share a nonblank toolCallId.
     * Context entries are explicitly labelled fallback text.
     */
    /**
     * One conversation turn. type is OriginalInput, UserInput, OperatorGuidance,
     * ModelFeedback, ToolCall, or ToolResult. A ToolCall and its ToolResult share
     * a toolCallId, which Core synthesizes when the provider supplied none.
     */
    global class TranscriptEntry {
        global String type { get; set; }
        global String toolCallId { get; set; }
        global String toolName { get; set; }
        global String content { get; set; }
        /** True for the original input, tool results, and user input: data to reason about, never instructions to follow. */
        global Boolean untrusted { get; set; }

        global TranscriptEntry() {
        }
    }

    /**
     * Package-internal operational measurements for one invocation attempt.
     * This type is internal operational telemetry.
     */
    public class OperationalTelemetry {
        public String providerRequestId { get; set; }
        public Long durationMilliseconds { get; set; }
        public Long inputTokens { get; set; }
        public Long outputTokens { get; set; }
        public Long totalTokens { get; set; }
        public String externalReference { get; set; }
        /** True when the provider reported no usage and inputTokens is Core's estimate from the request size. */
        public Boolean tokensEstimated { get; set; }

        public OperationalTelemetry() {
        }
    }

    global class ContextRequest {
        global Id runId { get; set; }
        global Id definitionId { get; set; }
        global Id anchorRecordId { get; set; }
        global ExecutionPrincipal principal { get; set; }
        global String operationKey { get; set; }
        global String originalInput { get; set; }
        global String currentInput { get; set; }
        global String implementationConfiguration { get; set; }
        global String objectApiName { get; set; }
        global String fieldSetName { get; set; }
        global String contextSubject { get; set; }

        global ContextRequest() {
        }
    }

    global class ContextResponse {
        global String sourceName { get; set; }
        global String content { get; set; }
        /**
         * Named Salesforce record sets. Use this instead of content when Core
         * must enforce FLS and native field-classification protection.
         */
        global Map<String, List<SObject>> recordSets { get; set; }

        global ContextResponse() {
        }
    }

    global class ContextItem {
        global String sourceName { get; set; }
        global String content { get; set; }
        global Map<String, List<SObject>> recordSets { get; set; }
        global Boolean truncated { get; set; }
        /** Always true: context comes from records and is data, never instructions. */
        global Boolean untrusted { get; set; }

        global ContextItem() {
        }
    }

    global class ModelResponse {
        global Boolean isSuccess { get; set; }
        global Boolean retryable { get; set; }
        global Boolean isFinal { get; set; }
        global String output { get; set; }
        global List<ModelToolCall> toolCalls { get; set; }
        global String providerRequestId { get; set; }
        global Long durationMilliseconds { get; set; }
        global Long inputTokens { get; set; }
        global Long outputTokens { get; set; }
        global Long totalTokens { get; set; }
        global Integer retryAfterSeconds { get; set; }
        global String errorCode { get; set; }
        global String errorMessage { get; set; }
        /** Optional bounded provider-native evidence. Never include credentials or authorization headers. */
        global String nativeRequestEvidence { get; set; }
        global String nativeResponseEvidence { get; set; }

        global ModelResponse() {
        }
    }

    /** One provider-neutral tool request in a sequential durable batch. */
    global class ModelToolCall {
        global String toolName { get; set; }
        global String toolInput { get; set; }
        global String toolCallId { get; set; }

        global ModelToolCall() {
        }
    }

    /**
     * Who a run acts for. Business work runs as resolvedPrincipalUserId: the
     * Agent Execution Identity's user when executionIdentityId is set, the
     * starting user otherwise.
     */
    global class ExecutionPrincipal {
        global Id initiatingUserId { get; private set; }
        /** The run's Agent Execution Identity; null when the run acts as the user who started it. */
        global Id executionIdentityId { get; private set; }
        global Id resolvedPrincipalUserId { get; private set; }
        global Id anchorRecordId { get; private set; }
        /**
         * The person a run of an agent with an identity works for, or null.
         * Tools must not return or change data this person could not read or
         * change themselves; ToolSecurity's requester helpers check it.
         */
        global Id attendedByUserId { get; private set; }

        global ExecutionPrincipal(Id initiatingUserId, Id executionIdentityId, Id resolvedPrincipalUserId, Id anchorRecordId, Id attendedByUserId) {
            this.initiatingUserId = initiatingUserId;
            this.executionIdentityId = executionIdentityId;
            this.resolvedPrincipalUserId = resolvedPrincipalUserId;
            this.anchorRecordId = anchorRecordId;
            this.attendedByUserId = attendedByUserId;
        }
    }

    public static ExecutionPrincipal principalOf(AgentRun__c run) {
        return new ExecutionPrincipal(
            run.InitiatingUser__c,
            run.ExecutionIdentity__c,
            run.ResolvedPrincipalUser__c,
            String.isBlank(run.AnchorRecordId__c) ? null : (Id) run.AnchorRecordId__c,
            run.AttendedBy__c
        );
    }

    /** What ITool.validateConfiguration checks: the saved tool's own settings. */
    global class ToolConfiguration {
        global String toolName { get; set; }
        global String implementationConfiguration { get; set; }
        /** The tool's input schema: hand-written, or built from the settings with the admin's edits. Blank in IToolAuthoring.describe. */
        global String inputSchema { get; set; }

        global ToolConfiguration() {
        }
    }

    /**
     * What IToolAuthoring.describe returns: the settings an admin fills in,
     * and the input schema those settings give the model. Return either
     * inputSchema or problem, unless inputsWrittenByAdmin is true.
     */
    global class ToolAuthoring {
        global List<ToolSetting> settings { get; set; }
        /** The closed Input Schema this configuration implies. */
        global String inputSchema { get; set; }
        /** Why inputSchema cannot be built from this configuration yet, telling the admin what to fix. */
        global String problem { get; set; }
        /**
         * True when the tool type describes only its settings and the admin
         * writes the inputs in Input Schema, as for an API call whose inputs
         * only the admin knows. Set it the same for every configuration.
         */
        global Boolean inputsWrittenByAdmin { get; set; }

        global ToolAuthoring() {
            this.settings = new List<ToolSetting>();
        }
    }

    /**
     * One Implementation Configuration key an authoring screen asks the admin
     * for, shown with the control its type names:
     * - string, text (several lines), integer, number, boolean: a plain value.
     * - textList: a list of text values, one per line.
     * - keyValues: an object of names to text values. allowedValues limits the values.
     * - object: an object API name.
     * - recordType: a record type developer name of the object in objectSetting.
     * - fields: a list of field API names of the object in objectSetting or objectApiName.
     * - fieldValues: an object of field API name to value, for the object in objectSetting.
     * - record: a record ID of one of recordObjects. Blank means blankMeaning.
     * - query: a SOQL query.
     * - flow: an autolaunched Flow API name.
     * - report: a report API name.
     * - queue: a queue API name.
     * - namedCredential: a Named Credential API name.
     * - json: any JSON value, typed as JSON.
     * The key inputOverrides is Core's, for the admin's edits to the inputs.
     */
    global class ToolSetting {
        global String name { get; set; }
        global String label { get; set; }
        global String type { get; set; }
        /** For recordType, fields, and fieldValues: the name of the object setting they belong to. */
        global String objectSetting { get; set; }
        /** For fields on one fixed object, such as Knowledge__kav: that object's API name. */
        global String objectApiName { get; set; }
        /** For record: the objects the record may belong to, such as User and CollaborationGroup. */
        global List<String> recordObjects { get; set; }
        /** For an optional setting: what the tool does when it is blank, such as "Post to the run's record". */
        global String blankMeaning { get; set; }
        global Boolean required { get; set; }
        global String helpText { get; set; }
        /** The only values the tool accepts, when it accepts a fixed set. */
        global List<String> allowedValues { get; set; }

        global ToolSetting() {
        }

        global ToolSetting(String name, String label, String type, Boolean required, String helpText) {
            this.name = name;
            this.label = label;
            this.type = type;
            this.required = required;
            this.helpText = helpText;
        }
    }

    global class ToolRequest {
        global Id runId { get; set; }
        global String toolName { get; set; }
        global String input { get; set; }
        global String implementationConfiguration { get; set; }
        global String operationKey { get; set; }
        global ExecutionPrincipal principal { get; set; }
        /**
         * Hand this to an outside system when the tool returns
         * awaitingExternalInput; its callback resumes this wait, and only this
         * one, with AgentRunService.resumeWait. A secret: never log it or put
         * it in output.
         */
        global String resumeKey { get; set; }

        global ToolRequest() {
        }
    }

    global class ToolResponse {
        global Boolean isSuccess { get; set; }
        global Boolean retryable { get; set; }
        global Boolean outcomeUnknown { get; set; }
        global String output { get; set; }
        /** Optional structured Salesforce output, mutually exclusive with output. */
        global Map<String, List<SObject>> recordSets { get; set; }
        global String externalReference { get; set; }
        global Long durationMilliseconds { get; set; }
        global Integer retryAfterSeconds { get; set; }
        global String errorCode { get; set; }
        global String errorMessage { get; set; }
        global Boolean awaitingExternalInput { get; set; }
        global String waitingReason { get; set; }
        global String resumeJsonSchema { get; set; }
        global Integer waitTimeoutSeconds { get; set; }
        /** Optional bounded target-native evidence. Never include credentials or authorization headers. */
        global String nativeRequestEvidence { get; set; }
        global String nativeResponseEvidence { get; set; }

        global ToolResponse() {
        }
    }
}
