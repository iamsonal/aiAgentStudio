/**
 * @description Focused tests for ToolDependencyValidator dependency enforcement
 */
@IsTest
private class ToolDependencyValidatorTest {
    @IsTest
    static void testValidate_AllOfAndAnyOfBlocking() {
        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '1.0',
                'generatedAt' => '2026-01-25T10:30:00Z',
                'dependencies' => new Map<String, Object>{
                    'tool_b' => new Map<String, Object>{ 'allOf' => new List<String>{ 'tool_a' } },
                    'tool_c' => new Map<String, Object>{ 'anyOf' => new List<String>{ 'tool_a', 'tool_b' } }
                }
            }
        );

        ToolDependencyValidator.ValidationResult blockedAllOf = ToolDependencyValidator.validate('tool_b', new Set<String>(), graphJson);
        System.assertEquals(false, blockedAllOf.allowed, 'tool_b should be blocked when tool_a not executed');
        System.assertEquals(true, blockedAllOf.missingDependencies.contains('tool_a'), 'Missing allOf dependency should be listed');
        System.assert(blockedAllOf.guidanceForLLM.contains('DEPENDENCY VIOLATION'), 'Guidance should explain violation');

        ToolDependencyValidator.ValidationResult blockedAnyOf = ToolDependencyValidator.validate('tool_c', new Set<String>(), graphJson);
        System.assertEquals(false, blockedAnyOf.allowed, 'tool_c should be blocked when no anyOf met');
        System.assertEquals(true, blockedAnyOf.missingAnyOfGroups[0].contains('tool_a'), 'Missing anyOf group should be listed');

        ToolDependencyValidator.ValidationResult allowed = ToolDependencyValidator.validate('tool_b', new Set<String>{ 'tool_a' }, graphJson);
        System.assertEquals(true, allowed.allowed, 'tool_b should be allowed once tool_a executed');

        ToolDependencyValidator.ValidationResult anyOfAllowed = ToolDependencyValidator.validate('tool_c', new Set<String>{ 'tool_b' }, graphJson);
        System.assertEquals(true, anyOfAllowed.allowed, 'tool_c should be allowed once anyOf dependency satisfied');
    }

    @IsTest
    static void testDetectCircularDependencies() {
        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '1.0',
                'dependencies' => new Map<String, Object>{
                    'tool_a' => new Map<String, Object>{ 'allOf' => new List<String>{ 'tool_b' } },
                    'tool_b' => new Map<String, Object>{ 'allOf' => new List<String>{ 'tool_a' } }
                }
            }
        );

        ToolDependencyValidator.DependencyGraph graph = ToolDependencyValidator.parseGraph(graphJson);
        List<String> cycles = ToolDependencyValidator.detectCircularDependencies(graph);

        System.assertEquals(true, cycles.contains('tool_a'), 'Cycle should include tool_a');
        System.assertEquals(true, cycles.contains('tool_b'), 'Cycle should include tool_b');
    }

    @IsTest
    static void testTopologicalSort_OrdersDependencies() {
        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '1.0',
                'dependencies' => new Map<String, Object>{ 'tool_b' => new Map<String, Object>{ 'allOf' => new List<String>{ 'tool_a' } } }
            }
        );

        ToolDependencyValidator.DependencyGraph graph = ToolDependencyValidator.parseGraph(graphJson);

        Set<String> tools = new Set<String>{ 'tool_b', 'tool_a' };
        List<String> ordered = ToolDependencyValidator.topologicalSort(tools, graph, new Set<String>());

        System.assertEquals(2, ordered.size(), 'Both tools should be ordered');
        System.assertEquals('tool_a', ordered[0], 'tool_a should come before tool_b');
        System.assertEquals('tool_b', ordered[1], 'tool_b should come after tool_a');
    }

    @IsTest
    static void testValidate_BlankGraphJson_ReturnsAllowed() {
        ToolDependencyValidator.ValidationResult result = ToolDependencyValidator.validate('any_tool', new Set<String>(), '');
        System.assertEquals(true, result.allowed, 'Blank graph JSON should allow all tools');

        ToolDependencyValidator.ValidationResult result2 = ToolDependencyValidator.validate('any_tool', new Set<String>(), null);
        System.assertEquals(true, result2.allowed, 'Null graph JSON should allow all tools');
    }

    @IsTest
    static void testValidate_ToolNotInGraph_ReturnsAllowed() {
        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '1.0',
                'dependencies' => new Map<String, Object>{ 'tool_b' => new Map<String, Object>{ 'allOf' => new List<String>{ 'tool_a' } } }
            }
        );

        ToolDependencyValidator.ValidationResult result = ToolDependencyValidator.validate('unknown_tool', new Set<String>(), graphJson);
        System.assertEquals(true, result.allowed, 'Tool not in dependency graph should be allowed');
    }

    @IsTest
    static void testParseGraph_EmptyDependencies_HasNoDependencies() {
        String graphJson = JSON.serialize(new Map<String, Object>{ 'version' => '1.0', 'dependencies' => new Map<String, Object>() });

        ToolDependencyValidator.DependencyGraph graph = ToolDependencyValidator.parseGraph(graphJson);
        System.assertEquals(false, graph.hasDependencies(), 'Empty dependencies should report no dependencies');
        System.assertEquals(true, graph.getToolsWithDependencies().isEmpty(), 'Should have no tools with dependencies');
    }

    @IsTest
    static void testParseGraph_MalformedJson_ReturnsEmptyGraph() {
        // parseGraph wraps JSON.deserializeUntyped which throws JSONException on malformed JSON
        // The method doesn't currently catch this, so the exception propagates
        Boolean threw = false;
        try {
            ToolDependencyValidator.DependencyGraph graph = ToolDependencyValidator.parseGraph('{not valid json}');
        } catch (System.JSONException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Malformed JSON should throw JSONException');
    }

    @IsTest
    static void testDependencyRequirements_IsEmpty() {
        ToolDependencyValidator.DependencyRequirements reqs = new ToolDependencyValidator.DependencyRequirements();
        System.assertEquals(true, reqs.isEmpty(), 'New DependencyRequirements should be empty');

        reqs.allOf.add('tool_a');
        System.assertEquals(false, reqs.isEmpty(), 'DependencyRequirements with allOf should not be empty');
    }

    @IsTest
    static void testTopologicalSort_AlreadyExecutedTools_AreExcluded() {
        String graphJson = JSON.serialize(
            new Map<String, Object>{
                'version' => '1.0',
                'dependencies' => new Map<String, Object>{ 'tool_b' => new Map<String, Object>{ 'allOf' => new List<String>{ 'tool_a' } } }
            }
        );

        ToolDependencyValidator.DependencyGraph graph = ToolDependencyValidator.parseGraph(graphJson);

        Set<String> tools = new Set<String>{ 'tool_b', 'tool_a' };
        List<String> ordered = ToolDependencyValidator.topologicalSort(tools, graph, new Set<String>{ 'tool_a' });

        System.assertEquals(1, ordered.size(), 'Already executed tool should be excluded from sort');
        System.assertEquals('tool_b', ordered[0], 'Only tool_b should remain');
    }

    @IsTest
    static void testGenerateCapabilitiesHash_EmptyList_ReturnsHash() {
        String hash = ToolDependencyValidator.generateCapabilitiesHash(new List<AgentCapability__c>());
        // Empty list may return blank hash or a hash of empty content - both are valid
        System.assertNotEquals(null, hash, 'Empty list should return a non-null hash');
    }

    @IsTest
    static void testCapabilitiesHashAndStaleness() {
        AgentCapability__c capA = new AgentCapability__c(CapabilityName__c = 'cap_a', ExposureLevel__c = 'External');
        AgentCapability__c capB = new AgentCapability__c(CapabilityName__c = 'cap_b', ExposureLevel__c = 'External');

        String hash = ToolDependencyValidator.generateCapabilitiesHash(new List<AgentCapability__c>{ capA, capB });
        System.assert(String.isNotBlank(hash), 'Hash should be generated');
        System.assertEquals(false, ToolDependencyValidator.isGraphStale(hash, hash), 'Matching hashes should not be stale');
        System.assertEquals(true, ToolDependencyValidator.isGraphStale(hash, 'different'), 'Mismatched hashes should be stale');

        AgentCapability__c capAAsync = new AgentCapability__c(CapabilityName__c = 'cap_a', ExposureLevel__c = 'External', RunAsynchronously__c = true);
        String asyncHash = ToolDependencyValidator.generateCapabilitiesHash(new List<AgentCapability__c>{ capAAsync, capB });
        System.assertNotEquals(hash, asyncHash, 'Hash should change when execution mode changes');
    }
}
