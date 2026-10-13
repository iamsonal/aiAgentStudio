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
 * Registers the tool types of Core's test-only tool classes. Agent Tool
 * Type records cannot be inserted in tests, so AgentToolTypeService loads
 * this fixture whenever it runs under test.
 */
@IsTest
public class AgentToolTypeTestFixtures {
    /** Stays in This Org: runs inside a savepoint; a failed or lost call is undone and may repeat. */
    public static final String IN_ORG = 'KernelTestTool';
    /** Changes Outside Systems: an unconfirmed call is Unknown. */
    public static final String EXTERNAL = 'KernelTestExternalTool';
    /** Reads Outside Systems: leaves the transaction but only reads; a failed or lost call repeats. */
    public static final String READ_ONLY_EXTERNAL = 'KernelTestReadOnlyExternalTool';
    /** No Effects value: Core treats it as Changes Outside Systems. */
    public static final String EFFECTS_UNSET = 'KernelTestEffectsUnsetTool';
    /** Stays in This Org, with a class that filters its text for the requester. */
    public static final String FILTERED = 'KernelTestFilteredTool';
    /** Stays in This Org, with a class that builds its Input Schema from its settings. */
    public static final String AUTHORING = 'KernelTestAuthoringTool';

    public AgentToolTypeTestFixtures() {
        AgentToolTypeService.registerForTest(IN_ORG, 'KernelTestTool', AgentToolTypeService.EFFECTS_IN_ORG);
        AgentToolTypeService.registerForTest(EXTERNAL, 'KernelTestTool', AgentToolTypeService.EFFECTS_CHANGES_OUTSIDE);
        AgentToolTypeService.registerForTest(READ_ONLY_EXTERNAL, 'KernelTestTool', AgentToolTypeService.EFFECTS_READS_OUTSIDE);
        AgentToolTypeService.registerForTest(EFFECTS_UNSET, 'KernelTestTool', null);
        AgentToolTypeService.registerForTest(FILTERED, 'KernelTestFilteredTool', AgentToolTypeService.EFFECTS_IN_ORG);
        AgentToolTypeService.registerForTest(AUTHORING, 'KernelTestAuthoringTool', AgentToolTypeService.EFFECTS_IN_ORG);
    }
}
