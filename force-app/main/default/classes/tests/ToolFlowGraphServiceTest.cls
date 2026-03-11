/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Copyright (c) 2025 Sonal
 */

/**
 * @description Tests for ToolFlowGraphService — covers eligible computation, gateway
 * types, join gates, exclusive locking, staleness detection, and no-graph fallback.
 */
@IsTest
private class ToolFlowGraphServiceTest {
    // ── helpers ────────────────────────────────────────────────────────────────

    private static ToolFlowGraphService.FlowGraph buildGraph(List<String> entry, List<Map<String, Object>> rules) {
        Map<String, Object> raw = new Map<String, Object>{ 'version' => '3.0', 'entry' => entry };
        if (rules != null) {
            raw.put('flow', rules);
        }
        return ToolFlowGraphService.parseGraph(JSON.serialize(raw));
    }

    private static Map<String, Object> rule(Object fromVal, String ruleType, List<String> toVal) {
        List<String> fromTools = new List<String>();
        if (fromVal instanceof String) {
            fromTools.add((String) fromVal);
        } else if (fromVal instanceof List<String>) {
            fromTools.addAll((List<String>) fromVal);
        } else if (fromVal instanceof List<Object>) {
            for (Object item : (List<Object>) fromVal) {
                if (item != null) {
                    fromTools.add(String.valueOf(item));
                }
            }
        }
        return new Map<String, Object>{ 'fromTools' => fromTools, 'type' => ruleType, 'toTools' => toVal };
    }

    // ── parseGraph ──────────────────────────────────────────────────────────────

    @IsTest
    static void testParseGraph_EmptyJson_ReturnsEmptyGraph() {
        ToolFlowGraphService.FlowGraph g = ToolFlowGraphService.parseGraph('{}');
        System.assert(g.entry.isEmpty(), 'Empty JSON should produce empty entry list');
        System.assert(g.flow.isEmpty(), 'Empty JSON should produce empty flow list');
    }

    @IsTest
    static void testParseGraph_FromAsString_Rejected() {
        String json = '{"version":"3.0","entry":["tool_a"],"flow":[{"fromTools":"tool_a","type":"sequential","toTools":["tool_b"]}]}';
        Boolean threw = false;
        try {
            ToolFlowGraphService.parseGraph(json);
        } catch (Exception e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'String-valued fromTools should be rejected');
    }

    @IsTest
    static void testParseGraph_FromAsArray_JoinGate() {
        String json = '{"version":"3.0","entry":["a","b"],"flow":[{"fromTools":["a","b"],"type":"sequential","toTools":["c"]}]}';
        ToolFlowGraphService.FlowGraph g = ToolFlowGraphService.parseGraph(json);
        System.assertEquals(1, g.flow.size());
        System.assert(g.flow[0].isJoinGate(), 'Array from with 2 items should be a join gate');
    }

    // ── computeEligibleTools: entry ─────────────────────────────────────────────

    @IsTest
    static void testCompute_EntryToolsEligibleBeforeAnyExecution() {
        ToolFlowGraphService.FlowGraph g = buildGraph(new List<String>{ 'get_case', 'search_kb' }, null);
        Set<String> eligible = ToolFlowGraphService.computeEligibleTools(g, new Set<String>(), new Set<String>());
        System.assert(eligible.contains('get_case'));
        System.assert(eligible.contains('search_kb'));
    }

    @IsTest
    static void testCompute_LockedEntryToolIsExcluded() {
        ToolFlowGraphService.FlowGraph g = buildGraph(new List<String>{ 'tool_a', 'tool_b' }, null);
        Set<String> locked = new Set<String>{ 'tool_a' };
        Set<String> eligible = ToolFlowGraphService.computeEligibleTools(g, new Set<String>(), locked);
        System.assert(!eligible.contains('tool_a'), 'Locked entry tool should be excluded');
        System.assert(eligible.contains('tool_b'));
    }

    // ── computeEligibleTools: sequential ───────────────────────────────────────

    @IsTest
    static void testCompute_SequentialUnlocked_AfterFromExecuted() {
        ToolFlowGraphService.FlowGraph g = buildGraph(
            new List<String>{ 'step_1' },
            new List<Map<String, Object>>{ rule('step_1', 'sequential', new List<String>{ 'step_2' }) }
        );

        Set<String> eligibleBefore = ToolFlowGraphService.computeEligibleTools(g, new Set<String>(), new Set<String>());
        System.assert(!eligibleBefore.contains('step_2'), 'step_2 should not be eligible before step_1 runs');

        Set<String> eligibleAfter = ToolFlowGraphService.computeEligibleTools(g, new Set<String>{ 'step_1' }, new Set<String>());
        System.assert(eligibleAfter.contains('step_2'), 'step_2 should be eligible once step_1 has run');
    }

    @IsTest
    static void testCompute_EntryToolRemainsEligibleAfterExecution() {
        ToolFlowGraphService.FlowGraph g = buildGraph(
            new List<String>{ 'score_account' },
            new List<Map<String, Object>>{ rule('score_account', 'sequential', new List<String>{ 'update_case' }) }
        );
        Set<String> executed = new Set<String>{ 'score_account' };
        Set<String> eligible = ToolFlowGraphService.computeEligibleTools(g, executed, new Set<String>());
        System.assert(eligible.contains('score_account'), 'Entry tool should remain eligible (repeatable)');
        System.assert(eligible.contains('update_case'));
    }

    // ── computeEligibleTools: parallel ─────────────────────────────────────────

    @IsTest
    static void testCompute_ParallelUnlocked_BothToolsEligible() {
        ToolFlowGraphService.FlowGraph g = buildGraph(
            new List<String>{ 'fetch_data' },
            new List<Map<String, Object>>{ rule('fetch_data', 'parallel', new List<String>{ 'notify_user', 'log_event' }) }
        );
        Set<String> eligible = ToolFlowGraphService.computeEligibleTools(g, new Set<String>{ 'fetch_data' }, new Set<String>());
        System.assert(eligible.contains('notify_user'), 'parallel: notify_user should be eligible');
        System.assert(eligible.contains('log_event'), 'parallel: log_event should be eligible');
    }

    // ── computeEligibleTools: exclusive ────────────────────────────────────────

    @IsTest
    static void testCompute_Exclusive_AllBranchesEligibleUntilOnePicked() {
        ToolFlowGraphService.FlowGraph g = buildGraph(
            new List<String>{ 'evaluate_case' },
            new List<Map<String, Object>>{ rule('evaluate_case', 'exclusive', new List<String>{ 'escalate', 'resolve' }) }
        );
        Set<String> eligible = ToolFlowGraphService.computeEligibleTools(g, new Set<String>{ 'evaluate_case' }, new Set<String>());
        System.assert(eligible.contains('escalate'));
        System.assert(eligible.contains('resolve'));
    }

    @IsTest
    static void testCompute_Exclusive_LockedSiblingExcluded() {
        ToolFlowGraphService.FlowGraph g = buildGraph(
            new List<String>{ 'evaluate_case' },
            new List<Map<String, Object>>{ rule('evaluate_case', 'exclusive', new List<String>{ 'escalate', 'resolve' }) }
        );
        Set<String> locked = new Set<String>{ 'resolve' };
        Set<String> eligible = ToolFlowGraphService.computeEligibleTools(g, new Set<String>{ 'evaluate_case' }, locked);
        System.assert(eligible.contains('escalate'));
        System.assert(!eligible.contains('resolve'), 'Locked branch should be excluded');
    }

    // ── computeEligibleTools: join gate ─────────────────────────────────────────

    @IsTest
    static void testCompute_JoinGate_NotEligibleUntilAllFromComplete() {
        List<Map<String, Object>> rules = new List<Map<String, Object>>{
            rule(new List<String>{ 'tool_a', 'tool_b' }, 'sequential', new List<String>{ 'tool_c' })
        };
        ToolFlowGraphService.FlowGraph g = buildGraph(new List<String>{ 'tool_a', 'tool_b' }, rules);

        Set<String> onlyA = ToolFlowGraphService.computeEligibleTools(g, new Set<String>{ 'tool_a' }, new Set<String>());
        System.assert(!onlyA.contains('tool_c'), 'Join gate: tool_c not eligible with only tool_a done');

        Set<String> both = ToolFlowGraphService.computeEligibleTools(g, new Set<String>{ 'tool_a', 'tool_b' }, new Set<String>());
        System.assert(both.contains('tool_c'), 'Join gate: tool_c eligible once both tool_a and tool_b done');
    }

    // ── computeEligibleTools: nested branches ──────────────────────────────────

    @IsTest
    static void testCompute_NestedBranch_ChainUnlocks() {
        List<Map<String, Object>> rules = new List<Map<String, Object>>{
            rule('step_1', 'sequential', new List<String>{ 'step_2' }),
            rule('step_2', 'sequential', new List<String>{ 'step_3' })
        };
        ToolFlowGraphService.FlowGraph g = buildGraph(new List<String>{ 'step_1' }, rules);

        Set<String> afterStep1 = ToolFlowGraphService.computeEligibleTools(g, new Set<String>{ 'step_1' }, new Set<String>());
        System.assert(afterStep1.contains('step_2'));
        System.assert(!afterStep1.contains('step_3'), 'step_3 should not be eligible after only step_1');

        Set<String> afterStep2 = ToolFlowGraphService.computeEligibleTools(g, new Set<String>{ 'step_1', 'step_2' }, new Set<String>());
        System.assert(afterStep2.contains('step_3'));
    }

    // ── lockExclusiveSiblings ──────────────────────────────────────────────────

    @IsTest
    static void testLockExclusiveSiblings_LocksOtherBranches() {
        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '3.0',
                'entry' => new List<String>{ 'evaluate' },
                'flow' => new List<Map<String, Object>>{ rule('evaluate', 'exclusive', new List<String>{ 'branch_a', 'branch_b', 'branch_c' }) }
            }
        );
        AIAgentDefinition__c agentDef = new AIAgentDefinition__c(ToolFlowGraph__c = graphJson, EnableToolFlowGraph__c = true);

        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();
        TestFactory.createToolCallSequence(setup.agentExecution.Id, 'evaluate');

        ToolFlowGraphService.lockExclusiveSiblings(agentDef, 'branch_a', setup.agentExecution.Id);

        Set<String> locked = TransactionContext.getInstance().getLockedBranches(setup.agentExecution.Id);
        System.assert(locked.contains('branch_b'), 'branch_b should be locked after branch_a chosen');
        System.assert(locked.contains('branch_c'), 'branch_c should be locked after branch_a chosen');
        System.assert(!locked.contains('branch_a'), 'Chosen branch should NOT be locked');
    }

    @IsTest
    static void testLockExclusiveSiblings_DoesNotLockBeforeFromToolSatisfied() {
        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '3.0',
                'entry' => new List<String>{ 'evaluate' },
                'flow' => new List<Map<String, Object>>{ rule('evaluate', 'exclusive', new List<String>{ 'branch_a', 'branch_b', 'branch_c' }) }
            }
        );
        AIAgentDefinition__c agentDef = new AIAgentDefinition__c(ToolFlowGraph__c = graphJson, EnableToolFlowGraph__c = true);
        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();

        ToolFlowGraphService.lockExclusiveSiblings(agentDef, 'branch_a', setup.agentExecution.Id);

        Set<String> locked = TransactionContext.getInstance().getLockedBranches(setup.agentExecution.Id);
        System.assert(locked.isEmpty(), 'Exclusive siblings should not lock until the rule from-tool has actually executed');
    }

    @IsTest
    static void testLockExclusiveSiblings_NoOpForSequentialRule() {
        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '3.0',
                'entry' => new List<String>{ 'tool_a' },
                'flow' => new List<Map<String, Object>>{ rule('tool_a', 'sequential', new List<String>{ 'tool_b', 'tool_c' }) }
            }
        );
        AIAgentDefinition__c agentDef = new AIAgentDefinition__c(ToolFlowGraph__c = graphJson, EnableToolFlowGraph__c = true);
        Id fakeExecutionId = TestFactory.generateMockId(AgentExecution__c.SObjectType);

        ToolFlowGraphService.lockExclusiveSiblings(agentDef, 'tool_b', fakeExecutionId);

        Set<String> locked = TransactionContext.getInstance().getLockedBranches(fakeExecutionId);
        System.assert(locked.isEmpty(), 'Sequential rule should not lock any branches');
    }

    // ── filterToEligible: no-graph fallback ────────────────────────────────────

    @IsTest
    static void testFilterToEligible_NoGraphEnabled_ReturnsAll() {
        AIAgentDefinition__c agentDef = new AIAgentDefinition__c(EnableToolFlowGraph__c = false, ToolFlowGraph__c = null);

        List<AgentCapability__c> caps = new List<AgentCapability__c>{
            new AgentCapability__c(CapabilityName__c = 'tool_a'),
            new AgentCapability__c(CapabilityName__c = 'tool_b')
        };

        List<AgentCapability__c> result = ToolFlowGraphService.filterToEligible(caps, agentDef, null);
        System.assertEquals(2, result.size(), 'No graph: all capabilities returned');
    }

    @IsTest
    static void testFilterToEligible_MalformedGraph_ReturnsAll() {
        AIAgentDefinition__c agentDef = new AIAgentDefinition__c(EnableToolFlowGraph__c = true, ToolFlowGraph__c = 'NOT JSON');

        List<AgentCapability__c> caps = new List<AgentCapability__c>{ new AgentCapability__c(CapabilityName__c = 'tool_a') };

        List<AgentCapability__c> result = ToolFlowGraphService.filterToEligible(caps, agentDef, null);
        System.assertEquals(1, result.size(), 'Malformed graph: all capabilities returned as fallback');
    }

    @IsTest
    static void testFilterToEligible_ExclusiveChoicePersistsFromExecutionHistory() {
        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '3.0',
                'entry' => new List<String>{ 'evaluate_case' },
                'flow' => new List<Map<String, Object>>{ rule('evaluate_case', 'exclusive', new List<String>{ 'branch_a', 'branch_b' }) }
            }
        );
        AIAgentDefinition__c agentDef = new AIAgentDefinition__c(EnableToolFlowGraph__c = true, ToolFlowGraph__c = graphJson);

        TestFactory.AgentSetup setup = TestFactory.createFullAgentSetup().save();
        insert new List<ExecutionStep__c>{
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolName__c = 'evaluate_case',
                ToolCallId__c = 'call-evaluate-case',
                IsError__c = false
            ),
            new ExecutionStep__c(
                AgentExecution__c = setup.agentExecution.Id,
                StepType__c = 'ToolResult',
                StepRole__c = 'Tool',
                ToolName__c = 'branch_a',
                ToolCallId__c = 'call-branch-a',
                IsError__c = false
            )
        };

        TransactionContext.resetInstance();

        List<AgentCapability__c> caps = new List<AgentCapability__c>{
            new AgentCapability__c(CapabilityName__c = 'evaluate_case'),
            new AgentCapability__c(CapabilityName__c = 'branch_a'),
            new AgentCapability__c(CapabilityName__c = 'branch_b')
        };

        List<AgentCapability__c> result = ToolFlowGraphService.filterToEligible(caps, agentDef, setup.agentExecution.Id);
        Set<String> eligibleNames = new Set<String>();
        for (AgentCapability__c cap : result) {
            eligibleNames.add(cap.CapabilityName__c);
        }

        System.assert(eligibleNames.contains('branch_a'), 'Chosen branch should remain eligible after it succeeds');
        System.assert(!eligibleNames.contains('branch_b'), 'Sibling branch should stay locked even in a later transaction');
    }

    @IsTest
    static void testCollectValidationIssues_MixedGatewayTypesRejected() {
        ToolFlowGraphService.FlowGraph graph = buildGraph(
            new List<String>{ 'tool_a' },
            new List<Map<String, Object>>{
                rule('tool_a', 'sequential', new List<String>{ 'tool_b' }),
                rule('tool_a', 'exclusive', new List<String>{ 'tool_c', 'tool_d' })
            }
        );

        ToolFlowGraphService.ValidationResult result = ToolFlowGraphService.collectValidationIssues(
            graph,
            new Set<String>{ 'tool_a', 'tool_b', 'tool_c', 'tool_d' },
            true
        );

        System.assertEquals(false, result.isValid(), 'Mixed gateway types from the same source should be rejected');
        System.assert(String.join(result.errors, ' ').contains('multiple flow rules'), 'Error should explain the duplicate source definition');
    }

    @IsTest
    static void testCollectValidationIssues_ParallelRejectedWhenDisabled() {
        ToolFlowGraphService.FlowGraph graph = buildGraph(
            new List<String>{ 'tool_a' },
            new List<Map<String, Object>>{ rule('tool_a', 'parallel', new List<String>{ 'tool_b', 'tool_c' }) }
        );

        ToolFlowGraphService.ValidationResult result = ToolFlowGraphService.collectValidationIssues(
            graph,
            new Set<String>{ 'tool_a', 'tool_b', 'tool_c' },
            false
        );

        System.assertEquals(false, result.isValid(), 'Parallel rules should be rejected when agent parallel calling is disabled');
        System.assert(
            String.join(result.errors, ' ').contains('Parallel Tool Calling is disabled'),
            'Validation should mention the agent parallel calling setting'
        );
    }

    @IsTest
    static void testCollectValidationIssues_ExclusiveConditionsMustBeMeaningful() {
        String json =
            '{"version":"3.0","entry":["tool_a"],"flow":[{"fromTools":["tool_a"],"type":"exclusive","toTools":["tool_b","tool_c"],' +
            '"conditions":{"tool_b":"Default condition","tool_c":"Default condition"}}]}';
        ToolFlowGraphService.FlowGraph graph = ToolFlowGraphService.parseGraph(json);

        ToolFlowGraphService.ValidationResult result = ToolFlowGraphService.collectValidationIssues(
            graph,
            new Set<String>{ 'tool_a', 'tool_b', 'tool_c' },
            true
        );

        System.assertEquals(false, result.isValid(), 'Placeholder exclusive conditions should be rejected');
        String joinedErrors = String.join(result.errors, ' ');
        System.assert(joinedErrors.contains('placeholder condition text'), 'Validation should flag placeholder labels');
        System.assert(joinedErrors.contains('reuses the same condition label'), 'Validation should flag duplicate branch labels');
    }

    // ── isGraphStale / generateCapabilitiesHash ────────────────────────────────

    @IsTest
    static void testIsGraphStale_NoStoredHash_IsStale() {
        System.assert(ToolFlowGraphService.isGraphStale('abc', null), 'Blank stored hash should be stale');
        System.assert(ToolFlowGraphService.isGraphStale('abc', ''), 'Empty stored hash should be stale');
    }

    @IsTest
    static void testIsGraphStale_HashesMatch_NotStale() {
        System.assert(!ToolFlowGraphService.isGraphStale('abc123', 'abc123'), 'Matching hashes should not be stale');
    }

    @IsTest
    static void testIsGraphStale_HashesDiffer_IsStale() {
        System.assert(ToolFlowGraphService.isGraphStale('abc123', 'xyz789'), 'Different hashes should be stale');
    }

    @IsTest
    static void testGenerateCapabilitiesHash_Deterministic() {
        List<AgentCapability__c> caps = new List<AgentCapability__c>{
            new AgentCapability__c(CapabilityName__c = 'tool_a', Description__c = 'Desc A', ExposureLevel__c = 'External', RunAsynchronously__c = false),
            new AgentCapability__c(CapabilityName__c = 'tool_b', Description__c = 'Desc B', ExposureLevel__c = 'External', RunAsynchronously__c = true)
        };

        String hash1 = ToolFlowGraphService.generateCapabilitiesHash(caps);
        String hash2 = ToolFlowGraphService.generateCapabilitiesHash(caps);
        System.assertEquals(hash1, hash2, 'Hash should be deterministic');
        System.assertNotEquals('', hash1, 'Hash should not be empty');
    }

    @IsTest
    static void testGenerateCapabilitiesHash_OrderIndependent() {
        AgentCapability__c capA = new AgentCapability__c(
            CapabilityName__c = 'tool_a',
            Description__c = 'Desc A',
            ExposureLevel__c = 'External',
            RunAsynchronously__c = false
        );
        AgentCapability__c capB = new AgentCapability__c(
            CapabilityName__c = 'tool_b',
            Description__c = 'Desc B',
            ExposureLevel__c = 'External',
            RunAsynchronously__c = false
        );

        String hash1 = ToolFlowGraphService.generateCapabilitiesHash(new List<AgentCapability__c>{ capA, capB });
        String hash2 = ToolFlowGraphService.generateCapabilitiesHash(new List<AgentCapability__c>{ capB, capA });
        System.assertEquals(hash1, hash2, 'Hash should be order-independent (sorted)');
    }
}
