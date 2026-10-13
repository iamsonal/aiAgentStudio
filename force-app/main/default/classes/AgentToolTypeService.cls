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
 * Resolves Agent Tool Type records and the recovery rules their Effects imply.
 * Stays in This Org runs inside a savepoint, so a failed or lost call leaves
 * nothing behind and may be repeated. Reads Outside Systems runs outside a
 * savepoint but may also be repeated, because it changes nothing. Changes
 * Outside Systems is never repeated after an unconfirmed outcome unless the
 * tool itself asks for a retry. A missing type or value is Changes Outside
 * Systems.
 */
public inherited sharing class AgentToolTypeService {
    public static final String IMPLEMENTATION_STANDARD = 'Standard';
    public static final String IMPLEMENTATION_FLOW = 'Flow';
    public static final String IMPLEMENTATION_APEX = 'Apex';
    public static final String EFFECTS_IN_ORG = 'InOrg';
    public static final String EFFECTS_READS_OUTSIDE = 'ReadsOutside';
    public static final String EFFECTS_CHANGES_OUTSIDE = 'ChangesOutside';
    private static Map<String, AgentToolType__mdt> typesByName;

    /** Returns the named tool type when it names a tool class, or null. */
    public static AgentToolType__mdt toolType(String developerName) {
        AgentToolType__mdt toolType = String.isBlank(developerName) ? null : types().get(developerName.trim().toLowerCase());
        return toolType == null || String.isBlank(toolType.ToolClass__c) ? null : toolType;
    }

    public static AgentToolType__mdt toolType(AgentTool__c tool) {
        return tool == null ? null : toolType(tool.ToolType__c);
    }

    /** Every usable tool type, ordered by label. */
    public static List<AgentToolType__mdt> toolTypes() {
        Map<String, AgentToolType__mdt> byLabel = new Map<String, AgentToolType__mdt>();
        for (AgentToolType__mdt toolType : types().values()) {
            if (!String.isBlank(toolType.ToolClass__c)) {
                byLabel.put(toolType.MasterLabel + '|' + toolType.DeveloperName, toolType);
            }
        }
        List<String> labels = new List<String>(byLabel.keySet());
        labels.sort();
        List<AgentToolType__mdt> result = new List<AgentToolType__mdt>();
        for (String label : labels) {
            result.add(byLabel.get(label));
        }
        return result;
    }

    /** Copies each tool's Implementation Type from its tool type, so reports never disagree with it. */
    public static void stampImplementationType(List<AgentTool__c> tools) {
        for (AgentTool__c tool : tools) {
            tool.ImplementationType__c = implementationType(toolType(tool));
        }
    }

    /** Standard, Flow, or Apex; a tool type that leaves it blank is custom Apex. */
    public static String implementationType(AgentToolType__mdt toolType) {
        if (toolType == null) {
            return null;
        }
        return String.isBlank(toolType.ImplementationType__c) ? IMPLEMENTATION_APEX : toolType.ImplementationType__c;
    }

    /** Whether the tool's type needs an objectApiName its configuration does not name. */
    public static Boolean isMissingRequiredObject(AgentTool__c tool) {
        AgentToolType__mdt toolType = toolType(tool);
        if (toolType == null || toolType.RequiresObject__c != true) {
            return false;
        }
        Object objectApiName;
        try {
            objectApiName = ((Map<String, Object>) JSON.deserializeUntyped(tool.ImplementationConfiguration__c)).get('objectApiName');
        } catch (Exception unreadable) {
            objectApiName = null;
        }
        return !(objectApiName instanceof String) || String.isBlank((String) objectApiName);
    }

    public static String missingObjectMessage(String developerName) {
        return 'Tool type ' + developerName + ' acts on one Salesforce object: set objectApiName in the Implementation Configuration.';
    }

    public static String unavailableMessage(String developerName) {
        return String.isBlank(developerName)
            ? 'A tool type is required: enter the API name of an Agent Tool Type record, such as UpdateRecord.'
            : 'Tool type ' + developerName + ' must name an Agent Tool Type record with a tool class.';
    }

    /** The tool type's Effects. Fails closed: a missing type or value is Changes Outside Systems. */
    public static String effects(AgentTool__c tool) {
        AgentToolType__mdt toolType = toolType(tool);
        return toolType == null ? EFFECTS_CHANGES_OUTSIDE : effects(toolType.Effects__c);
    }

    /** Whether the tool can leave the transaction, so it cannot run inside a savepoint. */
    public static Boolean hasExternalEffects(AgentTool__c tool) {
        return effects(tool) != EFFECTS_IN_ORG;
    }

    /** Whether the tool may change something outside this org. */
    public static Boolean mayChangeOutside(AgentTool__c tool) {
        return effects(tool) == EFFECTS_CHANGES_OUTSIDE;
    }

    /** The Effects fixed on this command at its first lease; blank is Changes Outside Systems. */
    public static String admittedEffects(AgentCommand__c command) {
        return effects(command.AdmittedEffects__c);
    }

    /**
     * Whether this command runs inside a savepoint: it was admitted as Only
     * This Org. A command that was never admitted has no proven binding and
     * does not.
     */
    public static Boolean runsInSavepoint(AgentCommand__c command) {
        return !String.isBlank(command.AdmittedToolBindingHash__c) && admittedEffects(command) == EFFECTS_IN_ORG;
    }

    /**
     * Whether a lost or failed attempt of this command may be repeated: it was
     * admitted as Stays in This Org or Reads Outside Systems.
     */
    public static Boolean isRetrySafe(AgentCommand__c command) {
        return !String.isBlank(command.AdmittedToolBindingHash__c) && admittedEffects(command) != EFFECTS_CHANGES_OUTSIDE;
    }

    /** Fixes the tool's executable binding, including its tool type's class and effects, when its command is first leased. */
    public static void admit(AgentCommand__c command, AgentTool__c tool) {
        command.AdmittedEffects__c = effects(tool);
        command.AdmittedToolBindingHash__c = bindingHash(tool);
    }

    public static String bindingHash(AgentTool__c tool) {
        if (tool == null) {
            return null;
        }
        AgentToolType__mdt toolType = toolType(tool);
        String toolEffects = effects(tool);
        // Effects is encoded as 'true'/'false' plus 'safeToRepeat' so hashes already stored on leased commands still match.
        List<String> binding = new List<String>{
            String.valueOf(tool.Id),
            tool.ToolType__c,
            toolType == null ? null : toolType.ToolClass__c,
            String.valueOf(toolEffects != EFFECTS_IN_ORG),
            tool.ImplementationConfiguration__c
        };
        if (toolEffects == EFFECTS_READS_OUTSIDE) {
            binding.add('safeToRepeat');
        }
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(JSON.serialize(binding))));
    }

    private static String effects(String value) {
        return value == EFFECTS_IN_ORG || value == EFFECTS_READS_OUTSIDE ? value : EFFECTS_CHANGES_OUTSIDE;
    }

    private static Map<String, AgentToolType__mdt> types() {
        if (typesByName == null) {
            typesByName = new Map<String, AgentToolType__mdt>();
            for (AgentToolType__mdt toolType : AgentToolType__mdt.getAll().values()) {
                typesByName.put(toolType.DeveloperName.toLowerCase(), toolType);
            }
            if (Test.isRunningTest()) {
                // Test-only tool classes register their types from this @IsTest fixture.
                Type fixtures = Type.forName('AgentToolTypeTestFixtures');
                if (fixtures != null) {
                    fixtures.newInstance();
                }
            }
        }
        return typesByName;
    }

    @TestVisible
    private static void registerForTest(String developerName, String toolClass, String effects) {
        types()
            .put(
                developerName.toLowerCase(),
                new AgentToolType__mdt(
                    DeveloperName = developerName,
                    MasterLabel = developerName,
                    ToolClass__c = toolClass,
                    Effects__c = effects,
                    ImplementationType__c = IMPLEMENTATION_APEX,
                    RequiresObject__c = false
                )
            );
    }
}
