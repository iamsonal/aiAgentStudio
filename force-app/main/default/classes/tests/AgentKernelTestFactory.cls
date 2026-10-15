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
public class AgentKernelTestFactory {
    public static final String KERNEL_TEST_MODEL = 'KernelTestModel';
    public static final String TEST_LOOPBACK = 'Agent_Core_Loopback';
    private static Integer sequence = 0;

    public static AgentModel__mdt kernelTestModel() {
        return new AgentModel__mdt(
            DeveloperName = KERNEL_TEST_MODEL,
            ModelAdapterClass__c = 'KernelTestModelProvider',
            NamedCredential__c = 'Kernel_Test_Named_Credential',
            ModelIdentifier__c = 'kernel-test-model',
            IsActive__c = true
        );
    }

    public static AgentDefinition__c createDefinition() {
        return createDefinition(5, 10);
    }

    public static AgentDefinition__c createDefinition(Integer maxModelCalls, Integer maxToolCalls) {
        return createDefinition(maxModelCalls, maxToolCalls, 2);
    }

    public static AgentDefinition__c createDefinition(Integer maxModelCalls, Integer maxToolCalls, Integer maxRetries) {
        TrustKeyProvider.provision();
        AgentModelService.setTestModels(new List<AgentModel__mdt>{ kernelTestModel() });
        sequence++;
        AgentDefinition__c definition = new AgentDefinition__c(
            Name = 'Kernel Test Agent ' + sequence,
            DeveloperName__c = 'kernel_test_agent_' + sequence,
            IsActive__c = true,
            Instructions__c = 'Run the focused phase-one kernel tests.',
            Model__c = KERNEL_TEST_MODEL,
            MaxModelCalls__c = maxModelCalls,
            MaxToolCalls__c = maxToolCalls,
            MaxRetries__c = maxRetries,
            OutputSchema__c = '{"type":"object"}'
        );
        insert definition;
        return definition;
    }

    /**
     * Gives the definition an Agent Execution Identity with a new, dedicated
     * execution user. Work the loopback would run as that user belongs in
     * System.runAs(principal(identity)).
     */
    public static AgentExecutionIdentity__c useDelegatedPrincipal(AgentDefinition__c definition) {
        return useDelegatedPrincipal(definition, servicePrincipalUser().Id);
    }

    public static AgentExecutionIdentity__c useDelegatedPrincipal(AgentDefinition__c definition, Id principalId) {
        AgentExecutionIdentity__c identity = serviceUser(principalId);
        definition.ExecutionIdentity__c = identity.Id;
        update definition;
        AgentConfigService.clearCacheForTest();
        return identity;
    }

    /** Records the loopback landing as the run's snapshotted principal, as dispatch does before the first lease. */
    public static void acceptLoopback(AgentKernelModels.StartResult started) {
        AgentCommand__c initial = getCommand(started.commandId);
        System.runAs(worker(started.runId)) {
            AgentKernel.acceptLoopbackDispatch(started.runId, started.commandId, started.revision, started.operationKey, initial.DispatchToken__c);
        }
    }

    /** The execution user behind an execution identity, for System.runAs. */
    public static User principal(AgentExecutionIdentity__c identity) {
        return new User(Id = identity.PrincipalUser__c);
    }

    public static final String HUMAN_DECISION = 'AgentKernelHumanDecision';
    public static final String OPERATOR = 'AgentKernelOperator';
    public static final String ADMIN = 'AgentKernelAdmin';
    public static final String APPROVAL_RELAY = 'AgentKernelApprovalRelay';
    public static final String TRUST_RESOLVER = 'AgentKernelTrustResolver';
    public static final String SERVICE_PRINCIPAL = 'AgentKernelServicePrincipal';

    /** The running user, for System.runAs blocks that must see permission sets granted in the test. */
    /** One count of a Health action, or 0 when the action or count is absent. */
    public static Integer healthCount(AgentKernelHealthService.HealthReport report, String actionCode, String countName) {
        for (AgentKernelHealthService.HealthAction action : report.actions) {
            if (action.code == actionCode) {
                return action.counts.containsKey(countName) ? action.counts.get(countName) : 0;
            }
        }
        return 0;
    }

    public static User self() {
        return new User(Id = UserInfo.getUserId());
    }

    /**
     * Assigns Core permission sets to a user. Custom permission checks see the
     * grant inside a later System.runAs block for that user.
     */
    public static void grant(Id userId, List<String> permissionSetNames) {
        Set<Id> assigned = new Set<Id>();
        for (PermissionSetAssignment assignment : [SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId = :userId]) {
            assigned.add(assignment.PermissionSetId);
        }
        List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
        for (PermissionSet permissionSet : [SELECT Id FROM PermissionSet WHERE Name IN :permissionSetNames]) {
            if (!assigned.contains(permissionSet.Id)) {
                assignments.add(new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permissionSet.Id));
            }
        }
        System.runAs(self()) {
            insert assignments;
        }
    }

    public static void grant(List<String> permissionSetNames) {
        grant(UserInfo.getUserId(), permissionSetNames);
    }

    /** A new active user with the running user's profile and the given Core permission sets. */
    public static User userWith(List<String> permissionSetNames) {
        return userWith(permissionSetNames, UserInfo.getProfileId());
    }

    /** A new active user with a non-admin profile, so only the given Core permission sets grant access. */
    public static User standardUserWith(List<String> permissionSetNames) {
        Profile standard = [SELECT Id FROM Profile WHERE UserLicense.Name = 'Salesforce' AND Name != 'System Administrator' LIMIT 1];
        return userWith(permissionSetNames, standard.Id);
    }

    private static User userWith(List<String> permissionSetNames, Id profileId) {
        sequence++;
        User created = new User(
            Alias = 'akt' + sequence,
            Email = 'agent-kernel-test@example.com',
            Username = 'agent-kernel-test-' + sequence + '-' + Crypto.getRandomInteger() + '@example.com',
            LastName = 'Kernel Test ' + sequence,
            ProfileId = profileId,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        System.runAs(self()) {
            insert created;
        }
        grant(created.Id, permissionSetNames);
        return created;
    }

    /** A new active user set up as the documented execution user: Service Principal, and no decision or relay authority. */
    public static User servicePrincipalUser() {
        return userWith(new List<String>{ SERVICE_PRINCIPAL });
    }

    /** An active user other than the running user who holds Human Decision. */
    public static Id approverUser() {
        return userWith(new List<String>{ HUMAN_DECISION }).Id;
    }

    /** A retry request for the leased command, as the worker builds it. */
    public static AgentKernelModels.RetryRequest retryRequest(AgentRun__c run, AgentCommand__c command, String errorCode, Integer delaySeconds) {
        AgentKernelModels.RetryRequest request = new AgentKernelModels.RetryRequest();
        request.runId = run.Id;
        request.commandId = command.Id;
        request.expectedRevision = run.Revision__c;
        request.operationKey = command.OperationKey__c;
        request.leaseToken = command.LeaseToken__c;
        request.errorCode = errorCode;
        request.errorMessage = 'Retry requested.';
        request.delaySeconds = delaySeconds;
        return request;
    }

    public static AgentKernelModels.ResumeRequest resumeRequest(Id runId, Decimal expectedRevision, String payload) {
        AgentKernelModels.ResumeRequest request = new AgentKernelModels.ResumeRequest();
        request.runId = runId;
        request.expectedRunRevision = expectedRevision;
        request.payload = payload;
        return request;
    }

    /** Starts a run through the kernel without dispatching it. */
    public static AgentKernelModels.StartResult start(Id definitionId, String input) {
        return start(definitionId, input, null);
    }

    public static AgentKernelModels.StartResult start(Id definitionId, String input, Id anchorRecordId) {
        AgentKernelModels.StartRequest request = new AgentKernelModels.StartRequest();
        request.definitionId = definitionId;
        request.input = input;
        request.anchorRecordId = anchorRecordId;
        return AgentKernel.startRun(request, AgentKernelModels.INVOCATION_APEX);
    }

    public static AgentKernelModels.StartRequest startRequest(AgentDefinition__c definition, String input) {
        AgentKernelModels.StartRequest request = new AgentKernelModels.StartRequest();
        request.definitionId = definition.Id;
        request.input = input;
        return request;
    }

    public static AgentApprovalService.Request approvalRequest(Id ownerId) {
        AgentApprovalService.Request request = new AgentApprovalService.Request();
        request.reason = 'Approval required.';
        request.expiresAt = System.now().addHours(1);
        request.ownerId = ownerId;
        request.approverType = AgentKernelModels.APPROVER_USER;
        request.expiryAction = AgentKernelModels.APPROVAL_EXPIRY_DENY;
        return request;
    }

    /** Opens an approval directly, for fixtures that fabricate a waiting run. */
    public static AgentApproval__c openApproval(AgentRun__c run, AgentCommand__c command, Id ownerId) {
        return AgentApprovalService.open(run, command, approvalRequest(ownerId));
    }

    public static AgentApproval__c pendingApproval(Id runId) {
        return [
            SELECT
                Id,
                OwnerId,
                Status__c,
                AgentCommand__c,
                ApproverType__c,
                DecidedBy__c,
                RelayedBy__c,
                DecisionComment__c,
                ClosedAt__c,
                ExpiresAt__c,
                RunRevision__c
            FROM AgentApproval__c
            WHERE AgentRun__c = :runId
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
    }

    public static AgentKernelModels.ApprovalDecision approvalDecision(Id approvalId, Boolean approved, String comment) {
        AgentKernelModels.ApprovalDecision decision = new AgentKernelModels.ApprovalDecision();
        decision.approvalId = approvalId;
        decision.approved = approved;
        decision.comment = comment;
        return decision;
    }

    public static AgentExecutionIdentity__c serviceUser(Id principalId) {
        return serviceUser(principalId, TEST_LOOPBACK);
    }

    public static AgentExecutionIdentity__c serviceUser(Id principalId, String namedCredential) {
        if (ExecutionIdentityService.testNamedCredentials == null) {
            ExecutionIdentityService.testNamedCredentials = new Set<String>();
        }
        ExecutionIdentityService.testNamedCredentials.add(namedCredential);
        List<AgentExecutionIdentity__c> existing = [
            SELECT Id, PrincipalUser__c
            FROM AgentExecutionIdentity__c
            WHERE LoopbackNamedCredential__c = :namedCredential
            LIMIT 1
        ];
        AgentExecutionIdentity__c identity = existing.isEmpty()
            ? new AgentExecutionIdentity__c(Name = namedCredential, LoopbackNamedCredential__c = namedCredential, IsActive__c = true)
            : existing[0];
        identity.PrincipalUser__c = principalId;
        upsert identity;
        return identity;
    }

    public static void configureExecutionPolicy(AgentExecutionPolicyService.Policy policy) {
        AgentExecutionPolicyService.setTestOverride(policy);
    }

    public static AgentExecutionPolicyService.Policy executionPolicyOverride() {
        return AgentExecutionPolicyService.resolve();
    }

    public static AgentTool__c createTool(Id definitionId, String developerName, String inputSchema) {
        if (inputSchema == '{"type":"object"}') {
            inputSchema = '{"type":"object","properties":{},"additionalProperties":false}';
        }
        AgentTool__c tool = new AgentTool__c(
            Name = 'Kernel Test Tool ' + developerName,
            AgentDefinition__c = definitionId,
            DeveloperName__c = developerName,
            Description__c = 'A test-only kernel tool.',
            ToolType__c = AgentToolTypeTestFixtures.IN_ORG,
            InputSchema__c = inputSchema,
            IsActive__c = true,
            SortOrder__c = 1
        );
        insert tool;
        return tool;
    }

    /** A tool whose calls the agent's policy decides. Set the definition's policy class first. */
    public static AgentTool__c createPolicyTool(Id definitionId, String developerName) {
        AgentTool__c tool = createTool(definitionId, developerName, '{"type":"object"}');
        tool.ApprovalMode__c = AgentKernelModels.APPROVAL_DECIDED_BY_POLICY;
        tool.ApprovalExpiryAction__c = AgentKernelModels.APPROVAL_EXPIRY_DENY;
        updateRecord(tool);
        return tool;
    }

    public static AgentContextProvider__c createContextProvider(Id definitionId, String developerName, String implementationReference) {
        AgentContextProvider__c provider = new AgentContextProvider__c(
            Name = 'Kernel Test Context ' + developerName,
            AgentDefinition__c = definitionId,
            DeveloperName__c = developerName,
            Description__c = 'Test context provider.',
            ImplementationType__c = 'Apex',
            ImplementationReference__c = implementationReference,
            IsActive__c = true,
            SortOrder__c = 1
        );
        insert provider;
        return provider;
    }

    /**
     * Fixture updates run in system mode so authoring fields such as tool
     * side-effect type remain writable in tests without granting operators
     * lifecycle edit rights.
     */
    public static void updateRecord(SObject record) {
        updateRecords(new List<SObject>{ record });
    }

    public static void insertRecord(SObject record) {
        insertRecords(new List<SObject>{ record });
    }

    public static void insertRecords(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            return;
        }
        Database.insert(records, AccessLevel.SYSTEM_MODE);
    }

    public static void updateRecords(List<SObject> records) {
        if (records == null || records.isEmpty()) {
            return;
        }
        for (SObject record : records) {
            if (record instanceof AgentCommand__c) {
                AgentCommand__c command = (AgentCommand__c) record;
                if (
                    command.CommandType__c == AgentKernelModels.COMMAND_TYPE_TOOL &&
                    command.Status__c == AgentKernelModels.COMMAND_STATUS_LEASED &&
                    command.AdmittedToolBindingHash__c == null
                ) {
                    try {
                        AgentTool__c tool = AgentRunConfigurationService.getTool(command.AgentRun__c, command.ToolName__c);
                        AgentToolTypeService.admit(command, tool);
                    } catch (Exception unavailableTool) {
                        // Negative configuration fixtures intentionally lack an active tool.
                    }
                }
            }
        }
        Database.update(records, AccessLevel.SYSTEM_MODE);
    }

    public static void replaceCurrentCommand(AgentKernelModels.StartResult started, AgentCommand__c command) {
        AgentRun__c run = getRun(started.runId);
        Decimal nextRevision = run.Revision__c + 1;
        updateRecord(new AgentRun__c(Id = run.Id, CurrentCommand__c = command.Id, Revision__c = nextRevision));
        updateRecord(new AgentCommand__c(Id = command.Id, ExpectedRunRevision__c = nextRevision));
        command.ExpectedRunRevision__c = nextRevision;
        started.revision = nextRevision;
    }

    public static AgentCommand__c insertToolCommand(Id runId, Decimal revision, String toolName, String status) {
        AgentCommand__c command = new AgentCommand__c(
            AgentRun__c = runId,
            CommandType__c = AgentKernelModels.COMMAND_TYPE_TOOL,
            Status__c = status,
            ExpectedRunRevision__c = revision,
            OperationKey__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
            DispatchToken__c = EncodingUtil.convertToHex(Crypto.generateAesKey(128)),
            ToolName__c = toolName,
            Input__c = '{}',
            AvailableAt__c = System.now(),
            AttemptNumber__c = 1
        );
        Database.insert(command, AccessLevel.SYSTEM_MODE);
        return command;
    }

    /**
     * Starts directly through the kernel so lifecycle tests can assert the
     * persisted Pending boundary without enqueuing hidden async work.
     */
    public static AgentKernelModels.StartResult startRunWithoutDispatch(AgentDefinition__c definition) {
        return start(definition.Id, '{"request":"test"}');
    }

    public static AgentRun__c getRun(Id runId) {
        return [
            SELECT
                Id,
                Status__c,
                ParentRun__c,
                ExternalCorrelationKey__c,
                InitiatingUser__c,
                ExecutionIdentity__c,
                LoopbackNamedCredential__c,
                ExpectedPrincipalUser__c,
                ResolvedPrincipalUser__c,
                ExecutionContextStatus__c,
                Revision__c,
                LastEventSequence__c,
                CurrentCommand__c,
                Input__c,
                InputHash__c,
                OutputHash__c,
                PayloadRetentionMode__c,
                RetainedPayloadCharacters__c,
                ModelCallCount__c,
                ToolCallCount__c,
                RetryCount__c,
                InputTokenCount__c,
                OutputTokenCount__c,
                TotalTokenCount__c,
                ModelDurationMs__c,
                ToolDurationMs__c,
                CompletedAt__c,
                PurgeAfter__c,
                CancellationRequestedAt__c,
                CancellationReason__c,
                WaitingReason__c,
                ResumeJsonSchema__c,
                WaitExpiresAt__c,
                ContinuationMode__c,
                WaitingCommand__c,
                ErrorCode__c,
                ErrorMessage__c,
                Output__c,
                ConfigurationHash__c
            FROM AgentRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
        ];
    }

    public static AgentCommand__c getCommand(Id commandId) {
        return [
            SELECT
                Id,
                AgentRun__c,
                CommandType__c,
                Status__c,
                ExpectedRunRevision__c,
                OperationKey__c,
                DispatchToken__c,
                ToolName__c,
                Input__c,
                Output__c,
                InputHash__c,
                OutputHash__c,
                ErrorCode__c,
                ErrorMessage__c,
                AttemptNumber__c,
                RetryWindowStartAttempt__c,
                LeaseToken__c,
                LeaseExpiresAt__c,
                RecoveryCheckAt__c,
                AdmittedEffects__c,
                AdmittedToolBindingHash__c,
                WorkerJobId__c,
                WorkerEnqueuedAt__c,
                DeliveryAnomalyCode__c,
                DeliveryAnomalyCount__c,
                LastDeliveryAnomalyAt__c,
                AvailableAt__c,
                ProviderRequestId__c,
                ProviderToolCallId__c,
                DurationMs__c,
                InputTokens__c,
                OutputTokens__c,
                TotalTokens__c,
                ExternalReference__c,
                PolicyApproved__c
            FROM AgentCommand__c
            WHERE Id = :commandId
            WITH SYSTEM_MODE
        ];
    }

    public static AgentKernelModels.CommandOutcome applyOutcome(AgentKernelModels.CommandOutcome outcome) {
        AgentCommand__c command = getCommand(outcome.commandId);
        if (command.Status__c == AgentKernelModels.COMMAND_STATUS_PENDING) {
            command.Status__c = AgentKernelModels.COMMAND_STATUS_LEASED;
            command.LeaseToken__c = 'test-lease-' + sequence + '-' + command.Id;
            command.LeaseExpiresAt__c = System.now().addMinutes(5);
            command.AttemptNumber__c = (command.AttemptNumber__c == null ? 0 : command.AttemptNumber__c) + 1;
            updateRecord(command);
            command = getCommand(command.Id);
        }
        outcome.leaseToken = command.LeaseToken__c;
        AgentKernelModels.CommandOutcome applied;
        System.runAs(worker(outcome.runId)) {
            applied = AgentKernel.applyOutcome(outcome);
        }
        return applied;
    }

    private static final Integer MAX_DRIVEN_STEPS = 12;
    /** SOQL queries each worker step used in the last runUntilSettled call. */
    public static List<Integer> stepQueries = new List<Integer>();
    /** Commands each step finished; a model step also finishes the tool calls that ran in its job. */
    public static List<Integer> stepCommands = new List<Integer>();

    /**
     * Runs a run's commands through the real model and tool workers, as
     * dispatch would, until the run waits, pauses, or ends. Each step leases
     * the current command as the run's worker user. Queued dispatch is
     * suppressed, so the test drives every step itself.
     */
    public static AgentRun__c runUntilSettled(Id runId) {
        AgentRun__c run = runSteps(runId, MAX_DRIVEN_STEPS);
        System.assert(
            run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING || run.CurrentCommand__c == null,
            'The run did not settle within ' + MAX_DRIVEN_STEPS + ' steps.'
        );
        return run;
    }

    /**
     * Runs at most maxSteps worker steps, so a long scenario can stop, call
     * Test.startTest() for fresh limits, and continue.
     */
    public static AgentRun__c runSteps(Id runId, Integer maxSteps) {
        CommandDeliveryTracker.suppressEnqueueForTest = true;
        stepQueries = new List<Integer>();
        stepCommands = new List<Integer>();
        for (Integer step = 0; step < maxSteps; step++) {
            AgentRun__c run = getRun(runId);
            if (run.Status__c != AgentKernelModels.RUN_STATUS_RUNNING || run.CurrentCommand__c == null) {
                return run;
            }
            System.assert(
                Limits.getLimitQueries() - Limits.getQueries() >= 30,
                'Too few queries left for another step; split the test with Test.startTest(). Queries per step so far: ' + stepQueries
            );
            AgentCommand__c command = getCommand(run.CurrentCommand__c);
            Integer settledBefore = settledCommands(runId);
            Integer queriesBefore = Limits.getQueries();
            System.runAs(worker(runId)) {
                if (ExecutionIdentityService.usesIdentity(run) && run.ResolvedPrincipalUser__c == null) {
                    AgentKernel.acceptLoopbackDispatch(run.Id, command.Id, run.Revision__c, command.OperationKey__c, command.DispatchToken__c);
                }
                // Dispatch may have leased it already; its queued worker job was suppressed.
                CommandLeaseService.Result leased = new CommandLeaseService.Result();
                leased.outcome = CommandLeaseService.Outcome.Leased;
                if (command.Status__c != AgentKernelModels.COMMAND_STATUS_LEASED) {
                    leased = CommandLeaseService.tryLease(run.Id, command.Id, run.Revision__c, command.OperationKey__c, command.DispatchToken__c);
                }
                System.assertEquals(
                    CommandLeaseService.Outcome.Leased,
                    leased.outcome,
                    'The current ' +
                        command.CommandType__c +
                        ' command must lease. Command ' +
                        command.Status__c +
                        ' at revision ' +
                        command.ExpectedRunRevision__c +
                        ', available ' +
                        command.AvailableAt__c +
                        '; run ' +
                        run.Status__c +
                        ' at revision ' +
                        run.Revision__c +
                        ', context ' +
                        run.ExecutionContextStatus__c
                );
                AgentCommand__c current = getCommand(command.Id);
                if (current.CommandType__c == AgentKernelModels.COMMAND_TYPE_MODEL) {
                    new ModelCommandQueueable(run.Id, current.Id, current.ExpectedRunRevision__c, current.OperationKey__c, current.LeaseToken__c).execute(null);
                } else {
                    new ToolCommandQueueable(run.Id, current.Id, current.ExpectedRunRevision__c, current.OperationKey__c, current.LeaseToken__c).execute(null);
                }
            }
            stepQueries.add(Limits.getQueries() - queriesBefore);
            stepCommands.add(Math.max(1, settledCommands(runId) - settledBefore));
        }
        return getRun(runId);
    }

    private static Integer settledCommands(Id runId) {
        return [
            SELECT COUNT()
            FROM AgentCommand__c
            WHERE
                AgentRun__c = :runId
                AND Status__c NOT IN (
                    :AgentKernelModels.COMMAND_STATUS_PENDING,
                    :AgentKernelModels.COMMAND_STATUS_BLOCKED,
                    :AgentKernelModels.COMMAND_STATUS_LEASED,
                    :AgentKernelModels.COMMAND_STATUS_RETRY_WAITING
                )
        ];
    }

    /**
     * Checks the lifecycle rules every run must keep, whatever happened to it,
     * in one query: events are numbered 1..N with no gap or repeat, at most one
     * command is queued or leased and it is the run's current command, and a
     * finished run has completed with nothing left to do.
     */
    public static void assertLifecycleInvariants(Id runId) {
        AgentRun__c run = [
            SELECT
                Status__c,
                CurrentCommand__c,
                CompletedAt__c,
                LastEventSequence__c,
                (SELECT Sequence__c FROM Events__r ORDER BY Sequence__c ASC),
                (SELECT Id, Status__c FROM Commands__r WHERE Status__c IN ('Pending', 'Retry Waiting', 'Leased'))
            FROM AgentRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
        ];
        for (Integer index = 0; index < run.Events__r.size(); index++) {
            System.assertEquals(index + 1, run.Events__r[index].Sequence__c, 'Events must be numbered without gaps or repeats.');
        }
        System.assertEquals(run.Events__r.size(), run.LastEventSequence__c, 'The run must point at its last event.');
        System.assert(run.Commands__r.size() <= 1, 'At most one command may be queued or leased: ' + run.Commands__r);
        if (!run.Commands__r.isEmpty()) {
            System.assertEquals(run.CurrentCommand__c, run.Commands__r[0].Id, 'The queued or leased command must be the current one.');
            System.assert(
                run.Status__c == AgentKernelModels.RUN_STATUS_RUNNING || run.Status__c == AgentKernelModels.RUN_STATUS_PAUSED,
                'Only a running or paused run holds queued work, not a ' + run.Status__c + ' one.'
            );
        }
        if (
            new Set<String>{ AgentKernelModels.RUN_STATUS_SUCCEEDED, AgentKernelModels.RUN_STATUS_FAILED, AgentKernelModels.RUN_STATUS_CANCELLED }
                .contains(run.Status__c)
        ) {
            System.assertNotEquals(null, run.CompletedAt__c, 'A finished run records when it finished.');
            System.assertEquals(null, run.CurrentCommand__c, 'A finished run has no current command.');
        }
    }

    /** The user a run's worker executes as: the identity's execution user when the run has one, else the running user. */
    public static User worker(Id runId) {
        AgentRun__c run = getRun(runId);
        return ExecutionIdentityService.usesIdentity(run) ? new User(Id = run.ExpectedPrincipalUser__c) : self();
    }

    /** An Agent Execution Identity Id for in-memory records that are never saved. */
    public static Id unsavedIdentityId() {
        return (Id) (AgentExecutionIdentity__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001');
    }

    public static List<AgentEvent__c> getEvents(Id runId) {
        return [
            SELECT
                Id,
                Sequence__c,
                EventType__c,
                CommandKey__c,
                Summary__c,
                Payload__c,
                PayloadHash__c,
                PayloadProtectionMode__c,
                OriginalPayloadLength__c,
                PayloadTruncated__c,
                PayloadRedacted__c
            FROM AgentEvent__c
            WHERE AgentRun__c = :runId
            WITH SYSTEM_MODE
            ORDER BY Sequence__c
        ];
    }
}
